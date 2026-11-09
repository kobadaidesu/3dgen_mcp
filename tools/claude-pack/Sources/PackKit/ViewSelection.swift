import Foundation
import CaptureCore

/// How a photo's mask may be used (silhouette, cutout, visual hull).
public enum MaskUse: String, Codable, Sendable, Comparable {
    /// `confirmed`, or `candidate` whose check is `ok`.
    case good
    /// `candidate` without a check (sessions from before `mask.check` existed). Used, but flagged.
    case unchecked
    /// suspicious / unknown check, failed, noObject, not generated, or the file is missing.
    case unusable

    public static func of(_ photo: Photo, fileExists: Bool = true) -> MaskUse {
        guard fileExists, photo.mask.status.hasFile, photo.mask.file != nil else { return .unusable }
        switch photo.mask.status {
        case .confirmed: return .good
        case .candidate:
            switch photo.mask.check?.status {
            case .ok?: return .good
            case nil: return .unchecked
            case .suspicious?, .unknown?: return .unusable
            }
        default: return .unusable
        }
    }

    var rank: Int { self == .good ? 0 : self == .unchecked ? 1 : 2 }
    public static func < (a: MaskUse, b: MaskUse) -> Bool { a.rank < b.rank }
}

/// Saved-image quality (`quality.saved`) as one rank: 0 = blur and brightness ok, 1 = not analysed, 2 = warning or worse.
public enum SavedQualityRank {
    public static func of(_ photo: Photo) -> Int {
        guard let saved = photo.quality.saved else { return 1 }
        return saved.blur == .ok && saved.brightness == .ok ? 0 : 2
    }

    public static func note(_ photo: Photo) -> String? {
        guard let saved = photo.quality.saved else { return "saved quality not analysed" }
        var parts: [String] = []
        if saved.blur != .ok { parts.append("blur \(saved.blur.rawValue)") }
        if saved.brightness != .ok { parts.append("brightness \(saved.brightness.rawValue)") }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }
}

/// One canonical view of the package.
public struct ViewSlot: Equatable, Sendable {
    public enum Kind: String, Sendable { case ring, top, frontHigh }

    public var name: String
    public var kind: Kind
    /// Wanted azimuth (nil for `top`: any azimuth, front preferred).
    public var azimuthDeg: Double?
    public var elevationDeg: Double
    public var azimuthToleranceDeg: Double
    public var elevationToleranceDeg: Double
    /// Lowest elevation accepted (only `top`).
    public var minimumElevationDeg: Double?

    /// Human-readable name used in labels.
    public var label: String { name.replacingOccurrences(of: "_", with: "-") }

    /// The 8 ring views at the lowest band, then `top` and `front_high`.
    public static func standard(lowestBandDeg: Double) -> [ViewSlot] {
        let ring: [(String, Double)] = [
            ("front", 0), ("front_right", 45), ("right", 90), ("back_right", 135),
            ("back", 180), ("back_left", 225), ("left", 270), ("front_left", 315),
        ]
        var slots = ring.map {
            ViewSlot(name: $0.0, kind: .ring, azimuthDeg: $0.1, elevationDeg: lowestBandDeg,
                     azimuthToleranceDeg: ViewSelector.ringAzimuthTolerance, elevationToleranceDeg: ViewSelector.ringElevationTolerance)
        }
        slots.append(ViewSlot(name: "top", kind: .top, azimuthDeg: nil, elevationDeg: ViewSelector.topPreferredElevation,
                              azimuthToleranceDeg: 180, elevationToleranceDeg: 90,
                              minimumElevationDeg: max(ViewSelector.topMinimumElevation, lowestBandDeg + 20)))
        slots.append(ViewSlot(name: "front_high", kind: .frontHigh, azimuthDeg: 0, elevationDeg: 45,
                              azimuthToleranceDeg: ViewSelector.ringAzimuthTolerance, elevationToleranceDeg: 12))
        return slots
    }
}

/// The photo chosen for a slot (or why there is none).
public struct ViewChoice: Codable, Equatable, Sendable {
    public var name: String
    public var label: String
    @NullCodable public var requestedAzimuthDeg: Double?
    public var requestedElevationDeg: Double
    @NullCodable public var photoId: String?
    @NullCodable public var sequence: Int?
    @NullCodable public var targetId: String?
    @NullCodable public var azimuthDeg: Double?
    @NullCodable public var elevationDeg: Double?
    @NullCodable public var distanceM: Double?
    @NullCodable public var maskUse: MaskUse?
    /// `mask.check.reasons` and other remarks about the chosen photo (blur, angle far from the slot, …).
    public var notes: [String]
    /// Why the slot is empty.
    @NullCodable public var missingReason: String?
    /// Files written for the slot (relative to the package folder).
    @NullCodable public var file: String?
    @NullCodable public var cutoutFile: String?
    /// How the crop was decided: "maskBoundingBox" | "projectedCylinder".
    @NullCodable public var cropSource: String?
    /// Crop in the stored (sensor-orientation) photo, pixels.
    @NullCodable public var cropInPhoto: PixelBox?
    @NullCodable public var outputWidth: Int?
    @NullCodable public var outputHeight: Int?

    public var isMissing: Bool { photoId == nil }
}

public enum ViewSelector {
    public static let ringAzimuthTolerance = 25.0
    public static let ringElevationTolerance = 15.0
    public static let topPreferredElevation = 70.0
    public static let topMinimumElevation = 40.0
    /// A chosen photo further than this from the slot gets a note ("weak" slot in the brief).
    public static let weakAngleDeg = 10.0

