// Measures the APAC encoder behind AVAudioConverter: packet size, priming,
// latency to the first packet per DRC setting, bitrate, sync packets, cookie.
// Run: swiftc -O main.swift -o apacprobe && ./apacprobe [interleaved-f32-12ch.raw]
import AVFAudio
import AudioToolbox
import Foundation

setvbuf(stdout, nil, _IONBF, 0)
let rate = 48_000.0
let channels: AVAudioChannelCount = 12

func pcmFormat() -> AVAudioFormat {
    let layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_Atmos_7_1_4)!
    return AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, interleaved: false, channelLayout: layout)
}

func apacFormat() -> AVAudioFormat {
    var asbd = AudioStreamBasicDescription()
    asbd.mFormatID = kAudioFormatAPAC
    asbd.mSampleRate = rate
    asbd.mChannelsPerFrame = channels
    let layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_Atmos_7_1_4)!
    return AVAudioFormat(streamDescription: &asbd, channelLayout: layout)!
}

struct Source {
    let frames: [[Float]]
    var cursor = 0
    init(file: String?, seconds: Double) {
        let count = Int(rate * seconds)
        if let file, let data = FileManager.default.contents(atPath: file) {
            let all = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
            let n = min(count, all.count / Int(channels))
            frames = (0..<Int(channels)).map { c in (0..<n).map { all[$0 * Int(channels) + c] } }
        } else {
            var seed: UInt32 = 1
            frames = (0..<Int(channels)).map { c in
                (0..<count).map { i in
                    seed = seed &* 1_664_525 &+ 1_013_904_223
                    let noise = Float(Int32(bitPattern: seed)) / Float(Int32.max) * 0.05
                    return 0.2 * sinf(Float(i) * 2 * .pi * Float(110 * (c + 1)) / Float(rate)) + noise
                }
            }
        }
    }
    var length: Int { frames[0].count }
}

nonisolated(unsafe) var encodedFormat: AVAudioFormat?

struct Run {
    var packets: [Data] = []
    var framesFedAtFirstPacket = -1
    var encodeSeconds = 0.0
    var cookie = Data()
    var framesPerPacket: UInt32 = 0
    var maxPacket = 0
    var prime = AVAudioConverterPrimeInfo()
    var bitRate = 0
    var error: String?
}

func encode(_ source: Source, drc: AVAudioDynamicRangeControlConfiguration, content: AVAudioContentSource,
            bitRate: Int?, syncEvery: Int?, chunk: AVAudioFrameCount) -> Run {
    var run = Run()
    guard let converter = AVAudioConverter(from: pcmFormat(), to: apacFormat()) else {
        run.error = "no converter"; return run
    }
    converter.dynamicRangeControlConfiguration = drc
    converter.contentSource = content
    if let bitRate { converter.bitRate = bitRate }
    if let syncEvery { converter.audioSyncPacketFrequency = syncEvery }
    run.framesPerPacket = converter.outputFormat.streamDescription.pointee.mFramesPerPacket
    encodedFormat = converter.outputFormat
    run.maxPacket = converter.maximumOutputPacketSize
    run.prime = converter.primeInfo
    run.bitRate = converter.bitRate
    let out = AVAudioCompressedBuffer(format: converter.outputFormat, packetCapacity: 1,
                                      maximumPacketSize: max(converter.maximumOutputPacketSize, 1))
    var fed = 0
    var ended = false
    let started = Date()
    while true {
        var status = AVAudioConverterOutputStatus.haveData
        var err: NSError?
        status = converter.convert(to: out, error: &err) { want, outStatus in
            if fed >= source.length {
                outStatus.pointee = .endOfStream; ended = true; return nil
            }
            let n = min(Int(chunk), source.length - fed)
            let buf = AVAudioPCMBuffer(pcmFormat: pcmFormat(), frameCapacity: AVAudioFrameCount(n))!
            buf.frameLength = AVAudioFrameCount(n)
            for c in 0..<Int(channels) {
                source.frames[c].withUnsafeBufferPointer { src in
                    buf.floatChannelData![c].update(from: src.baseAddress! + fed, count: n)
                }
            }
            fed += n
            outStatus.pointee = .haveData
            return buf
        }
        if let err { run.error = err.localizedDescription; break }
        for i in 0..<Int(out.packetCount) {
            let d = out.packetDescriptions![i]
            run.packets.append(Data(bytes: out.data + Int(d.mStartOffset), count: Int(d.mDataByteSize)))
            if run.framesFedAtFirstPacket < 0 { run.framesFedAtFirstPacket = fed }
        }
        if status == .endOfStream || status == .error || (ended && out.packetCount == 0) { break }
    }
    run.encodeSeconds = Date().timeIntervalSince(started)
    run.cookie = converter.magicCookie ?? Data()
    return run
}

