import XCTest
import simd
import CoreGraphics
import CaptureCore
@testable import PackKit

final class PackKitTests: XCTestCase {
    // MARK: - Fixtures

    static let plan = DirectionPlan(id: "test", targets: [
        DirectionTarget(id: "a000-e20", azimuthDeg: 0, elevationDeg: 20, azimuthToleranceDeg: 7, elevationToleranceDeg: 10),
        DirectionTarget(id: "a015-e20", azimuthDeg: 15, elevationDeg: 20, azimuthToleranceDeg: 7, elevationToleranceDeg: 10),
        DirectionTarget(id: "a090-e20", azimuthDeg: 90, elevationDeg: 20, azimuthToleranceDeg: 7, elevationToleranceDeg: 10),
        DirectionTarget(id: "a000-e70", azimuthDeg: 0, elevationDeg: 70, azimuthToleranceDeg: 20, elevationToleranceDeg: 10),
    ])

    static func pid(_ n: Int) -> String { String(format: "00000000-0000-4000-8000-%012d", n) }

    func photo(_ seq: Int, az: Double, el: Double, frame: String? = "ref-1", confirmed: Bool = true, target: String? = nil,
               mask: MaskStatus = .candidate, check: MaskCheckStatus? = .ok, blur: CheckStatus = .ok) -> Photo {
        let id = Self.pid(seq)
        return Photo(
            photoId: id, sequence: seq, capturedAt: Date(timeIntervalSince1970: Double(seq)), trigger: .auto,
            referenceFrameId: frame,
            image: ImageInfo(file: Photo.imagePath(photoId: id), width: 4032, height: 3024, displayRotationDegClockwise: 90, deviceOrientation: "portrait"),
            camera: CameraInfo(arFrameTimestamp: 0, cameraToWorld: Matrix4x4(matrix_identity_double4x4),
                               intrinsics: Matrix3x3(simd_double3x3(rows: [SIMD3(3000, 0, 2016), SIMD3(0, 3000, 1512), SIMD3(0, 0, 1)])),
                               intrinsicsResolution: PixelSize(width: 4032, height: 3024),
                               exposureDurationS: nil, exposureOffsetEV: nil, trackingState: .normal, trackingReason: nil),
            direction: DirectionInfo(confirmed: confirmed, unconfirmedReason: confirmed ? nil : .trackingNotNormal,
                                     targetId: confirmed ? target : nil, azimuthDeg: az, elevationDeg: el, distanceM: 0.3),
            quality: PhotoQuality(live: .unknown, saved: SavedQuality(meanLuma: 0.5, sharpness: 0.01, brightness: .ok, blur: blur)),
            mask: MaskInfo(status: mask, file: mask.hasFile ? Photo.maskPath(photoId: id) : nil, width: 4032, height: 3024,
                           check: mask.hasFile ? check.map { MaskCheck(status: $0, reasons: $0 == .ok ? [] : [.tooLarge]) } : nil)
        )
    }

    func session(_ photos: [Photo], frames: [String] = ["ref-1"]) -> CaptureSession {
        var s = CaptureSession(sessionId: "S", title: "", createdAt: Date(timeIntervalSince1970: 0),
                               device: DeviceInfo(model: "", systemName: "iOS", systemVersion: "", appVersion: "", appBuild: ""),
                               directionPlan: Self.plan)
        s.referenceFrames = frames.map { ReferenceFrame(id: $0, createdAt: Date(timeIntervalSince1970: 0), basePointWorld: .zero) }
        s.photos = photos
        return s
    }

    func choice(_ name: String, _ result: (referenceFrameId: String?, choices: [ViewChoice])) -> ViewChoice {
        result.choices.first { $0.name == name }!
    }

    // MARK: - View selection

    func testClosestAngleWins() {
        let s = session([photo(1, az: 12, el: 21), photo(2, az: 3, el: 22), photo(3, az: 350, el: 30)])
        let r = ViewSelector.select(session: s)
        XCTAssertEqual(choice("front", r).photoId, Self.pid(2))
        XCTAssertEqual(choice("front", r).azimuthDeg, 3)
        XCTAssertTrue(choice("front", r).notes.isEmpty)
    }

