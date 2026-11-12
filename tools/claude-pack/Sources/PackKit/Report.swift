import Foundation
import CaptureCore

public enum PackInfo {
    public static let toolName = "memoria-pack"
    public static let toolVersion = "0.2.0"
}

public struct Size3: Codable, Equatable, Sendable {
    /// Along X (left–right seen from the front).
    public var width: Double
    /// Along Z (front–back).
    public var depth: Double
    /// Along Y (up).
    public var height: Double
}

/// `measurements.json`.
public struct Measurements: Codable, Sendable {
    public struct Uncertainty: Codable, Equatable, Sendable {
        /// ± per dimension (cm): voxel edge + median reprojection slack.
        public var plusMinusCm: Double
        public var voxelCm: Double
        @NullCodable public var reprojectionSlackCm: Double?
        /// The top can be this much too high when the object's top is flat (the photos only look down at it);
        /// rounded tops are affected less. The true height lies roughly in [height − this, height + plusMinus].
        @NullCodable public var heightOverestimateUpToCm: Double?
        public var note: String
    }

    public struct Footprint: Codable, Equatable, Sendable {
        public var lengthCm: Double
        public var widthCm: Double
        /// Direction of the long side (azimuth convention: 0 = front–back along Z, 90 = left–right along X).
        public var longAxisAzimuthDeg: Double
    }

    public struct Grid: Codable, Equatable, Sendable {
        public var nx: Int, ny: Int, nz: Int
        public var voxelSizeM: Double
        public var searchBoxMinM: [Double]
        public var searchBoxMaxM: [Double]
    }

    public struct SkippedView: Codable, Equatable, Sendable {
        public var photoId: String
        public var sequence: Int
        public var reason: String
    }

    public struct Mesh: Codable, Equatable, Sendable {
        public var file: String
        public var vertices: Int
        public var faces: Int
        public var voxelSizeM: Double
    }

    public var schema = "memoria.claude-pack.measurements"
    public var schemaVersion = 1
    public var sessionId: String
    /// "ok" (visual hull) | "approximate" (too few silhouettes: `sizeCm` is the user-fitted cylinder, see `method`) | "unavailable"
    public var status: String
    @NullCodable public var unavailableReason: String?
    /// "visualHull" | "userCylinder" (the cylinder fitted with the AR guide during capture, not a measurement)
    public var method = "visualHull"
    public var frame: [String: String] = [
        "units": "metres (sizeCm in centimetres)",
        "origin": "x, z: the capture's reference point (base centre); y = 0: the table plane estimated from the hull (see tablePlaneAboveReferenceM)",
        "y": "up (gravity opposite)",
        "z": "towards the front camera (views/front.jpg looks along -Z)",
        "x": "right as seen from the front (x = y × z)",
    ]
    @NullCodable public var referenceFrameId: String?
    /// The table plane estimated from the hull, measured from the capture's reference point (m, up is positive).
    /// The package's frame puts y = 0 on this plane (x and z stay as in the capture's object frame).
    @NullCodable public var tablePlaneAboveReferenceM: Double?
    @NullCodable public var sizeCm: Size3?
    @NullCodable public var sizeM: Size3?
    @NullCodable public var bboxMinM: [Double]?
    @NullCodable public var bboxMaxM: [Double]?
    @NullCodable public var footprint: Footprint?
    @NullCodable public var uncertainty: Uncertainty?
    /// "normal" | "low" (few silhouettes, silhouettes that disagree, unchecked masks): see `confidenceReasons`.
    @NullCodable public var confidence: String?
    public var confidenceReasons: [String] = []
    /// Silhouettes whose mask was never checked (`candidate` without `check`, older sessions).
    public var uncheckedMaskViews = 0
    @NullCodable public var grid: Grid?
    @NullCodable public var voxelCount: Int?
    /// voxelCount · voxel³ (an upper bound: the hull fills concavities and the hidden underside).
    @NullCodable public var volumeCm3: Double?
    /// Voxels dropped as small detached fragments (not the largest connected piece).
    @NullCodable public var removedFragmentVoxels: Int?
    /// Sides of the search box the hull reaches ("x-", "x+", "z-", "z+", "y+"): the object may be larger there.
    public var touchesSearchBox: [String] = []
    public var viewsUsed = 0
    /// Photos of the reference frame with a usable silhouette (mask). Below `PackBuilder.minimumHullViews` no hull is carved.
    public var usableSilhouettes = 0
    public var viewsUsedPhotoIds: [String] = []
    public var viewsSkipped: [SkippedView] = []
    public var perViewSlack: [VisualHull.ViewSlack] = []
    /// The cylinder the user fitted with the AR guide (the search box is this × 1.3).
    @NullCodable public var userCylinder: ObjectSize?
    @NullCodable public var baseSource: String?
    @NullCodable public var mesh: Mesh?
    public var caveats: [String] = []
    public var seconds: Double = 0
}

/// `pack.json`: the package's index and provenance.
public struct PackIndex: Codable, Sendable {
    public struct Provenance: Codable, Equatable, Sendable {
        public var sessionId: String
        @NullCodable public var manifestHash: String?
        @NullCodable public var receivedAt: String?
        public var generatedAt: String
        public var tool: String
        public var toolVersion: String
        public var sourceFolder: String
        /// Whether `views/*_cutout.png` were written (`--cutouts`). Missing in packages from before the option (they had grey JPG cutouts).
        public var cutouts: Bool?
    }

    public struct Coverage: Codable, Equatable, Sendable {
        @NullCodable public var referenceFrameId: String?
        public var referenceFrameIds: [String]
        public var photoCount: Int
        public var photosInReferenceFrame: Int
        @NullCodable public var minElevationDeg: Double?
        @NullCodable public var maxElevationDeg: Double?
        public var directionPlanId: String
        public var bands: [Band]
        public var bottomCaptured = false
        public var missingViews: [String]
        public var weakViews: [String]
    }

    public struct Band: Codable, Equatable, Sendable {
        public var elevationDeg: Double
        /// Directions of the plan at this elevation.
        public var targets: Int
        /// Directions with at least one photo (direction confirmed, this reference frame).
        public var shot: Int
        /// Directions whose best photo has a checked, usable mask (the app's "done").
        public var done: Int
    }

    public struct MaskIssue: Codable, Equatable, Sendable {
        public var sequence: Int
        public var photoId: String
        @NullCodable public var targetId: String?
        @NullCodable public var referenceFrameId: String?
        public var status: String
        @NullCodable public var check: String?
        public var reasons: [String]
    }

    public var schema = "memoria.claude-pack"
    public var schemaVersion = 1
    public var provenance: Provenance
    public var title: String
    public var views: [ViewChoice]
    public var coverage: Coverage
    public var maskIssues: [MaskIssue]
    public var files: [String]
    public var timingsS: [String: Double]
}
