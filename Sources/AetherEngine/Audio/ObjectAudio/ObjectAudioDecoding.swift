import Foundation

/// One object state reached at `offset` frames after a block's first frame, over `ramp` frames.
struct ObjectElementState: Equatable, Sendable {
    /// Room cube: x 0 left..1 right, y 0 front..1 back, z 0 ear level..1 ceiling.
    var x: Float
    var y: Float
    var z: Float
    /// Linear; 0 when the element is inactive.
    var gain: Float
    var size: Float = 0
    var snap: Bool = false
    var elevation: Bool = true
    var zone: UInt8 = 0
}

struct ObjectMetadataUpdate: Equatable, Sendable {
    var offset: Int
    var ramp: Int
    var elements: [ObjectElementState]
}

enum ObjectElementRole: Equatable, Sendable {
    /// OAMD bed speaker code (L R C LFE Lss Rss Lrs Rrs Lfh Rfh Lts Rts Lrh Rrh Lw Rw LFE2).
    case bed(UInt8)
    case object
    case unknown

    init(code: UInt8) {
        switch code {
        case 0...16: self = .bed(code)
        case 0xFE: self = .object
        default: self = .unknown
        }
    }
}

/// A decoded access unit. `samples` is planar with `stride` between elements and is valid only
/// until the decoder is called again.
struct ObjectAudioBlock {
    var sampleRate: Int
    var frames: Int
    var elementCount: Int
    var stride: Int
    var samples: UnsafePointer<Float>
    var roles: [ObjectElementRole]
    var updates: [ObjectMetadataUpdate]
    /// Caller timeline in frames, from the pts given to `push`; nil when unknown.
    var pts: Int64?
    var discontinuity: Bool
    var hasObjectMetadata: Bool
}

struct ObjectAudioDecoderStats: Equatable, Sendable {
    var blocks: UInt64 = 0
    var errors: UInt64 = 0
}

/// Compressed object audio in, one access unit at a time out. A protocol so the bridge can be
/// driven by a synthetic decoder in tests.
protocol ObjectAudioDecoding: AnyObject {
    /// `pts`: the caller's time of the first byte, in frames at the stream rate.
    func push(_ bytes: UnsafeRawBufferPointer, pts: Int64?) throws
    func nextBlock() throws -> ObjectAudioBlock?
    func reset()
    var stats: ObjectAudioDecoderStats { get }
}

enum ObjectAudioDecoderError: Error, Equatable {
    case unavailable
    case failed(code: Int32)
}