    func testSkipsUnusableMasksUnconfirmedAndOtherFrames() {
        let s = session([
            photo(1, az: 0, el: 20, check: .suspicious),            // suspicious mask
            photo(2, az: 1, el: 20, mask: .noObject),                // no mask
            photo(3, az: 0.5, el: 20, frame: nil, confirmed: false), // unconfirmed direction
            photo(4, az: 359, el: 20, frame: "ref-2"),               // minority frame
            photo(5, az: 9, el: 24),                                 // usable, further away
            photo(6, az: 90, el: 20), photo(7, az: 180, el: 20),
        ], frames: ["ref-1", "ref-2"])
        let r = ViewSelector.select(session: s)
        XCTAssertEqual(r.referenceFrameId, "ref-1")
        XCTAssertEqual(choice("front", r).photoId, Self.pid(5))
        XCTAssertEqual(choice("front", r).maskUse, .good)
        XCTAssertEqual(choice("right", r).photoId, Self.pid(6))
    }

    func testUnusableMaskOnlyAsLastResort() {
        let s = session([photo(1, az: 0, el: 20, check: .suspicious)])
        let c = choice("front", ViewSelector.select(session: s))
        XCTAssertEqual(c.photoId, Self.pid(1))
        XCTAssertEqual(c.maskUse, .unusable)
        XCTAssertTrue(c.notes.contains { $0.hasPrefix("no usable mask") })
    }

    func testBlurPreferredLessThanCleanPhoto() {
        let s = session([photo(1, az: 0, el: 20, blur: .warning), photo(2, az: 8, el: 20)])
        XCTAssertEqual(choice("front", ViewSelector.select(session: s)).photoId, Self.pid(2))
    }

    func testSupersededPhotosAreSkipped() {
        // Same target, both usable: the older shot is superseded even though it is closer to the slot.
        let s = session([photo(1, az: 0, el: 20, target: "a000-e20"), photo(2, az: 5, el: 20, target: "a000-e20")])
        XCTAssertEqual(ViewSelector.supersededPhotoIds(s), [Self.pid(1)])
        XCTAssertEqual(choice("front", ViewSelector.select(session: s)).photoId, Self.pid(2))
    }

    func testMajorityReferenceFrame() {
        let s = session([
            photo(1, az: 0, el: 20, frame: "ref-1"), photo(2, az: 90, el: 20, frame: "ref-1"),
            photo(3, az: 0, el: 20, frame: "ref-2"), photo(4, az: 90, el: 20, frame: "ref-2"), photo(5, az: 180, el: 20, frame: "ref-2"),
            photo(6, az: 0, el: 20, frame: nil, confirmed: false), photo(7, az: 0, el: 20, frame: nil, confirmed: false),
            photo(8, az: 0, el: 20, frame: nil, confirmed: false),
        ], frames: ["ref-1", "ref-2"])
        XCTAssertEqual(ViewSelector.majorityReferenceFrame(s), "ref-2")
        XCTAssertEqual(choice("front", ViewSelector.select(session: s)).photoId, Self.pid(3))
        // ties go to the later frame
        let tie = session([photo(1, az: 0, el: 20, frame: "ref-1"), photo(2, az: 0, el: 20, frame: "ref-2")], frames: ["ref-1", "ref-2"])
        XCTAssertEqual(ViewSelector.majorityReferenceFrame(tie), "ref-2")
    }

    func testTopAndFrontHighAndMissingSlots() {
        let s = session([photo(1, az: 0, el: 20), photo(2, az: 120, el: 69), photo(3, az: 10, el: 75), photo(4, az: 5, el: 44)])
        let r = ViewSelector.select(session: s)
        XCTAssertEqual(choice("top", r).photoId, Self.pid(2))       // closest to 70°
        XCTAssertEqual(choice("front_high", r).photoId, Self.pid(4))
        XCTAssertNil(choice("back", r).photoId)
        XCTAssertNotNil(choice("back", r).missingReason)
        // a photo is used once: photo 1 is the front, not also the front-left
        XCTAssertNil(choice("front_left", r).photoId)

        let low = session([photo(1, az: 0, el: 20), photo(2, az: 90, el: 35)])
        XCTAssertNil(choice("top", ViewSelector.select(session: low)).photoId)  // 35° is not a top view
    }

