import Foundation

struct SoftwareVODRebufferGate: Equatable {
    static let parkedVideoCap = 256
    static let heldParkedVideoCap = 1024
    static let heldParkedVideoByteBudget = 48 << 20
    static let unprovenSourcePauseLeadSeconds = 0.0

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

    mutating func evaluate(lead: Double, isPlaying: Bool, sourceDry: Bool?, parkedCount: Int) -> Action {
        if lead >= AudioLookaheadPolicy.rebufferResumeLeadSeconds { everHadLead = true }
        guard isPlaying else {
            rebuffering = false
            return .none
        }
        if rebuffering {
            guard lead >= AudioLookaheadPolicy.rebufferResumeLeadSeconds else { return .none }
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
