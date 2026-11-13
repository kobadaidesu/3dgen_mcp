# AGENTS.md

このリポジトリで作業する AI エージェント（Claude Code・Codex など）と、引き継ぐ人向けのメモです。人向けの短い説明は [README.md](README.md) にあります。

## 目的と範囲

子どもの絵や工作を 3D モデルにするときの **入力の写真をそろえる** ためのリポジトリです。iPhone のアプリで作品のまわりを撮り、同じネットワークの Mac へ送り、AI エージェントが読みやすい形にまとめるところまでを持ちます。

- **3D の生成そのものは範囲の外です。** 生成は、Claude Code・Codex などの AI エージェントが、ここで作ったデータを読んで行います。生成のアルゴリズムや特定の生成サービスへの接続は、このリポジトリに入れません。
- 例外として、**平らな作品（貼り絵・紙に描いた絵）を写真 1 枚から GLB にするツール** `tools/flat-art-glb/` を置いています（ユーザーが決めたもの）。撮影アプリや `for_claude/` の流れとはつながっておらず、写真 1 枚と設定ファイルから単独で動きます。立体の作品の生成は、引き続き範囲の外です。
- 今の方針（ユーザーが決めたもの）は **「AI に推論させながら作る」** です。底の中心を決めてから、正面・右・後ろ・左の 4 方向と、最後に真上から撮る **5 枚の撮影（`ai5`）** を、新しいセッションの既定にしています。数枚のよい写真から AI が形を推論する前提なので、写真どうしの重なりは要りません。
- 新しいセッションを作るときに、撮る人が作品の種類を選びます。**立体（工作・粘土など）** は上の `ai5`、**平面（絵・貼り絵など）** は真上から 1 枚（`flat1`）です。どちらにするかは人が決め、アプリは自動で見分けません。
- 48 方向の写真測量向けの撮影（`photogrammetry`）や Mac での写真測量のツール（`tools/reconstruct/`）は、実験のために残しています。今の主な流れではありません（下の「決めたこと・分かったこと」）。

## 構成

| ディレクトリ | 中身 | 役割 |
|---|---|---|
| `ios/MemoriaCapture/`・`ios/MemoriaCapture.xcodeproj` | iPhone のアプリ（Swift・SwiftUI・ARKit・Vision。iOS 17 以上、外部のライブラリなし） | 撮影の案内・高解像度の写真（`ARSession.captureHighResolutionFrame()`）とカメラの情報の保存・作品マスクの作成と確かめ・平面の作品の用紙の検出と遠近の補正・確認画面・Mac への送信。`App/`・`UI/`・`AR/`・`Analysis/`・`Storage/`・`Transfer/` に分けている。平面の作品の撮影は `AR/FlatCaptureController.swift`・`UI/FlatCaptureView.swift`・`Analysis/SheetDetection.swift` |
| `ios/Packages/CaptureCore/` | SwiftPM のパッケージ（Foundation・simd・CryptoKit だけ） | アプリの「純粋なロジック」：session.json の型、撮影方向の一覧（`DirectionPlan`）、角度と投影の計算、撮影の進み具合、マスクの範囲と確かめ、平面の作品の計算（`FlatCapture.swift`：四隅の並べ方・実寸・案内・自動撮影）、転送、同じネットワークかの判定（`LocalNetworkPolicy`）。macOS の `swift test` で確かめられる。Mac のツールもこの型を使う。確認用の `capture-e2e`（合成セッションを受信サーバーへ送る）もここ |
| `receiver/` | Python 3.9 以上（標準ライブラリだけ） | Mac の受信サーバー `memoria_receiver.py`。同じネットワークからの接続だけを受け、`captures/` に保存する。受け取るたびに `memoria-pack` を裏で動かす |
| `tools/claude-pack/` | Swift（macOS 14 以上） | `memoria-pack`。受け取ったセッションから AI 向けの入力 `captures/for_claude/<sessionId>/` を作る（平面の作品は、まっすぐにした絵と紙の実寸だけ） |
| `mcp-server/` | Python（MCP の SDK は uv が入れる。中身の `memoria_core.py` は標準ライブラリだけ） | Claude Code・Codex から撮影データを読む MCP サーバー（`list_sessions`・`get_brief`・`get_view` など） |
| `tools/reconstruct/` | Swift（Apple シリコンの Mac、macOS 14 以上） | `memoria-reconstruct`。RealityKit の `PhotogrammetrySession` で写真から USDZ を作る実験用のツール |
| `tools/flat-art-glb/` | Python（numpy・OpenCV・mapbox_earcut）。確かめには Node.js（three・gltf-validator）と Playwright | 平らな作品の写真 1 枚から GLB を作る関数の集まりとコマンド（`flatart_glb.py`）。撮影の流れとは別に単独で動く。説明は `tools/flat-art-glb/README.md` |
| `docs/` | 取り決め | `data-format.md`（session.json の形・座標・画像の向き・撮影方向の一覧・マスクの確かめ）、`transfer-protocol.md`（iPhone → Mac の転送の手順と、同じネットワークの中だけにする決まり） |
| `captures/` | 受け取ったデータ（git に入らない） | 受信サーバーが作る。読み方は受信サーバーが起動のたびに書き直す `captures/README.md` |

