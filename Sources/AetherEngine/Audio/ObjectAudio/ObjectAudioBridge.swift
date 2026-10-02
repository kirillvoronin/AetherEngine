import Foundation
import AetherLibavcodec
import AetherLibavutil

/// TrueHD Atmos objects rendered into a 7.1.4 bed and delivered as APAC in the HLS fMP4.
///
/// The muxer is given a placeholder ALAC track (movenc writes it from parameters alone and never
/// parses its packets); `sampleEntryReplacement` turns the init's entry into `apac` + `dapa`.
/// Damaged input becomes silence in place; repeated failures hand the session back to the host
/// through `onGiveUp`, once, so it can reload on the lossless bridge instead of playing silent.
@available(tvOS 26.0, iOS 26.0, macOS 26.0, visionOS 26.0, *)
final class ObjectAudioBridge: SegmentAudioBridge, @unchecked Sendable {
    static let sampleRate = 48_000

    let layout: RoomLayout
    let outputCodecID: AVCodecID = AV_CODEC_ID_ALAC
    let encoderTimeBase = AVRational(num: 1, den: Int32(ObjectAudioBridge.sampleRate))
    private(set) var encoderCodecpar: UnsafeMutablePointer<AVCodecParameters>?
    let sampleEntryReplacement: Data?
    let codecsString: String
    let bitRate: Int
    let primingFrames: Int

    /// Called once, on the pump thread, when the path keeps failing.
    var onGiveUp: (@Sendable (String) -> Void)?

    private let decoder: any ObjectAudioDecoding
    private let mixer: ObjectMixer
    private let encoder: APACEncoder
    private let srcTimeBase: AVRational
    private var timeline = ObjectAudioTimeline(framesPerPacket: APACEncoder.framesPerPacket)

    private let opLock = NSLock()
    private let capacity: Int
    private var bed: UnsafeMutablePointer<Float>
    private var filled = 0
    private var dropPrimingInRun = false
    private var drainedAtEOF = false

    private var stats = AudioBridge.FeedStats()
    private(set) var outputBytesLifetime: Int64 = 0
    private var discontinuities = 0
    private var gapFrames: Int64 = 0
    private var encoderFailures = 0
    private var gaveUp = false
    private var workSeconds: Double = 0
    private var reportedAtFrames: Int64 = 0
    private var renderedFrames: Int64 = 0

    enum BridgeError: Error, CustomStringConvertible {
        case codecparAllocFailed
        case sampleEntry
        var description: String {
            switch self {
            case .codecparAllocFailed: return "ObjectAudioBridge: placeholder codecpar alloc failed"
            case .sampleEntry: return "ObjectAudioBridge: encoder cookie is not a dapa box"
            }
        }
    }

    init(decoder: any ObjectAudioDecoding, srcTimeBase: AVRational, layout: RoomLayout = .atmos714,
         bitRatePerChannel: Int = 320_000) throws {
        self.decoder = decoder
        self.srcTimeBase = srcTimeBase
        self.layout = layout
        self.mixer = ObjectMixer(layout: layout)
        self.encoder = try APACEncoder(layout: layout, sampleRate: Double(Self.sampleRate),
                                       bitRatePerChannel: bitRatePerChannel)
        self.bitRate = encoder.bitRate
        self.primingFrames = encoder.primingFrames
        guard let entry = APACSampleEntry.make(dapaBox: encoder.magicCookie, sampleRate: Self.sampleRate) else {
            throw BridgeError.sampleEntry
        }
        self.sampleEntryReplacement = entry
        self.codecsString = APACSampleEntry.codecsString(channels: layout.channelCount)
        // One packet plus the largest block and a gap chunk fit without reallocating.
        self.capacity = APACEncoder.framesPerPacket * 4
        self.bed = .allocate(capacity: capacity * layout.channelCount)
        self.bed.initialize(repeating: 0, count: capacity * layout.channelCount)
        guard let cp = Self.makePlaceholderCodecpar() else {
            bed.deallocate()
            throw BridgeError.codecparAllocFailed
        }
        self.encoderCodecpar = cp
    }

    deinit {
        bed.deallocate()
        if encoderCodecpar != nil { avcodec_parameters_free(&encoderCodecpar) }
    }

