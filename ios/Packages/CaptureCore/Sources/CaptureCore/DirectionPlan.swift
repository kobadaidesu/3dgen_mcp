import Foundation

public struct DirectionTarget: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var azimuthDeg: Double
    public var elevationDeg: Double
    public var azimuthToleranceDeg: Double
    public var elevationToleranceDeg: Double

    public init(id: String, azimuthDeg: Double, elevationDeg: Double, azimuthToleranceDeg: Double, elevationToleranceDeg: Double) {
        self.id = id
        self.azimuthDeg = azimuthDeg
        self.elevationDeg = elevationDeg
        self.azimuthToleranceDeg = azimuthToleranceDeg
        self.elevationToleranceDeg = elevationToleranceDeg
    }

    /// `a000-e20` の形の id。
    public static func makeId(azimuthDeg: Double, elevationDeg: Double) -> String {
        let az = Int(Geometry.normalizeDegrees(azimuthDeg).rounded())
        let el = Int(elevationDeg.rounded())
        let elText = el < 0 ? String(format: "m%02d", -el) : String(format: "%02d", el)
        return String(format: "a%03d-e", az) + elText
    }

    public static func make(azimuthDeg: Double, elevationDeg: Double, azimuthTolerance: Double, elevationTolerance: Double) -> DirectionTarget {
        DirectionTarget(
            id: makeId(azimuthDeg: azimuthDeg, elevationDeg: elevationDeg),
            azimuthDeg: azimuthDeg, elevationDeg: elevationDeg,
            azimuthToleranceDeg: azimuthTolerance, elevationToleranceDeg: elevationTolerance
        )
    }
}

/// 撮影する方向の一覧（session.json の `directionPlan`）。
public struct DirectionPlan: Codable, Equatable, Sendable {
    public var id: String
    public var targets: [DirectionTarget]

    public init(id: String, targets: [DirectionTarget]) {
        self.id = id
        self.targets = targets
    }

    public func target(id: String?) -> DirectionTarget? {
        guard let id else { return nil }
        return targets.first { $0.id == id }
    }
}

/// 撮影方向のプリセット。値を変えるときはここだけを変える。
/// 一覧にない方向の写真（追加撮影）はいつでも撮れる（`targetId` が null になる）。
public enum DirectionPlanPreset: String, CaseIterable, Codable, Sendable, Identifiable {
    /// 既定。仰角 20° で 45° ごとに 8 方向。
    case ring8
    /// 仰角 20° で 0 / 90 / 180 / 270 の 4 方向。
    case ring4
    /// ring8 に、仰角 50° で 90° ごとの 4 方向を足した 12 方向。
    case ring8plusHigh

    public var id: String { rawValue }

    public static let `default`: DirectionPlanPreset = .ring8

    /// 方位の許容（±度）。
    public static let azimuthTolerance: Double = 20
    /// 仰角の許容（±度）。
    public static let elevationTolerance: Double = 15
    /// ふつうの高さの仰角。
    public static let lowElevation: Double = 20
    /// 上から撮る方向の仰角。
    public static let highElevation: Double = 50

    public var displayName: String {
        switch self {
        case .ring8: return "8 方向（標準）"
        case .ring4: return "4 方向（かんたん）"
        case .ring8plusHigh: return "8 方向 + 上から 4 方向"
        }
    }

    public var plan: DirectionPlan {
        DirectionPlan(id: rawValue, targets: targets)
    }

    private var targets: [DirectionTarget] {
        let azTol = Self.azimuthTolerance
        let elTol = Self.elevationTolerance
        func ring(step: Double, elevation: Double) -> [DirectionTarget] {
            stride(from: 0.0, to: 360.0, by: step).map {
                DirectionTarget.make(azimuthDeg: $0, elevationDeg: elevation, azimuthTolerance: azTol, elevationTolerance: elTol)
            }
        }
        switch self {
        case .ring8:
            return ring(step: 45, elevation: Self.lowElevation)
        case .ring4:
            return ring(step: 90, elevation: Self.lowElevation)
        case .ring8plusHigh:
            return ring(step: 45, elevation: Self.lowElevation) + ring(step: 90, elevation: Self.highElevation)
        }
    }
}
