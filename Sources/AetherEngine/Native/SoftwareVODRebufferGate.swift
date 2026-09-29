import Foundation

struct SoftwareVODRebufferGate: Equatable {
    static let parkedVideoCap = 256
    static let heldParkedVideoCap = 1024
    static let heldParkedVideoByteBudget = 48 << 20

    enum Action: Equatable {
        case none
        case pauseForRebuffer
        case resume
    }

    private(set) var rebuffering = false
    private(set) var everHadLead = false

    mutating func reset() {
        self = SoftwareVODRebufferGate()
    }

    mutating func evaluate(lead: Double, isPlaying: Bool, sourceDry: Bool?, parkedCount: Int) -> Action {
        if lead >= AudioLookaheadPolicy.rebufferResumeLeadSeconds { everHadLead = true }
        guard everHadLead, isPlaying || rebuffering else { return .none }
        switch AudioLookaheadPolicy.clockAction(
            rebuffering: rebuffering,
            lastFedAudioPTS: lead,
            clockSeconds: 0,
            atRingEnd: true,
            sourceEnded: false
        ) {
        case .pauseForRebuffer:
            rebuffering = true
            return .pauseForRebuffer
        case .resume:
            rebuffering = false
            return .resume
        case .none:
            return .none
        }
    }

    func parkedCap(parkedCount: Int, parkedBytes: Int) -> Int {
        Self.parkedVideoCap
    }

    mutating func releaseForRendererWait(parkedCount: Int, parkedBytes: Int) -> Bool {
        guard rebuffering else { return false }
        rebuffering = false
        return true
    }

    mutating func releaseForDrain() -> Bool {
        guard rebuffering else { return false }
        rebuffering = false
        return true
    }
}
