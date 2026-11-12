import Foundation
import CaptureCore

/// `brief.md`: a short Japanese description of the package for an AI modeller (and the person who runs it).
/// Only facts from session.json and the measurements; nothing is guessed.
public enum Brief {
    static let viewNameJa: [String: String] = [
        "front": "正面", "front_right": "右前", "right": "右", "back_right": "右後ろ",
        "back": "後ろ", "back_left": "左後ろ", "left": "左", "front_left": "左前",
        "top": "上", "front_high": "正面・高め",
    ]

    static func f1(_ v: Double?) -> String { v.map { String(format: "%.1f", $0) } ?? "—" }
    static func f0(_ v: Double?) -> String { v.map { String(format: "%.0f", $0) } ?? "—" }

    static let baseSourceJa: [String: String] = [
        "existingPlaneInfinite": "ARKit の平面（延長）",
        "existingPlaneGeometry": "ARKit の平面の形",
        "estimatedPlane": "ARKit の推定平面",
        "featurePoints": "特徴点から推定した机の高さ（数 mm〜1 cm ずれることがある）",
        "deviceEdge": "iPhone の下端を机に当てて測った高さ（機種ごとの寸法はおおよそ）",
    ]

    /// Remarks about a chosen photo, in Japanese (pack.json keeps the English `notes`).
    static func notesJa(_ c: ViewChoice, session: CaptureSession) -> [String] {
        var notes: [String] = []
        switch c.maskUse {
        case .unchecked?: notes.append("切り抜きは確かめていない（古いセッション）")
        case .unusable?: notes.append("使える切り抜きなし（切り抜く範囲は作品の円柱の投影から）")
        default: break
        }
        if let id = c.photoId, let p = session.photo(id: id) {
            if let saved = p.quality.saved {
                if saved.blur != .ok { notes.append("ぶれ \(saved.blur.rawValue)") }
                if saved.brightness != .ok { notes.append("明るさ \(saved.brightness.rawValue)") }
            } else {
                notes.append("画質は未解析")
            }
        }
        if let want = c.requestedAzimuthDeg, let az = c.azimuthDeg {
            let d = Geometry.angleDistance(want, az)
            if d > ViewSelector.weakAngleDeg { notes.append("方位が \(f0(d))° ずれ") }
        }
        if let el = c.elevationDeg {
            if c.name == "top" {
                if el < (session.directionPlan.usesStepNames ? 75 : 55) { notes.append("一番高い写真でも仰角 \(f0(el))°（真上ではない）") }
            } else if abs(el - c.requestedElevationDeg) > ViewSelector.weakAngleDeg {
                notes.append("仰角が \(f0(abs(el - c.requestedElevationDeg)))° ずれ")
            }
        }
        if c.cropSource == "projectedCylinder" { notes.append("切り抜き範囲は円柱の投影から") }
        return notes
    }