session.json の形は [docs/data-format.md](docs/data-format.md) が正です。iPhone・受信サーバー・Mac のツールは同じ形を読み書きします。項目を足すときは、無くても読めるようにして `schemaVersion` を 1 のままにしてきました（足した項目はどれも「後から足した項目」と書いてある）。

## 撮影から AI に渡るまでの流れ（立体：`ai5`）

1. Mac で受信サーバーを起動します。ペアリングコード（6 桁）と接続先の URL が出ます。
2. iPhone と Mac を同じネットワーク（自宅の Wi-Fi・USB ケーブル・iPhone のインターネット共有）につなぎ、アプリの「設定」で送り先（Bonjour の一覧か、URL の手入力）とペアリングコードを入れて「接続を確認」を押します。
3. 「新しく撮る」で作品名を入れ（AI が何の物かを知る手がかりになります）、作品の種類で **「立体（工作・粘土など）」**（既定）を選びます。平面の作品は下の「平面の作品の流れ」です。
4. 底の中心に印を合わせて「ここが底の中心」を押し、円柱のガイドの高さと半径を作品に合わせ、「基準を確定」を押します。印は ARKit の平面（黄色）、机の特徴点から推定した高さ（水色）、iPhone の下端を机に当てて測った高さ（紫）の順に使います。「底の高さ ▼▲」で 0.5 cm ずつ直せます。
5. 正面を手動で撮ります（**この方向がデータの「正面」になります**）。続けて近い方の横から右・後ろ・左（またはその逆）を仰角 15° 前後で撮り（条件がそろうと自動で撮る）、最後に真上（仰角 75° 以上、向きは問わない）を撮ります。画面には「n / 5」が出ます。
6. 確認画面で写真と切り抜きを見て、「送信」を押します。
7. Mac では、完了したセッションが `captures/sessions/<sessionId>/` に入り、続けて `captures/for_claude/<sessionId>/` が作られます（`tools/claude-pack` を release でビルドしてあるときだけ）。AI エージェントの入口は **`captures/for_claude/<sessionId>/brief.md`** です。

## 平面の作品の流れ（`flat1`）

1〜2 は立体と同じです。

