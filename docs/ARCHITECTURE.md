# chatora — Cosense client for Neovim

## 概要

chatora は Cosense（旧 Scrapbox）の Neovim クライアントで、2 つの層でできている。

**Lua プラグイン**（`lua/` と `plugin/`）は UI だけを持つ薄い層で、サイドバー・関連ページパネル・
検索・バッファ管理を担当する。**TypeScript の LSP サーバー**（`packages/server` =
`@chatora/server`）は、`@cosense-toolbox/parser` を使ったハイライト（semantic tokens）・リンク補完・
定義ジャンプを標準の LSP 機能として提供し、それに加えて `chatora/*` という独自リクエストで
Cosense API を仲介する。

この 2 つに挟まれる純ロジック — API クライアント、認証、行の diff — は `packages/core`
（`@chatora/core`）に分けてある。UI にも LSP にも依存しないので、単体テストで直接叩ける。

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

開発には bun を使うが、**サーバーを動かすのは `node`（>= 20）**で、bun は要らない。ビルドは
tsdown が担当し、`packages/server/dist/main.js` という単一の ESM バンドルを吐く。lint と
format は biome、TypeScript は strict、テストは `bun test` で core と server の純ロジックを回す。

## Cosense API（公式 cosense-cli 準拠）

Cosense の API に公式のドキュメントは無い。一次情報は
[helpfeel/cosense-cli](https://github.com/helpfeel/cosense-cli) のソース、とくに
`src/lib/request.ts` と `src/commands/*.ts` で、ここに書いてあることはすべてそこか実測から来て
いる。origin は既定で `https://scrapbox.io`、設定で変更できる。

### 認証

認証ヘッダーは PAT なら `x-personal-access-token: <token>`、Service Account なら
`x-service-account-access-key: cs_...`（**Bearer ではない**）。PAT の発行ページは
`<origin>/settings/personal-access-tokens`。

資格情報は chatora が独自に管理し、**cosense-cli の `settings.json` は読まない**。解決の順序は次の
とおり。

1. 環境変数 `COSENSE_PAT`
2. アカウント索引の active なアカウント →
   `security find-generic-password -s chatora -a <accountId> -w`
3. レガシー経路 → `security find-generic-password -s chatora -a <origin> -w`

保存先は macOS Keychain だけで、ファイルには書かない
（`security add-generic-password -U -s chatora -a <accountId> -w <pat>`）。

**PAT は絶対に、ログにもエラーメッセージにも LSP のレスポンスにも入れない。**

#### 複数アカウント

1 つの PAT が 1 つのアカウントに対応する（`{ id, origin, userId, name, displayName, photo? }`）。
`id` は `` `${origin}#${userId}` `` で、Keychain の account（`-a`）にもそのまま使う。

PAT 本体は上記のとおり Keychain にしか置かない。一方、**PAT を含まないアカウント索引**
（メタデータと、どれが active か）は JSON ファイルに永続化する。場所は `${CHATORA_STATE_DIR}` が
あればそこ、無ければ `${XDG_STATE_HOME:-$HOME/.local/state}/chatora/accounts.json`
（`CHATORA_STATE_DIR` はテスト用の差し替え口）。ファイルのパーミッションは 0600 で、壊れた JSON は
空の索引として扱う。
  ```json
  { "active": "https://scrapbox.io#abc123",
    "accounts": [ { "id": "https://scrapbox.io#abc123", "origin": "https://scrapbox.io",
                    "userId": "abc123", "name": "qaynam", "displayName": "Qaynam", "photo": "https://..." } ] }
  ```
この索引と Keychain の両方を仲介するのが `@chatora/core` の `AccountStore`
（`list` / `add` / `remove` / `setActive` / `resolveActive`）で、`CredentialStore.resolve` は解決順の
2 段目としてその `resolveActive(origin)` を呼ぶ。

古いバージョンは Keychain の account に `<origin>` を使って PAT を持っていた（解決順の 3 段目）。
このレガシーエントリを消す移行処理は**書かない**。読めるものは読めたままにしておく、という方針
である。`chatora/login` はレガシー経路ではなく `AccountStore.add` を通る（アカウントの追加と
active 化を兼ねる）。

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

タイトルの URL エンコードは cosense-cli の `encodeTitleForUrl` 方式に合わせてあり、`CosenseApi` の
内部で処理する。呼び出し側は生のタイトルを渡すだけでよい。

レスポンスは寛容にパースする。未知のフィールドは黙って通し、必要なフィールドだけを検証する。
Cosense の API は予告なく増えるので、知らないフィールドが来たことをデコード失敗にしてはいけない。

### Write（2 段階 REST、page-edit-for-ai）

1. `POST /api/pages/v2/:project/page-edit-for-ai/preview`
   - body: `{ pageId?, changes: RawChange[] }`（新規ページは pageId なし）
   - RawChange: `{_insert: <anchorLineId|'_end'>, lines: {id, text}}` | `{_update: <lineId>, lines: {text}}` | `{_delete: <lineId>}`（`_delete` に `lines` フィールドは**ない**。cosense-cli `previewEdit.ts` で実測確認済み）
   - `_insert` のアンカー = 「この行 ID の**前**に挿入」、`'_end'` = 末尾追加
   - res: `{ previewId, expireAt, pagePreview }`
2. `POST /api/pages/v2/:project/page-edit-for-ai/submit`
   - body: `{ previewId }`（**使い捨て・5 分で失効**）
   - res: `{ commitId, page: {title}|null, titleChanged?: {from,to} }`
エラーは 3 つある。`409 {"error":"NotFastForward"}` は楽観ロックの競合で、再取得してから preview を
やり直す。`409 DuplicateTitle` は同名ページ、`422` は不正な lineId などである。

新しく挿入する行の `id` は**クライアントが生成する** 24 桁の lowercase hex で、cosense-cli の実装は
`randomBytes(12).toString('hex')`。unixtime も userId も**含まない**。`@chatora/core` の
`createNewLineId()` がこれに合わせてある。

**存在しないページは 404 にならない。** `GET /api/pages/v2/...` は HTTP 200 を返し、
`persistent: false` と、偽の id・commitId・行 id を一緒に返してくる。この偽 id を挿入のアンカーに
使うと事故るので、`CosenseApi.getPage()` が `persistent: false` を `null` に畳み込んでいる。

HTTP パス上のタイトルエンコードは `encodeURIComponent` ではなく、cosense-cli の
`encodeTitleForUrl` 方式である（`% / ? #` だけをエンコードし、空白は `_`、unicode は生のまま）。
これは `CosenseApi` の内部にあるので、呼び出し側は生のタイトルを渡すだけでよい。後述の
`cosense://` URI スキームとは**別物**なので注意すること。

## @chatora/core 公開 API（effect-ts、サーバーが依存する契約）

TypeScript 層は effect-ts（^3.22）を全面的に使う。サービスは Context.Tag と Layer で組み立て、
エラーは Data.TaggedError、レスポンスは寛容な Schema でデコードする。**どの操作も throw せず、
`Effect<A, E, R>` を返す。**

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

サーバーは initialize で origin を受け取って ManagedRuntime を構築し、LSP のコールバックの縁で
`runtime.runPromise` する。Effect の世界と LSP の世界の境目はここだけになる。

セッション状態 — 資格情報、その検証結果、タイトルと vector のキャッシュ、ページの base 状態 — は
SessionState サービスが SynchronizedRef と Ref で保持する。TTL は Clock 経由なので、テストから
時間を進められる。

## LSP プロトコル

### 標準機能

- `textDocument/semanticTokens/full`（+ range）: parser AST → トークン。**トークンは行をまたげない**ので複数行ノード（codeBlock 等）は行ごとに分割して出す。
- `textDocument/completion`: 詳しくは下記。
- `textDocument/definition`: カーソル下の internalLink / hashtag / projectLink → `cosense://<project>/<title>` の Location。
- sync: `TextDocuments` ヘルパー（incremental）。

#### リンク補完

trigger character は `[` `#` と空白の 3 つ。空白が入っているのは、クライアントが単語の切れ目で
メニューを閉じたあとに開き直させるため。

補完が発火するのは**閉じた `[...]` ペアの内側にカーソルがある時だけ**で、クエリはカーソル位置に
関係なく**ブラケットの中身の全文**になる。これは Cosense 本家と同じセマンティクスで、確定時は
`[title]` や `#title` をペアごと textEdit で置き換える。コードブロックの中と inlineCode の中では
発火しない。

候補の第一ソースは **vector（意味）検索**の `GET /api/pages/:project/search/vector/titles?q=` で、
score 順に並び、`exists:false` は赤リンクを意味する。本家の Web エディタがキーストロークごとに
これを叩いているのを HAR で実測して合わせた。その後段にローカルのタイトル索引（exact > prefix >
substring > asearch のファジー階層）をマージするので、vector 検索が使えないプロジェクト
（490 や 404 が返る）でもローカルだけで動く。毎キーストロークで引き直すため `isIncomplete: true`
を返す。

### semantic token 型（legend の順序も contract）

`title, link, projectLink, externalLink, hashtag, code, codeBlock, formula, icon, quote, bold, italic, strike, underline, image, table, bold2, bold3`

decoration ノードは bold / italic / strike / underline のうち該当するものを 1 つだけ出す。優先順は
bold > italic > strike > underline。

bold はさらに sizeLevel で段階を分け、`[*]` が bold、`[**]` が bold2、`[***]` 以上が bold3 になる。
ターミナルには太さの段階が 1 つしか無いので、web でフォントサイズが担っている強調の段階を、
色で表すしかないためである。Neovim 側は `@lsp.type.<name>.cosense` に既定のハイライトを定義する。

#### ユーザー定義のカスタム装飾記法（`notations`）

`lua/chatora/config.lua` の `notations`（既定は `{}`）を使うと、`[<記号> 本文]` の記号をユーザーが
自分で定義できる。形は `{ ['|'] = { name = 'highlight', icon = '📌', hl = {...} } }` で、キーは `[` の
直後の 1 文字、`name` は `^[%w_]+$`、公式記法の記号（`* / - _ $ [ #`）とは衝突できない。

**違反を弾くのはサーバーではなく `config.lua` の `setup()`** で、`vim.notify` で警告してその項目
だけを捨てる。設定の誤りでプラグイン全体を落とさないためである。`icon`（任意）は 1 文字
（`vim.fn.strchars`）でなければ同じように警告して捨てるが、`name` と `hl` は活かす。1 文字に
限るのは、Neovim の extmark `conceal` が 1 文字しか置換に使えないからである。

LSP サーバーへは `init_options.notations`（`{ marker, name }[]`、marker 昇順）として渡す。`hl` と
`icon` は渡さない。どう描くかは Neovim 側の関心事であって、サーバーが知る必要はない。

サーバー側の実装は `packages/server/src/notations.ts` で、`@cosense-toolbox/parser` の `bracketRule`
拡張として書いてある。`inner` が `<marker>` + 空白 1 文字以上で始まれば `decoration` ノードを返す
（bold/italic/strike/underline はすべて false、sizeLevel は 0、children は残りを `ctx.tokenize` で
再帰的に解釈する）。`main.ts` の `onInitialize` が `initializationOptions.notations` を検証してから
`setNotations()` に渡す。クライアントから来る値は信頼しない入力なので、Lua 側と同じ規則で不正な
要素を捨てる。

**以後の `parse` / `parseLine` はすべて、この拡張込みの `parseOptions()` を渡さなければならない。**
渡し漏れると、機能ごとに装飾やリンクの解釈が食い違う。legend は
`[...TOKEN_TYPES, ...カスタム name（marker 昇順）]` になる。

decoration ノードのフラグが全部 false のとき、ソース上の `position.start.column + 1`（`[` の次の
文字）を設定済みの marker と突き合わせて `name` を解決する。このロジックは `notations.ts` の
`notationNameForDecoration()` に集約してあり、`computeTokens`（token 型として出力する。
`TOKEN_TYPES` 自体は固定で、末尾に動的追加する）と `computeConcealRanges`（後述の
`ConcealRange.notation`）の両方がここを呼ぶ。公式記法の記号（`* / - _`）は `markerToName` に無い
ので常に `undefined` が返り、`RESERVED_MARKERS` がユーザー定義との衝突を防いでいる。

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
'chatora/urlAt'       { uri, line, character } → { ok, url: string|null, play?: string }
   // play は Gyazo の動画のときだけ付く（素の Gyazo は i.gyazo.com/<hash>.mp4、チームは
   // oembed の iframe が指すプレイヤーページ）。Lua 側の `video` 設定がそれを受け取る
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
   // GIF は magick で `[0]`（先頭フレーム）を PNG に切り出してから返す。フレームを指定しないと
   // ImageMagick は 1 フレーム 1 ファイルで書き出すため、渡したパスに何も無い状態になる
   // Gyazo の URL は /api/oembed-proxy/gyazo で解決してから取りに行く（写真は url、動画は
   // thumbnail_url）。i.gyazo.com/<hash>.png の組み立てでは GIF が 404 になり、チーム Gyazo は
   // 組み立てられない。キャッシュのキーはページに書かれた URL のままなので、2 回目は解決も不要
```

### URI スキーム

`cosense://<project>/<title>` の形。この URI はバッファ名を兼ねていてタブなどに表示されるので、
unicode は生のまま残し、構造を壊す `%` `/` `?` `#` と制御文字だけをパーセントエンコードする。

同じ規則を Lua（`uri.lua`）とサーバー（`uriScheme.ts`）がバイト単位で共有している。パースは単純な
文字列処理（authority が project、path が title）で、フルエンコードされた旧形式の URI も受理する。

なお、これは HTTP パス上のタイトルエンコード（`encodeTitleForUrl`）とは**別物**である。

## Neovim プラグイン仕様（lua/ + plugin/）

nvim >= 0.11 を前提とし、**必須の依存プラグインは無い**。ページの選択は内蔵のピッカー、入力は
`vim.ui.input`、PAT の入力だけは `vim.fn.inputsecret` を使う。telescope は
`lua/telescope/_extensions/chatora.lua` に拡張を置いてあるが、あくまで任意である。画像の描画に
使う image.nvim と snacks.nvim も同じく任意で、どちらも無ければ画像を描かないだけになる。

設定は `require('chatora').setup({...})` に渡す。既定値は `lua/chatora/config.lua` の `defaults` が
唯一の正で、この文書には複製しない（増えるので必ず腐る）。

LSP は `vim.lsp.start({ name = 'chatora', cmd = { 'node', <repo>/packages/server/dist/main.js,
'--stdio' } })` で起動する。`server_cmd` で上書きでき、開発中は `{'bun', 'run', src/main.ts}` を
指すとビルドを挟まずに済む。サイドバーのバッファにも attach して、そこからカスタムリクエストを
送れるようにしてある。

カスタムリクエストは `client:request('chatora/xxx', params, cb)` の薄いラッパーとして
`lua/chatora/lsp.lua` の `lsp.request(method, params, cb)` にまとめてある。

### コマンド / フロー

コマンドの一覧は [README](../README.md#コマンド) が正で、ここには重複させない。起動時の流れだけ
書いておく。

`:Chatora` はまず `chatora/authStatus` で認証を確かめる。未認証なら `inputsecret` で PAT を受け取り、
`chatora/login` に渡して検証する。認証が済んだらプロジェクトを選び（`setup()` の `project` で固定
することもできる）、サイドバーを開く。

### サイドバー（lua/chatora/sidebar.lua）

左の vsplit に幅 `sidebar_width`（既定 32）で開く、`chatora://sidebar` という名前の nofile バッファ。
ページ一覧を updated 順に 1 行 1 ページで並べる。ウィンドウ属性は number off、cursorline on、
winfixwidth。

バッファローカルのキーマップは `<CR>` と `l` で開く、`R` でリロード、`s` で検索、`n` で新規ページ、
`P` でプロジェクト切り替え、`A` でアカウント切り替え、`q` で閉じる、`<Tab>` / `<S-Tab>` と `1`〜`9`
でタブの切り替え。

サイドバーは**今見ているページのプロジェクト**を映す。プロジェクトごとに一覧を持っておき、
別プロジェクトのバッファに移ったら、そのプロジェクトの一覧に張り替える。

### ページバッファ（lua/chatora/page.lua）

`BufReadCmd cosense://*` が `chatora/openPage` を投げ、返ってきた本文を流し込んでから
`filetype=cosense`、`buftype=acwrite` を立てて undo をリセットする。定義ジャンプ（`gd` などの標準
LSP 機構）で `cosense://` URI に飛んだときも、同じ経路で開く。

保存は `BufWriteCmd cosense://*` から `chatora/savePage`。成功すれば `modified` を下ろして
コマンドラインに知らせる。`conflict` が返った場合はマージ結果を流し込んで衝突行に印を付け、
バッファは modified のまま残す（`]c` で移動できる）。**ここだけは同期で待つ。** 直後に `:wq` が
`modified` を見るためである。

自動保存は `:write` を経由せず `chatora/savePage` を直接投げる。待たないので、保存中にカーソルが
固まらない。リクエストにはそのときの `changedtick` を持たせておき、返事が届くまでに打鍵が
あった場合は、バッファ全体を代表する処理（`modified` のクリア、正規化テキストの適用）を行わない。

`BufEnter` と `FocusGained` では `chatora/syncPage` を投げる。ポーリングするのは画面に出ている
バッファだけで、離れれば止まる。取り込みは上書きではなくマージなので、ローカルの未保存分は
消えない。

### 関連ページパネル（lua/chatora/related.lua)

エディタウィンドウに対する split で、`related_position` が `'bottom'`（既定）なら下に高さ
`related_height`（既定 8）、`'right'` なら右に幅 `related_width`（既定 40）で開く。`gR` か
`:Chatora related` でトグルする。

内容は `links1hop` を先に、`links2hop` を区切りを挟んで並べたもので、`<CR>` を押すと現在の
エディタウィンドウでそのページを開く。ページを開いたり切り替えたりしたとき、パネルが開いて
いれば内容は自動で更新される。

### ハイライト（lua/chatora/highlight.lua）

`@lsp.type.<token>.cosense` に既定のハイライトを定義する。すべて `default = true` なので、ユーザー
の colorscheme や設定が後から上書きできる。

色は colorscheme の標準グループから借りるが、**同じ色を二度使わないことを保証する**。ターミナル
のフォントには大きさの段階が無く、web でフォントサイズが担っている強調の段階を色で表すしか
ないので、リンクの色と強調の色が同じでは意味が潰れてしまうためである。

bold や italic といった属性は `Bold` や `@markup.strong` にリンクせず、直接指定する。colorscheme が
それらのグループをどう定義していても装飾が出るようにするためで、色のほうは `:colorscheme` の
たびに借り直す。

## まだ無いもの

- **hover プレビュー** — リンクの上でページの冒頭を出す
- **references（バックリンク）** — 関連ページパネルが 1hop/2hop で代替しているが、LSP の
  `textDocument/references` としては実装していない
- **rename** — ページ名の変更と、それを指すリンクの一括置換
- **Service Account** — ヘッダー（`x-service-account-access-key`）の存在は分かっているが、
  chatora が扱うのは PAT だけ

## テスト戦略

テストは 3 段ある。

**core と server の単体テスト**（`bun test`）は純ロジックを直接叩く。`HttpClient` と
`CommandExecutor` がサービスとして分かれているのは、ここで fetch と `security` コマンドを差し替え
られるようにするためである。API クライアント、資格情報の解決、`computeChanges`、semantic tokens
の変換、補完の検出、URI 変換がここに入る。

**スモークテスト**（`tests/smoke.lua`）は headless の Neovim でプラグインを読み込み、描画まで含めて
検証する。extmark やカーソル位置のような「実際に Neovim がどう振る舞ったか」は、ここでしか
確かめられない。

**E2E**（`tests/e2e/`）は偽の Cosense サーバーを立てて、headless の Neovim から通しで動かす。
リクエストの中身（メソッド、URL、body）まで検証するので、書き込みのプロトコルが壊れたらここで
落ちる。**実 API を叩くテストは書かない。**

すべてを `bun run verify` が順に回す。

## セキュリティ / 作法

- PAT をログ・例外文字列・LSP trace に出さない。
- 資格情報ヘッダーはリダイレクト先（別 origin）に転送しない（cosense-cli と同じ方針）。
- API リクエストの失敗（401/403）は「再ログインが必要」への導線として Lua まで伝える。
- ページタイトル・本文はすべて信頼できない入力として扱う（Lua 側で `nvim_buf_set_lines` 以外の評価をしない。コマンド組み立てに混ぜない）。
