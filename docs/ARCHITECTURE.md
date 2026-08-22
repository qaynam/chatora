# chatora — Cosense client for Neovim

## 概要

chatora は Cosense（旧 Scrapbox）の Neovim クライアント。構成は 2 層:

1. **Lua プラグイン**（`nvim/`）— サイドバー・関連ページパネル・検索・バッファ管理などの薄い UI 層
2. **TypeScript LSP サーバー**（`packages/server`、`@chatora/server`）— `@cosense-toolbox/parser` によるハイライト（semantic tokens）・リンク補完・定義ジャンプ、および `chatora/*` カスタムリクエストで Cosense API を仲介

API クライアント・認証・diff などの純ロジックは `packages/core`（`@chatora/core`）に分離し、単体テスト可能にする。

```
┌─ Neovim ────────────────────────────────────┐
│ ┌─ sidebar ─┐ ┌─ editor (cosense://…) ────┐ │
│ │ page list │ │ 本文バッファ               │ │
│ │           │ │  highlight = semantic tok │ │
│ │           │ ├─ related panel (toggle) ──┤ │
│ └───────────┘ └───────────────────────────┘ │
│        │  vim.lsp (stdio)                    │
└────────┼─────────────────────────────────────┘
         ▼
  @chatora/server (LSP, node)
         │ @chatora/core (fetch)
         ▼
  https://scrapbox.io  (PAT REST API)
```

## リポジトリ構成

```
package.json            # bun workspaces ["packages/*"]
biome.json
tsconfig.base.json
lua/chatora/*.lua       # Neovim プラグイン本体（リポジトリルート = runtimepath ルート、
plugin/chatora.lua      #   プラグインマネージャで GitHub から直接インストール可能）
packages/core/          # @chatora/core  — 純ロジック（UI/LSP 非依存、Node API 最小限）
packages/server/        # @chatora/server — LSP サーバー本体（stdio）
tests/smoke.lua         # headless スモークテスト
tests/e2e/              # 偽 Cosense サーバー + headless nvim の E2E
docs/ARCHITECTURE.md    # 本ドキュメント
```

- ランタイム: 開発は bun、サーバー実行は `node`（>=20）。ビルドは tsdown で `packages/server/dist/main.js`（単一 ESM バンドル）を生成。
- Lint/format: biome（ユーザーの他リポジトリと同じ流儀）。TS は strict。
- テスト: `bun test`（core / server の純ロジック）。

## Cosense API（公式 cosense-cli 準拠）

一次情報は https://github.com/helpfeel/cosense-cli （`src/lib/request.ts`, `src/commands/*.ts`）。
origin は既定 `https://scrapbox.io`（設定で変更可能に）。

### 認証

- ヘッダー: PAT は `x-personal-access-token: <token>`、Service Account は `x-service-account-access-key: cs_...`
- PAT 発行ページ: `<origin>/settings/personal-access-tokens`
- **資格情報の解決順**（`packages/core/src/credentials.ts`）:
  1. 環境変数 `COSENSE_PAT`
  2. macOS Keychain: `security find-generic-password -s chatora -a <origin> -w`
  3. 公式 CLI 互換 `~/.cosense/settings.json`: `users[].url` が origin に一致 → `token`（PAT）。`projects[].url` 一致 → `serviceAccount`
- ログイン保存は Keychain のみ: `security add-generic-password -U -s chatora -a <origin> -w <pat>`（`settings.json` へは書かない）
- PAT は絶対にログ・エラーメッセージ・LSP レスポンスに含めない。

### Read エンドポイント

| 用途 | エンドポイント |
|---|---|
| 自分 + userId | `GET /api/users/me` |
| プロジェクト一覧 | `GET /api/projects` |
| ページ一覧 | `GET /api/pages/:project/?sort=updated&limit=&skip=` |
| ページ本文（v2、lines に id 付き） | `GET /api/pages/v2/:project/:titleEncoded` |
| 関連ページ | `GET /api/pages/v2/:project/:titleEncoded/links1hop` / `links2hop` |
| 全文検索 | `GET /api/pages/:project/search/query?q=` |
| ベクトル検索 | `GET /api/pages/:project/search/vector/titles?q=`（HTTP 490 = 機能無効 → 空配列扱い） |
| タイトル一覧（補完用） | `GET /api/pages/:project/search/titles` |

