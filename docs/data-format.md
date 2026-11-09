# 撮影データの形式（session.json schemaVersion 1）

iPhone 側と PC 側で同じ形です。1 つの撮影セッションが 1 つのフォルダになります。

```
<sessionId>/
  session.json            メタデータ（このファイルの形）
  photos/<photoId>.jpg    元写真（センサーの向きのまま。回転・縮小・切り抜きなし）
  masks/<photoId>.png     作品マスク（元写真と同じ幅・高さ・向き。8bit グレー、255 = 作品、0 = 背景）
```

- `sessionId`・`photoId` は UUID（大文字、ハイフン付き）。ファイル名に使える文字はこれだけです。
- 元写真は上書きしません。マスクは別ファイルで、マスクが無い（失敗・未生成）写真もあります。
- iPhone 側の転送状態（`transfer.json`）はセッションのフォルダにありますが、転送するファイルには入れません。

## 決まり（conventions）

`session.json` の `conventions` にも同じ内容を文字で入れます。

| 項目 | 決まり |
|---|---|
| 単位 | メートル、角度は度、時刻は ISO 8601（タイムゾーン付き）、`arFrameTimestamp` は秒（端末の起動からの時間） |
| 世界座標 | ARKit の world（`worldAlignment = .gravity`）。右手系、+Y が重力の反対（上）、原点は AR セッション開始時の端末位置。**同じ `referenceFrameId` の中でだけ意味を持つ** |
| 行列 | 入れ子の配列で **行優先**（`m[row][col]`）。点は列ベクトルで `p' = M · p` |
| `cameraToWorld` | ARKit の `ARCamera.transform`（カメラ → 世界）。カメラ座標は ARKit の決まりで、+X が保存した画像の右、+Y が画像の上、−Z が見ている方向。OpenCV 式（x 右・y 下・z 前）にするには右から `diag(1, −1, −1, 1)` を掛ける |
| `intrinsics` | 3 × 3 の K（行優先、ピクセル単位、原点は保存した画像の左上）。`intrinsicsResolution` の大きさの画像に対する値 |
| 画像の向き | 保存した画像はセンサーの向き（横長）のまま。EXIF Orientation は 1。`displayRotationDegClockwise` は、まっすぐ見るために時計回りに回す角度（表示用の情報で、K は回さない画像のもの） |
| 作品座標（objectToWorld） | 原点は作品の底面中央（基準マーカー）。+Y は上、+Z は基準点から正面のカメラへ向かう水平方向、+X = Y × Z（正面から見て右） |
| 方位角 `azimuthDeg` | 作品座標でのカメラ位置 (x, z) について `atan2(x, z)` を度にして 0〜360。0 = 正面、90 = +X 側（正面から見て右へ回り込んだ位置） |
| 仰角 `elevationDeg` | 作品の中心（基準点から `heightM / 2` 上）からカメラへのベクトルの水平面からの角度。上から見下ろすと正 |

## session.json

