# CLAUDE.md

chatora は Cosense（旧 Scrapbox）の Neovim クライアントです。Neovim 側の Lua プラグインと、
TypeScript で書いた LSP サーバーの 2 つでできています。

## 構成

| | |
|---|---|
| `lua/chatora/` | Neovim 側。UI・キーマップ・extmark による描画・LSP クライアント |
| `packages/core/` | 認証、Cosense API クライアント、行 ID ベースの差分 |
| `packages/server/` | LSP サーバー。semantic tokens・補完・定義ジャンプ・`chatora/*` の独自リクエスト |
| `tests/smoke.lua` | headless nvim で Lua 側を通しで検証する |
| `tests/e2e/` | 偽 Cosense サーバー + headless nvim |
| `docs/ARCHITECTURE.md` | 設計と内部プロトコル。**迷ったらここが正** |
| `docs/FEATURES.md` | 機能ごとの詳しい挙動（ユーザー向け） |

## 検証

変更したら必ず通します。

```sh
bun run verify   # typecheck + bun test + build + biome + smoke + E2E
```

サーバー側を変えたときは、先に `bun run build` が要ります。クライアントはサーバーのプロセスを
起動し直すだけで、ビルドまではしません。

## 決まりごと

- コミットは **main へ直接**入れます。ブランチは切りません
- **コードのコメントは英語**、ユーザーに見える文字列は日本語で書きます
- 日本語は短く平易に、**接続詞のある文**で書きます。体言止めを並べないでください
- コメントは**コードの言い換えを書かない**こと。理由・制約・不変条件だけを書きます
- README とテストに**実名を書かない**こと。ダミーは `my-project` / `taro` / `qaynam` /
  `sakura` を使います
- `.dev/` には本物の HAR（Cookie 入り）が入っています。**絶対にコミットしない**でください
  （`.gitignore` 済み）
- 推測で断言しないこと。Neovim の挙動は headless で測れます
  （`nvim --headless --clean -u NORC -c "luafile ..."`、extmark は `nvim_buf_get_extmarks`、
  画面は `screenstring()` や `nvim__inspect_cell`）
- Cosense の API に公式ドキュメントはありません。一次情報は
  [helpfeel/cosense-cli](https://github.com/helpfeel/cosense-cli) のソースです

## よく踏む落とし穴

- `vim.treesitter.language.add` は**パーサーが無くてもエラーになりません**。戻り値で判断します
- extmark は優先度が同じなら、**あとに置いたほうが勝ちます**
- ページのタイトルは拡張子に見えることがあります（`next.js`）。filetype は `plugin/chatora.lua`
  で `cosense://` のパターンに固定してあります
- `bun.lock` は公開レジストリを指します。`bunfig.toml` の `[install] registry` で固定済みです
- 画像の描画バックエンド（image.nvim / snacks.nvim）は**任意**です。依存として固定していません
