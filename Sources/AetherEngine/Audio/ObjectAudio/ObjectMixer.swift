import Foundation
import Accelerate

/// Mixes decoded bed channels and objects into the speakers of a `RoomLayout`.
///
/// Gains are computed once per metadata update and ramped linearly over the update's ramp. The
/// first update after a reset or a discontinuity is applied at once: a ramp from silence would
/// make every object fade in after each seek.
final class ObjectMixer {
    let layout: RoomLayout
    private let panner: RoomPanner

    private struct Element {
        var current: [Float]
        var target: [Float]
        var step: [Float]
        var rampLeft = 0
        var hasGains = false
    }

    private struct Pending {
        let at: Int64
        let ramp: Int
        let element: Int
        let gains: [Float]
    }

    private var elements: [Element] = []
    private var pending: [Pending] = []
    private var roles: [ObjectElementRole] = []
    private var clock: Int64 = 0
    private var jumpNext = true

    /// Updates applied since the last reset.
    private(set) var appliedUpdates = 0

    init(layout: RoomLayout) {
        self.layout = layout
        self.panner = RoomPanner(layout: layout)
    }

    func reset() {
        elements.removeAll()
        pending.removeAll()
        roles.removeAll()
        clock = 0
        jumpNext = true
        appliedUpdates = 0
    }

    /// Lost input: the states in force are no longer known to match the audio.
    func noteDiscontinuity() {
        pending.removeAll()
        jumpNext = true
    }

    /// Number of elements that currently reach any speaker.
    var audibleElements: Int {
        elements.filter { $0.hasGains && $0.current.contains { $0 != 0 } }.count
    }

    /// Writes `block.frames` frames into `out`: channel `c` at `out + c * stride`.
    func render(_ block: ObjectAudioBlock, into out: UnsafeMutablePointer<Float>, stride: Int) {
        let channels = layout.channelCount
        let frames = block.frames
        for c in 0..<channels {
            vDSP_vclr(out + c * stride, 1, vDSP_Length(frames))
        }
        prepare(roles: block.roles, count: block.elementCount)
        schedule(block)

        var done = 0
        while done < frames {
            var segmentEnd = frames
            if let next = pending.first {
                let rel = Int(next.at - (clock + Int64(done)))
                if rel <= 0 {
                    applyDue(upTo: clock + Int64(done))
                    continue
                }
                segmentEnd = min(segmentEnd, done + rel)
            }
            for e in elements.indices where elements[e].rampLeft > 0 {
                segmentEnd = min(segmentEnd, done + elements[e].rampLeft)
            }
            mix(block, from: done, count: segmentEnd - done, into: out, stride: stride)
            done = segmentEnd
        }
        clock += Int64(frames)
    }

    /// Writes silence for `frames` frames; ramps and pending updates move on as if audio had played.
    func renderSilence(frames: Int, into out: UnsafeMutablePointer<Float>, stride: Int) {
        for c in 0..<layout.channelCount {
            vDSP_vclr(out + c * stride, 1, vDSP_Length(frames))
        }
        clock += Int64(frames)
        applyDue(upTo: clock)
        for e in elements.indices where elements[e].rampLeft > 0 {
            elements[e].rampLeft = 0
            elements[e].current = elements[e].target
        }
    }

    // MARK: - Private

    private func prepare(roles newRoles: [ObjectElementRole], count: Int) {
        let channels = layout.channelCount
        if elements.count != count {
            elements = (0..<count).map { _ in
                Element(current: .init(repeating: 0, count: channels),
                        target: .init(repeating: 0, count: channels),
                        step: .init(repeating: 0, count: channels))
            }
            pending.removeAll()
            jumpNext = true
        }
        roles = newRoles
    }

    private func schedule(_ block: ObjectAudioBlock) {
        if !block.hasObjectMetadata {
            // A channel-based stream: beds go straight to their speakers.
            for e in 0..<min(block.elementCount, roles.count) where !elements[e].hasGains {
                if case .bed(let code) = roles[e] {
                    setNow(e, gains: panner.bedGains(code: code))
                }
            }
            return
        }
        for update in block.updates {
            let at = clock + Int64(update.offset)
            for (e, state) in update.elements.prefix(block.elementCount).enumerated() {
                pending.append(Pending(at: at, ramp: update.ramp, element: e, gains: gains(for: e, state)))
            }
        }
        pending.sort { $0.at < $1.at }
    }

    private func gains(for element: Int, _ state: ObjectElementState) -> [Float] {
        let role = element < roles.count ? roles[element] : .unknown
        var g: [Float]
        switch role {
        case .bed(let code):
            g = panner.bedGains(code: code)
        case .object:
            g = panner.gains(x: state.x, y: state.y, z: state.z, size: state.size, snap: state.snap,
                             elevation: state.elevation, zone: state.zone)
        case .unknown:
            return [Float](repeating: 0, count: layout.channelCount)
        }
        if state.gain != 1 {
            for c in g.indices { g[c] *= state.gain }
        }
        return g
    }

    private func applyDue(upTo time: Int64) {
        var applied = false
        while let next = pending.first, next.at <= time {
            pending.removeFirst()
            guard next.element < elements.count else { continue }
            if jumpNext || next.ramp <= 0 || !elements[next.element].hasGains {
                setNow(next.element, gains: next.gains)
            } else {
                var el = elements[next.element]
                el.target = next.gains
                el.rampLeft = next.ramp
                for c in el.step.indices { el.step[c] = (el.target[c] - el.current[c]) / Float(next.ramp) }
                elements[next.element] = el
            }
            appliedUpdates += 1
            applied = true
        }
        if applied { jumpNext = false }
    }

    private func setNow(_ e: Int, gains: [Float]) {
        elements[e].current = gains
        elements[e].target = gains
        elements[e].rampLeft = 0
        elements[e].hasGains = true
    }

    private func mix(_ block: ObjectAudioBlock, from start: Int, count: Int,
                     into out: UnsafeMutablePointer<Float>, stride: Int) {
        guard count > 0 else { return }
        let n = vDSP_Length(count)
        for e in 0..<min(block.elementCount, elements.count) where elements[e].hasGains {
            let input = block.samples + e * block.stride + start
            if elements[e].rampLeft > 0 {
                for c in 0..<layout.channelCount {
                    var level = elements[e].current[c]
                    var step = elements[e].step[c]
                    if level == 0 && step == 0 { continue }
                    vDSP_vrampmuladd(input, 1, &level, &step, out + c * stride + start, 1, n)
                    elements[e].current[c] = level
                }
                elements[e].rampLeft -= count
                if elements[e].rampLeft <= 0 {
                    elements[e].rampLeft = 0
                    elements[e].current = elements[e].target
                }
            } else {
                for c in 0..<layout.channelCount {
                    var level = elements[e].current[c]
                    if level == 0 { continue }
                    let dst = out + c * stride + start
                    vDSP_vsma(input, 1, &level, dst, 1, dst, 1, n)
                }
            }
        }
    }
}
