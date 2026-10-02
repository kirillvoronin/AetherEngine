import Foundation

/// Where decoded audio and encoded packets sit on the output timeline (frames at the stream rate).
///
/// Input: each decoded block brings the time of its source packet. The first block after a reset
/// anchors the timeline; later blocks are counted forward, so millisecond-rounded container
/// timestamps (Matroska) cannot jitter it. A block that starts clearly later than expected leaves a
/// gap the bridge fills with silence, so everything after it stays on its own time.
///
/// Output: AVFoundation presents an APAC packet `priming` frames before its timestamp, because it
/// discards the encoder's priming itself. So packet k of an encoder run is stamped
/// `anchor + k * framesPerPacket`, where the anchor is the time of the run's first input frame:
/// priming packets keep their place and content lands on its source time.
struct ObjectAudioTimeline: Equatable {
    enum Placement: Equatable {
        case render
        /// Silence of this many frames comes first.
        case gapThenRender(Int)
        /// The block repeats time already rendered.
        case drop
    }

    let framesPerPacket: Int
    /// Smaller differences are container rounding, not lost audio.
    let tolerance: Int

    /// Input position of the next frame the mixer renders; nil until a block anchors it.
    private(set) var expected: Int64?
    /// Input position of the first frame of the current encoder run.
    private(set) var runAnchor: Int64?
    /// Packets emitted in the current encoder run, priming included.
    private(set) var packetIndex: Int64 = 0
    /// Added to every packet timestamp: live timeline jumps.
    private(set) var outputShift: Int64 = 0

    init(framesPerPacket: Int = 1024, tolerance: Int = 120) {
        self.framesPerPacket = framesPerPacket
        self.tolerance = tolerance
    }

    mutating func reset() {
        expected = nil
        runAnchor = nil
        packetIndex = 0
    }

    mutating func place(blockPts: Int64?, frames: Int, fallbackPts: Int64?) -> Placement {
        guard let current = expected else {
            expected = (blockPts ?? fallbackPts ?? 0) + Int64(frames)
            return .render
        }
        guard let pts = blockPts else {
            expected = current + Int64(frames)
            return .render
        }
        let difference = pts - current
        if difference > Int64(tolerance) {
            expected = pts + Int64(frames)
            return .gapThenRender(Int(difference))
        }
        if difference < -Int64(tolerance) && difference + Int64(frames) <= 0 {
            return .drop
        }
        expected = current + Int64(frames)
        return .render
    }

    /// Input position where the first anchored block started, for the first encoder run.
    mutating func startRun(at inputPosition: Int64) {
        runAnchor = inputPosition
        packetIndex = 0
    }

    var hasRun: Bool { runAnchor != nil }

    /// Timestamp for the next packet of the run, then advances.
    mutating func nextPacketPts() -> Int64 {
        let pts = (runAnchor ?? 0) + packetIndex * Int64(framesPerPacket) + outputShift
        packetIndex += 1
        return pts
    }

    mutating func shiftOutput(by frames: Int64) {
        outputShift += frames
    }
}