final class Feed {
    var queue: [Data]
    var current = Data()
    var description = AudioStreamPacketDescription()
    init(_ q: [Data]) { queue = q }
}

func decodeAll(_ packets: ArraySlice<Data>, cookie: Data) -> [[Float]] {
    var srcDesc = AudioStreamBasicDescription()
    srcDesc.mFormatID = kAudioFormatAPAC
    srcDesc.mSampleRate = rate
    srcDesc.mChannelsPerFrame = channels
    srcDesc.mFramesPerPacket = 1024
    let dstFormat = pcmFormat()
    var dstDesc = dstFormat.streamDescription.pointee
    var converter: AudioConverterRef?
    var status = AudioConverterNew(&srcDesc, &dstDesc, &converter)
    guard status == noErr, let converter else { print("AudioConverterNew", status, srcDesc, dstDesc); return [] }
    defer { AudioConverterDispose(converter) }
    status = cookie.withUnsafeBytes {
        AudioConverterSetProperty(converter, kAudioConverterDecompressionMagicCookie, UInt32(cookie.count), $0.baseAddress!)
    }
    if status != noErr { print("set cookie", status) }
    var layout = AudioChannelLayout(mChannelLayoutTag: kAudioChannelLayoutTag_Atmos_7_1_4, mChannelBitmap: [], mNumberChannelDescriptions: 0, mChannelDescriptions: AudioChannelDescription())
    _ = AudioConverterSetProperty(converter, kAudioConverterOutputChannelLayout, UInt32(MemoryLayout<AudioChannelLayout>.size), &layout)
    let feed = Feed(Array(packets))
    var result = [[Float]](repeating: [], count: Int(channels))
    let capacity: UInt32 = 1024
    let abl = AudioBufferList.allocate(maximumBuffers: Int(channels))
    defer { free(abl.unsafeMutablePointer) }
    var storage = (0..<Int(channels)).map { _ in [Float](repeating: 0, count: Int(capacity)) }
    while true {
        for c in 0..<Int(channels) {
            storage[c].withUnsafeMutableBufferPointer { ptr in
                abl[c] = AudioBuffer(mNumberChannels: 1, mDataByteSize: capacity * 4, mData: ptr.baseAddress)
            }
        }
        var frames = capacity
        let unmanaged = Unmanaged.passUnretained(feed).toOpaque()
        status = AudioConverterFillComplexBuffer(converter, { _, ioCount, ioData, outDesc, user in
            let feed = Unmanaged<Feed>.fromOpaque(user!).takeUnretainedValue()
            guard !feed.queue.isEmpty else { ioCount.pointee = 0; return 1 }
            feed.current = feed.queue.removeFirst()
            feed.description = AudioStreamPacketDescription(mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: UInt32(feed.current.count))
            ioCount.pointee = 1
            feed.current.withUnsafeMutableBytes { raw in
                ioData.pointee.mNumberBuffers = 1
                ioData.pointee.mBuffers = AudioBuffer(mNumberChannels: 0, mDataByteSize: UInt32(raw.count), mData: raw.baseAddress)
            }
            withUnsafeMutablePointer(to: &feed.description) { outDesc?.pointee = $0 }
            return noErr
        }, unmanaged, &frames, abl.unsafeMutablePointer, nil)
        for c in 0..<Int(channels) { result[c] += storage[c][0..<Int(frames)] }
        if frames == 0 || (status != noErr && status != 1) {
            if status != noErr && status != 1 && result[0].isEmpty { print("decode status", status) }
            break
        }
    }
    return result
}

let file = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : nil
let source = Source(file: file, seconds: 20)
print("source frames \(source.length) (\(file ?? "synthetic"))")

