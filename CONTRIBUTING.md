# コントリビュート

## はじめに

```sh
git clone https://github.com/qaynam/chatora
cd chatora
bun install
bun run build          # LSP サーバーを packages/server/dist/main.js に吐く
```

リリースを使う人はビルド済みのサーバーを落としてきますが（`scripts/install-server.sh`）、タグの
上に居ない開発中のチェックアウトは常にソースからビルドします。つまり**開発には bun が要ります**。
一方で、サーバーを動かすのは node（>= 20）です。

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
- Neovim の挙動は推測せず、headless で測ってください。extmark は `nvim_buf_get_extmarks`、
  画面は `screenstring()` で見えます

## 設計の要点

chatora は 2 つの層でできています。Neovim 側の Lua プラグイン（`lua/`、`plugin/`）は UI だけを
持ち、TypeScript の LSP サーバー（`packages/server`）がハイライト・補完・定義ジャンプと、
`chatora/*` という独自リクエストによる Cosense API の仲介を担います。API クライアント・認証・
行の diff は `packages/core` に分けてあり、UI にも LSP にも依存しません。

こう分けたのは、記法のパーサー（`@cosense-toolbox/parser`）が TypeScript にしか無く、一方で
Neovim の描画は Lua でしか書けないからです。LSP はその 2 つを繋ぐ既製の配管で、semantic tokens・
補完・定義ジャンプは標準の機能がそのまま使えます。標準に無いもの（ページの保存、サイドバー、
画像）だけを `chatora/*` として足してあります。`packages/core` を切り離してあるのは、LSP の
プロセスを立てずにテストするためです。

### 失敗は値で返す

TypeScript 層は effect-ts で書いてあり、どの操作も throw せずに `Effect<A, E, R>` を返します。
Effect の世界と LSP の世界の境目は `packages/server/src/main.ts` の 1 箇所だけで、LSP の
コールバックの縁で `runtime.runPromise` します。

`chatora/*` のリクエストは、失敗も LSP のエラー応答ではなく `{ ok: false, code, message }` で
返します。Lua 側の分岐を単純にするためです。リクエストの一覧と型は `main.ts` が正です。

その上で、失敗は UI を騒がせません。読めないページは「存在しないページ」に、取れない画像は
「描かれない画像」になり、何が起きたかは `log = true` の診断ログにだけ残ります。

### Cosense の API について分かったことは、コードの隣に書く

Cosense の API に公式ドキュメントはありません。出所は
[helpfeel/cosense-cli](https://github.com/helpfeel/cosense-cli) のソースと、本家 Web クライアントの
通信を HAR で記録した実測の 2 つだけです。分かった事実は、別の文書ではなく、それを使っている
コードのコメントに書いてください。文書に写すと、コードを直したときに必ず腐ります。

たとえば、次のことはそれぞれの場所に書いてあります。

- 存在しないページが 404 ではなく `persistent: false` と偽の id で返ってくること →
  `packages/core/src/types.ts` の `PageDetail`
- `page-edit-for-ai` の preview → submit と、`changes` の 3 つの形 →
  `packages/core/src/types.ts` と `changes.ts`
- タイトルのエンコードが `encodeURIComponent` ではないこと → `packages/core/src/api.ts`
- 認証ヘッダーの名前と、資格情報を探す順序 → `packages/core/src/credentials.ts`

### 両側で同じでなければならないもの

- `cosense://<project>/<title>` の URI は、`lua/chatora/uri.lua` と
  `packages/server/src/uriScheme.ts` がバイト単位で同じ規則を持ちます。
  `tests/uri-parity.test.ts` が一致を確かめます
- semantic tokens の legend の順序は、`packages/server/src/tokens.ts` と
  `lua/chatora/highlight.lua` のあいだの契約です
- `parse` / `parseLine` には必ず `parseOptions()` を渡します。渡し漏れると、カスタム記法の解釈が
  機能ごとに食い違います

### Neovim 側

ページは本物のバッファです。`BufReadCmd cosense://*` で開き、`buftype=acwrite` にして
`BufWriteCmd` で保存するので、`:w` も `:wq` も定義ジャンプも Vim の作法がそのまま通ります。
保存だけは同期で待ちます。直後に `:wq` が `modified` を見るからです。自動保存は待たず、代わりに
リクエストへ `changedtick` を持たせて、返事までに打鍵があればバッファ全体に関わる処理をしません。

必須の依存プラグインはありません。telescope・image.nvim・snacks.nvim はどれも任意で、無ければ
その機能が無いだけになります。

## テスト

3 段あり、それぞれそこでしか捕まらないものを捕まえます。

| | 何を確かめるか |
|---|---|
| 単体テスト（`bun test`） | 純ロジックです。fetch と `security` コマンドは差し替えられます |
| スモークテスト（`tests/smoke.lua`） | headless の Neovim です。extmark が実際にどこに付いたか、カーソルがどこにあるかは、ここでしか分かりません |
| E2E（`tests/e2e/`） | 偽の Cosense サーバー + headless の Neovim です。リクエストの中身（メソッド・URL・body）まで見るので、書き込みのプロトコルが壊れたらここで落ちます |

実 API を叩くテストは書きません。

## セキュリティ

- PAT は macOS Keychain にだけ置き、ログ・エラーメッセージ・LSP の応答に出しません
- 資格情報ヘッダーはリダイレクト先に転送しません。リダイレクトは manual で受け、origin を離れた
  時点でヘッダーを外します
- 401 / 403 は「再ログインが必要」への導線として Lua まで伝えます
- ページのタイトルと本文は信頼できない入力です。Lua 側では `nvim_buf_set_lines` 以外で評価せず、
  外部コマンドは argv 配列で渡してシェルを経由しません

## まだ無いもの

- hover プレビュー（リンクの上でページの冒頭を出す）
- `textDocument/references`（関連ページパネルが 1hop / 2hop で代替しています）
- rename（ページ名の変更と、それを指すリンクの一括置換）
- Service Account（ヘッダー名は分かっていますが、扱うのは PAT だけです）