    /// The measured-size part (visual hull), or why there is none.
    static func sizeSection(_ m: Measurements, into out: inout [String]) {
        if let s = m.sizeCm {

            out.append("| 幅（X、左右） | 奥行き（Z、前後） | 高さ（Y、上下） | 誤差の目安 |")
            out.append("|---|---|---|---|")
            out.append("| \(f1(s.width)) cm | \(f1(s.depth)) cm | \(f1(s.height)) cm | ±\(f1(m.uncertainty?.plusMinusCm)) cm |")
            out.append("")
            if let f = m.footprint {
                out.append("- 上から見て一番小さく囲む長方形：\(f1(f.lengthCm)) × \(f1(f.widthCm)) cm（長い辺の向きは方位 \(f0(f.longAxisAzimuthDeg))°。0° = 前後、90° = 左右）。"
                           + "作品が正面に対して斜めに置かれていると、上の幅・奥行き（軸に沿った箱）はこれより大きくなります。")
            }
            out.append("- 求め方：基準 `\(m.referenceFrameId ?? "?")` の写真 \(m.viewsUsed) 枚の切り抜き（マスク）とカメラの位置・内部パラメータ（ARKit）から、"
                       + "ボクセル \(f1((m.grid?.voxelSizeM ?? 0) * 1000)) mm の visual hull（どの写真でも輪郭の内側に入る空間）を作り、その外接箱を測りました。")
            out.append("- 誤差の目安 ±\(f1(m.uncertainty?.plusMinusCm)) cm = ボクセル \(f1(m.uncertainty?.voxelCm)) cm ＋ 写真ごとの輪郭とのずれの中央値 \(f1(m.uncertainty?.reprojectionSlackCm)) cm。")
            if let bias = m.uncertainty?.heightOverestimateUpToCm, let h = m.sizeCm?.height {
                out.append("- 高さは大きめに出ます：写真はどれも上から見下ろしているので、上面が平らだと最大 \(f1(bias)) cm 高く出ます（丸い上面ほど小さい）。実際の高さはおよそ \(f1(max(0, h - bias)))〜\(f1(h)) cm。")
            }
            if m.confidence == "low" {
                var reasons: [String] = []
                if m.viewsUsed < 12 { reasons.append("輪郭に使えた写真が \(m.viewsUsed) 枚だけ（12 枚以上がよい）") }
                if let sl = m.uncertainty?.reprojectionSlackCm, sl > 0.5 { reasons.append("写真どうしの輪郭のずれが \(f1(sl)) cm（カメラ位置のずれか、切り抜きの誤り）") }
                if m.uncheckedMaskViews > 0 { reasons.append("確かめていない切り抜きが \(m.uncheckedMaskViews) 枚") }
                out.append("- **信頼度は低め**：\(reasons.joined(separator: "、"))。輪郭が写真どうしで合わないと実物の一部まで削られるので、上の ± を超えて小さく出ることがあります。写真と見比べてください。")
            }
            out.append("- visual hull は凹んだ所・穴・底の下を埋めるので、実物より大きめに出ます（小さくは出にくい）。")
            if let t = m.tablePlaneAboveReferenceM {
                out.append("- 高さは、hull の底の形から推定した机の面からの高さです。撮影時の基準点（底の中心）は、その机の面より \(f1(abs(t) * 100)) cm \(t >= 0 ? "下" : "上")にありました"
                           + "（基準点の求め方：\(m.baseSource.flatMap { baseSourceJa[$0] } ?? "記録なし")）。この分は直してあります。")
            } else {
                out.append("- 高さは撮影時の基準点（机の面）からの高さです（机の面を推定できませんでした。基準点の求め方：\(m.baseSource.flatMap { baseSourceJa[$0] } ?? "記録なし")）。")
            }
            if let lo = m.bboxMinM, let hi = m.bboxMaxM {
                out.append(String(format: "- 外接箱の位置（m）：x %.3f〜%.3f、y %.3f〜%.3f、z %.3f〜%.3f。原点（基準点）は作品の中心からずれていることがあります。", lo[0], hi[0], lo[1], hi[1], lo[2], hi[2]))
            }
            if let c = m.userCylinder {
                out.append("- 参考：撮影時にユーザーが AR のガイドで合わせた円柱は 半径 \(f1(c.radiusM * 100)) cm・高さ \(f1(c.heightM * 100)) cm（作品より大きめに囲む目安で、作品の大きさではありません）。")
            }
            if !m.touchesSearchBox.isEmpty {
                out.append("- 注意：形が探索範囲の端（\(m.touchesSearchBox.joined(separator: "、"))）に届いています。その向きは実物がもっと大きい可能性があります。")
            }
            out.append("- 粗い形：`hull.obj`（同じ座標・メートル。ボクセルの外側の面だけのカクカクした形）。大きさと位置合わせの下敷きに使えますが、細部はありません。")
        } else {
            out.append("実寸は求められませんでした：\(m.unavailableReason ?? "理由不明")。大きさは写真から推測するしかありません（推測したことを結果に書いてください）。")
        }
    }