    func testMaskUseRules() {
        XCTAssertEqual(MaskUse.of(photo(1, az: 0, el: 20, mask: .confirmed, check: .suspicious)), .good)
        XCTAssertEqual(MaskUse.of(photo(1, az: 0, el: 20, check: .ok)), .good)
        XCTAssertEqual(MaskUse.of(photo(1, az: 0, el: 20, check: nil)), .unchecked)
        XCTAssertEqual(MaskUse.of(photo(1, az: 0, el: 20, check: .unknown)), .unusable)
        XCTAssertEqual(MaskUse.of(photo(1, az: 0, el: 20, mask: .failed)), .unusable)
        XCTAssertEqual(MaskUse.of(photo(1, az: 0, el: 20), fileExists: false), .unusable)
    }

    // MARK: - Crop and rotation

    func testUprightRectMatchesDisplayRotation() {
        let W = 4032, H = 3024
        let r = PixelBox(x: 1000, y: 500, width: 800, height: 600)
        for rot in [0, 90, 180, 270] {
            let u = CropMath.upright(r, imageWidth: W, imageHeight: H, rotationDegClockwise: rot)
            let size = DisplayRotation.displaySize(width: W, height: H, rotationDegClockwise: rot)
            // the four corners of r land on the corners of u
            let corners = [(r.x, r.y), (r.maxX, r.y), (r.x, r.maxY), (r.maxX, r.maxY)].map { c -> SIMD2<Double> in
                let n = DisplayRotation.displayPoint(fromSensor: SIMD2(Double(c.0) / Double(W), Double(c.1) / Double(H)), rotationDegClockwise: rot)
                return SIMD2(n.x * Double(size.width), n.y * Double(size.height))
            }
            XCTAssertEqual(corners.map(\.x).min()!, Double(u.x), accuracy: 1e-6, "rot \(rot)")
            XCTAssertEqual(corners.map(\.y).min()!, Double(u.y), accuracy: 1e-6, "rot \(rot)")
            XCTAssertEqual(corners.map(\.x).max()!, Double(u.maxX), accuracy: 1e-6, "rot \(rot)")
            XCTAssertEqual(corners.map(\.y).max()!, Double(u.maxY), accuracy: 1e-6, "rot \(rot)")
        }
        XCTAssertEqual(CropMath.upright(r, imageWidth: W, imageHeight: H, rotationDegClockwise: 90),
                       PixelBox(x: 3024 - 1100, y: 1000, width: 600, height: 800))
    }

    func testCropAddsMarginKeepsAspectAndStaysInside() {
        let box = PixelRect(x: 1000, y: 1000, width: 400, height: 100)
        let c = CropMath.crop(around: box, imageWidth: 4032, imageHeight: 3024)!
        // 20 % of the long side on each side → 560 wide, then widened to 4:3 → 420 tall, centred
        XCTAssertEqual(c.width, 560)
        XCTAssertEqual(c.height, 420)
        XCTAssertEqual(Double(c.x) + Double(c.width) / 2, box.midX, accuracy: 1)
        XCTAssertEqual(Double(c.y) + Double(c.height) / 2, box.midY, accuracy: 1)
        // near the corner it shifts inside, keeping its size
        let corner = CropMath.crop(around: PixelRect(x: 0, y: 0, width: 300, height: 300), imageWidth: 4032, imageHeight: 3024)!
        XCTAssertEqual(corner, PixelBox(x: 0, y: 0, width: 420, height: 420))
        // larger than the photo: clipped to it
        let big = CropMath.crop(around: PixelRect(x: 0, y: 0, width: 4000, height: 3000), imageWidth: 4032, imageHeight: 3024)!
        XCTAssertEqual(big, PixelBox(x: 0, y: 0, width: 4032, height: 3024))
        XCTAssertNil(CropMath.crop(around: PixelRect(x: 5000, y: 0, width: 10, height: 10), imageWidth: 4032, imageHeight: 3024))
    }

