import Foundation
import AetherLibavcodec
import AetherLibavutil

/// What the HLS producer needs from an audio bridge: source packets in, encoded packets out, and the
/// segment lifecycle around them. `AudioBridge` (FLAC / E-AC-3) and `ObjectAudioBridge` (TrueHD Atmos
/// objects rendered to 7.1.4 APAC) both serve the same producer through it.
protocol SegmentAudioBridge: AnyObject, Sendable {
    /// Parameters of the track the muxer writes. Owned by the bridge.
    var encoderCodecpar: UnsafeMutablePointer<AVCodecParameters>? { get }
    /// Time base of the packets `feed` and `flush` return.
    var encoderTimeBase: AVRational { get }
    var outputCodecID: AVCodecID { get }
    /// A finished sample entry (`stsd` child) that replaces the one movenc writes for the audio
    /// track, for a codec movenc cannot describe. Nil keeps movenc's own.
    var sampleEntryReplacement: Data? { get }
    var feedStats: AudioBridge.FeedStats { get }
    var liveBytes: AudioBridge.LiveBytes { get }
    var outputBytesLifetime: Int64 { get }
    var fifoSampleCount: Int { get }

    func feed(packet: UnsafePointer<AVPacket>) throws -> [UnsafeMutablePointer<AVPacket>]
    func flush() -> [UnsafeMutablePointer<AVPacket>]
    func startSegment()
    func noteTimelineJump(deltaSeconds: Double)
    func close()
}

extension AudioBridge: SegmentAudioBridge {
    var sampleEntryReplacement: Data? { nil }
}