```jsonc
{
  "schema": "memoria.capture.session",
  "schemaVersion": 1,
  "sessionId": "8B0F…",
  "title": "ねこの貯金箱",                 // 作品名（空文字可）
  "createdAt": "2026-11-09T10:00:00+09:00",
  "updatedAt": "…",
  "conventions": { "…": "上の表と同じ内容の文字列" },
  "device": { "model": "iPhone15,4", "systemName": "iOS", "systemVersion": "26.6",
              "appVersion": "0.1.0", "appBuild": "1" },
  "object": {                              // 作品の大きさ（ユーザーが AR のガイドで合わせた値）
    "heightM": 0.15, "radiusM": 0.08, "source": "userAdjusted"
  },
  "referenceFrames": [                     // 基準を設定するたびに 1 つ増える
    {
      "id": "ref-1",
      "createdAt": "…",
      "basePointWorld": [0.1, -0.7, -0.4],
      "objectToWorld": [[1,0,0,0.1],[0,1,0,-0.7],[0,0,1,-0.4],[0,0,0,1]], // 正面が決まるまで null
      "frontPhotoId": "…",                 // 正面を決めた写真（最初の写真）。まだなら null
      "invalidatedAt": null,               // 中断・リセット・基準の再設定で無効になった時刻
      "invalidationReason": null           // "sessionInterrupted" | "trackingLost" | "userReset" | "anchorDrift"
    }
  ],
  "directionPlan": {
    "id": "ring8",
    "targets": [
      { "id": "a000-e20", "azimuthDeg": 0, "elevationDeg": 20,
        "azimuthToleranceDeg": 20, "elevationToleranceDeg": 15 }
    ]
  },
  "photos": [
    {
      "photoId": "…",
      "sequence": 1,                       // 撮影順。削除しても番号は詰めない
      "capturedAt": "…",
      "trigger": "auto",                   // "auto" | "manual"
      "referenceFrameId": "ref-1",         // 基準が無いときは null
      "image": {
        "file": "photos/<photoId>.jpg", "format": "jpeg", "width": 4032, "height": 3024,
        "exifOrientation": 1, "displayRotationDegClockwise": 90,
        "deviceOrientation": "portrait"    // 撮影時の端末の向き（UIDeviceOrientation の名前）
      },
      "camera": {                          // 写真と同じ ARFrame（captureHighResolutionFrame の返り値）から取得
        "source": "captureHighResolutionFrame",
        "arFrameTimestamp": 12345.678,
        "cameraToWorld": [[…],[…],[…],[0,0,0,1]],
        "intrinsics": [[fx,0,cx],[0,fy,cy],[0,0,1]],
        "intrinsicsResolution": { "width": 4032, "height": 3024 },
        "exposureDurationS": 0.01,         // 取れないときは null
        "exposureOffsetEV": 0.0,           // 取れないときは null
        "trackingState": "normal",         // "normal" | "limited" | "notAvailable"
        "trackingReason": null             // limited のとき "initializing" | "relocalizing" | "excessiveMotion" | "insufficientFeatures"
      },
      "direction": {
        "confirmed": true,                 // false なら方向は参考値。撮影済みの方向として数えない
        "unconfirmedReason": null,         // "trackingNotNormal" | "noReference" | "referenceInvalidated"
        "targetId": "a000-e20",            // 当てはまる撮影方向。追加撮影・範囲外は null
        "azimuthDeg": 3.2, "elevationDeg": 21.0, "distanceM": 0.42
      },
      "quality": {
        "live": {                          // シャッター直前の解析結果
          "tracking": "ok", "inFrame": "ok", "direction": "ok", "motion": "ok",
          "brightness": "ok", "sharpness": "warning",   // "ok" | "warning" | "blocked" | "unknown"
          "warningsAcknowledged": true     // 警告を確認して手動で撮ったとき true
        },
        "saved": {                         // 保存した写真そのものを解析した結果
          "meanLuma": 0.46, "sharpness": 0.0021,        // 0〜1 の明るさ、ラプラシアンの分散（縮小画像）
          "brightness": "ok", "blur": "ok"
        }
      },
      "mask": {
        "status": "candidate",             // "notGenerated" | "processing" | "candidate"（自動で選んだ・未確定）
                                           // | "confirmed"（ユーザーが確認） | "failed" | "noObject"
        "file": "masks/<photoId>.png",     // candidate / confirmed のときだけ。ほかは null
        "width": 4032, "height": 3024,
        "method": "VNGenerateForegroundInstanceMaskRequest",
        "instanceCount": 2,                // Vision が見つけた物の数（番号は写真ごとの番号で、写真間で同じ物とは限らない）
        "selectedInstances": [1],
        "selection": "auto",               // "auto" | "user"
        "error": null
      }
    }
  ]
}
```

- 取れない値は推測で埋めず `null` にします。
- 撮影に失敗した写真・保存に失敗した写真は `photos` に入りません。
- `direction.confirmed` が true になるのは、写真の `trackingState` が `normal` で、無効になっていない基準（`objectToWorld` あり）があるときだけです。
- 別の `referenceFrameId` の写真どうしの姿勢は比べられません（同じ世界座標とは限らない）。
