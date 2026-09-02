# コントリビュート

## はじめに

```sh
git clone https://github.com/qaynam/chatora
cd chatora
bun install
bun run build          # LSP サーバーを packages/server/dist/main.js に吐く
```

Neovim からは、プラグインマネージャに `dir` でこのディレクトリを指してもらえば読み込めます。

```lua
{ dir = '/path/to/chatora', cmd = 'Chatora', opts = { project = 'your-project' } }
```

## 変更したら

```sh
bun run verify
```

typecheck、`bun test`、build、biome、headless Neovim のスモークテスト、偽 Cosense サーバーを
使った E2E を順に回します。**これが通らないものは送らないでください。**

サーバー側（`packages/server`、`packages/core`）を変えたときは、先に `bun run build` が要ります。
クライアントはサーバーのプロセスを起動し直すだけで、ビルドまではしません。開発中は
`:Chatora reload` で Neovim を再起動せずに入れ替えられます。

## 書き方

- **コードのコメントは英語**、ユーザーに見える文字列は日本語で書きます
- コメントには、コードを読めば分かることではなく、**理由・制約・不変条件**を書きます
- 日本語は短く平易に、接続詞のある文で書きます
- README とテストに実名（実在のプロジェクト名・ユーザー名）を書かないでください
- Cosense の API に公式ドキュメントはありません。挙動を変えるときは
  [helpfeel/cosense-cli](https://github.com/helpfeel/cosense-cli) のソースか、実測を根拠にしてください

## 設計

全体像と内部プロトコルは [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) にあります。`chatora/*` の
リクエストを増やすときや、書き込みのプロトコルに触るときは先に読んでください。
