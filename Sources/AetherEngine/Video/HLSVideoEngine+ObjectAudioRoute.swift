import Foundation
import AetherLibavformat
import AetherLibavcodec
import AetherLibavutil

/// TVSeerr fork: the one attempt before the bridge cascade that renders TrueHD Atmos objects into
/// 7.1.4 and delivers APAC. Any refusal or failure falls through to the cascade (lossless 7.1).
extension HLSVideoEngine {

    /// FFmpeg's `AV_PROFILE_TRUEHD_ATMOS`, set by the TrueHD decoder at probe from the major sync.
    static let trueHDAtmosProfile: Int32 = 30

    enum ObjectAudioRefusal: String, Equatable {
        case optionOff = "option off"
        case notTrueHD = "not TrueHD"
        case notAtmos = "TrueHD without Atmos"
        case sampleRate = "not 48 kHz"
        case system = "needs tvOS 26"
        case decoderMissing = "object decoder not in this build"
    }

    static func objectAudioRefusal(
        rendering: ObjectAudioRendering, codecID: AVCodecID, profile: Int32, sampleRate: Int32,
        systemSupportsAPAC: Bool, decoderAvailable: Bool
    ) -> ObjectAudioRefusal? {
        guard rendering != .off else { return .optionOff }
        guard codecID == AV_CODEC_ID_TRUEHD else { return .notTrueHD }
        guard profile == trueHDAtmosProfile else { return .notAtmos }
        guard sampleRate == 0 || sampleRate == 48_000 else { return .sampleRate }
        guard systemSupportsAPAC else { return .system }
        guard decoderAvailable else { return .decoderMissing }
        return nil
    }

    static var objectDecoderAvailable: Bool {
        #if canImport(TrueHDObjectsC)
        true
        #else
        false
        #endif
    }

    /// The TrueHD object decoder of this build; nil when the platform has none.
    static func makeObjectDecoder() throws -> (any ObjectAudioDecoding)? {
        #if canImport(TrueHDObjectsC)
        try TrueHDObjectsDecoder()
        #else
        nil
        #endif
    }

    func buildObjectAudioProducer(
        audioStream: UnsafeMutablePointer<AVStream>,
        sourceAudioStreamIndex: Int32,
        audioHLSCodecs: inout String?,
        audioLanguage: String?
    ) -> HLSSegmentProducer? {
        let par = audioStream.pointee.codecpar.pointee
        var systemSupportsAPAC = false
        if #available(tvOS 26.0, iOS 26.0, macOS 26.0, visionOS 26.0, *) { systemSupportsAPAC = true }
        if let refusal = Self.objectAudioRefusal(
            rendering: objectAudioRendering, codecID: par.codec_id, profile: par.profile,
            sampleRate: par.sample_rate, systemSupportsAPAC: systemSupportsAPAC,
            decoderAvailable: Self.objectDecoderAvailable) {
            if refusal != .optionOff, refusal != .notTrueHD {
                EngineLog.emit("[ObjectAudio] route refused: \(refusal.rawValue)", category: .session)
            }
            return nil
        }
        guard #available(tvOS 26.0, iOS 26.0, macOS 26.0, visionOS 26.0, *) else { return nil }
        let bridge: ObjectAudioBridge
        do {
            guard let decoder = try Self.makeObjectDecoder() else { return nil }
            bridge = try ObjectAudioBridge(decoder: decoder, srcTimeBase: audioStream.pointee.time_base)
        } catch {
            EngineLog.emit("[ObjectAudio] route refused: bridge init failed (\(error))", category: .session)
            return nil
        }
        guard let cp = bridge.encoderCodecpar else { return nil }
        bridge.onGiveUp = { [weak self] reason in self?.onObjectAudioGaveUp?(reason) }
        let cfg = HLSSegmentProducer.AudioConfig(
            codecpar: cp,
            timeBase: bridge.encoderTimeBase,
            sourceStreamIndex: sourceAudioStreamIndex,
            inputTimeBase: bridge.encoderTimeBase,
            sourceTimeBase: audioStream.pointee.time_base,
            bridge: bridge,
            language: audioLanguage
        )
        savedAudioConfig = cfg
        audioBridge = bridge
        do {
            let prod = try makeProducer(baseIndex: initialProducerBaseIndex)
            audioHLSCodecs = bridge.codecsString
            audioPipelineDescription = "TRUEHD Atmos → APAC 7.1.4"
            audioDelivery = .bridged
            EngineLog.emit(
                "[ObjectAudio] TrueHD Atmos → 7.1.4 APAC \(bridge.bitRate / 1000) kbit/s "
                + "priming=\(bridge.primingFrames) codecs=\(bridge.codecsString) "
                + "decoder=\(Self.objectDecoderVersion)",
                category: .session
            )
            return prod
        } catch {
            EngineLog.emit(
                "[ObjectAudio] route refused: header write failed (\(error)), using the bridge cascade",
                category: .session
            )
            savedAudioConfig = nil
            audioBridge = nil
            bridge.close()
            return nil
        }
    }

    static var objectDecoderVersion: String {
        #if canImport(TrueHDObjectsC)
        TrueHDObjectsDecoder.version
        #else
        "none"
        #endif
    }
}
