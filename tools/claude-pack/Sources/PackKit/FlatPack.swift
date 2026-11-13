import Foundation
import CoreGraphics
import CaptureCore

/// Flat artwork (`workKind` "flat", plan `flat1`): one photo from straight above. The pack holds the picture itself
/// (rectified when the app found the sheet), the measured sheet size or a plain "unknown", and says that no 3D
/// reconstruction is needed. No overview grid, no hull, no masks.
extension PackBuilder {
    static let artworkViewName = "artwork"
    static let photoViewName = "photo"

    /// The photo the pack uses: not superseded (the app's rule: the latest overhead shot replaces earlier ones), shot overhead
    /// (`targetId` set), with a rectified image, with sheet corners, good saved quality, then the newest.
    public static func chooseFlatPhoto(session: CaptureSession, rectifiedExists: (Photo) -> Bool = { _ in true }) -> Photo? {
        let superseded = Set(Readiness.make(session: session).supersededPhotoIds)
        let current = session.photos.filter { !superseded.contains($0.photoId) }
        let pool = current.isEmpty ? session.photos : current
        func key(_ p: Photo) -> [Double] {
            [p.direction.targetId == nil ? 1 : 0,
             p.flat?.rectified != nil && rectifiedExists(p) ? 0 : 1,
             p.flat?.corners == nil ? 1 : 0,
             Double(SavedQualityRank.of(p)),
             -Double(p.sequence)]
        }
        return pool.min { key($0).lexicographicallyPrecedes(key($1)) }
    }

    func rectifiedExists(_ p: Photo) -> Bool {
        guard let f = p.flat?.rectified?.file else { return false }
        return FileManager.default.fileExists(atPath: url(f).path)
    }

