import Foundation
import Testing
import AetherLibavcodec
@testable import AetherEngine

// TVSeerr fork: TrueHD Atmos objects rendered into a 7.1.4 bed.

private let L = 0, R = 1, C = 2, LFE = 3, Ls = 4, Rs = 5, Rls = 6, Rrs = 7, Vhl = 8, Vhr = 9, Ltr = 10, Rtr = 11

private func power(_ g: [Float]) -> Float { g.reduce(0) { $0 + $1 * $1 } }

@Suite("RoomPanner dual-balance panning into 7.1.4")
struct RoomPannerTests {
    let panner = RoomPanner(layout: .atmos714)

    @Test("power is preserved everywhere in the room, LFE never fed")
    func powerPreserved() {
        for x in stride(from: Float(0), through: 1, by: 0.125) {
            for y in stride(from: Float(0), through: 1, by: 0.125) {
                for z in stride(from: Float(-0.5), through: 1, by: 0.25) {
                    let g = panner.gains(x: x, y: y, z: z)
                    #expect(abs(power(g) - 1) < 1e-4, "x \(x) y \(y) z \(z)")
                    #expect(g[LFE] == 0)
                }
            }
        }
    }

    @Test("a position on a speaker feeds that speaker alone")
    func discreteAtSpeakers() {
        for (index, s) in RoomLayout.atmos714.speakers.enumerated() where !s.isLFE {
            let g = panner.gains(x: s.x, y: s.y, z: s.z)
            #expect(abs(g[index] - 1) < 1e-6, "\(s.label)")
            #expect(abs(power(g) - 1) < 1e-6)
        }
    }

    @Test("halfway up the front-left edge splits equal-power between L and Vhl")
    func heightSplit() {
        let g = panner.gains(x: 0, y: 0, z: 0.5)
        #expect(abs(g[L] - sqrtf(0.5)) < 1e-5)
        #expect(abs(g[Vhl] - sqrtf(0.5)) < 1e-5)
    }

    @Test("below ear level stays on the floor")
    func belowEarLevel() {
        #expect(panner.gains(x: 1, y: 1, z: -1) == panner.gains(x: 1, y: 1, z: 0))
    }

