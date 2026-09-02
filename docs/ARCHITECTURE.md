# chatora の設計

この文書には、**コードを読んでも分からないこと**だけを書く。Cosense の API を実測して分かった
事実と、その上でなぜこう作ったかである。

関数の一覧や型、設定項目、キーマップはここには無い。それはコードと [README](../README.md) が
正であり、写しを置けば必ず腐るからである。

- 何ができるか → [README](../README.md)
- 機能ごとの挙動 → [docs/FEATURES.md](FEATURES.md)
- 作業のしかた → [CLAUDE.md](../CLAUDE.md) と [CONTRIBUTING.md](../CONTRIBUTING.md)

## 全体像

chatora は 2 つの層でできている。**Lua プラグイン**（`lua/`、`plugin/`）は UI だけを持ち、
**TypeScript の LSP サーバー**（`packages/server`）がハイライト・補完・定義ジャンプと、
`chatora/*` という独自リクエストによる Cosense API の仲介を担う。API クライアント・認証・行の
diff は `packages/core` に分けてあり、UI にも LSP にも依存しない。

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

**なぜ 2 層なのか。** 記法のパーサー（`@cosense-toolbox/parser`）が TypeScript にしか無く、
Cosense の API も TypeScript のほうが書きやすい。かといって Neovim の描画は Lua でしか書けない。
LSP はその 2 つを繋ぐ既製の配管であり、semantic tokens・補完・定義ジャンプは**標準の機能として
そのまま使える**。標準に無いもの（ページの保存、サイドバー、画像）だけを `chatora/*` として足した。

**なぜ純ロジックを `packages/core` に分けるのか。** LSP のプロセスを立てずにテストしたいから。
`HttpClient` と `CommandExecutor` をサービスとして切ってあるのも、テストで fetch と `security`
コマンドを差し替えるためである。

開発には bun を使うが、**サーバーを動かすのは node（>= 20）**である。ビルドだけは bun で行う
（tsdown を node で走らせると `Promise.withResolvers` を要求して node 22 未満で落ちるため、
`bunx --bun tsdown` にしてある）。

## Cosense API