3. 「新しく撮る」で作品名を入れ、**「平面（絵・貼り絵など）」** を選びます。画面には見分ける手がかり（横から見るとほぼ紙だけの物）を出しますが、決めるのは撮る人です。
4. 底の中心・円柱の設定はありません。iPhone を作品の真上に持ち、紙の全体を画面に入れます。Vision（`VNDetectRectanglesRequest`）が見つけた紙の輪郭が画面に出ます（撮れる状態なら緑）。
5. 輪郭が止まり、iPhone の傾きが 70° 以上（ほぼ真上）、紙が画面の端にかかっていないと、0.8 秒で自動で撮ります（自動撮影はオフにもできる）。シャッターはいつでも押せます（紙が見つからない・真上でないときも撮れる。撮ったあとに知らせる）。画面には「1 / 1 撮りました」と、紙が見つからない・端にかかっている・真上でない・測った大きさが出ます。
6. 撮った高解像度の写真で紙を見つけ直し、ARKit の平面に四隅を当てて実寸を測り（平面が無ければ大きさは null）、遠近を直した画像（`rectified/<photoId>.jpg`）を作ります。元の写真はそのまま保存します。マスクは作りません。
7. 確認画面（1/1）で写真を見て「送信」を押します。撮り直すと一番新しい写真が代表になります。
8. Mac の `for_claude/<sessionId>/` には `brief.md`（平面の作品で、3D の再構成は要らない、紙の実寸か「分かりません」）、`views/artwork.jpg`（まっすぐにした絵。直せなかったときは写真をまっすぐに回したもの）、補正したときは `views/photo.jpg`、`measurements.json`（`sheet`）、`pack.json`（`workKind: "flat"`）が入ります。`overview.jpg`・`hull.obj` はありません。

session.json の形（`workKind`・`photos[].flat`）は [docs/data-format.md](docs/data-format.md) の「平面の作品」です。

## 立体のパックの中身

`ai5` のセッションの `for_claude/` には、`brief.md`、`overview.jpg`（3 × 3 の一覧）、`views/{front,right,back,left,top}.jpg`（まっすぐに回し、作品のまわりで切り出した背景付きの写真）、`measurements.json`、`pack.json` が入ります。`ai5` では visual hull を作らないので `hull.obj` はありません。中身の詳しい説明は [tools/claude-pack/README.md](tools/claude-pack/README.md) です。

## 起動と確認

コマンドはリポジトリの一番上から書いています（`cd` のあるものを除く）。

```sh
# 受信サーバー（ポート 8765、保存先 captures/。止めるときは Ctrl-C）
python3 receiver/memoria_receiver.py
python3 receiver/memoria_receiver.py list                       # 受け取ったセッションの一覧
python3 receiver/memoria_receiver.py show <sessionId の先頭>     # 1 つのセッションの写真ごとの情報

# AI 向けの入力を作るツール（受信サーバーが自動で使うのは release のビルド）
(cd tools/claude-pack && swift build -c release)
tools/claude-pack/.build/release/memoria-pack <sessionId の先頭> --force             # 作り直す
tools/claude-pack/.build/release/memoria-pack <sessionId の先頭> --force --cutouts   # 背景を透明にした PNG も作る

# 写真測量（実験用）
(cd tools/reconstruct && swift run -c release memoria-reconstruct <sessionId の先頭> --detail preview)
```

受信サーバーのオプション（`--port`・`--data-dir`・`--no-bonjour`・`--allow-remote`・`--reset-code` など）は [receiver/README.md](receiver/README.md) にあります。

テスト（どれも Mac の中だけで動き、受信サーバーのテストは空いているポートと一時フォルダを使います）：

```sh
(cd ios/Packages/CaptureCore && swift test)
(cd tools/claude-pack && swift test)
(cd tools/reconstruct && swift test)
python3 -m unittest discover -s receiver/tests
python3 -m unittest discover -s mcp-server/tests
python3 -m unittest discover -s tools/flat-art-glb/tests   # numpy・OpenCV・mapbox_earcut が要る
```

iPhone のアプリのビルド：

```sh
# 署名なしでビルドが通るかの確認（実機は要らない）
xcodebuild -project ios/MemoriaCapture.xcodeproj -scheme MemoriaCapture \
  -destination 'generic/platform=iOS' -configuration Debug CODE_SIGNING_ALLOWED=NO build
```

実機に入れるとき：