    func writeFlat(into dir: URL, started: Date) throws -> String {
        let photo = timed("selectViews") { Self.chooseFlatPhoto(session: session, rectifiedExists: rectifiedExists) }
        var choices: [ViewChoice] = []
        var artworkSource = "none"
        try timed("views") {
            guard let photo else {
                var c = ViewChoice(name: Self.artworkViewName, label: "artwork", requestedAzimuthDeg: nil, requestedElevationDeg: 90, notes: [])
                c.missingReason = "no photo in the session"
                choices.append(c)
                return
            }
            let rotation = photo.image.displayRotationDegClockwise
            if rectifiedExists(photo), let file = photo.flat?.rectified?.file {
                var c = flatChoice(photo, name: Self.artworkViewName, label: "artwork (rectified)")
                c.cropSource = "rectified"
                try writeScaled(url(file), rotation: 0, name: Self.artworkViewName, into: dir, choice: &c)
                choices.append(c)
                artworkSource = "rectified"
                var whole = flatChoice(photo, name: Self.photoViewName, label: "photo (upright, uncorrected)")
                whole.notes = ["the original photo turned upright, perspective not corrected (for checking the rectified picture)"]
                whole.cropSource = "fullImage"
                try writeScaled(url(photo.image.file), rotation: rotation, name: Self.photoViewName, into: dir, choice: &whole)
                choices.append(whole)
            } else {
                var c = flatChoice(photo, name: Self.artworkViewName, label: "artwork (photo, not rectified)")
                c.notes.insert(photo.flat?.corners == nil
                               ? "no sheet was detected: the whole photo turned upright, perspective not corrected"
                               : "no rectified image: the whole photo turned upright, perspective not corrected", at: 0)
                c.cropSource = "fullImage"
                try writeScaled(url(photo.image.file), rotation: rotation, name: Self.artworkViewName, into: dir, choice: &c)
                choices.append(c)
                artworkSource = "uprightPhoto"
            }
        }

        var m = Measurements(sessionId: session.sessionId, status: "unavailable")
        m.workKind = WorkKind.flat.rawValue
        m.method = "flatSheetCorners"
        m.frame = [
            "units": "metres (sheet.widthCm/heightCm in centimetres)",
            "sheet": "width = the horizontal side of views/artwork.jpg, height = its vertical side",
            "thickness": "not measured (flat artwork)",
        ]
        if let photo, let size = photo.flat?.size {
            m.status = "ok"
            m.sheet = .init(widthM: round6(size.widthM), heightM: round6(size.heightM), widthCm: round1(size.widthM * 100),
                            heightCm: round1(size.heightM * 100), planeSource: size.planeSource, photoId: photo.photoId)
            m.caveats = [
                "The sheet's four corners (found by Vision in the photo) were projected onto an ARKit plane (\(size.planeSource)) and the opposite edges averaged. Expect an error of a few millimetres to about a centimetre.",
                "Only the sheet (the rectangle) is measured; parts glued on that stick out of the paper are not included, and the thickness is not measured.",
            ]
        } else {
            m.unavailableReason = photo == nil ? "no photo"
                : photo?.flat?.corners == nil ? "no sheet (rectangle) was detected in the photo"
                : "the sheet's corners could not be projected onto an ARKit plane (no plane was found)"
            m.caveats = ["The size is unknown. Do not invent one; if a size is needed, say it is a guess."]
        }
        m.seconds = 0

        let flatSource = PackIndex.FlatSource(
            photoId: photo?.photoId, sequence: photo?.sequence, corners: photo?.flat?.corners, sheetAtFrameEdge: photo?.flat?.sheetAtFrameEdge,
            rectifiedInSession: photo.flatMap { rectifiedExists($0) ? $0.flat?.rectified?.file : nil },
            artworkSource: artworkSource,
            cameraTiltFromVerticalDeg: photo?.direction.elevationDeg.map { round1(90 - $0) })
        let progress = Coverage.progress(in: session, referenceFrameId: nil)
        let bands = session.directionPlan.bands.map { band -> PackIndex.Band in
            let states = band.targets.map { progress.state(of: $0.id) }
            return PackIndex.Band(elevationDeg: band.elevationDeg, targets: states.count,
                                  shot: states.filter { $0 != .notShot }.count, done: states.filter { $0 == .done }.count)
        }
        let els = session.photos.compactMap(\.direction.elevationDeg)
        let coverage = PackIndex.Coverage(
            referenceFrameId: nil, referenceFrameIds: session.referenceFrames.map(\.id),
            photoCount: session.photos.count, photosInReferenceFrame: session.photos.filter(\.direction.confirmed).count,
            minElevationDeg: els.min().map(round1), maxElevationDeg: els.max().map(round1),
            directionPlanId: session.directionPlan.id, bands: bands,
            missingViews: choices.filter(\.isMissing).map(\.name),
            weakViews: choices.filter { !$0.isMissing && $0.name == Self.artworkViewName && !$0.notes.isEmpty }.map(\.name))

        let now = Date()
        let provenance = makeProvenance(now: now)
        timings["total"] = (now.timeIntervalSince(started) * 100).rounded() / 100
        let files = ["brief.md", "measurements.json", "pack.json"] + choices.compactMap(\.file)

        let brief = Brief.flatMarkdown(session: session, provenance: provenance, choices: choices, measurements: m, source: flatSource)
        try Data(brief.utf8).write(to: dir.appendingPathComponent("brief.md"))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(m).write(to: dir.appendingPathComponent("measurements.json"))
        let index = PackIndex(workKind: WorkKind.flat.rawValue, provenance: provenance, title: session.title, views: choices,
                              coverage: coverage, maskIssues: [], files: files, timingsS: timings, flat: flatSource)
        try encoder.encode(index).write(to: dir.appendingPathComponent("pack.json"))

        let size = m.sheet.map { String(format: "sheet %.1f × %.1f cm", $0.widthCm, $0.heightCm) } ?? "sheet size unknown"
        return String(format: "[pack] %@: flat artwork, %@ (%@), %.1fs", session.sessionId, size, artworkSource, timings["total"] ?? 0)
    }

