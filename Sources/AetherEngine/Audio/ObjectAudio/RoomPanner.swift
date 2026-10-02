import Foundation
import CoreAudioTypes

/// Speaker layout in the allocentric room cube Atmos metadata uses: x 0 left..1 right, y 0 front
/// (screen)..1 back, z 0 ear level..1 ceiling. Channel order is CoreAudio's for the layout tag.
struct RoomLayout: Sendable {
    struct Speaker: Sendable, Equatable {
        let label: String
        let x: Float
        let y: Float
        let z: Float
        let isLFE: Bool
    }

    let speakers: [Speaker]
    let channelLayoutTag: AudioChannelLayoutTag

    var channelCount: Int { speakers.count }
    var lfeIndex: Int? { speakers.firstIndex { $0.isLFE } }

    /// L R C LFE Ls Rs Rls Rrs Vhl Vhr Ltr Rtr (`kAudioChannelLayoutTag_Atmos_7_1_4`).
    static let atmos714 = RoomLayout(
        speakers: [
            Speaker(label: "L", x: 0, y: 0, z: 0, isLFE: false),
            Speaker(label: "R", x: 1, y: 0, z: 0, isLFE: false),
            Speaker(label: "C", x: 0.5, y: 0, z: 0, isLFE: false),
            Speaker(label: "LFE", x: 0.5, y: 0, z: 0, isLFE: true),
            Speaker(label: "Ls", x: 0, y: 0.5, z: 0, isLFE: false),
            Speaker(label: "Rs", x: 1, y: 0.5, z: 0, isLFE: false),
            Speaker(label: "Rls", x: 0, y: 1, z: 0, isLFE: false),
            Speaker(label: "Rrs", x: 1, y: 1, z: 0, isLFE: false),
            Speaker(label: "Vhl", x: 0, y: 0, z: 1, isLFE: false),
            Speaker(label: "Vhr", x: 1, y: 0, z: 1, isLFE: false),
            Speaker(label: "Ltr", x: 0, y: 1, z: 1, isLFE: false),
            Speaker(label: "Rtr", x: 1, y: 1, z: 1, isLFE: false),
        ],
        channelLayoutTag: kAudioChannelLayoutTag_Atmos_7_1_4
    )

    /// Where an OAMD bed speaker sits in the cube (codes L R C LFE Lss Rss Lrs Rrs Lfh Rfh Lts Rts
    /// Lrh Rrh Lw Rw LFE2). Wides sit at y = 0.5 - 21/62, as in the OAMD speaker table.
    static func bedPosition(code: UInt8) -> (x: Float, y: Float, z: Float, isLFE: Bool)? {
        let wideY: Float = 0.5 - 21.0 / 62.0
        switch code {
        case 0: return (0, 0, 0, false)
        case 1: return (1, 0, 0, false)
        case 2: return (0.5, 0, 0, false)
        case 3, 16: return (0.5, 0, 0, true)
        case 4: return (0, 0.5, 0, false)
        case 5: return (1, 0.5, 0, false)
        case 6: return (0, 1, 0, false)
        case 7: return (1, 1, 0, false)
        case 8: return (0, 0, 1, false)
        case 9: return (1, 0, 1, false)
        case 10: return (0, 0.5, 1, false)
        case 11: return (1, 0.5, 1, false)
        case 12: return (0, 1, 1, false)
        case 13: return (1, 1, 1, false)
        case 14: return (0, wideY, 0, false)
        case 15: return (1, wideY, 0, false)
        default: return nil
        }
    }
}

/// Point panning by "dual balance" in the cube, after the allocentric panner of ITU-R BS.2127: the
/// position is split between the two height planes, inside a plane between the two rows that
/// bracket its depth, inside a row between the two speakers that bracket its width. Every split is
/// equal-power, so the squared gains always sum to one.
struct RoomPanner: Sendable {
    let layout: RoomLayout

    /// OAMD zone constraints. They mask ear-level speakers; heights drop out only for zones that
    /// confine the object to the ear plane. Center back has no public definition and acts as no sides.
    enum Zone: UInt8, CaseIterable {
        case all = 0, noBack, noSides, centerBack, screenOnly, surroundOnly
    }

    private struct Row: Sendable {
        let y: Float
        let xs: [Float]
        let channels: [Int]
    }

    private struct Plane: Sendable {
        let z: Float
        let rows: [Row]
        let ys: [Float]
    }

    private struct Grid: Sendable {
        let planes: [Plane]
        let zs: [Float]
        let allowed: [Bool]
    }

    /// Indexed by zone raw value * 2 + elevation.
    private let grids: [Grid]

    init(layout: RoomLayout) {
        self.layout = layout
        var grids: [Grid] = []
        for zone in Zone.allCases {
            for elevation in [false, true] {
                let allowed = Self.allowedSpeakers(layout: layout, zone: zone, elevation: elevation)
                grids.append(Self.grid(layout: layout, allowed: allowed))
            }
        }
        self.grids = grids
    }