    func testOutputSizeNeverUpscalesAndCapsLongSide() {
        let small = CropMath.outputSize(crop: PixelBox(x: 0, y: 0, width: 600, height: 400), rotationDegClockwise: 90)
        XCTAssertEqual(small.width, 400)
        XCTAssertEqual(small.height, 600)
        let big = CropMath.outputSize(crop: PixelBox(x: 0, y: 0, width: 3136, height: 2352), rotationDegClockwise: 90)
        XCTAssertEqual(big.width, 1176)
        XCTAssertEqual(big.height, 1568)
    }

    func testUprightCropTurnsPixelsClockwise() throws {
        // A 4 × 2 grid of 10-px blocks with values 0…70; crop the right 3 block columns and turn it.
        let blocks: [[UInt8]] = [[0, 10, 20, 30], [40, 50, 60, 70]]
        let n = 10
        var src = GrayImage(width: 4 * n, height: 2 * n)
        for y in 0..<(2 * n) { for x in 0..<(4 * n) { src[x, y] = blocks[y / n][x / n] } }
        let image = ImageOps.makeGrayImage(src)!
        let crop = PixelBox(x: n, y: 0, width: 3 * n, height: 2 * n)
        let expected: [Int: [[UInt8]]] = [
            0: [[10, 20, 30], [50, 60, 70]],
            90: [[50, 10], [60, 20], [70, 30]],    // the left block column of the crop becomes the top row
            180: [[70, 60, 50], [30, 20, 10]],
            270: [[30, 70], [20, 60], [10, 50]],
        ]
        for (rot, want) in expected {
            let size = CropMath.outputSize(crop: crop, rotationDegClockwise: rot)
            let out = try ImageOps.gray(ImageOps.uprightCrop(image, crop: crop, rotationDegClockwise: rot,
                                                              width: size.width, height: size.height, gray: true))
            XCTAssertEqual(out.width, want[0].count * n, "rot \(rot)")
            XCTAssertEqual(out.height, want.count * n, "rot \(rot)")
            let got = (0..<want.count).map { r in (0..<want[0].count).map { c in out[c * n + n / 2, r * n + n / 2] } }
            XCTAssertEqual(got, want, "rot \(rot)")
            let u = CropMath.upright(crop, imageWidth: 4 * n, imageHeight: 2 * n, rotationDegClockwise: rot)
            XCTAssertEqual([u.width, u.height], [out.width, out.height])
        }
    }

