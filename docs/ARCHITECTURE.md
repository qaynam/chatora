# chatora — Cosense client for Neovim

## 概要

chatora は Cosense（旧 Scrapbox）の Neovim クライアント。構成は 2 層:

1. **Lua プラグイン**（リポジトリ直下の `lua/` と `plugin/`）— サイドバー・関連ページパネル・検索・バッファ管理などの薄い UI 層
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
- **資格情報の解決順**（chatora 独自管理。cosense-cli の settings.json は読まない）:
  1. 環境変数 `COSENSE_PAT`
  2. アカウント索引の active アカウント → macOS Keychain: `security find-generic-password -s chatora -a <accountId> -w`
  3. レガシー: macOS Keychain: `security find-generic-password -s chatora -a <origin> -w`
- ログイン保存は Keychain のみ: `security add-generic-password -U -s chatora -a <accountId> -w <pat>`
- PAT は絶対にログ・エラーメッセージ・LSP レスポンスに含めない。

#### 複数アカウント

- 1 つの PAT = 1 アカウント（`{ id, origin, userId, name, displayName, photo? }`）。`id` = `` `${origin}#${userId}` `` で、Keychain の account（`-a`）にもそのまま使う。
- PAT 本体は上記の通り Keychain のみに保存する。PAT を含まないアカウント索引（メタデータ + どれが active か）は JSON ファイルに永続化する: `${CHATORA_STATE_DIR}` があればそこ、なければ `${XDG_STATE_HOME:-$HOME/.local/state}/chatora/accounts.json`（`CHATORA_STATE_DIR` はテスト用の差し替え口）。ファイルは 0600。壊れた JSON は空の索引として扱う。
  ```json
  { "active": "https://scrapbox.io#abc123",
    "accounts": [ { "id": "https://scrapbox.io#abc123", "origin": "https://scrapbox.io",
                    "userId": "abc123", "name": "qaynam", "displayName": "Qaynam", "photo": "https://..." } ] }
  ```
- `@chatora/core` の `AccountStore`（`list` / `add` / `remove` / `setActive` / `resolveActive`）がこの索引 + Keychain を仲介する。`CredentialStore.resolve` は `AccountStore.resolveActive(origin)` を上記解決順 2 段目として呼ぶ。
- 後方互換: 旧バージョンは Keychain の account = `<origin>`（上記解決順 3 段目）に PAT を持つ。このレガシーエントリを削除する移行処理はない（読めれば動く、を維持）。`chatora/login` はレガシー経路ではなく `AccountStore.add` を通る（＝アカウント追加 + active 化のエイリアス）。

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

タイトルの URL エンコードは cosense-cli の `encodeTitleForUrl` 方式（`CosenseApi` 内部で処理）。レスポンス型は寛容にパースする（未知フィールドを許容、必要フィールドだけ検証。zod は使わず手書きの narrow で十分）。

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
- HTTP パス上のタイトルエンコードは encodeURIComponent ではなく cosense-cli の `encodeTitleForUrl` 方式（`% / ? #` のみ encode、空白→`_`、unicode は生）。これは `CosenseApi` 内部に実装済みで、呼び出し側は生タイトルを渡すだけでよい。**cosense:// URI スキームは最小限エンコード（下記）** であり別物（HTTP パスとは無関係）。

## @chatora/core 公開 API（effect-ts、サーバーが依存する契約）

TS 層は effect-ts（^3.22）全面採用。サービスは Context.Tag + Layer、エラーは Data.TaggedError、
レスポンスは寛容な Schema でデコード（現行 API が受理するレスポンスをデコード失敗にしない）。

