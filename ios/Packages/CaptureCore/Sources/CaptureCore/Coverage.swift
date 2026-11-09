import Foundation
import simd

/// 撮影方向の当てはめ・撮影済みの方向・次に撮る方向。
public enum Coverage {
    /// 方位角・仰角に当てはまる方向（許容の中で一番近いもの。同じ近さなら一覧の順で先のもの）。
    /// 方位角が分からない（正面が決まっていない）ときは nil。
    public static func match(azimuthDeg: Double?, elevationDeg: Double?, plan: DirectionPlan) -> DirectionTarget? {
        guard let azimuthDeg, let elevationDeg else { return nil }
        var best: (target: DirectionTarget, score: Double)?
        for target in plan.targets {
            let dAz = Geometry.angleDistance(azimuthDeg, target.azimuthDeg)
            let dEl = abs(elevationDeg - target.elevationDeg)
            guard dAz <= target.azimuthToleranceDeg, dEl <= target.elevationToleranceDeg else { continue }
            // 許容で割って比べる（方位と仰角で許容が違うため）。
            let score = dAz / max(target.azimuthToleranceDeg, 1e-6) + dEl / max(target.elevationToleranceDeg, 1e-6)
            if best == nil || score < best!.score {
                best = (target, score)
            }
        }
        return best?.target
    }

    /// 今の基準で撮影済みの方向。数えるのは、今の有効な基準（`activeReferenceFrame`）で撮った、
    /// `direction.confirmed` が true の写真だけ。基準が無い・無効なら空。
    public static func coveredTargetIds(in session: CaptureSession) -> Set<String> {
        guard let reference = session.activeReferenceFrame else { return [] }
        return coveredTargetIds(photos: session.photos, referenceFrameId: reference.id)
    }

    public static func coveredTargetIds(photos: [Photo], referenceFrameId: String) -> Set<String> {
        Set(photos.compactMap { photo -> String? in
            guard photo.referenceFrameId == referenceFrameId, photo.direction.confirmed else { return nil }
            return photo.direction.targetId
        })
    }

    /// 正面（方位 0°）の方向のうち、仰角が一番近いもの（同じ近さなら一覧の順で先）。正面の 1 枚目の高さの案内に使う。
    public static func frontTarget(plan: DirectionPlan, elevationDeg: Double) -> DirectionTarget? {
        plan.targets
            .filter { Geometry.angleDistance($0.azimuthDeg, 0) < 0.5 }
            .min { abs($0.elevationDeg - elevationDeg) < abs($1.elevationDeg - elevationDeg) }
    }

    /// 次に撮る方向：まだ撮っていない方向のうち、今の方位に一番近いもの。
    /// 方位の差が同じなら仰角の差、それも同じなら一覧の順。`preferredTargetId`（撮り直し）が未撮影ならそれを優先。
    /// 方位が分からないときは一覧の順で最初の未撮影の方向。
    public static func nextTarget(
        plan: DirectionPlan, covered: Set<String>, currentAzimuthDeg: Double?, currentElevationDeg: Double?,
        preferredTargetId: String? = nil
    ) -> DirectionTarget? {
        let remaining = plan.targets.filter { !covered.contains($0.id) }
        if let preferredTargetId, let preferred = remaining.first(where: { $0.id == preferredTargetId }) {
            return preferred
        }
        guard let currentAzimuthDeg else { return remaining.first }
        var best: (target: DirectionTarget, dAz: Double, dEl: Double)?
        for target in remaining {
            let dAz = Geometry.angleDistance(currentAzimuthDeg, target.azimuthDeg)
            let dEl = currentElevationDeg.map { abs($0 - target.elevationDeg) } ?? 0
            if let b = best {
                if dAz < b.dAz - 1e-9 || (abs(dAz - b.dAz) <= 1e-9 && dEl < b.dEl - 1e-9) {
                    best = (target, dAz, dEl)
                }
            } else {
                best = (target, dAz, dEl)
            }
        }
        return best?.target
    }
}

/// 撮影画面で使う、今のカメラの方向の情報。
public struct DirectionContext: Equatable, Sendable {
    /// 正面が決まっていないときは nil。
    public var azimuthDeg: Double?
    public var elevationDeg: Double
    public var distanceM: Double
    /// 今の方向に当てはまる方向（未撮影・撮影済みどちらも）。
    public var matchedTarget: DirectionTarget?
    public var matchedTargetCovered: Bool
    public var nextTarget: DirectionTarget?
    public var coveredCount: Int
    public var totalCount: Int
    /// 正面が決まっていないとき、1 枚目（正面）を当てはめる方向：方位 0° の方向のうち、今の仰角に一番近いもの。
    /// 正面が決まっているとき・方位 0° の方向が無いときは nil。
    public var frontTarget: DirectionTarget?
    /// 撮り直しが要る方向（撮ったが、切り抜きがうまくいかなかった）。`covered` には入らない。
    public var retakeTargetIds: Set<String>