    /// Reference frame with the most direction-confirmed photos (ties → the later frame). nil without any.
    public static func majorityReferenceFrame(_ session: CaptureSession) -> String? {
        var counts: [String: Int] = [:]
        for p in session.photos where p.direction.confirmed {
            if let id = p.referenceFrameId { counts[id, default: 0] += 1 }
        }
        let order = Dictionary(uniqueKeysWithValues: session.referenceFrames.enumerated().map { ($1.id, $0) })
        return counts.max { a, b in
            a.value != b.value ? a.value < b.value : (order[a.key] ?? -1) < (order[b.key] ?? -1)
        }?.key
    }

    /// Photos replaced by a later shot of the same direction (per reference frame, the app's rule).
    public static func supersededPhotoIds(_ session: CaptureSession) -> Set<String> {
        Set(Readiness.make(session: session).supersededPhotoIds)
    }

    /// Lowest elevation band of the direction plan (20° for every current plan).
    public static func lowestBand(_ session: CaptureSession) -> Double {
        session.directionPlan.bands.first?.elevationDeg ?? 20
    }

    /// Chooses one photo per slot. Hard rules: direction confirmed, majority reference frame, not superseded,
    /// angles known, within the slot's tolerance. Among those: usable mask first (good, then unchecked, then none),
    /// then saved quality (ok, not analysed, warning), then the closest angle. A photo is used for one slot only.
    public static func select(
        session: CaptureSession, slots: [ViewSlot]? = nil,
        maskFileExists: (Photo) -> Bool = { _ in true }
    ) -> (referenceFrameId: String?, choices: [ViewChoice]) {
        let frame = majorityReferenceFrame(session)
        let slots = slots ?? ViewSlot.standard(lowestBandDeg: lowestBand(session))
        let superseded = supersededPhotoIds(session)
        let pool = session.photos.filter {
            $0.direction.confirmed && $0.referenceFrameId == frame && frame != nil && !superseded.contains($0.photoId)
                && $0.direction.azimuthDeg != nil && $0.direction.elevationDeg != nil
        }.sorted { $0.sequence < $1.sequence }

        var used = Set<String>()
        var choices: [ViewChoice] = []
        for slot in slots {
            var best: (key: [Double], photo: Photo, use: MaskUse)?
            for photo in pool where !used.contains(photo.photoId) {
                guard let score = angleScore(slot: slot, azimuth: photo.direction.azimuthDeg!, elevation: photo.direction.elevationDeg!) else { continue }
                let use = MaskUse.of(photo, fileExists: maskFileExists(photo))
                let key = [Double(use.rank), Double(SavedQualityRank.of(photo)), score, -Double(photo.sequence)]
                if best == nil || key.lexicographicallyPrecedes(best!.key) { best = (key, photo, use) }
            }
            var choice = ViewChoice(name: slot.name, label: slot.label, requestedAzimuthDeg: slot.azimuthDeg,
                                    requestedElevationDeg: slot.elevationDeg, notes: [])
            guard let best else {
                choice.missingReason = frame == nil ? "no photo with a confirmed direction"
                    : slot.kind == .top ? "no photo at \(Int(slot.minimumElevationDeg ?? 40))° elevation or higher"
                    : "no usable photo within ±\(Int(slot.azimuthToleranceDeg))° azimuth / ±\(Int(slot.elevationToleranceDeg))° elevation"
                choices.append(choice)
                continue
            }
            used.insert(best.photo.photoId)
            let p = best.photo
            choice.photoId = p.photoId
            choice.sequence = p.sequence
            choice.targetId = p.direction.targetId
            choice.azimuthDeg = p.direction.azimuthDeg
            choice.elevationDeg = p.direction.elevationDeg
            choice.distanceM = p.direction.distanceM
            choice.maskUse = best.use
            switch best.use {
            case .good: break
            case .unchecked: choice.notes.append("mask not checked (older session)")
            case .unusable:
                let reasons = p.mask.check?.reasons.map(\.rawValue).joined(separator: ",") ?? ""
                choice.notes.append("no usable mask (\(p.mask.status.rawValue)\(p.mask.check.map { " \($0.status.rawValue)" } ?? "")\(reasons.isEmpty ? "" : ": " + reasons)); crop from the projected cylinder, no cutout")
            }
            if let q = SavedQualityRank.note(p) { choice.notes.append(q) }
            if let az = slot.azimuthDeg {
                let d = Geometry.angleDistance(az, p.direction.azimuthDeg!)
                if d > weakAngleDeg { choice.notes.append(String(format: "azimuth %.0f° off the slot", d)) }
            }
            if slot.kind != .top {
                let d = abs(p.direction.elevationDeg! - slot.elevationDeg)
                if d > weakAngleDeg { choice.notes.append(String(format: "elevation %.0f° off the slot", d)) }
            } else if p.direction.elevationDeg! < 55 {
                choice.notes.append(String(format: "highest photo is only %.0f° elevation (oblique, not a true top view)", p.direction.elevationDeg!))
            }
            choices.append(choice)
        }
        return (frame, choices)
    }

    /// Normalised distance to the slot (smaller is better), or nil when outside the slot.
    public static func angleScore(slot: ViewSlot, azimuth: Double, elevation: Double) -> Double? {
        switch slot.kind {
        case .top:
            guard elevation >= (slot.minimumElevationDeg ?? topMinimumElevation) else { return nil }
            // closest to the preferred elevation; among equals, the one nearest the front
            return abs(elevation - slot.elevationDeg) / 15 + Geometry.angleDistance(azimuth, 0) / 180 * 0.25
        case .ring, .frontHigh:
            let da = Geometry.angleDistance(azimuth, slot.azimuthDeg ?? 0)
            let de = abs(elevation - slot.elevationDeg)
            guard da <= slot.azimuthToleranceDeg, de <= slot.elevationToleranceDeg else { return nil }
            return da / slot.azimuthToleranceDeg + de / slot.elevationToleranceDeg
        }
    }
}