**公式のドキュメントは存在しない。** ここに書いてあることの出所は 2 つだけで、
[helpfeel/cosense-cli](https://github.com/helpfeel/cosense-cli) のソース（`src/lib/request.ts`、
`src/commands/*.ts`）と、本家 Web クライアントの通信を HAR で記録した実測である。**推測は書いて
いない。** origin は既定 `https://scrapbox.io` で、設定で変えられる。

### 認証

認証ヘッダーは PAT なら `x-personal-access-token: <token>`、Service Account なら
`x-service-account-access-key: cs_...`。**Bearer ではない。** PAT の発行ページは
`<origin>/settings/personal-access-tokens`。

資格情報は chatora が独自に管理し、**cosense-cli の `settings.json` は読まない**。解決の順序は、

1. 環境変数 `COSENSE_PAT`
2. アカウント索引の active なアカウント → `security find-generic-password -s chatora -a <accountId> -w`
3. レガシー経路 → `security find-generic-password -s chatora -a <origin> -w`

保存先は macOS Keychain だけで、ファイルには書かない。**したがってアカウントの追加と切り替えは
macOS でしか動かない。** 他の OS では 1 の環境変数が唯一の入口になる。

**PAT は絶対に、ログにもエラーメッセージにも LSP のレスポンスにも入れない。**

### 複数アカウント

1 つの PAT が 1 つのアカウントに対応し、`id` は `` `${origin}#${userId}` ``。Keychain の
account（`-a`）にもこの id をそのまま使う。

PAT 本体は Keychain にしか置かないが、**PAT を含まないアカウント索引**（メタデータと、どれが
active か）は JSON ファイルに永続化する。場所は `${CHATORA_STATE_DIR}`、無ければ
`${XDG_STATE_HOME:-$HOME/.local/state}/chatora/accounts.json`。パーミッションは 0600 で、壊れた
JSON は空の索引として扱う（起動を止めない）。

古いバージョンは Keychain の account に `<origin>` を使っていた（解決順の 3 段目）。**このレガシー
エントリを消す移行処理は書かない。** 読めるものは読めたままにしておく。

### 読み取り

| 用途 | エンドポイント |
|---|---|
| 自分 + userId | `GET /api/users/me` |
| プロジェクト一覧 | `GET /api/projects` |
| ページ一覧 | `GET /api/pages/:project/?sort=updated&limit=&skip=` |
| ページ本文（v2、lines に id 付き） | `GET /api/pages/v2/:project/:titleEncoded` |
| 関連ページ | `GET /api/pages/v2/:project/:titleEncoded/links1hop` / `links2hop` |
| 全文検索 | `GET /api/pages/:project/search/query?q=` |
| ベクトル検索 | `GET /api/pages/:project/search/vector/titles?q=` |
| タイトル一覧（補完用） | `GET /api/pages/:project/search/titles` |

ベクトル検索は **HTTP 490 が「この機能は無効」**を意味する。エラーではないので、空配列に畳んで
先へ進める。

**存在しないページは 404 にならない。** `GET /api/pages/v2/...` は HTTP 200 に
`persistent: false` を載せ、**偽の id・commitId・行 id** を一緒に返してくる。この偽 id を挿入の
アンカーに使うと他人のページを壊しかねないので、`CosenseApi.getPage()` が `persistent: false` を
その場で `null` に畳み込む。偽 id を層の外に出さない、というのがこの設計の要点である。

レスポンスは寛容にパースする。未知のフィールドは黙って通し、必要なものだけ検証する。Cosense の
API は予告なくフィールドが増えるので、知らないものが来たことをデコード失敗にしてはいけない。

### 書き込み（page-edit-for-ai、2 段階 REST）

WebSocket は要らない。REST を 2 回叩く。

1. `POST /api/pages/v2/:project/page-edit-for-ai/preview`
   - body `{ pageId?, changes }`（新規ページは `pageId` なし）→ res `{ previewId, expireAt, pagePreview }`
2. `POST /api/pages/v2/:project/page-edit-for-ai/submit`
   - body `{ previewId }` → res `{ commitId, page, titleChanged? }`

`previewId` は**使い捨てで 5 分で失効する**。

`changes` の形は 3 つ。

```
{ _insert: <anchorLineId | '_end'>, lines: { id, text } }
{ _update: <lineId>, lines: { text } }
{ _delete: <lineId> }
```

`_insert` のアンカーは「**この行 ID の前に挿入**」であり、`'_end'` が末尾追加。`_delete` に
`lines` フィールドは**無い**（cosense-cli の `previewEdit.ts` で確認済み）。

新しく挿入する行の `id` は**クライアントが生成する** 24 桁の lowercase hex で、cosense-cli の実装は
`randomBytes(12).toString('hex')`。unixtime も userId も**含まない**。

エラーは 3 つ。`409 NotFastForward` が楽観ロックの競合（＝再取得してやり直す）、
`409 DuplicateTitle` が同名ページ、`422` が不正な lineId など。

### タイトルのエンコード

HTTP パス上では `encodeURIComponent` ではなく cosense-cli の `encodeTitleForUrl` 方式を使う。
**`% / ? #` だけをエンコードし、空白は `_`、unicode は生のまま。** `CosenseApi` の内部で処理する
ので、呼び出し側は生のタイトルを渡すだけでよい。

これは後述の `cosense://` URI スキームとは**別物**である。混ぜると、タイトルに `/` を含むページで
壊れる。

## 設計上の決めごと

### エラーを投げない

TypeScript 層は effect-ts を全面的に使い、**どの操作も throw せず `Effect<A, E, R>` を返す**。
サービスは Context.Tag と Layer、エラーは Data.TaggedError。Effect の世界と LSP の世界の境目は
1 箇所だけで、サーバーが initialize で ManagedRuntime を作り、LSP のコールバックの縁で
`runtime.runPromise` する。

**失敗を値に変えて UI を静かに保つ**、というのが全体の方針である。読めないページは「存在しない
ページ」に、取れない画像は「描かれない画像」になる。代わりに、何が起きたかは `log = true` の
診断ログにだけ残る。

### `chatora/*` は成功も失敗も `ok` で返す

LSP のエラー応答ではなく `{ ok: false, code, message }` を返す。Lua 側の分岐を単純にするためで、
成功は `{ ok: true, ... }`。**リクエストの一覧と型は `packages/server/src/main.ts` が正。**

`chatora/*` を足すときに踏みやすい穴だけ、ここに残しておく。

- **JSON の `null` は Lua で `vim.NIL` になり、これは truthy である。** `lsp.request` の境界で
  落として `nil` に統一してあるので、その上では `if result.x then` が期待どおり動く
- **未読は自分で計算する。** サーバーは未読フラグを返さない。本家のグリッドが青枠を出す条件と
  同じ `updated > accessed` で判定し、`accessed` が無ければ未訪問＝未読とする
- **未読フィルタはサーバー側に無い。** クライアントが取得後に間引くので、`skip` は取得件数では
  なく**間引く前の件数**で進める。さもないと落とした分を次のページでまた取る
- **既読化（`POST /api/pages/:project/:pageId/accessed`）は非公式。** 405 なら GET に落とし、
  失敗しても無視する
- **テロメアにはバッファの行を渡す。** 保存やマージの直後に呼ばれるため、`didChange` の到着を
  待つ同期文書ではズレる。base 行と一致しない行はローカルの未保存分として `updated: 0` にする
- **赤リンクの判定は 60 秒キャッシュ越し**（補完と共用のタイトル索引）なので、最大 1 分遅れる
- **画像のアップロード先は 2 系統ある。** PAT では `/api/projects/<name>` が 401 になるので、
  既定は GCS 側（project id は `/api/projects/<name>/users` から取る）。片方が失敗したらもう
  片方を試す
- **パーサーの `isImageUrl` はスキームを見ない。** `#.png` のような接尾辞だけで判定するため、
  `[?userId=…#.svg]`、`[/relative.png]`、`[javascript:…#.png]` もすべて image ノードになる。
  絶対 http(s) URL 以外は収集側で外し、取得側でも再度拒否する。**ページ本文は信頼できない入力
  であり、ここが唯一ネットワークを触る境界だからである**

### 保存は上書きではなくマージ

`chatora/openPage` の時点で、サーバーが base 状態（行 ID つきの本文、pageId、commitId）を URI を
キーに持つ。保存はその base と現在の文書の diff を `changes` に変換して投げる。

`NotFastForward` が返ったら、再取得して**三方向マージ**し、preview をもう一度だけ試す。両側が
同じ行を触っていたときだけ `conflict` で止め、マージ結果と衝突行を返す。ポーリング
（`chatora/syncPage`）も同じマージを通るので、**バッファの未保存分がサーバーの更新で消えることは
ない**。

### URI スキーム

`cosense://<project>/<title>`。この URI は**バッファ名を兼ねてタブに表示される**ので、unicode は
生のまま残し、構造を壊す `%` `/` `?` `#` と制御文字だけをパーセントエンコードする。

同じ規則を Lua（`uri.lua`）とサーバー（`uriScheme.ts`）が**バイト単位で共有している**。どちらかを
変えるなら、必ず両方を変えること。

### semantic tokens

**トークンは行をまたげない。** そのため codeBlock のような複数行ノードは、行ごとに分割して出す。

decoration ノードは bold / italic / strike / underline のうち 1 つだけを、この優先順で出す。
bold はさらに `[*]` / `[**]` / `[***]` を bold / bold2 / bold3 に分ける。**ターミナルには文字の
大きさが 1 種類しか無い**ので、web でフォントサイズが担っている強調の段階を、色で表すしかない
ためである。legend の順序自体がクライアントとの契約になる。

### ユーザー定義の装飾記法

`[<記号> 本文]` の記号をユーザーが定義できる（`notations`）。設計上の判断が 3 つある。

**検証は Lua 側の `setup()` で行い、サーバーではない。** 不正な項目は `vim.notify` で警告して
その項目だけ捨てる。設定の誤りでプラグイン全体を落とさないためである。ただしサーバーも
`initializationOptions` を**信頼しない入力として同じ規則で検証する**（LSP クライアントは
chatora だけとは限らない）。

**`icon` は 1 文字に限る。** Neovim の extmark `conceal` が 1 文字しか置換に使えない。

**`hl` と `icon` はサーバーに渡さない。** どう描くかは Neovim 側の関心事で、サーバーが知る必要が
ない。渡すのは `{ marker, name }` だけ。

実装は `@cosense-toolbox/parser` の `bracketRule` 拡張（`notations.ts`）で、`inner` が
`<marker>` + 空白で始まれば decoration ノードを返す。**以後の `parse` / `parseLine` はすべて、
この拡張込みの `parseOptions()` を渡さなければならない。** 渡し漏れると、機能ごとに装飾やリンクの
解釈が食い違う。

## Neovim 側の決めごと

**ページは本物のバッファである。** `BufReadCmd cosense://*` で開き、`buftype=acwrite` にして
`BufWriteCmd` で保存する。だから `:w` も `:wq` も定義ジャンプも、Vim の作法がそのまま通る。

**保存だけは同期で待つ。** 直後に `:wq` が `modified` を見るためである。一方**自動保存は待たない**
（カーソルが固まるため）。その代わりリクエストに `changedtick` を持たせ、返事までに打鍵があった
場合はバッファ全体を代表する処理（`modified` のクリア、正規化テキストの適用）を行わない。

**ポーリングは画面に出ているバッファだけ。** `BufEnter` と `FocusGained` で `chatora/syncPage` を
投げ、離れれば止まる。

**サイドバーは今見ているページのプロジェクトを映す。** プロジェクトごとに一覧を持っておき、別
プロジェクトのバッファに移ったら張り替える。

**必須の依存プラグインは無い。** ピッカーも内蔵で、telescope・image.nvim・snacks.nvim はどれも
任意である。無ければその機能が無いだけになる。

### ハイライト

`@lsp.type.<token>.cosense` に既定を定義する。すべて `default = true` なので、ユーザーの
colorscheme が後から上書きできる。

色は colorscheme の標準グループから借りるが、**同じ色を二度使わないことを保証する**。強調の段階を
色でしか表せない以上、リンクの色と強調の色が同じでは意味が潰れるためである。bold や italic の
属性は `Bold` や `@markup.strong` にリンクせず直接指定する。colorscheme がそれらをどう定義して
いても装飾が出るようにするためで、色のほうは `:colorscheme` のたびに借り直す。

## テスト

3 段あり、それぞれ**そこでしか捕まらないもの**を捕まえる。

**単体テスト**（`bun test`）は純ロジック。fetch と `security` を差し替えられるのはこのため。

**スモークテスト**（`tests/smoke.lua`）は headless の Neovim。extmark が実際にどこに付いたか、
カーソルがどこにあるかは、ここでしか確かめられない。

**E2E**（`tests/e2e/`）は偽の Cosense サーバーと headless の Neovim。**リクエストの中身**
（メソッド・URL・body）まで検証するので、書き込みのプロトコルが壊れたらここで落ちる。

**実 API を叩くテストは書かない。** すべてを `bun run verify` が順に回す。

## セキュリティ

- PAT をログ・例外文字列・LSP trace に出さない
- 資格情報ヘッダーを**リダイレクト先（別 origin）に転送しない**。リダイレクトは manual で受け、
  origin を離れた時点でヘッダーを外す
- 401 / 403 は「再ログインが必要」への導線として Lua まで伝える
- **ページのタイトルと本文は信頼できない入力**として扱う。Lua 側では `nvim_buf_set_lines` 以外の
  評価をせず、外部コマンドは argv 配列で渡してシェルを経由しない

## まだ無いもの

- **hover プレビュー** — リンクの上でページの冒頭を出す
- **references（バックリンク）** — 関連ページパネルが 1hop / 2hop で代替しているが、LSP の
  `textDocument/references` としては実装していない
- **rename** — ページ名の変更と、それを指すリンクの一括置換
- **Service Account** — ヘッダーの存在は分かっているが、chatora が扱うのは PAT だけ