1. iPhone を Mac にケーブルでつなぎ、ロックを解除します。iPhone の「デベロッパモード」をオンにしておきます（再起動のあとの確認で「オンにする」を押すまでがひとまとまり）。
2. 初めてのときは、`ios/Config/Local.xcconfig.example` を同じフォルダに `Local.xcconfig` としてコピーし、`DEVELOPMENT_TEAM =` のあとに **自分の Team ID** を書きます（調べ方は example の中に書いてあります）。署名の Team は `ios/Config/Signing.xcconfig` がこのファイルから読みます。`Local.xcconfig` は `.gitignore` に入っていて、コミットされません。`project.pbxproj` には Team を書かないので、Xcode の「Signing & Capabilities」で Team を選び直さないでください（選ぶと `project.pbxproj` に書き込まれます）。Bundle Identifier が使えないと出たら末尾を変えます。
3. 次のコマンドでビルドして入れます。`<UDID>` は `xcrun devicectl list devices` の Identifier の列です。`ios/DerivedData/` は git に入りません。

```sh
xcrun devicectl list devices
xcodebuild -project ios/MemoriaCapture.xcodeproj -scheme MemoriaCapture \
  -destination 'id=<UDID>' -configuration Debug -derivedDataPath ios/DerivedData \
  -allowProvisioningUpdates build
xcrun devicectl device install app --device <UDID> ios/DerivedData/Build/Products/Debug-iphoneos/MemoriaCapture.app
```

- 初めて署名するときは、Mac で codesign がキーチェーンの鍵を使う許可を求めます（Mac のログインのパスワードを入れて「常に許可」）。コマンドからだと `errSecInternalComponent` で止まることがあり、そのときは Xcode の ▶ で一度実行します。
- iPhone で「信頼されていないデベロッパ」と出たら、「設定 > 一般 > VPN とデバイス管理」で自分の開発元を信頼します。
- `devicectl` で iPhone が `unavailable` のときは入れられません。ケーブルでつなぎ直し、ロックを解除します。
- 送信の流れは、`capture-e2e` で実機なしに確かめられます。8765 で動いている受信サーバーとは別のポートと一時フォルダで受信サーバーを立てて、`(cd ios/Packages/CaptureCore && swift run capture-e2e http://127.0.0.1:<port> <ペアリングコード>)` を実行します（受信サーバーの `--host 127.0.0.1 --no-bonjour --data-dir <一時フォルダ>`。`--fail-put-every N` で再送も確かめられる）。`--flat` を付けると、平面の作品の合成セッション（真上の写真 1 枚・紙の四隅・実寸・補正した画像）を送ります。受信サーバーは受け取るたびに release の `memoria-pack` を動かすので、続けて `for_claude/` も確かめられます。

## 決めたこと・分かったこと

白いマウス（Logitech G Pro X Superlight、実物は約 12.5 × 6.4 × 4.0 cm）を撮ったセッションで、生成の方法を比べました。生成は範囲の外ですが、ここで作る入力が役に立つかを確かめるためです。

| 方法 | 結果 |
|---|---|
| 写真測量（`tools/reconstruct`、Mac の `PhotogrammetrySession`） | 1 周 8 方向では形にならない（机の天板だけ）。48 方向の撮影（53 枚）で 48 枚の位置が決まり、medium で約 21 秒。マウスと分かる形だが、なめらかすぎて黒いムラがあり、底は無い。白く模様の無い物は苦手。ARKit のカメラの姿勢と K は渡せない（写真から推定し直す） |
| Claude Code が写真を見て Blender のスクリプトで組み立てる（2 分） | 約 53 秒。卵形や円柱の組み合わせで、質は低い。`for_claude/` だけを渡した別のエージェントは 24 秒で、質は同程度。寸法は実測に基づくようになった |
| Hunyuan3D-2.1（Mac の中、写真 1 枚） | 生成 96 秒、全体で約 2 分 10 秒、メモリは最大約 23 GB。手元の方法の中では形が一番良いが、色は付かない。幅が約 1 割広い |
| Tripo（クラウド、Web 版、写真 1 枚） | 一番良い。形と色が一度に出る。約 2 分半〜3 分、約 197 万面と重い。写っていない部分は想像で作る。無料のプランでは作ったモデルが公開になる |
| Tripo のマルチビュー（前・左・右・背面） | Web 版の無料のプランでは使えない（有料プランが要る）。API にはマルチビューがあるが、試していない（API の残高は Web 版のクレジットと別。チャージとキーが要る） |
| AI エージェントに 14 分で作らせる（48 方向の輪郭から形を削り、写真の色を投影） | 約 15.5 分かかり、5.5 × 4.0 × 12.0 cm と小さめ。表面はでこぼこで、色はぼやけて二重。写真測量と同じくらいの質 |

