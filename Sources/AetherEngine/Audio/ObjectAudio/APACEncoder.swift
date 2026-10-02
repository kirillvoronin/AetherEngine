import Foundation
import AVFAudio

/// Planar Float32 bed in, APAC packets out, through `AVAudioConverter` (tvOS 26 / macOS 26).
///
/// Settings follow the encoder facts measured for this path: DRC off, because with DRC on the first
/// packet comes 1.5 s to over 20 s after the input; a one-packet output buffer, because `convert`
/// returns only once the buffer is full; 1024-frame packets with 2048 frames of priming.
@available(tvOS 26.0, iOS 26.0, macOS 26.0, visionOS 26.0, *)
final class APACEncoder: @unchecked Sendable {
    enum EncoderError: Error, Equatable {
        case formatUnavailable
        case converterUnavailable
        case noMagicCookie
        case convertFailed(String)
    }

    static let framesPerPacket = 1024

    let layout: RoomLayout
    let sampleRate: Double
    let bitRate: Int
    let magicCookie: Data
    let primingFrames: Int

    private let pcmFormat: AVAudioFormat
    private let apacFormat: AVAudioFormat
    private var converter: AVAudioConverter
    private let input: AVAudioPCMBuffer
    private let output: AVAudioCompressedBuffer
    private var inputQueued = false

    init(layout: RoomLayout, sampleRate: Double = 48_000, bitRatePerChannel: Int = 320_000) throws {
        self.layout = layout
        self.sampleRate = sampleRate
        self.bitRate = bitRatePerChannel * layout.channelCount
        guard let channelLayout = AVAudioChannelLayout(layoutTag: layout.channelLayoutTag) else {
            throw EncoderError.formatUnavailable
        }
        pcmFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                  interleaved: false, channelLayout: channelLayout)
        var asbd = AudioStreamBasicDescription()
        asbd.mFormatID = kAudioFormatAPAC
        asbd.mSampleRate = sampleRate
        asbd.mChannelsPerFrame = UInt32(layout.channelCount)
        guard let apac = AVAudioFormat(streamDescription: &asbd, channelLayout: channelLayout) else {
            throw EncoderError.formatUnavailable
        }
        apacFormat = apac
        converter = try Self.makeConverter(from: pcmFormat, to: apac, bitRate: bitRate)
        guard let cookie = converter.magicCookie, !cookie.isEmpty else { throw EncoderError.noMagicCookie }
        magicCookie = cookie
        primingFrames = Int(converter.primeInfo.leadingFrames)
        guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: pcmFormat,
                                                 frameCapacity: AVAudioFrameCount(Self.framesPerPacket)) else {
            throw EncoderError.formatUnavailable
        }
        input = inputBuffer
        output = AVAudioCompressedBuffer(format: converter.outputFormat, packetCapacity: 1,
                                         maximumPacketSize: max(converter.maximumOutputPacketSize, 1))
    }

    private static func makeConverter(from pcm: AVAudioFormat, to apac: AVAudioFormat,
                                      bitRate: Int) throws -> AVAudioConverter {
        guard let converter = AVAudioConverter(from: pcm, to: apac) else {
            throw EncoderError.converterUnavailable
        }
        converter.dynamicRangeControlConfiguration = .none
        converter.contentSource = .av_Spatial_Live
        converter.bitRate = bitRate
        return converter
    }

    /// Starts a fresh stream; priming comes again before the next packet with content.
    func reset() throws {
        converter = try Self.makeConverter(from: pcmFormat, to: apacFormat, bitRate: bitRate)
        inputQueued = false
    }

    /// Encodes exactly one packet's worth of frames (`framesPerPacket`) from planar `samples`.
    func encode(_ samples: UnsafePointer<Float>, stride: Int) throws -> [Data] {
        guard let planes = input.floatChannelData else { throw EncoderError.formatUnavailable }
        for c in 0..<layout.channelCount {
            planes[c].update(from: samples + c * stride, count: Self.framesPerPacket)
        }
        input.frameLength = AVAudioFrameCount(Self.framesPerPacket)
        inputQueued = true
        return try drain(endOfStream: false)
    }

    /// Ends the stream and returns what the encoder still holds.
    func finish() throws -> [Data] {
        try drain(endOfStream: true)
    }

    private func drain(endOfStream: Bool) throws -> [Data] {
        var packets: [Data] = []
        while true {
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { [self] _, outStatus in
                if inputQueued {
                    inputQueued = false
                    outStatus.pointee = .haveData
                    return input
                }
                outStatus.pointee = endOfStream ? .endOfStream : .noDataNow
                return nil
            }
            if let error { throw EncoderError.convertFailed("\(error.domain) \(error.code)") }
            if status == .error { throw EncoderError.convertFailed("status error") }
            collect(into: &packets)
            if status != .haveData { break }
        }
        return packets
    }

    private func collect(into packets: inout [Data]) {
        guard let descriptions = output.packetDescriptions else { return }
        for i in 0..<Int(output.packetCount) {
            let d = descriptions[i]
            packets.append(Data(bytes: output.data + Int(d.mStartOffset), count: Int(d.mDataByteSize)))
        }
        output.packetCount = 0
        output.byteLength = 0
    }
}
