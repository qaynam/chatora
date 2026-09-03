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
| `CONTRIBUTING.md` | 設計の要点・テストの 3 段・セキュリティ。**設計で迷ったらここ** |
| `docs/FEATURES.md` | 機能ごとの詳しい挙動（ユーザー向け） |

## 検証

変更したら必ず通します。

```sh
bun run verify   # typecheck + bun test + build + biome + smoke + E2E
```

サーバー側を変えたときは、先に `bun run build` が要ります。クライアントはサーバーのプロセスを
起動し直すだけで、ビルドまではしません。

## 決まりごと

- 作業はブランチで行い、**PR を作ります**。main へ直接は入れません
- **push する前に必ず確認を取ります**（ブランチの push も PR の作成も、勝手にやらない）
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
- `chatora/*` の応答で JSON の `null` は `vim.NIL` になり、これは **truthy** です。`lsp.request` の
  境界で `nil` に落としてあるので、その上では `if result.x then` がそのまま使えます
- `parse` / `parseLine` には必ず `parseOptions()` を渡します。渡し漏れると、カスタム記法の解釈が
  機能ごとに食い違います
- `cosense://` の URI 規則は `lua/chatora/uri.lua` と `packages/server/src/uriScheme.ts` の両方に
  あります。片方を変えたら両方を変えます。`tests/uri-parity.test.ts` が一致を確かめます
- 折り返した行の字下げ（`breakindent`）は、インデントの文字と固定の shift しか数えません。inline の
  仮想テキストは数えないので、pads が 1 行に足すセルは常に 1（中点）でなければ、折り返した行が
  本文からずれます