    @Test("an object without elevation never reaches the heights")
    func elevationOff() {
        let g = panner.gains(x: 0.3, y: 0.2, z: 1, elevation: false)
        for top in [Vhl, Vhr, Ltr, Rtr] { #expect(g[top] == 0) }
        #expect(abs(power(g) - 1) < 1e-5)
    }

    @Test("snap picks the nearest speaker")
    func snap() {
        let g = panner.gains(x: 0.9, y: 0.6, z: 0.1, snap: true)
        #expect(g[Rs] == 1)
        #expect(power(g) == 1)
    }

    @Test("screen-only keeps an object on L, C, R")
    func screenOnly() {
        let g = panner.gains(x: 0.2, y: 0.9, z: 0.8, zone: RoomPanner.Zone.screenOnly.rawValue)
        for (i, v) in g.enumerated() where ![L, C, R].contains(i) { #expect(v == 0) }
        #expect(abs(power(g) - 1) < 1e-5)
    }

    @Test("size spreads power over more speakers without changing it")
    func size() {
        let point = panner.gains(x: 0.5, y: 0.5, z: 0.5)
        let wide = panner.gains(x: 0.5, y: 0.5, z: 0.5, size: 0.8)
        #expect(abs(power(wide) - 1) < 1e-4)
        #expect(wide.filter { $0 > 0.01 }.count >= point.filter { $0 > 0.01 }.count)
    }

    @Test("bed speakers: own speaker, LFE to LFE, top sides between top front and top rear")
    func beds() {
        #expect(panner.bedGains(code: 0)[L] == 1)
        #expect(panner.bedGains(code: 3)[LFE] == 1)
        #expect(panner.bedGains(code: 16)[LFE] == 1)
        #expect(panner.bedGains(code: 6)[Rls] == 1)
        #expect(panner.bedGains(code: 13)[Rtr] == 1)
        let lts = panner.bedGains(code: 10)
        #expect(abs(lts[Vhl] - sqrtf(0.5)) < 1e-5 && abs(lts[Ltr] - sqrtf(0.5)) < 1e-5)
        #expect(power(panner.bedGains(code: 14)) > 0.999)
    }
}

/// Planar test block: element e carries `values[e]` on every frame.
private final class BlockStorage {
    let samples: UnsafeMutablePointer<Float>
    let stride: Int
    init(elements: Int, frames: Int, fill: (Int, Int) -> Float) {
        stride = frames
        samples = .allocate(capacity: elements * frames)
        for e in 0..<elements { for f in 0..<frames { samples[e * frames + f] = fill(e, f) } }
    }
    deinit { samples.deallocate() }

    func block(elements: Int, roles: [ObjectElementRole], updates: [ObjectMetadataUpdate],
               pts: Int64? = nil, discontinuity: Bool = false) -> ObjectAudioBlock {
        ObjectAudioBlock(sampleRate: 48_000, frames: stride, elementCount: elements, stride: stride,
                         samples: UnsafePointer(samples), roles: roles, updates: updates, pts: pts,
                         discontinuity: discontinuity, hasObjectMetadata: true)
    }
}

@Suite("ObjectMixer gains, ramps and jumps")
struct ObjectMixerTests {
    let channels = RoomLayout.atmos714.channelCount

    private func render(_ mixer: ObjectMixer, _ block: ObjectAudioBlock) -> [[Float]] {
        let out = UnsafeMutablePointer<Float>.allocate(capacity: channels * block.frames)
        defer { out.deallocate() }
        mixer.render(block, into: out, stride: block.frames)
        return (0..<channels).map { c in Array(UnsafeBufferPointer(start: out + c * block.frames, count: block.frames)) }
    }

    private func state(_ x: Float, _ y: Float, _ z: Float, gain: Float = 1) -> ObjectElementState {
        ObjectElementState(x: x, y: y, z: z, gain: gain)
    }

    @Test("an object at front left reaches L only; a bed LFE reaches LFE only")
    func routing() {
        let mixer = ObjectMixer(layout: .atmos714)
        let storage = BlockStorage(elements: 2, frames: 40) { _, _ in 0.5 }
        let update = ObjectMetadataUpdate(offset: 0, ramp: 512, elements: [state(0.5, 0, 0), state(0, 0, 0)])
        let out = render(mixer, storage.block(elements: 2, roles: [.bed(3), .object], updates: [update]))
        #expect(out[LFE].allSatisfy { abs($0 - 0.5) < 1e-6 })
        #expect(out[L].allSatisfy { abs($0 - 0.5) < 1e-6 })
        #expect(out[R].allSatisfy { $0 == 0 } && out[Vhl].allSatisfy { $0 == 0 })
    }

    @Test("the first update after a reset applies at once, the next one ramps linearly")
    func rampAfterJump() {
        let mixer = ObjectMixer(layout: .atmos714)
        let storage = BlockStorage(elements: 1, frames: 40) { _, _ in 1 }
        let first = ObjectMetadataUpdate(offset: 0, ramp: 512, elements: [state(0, 0, 0)])
        let a = render(mixer, storage.block(elements: 1, roles: [.object], updates: [first]))
        #expect(a[L].allSatisfy { $0 == 1 })
        let second = ObjectMetadataUpdate(offset: 0, ramp: 40, elements: [state(1, 0, 0)])
        let b = render(mixer, storage.block(elements: 1, roles: [.object], updates: [second]))
        #expect(abs(b[L][0] - 1) < 1e-6)
        #expect(abs(b[L][20] - 0.5) < 1e-5)
        #expect(abs(b[R][20] - 0.5) < 1e-5)
        let c = render(mixer, storage.block(elements: 1, roles: [.object], updates: []))
        #expect(c[R].allSatisfy { abs($0 - 1) < 1e-5 } && c[L].allSatisfy { abs($0) < 1e-5 })
    }

    @Test("an update timed past the block waits for its frame")
    func lateUpdate() {
        let mixer = ObjectMixer(layout: .atmos714)
        let storage = BlockStorage(elements: 1, frames: 40) { _, _ in 1 }
        _ = render(mixer, storage.block(elements: 1, roles: [.object],
                                        updates: [ObjectMetadataUpdate(offset: 0, ramp: 0, elements: [state(0, 0, 0)])]))
        let late = ObjectMetadataUpdate(offset: 50, ramp: 0, elements: [state(1, 0, 0)])
        let b = render(mixer, storage.block(elements: 1, roles: [.object], updates: [late]))
        #expect(b[L].allSatisfy { $0 == 1 })
        let c = render(mixer, storage.block(elements: 1, roles: [.object], updates: []))
        #expect(c[L][9] == 1 && c[R][9] == 0)
        #expect(c[R][10] == 1 && c[L][10] == 0)
    }

    @Test("after a discontinuity the next update jumps instead of ramping")
    func discontinuityJumps() {
        let mixer = ObjectMixer(layout: .atmos714)
        let storage = BlockStorage(elements: 1, frames: 40) { _, _ in 1 }
        _ = render(mixer, storage.block(elements: 1, roles: [.object],
                                        updates: [ObjectMetadataUpdate(offset: 0, ramp: 0, elements: [state(0, 0, 0)])]))
        mixer.noteDiscontinuity()
        let next = ObjectMetadataUpdate(offset: 0, ramp: 2000, elements: [state(1, 0, 0)])
        let b = render(mixer, storage.block(elements: 1, roles: [.object], updates: [next]))
        #expect(b[R].allSatisfy { $0 == 1 } && b[L].allSatisfy { $0 == 0 })
    }

    @Test("object gain scales its speakers; an unknown role stays silent")
    func gainAndUnknown() {
        let mixer = ObjectMixer(layout: .atmos714)
        let storage = BlockStorage(elements: 2, frames: 40) { _, _ in 1 }
        let update = ObjectMetadataUpdate(offset: 0, ramp: 0,
                                          elements: [state(0.5, 0, 0, gain: 0.25), state(0, 0, 0)])
        let out = render(mixer, storage.block(elements: 2, roles: [.object, .unknown], updates: [update]))
        #expect(out[C].allSatisfy { abs($0 - 0.25) < 1e-6 })
        #expect(out[L].allSatisfy { $0 == 0 })
    }
}

@Suite("ObjectAudioTimeline anchors, gaps and packet stamps")
struct ObjectAudioTimelineTests {

    @Test("the first block anchors; container jitter is counted through")
    func anchorAndJitter() {
        var t = ObjectAudioTimeline()
        #expect(t.place(blockPts: 48_000, frames: 40, fallbackPts: nil) == .render)
        #expect(t.expected == 48_040)
        // Matroska rounds to the millisecond: 48_048 is 0.17 ms late, still the next unit.
        #expect(t.place(blockPts: 48_048, frames: 40, fallbackPts: nil) == .render)
        #expect(t.expected == 48_080)
    }

    @Test("a late block leaves a gap of exactly the missing frames")
    func gap() {
        var t = ObjectAudioTimeline()
        _ = t.place(blockPts: 0, frames: 40, fallbackPts: nil)
        #expect(t.place(blockPts: 40 + 4_000, frames: 40, fallbackPts: nil) == .gapThenRender(4_000))
        #expect(t.expected == 4_080)
    }

    @Test("a block entirely in the past is dropped")
    func overlap() {
        var t = ObjectAudioTimeline()
        _ = t.place(blockPts: 10_000, frames: 40, fallbackPts: nil)
        _ = t.place(blockPts: 10_040, frames: 40, fallbackPts: nil)
        #expect(t.place(blockPts: 9_000, frames: 40, fallbackPts: nil) == .drop)
        #expect(t.expected == 10_080)
    }

    @Test("packet k of a run is stamped anchor + k * 1024, priming included")
    func packetStamps() {
        var t = ObjectAudioTimeline()
        t.startRun(at: 96_000)
        #expect((0..<4).map { _ in t.nextPacketPts() } == [96_000, 97_024, 98_048, 99_072])
        t.shiftOutput(by: 480)
        #expect(t.nextPacketPts() == 96_000 + 4 * 1024 + 480)
        t.startRun(at: 0)
        #expect(t.nextPacketPts() == 480)
    }

    @Test("without block timestamps the packet time falls back once, then counts")
    func noPts() {
        var t = ObjectAudioTimeline()
        #expect(t.place(blockPts: nil, frames: 40, fallbackPts: 1_000) == .render)
        #expect(t.place(blockPts: nil, frames: 40, fallbackPts: 5_000) == .render)
        #expect(t.expected == 1_080)
    }
}

@Suite("Object audio route decision")
struct ObjectAudioRouteTests {

    @Test("only TrueHD Atmos at 48 kHz with the option on, a decoder and tvOS 26 takes the path")
    func refusals() {
        typealias E = HLSVideoEngine
        func check(_ r: ObjectAudioRendering = .apac714, codec: AVCodecID = AV_CODEC_ID_TRUEHD,
                   profile: Int32 = 30, rate: Int32 = 48_000, os: Bool = true, decoder: Bool = true)
            -> E.ObjectAudioRefusal? {
            E.objectAudioRefusal(rendering: r, codecID: codec, profile: profile, sampleRate: rate,
                                 systemSupportsAPAC: os, decoderAvailable: decoder)
        }
        #expect(check() == nil)
        #expect(check(rate: 0) == nil)
        #expect(check(.off) == .optionOff)
        #expect(check(codec: AV_CODEC_ID_DTS) == .notTrueHD)
        #expect(check(profile: -99) == .notAtmos)
        #expect(check(rate: 96_000) == .sampleRate)
        #expect(check(os: false) == .system)
        #expect(check(decoder: false) == .decoderMissing)
    }

    @Test("the option is off by default and is a correctable LoadOptions field")
    func optionDefault() {
        #expect(LoadOptions().objectAudioRendering == .off)
        var proposed = LoadOptions()
        proposed.objectAudioRendering = .apac714
        #expect(SessionOptionCorrection.refusedFields(from: LoadOptions(), to: proposed).isEmpty)
    }

    @Test("CODECS level follows the channel count")
    func codecs() {
        #expect(APACSampleEntry.codecsString(channels: 12) == "apac.31.03")
        #expect(APACSampleEntry.codecsString(channels: 2) == "apac.31.00")
        #expect(APACSampleEntry.codecsString(channels: 8) == "apac.31.02")
    }
}