```ts
// errors.ts — throw しない。全操作が Effect<A, E, R> を返す
CosenseApiError { status: number; code?: string }   // status 0 = transport、code 'NotFastForward' 等
KeychainError / CommandExecutorError / HttpClientError

// サービス（それぞれ *Live Layer あり）
CommandExecutor  // execFile ラッパー（argv 配列、shell 文字列禁止）
HttpClient       // fetch ラッパー（テストで差し替え）
CredentialStore  // resolve(origin): Effect<Option<Credential>>（env COSENSE_PAT → AccountStore の active → レガシー Keychain）
                 // store(origin, pat) / remove(origin)（レガシー Keychain 経路。互換のため残存）
                 // CredentialStoreLive は CommandExecutor | AccountStore を要求
AccountStore     // list(): Effect<{ active: Option<string>; accounts: Account[] }>
                 // add(account, pat) / remove(id): Effect<void, KeychainError>（Keychain + 索引ファイル）
                 // setActive(id): Effect<Option<Account>> / resolveActive(origin): Effect<Option<string>>（active の PAT）
                 // AccountStoreLive は CommandExecutor を要求

// api.ts
makeCosenseApi({ origin, credential }): CosenseApiShape
// 各操作は Effect<A, CosenseApiError, HttpClient>:
// me / projects / listPages / getPage → Option<PageDetail>（404 と persistent:false は none、
// 偽 ID を絶対に漏らさない）/ relatedPages（1hop+2hop 並列）/ searchFullText /
// searchVector（490 → {pages:[]}）/ searchTitles / previewEdit / submitEdit

// 純関数（Effect で包まない）
computeChanges(base, next, newLineId): readonly RawChange[]
createNewLineId(userId): string   // 24 hex（userId は未使用、cosense-cli 互換）
```

サーバー側は initialize 時に origin を受けて ManagedRuntime を構築し、LSP コールバックの縁で
`runtime.runPromise` する。セッション状態（credential/検証結果/タイトル・vector キャッシュ/
ページ base 状態）は SynchronizedRef/Ref を持つ SessionState サービス（TTL は Clock 経由）。

## LSP プロトコル

### 標準機能

- `textDocument/semanticTokens/full`（+ range）: parser AST → トークン。**トークンは行をまたげない**ので複数行ノード（codeBlock 等）は行ごとに分割して出す。
- `textDocument/completion`: trigger characters `[` `#` ` `（スペースはクライアントが単語区切りでメニューを閉じた後の再表示用）。リンク補完は**閉じた `[...]` ペアの内側にカーソルがある時だけ**発火し、クエリはカーソル位置に依らず**ブラケット内の全文**（Cosense と同じセマンティクス）。確定時はペア全体を置換。候補の第一ソースは **vector（意味）検索** `GET /api/pages/:project/search/vector/titles?q=`（本家 Web エディタがキーストロークごとに叩いているのを HAR で実測確認。score 順・`exists:false` = 赤リンク）。ローカルのタイトルインデックス（exact > prefix > substring > asearch ファジー階層）を後段にマージし、vector が使えないプロジェクト（490/404）ではローカルのみで動く。textEdit で `[title]` / `#title` 全体を置換。コードブロック内・inlineCode 内では発火しない。`isIncomplete: true` で毎キーストローク再クエリ。
- `textDocument/definition`: カーソル下の internalLink / hashtag / projectLink → `cosense://<project>/<title>` の Location。
- sync: `TextDocuments` ヘルパー（incremental）。

### semantic token 型（legend の順序も contract）

`title, link, projectLink, externalLink, hashtag, code, codeBlock, formula, icon, quote, bold, italic, strike, underline, image, table, bold2, bold3`

decoration ノードは bold/italic/strike/underline のうち該当するもの 1 つを優先順 bold > italic > strike > underline で出す。bold は sizeLevel で段階分け: `[*]`=bold、`[**]`=bold2、`[***]` 以上=bold3（ターミナルは太さ 1 段階しかないため色で強調を段階化する）。Neovim 側は `@lsp.type.<name>.cosense` に対して既定ハイライトを定義する。

#### ユーザー定義のカスタム装飾記法（`notations`）

`lua/chatora/config.lua` の `notations`（既定 `{}`）で `[<記号> 本文]` をユーザーが自分で定義できる。
`{ ['|'] = { name = 'highlight', icon = '📌', hl = {...} } }` の形。キーは `[` の直後 1 文字、`name` は
`^[%w_]+$`、公式記法の記号（`* / - _ $ [ #`）とは衝突不可 — 違反はサーバーではなく
`config.lua` の `setup()` が `vim.notify` で警告して黙って捨てる（プラグインは落とさない）。`icon`
（任意）は 1 文字（`vim.fn.strchars`）でなければ警告してその項目だけ捨てる（`name`/`hl` は活かす）—
Neovim の extmark `conceal` が 1 文字しか置換に使えないため。`init_options.notations`
（`{ marker, name }[]`、marker 昇順）で LSP サーバーに渡す。`hl`/`icon` は渡さない（描画は Neovim
側の関心事）。