    public init(
        azimuthDeg: Double?, elevationDeg: Double, distanceM: Double, matchedTarget: DirectionTarget?,
        matchedTargetCovered: Bool, nextTarget: DirectionTarget?, coveredCount: Int, totalCount: Int,
        frontTarget: DirectionTarget? = nil, retakeTargetIds: Set<String> = []
    ) {
        self.azimuthDeg = azimuthDeg
        self.elevationDeg = elevationDeg
        self.distanceM = distanceM
        self.matchedTarget = matchedTarget
        self.matchedTargetCovered = matchedTargetCovered
        self.nextTarget = nextTarget
        self.coveredCount = coveredCount
        self.totalCount = totalCount
        self.frontTarget = frontTarget
        self.retakeTargetIds = retakeTargetIds
    }

    /// 正面の 1 枚目の高さ（仰角）が、正面の方向の許容の中か。正面が決まっている・正面の方向が無いときは nil。
    public var frontElevationOK: Bool? {
        guard azimuthDeg == nil, let frontTarget else { return nil }
        return abs(elevationDeg - frontTarget.elevationDeg) <= frontTarget.elevationToleranceDeg
    }

    public var allCovered: Bool { coveredCount >= totalCount }
    public var isOnUncoveredTarget: Bool { matchedTarget != nil && !matchedTargetCovered }

    /// 今のカメラ位置と基準から作る。
    public static func make(
        cameraPosition: SIMD3<Double>, basePoint: SIMD3<Double>, heightM: Double, objectToWorld: simd_double4x4?,
        plan: DirectionPlan, covered: Set<String>, preferredTargetId: String? = nil, retake: Set<String> = []
    ) -> DirectionContext {
        let (elevation, distance) = Geometry.elevationAndDistance(cameraPosition: cameraPosition, basePoint: basePoint, heightM: heightM)
        let azimuth = objectToWorld.map { Geometry.azimuth(cameraPosition: cameraPosition, objectToWorld: $0) }
        let matched = Coverage.match(azimuthDeg: azimuth, elevationDeg: elevation, plan: plan)
        let next = Coverage.nextTarget(
            plan: plan, covered: covered, currentAzimuthDeg: azimuth, currentElevationDeg: elevation,
            preferredTargetId: preferredTargetId
        )
        let coveredCount = plan.targets.filter { covered.contains($0.id) }.count
        return DirectionContext(
            azimuthDeg: azimuth, elevationDeg: elevation, distanceM: distance, matchedTarget: matched,
            matchedTargetCovered: matched.map { covered.contains($0.id) } ?? false, nextTarget: next,
            coveredCount: coveredCount, totalCount: plan.targets.count,
            frontTarget: azimuth == nil ? Coverage.frontTarget(plan: plan, elevationDeg: elevation) : nil,
            retakeTargetIds: retake.intersection(plan.targets.map(\.id)).subtracting(covered)
        )
    }

    /// 次の方向へ動くための案内。
    public var guidance: String {
        guard let azimuthDeg else { return frontGuidance }
        if allCovered { return "すべての方向を撮影しました。追加で撮るか、確認へ進んでください" }
        if isOnUncoveredTarget {
            if let matchedTarget, retakeTargetIds.contains(matchedTarget.id) {
                return "\(Self.label(matchedTarget)) を撮り直します。この方向で撮影できます"
            }
            return "この方向で撮影できます"
        }
        guard let next = nextTarget else { return "すべての方向を撮影しました" }
        let retakePrefix = retakeTargetIds.contains(next.id)
            ? "\(Self.label(next)) の写真の切り抜きがうまくいきませんでした。もう一度撮ります。" : ""
        let dAz = Geometry.signedAngleDifference(from: azimuthDeg, to: next.azimuthDeg)
        if abs(dAz) > next.azimuthToleranceDeg {
            let side = dAz > 0 ? "右" : "左"
            let prefix = retakePrefix.isEmpty && matchedTargetCovered ? "この方向は撮影済みです。" : ""
            return "\(retakePrefix)\(prefix)もう少し\(side)へ回ってください（あと \(Int(abs(dAz).rounded()))°）"
        }
        let dEl = next.elevationDeg - elevationDeg
        if abs(dEl) > next.elevationToleranceDeg {
            return retakePrefix + (dEl > 0 ? "もう少し上から見下ろして撮ってください" : "もう少し低い位置から撮ってください")
        }
        return retakePrefix + "この方向で撮影できます"
    }

    /// 正面が決まっていないときの案内（1 枚目の高さも正面の方向に合わせる）。
    private var frontGuidance: String {
        let base = "正面から撮ってください（1 枚目が正面になります）"
        guard let frontTarget, frontElevationOK == false else { return base }
        let now = Int(elevationDeg.rounded()), goal = Int(frontTarget.elevationDeg.rounded())
        let move = elevationDeg > frontTarget.elevationDeg ? "もう少し低い位置から" : "もう少し高い位置から"
        return "正面の 1 枚目は、\(move)撮ってください（高さ \(now)° → \(goal)°）"
    }

    /// 方向の短い名前（「45°」、上から撮る方向は「90°・上から」）。
    public static func label(_ target: DirectionTarget) -> String {
        let az = "\(Int(target.azimuthDeg.rounded()))°"
        return target.elevationDeg > (DirectionPlanPreset.lowElevation + DirectionPlanPreset.highElevation) / 2 ? az + "・上から" : az
    }
}
