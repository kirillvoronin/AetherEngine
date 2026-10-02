import AVFoundation
import Foundation
import Synchronization
import Testing
import AetherLibavcodec
import AetherLibavformat
import AetherLibavutil
@testable import AetherEngine

// TVSeerr fork: the APAC half of the object audio path, checked against AVFoundation itself.

/// One 40-frame block per push, element 0 an object at the centre: silence, then a 1 kHz burst.
private final class SyntheticDecoder: ObjectAudioDecoding {
    let burstStart: Int64
    let burstFrames: Int64 = 9_600
    private var queue: [Int64?] = []
    private let buffer = UnsafeMutablePointer<Float>.allocate(capacity: 40)
    private var sentMetadata = false
    private(set) var resets = 0
    var stats = ObjectAudioDecoderStats()

    init(burstStart: Int64) { self.burstStart = burstStart }
    deinit { buffer.deallocate() }

    func push(_ bytes: UnsafeRawBufferPointer, pts: Int64?) throws { queue.append(pts) }

    func nextBlock() throws -> ObjectAudioBlock? {
        guard !queue.isEmpty else { return nil }
        let pts = queue.removeFirst() ?? 0
        for i in 0..<40 {
            let t = pts + Int64(i)
            let inBurst = t >= burstStart && t < burstStart + burstFrames
            buffer[i] = inBurst ? 0.5 * sinf(Float(t - burstStart) * 2 * .pi * 1000 / 48_000) : 0
        }
        let updates = sentMetadata ? [] : [ObjectMetadataUpdate(
            offset: 0, ramp: 0, elements: [ObjectElementState(x: 0.5, y: 0, z: 0, gain: 1)])]
        sentMetadata = true
        stats.blocks += 1
        return ObjectAudioBlock(sampleRate: 48_000, frames: 40, elementCount: 1, stride: 40,
                                samples: UnsafePointer(buffer), roles: [.object], updates: updates,
                                pts: pts, discontinuity: false, hasObjectMetadata: true)
    }

    func reset() {
        queue.removeAll()
        sentMetadata = false
        resets += 1
    }
}

@available(macOS 26.0, *)
private func feed(_ bridge: ObjectAudioBridge, units: Range<Int64>, skipping: Set<Int64> = []) throws -> [UnsafeMutablePointer<AVPacket>] {
    var out: [UnsafeMutablePointer<AVPacket>] = []
    var byte: UInt8 = 0
    for unit in units where !skipping.contains(unit) {
        guard let pkt = av_packet_alloc() else { continue }
        defer { var p: UnsafeMutablePointer<AVPacket>? = pkt; av_packet_free(&p) }
        _ = av_new_packet(pkt, 1)
        pkt.pointee.data?.pointee = byte
        byte &+= 1
        pkt.pointee.pts = unit * 40
        out += try bridge.feed(packet: pkt)
    }
    return out
}

private func free(_ packets: [UnsafeMutablePointer<AVPacket>]) {
    for p in packets { var q: UnsafeMutablePointer<AVPacket>? = p; av_packet_free(&q) }
}

/// Audio-only fragmented MP4 the way the segment muxer writes it, placeholder entry swapped.
@available(macOS 26.0, *)
private func muxFragmentedMP4(_ bridge: ObjectAudioBridge, packets: [UnsafeMutablePointer<AVPacket>]) throws -> Data {
    var ctxOut: UnsafeMutablePointer<AVFormatContext>?
    guard avformat_alloc_output_context2(&ctxOut, nil, "mp4", "t.mp4") == 0, let ctx = ctxOut else {
        throw CancellationError()
    }
    defer { avformat_free_context(ctx) }
    var pb: UnsafeMutablePointer<AVIOContext>?
    guard avio_open_dyn_buf(&pb) >= 0, let pbCtx = pb else { throw CancellationError() }
    ctx.pointee.pb = pbCtx
    guard let stream = avformat_new_stream(ctx, nil), let cp = bridge.encoderCodecpar else { throw CancellationError() }
    _ = avcodec_parameters_copy(stream.pointee.codecpar, cp)
    stream.pointee.time_base = bridge.encoderTimeBase
    var opts: OpaquePointer?
    av_dict_set(&opts, "movflags", "+empty_moov+default_base_moof+frag_custom+delay_moov+frag_discont", 0)
    let header = avformat_write_header(ctx, &opts)
    av_dict_free(&opts)
    #expect(header >= 0)
    for (i, p) in packets.enumerated() {
        p.pointee.stream_index = 0
        av_packet_rescale_ts(p, bridge.encoderTimeBase, stream.pointee.time_base)
        _ = av_write_frame(ctx, p)
        if i % 47 == 46 { _ = av_write_frame(ctx, nil) }
    }
    _ = av_write_frame(ctx, nil)
    _ = av_write_trailer(ctx)
    var buf: UnsafeMutablePointer<UInt8>?
    let size = avio_close_dyn_buf(pbCtx, &buf)
    defer { av_free(buf) }
    guard let buf, size > 0 else { throw CancellationError() }
    let raw = Data(bytes: buf, count: Int(size))
    guard let entry = bridge.sampleEntryReplacement,
          let patched = InitSampleEntryPatch.replacingAudioSampleEntry(in: raw, with: entry) else {
        throw CancellationError()
    }
    return patched
}