サーバー側（`packages/server/src/notations.ts`）は `@cosense-toolbox/parser` の
`bracketRule` 拡張で実装: `inner` が `<marker>` + 空白 1 文字以上で始まれば `decoration` ノード
（bold/italic/strike/underline 全部 false、sizeLevel 0、children は残りを `ctx.tokenize` で再帰
解釈）を返す。`main.ts` の `onInitialize` が `initializationOptions.notations` を検証（信頼しない
入力として、同じ規則で不正な要素を捨てる）して `setNotations()` に渡し、以後すべての
`parse`/`parseLine` 呼び出しはこの拡張込みの `parseOptions()` を渡す（渡し漏れがあると機能ごとに
装飾/リンクの解釈が食い違う）。legend は `[...TOKEN_TYPES, ...カスタム name（marker 昇順）]`。
decoration ノードのフラグが全部 false のとき、ソース上 `position.start.column + 1`（`[` の次の文字）
を設定済み marker と突き合わせて `name` を解決するロジックは `notations.ts` の
`notationNameForDecoration()` に集約し、`computeTokens`（token 型として出力。`TOKEN_TYPES` 自体は
固定のまま末尾に動的追加）と `computeConcealRanges`（下記 `ConcealRange.notation`）の双方から使う。
公式記法の記号（`* / - _`）は `markerToName` に存在しないため常に `undefined` を返す
（`RESERVED_MARKERS` がユーザー定義との衝突を防いでいる）。

### カスタムリクエスト（`chatora/*`）

すべて request（response あり）。エラーは LSP エラーではなく `{ ok: false, code, message }` を返す（Lua 側の分岐を単純にするため）。成功は `{ ok: true, ... }`。