    func testCutoutBlendsToMidGrey() throws {
        let photo = ImageOps.makeGrayImage(GrayImage(width: 2, height: 1, pixels: [255, 255]))!
        let cut = try ImageOps.cutout(photo: photo, alpha: GrayImage(width: 2, height: 1, pixels: [255, 0]))
        var px = [UInt8](repeating: 0, count: 8)
        let ctx = CGContext(data: &px, width: 2, height: 1, bitsPerComponent: 8, bytesPerRow: 8,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.draw(cut, in: CGRect(x: 0, y: 0, width: 2, height: 1))
        XCTAssertEqual(Array(px[0..<3]), [255, 255, 255])
        for c in 4..<7 { XCTAssertEqual(Int(px[c]), 0x7f, accuracy: 1) }
    }

    // MARK: - Visual hull on a synthetic scene

    /// ARKit-style camera at `position` looking at `target` (+X image right, +Y image up, −Z forward).
    static func lookAt(_ position: SIMD3<Double>, _ target: SIMD3<Double>) -> simd_double4x4 {
        let forward = simd_normalize(target - position)
        let right = simd_normalize(simd_cross(forward, SIMD3(0, 1, 0)))
        let up = simd_cross(right, forward)
        return simd_double4x4(columns: (SIMD4(right, 0), SIMD4(up, 0), SIMD4(-forward, 0), SIMD4(position, 1)))
    }

    /// Mask of an axis-aligned box (world) seen by a pinhole camera: a pixel is set when its ray hits the box.
    static func renderBox(min lo: SIMD3<Double>, max hi: SIMD3<Double>, cameraToWorld: simd_double4x4,
                          f: Double, width: Int, height: Int) -> GrayImage {
        var out = GrayImage(width: width, height: height)
        let o = cameraToWorld.translation
        let r = simd_double3x3(SIMD3(cameraToWorld.columns.0.x, cameraToWorld.columns.0.y, cameraToWorld.columns.0.z),
                               SIMD3(cameraToWorld.columns.1.x, cameraToWorld.columns.1.y, cameraToWorld.columns.1.z),
                               SIMD3(cameraToWorld.columns.2.x, cameraToWorld.columns.2.y, cameraToWorld.columns.2.z))
        for y in 0..<height {
            for x in 0..<width {
                let d = simd_normalize(r * SIMD3((Double(x) + 0.5 - Double(width) / 2) / f, -(Double(y) + 0.5 - Double(height) / 2) / f, -1))
                var t0 = 0.0, t1 = Double.infinity
                var hit = true
                for a in 0..<3 {
                    if abs(d[a]) < 1e-12 {
                        if o[a] < lo[a] || o[a] > hi[a] { hit = false; break }
                        continue
                    }
                    var ta = (lo[a] - o[a]) / d[a], tb = (hi[a] - o[a]) / d[a]
                    if ta > tb { swap(&ta, &tb) }
                    t0 = max(t0, ta); t1 = min(t1, tb)
                    if t0 > t1 { hit = false; break }
                }
                if hit { out[x, y] = 1 }
            }
        }
        return out
    }

    func syntheticViews(boxMin: SIMD3<Double>, boxMax: SIMD3<Double>) -> [HullView] {
        let f = 260.0, w = 320, h = 240
        var views: [HullView] = []
        let center = (boxMin + boxMax) / 2
        for el in [20.0, 45.0, 70.0] {
            for i in 0..<12 {
                let az = Double(i) * 30 + (el == 45 ? 15 : 0)
                let e = el * .pi / 180, a = az * .pi / 180
                let p = center + 0.35 * SIMD3(cos(e) * sin(a), sin(e), cos(e) * cos(a))
                let c2w = Self.lookAt(p, center)
                let mask = Self.renderBox(min: boxMin, max: boxMax, cameraToWorld: c2w, f: f, width: w, height: h)
                let k = simd_double3x3(rows: [SIMD3(f, 0, Double(w) / 2), SIMD3(0, f, Double(h) / 2), SIMD3(0, 0, 1)])
                views.append(HullView(id: "v\(views.count)", cameraToWorld: c2w, intrinsics: k,
                                      intrinsicsWidth: Double(w), intrinsicsHeight: Double(h), mask: mask))
            }
        }
        return views
    }

    func testVisualHullRecoversBoxSizeAndTable() {
        // A 10 × 4 × 6 cm box (W × H × D) on the table, a bit off the reference point.
        let lo = SIMD3(-0.04, 0.0, -0.035), hi = SIMD3(0.06, 0.04, 0.025)
        let views = syntheticViews(boxMin: lo, boxMax: hi)
        var settings = HullSettings()
        settings.voxelSize = 0.003
        settings.maskDilation = 0
        settings.carveFraction = 0
        // The reference point was measured 1 cm below the table: the object frame sits 1 cm lower.
        let offset = 0.01
        let objectToWorld = simd_double4x4(columns: (SIMD4(1, 0, 0, 0), SIMD4(0, 1, 0, 0), SIMD4(0, 0, 1, 0), SIMD4(0, -offset, 0, 1)))
        let empty = VisualHull.grid(radiusM: 0.09, heightM: 0.06, settings: settings)
        var grid = VisualHull.carve(grid: empty, views: views, objectToWorld: objectToWorld, settings: settings)
        grid.keepLargestComponent()
        let cams = views.map { v -> SIMD3<Double> in
            let p = objectToWorld.inverse * SIMD4(v.cameraToWorld.translation, 1)
            return SIMD3(p.x, p.y, p.z)
        }
        let table = VisualHull.estimateTable(grid: grid, cameraPositions: cams)!
        let s = settings.voxelSize
        XCTAssertEqual(table, offset, accuracy: 1.5 * s)
        grid = VisualHull.clip(grid, belowY: table)
        let b = grid.bounds()!
        let size = b.max - b.min
        XCTAssertEqual(size.x, 0.10, accuracy: 1.5 * s)
        XCTAssertEqual(size.z, 0.06, accuracy: 1.5 * s)
        // height from the table: the flat top makes the hull a little taller, within the reported bias bound
        let height = b.max.y - table
        let bias = VisualHull.flatTopBias(grid: grid, cameraPositions: cams)!
        XCTAssertGreaterThanOrEqual(height, 0.04 - 1.5 * s)
        XCTAssertLessThanOrEqual(height, 0.04 + bias + 1.5 * s)
        let fp = VisualHull.footprint(grid: grid)!
        XCTAssertEqual(fp.lengthM, 0.10, accuracy: 1.5 * s)
        XCTAssertEqual(fp.widthM, 0.06, accuracy: 1.5 * s)
        XCTAssertEqual(fp.longAxisAzimuthDeg, 90)  // long side runs left–right
        // the hull projects inside every mask: slack is about a voxel
        let slack = VisualHull.slack(grid: grid, views: views, objectToWorld: objectToWorld)
        XCTAssertEqual(slack.count, views.count)
        XCTAssertLessThan(slack.map(\.slackM).max()!, 2 * s)
    }

    func testUnknownProjectionsDoNotCarve() {
        // A single view that does not see the grid at all must not carve anything; minSeenViews then drops it all.
        var settings = HullSettings()
        settings.voxelSize = 0.01
        settings.minSeenViews = 0
        let away = Self.lookAt(SIMD3(0, 0.02, 0.5), SIMD3(0, 0.02, 1.5))  // looking away from the object
        let view = HullView(id: "v", cameraToWorld: away, intrinsics: simd_double3x3(rows: [SIMD3(100, 0, 50), SIMD3(0, 100, 50), SIMD3(0, 0, 1)]),
                            intrinsicsWidth: 100, intrinsicsHeight: 100, mask: GrayImage(width: 100, height: 100))
        let empty = VisualHull.grid(radiusM: 0.05, heightM: 0.05, settings: settings)
        let kept = VisualHull.carve(grid: empty, views: [view], objectToWorld: matrix_identity_double4x4, settings: settings)
        XCTAssertEqual(kept.count, empty.nx * empty.ny * empty.nz)
        settings.minSeenViews = 1
        XCTAssertEqual(VisualHull.carve(grid: empty, views: [view], objectToWorld: matrix_identity_double4x4, settings: settings).count, 0)
    }

    func testCarveFractionToleratesOneBadMask() {
        let lo = SIMD3(-0.03, 0.0, -0.03), hi = SIMD3(0.03, 0.03, 0.03)
        var views = syntheticViews(boxMin: lo, boxMax: hi)
        views[0].mask = GrayImage(width: views[0].mask.width, height: views[0].mask.height)  // an empty (wrong) mask
        var settings = HullSettings()
        settings.voxelSize = 0.003
        settings.carveFraction = 0
        let empty = VisualHull.grid(radiusM: 0.06, heightM: 0.05, settings: settings)
        XCTAssertEqual(VisualHull.carve(grid: empty, views: views, objectToWorld: matrix_identity_double4x4, settings: settings).count, 0)
        settings.carveFraction = 0.1
        let tolerant = VisualHull.carve(grid: empty, views: views, objectToWorld: matrix_identity_double4x4, settings: settings)
        XCTAssertGreaterThan(tolerant.count, 0)
    }

    func testObjFacesAreClosedAndOutward() {
        var g = VoxelGrid(nx: 2, ny: 1, nz: 1, voxelSize: 0.01, origin: .zero)
        g.occupied = [true, true]
        let obj = VisualHull.obj(grid: g, header: ["test"])
        XCTAssertEqual(obj.faces, 10)     // a 2 × 1 × 1 block: 10 exposed unit faces
        XCTAssertEqual(obj.vertices, 12)
        XCTAssertTrue(obj.text.hasPrefix("# test\nv "))
        // every face normal (from its winding) points away from the block centre
        let vs = obj.text.split(separator: "\n").filter { $0.hasPrefix("v ") }.map { l -> SIMD3<Double> in
            let p = l.split(separator: " ").dropFirst().map { Double($0)! }
            return SIMD3(p[0], p[1], p[2])
        }
        let centre = SIMD3(0.01, 0.005, 0.005)
        for l in obj.text.split(separator: "\n") where l.hasPrefix("f ") {
            let idx = l.split(separator: " ").dropFirst().map { Int($0)! - 1 }
            let n = simd_cross(vs[idx[1]] - vs[idx[0]], vs[idx[2]] - vs[idx[0]])
            let faceCentre = idx.map { vs[$0] }.reduce(.zero, +) / 4
            XCTAssertGreaterThan(simd_dot(n, faceCentre - centre), 0, String(l))
        }
    }

    func testLargestComponentDropsFragments() {
        var g = VoxelGrid(nx: 5, ny: 1, nz: 1, voxelSize: 0.01, origin: .zero)
        g.occupied = [true, true, false, false, true]
        XCTAssertEqual(g.keepLargestComponent(), 1)
        XCTAssertEqual(g.occupied, [true, true, false, false, false])
    }

    // MARK: - JSON shape

    func testMeasurementsJSONShape() throws {
        var m = Measurements(sessionId: "S", status: "ok")
        m.sizeCm = Size3(width: 6.2, depth: 12.4, height: 4.9)
        m.uncertainty = .init(plusMinusCm: 0.5, voxelCm: 0.2, reprojectionSlackCm: 0.3, heightOverestimateUpToCm: 0.9, note: "n")
        let obj = try JSONSerialization.jsonObject(with: JSONEncoder().encode(m)) as! [String: Any]
        XCTAssertEqual(obj["schema"] as? String, "memoria.claude-pack.measurements")
        XCTAssertEqual(obj["schemaVersion"] as? Int, 1)
        XCTAssertEqual(obj["method"] as? String, "visualHull")
        let size = obj["sizeCm"] as! [String: Double]
        XCTAssertEqual(size, ["width": 6.2, "depth": 12.4, "height": 4.9])
        // missing values are null, not absent
        XCTAssertTrue(obj["footprint"] is NSNull)
        XCTAssertTrue(obj["tablePlaneAboveReferenceM"] is NSNull)
        XCTAssertNotNil((obj["frame"] as? [String: String])?["z"])
        let back = try JSONDecoder().decode(Measurements.self, from: JSONEncoder().encode(m))
        XCTAssertEqual(back.sizeCm, m.sizeCm)
    }

    func testViewChoiceAndPackIndexJSON() throws {
        let s = session([photo(1, az: 2, el: 21)])
        let choices = ViewSelector.select(session: s).choices
        let obj = try JSONSerialization.jsonObject(with: JSONEncoder().encode(choices)) as! [[String: Any]]
        XCTAssertEqual(obj.map { $0["name"] as! String },
                       ["front", "front_right", "right", "back_right", "back", "back_left", "left", "front_left", "top", "front_high"])
        XCTAssertEqual(obj[0]["photoId"] as? String, Self.pid(1))
        XCTAssertEqual(obj[0]["maskUse"] as? String, "good")
        XCTAssertTrue(obj[1]["photoId"] is NSNull)
        XCTAssertNotNil(obj[1]["missingReason"] as? String)
        XCTAssertTrue(obj[8]["requestedAzimuthDeg"] is NSNull)  // top: any azimuth
    }

    // MARK: - Options and output location

    func testOptions() throws {
        let o = try PackOptions.parse(["CEB6", "--data-dir", "x", "--force"])
        XCTAssertEqual(o, PackOptions(session: "CEB6", dataDir: "x", force: true))
        XCTAssertThrowsError(try PackOptions.parse([]))
        XCTAssertThrowsError(try PackOptions.parse(["a", "--nope"]))
    }

    func testOutputGoesToForClaudeAndNeverIntoSessions() throws {
        let data = URL(fileURLWithPath: "/tmp/pack-test-\(UUID().uuidString)", isDirectory: true)
        let located = LocatedSession(folder: data.appendingPathComponent("sessions/S"), dataDir: data,
                                     session: session([]), receipt: nil)
        XCTAssertEqual(try SessionLocator.outputDir(located: located).path, data.appendingPathComponent("for_claude/S").path)
        XCTAssertThrowsError(try SessionLocator.checkWritable(data.appendingPathComponent("sessions/S/for_claude"), located: located))
        XCTAssertThrowsError(try SessionLocator.checkWritable(data.appendingPathComponent("incoming/x"), located: located))
    }
}