    /// ALAC 2 ch / 48 kHz / 1024 frames with a valid `alac` config, so movenc writes a sample entry.
    static func makePlaceholderCodecpar() -> UnsafeMutablePointer<AVCodecParameters>? {
        guard let cp = avcodec_parameters_alloc() else { return nil }
        cp.pointee.codec_type = AVMEDIA_TYPE_AUDIO
        cp.pointee.codec_id = AV_CODEC_ID_ALAC
        cp.pointee.sample_rate = Int32(sampleRate)
        cp.pointee.frame_size = Int32(APACEncoder.framesPerPacket)
        cp.pointee.bits_per_coded_sample = 16
        av_channel_layout_default(&cp.pointee.ch_layout, 2)
        var config: [UInt8] = [0, 0, 0, 36] + Array("alac".utf8) + [0, 0, 0, 0]
        config += [0, 0, 4, 0, 0, 16, 40, 10, 14, 2, 0, 255, 0, 0, 0, 0, 0, 0, 0, 0]
        config += [0, 0, 0xBB, 0x80]
        let padded = config.count + Int(AV_INPUT_BUFFER_PADDING_SIZE)
        guard let extradata = av_mallocz(padded)?.assumingMemoryBound(to: UInt8.self) else {
            var p: UnsafeMutablePointer<AVCodecParameters>? = cp
            avcodec_parameters_free(&p)
            return nil
        }
        extradata.update(from: config, count: config.count)
        cp.pointee.extradata = extradata
        cp.pointee.extradata_size = Int32(config.count)
        return cp
    }

    // MARK: - SegmentAudioBridge

    var feedStats: AudioBridge.FeedStats { stats }

    var fifoSampleCount: Int { filled }

    var liveBytes: AudioBridge.LiveBytes {
        AudioBridge.LiveBytes(fifoSamples: filled, fifoBytes: filled * layout.channelCount * 4,
                              swrDelaySamples: 0, swrDelayBytes: 0)
    }

    func feed(packet: UnsafePointer<AVPacket>) throws -> [UnsafeMutablePointer<AVPacket>] {
        opLock.lock()
        defer { opLock.unlock() }
        guard !gaveUp, let data = packet.pointee.data, packet.pointee.size > 0 else { return [] }
        let started = Date()
        stats.packetsFed += 1
        stats.packetsFedSinceLastEnqueue += 1
        let pts = packet.pointee.pts == Self.noPTS
            ? nil : av_rescale_q(packet.pointee.pts, srcTimeBase, encoderTimeBase)
        var results: [UnsafeMutablePointer<AVPacket>] = []
        do {
            try decoder.push(UnsafeRawBufferPointer(start: data, count: Int(packet.pointee.size)), pts: pts)
            while let block = try decoder.nextBlock() {
                handle(block, fallbackPts: pts, results: &results)
            }
        } catch {
            stats.decodeErrors += 1
            noteFailure("decoder: \(error)")
            decoder.reset()
            mixer.noteDiscontinuity()
        }
        workSeconds += Date().timeIntervalSince(started)
        reportIfDue()
        return results
    }

    func flush() -> [UnsafeMutablePointer<AVPacket>] {
        opLock.lock()
        defer { opLock.unlock() }
        guard !drainedAtEOF, !gaveUp else { return [] }
        drainedAtEOF = true
        var results: [UnsafeMutablePointer<AVPacket>] = []
        if filled > 0 {
            appendSilence(APACEncoder.framesPerPacket - filled % APACEncoder.framesPerPacket)
            encodeFullPackets(results: &results)
        }
        do {
            emit(try encoder.finish(), results: &results)
        } catch {
            stats.encodeErrors += 1
        }
        EngineLog.emit("[ObjectAudio] EOF flush emitted \(results.count) packet(s)", category: .session)
        return results
    }

    func startSegment() {
        opLock.lock()
        defer { opLock.unlock() }
        decoder.reset()
        mixer.reset()
        filled = 0
        timeline.reset()
        dropPrimingInRun = false
        do {
            try encoder.reset()
            drainedAtEOF = false
        } catch {
            stats.encodeErrors += 1
            noteFailure("encoder restart: \(error)")
        }
    }

    func noteTimelineJump(deltaSeconds: Double) {
        opLock.lock()
        defer { opLock.unlock() }
        guard deltaSeconds > 0 else { return }
        timeline.shiftOutput(by: Int64((deltaSeconds * Double(Self.sampleRate)).rounded()))
    }

    func close() {
        opLock.lock()
        defer { opLock.unlock() }
        filled = 0
    }

    // MARK: - Pipeline

    private static let noPTS: Int64 = -0x7FFF_FFFF_FFFF_FFFF - 1

    private func handle(_ block: ObjectAudioBlock, fallbackPts: Int64?,
                        results: inout [UnsafeMutablePointer<AVPacket>]) {
        stats.framesDecoded += 1
        guard block.sampleRate == Self.sampleRate, block.frames > 0 else {
            noteFailure("unsupported block: \(block.sampleRate) Hz, \(block.frames) frames")
            return
        }
        let placement = timeline.place(blockPts: block.pts, frames: block.frames, fallbackPts: fallbackPts)
        if !timeline.hasRun, let expected = timeline.expected {
            timeline.startRun(at: expected - Int64(block.frames))
        }
        switch placement {
        case .drop:
            return
        case .gapThenRender(let gap):
            discontinuities += 1
            gapFrames += Int64(gap)
            mixer.noteDiscontinuity()
            fillGap(gap, results: &results)
        case .render:
            if block.discontinuity {
                discontinuities += 1
                mixer.noteDiscontinuity()
            }
        }
        if filled + block.frames > capacity { encodeFullPackets(results: &results) }
        mixer.render(block, into: bed + filled, stride: capacity)
        filled += block.frames
        renderedFrames += Int64(block.frames)
        stats.samplesEnqueued += Int64(block.frames)
        stats.packetsFedSinceLastEnqueue = 0
        encodeFullPackets(results: &results)
    }