```ts
'chatora/authStatus'  {}                          → { ok, authenticated, origin, source?, user?: { id, name, displayName, pageFilters } }
   // pageFilters = /api/users/me の保存フィルタ（[{type:'icon', value:'name'}]）。サイドバーの
   // タブが「自分のフィルタ」を解決するのに使う。
'chatora/login'       { pat }                     → 検証(/api/users/me) → AccountStore.add（アカウント追加 + active 化) → authStatus と同形
'chatora/logout'      {}                          → active アカウントを削除（+ レガシー Keychain エントリも従来通り試行）
'chatora/accounts'      {}      → { ok:true, active: string|null, accounts: Account[] }
'chatora/addAccount'    { pat } → PAT で /api/users/me を検証 → Account 組み立て → AccountStore.add（active 化）
                                   → セッションキャッシュ invalidate → { ok:true, account, accounts, active }
                                   検証失敗: { ok:false, code:'unauthorized', message:'invalid token' }
'chatora/useAccount'    { id }  → AccountStore.setActive → セッションキャッシュ invalidate → { ok:true, account, active }
                                   未知 id: { ok:false, code:'error', message:'unknown account' }
'chatora/removeAccount' { id }  → AccountStore.remove → セッションキャッシュ invalidate → { ok:true, accounts, active }
'chatora/projects'    {}                          → { ok, projects: ProjectSummary[] }
'chatora/listPages'   { project, skip?, limit?, filterType?, filterValue?, unreadOnly? }
                      → { ok, count, scanned, pages: (PageSummary & { unread })[] }
   // unread = updated > accessed（Cosense 本家のグリッドが青ボーダーを出す条件と同じ。サーバーは
   // 未読フラグを返さないのでクライアント側で計算する。accessed 欠落 = 未訪問 = 未読）。
   // filterType/filterValue は Cosense の保存フィルタ（例 'icon' / ユーザー名）をそのまま透過する。
   // unreadOnly はサーバー側フィルタが存在しないのでバッチを間引く。間引く前の件数が scanned で、
   // 呼び出し側は取得件数ではなく scanned で skip を進める（さもないと落とした分を再取得する）。
   // 既読化は openPage が `POST /api/pages/:project/:pageId/accessed`（405 等なら GET に
   // フォールバック）を投げっぱなしで行う。このエンドポイントは非公式で失敗しても無視する。
'chatora/openPage'    { project, title }          → { ok, uri, text, exists, pageId?, commitId? }
   // サーバーはここで base 状態（lines with ids, pageId, commitId）を uri キーで保持
'chatora/savePage'    { uri }                     → { ok: true, commitId, titleChanged?, text? }
                                                  | { ok: false, code: 'notFastForward'|'conflict'|'unauthorized'|'error', message }
   // didChange 済みの最新ドキュメント内容と base を diff → preview → submit → getPage で base を更新
   // text が返った場合はサーバー側の正規化結果（タイトル自動サフィックス等）なので Lua はバッファを置き換える
   // preview/submit が NotFastForward を返したら再取得 → 三方向マージ → 再 preview を 1 度だけ試みる。
   // 両側が同じ行を触っていた場合だけ code:'conflict' で止め、マージ結果を text、衝突行を conflicts で返す
'chatora/syncPage'    { uri }                     → { ok, changed, text, conflicts: MergeConflict[], meta? }
   // ポーリングと <leader>cf の実体。openPage と違い上書きではなくマージで、バッファの未保存分は
   // 残したまま base を取得結果に張り替える。changed=false ならバッファは既にマージ結果と同一
'chatora/allProjects' {}                          → { ok, projects: { name, displayName, account?, active }[] }
   // 保存済み全アカウントのプロジェクト（active なアカウントのものが先）。アカウント 1 つにつき
   // 1 リクエストなので、ユーザーが開いたピッカー専用。account が無い = 環境変数などの資格情報
'chatora/useProject'  { project }                 → { ok, project, switched?: Account, foreign }
   // プロジェクト名からアカウントを決める。まず現在のアカウントの /api/projects を見て、
   // 無ければ保存済みアカウントを順に当たり、持っていたものを active にして switched で返す。
   // どれも持っていなければ foreign（切り替えない。公開プロジェクトなら読み取り専用で読める）
'chatora/telomere'    { uri, lines: string[] }    → { ok, accessed, lines: { updated, userId }[] }
   // 行ごとの更新時刻（テロメア）。バッファの行を渡すのは、保存やマージ直後に呼ばれるため
   // didChange の到着を待つ同期文書ではズレるから。base 行と一致しない行＝ローカルの未保存分で
   // updated:0。accessed はページを開いた時点の「前回訪問」で、再取得しても動かさない
'chatora/emptyLinks'  { uri }                     → { ok, links: { line, startChar, endChar }[] }
   // 実体のないページを指す内部リンク（Cosense の赤リンク）。プロジェクトのタイトル索引
   // （60 秒キャッシュ、補完と共用）で判定するので最大 1 分遅れる
'chatora/uploadImage' { project, title, path }    → { ok, notation, url } | { ok:false, ... }
   // 行き先はプロジェクトの uploadImageTo。PAT では /api/projects/<name> が 401 なので既定は
   // GCS 側（project id は /api/projects/<name>/users から取る）。片方が失敗したらもう片方を試す
'chatora/logPath'     {}                          → { ok, path: string|null }  // 診断ログの出力先（無効なら null）
'chatora/relatedPages' { project, title }         → { ok, links1hop: RelatedPage[], links2hop: RelatedPage[] }
'chatora/search'      { project, query, mode? }   → { ok, pages: { title, lines?: string[] }[] }  // mode: 'fulltext'(既定)|'vector'
'chatora/newPage'     { project, title }          → { ok, uri, text }  // 空ページとして open（保存時に新規 preview/submit）
'chatora/urlAt'       { uri, line, character } → { ok, url: string|null }
   // カーソル位置がブラウザで開くべき URL の上にあるか。`[<画像url> <リンクurl>]` は
   // リンク側を返す（画像はレンダリング対象でしかない）。ページに解決するもの（内部リンク・
   // ハッシュタグ）と何でもない位置は null で、Lua 側は通常の定義ジャンプに落とす。
'chatora/decorations' { uri }                     → { ok, conceal: { line, startChar, endChar, notation? }[] }
   // 記法マークアップの conceal 範囲（UTF-16 列）。カーソル行の解除は Neovim の
   // conceallevel/concealcursor に任せる。外部リンクは `[label url]` / `[url label]` の
   // URL 部分と区切りの空白も隠し、本家 Cosense と同じく label だけを表示する
   // （`[url]` 単体はクリック対象が消えるので隠さない）。
   // `notation` はカスタム記法の開きマーカー側の range にだけ設定済み name が乗る（閉じ `]` 側・
   // 公式記法には乗らない）。Lua 側（render.lua）はこの range の conceal 置換文字として、
   // その name に icon が設定されていればそれを、なければ従来どおり空文字（完全に隠す）を使う。
'chatora/images'      { uri }                     → { ok, images: ImageTarget[] }
   // ImageTarget = { line, startChar, src, kind: 'image'|'icon', iconUser?, standalone }
   // （line/startChar は UTF-16 列、chatora/decorations と同じ単位）。パーサーの image/icon
   // ノードを visit で収集する。image は asImageSrc で解決した src（gyazo の裸 URL は
   // https://i.gyazo.com/<hash>.png に正規化、#.svg 等のフラグメントはそのまま）。icon は
   // URL を組み立てず iconUser（`[/proj/name.icon]` は '/proj/name' 形式のまま）だけを返す。
   // standalone は、そのノードが行（または title 行）の直接の子として唯一の非空白コンテンツ
   // であるとき true（decoration 記法にネストしている場合は false）。
   // 注意: パーサーの `isImageUrl` は `#.png` 等の接尾辞だけで判定しスキームを見ないため、
   // `[?userId=…#.svg]` `[/relative.png]` `[javascript:…#.png]` もすべて image ノードになる。
   // 絶対 http(s) URL 以外は images.ts で対象から外し、fetchAsset 側でも再度拒否する
   // （ページ本文は信頼できない入力であり、ここが唯一ネットワークを触る境界のため）。
