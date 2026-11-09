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

    public init(
        azimuthDeg: Double?, elevationDeg: Double, distanceM: Double, matchedTarget: DirectionTarget?,
        matchedTargetCovered: Bool, nextTarget: DirectionTarget?, coveredCount: Int, totalCount: Int
    ) {
        self.azimuthDeg = azimuthDeg
        self.elevationDeg = elevationDeg
        self.distanceM = distanceM
        self.matchedTarget = matchedTarget
        self.matchedTargetCovered = matchedTargetCovered
        self.nextTarget = nextTarget
        self.coveredCount = coveredCount
        self.totalCount = totalCount
    }

    public var allCovered: Bool { coveredCount >= totalCount }
    public var isOnUncoveredTarget: Bool { matchedTarget != nil && !matchedTargetCovered }

    /// 今のカメラ位置と基準から作る。
    public static func make(
        cameraPosition: SIMD3<Double>, basePoint: SIMD3<Double>, heightM: Double, objectToWorld: simd_double4x4?,
        plan: DirectionPlan, covered: Set<String>, preferredTargetId: String? = nil
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
            coveredCount: coveredCount, totalCount: plan.targets.count
        )
    }

    /// 次の方向へ動くための案内。
    public var guidance: String {
        guard let azimuthDeg else { return "正面から撮ってください（1 枚目が正面になります）" }
        if allCovered { return "すべての方向を撮影しました。追加で撮るか、確認へ進んでください" }
        if isOnUncoveredTarget { return "この方向で撮影できます" }
        guard let next = nextTarget else { return "すべての方向を撮影しました" }
        let dAz = Geometry.signedAngleDifference(from: azimuthDeg, to: next.azimuthDeg)
        if abs(dAz) > next.azimuthToleranceDeg {
            let side = dAz > 0 ? "右" : "左"
            let prefix = matchedTargetCovered ? "この方向は撮影済みです。" : ""
            return "\(prefix)もう少し\(side)へ回ってください（あと \(Int(abs(dAz).rounded()))°）"
        }
        let dEl = next.elevationDeg - elevationDeg
        if abs(dEl) > next.elevationToleranceDeg {
            return dEl > 0 ? "もう少し上から見下ろして撮ってください" : "もう少し低い位置から撮ってください"
        }
        return "この方向で撮影できます"
    }
}
