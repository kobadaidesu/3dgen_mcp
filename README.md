# Memoria Capture

子どもの絵や工作を 3D モデルにするための **入力の写真** をそろえる、iPhone の撮影アプリと Mac の受信側のツールです。

iPhone で作品のまわりを撮り、写真・作品のマスク（案内つきの撮り方のとき）・カメラの情報（姿勢と内部パラメータ）を同じネットワークの Mac へ送ります。Mac では、Claude Code・Codex などの AI エージェントがそのまま読める形（向きをそろえて切り出した写真・一覧の画像・おおよその大きさ・説明）にまとめます。3D の生成そのものは、このデータを読んだ AI エージェントが行います（このリポジトリの範囲の外）。

新しいセッションを作るときに、作品の種類を選びます。

- **立体（工作・粘土など）**：標準は **自由に撮る**（`guidance: "free"`）。案内も自動撮影もなく、シャッターを押すだけで何枚でも撮れます（1 枚以上で送れる）。画面には「正面・横・後ろ・真上があると作りやすい」という目安だけを出し、どの写真がどの向きかは Mac で AI が写真を見て決めます。高さが分かれば、新しく撮るときに cm で入力でき（省略できる）、AI にはその高さを使うよう伝えます。案内つきの撮り方（作品を十字に合わせて iPhone の向きで正面・右・後ろ・左・真上の 5 枚を撮る「向きで案内」、先に底の中心と円柱を合わせる前の方法）は、設定で選べます。
- **平面（絵・貼り絵など）**：真上から **1 枚**（`flat1`）。新しく撮るときに紙の大きさ（八つ切・四つ切・A4・B4・A3・B5、縦と横を入力する「その他」、または「わからない」）を選びます。紙の四隅を見つけて遠近を直し、選んだ紙があればその大きさを使います（机の平面で測れたときの実寸は補助として記録します）。AI 側では 3D の形を作らず、絵を板や額に貼る形で使えます。

どちらにするかは撮る人が決めます（アプリは自動で見分けません）。

## 3 つの部分

| 部分 | 場所 | 中身 |
|---|---|---|
| 撮影アプリ | `ios/` | SwiftUI・ARKit・Vision の iPhone アプリ（iOS 17 以上）。撮る方向と画質の案内、高解像度の写真とカメラの情報の保存、作品マスクの作成、Mac への送信。共通のロジックは SwiftPM のパッケージ `ios/Packages/CaptureCore` |
| 受信サーバー | `receiver/` | Python の標準ライブラリだけで動く Mac の受信サーバー。同じネットワーク（自宅の LAN・USB ケーブル・インターネット共有）からの接続だけを受け、`captures/sessions/` に保存する |
| AI 向けの入力を作るツール | `tools/claude-pack/` | `memoria-pack`。受け取ったセッションから `captures/for_claude/<sessionId>/`（入口は `brief.md`）を作る。受信サーバーが受け取るたびに自動で動かす |

ほかに、写真測量で 3D にしてみる実験用のツール `tools/reconstruct/` があります。また、平らな作品（貼り絵・紙に描いた絵）を写真 1 枚から GLB にするツール `tools/flat-art-glb/` があります（撮影アプリの流れとは別に、単独で動きます）。 層を積んだ形の単純な立体（箱・板・操作盤、紙皿の上に作った工作など）を数枚の写真から GLB にするツール `tools/solid-glb/` もあります。

## はじめかた

```sh
# Mac：AI 向けの入力を作るツールをビルドしてから、受信サーバーを起動する
(cd tools/claude-pack && swift build -c release)
python3 receiver/memoria_receiver.py
```

起動すると、ペアリングコードと接続先の URL が出ます。iPhone のアプリの「設定」で送り先とペアリングコードを入れ、撮影して送ると、`captures/sessions/<sessionId>/` と `captures/for_claude/<sessionId>/` ができます。iPhone へのアプリの入れ方は [AGENTS.md](AGENTS.md) の「起動と確認」にあります。

- 受信サーバーの使い方：[receiver/README.md](receiver/README.md)
- 撮影データの形（session.json・座標・画像の向き・撮影方向）：[docs/data-format.md](docs/data-format.md)
- iPhone → Mac の転送の手順：[docs/transfer-protocol.md](docs/transfer-protocol.md)
- AI 向けの入力の中身：[tools/claude-pack/README.md](tools/claude-pack/README.md)
- 写真測量のツール：[tools/reconstruct/README.md](tools/reconstruct/README.md)
- 平らな作品を GLB にするツール：[tools/flat-art-glb/README.md](tools/flat-art-glb/README.md)
- 層を積んだ形の単純な立体を GLB にするツール：[tools/solid-glb/README.md](tools/solid-glb/README.md)

## 注意

- 転送は暗号化しない HTTP なので、同じネットワークの中だけで使います。受信サーバーも iPhone も、公開 IP アドレスとはやりとりしません。
- 受信サーバーとツールは、写真を外部のクラウドに送りません。画像を AI や生成サービスに渡すかどうかは、使う人が決めます。
- `captures/` は git に入りません。

AI エージェントで作業するときの決まりと、これまでに決めたこと・分かったことは [AGENTS.md](AGENTS.md) にあります。