'chatora/fetchAsset'  { project, url, border? }   → { ok, path }  // url を取得しローカルキャッシュ（$XDG_CACHE_HOME/chatora/assets）のファイルパスを返す。資格情報ヘッダーは url が session origin と同一のときのみ付与し、リダイレクトで origin を離れた時点で外す。content-type が image/svg+xml のときは ImageMagick で density 192 で PNG にラスタライズしてから返す（端末のグラフィックプロトコルは raster しか描けないため。失敗時/ImageMagick 不在時は元の .svg パスを返す）。border = { width, color, padding } を渡すと ImageMagick（magick/convert、無ければ素通し）で透明パディング + 枠線を画像自体に合成した PNG 変体を返す（数値は 0–64 px にクランプ、color は色リテラルのみ許可、いずれも argv 配列渡しで shell を経由しない）
   // Gyazo の URL は /api/oembed-proxy/gyazo で解決してから取りに行く（写真は url、動画は
   // thumbnail_url）。i.gyazo.com/<hash>.png の組み立てでは GIF が 404 になり、チーム Gyazo は
   // 組み立てられない。キャッシュのキーはページに書かれた URL のままなので、2 回目は解決も不要
```

### URI スキーム

`cosense://<project>/<title>`。URI はバッファ名を兼ねてタブ等に表示されるため unicode は生のまま、構造を壊す `%` `/` `?` `#` と制御文字のみパーセントエンコードする。Lua（uri.lua）とサーバー（uriScheme.ts）でバイト単位に同一の規則を共有。パースは単純な文字列処理（authority = project、path = title）で、フルエンコードされた旧形式 URI も受理する。

## Neovim プラグイン仕様（lua/ + plugin/）

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
- `BufWriteCmd cosense://*` → `chatora/savePage` → 成功で `modified=false` + cmdline echo。`conflict` はマージ結果を流し込んで衝突行に印を付け、バッファは modified のまま残す（`]c` で移動）。`:wq` が直後に `modified` を見るのでここだけ同期待ちする。
- 自動保存は `:write` を経由せず `chatora/savePage` を直接投げる（待たないのでカーソルが固まらない）。返事にはリクエスト時の `changedtick` を持たせ、その間に打鍵があればバッファ全体を代表する処理（`modified` クリア・正規化テキスト適用）は行わない。
- `BufEnter`/`FocusGained` で `chatora/syncPage`（画面に出ているバッファだけポーリング、離れると停止）。取り込みはマージなのでローカルの未保存分は消えない。
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
- e2e: `nvim --headless` でプラグイン読込 + `:Chatora` コマンド存在確認のスモークテスト（`tests/smoke.lua`）。実 API を叩くテストは書かない（ユーザーが実 PAT で手動確認）。

## セキュリティ / 作法

- PAT をログ・例外文字列・LSP trace に出さない。
- 資格情報ヘッダーはリダイレクト先（別 origin）に転送しない（cosense-cli と同じ方針）。
- API リクエストの失敗（401/403）は「再ログインが必要」への導線として Lua まで伝える。
- ページタイトル・本文はすべて信頼できない入力として扱う（Lua 側で `nvim_buf_set_lines` 以外の評価をしない。コマンド組み立てに混ぜない）。
