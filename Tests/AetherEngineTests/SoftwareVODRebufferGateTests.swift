import Testing
@testable import AetherEngine

@Suite("SW VOD rebuffer hold (decoupled loop under a starved source)")
struct SoftwareVODRebufferGateTests {

    private let resumeLead = AudioLookaheadPolicy.rebufferResumeLeadSeconds

    private func engaged() -> SoftwareVODRebufferGate {
        var gate = SoftwareVODRebufferGate()
        _ = gate.evaluate(lead: resumeLead, isPlaying: true, sourceDry: false, parkedCount: 0)
        let action = gate.evaluate(lead: 0.05, isPlaying: true, sourceDry: true, parkedCount: 10)
        #expect(action == .pauseForRebuffer)
        return gate
    }

    @Test("a source slower than realtime from the first second pauses the clock once the lead runs out")
    func slowStartPauses() {
        var gate = SoftwareVODRebufferGate()
        let action = gate.evaluate(lead: -0.2, isPlaying: true, sourceDry: true, parkedCount: 12)
        #expect(action == .pauseForRebuffer)
        #expect(gate.rebuffering)
    }

    @Test("an exactly-realtime source whose lead never leaves the start offset is not paused")
    func realtimeSourceKeepsRunning() {
        var gate = SoftwareVODRebufferGate()
        let action = gate.evaluate(lead: 0.05, isPlaying: true, sourceDry: true, parkedCount: 12)
        #expect(action == .none)
        #expect(!gate.rebuffering)
    }

    @Test("a low lead with packets waiting in the store is decode lag, not a starved source")
    func storedPacketsAreNotStarvation() {
        var gate = SoftwareVODRebufferGate()
        _ = gate.evaluate(lead: resumeLead, isPlaying: true, sourceDry: false, parkedCount: 0)
        let action = gate.evaluate(lead: -0.5, isPlaying: true, sourceDry: false, parkedCount: 40)
        #expect(action == .none)
    }

    @Test("a paused session is never put into a rebuffer hold")
    func userPauseIsNotRebuffer() {
        var gate = SoftwareVODRebufferGate()
        let action = gate.evaluate(lead: -3, isPlaying: false, sourceDry: true, parkedCount: 0)
        #expect(action == .none)
    }

    @Test("the hold keeps reading past the normal FIFO cap instead of releasing there")
    func holdSurvivesTheNormalCap() {
        var gate = engaged()
        let cap = SoftwareVODRebufferGate.parkedVideoCap
        #expect(gate.parkedCap(parkedCount: cap, parkedBytes: cap * 8_000) > cap)
        let released1 = gate.releaseForRendererWait(parkedCount: cap, parkedBytes: cap * 8_000)
        #expect(!released1)
        #expect(gate.rebuffering)
    }

    @Test("the hold resumes on the resume lead, not before")
    func resumesAtTheResumeLead() {
        var gate = engaged()
        let action2 = gate.evaluate(lead: resumeLead - 0.5, isPlaying: true, sourceDry: true, parkedCount: 60)
        #expect(action2 == .none)
        let action3 = gate.evaluate(lead: resumeLead, isPlaying: true, sourceDry: false, parkedCount: 60)
        #expect(action3 == .resume)
        #expect(!gate.rebuffering)
    }

    @Test("a hold released by the memory backstop does not re-engage until the parked video drains")
    func backstopReleaseHasHysteresis() {
        var gate = engaged()
        let full = SoftwareVODRebufferGate.heldParkedVideoCap
        let released4 = gate.releaseForRendererWait(parkedCount: full, parkedBytes: full * 8_000)
        #expect(released4)
        let action5 = gate.evaluate(lead: -0.5, isPlaying: true, sourceDry: true, parkedCount: full - 1)
        #expect(action5 == .none)
        let action6 = gate.evaluate(lead: -0.5, isPlaying: true, sourceDry: true,
                              parkedCount: SoftwareVODRebufferGate.parkedVideoCap)
        #expect(action6 == .none)
        let action7 = gate.evaluate(lead: -0.5, isPlaying: true, sourceDry: true,
                              parkedCount: SoftwareVODRebufferGate.parkedVideoCap / 2)
        #expect(action7 == .pauseForRebuffer)
    }

    @Test("the byte budget ends the hold's extra room before the packet count does")
    func byteBudgetBoundsTheHold() {
        let gate = engaged()
        let parked = SoftwareVODRebufferGate.parkedVideoCap + 10
        #expect(gate.parkedCap(parkedCount: parked,
                               parkedBytes: SoftwareVODRebufferGate.heldParkedVideoByteBudget) == parked)
    }

    @Test("end of media and seams release the hold unconditionally")
    func drainReleases() {
        var gate = engaged()
        let released8 = gate.releaseForDrain()
        #expect(released8)
        #expect(!gate.rebuffering)
        let released9 = gate.releaseForDrain()
        #expect(!released9)
    }

    @Test("a seek resets the hold")
    func resetClears() {
        var gate = engaged()
        gate.reset()
        #expect(!gate.rebuffering)
    }
}

@Suite("SW VOD rebuffer hold vs the host's own pause")
struct SoftwareVODRebufferGatePauseTests {

    @Test("a host pause during a hold drops the hold, so the resume never restarts a paused clock")
    func hostPauseDropsTheHold() {
        var gate = SoftwareVODRebufferGate()
        _ = gate.evaluate(lead: AudioLookaheadPolicy.rebufferResumeLeadSeconds, isPlaying: true,
                          sourceDry: false, parkedCount: 0)
        let action10 = gate.evaluate(lead: -0.3, isPlaying: true, sourceDry: true, parkedCount: 0)
        #expect(action10 == .pauseForRebuffer)
        let action11 = gate.evaluate(lead: 0.5, isPlaying: false, sourceDry: true, parkedCount: 0)
        #expect(action11 == .none)
        #expect(!gate.rebuffering)
        let action12 = gate.evaluate(lead: 3, isPlaying: false, sourceDry: false, parkedCount: 0)
        #expect(action12 == .none)
    }
}
