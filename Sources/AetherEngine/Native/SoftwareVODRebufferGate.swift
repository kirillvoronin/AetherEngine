import Foundation

struct SoftwareVODRebufferGate: Equatable {
    static let parkedVideoCap = 256
    static let heldParkedVideoCap = 1024
    static let heldParkedVideoByteBudget = 48 << 20
    static let unprovenSourcePauseLeadSeconds = 0.0
    /// The resume target: at least this much stored ahead of the clock...
    static let minimumResumeLeadSeconds = 10.0
    /// ...and enough that, at the measured fill rate, the next starvation is this far away...
    static let keepUpHorizonSeconds = 30.0
    /// ...unless this much is stored, which resumes even a source that barely delivers.
    static let maximumResumeLeadSeconds = 30.0

    /// What the packet store holds ahead of the clock, and how fast the source refills it.
    struct SourceFill: Equatable {
        var bufferedLead: Double
        var fillRate: Double?
        var canGrow: Bool
    }

    enum Action: Equatable {
        case none
        case pauseForRebuffer
        case resume
    }

    private(set) var rebuffering = false
    private(set) var everHadLead = false
    private(set) var backstopReleased = false

    mutating func reset() {
        self = SoftwareVODRebufferGate()
    }

    mutating func evaluate(lead: Double, isPlaying: Bool, sourceDry: Bool?, parkedCount: Int,
                           fill: SourceFill? = nil) -> Action {
        if lead >= AudioLookaheadPolicy.rebufferResumeLeadSeconds { everHadLead = true }
        guard isPlaying else {
            rebuffering = false
            return .none
        }
        if rebuffering {
            guard Self.mayResume(audioLead: lead, fill: fill) else { return .none }
            rebuffering = false
            return .resume
        }
        if backstopReleased {
            guard parkedCount <= Self.parkedVideoCap / 2 else { return .none }
            backstopReleased = false
        }
        let pauseBelow: Double
        switch sourceDry {
        case .none:
            guard everHadLead else { return .none }
            pauseBelow = AudioLookaheadPolicy.underrunPauseLeadSeconds
        case .some(false):
            return .none
        case .some(true):
            pauseBelow = everHadLead
                ? AudioLookaheadPolicy.underrunPauseLeadSeconds : Self.unprovenSourcePauseLeadSeconds
        }
        guard lead < pauseBelow else { return .none }
        rebuffering = true
        return .pauseForRebuffer
    }

    /// AVPlayer's "likely to keep up", on what the software path can measure: the store's lead
    /// over the clock, and the media seconds the source adds per wall second. Playing drains the
    /// lead at 1 s/s and the source refills it at `fillRate`, so it lasts `lead / (1 - fillRate)`.
    /// A session without a store, or a store that cannot grow (source ended, window or byte budget
    /// full), has nothing more to wait for and keeps the audio-lead rule.
    static func mayResume(audioLead: Double, fill: SourceFill?) -> Bool {
        guard audioLead >= AudioLookaheadPolicy.rebufferResumeLeadSeconds else { return false }
        guard let fill, fill.canGrow else { return true }
        let lead = fill.bufferedLead
        if lead >= maximumResumeLeadSeconds { return true }
        guard lead >= minimumResumeLeadSeconds, let rate = fill.fillRate, rate.isFinite else { return false }
        if rate >= 1 { return true }
        return lead / (1 - max(0, rate)) >= keepUpHorizonSeconds
    }

    func parkedCap(parkedCount: Int, parkedBytes: Int) -> Int {
        guard rebuffering else { return Self.parkedVideoCap }
        guard parkedBytes < Self.heldParkedVideoByteBudget else {
            return min(parkedCount, Self.heldParkedVideoCap)
        }
        return Self.heldParkedVideoCap
    }

    mutating func releaseForRendererWait(parkedCount: Int, parkedBytes: Int) -> Bool {
        guard rebuffering, parkedCount >= parkedCap(parkedCount: parkedCount, parkedBytes: parkedBytes)
        else { return false }
        rebuffering = false
        backstopReleased = true
        return true
    }

    mutating func releaseForDrain() -> Bool {
        guard rebuffering else { return false }
        rebuffering = false
        return true
    }
}

/// Media seconds the source stores per wall second, over a recent window. Measured on timestamps
/// rather than bytes over a nominal bitrate, so a variable-bitrate stretch is counted as played.
struct SourceFillRateMeter: Equatable {
    static let windowSeconds = 8.0
    static let minimumSpanSeconds = 2.0
    static let sampleSpacingSeconds = 0.25

    private struct Sample: Equatable {
        let wall: Double
        let media: Double
    }

    private var samples: [Sample] = []

    mutating func reset() {
        samples.removeAll(keepingCapacity: true)
    }

    mutating func record(mediaSeconds: Double, at wallSeconds: Double) {
        guard mediaSeconds.isFinite, wallSeconds.isFinite else { return }
        if let last = samples.last, wallSeconds - last.wall < Self.sampleSpacingSeconds { return }
        samples.append(Sample(wall: wallSeconds, media: mediaSeconds))
        let floor = wallSeconds - Self.windowSeconds
        if let keep = samples.firstIndex(where: { $0.wall >= floor }), keep > 0 {
            samples.removeFirst(keep)
        }
    }

    var rate: Double? {
        guard let first = samples.first, let last = samples.last else { return nil }
        let span = last.wall - first.wall
        guard span >= Self.minimumSpanSeconds else { return nil }
        return max(0, (last.media - first.media) / span)
    }
}