タイトルの URL エンコードは `encodeURIComponent`。レスポンス型は寛容にパースする（未知フィールドを許容、必要フィールドだけ検証。zod は使わず手書きの narrow で十分）。

### Write（2 段階 REST、page-edit-for-ai）

1. `POST /api/pages/v2/:project/page-edit-for-ai/preview`
   - body: `{ pageId?, changes: RawChange[] }`（新規ページは pageId なし）
   - RawChange: `{_insert: <anchorLineId|'_end'>, lines: {id, text}}` | `{_update: <lineId>, lines: {text}}` | `{_delete: <lineId>}`（`_delete` に `lines` フィールドは**ない**。cosense-cli `previewEdit.ts` で実測確認済み）
   - `_insert` のアンカー = 「この行 ID の**前**に挿入」、`'_end'` = 末尾追加
   - res: `{ previewId, expireAt, pagePreview }`
2. `POST /api/pages/v2/:project/page-edit-for-ai/submit`
   - body: `{ previewId }`（**使い捨て・5 分で失効**）
   - res: `{ commitId, page: {title}|null, titleChanged?: {from,to} }`
- エラー: `409 {"error":"NotFastForward"}`（楽観ロック競合 → 再取得して再 preview）、`409 DuplicateTitle`、`422`（不正な lineId 等）
- 新規挿入行の `id` はクライアント生成の 24 桁 lowercase hex。cosense-cli 実装は `randomBytes(12).toString('hex')`（unixtime や userId は**含まない**）。`@chatora/core` の `createNewLineId()` が実装済み。
- **存在しないページは 404 にならない**: `GET /api/pages/v2/...` は HTTP 200 + `persistent: false` + 偽の id/commitId/行 id を返す。偽 id をアンカーに使うと事故るため、`CosenseApi.getPage()` は `persistent:false` を `null` に畳み込み済み。
- HTTP パス上のタイトルエンコードは encodeURIComponent ではなく cosense-cli の `encodeTitleForUrl` 方式（`% / ? #` のみ encode、空白→`_`、unicode は生）。これは `CosenseApi` 内部に実装済みで、呼び出し側は生タイトルを渡すだけでよい。**cosense:// URI スキームは従来どおり encodeURIComponent** であり別物（HTTP パスとは無関係）。

## @chatora/core 公開 API（サーバーが依存する契約）

```ts
// credentials.ts
type Credential = { type: 'pat' | 'serviceAccount'; value: string; source: 'env' | 'keychain' | 'settingsJson' }
resolveCredential(origin: string, opts?): Promise<Credential | null>
storeCredential(origin: string, pat: string): Promise<void>   // Keychain 保存
deleteCredential(origin: string): Promise<void>

// api.ts — fetch 注入可能（テスト用）
class CosenseApi {
  constructor(opts: { origin: string; credential: Credential; fetch?: typeof fetch })
  me(): Promise<Me>                       // { id, name, displayName }
  projects(): Promise<ProjectSummary[]>
  listPages(project, { skip?, limit?, sort? }): Promise<{ count: number; pages: PageSummary[] }>
  getPage(project, title): Promise<PageDetail | null>   // 404 → null。lines: {id,text}[] 必須
  relatedPages(project, title): Promise<RelatedPages>    // links1hop/links2hop
  searchFullText(project, query): Promise<SearchResult>
  searchVector(project, query): Promise<VectorResult>    // 490 → { pages: [] }
  searchTitles(project): Promise<TitleEntry[]>
  previewEdit(project, body): Promise<PreviewResponse>
  submitEdit(project, previewId): Promise<SubmitResponse>
}
// エラーは class CosenseApiError extends Error { status, code?: 'NotFastForward'|'DuplicateTitle'|... }

// changes.ts — 保存時の diff
computeChanges(base: { id: string; text: string }[], next: string[], newLineId: () => string): RawChange[]
// 行単位 diff（jsdiff の diffArrays か Myers 自前実装）。同一行の更新は _update、追加は直後アンカーの _insert、削除は _delete。

// lineId.ts
createNewLineId(userId: string): string
```

