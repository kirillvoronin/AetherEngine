import Foundation

/// Render Dolby TrueHD Atmos objects into a speaker bed and deliver it as APAC (tvOS 26+), which
/// tvOS hands an Atmos receiver as Dolby MAT. `.off` keeps the lossless 7.1 bridge.
public enum ObjectAudioRendering: String, Sendable, CaseIterable {
    case off
    /// 7.1.4 bed, APAC at 320 kbit/s per channel.
    case apac714
}