    /// A view entry for the flat photo (angles: elevation is the camera's look-down angle; no azimuth).
    func flatChoice(_ p: Photo, name: String, label: String) -> ViewChoice {
        var c = ViewChoice(name: name, label: label, requestedAzimuthDeg: nil, requestedElevationDeg: 90, notes: [])
        c.photoId = p.photoId
        c.sequence = p.sequence
        c.targetId = p.direction.targetId
        c.azimuthDeg = nil
        c.elevationDeg = p.direction.elevationDeg
        c.distanceM = p.direction.distanceM
        if p.flat?.sheetAtFrameEdge == true { c.notes.append("a sheet corner is near the photo's edge: the sheet may be cut off") }
        if p.direction.targetId == nil, let el = p.direction.elevationDeg {
            c.notes.append(String(format: "not shot from straight above (camera %.0f° from vertical)", 90 - el))
        }
        if let q = SavedQualityRank.note(p) { c.notes.append(q) }
        return c
    }

    /// Writes `views/<name>.jpg`: the whole image turned `rotation` degrees clockwise, long side at most `CropMath.maxOutputSide`.
    func writeScaled(_ source: URL, rotation: Int, name: String, into dir: URL, choice: inout ViewChoice) throws {
        let image = try ImageOps.loadImage(source)
        let crop = PixelBox(x: 0, y: 0, width: image.width, height: image.height)
        let out = CropMath.outputSize(crop: crop, rotationDegClockwise: rotation)
        let view = try ImageOps.uprightCrop(image, crop: crop, rotationDegClockwise: rotation, width: out.width, height: out.height)
        let file = "views/\(name).jpg"
        try ImageOps.writeJPEG(view, to: dir.appendingPathComponent(file))
        choice.file = file
        choice.outputWidth = out.width
        choice.outputHeight = out.height
    }
}