let base = encode(source, drc: .none, content: .av_Spatial_Live, bitRate: nil, syncEvery: nil, chunk: 2048)
if let e = base.error { print("error", e); exit(1) }
print("framesPerPacket \(base.framesPerPacket) maxPacket \(base.maxPacket) defaultBitRate \(base.bitRate)")
print("primeInfo leading \(base.prime.leadingFrames) trailing \(base.prime.trailingFrames)")
let cookieHex = base.cookie.prefix(48).map { String(format: "%02x", $0) }.joined()
print("cookie \(base.cookie.count) bytes: \(cookieHex)")
if let rates = AVAudioConverter(from: pcmFormat(), to: apacFormat())?.applicableEncodeBitRates {
    print("applicable bitrates (first/last) \(rates.first ?? 0) ... \(rates.last ?? 0), count \(rates.count)")
}

print("\n-- latency to first packet, chunk 2048 frames --")
for (name, drc) in [("none", AVAudioDynamicRangeControlConfiguration.none), ("music", .music), ("speech", .speech), ("movie", .movie), ("capture", .capture)] {
    let r = encode(source, drc: drc, content: .av_Spatial_Live, bitRate: nil, syncEvery: nil, chunk: 2048)
    let ms = Double(r.framesFedAtFirstPacket) / rate * 1000
    print("drc \(name): first packet after \(r.framesFedAtFirstPacket) frames (\(String(format: "%.1f", ms)) ms), packets \(r.packets.count), \(r.error ?? "ok")")
}
for chunk: AVAudioFrameCount in [40, 1024] {
    let r = encode(source, drc: .none, content: .av_Spatial_Live, bitRate: nil, syncEvery: nil, chunk: chunk)
    print("drc none chunk \(chunk): first packet after \(r.framesFedAtFirstPacket) frames")
}

print("\n-- content source and bitrate --")
let seconds = Double(source.length) / rate
for (name, content) in [("AV_Spatial_Live", AVAudioContentSource.av_Spatial_Live), ("AV_Spatial_Offline", .av_Spatial_Offline), ("AppleAV_Spatial_Offline", .appleAV_Spatial_Offline)] {
    for kbps in [nil, 3_840_000] as [Int?] {
        let r = encode(source, drc: .none, content: content, bitRate: kbps, syncEvery: nil, chunk: 2048)
        let bytes = r.packets.reduce(0) { $0 + $1.count }
        let rt = seconds / max(r.encodeSeconds, 1e-9)
        print("\(name) bitRate \(kbps.map(String.init) ?? "default"): avg \(Int(Double(bytes * 8) / seconds / 1000)) kbit/s, max packet \(r.packets.map(\.count).max() ?? 0) B, encode \(String(format: "%.1f", rt))x real time, \(r.error ?? "ok")")
    }
}

print("\n-- packet independence (decode from packet k vs continuous) --")
for sync in [nil, 1, 75] as [Int?] {
    let r = encode(source, drc: .none, content: .av_Spatial_Live, bitRate: nil, syncEvery: sync, chunk: 2048)
    let full = decodeAll(r.packets[...], cookie: r.cookie)
    var report: [String] = []
    for k in [10, 37, 100] where k < r.packets.count {
        let part = decodeAll(r.packets[k...], cookie: r.cookie)
        guard !part.isEmpty, !full.isEmpty, !full[0].isEmpty else { continue }
        // Best alignment over a window in the middle, then the error from there on.
        let base = k * 1024
        let probe = 20_000
        var best = (shift: 0, err: Float.infinity)
        for shift in stride(from: -4096, through: 4096, by: 1) {
            var e: Float = 0
            for i in stride(from: probe, to: probe + 2048, by: 4) {
                let j = base + i + shift
                if j < 0 || j >= full[0].count { e = .infinity; break }
                e += abs(part[0][i] - full[0][j])
            }
            if e < best.err { best = (shift, e) }
        }
        var firstEqual = -1
        var maxDiffTail: Float = 0
        let n = min(part[0].count, full[0].count - base - best.shift)
        for i in 0..<n {
            var d: Float = 0
            for c in 0..<Int(channels) { d = max(d, abs(part[c][i] - full[c][base + best.shift + i])) }
            if d < 1e-4, firstEqual < 0 { firstEqual = i }
            if i > 4096 { maxDiffTail = max(maxDiffTail, d) }
        }
        report.append("k=\(k): shift \(best.shift), equal (1e-4) from frame \(firstEqual), max diff after 4096 frames \(maxDiffTail)")
    }
    print("sync \(sync.map(String.init) ?? "default"): full \(full[0].count) frames for \(r.packets.count) packets; " + report.joined(separator: "; "))
}
