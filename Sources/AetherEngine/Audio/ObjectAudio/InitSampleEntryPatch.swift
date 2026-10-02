import Foundation

/// Swaps the first sample entry of the sound track in a finished fMP4 init (`ftyp` + `moov`) and
/// fixes the size of every box that contains it. Fragments never name the codec, so the init is the
/// only place a codec movenc cannot write (APAC) has to be described.
enum InitSampleEntryPatch {

    /// Nil when the init has no sound track with an `stsd` entry, or a box size does not add up.
    static func replacingAudioSampleEntry(in initBytes: Data, with entry: Data) -> Data? {
        let bytes = [UInt8](initBytes)
        guard let moov = child(of: bytes, in: 0..<bytes.count, type: "moov") else { return nil }
        for trak in children(of: bytes, in: moov.payload, type: "trak") {
            guard let mdia = child(of: bytes, in: trak.payload, type: "mdia"),
                  let hdlr = child(of: bytes, in: mdia.payload, type: "hdlr"),
                  handlerType(bytes, hdlr) == "soun",
                  let minf = child(of: bytes, in: mdia.payload, type: "minf"),
                  let stbl = child(of: bytes, in: minf.payload, type: "stbl"),
                  let stsd = child(of: bytes, in: stbl.payload, type: "stsd")
            else { continue }
            // stsd: version/flags (4) + entry_count (4), then the entries.
            let entriesStart = stsd.payload.lowerBound + 8
            guard entriesStart + 8 <= stsd.payload.upperBound,
                  let first = box(at: entriesStart, in: bytes, limit: stsd.payload.upperBound)
            else { return nil }
            let delta = entry.count - first.range.count
            var out = Array(bytes[0..<first.range.lowerBound])
            out += entry
            out += bytes[first.range.upperBound...]
            for ancestor in [stsd, stbl, minf, mdia, trak, moov] {
                guard addToSize(&out, at: ancestor.range.lowerBound, delta: delta) else { return nil }
            }
            return Data(out)
        }
        return nil
    }

    struct Box {
        let type: String
        let range: Range<Int>
        let payload: Range<Int>
    }

    static func box(at offset: Int, in bytes: [UInt8], limit: Int) -> Box? {
        guard offset + 8 <= limit else { return nil }
        let size32 = readUInt32(bytes, offset)
        let type = String(decoding: bytes[offset + 4..<offset + 8], as: UTF8.self)
        let header: Int
        let size: Int
        switch size32 {
        case 1:
            guard offset + 16 <= limit else { return nil }
            let size64 = (UInt64(readUInt32(bytes, offset + 8)) << 32) | UInt64(readUInt32(bytes, offset + 12))
            guard size64 <= UInt64(Int.max) else { return nil }
            header = 16
            size = Int(size64)
        case 0:
            header = 8
            size = limit - offset
        default:
            header = 8
            size = Int(size32)
        }
        guard size >= header, offset + size <= limit else { return nil }
        return Box(type: type, range: offset..<offset + size, payload: offset + header..<offset + size)
    }

    static func children(of bytes: [UInt8], in range: Range<Int>, type: String) -> [Box] {
        var found: [Box] = []
        var offset = range.lowerBound
        while let b = box(at: offset, in: bytes, limit: range.upperBound) {
            if b.type == type { found.append(b) }
            offset = b.range.upperBound
        }
        return found
    }

    static func child(of bytes: [UInt8], in range: Range<Int>, type: String) -> Box? {
        children(of: bytes, in: range, type: type).first
    }

    /// `hdlr`: version/flags (4), pre_defined (4), handler_type (4).
    private static func handlerType(_ bytes: [UInt8], _ hdlr: Box) -> String? {
        let at = hdlr.payload.lowerBound + 8
        guard at + 4 <= hdlr.payload.upperBound else { return nil }
        return String(decoding: bytes[at..<at + 4], as: UTF8.self)
    }

    private static func readUInt32(_ bytes: [UInt8], _ at: Int) -> UInt32 {
        UInt32(bytes[at]) << 24 | UInt32(bytes[at + 1]) << 16 | UInt32(bytes[at + 2]) << 8 | UInt32(bytes[at + 3])
    }

    /// Only 32-bit sizes are rewritten; an init never needs a 64-bit box.
    private static func addToSize(_ bytes: inout [UInt8], at offset: Int, delta: Int) -> Bool {
        let current = Int(readUInt32(bytes, offset))
        let updated = current + delta
        guard current > 1, updated >= 8, updated <= Int(UInt32.max) else { return false }
        let v = UInt32(updated)
        bytes[offset] = UInt8(v >> 24)
        bytes[offset + 1] = UInt8((v >> 16) & 0xFF)
        bytes[offset + 2] = UInt8((v >> 8) & 0xFF)
        bytes[offset + 3] = UInt8(v & 0xFF)
        return true
    }
}

/// The `apac` AudioSampleEntry, laid out the way AVAssetWriter writes it (macOS 26.6): version 0,
/// channelcount 2, samplesize 16, the rate in 16.16, then the encoder's magic cookie, which is
/// already a complete `dapa` box.
enum APACSampleEntry {

    static func make(dapaBox: Data, sampleRate: Int) -> Data? {
        guard dapaBox.count >= 8,
              String(decoding: dapaBox[dapaBox.startIndex + 4..<dapaBox.startIndex + 8], as: UTF8.self) == "dapa",
              sampleRate > 0, sampleRate < 65_536
        else { return nil }
        var body: [UInt8] = []
        body += [0, 0, 0, 0, 0, 0]          // reserved
        body += [0, 1]                      // data_reference_index
        body += [UInt8](repeating: 0, count: 8)  // version 0 reserved
        body += [0, 2]                      // channelcount
        body += [0, 16]                     // samplesize
        body += [0, 0, 0, 0]                // pre_defined, reserved
        let rate = UInt32(sampleRate) << 16
        body += [UInt8(rate >> 24), UInt8((rate >> 16) & 0xFF), 0, 0]
        body += [UInt8](dapaBox)
        let size = UInt32(8 + body.count)
        var entry: [UInt8] = [UInt8(size >> 24), UInt8((size >> 16) & 0xFF), UInt8((size >> 8) & 0xFF), UInt8(size & 0xFF)]
        entry += Array("apac".utf8)
        entry += body
        return Data(entry)
    }

    /// RFC 6381 string for the master playlist: `apac.<profile>.<level>` from the `dapa` payload is
    /// not documented, so the profile is fixed and the level follows the channel count.
    static func codecsString(channels: Int) -> String {
        let steps = [2, 6, 8, 12, 24, 32, 64]
        let level = steps.firstIndex { channels <= $0 } ?? steps.count - 1
        return String(format: "apac.31.%02d", level)
    }
}