    private func fillGap(_ frames: Int, results: inout [UnsafeMutablePointer<AVPacket>]) {
        var left = frames
        while left > 0 {
            let room = capacity - filled
            let chunk = min(left, room)
            appendSilence(chunk)
            left -= chunk
            encodeFullPackets(results: &results)
        }
    }

    private func appendSilence(_ frames: Int) {
        guard frames > 0 else { return }
        mixer.renderSilence(frames: frames, into: bed + filled, stride: capacity)
        filled += frames
    }

    private func encodeFullPackets(results: inout [UnsafeMutablePointer<AVPacket>]) {
        let packet = APACEncoder.framesPerPacket
        while filled >= packet {
            do {
                emit(try encoder.encode(bed, stride: capacity), results: &results)
            } catch {
                stats.encodeErrors += 1
                encoderFailures += 1
                restartEncoderAfterFailure(lostFrames: packet, reason: "\(error)")
            }
            for c in 0..<layout.channelCount {
                let lane = bed + c * capacity
                lane.update(from: lane + packet, count: filled - packet)
            }
            filled -= packet
        }
    }

    /// The new run starts where the next unencoded frame sits; its priming would overlap audio
    /// already sent, so those packets are dropped.
    private func restartEncoderAfterFailure(lostFrames: Int, reason: String) {
        noteFailure("encoder: \(reason)")
        do {
            try encoder.reset()
        } catch {
            noteFailure("encoder reset: \(error)")
            return
        }
        if let expected = timeline.expected {
            timeline.startRun(at: expected - Int64(filled) + Int64(lostFrames))
        }
        dropPrimingInRun = true
    }

    private func emit(_ packets: [Data], results: inout [UnsafeMutablePointer<AVPacket>]) {
        for bytes in packets {
            let primingPackets = Int64(primingFrames / APACEncoder.framesPerPacket)
            let isPriming = timeline.packetIndex < primingPackets
            let pts = timeline.nextPacketPts()
            if isPriming && dropPrimingInRun { continue }
            guard let pkt = av_packet_alloc() else { continue }
            guard av_new_packet(pkt, Int32(bytes.count)) >= 0, let dst = pkt.pointee.data else {
                var p: UnsafeMutablePointer<AVPacket>? = pkt
                av_packet_free(&p)
                continue
            }
            bytes.copyBytes(to: dst, count: bytes.count)
            pkt.pointee.pts = pts
            pkt.pointee.dts = pts
            pkt.pointee.duration = Int64(APACEncoder.framesPerPacket)
            pkt.pointee.flags |= AV_PKT_FLAG_KEY
            outputBytesLifetime += Int64(bytes.count)
            stats.packetsEmitted += 1
            results.append(pkt)
        }
    }

    // MARK: - Failure policy and journal

    private static let giveUpDiscontinuities = 40
    private static let giveUpEncoderFailures = 3

    private func noteFailure(_ reason: String) {
        EngineLog.emit("[ObjectAudio] \(reason)", category: .session)
        let decoderErrors = Int(decoder.stats.errors)
        guard !gaveUp,
              encoderFailures >= Self.giveUpEncoderFailures
                || decoderErrors + discontinuities >= Self.giveUpDiscontinuities
                || reason.hasPrefix("unsupported")
        else { return }
        gaveUp = true
        EngineLog.emit(
            "[ObjectAudio] giving up after \(encoderFailures) encoder failure(s), \(decoderErrors) decoder "
            + "error(s), \(discontinuities) discontinuities; asking for the lossless bridge",
            category: .session
        )
        onGiveUp?(reason)
    }

    private func reportIfDue() {
        let interval = Int64(Self.sampleRate * 30)
        guard renderedFrames - reportedAtFrames >= interval else { return }
        let audioSeconds = Double(renderedFrames - reportedAtFrames) / Double(Self.sampleRate)
        let speed = workSeconds > 0 ? audioSeconds / workSeconds : 0
        EngineLog.emit(
            "[ObjectAudio] \(String(format: "%.0f", speed))x real time, audible elements "
            + "\(mixer.audibleElements), decoder errors \(decoder.stats.errors), discontinuities "
            + "\(discontinuities) (\(gapFrames) silent frames), encoder failures \(encoderFailures)",
            category: .session
        )
        reportedAtFrames = renderedFrames
        workSeconds = 0
    }
}