## LSP プロトコル

### 標準機能

- `textDocument/semanticTokens/full`（+ range）: parser AST → トークン。**トークンは行をまたげない**ので複数行ノード（codeBlock 等）は行ごとに分割して出す。
- `textDocument/completion`: trigger characters `[` `#`。行テキストとカーソル位置から未クローズの `[query` / `#query` を検出し、タイトルインデックスから候補を返す（NFKC + lowercase + 空白/`_` 同一視で部分一致）。textEdit で `[title]` / `#title` 全体を置換。コードブロック内・inlineCode 内では発火しない。
- `textDocument/definition`: カーソル下の internalLink / hashtag / projectLink → `cosense://<project>/<title>` の Location。
- sync: `TextDocuments` ヘルパー（incremental）。

### semantic token 型（legend の順序も contract）

`title, link, projectLink, externalLink, hashtag, code, codeBlock, formula, icon, quote, bold, italic, strike, underline, image, table`

decoration ノードは bold/italic/strike/underline のうち該当するもの 1 つを優先順 bold > italic > strike > underline で出す（MVP）。Neovim 側は `@lsp.type.<name>.cosense` に対して既定ハイライトを定義する。

### カスタムリクエスト（`chatora/*`）

すべて request（response あり）。エラーは LSP エラーではなく `{ ok: false, code, message }` を返す（Lua 側の分岐を単純にするため）。成功は `{ ok: true, ... }`。

```ts
'chatora/authStatus'  {}                          → { ok, authenticated, origin, source?, user?: Me }
'chatora/login'       { pat }                     → 検証(/api/users/me) → Keychain 保存 → authStatus と同形
'chatora/logout'      {}                          → Keychain から削除
'chatora/projects'    {}                          → { ok, projects: ProjectSummary[] }
'chatora/listPages'   { project, skip?, limit? }  → { ok, count, pages: PageSummary[] }
'chatora/openPage'    { project, title }          → { ok, uri, text, exists, pageId?, commitId? }
   // サーバーはここで base 状態（lines with ids, pageId, commitId）を uri キーで保持
'chatora/savePage'    { uri }                     → { ok: true, commitId, titleChanged?, text? }
                                                  | { ok: false, code: 'notFastForward'|'conflict'|'unauthorized'|'error', message }
   // didChange 済みの最新ドキュメント内容と base を diff → preview → submit → getPage で base を更新
   // text が返った場合はサーバー側の正規化結果（タイトル自動サフィックス等）なので Lua はバッファを置き換える
'chatora/relatedPages' { project, title }         → { ok, links1hop: RelatedPage[], links2hop: RelatedPage[] }
'chatora/search'      { project, query, mode? }   → { ok, pages: { title, lines?: string[] }[] }  // mode: 'fulltext'(既定)|'vector'
'chatora/newPage'     { project, title }          → { ok, uri, text }  // 空ページとして open（保存時に新規 preview/submit）
```

### URI スキーム

`cosense://<project>/<encodeURIComponent(title)>`。Lua/サーバー双方でこの規約を共有。パースは `vscode-uri` を使わず単純な文字列処理でよい（authority = project、path = title）。

## Neovim プラグイン仕様（nvim/）

- nvim >= 0.11 前提。依存プラグインなし（telescope/snacks 連携は後回し。picker は `vim.ui.select`、入力は `vim.ui.input`、PAT 入力のみ `vim.fn.inputsecret`）。
- `require('chatora').setup({ origin?, project?, server_cmd?, sidebar_width?, related_height? })`
- LSP 起動: `vim.lsp.start({ name='chatora', cmd={'node', <repo>/packages/server/dist/main.js, '--stdio'} , ...})`。`server_cmd` で上書き可能（開発時は `{'bun', 'run', src/main.ts}`）。sidebar バッファにも attach してカスタムリクエストを送れるようにする。
- カスタムリクエストは `client:request('chatora/xxx', params, cb)` の薄いラッパー `lsp.request(method, params): Promise 的 callback` を `lua/chatora/lsp.lua` に。