分かったこと：

- 入力のデータ（方向別の写真・切り抜き・実寸・向き）は役目を果たしていて、品質を決めているのは生成の方法です。生成 AI（物の形の知識で補う）が強い、という結果でした。役割は「撮影アプリと `for_claude/` が入力をそろえる → AI エージェントが写真を選んで整え、生成を頼み、できたモデルを実寸と向きに合わせて確かめる → 生成 AI が形と色を作る」が合っていそうです。
- ARKit のカメラの姿勢は、写真ごとに数 mm ずれます。撮影の案内や切り抜きには十分ですが、輪郭を重ねると形が痩せ、色を投影すると二重になります。
- 底の位置（基準点）は、方法によって数 mm〜数 cm ずれます（iPhone の下端で測ったセッションでは約 2 cm 低かった）。48 方向のセッションでは `memoria-pack` が hull から机の面を推定し直します。
- 以上を受けて、ユーザーが **「AI に推論させながら作る」** 方針に切り替え、既定の撮影を `ai5` にしました。
- 背景を消した写真（cutout）は既定では作りません。読み手は写真を見る AI で、背景付きの写真で作品を見分けられるためです。要るときだけ `memoria-pack --cutouts` で、iPhone のマスクから透明な PNG を作ります。
- iPhone ではマスクを作り続けます（作品が写っているかの確認に使う）。ただし `ai5` で撮り直させるのは **はっきり失敗したときだけ** です（作品が見つからない・マスクの大半が作品の外など。決まりは [docs/data-format.md](docs/data-format.md) の「マスクの確かめ」）。マスクの確かめのしきい値（`MaskCheckThresholds`）は、マウスの撮影だけで決めた値です。
- 作品の種類（立体・平面）は **撮る人が選びます**。紙に毛糸を貼った絵のような中間の作品を自動で見分ける仕組みは作らない、とユーザーが決めました。
- 平面の作品はマスクを作りません（紙の四隅が作品の範囲の代わり）。撮り直しもマスクでは決めず、真上の写真が 1 枚あればそろったとみなします。紙が見つからない・端にかかっている・真上でない写真は「気になる写真」に出すだけで、撮る・送るのは止めません。
- 平面の作品の大きさは、ARKit の平面に四隅を当てて **測れたときだけ** 書きます。測れなければ null で、`brief.md` も「分かりません」と書きます。影・照り返しの検出は範囲の外です。
- `ai5` の大きさは **おおよそ** です。使えるマスクが 8 枚未満では visual hull を作らず、撮影のときに合わせた円柱の大きさを `status: "approximate"`・`confidence: "low"` で書きます。

## 守ること