    public static func markdown(session: CaptureSession, provenance: PackIndex.Provenance, choices: [ViewChoice],
                                measurements m: Measurements, coverage: PackIndex.Coverage, maskIssues: [PackIndex.MaskIssue],
                                cutouts: Bool = false) -> String {
        var out: [String] = []
        let named = session.directionPlan.usesStepNames
        func ja(_ name: String) -> String { named && name == "top" ? "真上" : viewNameJa[name] ?? name }
        let title = session.title.trimmingCharacters(in: .whitespacesAndNewlines)
        out.append("# 3D モデルを作るための入力（\(title.isEmpty ? "作品名なし" : title)）")
        out.append("")
        out.append("子どもが作った作品を iPhone で撮った写真から、AI（Claude Code など）が 3D モデルを作るときの入力です。"
                   + "受信した撮影セッション（`sessions/\(session.sessionId)/`）から `memoria-pack` が自動で作りました。元のセッションは変えていません。")
        out.append("")
        out.append("- 作品名（撮影アプリで入力した名前）：\(title.isEmpty ? "（空。何の作品かは書かれていません）" : "「\(title)」")")
        out.append("- まず `overview.jpg` を見てください（選んだ写真の一覧。カメラが立っていた位置に並べてあり、上から見た配置で正面が下、中央が上から見た写真）。")
        out.append("")

        // Size
        if m.method == "userCylinder", let s = m.sizeCm {
            out.append("## 大きさ（目安。実測ではありません）")
            out.append("")
            out.append("| 直径（幅・奥行き） | 高さ | 求め方 |")
            out.append("|---|---|---|")
            out.append("| \(f1(s.width)) cm | \(f1(s.height)) cm | 撮影時にユーザーが AR のガイドで合わせた円柱 |")
            out.append("")
            out.append("- **信頼度は低め**：輪郭（切り抜き）に使える写真が \(m.usableSilhouettes) 枚だけなので（visual hull には \(PackBuilder.minimumHullViews) 枚以上が要る）、写真からは測っていません。"
                       + "上の値は、作品をおおまかに囲むようにユーザーが目で合わせた円柱の大きさです。")
            out.append("- 作品はふつうこの円柱より小さく、上から見て丸いとは限りません（幅と奥行きは、どちらも円柱の直径です）。")
            out.append("- 高さは撮影時の基準点（作品の底の中心として測った点。求め方：\(m.baseSource.flatMap { baseSourceJa[$0] } ?? "記録なし")）からの高さです。")
            out.append("- 写真から大きさを読み取るときは、この円柱を上限の目安にし、推測した値は推測と書いてください。`hull.obj` はありません。")
        } else {
            out.append("## 大きさ（実測）")
            out.append("")
            sizeSection(m, into: &out)
        }
        out.append("")

        // Axes
        out.append("## モデルの座標")
        out.append("")
        if m.method == "userCylinder" {
            out.append("- 単位はメートル。+Y が上、原点は撮影時の基準点（作品の底の中心として測った点。y = 0 がおよそ机の面）。`measurements.json` も同じ座標です。")
        } else {
            out.append("- 単位はメートル。+Y が上、y = 0 は机の面。x・z の原点は撮影時の基準点（作品の底の中心のあたり）。`hull.obj` と `measurements.json` も同じ座標です。")
        }
        out.append("- +Z が正面（`views/front.jpg` を撮ったカメラの方向。正面の写真は −Z の向きに作品を見ている）。+X は正面から見て右。")
        out.append("- 写真の「方位」は作品のまわりの角度（0° = 正面、90° = 右、180° = 後ろ、270° = 左）、「仰角」は見下ろす角度です。")
        out.append("")

        // Views
        out.append("## 写真（`views/`）")
        out.append("")
        out.append("すべて上下をまっすぐに回し、作品のまわりを切り抜き（背景は写ったまま）、長い辺 \(CropMath.maxOutputSide) px 以下にしたものです（元の写真より大きくはしない）。"
                   + (cutouts ? "`*_cutout.png` は同じ範囲で、iPhone のマスクの外を透明にしたものです（縁は 1 px ほどぼかす）。" : "背景を消した画像は作っていません。"))
        out.append("")
        out.append("| ファイル | 向き | 方位 | 仰角 | 距離 | 写真 | メモ |")
        out.append("|---|---|---|---|---|---|---|")
        for c in choices {
            let jaName = ja(c.name)
            guard let id = c.photoId else {
                let why = c.name == "top" ? "仰角 \(f0(ViewSlot.slots(for: session).first { $0.kind == .top }?.minimumElevationDeg))° 以上の写真なし"
                    : coverage.referenceFrameId == nil ? "方向が確定した写真なし"
                    : "方位 ±\(f0(ViewSelector.ringAzimuthTolerance))°・仰角 ±\(f0(c.name == "front_high" ? 12 : ViewSelector.ringElevationTolerance))° の中に写真なし"
                out.append("| — | \(jaName)（\(c.name)） | — | — | — | — | 写真なし：\(why) |")
                continue
            }
            let files = [c.file, c.cutoutFile].compactMap { $0 }.map { "`\($0)`" }.joined(separator: "<br>")
            let dist = c.distanceM.map { String(format: "%.2f m", $0) } ?? "—"
            out.append("| \(files) | \(jaName)（\(c.name)） | \(f0(c.azimuthDeg))° | \(f0(c.elevationDeg))° | \(dist) | #\(c.sequence ?? 0) `\(id)` | \(notesJa(c, session: session).joined(separator: "、")) |")
        }
        out.append("")

        // Coverage
        out.append("## 撮れている範囲")
        out.append("")
        out.append("- 使った基準：`\(coverage.referenceFrameId ?? "なし")`（このセッションの基準：\(coverage.referenceFrameIds.isEmpty ? "なし" : coverage.referenceFrameIds.joined(separator: "、"))）。"
                   + "別の基準の写真は置き方や座標が違うことがあるので使っていません。")
        out.append("- 写真 \(coverage.photoCount) 枚のうち、この基準で方向が確定した写真 \(coverage.photosInReferenceFrame) 枚。仰角 \(f0(coverage.minElevationDeg))°〜\(f0(coverage.maxElevationDeg))°。")
        if !coverage.bands.isEmpty {
            let text = coverage.bands.map { "仰角 \(DirectionTarget.formatDegrees($0.elevationDeg))°：撮影 \($0.shot)/\($0.targets)・確かめた切り抜きあり \($0.done)" }
            out.append("- 撮影方向の一覧 `\(coverage.directionPlanId)` の段ごとのそろい方：\(text.joined(separator: "、"))")
        }
        out.append("- **底面は写っていません**（作品を机に置いて撮ったため）。底の形・色は写真にありません。")
        if !coverage.missingViews.isEmpty {
            out.append("- 写真の無い向き：\(coverage.missingViews.map { "\(ja($0))（\($0)）" }.joined(separator: "、"))")
        }
        if !coverage.weakViews.isEmpty {
            out.append("- 注意のある向き：\(coverage.weakViews.map { "\(ja($0))（\($0)）" }.joined(separator: "、"))（上の表のメモ）")
        }
        out.append("")

        // Masks
        out.append("## 切り抜き（マスク）")
        out.append("")
        if maskIssues.isEmpty {
            out.append("- すべての写真の切り抜きが使える状態です（確認済み、または自動の確かめが ok）。")
        } else {
            out.append("使えない切り抜き（実寸\(cutouts ? "にも `*_cutout.png` に" : "に")も使っていません）と、確かめていない切り抜き（`candidate` で確かめの記録が無いもの。使っていますが要注意）の写真：")
            out.append("")
            for i in maskIssues {
                let check = i.check.map { "・確かめ \($0)" } ?? ""
                let reasons = i.reasons.isEmpty ? "" : "（\(i.reasons.joined(separator: ", "))）"
                out.append("- #\(i.sequence) `\(i.photoId)`：\(i.status)\(check)\(reasons)、基準 \(i.referenceFrameId ?? "なし")、方向 \(i.targetId ?? "なし")")
            }
        }
        out.append("- 切り抜きは自動（Apple の Vision）で作ったもので、細い部分・机と同じ色の部分が欠けたり、影が入ったりすることがあります。"
                   + (cutouts ? "形は `*_cutout.png` と元の `views/<向き>.jpg` を見比べてください。" : "写真を切り抜く範囲と実寸に使っています。"))
        out.append("")

        // How to use
        out.append("## AI でモデルを作るときの使い方")
        out.append("")
        out.append("1. `overview.jpg` で全体の形・色・向きをつかむ。")
        out.append("2. 形・色・模様・細部は `views/<向き>.jpg`（\(named ? "正面・右・後ろ・左・真上" : "正面・横・後ろ・上")）で見る。写真には背景（机・まわりの物）も写っています。作品は真ん中の物です。"
                   + (cutouts ? "作品だけの輪郭は `views/*_cutout.png`（透明の PNG）でも確かめられます。" : ""))
        if m.method == "userCylinder" {
            out.append("3. 大きさは上の円柱（目安・上限）を参考に、写真から推測する。推測した大きさは結果に書く。")
        } else {
            out.append("3. 大きさは上の実測（`measurements.json` の `sizeM`）に合わせる。`hull.obj` を読み込んで、外形がその中に収まるように作ると位置と大きさがそろう。")
        }
        out.append("4. 正面は +Z、上は +Y、単位はメートル、y = 0 が机の面。")
        out.append("5. 写っていない所（底面、上の「写真の無い向き」）は推測になります。推測した部分は結果に書いてください。")
        out.append("")
        out.append("**これらの画像を Claude やほかのクラウドのツールに渡すことは外部への送信にあたります。** 子どもの作品とまわりが写った個人の写真です。送るかどうかはユーザーが決めます。")
        out.append("")

        // Provenance
        out.append("## 出どころ")
        out.append("")
        out.append("- sessionId：`\(provenance.sessionId)`")
        out.append("- manifestHash（`_receipt.json`）：`\(provenance.manifestHash ?? "なし")`")
        out.append("- 受信：\(provenance.receivedAt ?? "記録なし")")
        out.append("- 作成：\(provenance.generatedAt)（\(provenance.tool) \(provenance.toolVersion)）")
        out.append("- 機械で読む一覧：`pack.json`（写真の選び方・切り抜きの範囲・撮れている範囲）、`measurements.json`（実寸・写真ごとのずれ・注意）")
        out.append("")
        return out.joined(separator: "\n")
    }
}