### コマンド / フロー

- `:Chatora` — 認証確認（authStatus）→ 未認証なら PAT 入力（inputsecret）→ login → プロジェクト選択（vim.ui.select、setup で固定も可）→ サイドバー表示
- `:Chatora search [query]` — 検索。結果を vim.ui.select で表示 → 選択でページを開く
- `:Chatora logout`

### サイドバー（lua/chatora/sidebar.lua）

- 左 vsplit、幅 `sidebar_width`（既定 32）、`chatora://sidebar` という名前の nofile バッファ。ページ一覧（updated 順）を 1 行 1 ページで表示。
- キーマップ（バッファローカル）: `<CR>` 開く / `R` リロード / `s` 検索 / `n` 新規ページ（タイトル入力）/ `q` 閉じる
- ウィンドウ属性: number off, cursorline on, winfixwidth。

### ページバッファ（lua/chatora/page.lua）

- `BufReadCmd cosense://*` → `chatora/openPage` → 本文流し込み → `filetype=cosense`, `buftype=acwrite`, undo リセット。
- `BufWriteCmd cosense://*` → `chatora/savePage` → 成功で `modified=false` + `vim.notify`、`notFastForward` は「リモートが更新されています。:e で再読込してから保存してください」を通知。
- 定義ジャンプ（`gd` 等の標準 LSP 機構）で `cosense://` URI に飛ぶと同じ BufReadCmd 経路で開ける。

### 関連ページパネル（lua/chatora/related.lua)

- エディタウィンドウの下に高さ `related_height`（既定 8）の split。既定は閉。`gR`（バッファローカル）または `:Chatora related` でトグル。
- 内容: `links1hop` を先頭に、`links2hop` を区切り付きで列挙。`<CR>` でそのページを開く（現在のエディタウィンドウで）。
- ページバッファを開いた/切り替えた際、パネルが開いていれば内容を自動更新。

### ハイライト（lua/chatora/highlight.lua）

`@lsp.type.<token>.cosense` に既定リンクを張る:
`title→Title, link→Underlined(+fg), projectLink→Constant, externalLink→Underlined, hashtag→Special, code/codeBlock→String系, formula→Special, icon→Identifier, quote→Comment, bold→Bold, italic→Italic, strike→@markup.strikethrough, underline→Underlined, image→Directory, table→Structure`（`default = true` でユーザー上書き可能に）。

## フェーズ

- **P1（read-only MVP）**: 認証 / サイドバー / ページ閲覧 + ハイライト / 関連ページ / 検索
- **P2（編集）**: savePage（diff → preview/submit）/ リンク補完 / 定義ジャンプ / 新規ページ
- **P3（後回し）**: 画像表示（snacks.nvim image 連携）、hover プレビュー、references（バックリンク）、rename（replace/links）、vector search UI、`chatora` ランチャーコマンド、Service Account 対応強化

## テスト戦略

- core: fetch をモック注入して API クライアント・credentials（settings.json パスは `CHATORA_SETTINGS_PATH` 環境変数で差し替え、`COSENSE_SETTINGS_PATH` もエイリアスとして有効。Keychain は `security` コマンドを exec ラッパー経由にしてモック）・computeChanges を `bun test` で。
- server: semantic tokens 変換・補完検出・URI 変換を純関数として切り出して `bun test`。
- e2e: `nvim --headless` でプラグイン読込 + `:Chatora` コマンド存在確認のスモークテスト（`nvim/tests/smoke.lua`）。実 API を叩くテストは書かない（ユーザーが実 PAT で手動確認）。

## セキュリティ / 作法

- PAT をログ・例外文字列・LSP trace に出さない。
- 資格情報ヘッダーはリダイレクト先（別 origin）に転送しない（cosense-cli と同じ方針）。
- API リクエストの失敗（401/403）は「再ログインが必要」への導線として Lua まで伝える。
- ページタイトル・本文はすべて信頼できない入力として扱う（Lua 側で `nvim_buf_set_lines` 以外の評価をしない。コマンド組み立てに混ぜない）。