- **転送は同じネットワークの中だけ。** 通信は暗号化しない HTTP です。この Mac は公開 IPv4 が直接付くネットワークにいたことがあり、そのとき 0.0.0.0 で待ち受けていた受信サーバーにインターネットのスキャナーが届きました。それ以来、受信サーバーはループバック・プライベート・リンクローカル・IPv6 の ULA からの接続だけを受け、iPhone も公開アドレスへは送りません（[docs/transfer-protocol.md](docs/transfer-protocol.md)）。この判定をゆるめる変更をしないでください。`--allow-remote` はふだん使いません。Mac に公開アドレスしか無いときは、USB ケーブルか iPhone のインターネット共有でつなぎます。
- **`captures/sessions/` に書き込まない。** 元のデータです。派生データは `for_claude/`・`reconstructions/` などの別のフォルダに作ります（ツールも `sessions/`・`incoming/` への出力を断ります）。
- **`captures/incoming/` を読まない・使わない・消さない。** 転送の途中のデータで、受信サーバーが使います。
- **`captures/.receiver.json` の中身を出さない。** ペアリングコードと受信機の ID が入っています。ペアリングコードや接続先の IP アドレスをファイル・コミット・PR・チャットに書かないでください。
- **画像を外部に送るのはユーザーが決めること。** 写真は子どもの作品や身の回りを写した個人のデータです。受信サーバーとツールは外へ何も送りません。画像や session.json をクラウドの AI・生成サービスに渡すのは外部への送信なので、ユーザーがはっきり頼んだときだけにします。
- **秘密の値をコミットしない。** API キー・`.env`・パスワード・ペアリングコード・端末の UDID・メールアドレスなどです。**このリポジトリは公開です**（GitHub の `kobadaidesu/3dgen_mcp`）。ホームディレクトリの絶対パスも、リポジトリからの相対パスで書けるときは書きません。
- **Team ID のような、Mac や人ごとに違う値は、git に入らないローカルのファイルに書く。** 署名の Team ID は `ios/Config/Local.xcconfig`（`.gitignore` 済み）に書き、`project.pbxproj` などコミットするファイルには書きません。ほかにも同じ種類の値を足すときは、ローカルのファイルと、空の値の example を用意します。
- **コミットメッセージや PR の説明に、AI ツールの署名（`Co-Authored-By` や「Generated with」など）を入れない。**
- **コミットメッセージは英語**（今までの履歴と同じ書き方）。ドキュメントとアプリの文言は日本語です。
- **session.json の形を変えるときは、`docs/data-format.md`・`CaptureCore` の型・受信サーバーの検証・Mac のツールを一緒に確かめる。** 足す項目は無くても読めるようにし、取れない値は推測で埋めず `null` にします。

## 作業の進め方

ユーザーの決めた進め方です。

- メインのセッションは、指示・判断・設計をします。
- 実装やそのほかの手を動かす作業は、Opus 5.5 のサブエージェントに任せます。
- メインのセッションは、サブエージェントの差分を自分で見てからユーザーに報告します（テストを自分でも実行して確かめる）。

## 未対応・予定

- **iPhone にはまだ `ai5` と平面の作品の版が入っていません。** どちらも、作ったときは `devicectl` で iPhone が `unavailable` で、入れられませんでした。ケーブルでつなぎ、ロックを解除してから、上の「実機に入れるとき」で入れます。`ai5` と平面の作品の撮影の流れは、実機ではまだ試していません。
- **平面の作品で、実機でしか確かめられないこと**：撮影画面の紙の輪郭（Vision の四角の検出と、画面の座標への変換）、自動撮影のしきい値（傾き 70° 以上・角の動き 1.5%・0.8 秒）、ARKit の平面に四隅を当てた実寸の精度（白い机・白い紙で平面が見つかるか）、`CIPerspectiveCorrection` の向き（補正した画像の上が、撮る人が画面で見ていた上になるか）。計算そのもの（四隅の並べ方・実寸・補正した画像の大きさ）は CaptureCore のテストと `capture-e2e --flat` で確かめています。
- **作品としての正面を撮影のあとで選べるようにする。** 今はデータの「正面」が最初に撮った方向で、マウスではお尻側になりました。生成 AI のマルチビューの「前」には作品の正面が要ります。それまでは、作品の正面から撮り始めてもらいます。
- **写真ごとのカメラの情報を、AI が使いやすい形で `for_claude/` に入れる。**
- **低い角度の写真を足す**（真横に近い高さからの写真。上面の形や高さを見るため）。
- **Tripo の API のマルチビュー** は試していません。API へのチャージとキーが要ります（キーはユーザーが設定し、リポジトリには入れない）。
- 撮影の途中で基準をやり直すと、同じセッションのまま撮り続けられます。作品や周りを動かしたかを聞いて、動かしたなら別のセッションに分ける案があります。
- 人の体のように間違った物しか見つからない写真では、タップで作品を選び直せません（撮り直すしかない）。
- `captures/for_ai/` は、48 方向のセッションから 5 枚を手で抜き出した実験用のフォルダです。ツールは作りません。
- Claude Code・Codex から使う MCP サーバーは `mcp-server/` にあります。説明は `mcp-server/README.md` を見てください。