/// Presentation time (seconds) where the decoded centre channel first exceeds `threshold`.
@available(macOS 26.0, *)
private func firstLoudTime(in file: URL, threshold: Float) async throws -> (onset: Double?, channels: Int) {
    let asset = AVURLAsset(url: file)
    guard let track = try await asset.loadTracks(withMediaType: .audio).first else { return (nil, 0) }
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
        AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
        AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false,
    ])
    reader.add(output)
    guard reader.startReading() else { throw reader.error ?? CancellationError() }
    var channels = 0
    while let sample = output.copyNextSampleBuffer() {
        let start = CMSampleBufferGetPresentationTimeStamp(sample).seconds
        guard let desc = CMSampleBufferGetFormatDescription(sample),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc)?.pointee,
              let block = CMSampleBufferGetDataBuffer(sample) else { continue }
        channels = Int(asbd.mChannelsPerFrame)
        var length = 0
        var pointer: UnsafeMutablePointer<Int8>?
        CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &pointer)
        guard let pointer else { continue }
        let floats = UnsafeRawPointer(pointer).assumingMemoryBound(to: Float.self)
        let frames = length / 4 / channels
        for f in 0..<frames {
            var peak: Float = 0
            for c in 0..<channels { peak = max(peak, abs(floats[f * channels + c])) }
            if peak > threshold { return (start + Double(f) / asbd.mSampleRate, channels) }
        }
    }
    return (nil, channels)
}

@Suite("APAC encoder and object audio bridge (macOS 26)", .enabled(if: {
    if #available(macOS 26.0, *) { return true } else { return false }
}()))
struct ObjectAudioAPACTests {

    @Test("encoder facts this path relies on: 1024-frame packets, 2048 priming, dapa cookie, first packet within one packet of input")
    func encoderFacts() throws {
        guard #available(macOS 26.0, *) else { return }
        let encoder = try APACEncoder(layout: .atmos714)
        #expect(encoder.primingFrames == 2048)
        #expect(String(decoding: encoder.magicCookie[4..<8], as: UTF8.self) == "dapa")
        let silence = [Float](repeating: 0, count: 12 * 1024)
        let first = try silence.withUnsafeBufferPointer { try encoder.encode($0.baseAddress!, stride: 1024) }
        let second = try silence.withUnsafeBufferPointer { try encoder.encode($0.baseAddress!, stride: 1024) }
        #expect(first.count + second.count >= 1, "DRC is off, so packets come right away")
        let tail = try encoder.finish()
        #expect(first.count + second.count + tail.count == 4, "two content packets plus two of priming")
    }

    @Test("the sample entry swap yields an apac entry with its dapa and consistent box sizes")
    func sampleEntrySwap() throws {
        guard #available(macOS 26.0, *) else { return }
        let bridge = try ObjectAudioBridge(decoder: SyntheticDecoder(burstStart: .max),
                                           srcTimeBase: AVRational(num: 1, den: 48_000))
        let packets = try feed(bridge, units: 0..<200)
        let file = try muxFragmentedMP4(bridge, packets: packets)
        free(packets)
        let bytes = [UInt8](file)
        var offset = 0
        while let box = InitSampleEntryPatch.box(at: offset, in: bytes, limit: bytes.count) { offset = box.range.upperBound }
        #expect(offset == bytes.count, "top-level boxes tile the file")
        let moov = try #require(InitSampleEntryPatch.child(of: bytes, in: 0..<bytes.count, type: "moov"))
        let trak = try #require(InitSampleEntryPatch.child(of: bytes, in: moov.payload, type: "trak"))
        let mdia = try #require(InitSampleEntryPatch.child(of: bytes, in: trak.payload, type: "mdia"))
        let minf = try #require(InitSampleEntryPatch.child(of: bytes, in: mdia.payload, type: "minf"))
        let stbl = try #require(InitSampleEntryPatch.child(of: bytes, in: minf.payload, type: "stbl"))
        let stsd = try #require(InitSampleEntryPatch.child(of: bytes, in: stbl.payload, type: "stsd"))
        let entry = try #require(InitSampleEntryPatch.box(at: stsd.payload.lowerBound + 8, in: bytes, limit: stsd.payload.upperBound))
        #expect(entry.type == "apac")
        let dapa = InitSampleEntryPatch.box(at: entry.payload.lowerBound + 28, in: bytes, limit: entry.range.upperBound)
        #expect(dapa?.type == "dapa")
        #expect(InitSampleEntryPatch.replacingAudioSampleEntry(in: Data([0, 0, 0, 8] + Array("free".utf8)), with: Data()) == nil)
    }

