# Memoria Capture

子どもの絵や工作を 3D モデルにするための **入力の写真** をそろえる、iPhone の撮影アプリと Mac の受信側のツールです。

iPhone で作品のまわりを案内どおりに撮り、写真・作品のマスク・カメラの情報（姿勢と内部パラメータ）を同じネットワークの Mac へ送ります。Mac では、Claude Code・Codex などの AI エージェントがそのまま読める形（向きをそろえて切り出した写真・一覧の画像・おおよその大きさ・説明）にまとめます。3D の生成そのものは、このデータを読んだ AI エージェントが行います（このリポジトリの範囲の外）。

新しいセッションを作るときに、作品の種類を選びます。

- **立体（工作・粘土など）**：正面・右・後ろ・左と真上の **5 枚**（`ai5`）。
- **平面（絵・貼り絵など）**：真上から **1 枚**（`flat1`）。紙の四隅を見つけて遠近を直し、測れたときは紙の実寸も記録します。AI 側では 3D の形を作らず、絵を板や額に貼る形で使えます。

どちらにするかは撮る人が決めます（アプリは自動で見分けません）。

## 3 つの部分

| 部分 | 場所 | 中身 |
|---|---|---|
| 撮影アプリ | `ios/` | SwiftUI・ARKit・Vision の iPhone アプリ（iOS 17 以上）。撮る方向と画質の案内、高解像度の写真とカメラの情報の保存、作品マスクの作成、Mac への送信。共通のロジックは SwiftPM のパッケージ `ios/Packages/CaptureCore` |
| 受信サーバー | `receiver/` | Python の標準ライブラリだけで動く Mac の受信サーバー。同じネットワーク（自宅の LAN・USB ケーブル・インターネット共有）からの接続だけを受け、`captures/sessions/` に保存する |
| AI 向けの入力を作るツール | `tools/claude-pack/` | `memoria-pack`。受け取ったセッションから `captures/for_claude/<sessionId>/`（入口は `brief.md`）を作る。受信サーバーが受け取るたびに自動で動かす |

ほかに、写真測量で 3D にしてみる実験用のツール `tools/reconstruct/` があります。また、平らな作品（貼り絵・紙に描いた絵）を写真 1 枚から GLB にするツール `tools/flat-art-glb/` があります（撮影アプリの流れとは別に、単独で動きます）。

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

## 注意

- 転送は暗号化しない HTTP なので、同じネットワークの中だけで使います。受信サーバーも iPhone も、公開 IP アドレスとはやりとりしません。
- 受信サーバーとツールは、写真を外部のクラウドに送りません。画像を AI や生成サービスに渡すかどうかは、使う人が決めます。
- `captures/` は git に入りません。

AI エージェントで作業するときの決まりと、これまでに決めたこと・分かったことは [AGENTS.md](AGENTS.md) にあります。