    /// Gains per layout channel for an object. Squared gains sum to 1 (LFE always 0).
    func gains(x: Float, y: Float, z: Float, size: Float = 0, snap: Bool = false,
               elevation: Bool = true, zone: UInt8 = 0) -> [Float] {
        let zoneValue = Zone(rawValue: zone) ?? .all
        let grid = grids[Int(zoneValue.rawValue) * 2 + (elevation ? 1 : 0)]
        let px = clamp01(x), py = clamp01(y)
        let pz = elevation ? clamp01(z) : 0
        var out = [Float](repeating: 0, count: layout.channelCount)
        if snap {
            snapGains(x: px, y: py, z: pz, allowed: grid.allowed, into: &out)
        } else if size > 0.01 {
            extentGains(x: px, y: py, z: pz, size: min(size, 1), grid: grid, into: &out)
        } else {
            Self.accumulate(grid, x: px, y: py, z: pz, power: false, into: &out)
        }
        return out
    }

    /// Gains for a bed speaker of the source: discrete when the layout has it, panned otherwise.
    func bedGains(code: UInt8) -> [Float] {
        var out = [Float](repeating: 0, count: layout.channelCount)
        guard let pos = RoomLayout.bedPosition(code: code) else { return out }
        if pos.isLFE {
            if let lfe = layout.lfeIndex { out[lfe] = 1 }
            return out
        }
        Self.accumulate(grids[Int(Zone.all.rawValue) * 2 + 1], x: pos.x, y: pos.y, z: pos.z,
                        power: false, into: &out)
        return out
    }

    /// The two values bracketing `p` with equal-power weights; one value when `p` is outside or on it.
    static func split(_ values: [Float], at p: Float) -> [(index: Int, gain: Float)] {
        guard let first = values.first, let last = values.last else { return [] }
        if values.count == 1 || p <= first { return [(0, 1)] }
        if p >= last { return [(values.count - 1, 1)] }
        var upper = 1
        while upper < values.count - 1, values[upper] < p { upper += 1 }
        let b = values[upper]
        if b == p { return [(upper, 1)] }
        let a = values[upper - 1]
        let t = (p - a) / (b - a)
        return [(upper - 1, cosf(t * .pi / 2)), (upper, sinf(t * .pi / 2))]
    }

    // MARK: - Panning

    private static func accumulate(_ grid: Grid, x: Float, y: Float, z: Float, power: Bool,
                                   into out: inout [Float]) {
        for (p, planeGain) in split(grid.zs, at: z) where planeGain > 0 {
            let plane = grid.planes[p]
            for (r, rowGain) in split(plane.ys, at: y) where rowGain > 0 {
                let row = plane.rows[r]
                for (c, columnGain) in split(row.xs, at: x) where columnGain > 0 {
                    let g = planeGain * rowGain * columnGain
                    out[row.channels[c]] += power ? g * g : g
                }
            }
        }
    }

    /// Size spreads power over a grid of points around the position, then renormalises.
    private func extentGains(x: Float, y: Float, z: Float, size: Float, grid: Grid, into out: inout [Float]) {
        let steps = size > 0.5 ? 5 : 3
        let half = size / 2
        let offsets = (0..<steps).map { Float($0) / Float(steps - 1) * 2 - 1 }
        for dx in offsets {
            for dy in offsets {
                for dz in offsets {
                    Self.accumulate(grid, x: clamp01(x + dx * half), y: clamp01(y + dy * half),
                                    z: clamp01(z + dz * half), power: true, into: &out)
                }
            }
        }
        let total = out.reduce(0, +)
        guard total > 0 else { return }
        for c in out.indices { out[c] = sqrtf(out[c] / total) }
    }

    private func snapGains(x: Float, y: Float, z: Float, allowed: [Bool], into out: inout [Float]) {
        var best: (index: Int, distance: Float)?
        for (i, s) in layout.speakers.enumerated() where allowed[i] {
            let d = (s.x - x) * (s.x - x) + (s.y - y) * (s.y - y) + (s.z - z) * (s.z - z)
            if best.map({ d < $0.distance }) ?? true { best = (i, d) }
        }
        if let best { out[best.index] = 1 }
    }

    private static func grid(layout: RoomLayout, allowed: [Bool]) -> Grid {
        let usable = layout.speakers.indices.filter { allowed[$0] }
        let planes = Set(usable.map { layout.speakers[$0].z }).sorted().map { z -> Plane in
            let inPlane = usable.filter { layout.speakers[$0].z == z }
            let rows = Set(inPlane.map { layout.speakers[$0].y }).sorted().map { y -> Row in
                let inRow = inPlane.filter { layout.speakers[$0].y == y }
                    .sorted { layout.speakers[$0].x < layout.speakers[$1].x }
                return Row(y: y, xs: inRow.map { layout.speakers[$0].x }, channels: inRow)
            }
            return Plane(z: z, rows: rows, ys: rows.map(\.y))
        }
        return Grid(planes: planes, zs: planes.map(\.z), allowed: allowed)
    }

    private static func allowedSpeakers(layout: RoomLayout, zone: Zone, elevation: Bool) -> [Bool] {
        layout.speakers.map { s in
            if s.isLFE { return false }
            if s.z > 0 { return elevation && zone != .screenOnly && zone != .surroundOnly }
            switch zone {
            case .all: return true
            case .noBack: return s.y < 1
            case .noSides, .centerBack: return s.y == 0 || s.y == 1
            case .screenOnly: return s.y == 0
            case .surroundOnly: return s.y > 0
            }
        }
    }

    private func clamp01(_ v: Float) -> Float { min(max(v, 0), 1) }
}