    @Test("packets of one run are stamped back to back from the anchor; a gap is filled, not skipped")
    func packetTimeline() throws {
        guard #available(macOS 26.0, *) else { return }
        let bridge = try ObjectAudioBridge(decoder: SyntheticDecoder(burstStart: .max),
                                           srcTimeBase: AVRational(num: 1, den: 48_000))
        let packets = try feed(bridge, units: 100..<400, skipping: Set(200..<230))
        defer { free(packets) }
        let pts = packets.map(\.pointee.pts)
        #expect(pts.first == 4_000)
        #expect(zip(pts, pts.dropFirst()).allSatisfy { $1 - $0 == 1024 })
        // 300 units fed, 30 lost and filled: 12 000 frames of input, minus what the encoder still holds.
        #expect(packets.count >= 9 && packets.count <= 12)
        bridge.startSegment()
        let after = try feed(bridge, units: 2_000..<2_100)
        defer { free(after) }
        #expect(after.first?.pointee.pts == 80_000, "a restart re-anchors at the new source time")
    }

    @Test("AVFoundation plays a burst at its source time: priming kept, packets stamped from the anchor")
    func avFoundationSync() async throws {
        guard #available(macOS 26.0, *) else { return }
        let burst: Int64 = 48_000
        let bridge = try ObjectAudioBridge(decoder: SyntheticDecoder(burstStart: burst),
                                           srcTimeBase: AVRational(num: 1, den: 48_000))
        var packets = try feed(bridge, units: 0..<3_600)
        packets += bridge.flush()
        let file = try muxFragmentedMP4(bridge, packets: packets)
        free(packets)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("apac-sync-\(UUID()).mp4")
        try file.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let (onset, channels) = try await firstLoudTime(in: url, threshold: 0.05)
        #expect(channels == 12)
        let measured = try #require(onset)
        let errorMs = (measured - Double(burst) / 48_000) * 1000
        #expect(abs(errorMs) < 2, "burst at \(measured) s, \(String(format: "%.2f", errorMs)) ms off")
    }

    /// Runs only when `THO_SAMPLE` names a local raw TrueHD Atmos file (`.thd`, 48 kHz).
    @Test("a real TrueHD Atmos stream renders and encodes faster than real time",
          .enabled(if: ProcessInfo.processInfo.environment["THO_SAMPLE"] != nil))
    func realStream() throws {
        guard #available(macOS 26.0, *),
              let path = ProcessInfo.processInfo.environment["THO_SAMPLE"] else { return }
        let decoder = try #require(try HLSVideoEngine.makeObjectDecoder())
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let bridge = try ObjectAudioBridge(decoder: decoder,
                                           srcTimeBase: AVRational(num: 1, den: 48_000))
        let gaveUp = Mutex(false)
        bridge.onGiveUp = { _ in gaveUp.withLock { $0 = true } }
        let bytes = [UInt8](data.prefix(20_000_000))
        var offset = 0, unit: Int64 = 0, emitted = 0
        let started = Date()
        guard let pkt = av_packet_alloc() else { return }
        defer { var p: UnsafeMutablePointer<AVPacket>? = pkt; av_packet_free(&p) }
        while offset + 2 <= bytes.count {
            let length = Int((UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1])) & 0xFFF) << 1
            guard length > 0, offset + length <= bytes.count else { break }
            av_packet_unref(pkt)
            _ = av_new_packet(pkt, Int32(length))
            bytes.withUnsafeBufferPointer { pkt.pointee.data?.update(from: $0.baseAddress! + offset, count: length) }
            pkt.pointee.pts = unit * 40
            let out = try bridge.feed(packet: pkt)
            emitted += out.count
            free(out)
            offset += length
            unit += 1
        }
        let seconds = Double(unit * 40) / 48_000
        let speed = seconds / Date().timeIntervalSince(started)
        #expect(!gaveUp.withLock { $0 })
        #expect(bridge.feedStats.framesDecoded > 0)
        #expect(Double(emitted) > seconds * 46, "packets: \(emitted) for \(seconds) s")
        #expect(speed > 3, "\(String(format: "%.1f", speed))x real time")
        print("[ObjectAudio test] \(String(format: "%.1f", seconds)) s of TrueHD Atmos at \(String(format: "%.1f", speed))x real time, \(emitted) APAC packets")
    }
}
