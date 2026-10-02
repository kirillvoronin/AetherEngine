import Foundation
#if canImport(TrueHDObjectsC)
import TrueHDObjectsC
#endif

#if canImport(TrueHDObjectsC)
/// `ObjectAudioDecoding` over the TrueHDObjects C API (the `truehd` crate).
final class TrueHDObjectsDecoder: ObjectAudioDecoding {
    private let stream: OpaquePointer

    init() throws {
        guard let created = tho_create() else { throw ObjectAudioDecoderError.unavailable }
        stream = created
    }

    deinit {
        tho_destroy(stream)
    }

    static var version: String { String(cString: tho_version()) }

    func push(_ bytes: UnsafeRawBufferPointer, pts: Int64?) throws {
        guard let base = bytes.bindMemory(to: UInt8.self).baseAddress, !bytes.isEmpty else { return }
        let rc = tho_push(stream, base, bytes.count, pts ?? Int64.min)
        if rc < 0 { throw ObjectAudioDecoderError.failed(code: rc) }
    }

    func nextBlock() throws -> ObjectAudioBlock? {
        var block = THOBlock()
        let rc = tho_pull(stream, &block)
        if rc < 0 { throw ObjectAudioDecoderError.failed(code: rc) }
        guard rc == THO_BLOCK, let samples = block.samples, let rolesPtr = block.roles else { return nil }
        let count = Int(block.element_count)
        let roles = (0..<count).map { ObjectElementRole(code: rolesPtr[$0]) }
        var updates: [ObjectMetadataUpdate] = []
        if let raw = block.updates {
            updates.reserveCapacity(Int(block.update_count))
            for u in 0..<Int(block.update_count) {
                let update = raw[u]
                var elements: [ObjectElementState] = []
                if let states = update.elements {
                    elements.reserveCapacity(Int(update.element_count))
                    for e in 0..<Int(update.element_count) {
                        let s = states[e]
                        elements.append(ObjectElementState(
                            x: s.x, y: s.y, z: s.z, gain: s.gain, size: s.size,
                            snap: s.snap != 0, elevation: s.elevation != 0, zone: s.zone))
                    }
                }
                updates.append(ObjectMetadataUpdate(offset: Int(update.offset), ramp: Int(update.ramp),
                                                    elements: elements))
            }
        }
        return ObjectAudioBlock(
            sampleRate: Int(block.sample_rate),
            frames: Int(block.frame_count),
            elementCount: count,
            stride: Int(block.sample_stride),
            samples: samples,
            roles: roles,
            updates: updates,
            pts: block.pts == Int64.min ? nil : block.pts,
            discontinuity: block.discontinuity != 0,
            hasObjectMetadata: block.has_object_metadata != 0)
    }

    func reset() {
        _ = tho_reset(stream)
    }

    var stats: ObjectAudioDecoderStats {
        var s = THOStats()
        _ = tho_stats(stream, &s)
        return ObjectAudioDecoderStats(blocks: s.blocks,
                                       errors: s.extract_errors + s.parse_errors + s.decode_errors)
    }
}
#endif