extension Brief {
    /// `brief.md` for flat artwork (Japanese). Only what the app measured; a missing size is said to be unknown.
    public static func flatMarkdown(session: CaptureSession, provenance: PackIndex.Provenance, choices: [ViewChoice],
                                    measurements m: Measurements, source: PackIndex.FlatSource) -> String {
        var out: [String] = []
        let title = session.title.trimmingCharacters(in: .whitespacesAndNewlines)
        out.append("# 平面の作品の入力（\(title.isEmpty ? "作品名なし" : title)）")
        out.append("")
        out.append("**これは平面の作品（絵・貼り絵など）です。** 撮影アプリで「平面」を選んで、真上から 1 枚撮りました。"
                   + "受信した撮影セッション（`sessions/\(session.sessionId)/`）から `memoria-pack` が自動で作りました。元のセッションは変えていません。")
        out.append("")
        out.append("- 作品名（撮影アプリで入力した名前）：\(title.isEmpty ? "（空。何の作品かは書かれていません）" : "「\(title)」")")
        out.append("- **3D の形を推論・再構成する必要はありません。** `views/artwork.jpg` の絵を、薄い板（パネル）や額の表面にそのまま貼る形で使えます。")
        out.append("- 平面か立体かは、撮った人が選びました（毛糸や紙を貼った絵なども、撮った人が平面と決めたものです）。")
        out.append("")

        out.append("## 大きさ")
        out.append("")
        if let s = m.sheet {
            out.append("| 幅（絵の横） | 高さ（絵の縦） | 求め方 |")
            out.append("|---|---|---|")
            out.append("| \(f1(s.widthCm)) cm | \(f1(s.heightCm)) cm | 紙の四隅を ARKit の平面（\(planeJa(s.planeSource))）に当てて測った値 |")
            out.append("")
            out.append("- 測ったのは紙（四角）の大きさです。紙からはみ出して貼った物と、厚みは測っていません。誤差は数 mm〜1 cm ほどです。")
            out.append("- 板や額にするときは、この幅・高さに合わせてください（`measurements.json` の `sheet`）。")
        } else {
            out.append("**大きさは分かりません**（\(unavailableJa(m))）。推測で決めないでください。大きさが要るときは、推測したことをはっきり書いてください。")
        }
        out.append("")

        out.append("## 絵（`views/`）")
        out.append("")
        switch source.artworkSource {
        case "rectified":
            out.append("- `views/artwork.jpg`：撮影アプリが紙の四隅を見つけ、遠近を直してまっすぐにした絵です（紙の外は入っていません）。長い辺 \(CropMath.maxOutputSide) px 以下。")
            out.append("- `views/photo.jpg`：元の写真をまっすぐに回しただけのもの（遠近は直していない、まわりも写っている）。補正が正しいかを見比べるときに使います。")
            if let r = source.rectifiedInSession {
                out.append("- もっと細かい絵が要るときは、補正した元の大きさの画像 `sessions/\(session.sessionId)/\(r)` があります（読むだけ）。")
            }
        case "uprightPhoto":
            out.append("- `views/artwork.jpg`：**遠近を直していない**写真を、まっすぐに回したものです（"
                       + (source.corners == nil ? "撮影アプリが紙の四角を見つけられませんでした" : "補正した画像がありません")
                       + "）。紙のまわり（机など）も写っています。絵の部分を切り出して使ってください。")
        default:
            out.append("- 写真がありません。")
        }
        if source.sheetAtFrameEdge == true {
            out.append("- 注意：紙の角が写真の端に近く、**紙の一部が切れているかもしれません**。")
        }
        if let tilt = source.cameraTiltFromVerticalDeg {
            out.append("- カメラは真下から \(f0(tilt))° 傾いていました" + (tilt > DirectionPlanPreset.flatTopElevationTolerance ? "（真上ではありません。補正していない写真では形がゆがんで見えます）。" : "。"))
        }
        if let c = choices.first(where: { $0.name == PackBuilder.artworkViewName }), let id = c.photoId {
            let quality = session.photo(id: id).flatMap { p -> String? in
                guard let saved = p.quality.saved else { return "画質は未解析" }
                var parts: [String] = []
                if saved.blur != .ok { parts.append("ぶれ \(saved.blur.rawValue)") }
                if saved.brightness != .ok { parts.append("明るさ \(saved.brightness.rawValue)") }
                return parts.isEmpty ? nil : parts.joined(separator: "、")
            }
            out.append("- 元の写真：#\(c.sequence ?? 0) `\(id)`" + (quality.map { "（\($0)）" } ?? ""))
        }
        if session.photos.count > 1 {
            out.append("- このセッションの写真は \(session.photos.count) 枚です。使ったのは撮り直しの一番新しい真上の写真です。")
        }
        out.append("")

        out.append("## AI での使い方")
        out.append("")
        out.append("1. `views/artwork.jpg` を見て、何が描かれているか・色・貼った物をつかむ。")
        out.append("2. 3D にするときは、上の大きさの薄い板（または額）を作り、表面に `views/artwork.jpg` を貼る。形を推論する必要はありません。")
        out.append("3. 大きさが分からないときは、推測した大きさであることを結果に書く。")
        out.append("")
        out.append("**これらの画像を Claude やほかのクラウドのツールに渡すことは外部への送信にあたります。** 子どもの作品とまわりが写った個人の写真です。送るかどうかはユーザーが決めます。")
        out.append("")

        out.append("## 出どころ")
        out.append("")
        out.append("- sessionId：`\(provenance.sessionId)`")
        out.append("- manifestHash（`_receipt.json`）：`\(provenance.manifestHash ?? "なし")`")
        out.append("- 受信：\(provenance.receivedAt ?? "記録なし")")
        out.append("- 作成：\(provenance.generatedAt)（\(provenance.tool) \(provenance.toolVersion)）")
        out.append("- 機械で読む一覧：`pack.json`（`workKind` は `flat`、使った写真・紙の四隅）、`measurements.json`（`sheet` に紙の実寸。測れないときは null）")
        out.append("")
        return out.joined(separator: "\n")
    }

    static func planeJa(_ source: String) -> String {
        switch source {
        case "existingPlaneGeometry": return "見つかった机の平面"
        case "estimatedPlane": return "ARKit が推定した平面"
        default: return source
        }
    }

    static func unavailableJa(_ m: Measurements) -> String {
        switch m.unavailableReason {
        case "no photo"?: return "写真がありません"
        case "no sheet (rectangle) was detected in the photo"?: return "写真の中に紙の四角が見つかりませんでした"
        default: return "紙の四隅を当てる平面が見つかりませんでした"
        }
    }
}
