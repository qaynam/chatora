<div align="center">

# Chatora

<a href="https://gyazo.com/ffd4dd701f2241264fb6b5587f523480">
  <img src="https://i.gyazo.com/ffd4dd701f2241264fb6b5587f523480.png" width="140" alt="Chatora" />
</a>

Cosense（旧 Scrapbox）を Neovim から読み書きするためのプラグイン

</div>

## デモ

[![Image from Gyazo](https://i.gyazo.com/37dd99cd83a884213a5d1422d93667d2.gif)](https://gyazo.com/37dd99cd83a884213a5d1422d93667d2)

## 名前の由來

- 日本語の茶トラ猫から来ている
- [![Image from Gyazo](https://i.gyazo.com/53c8c22753ff50e183b6c0c9c69dc3a5.gif)](https://gyazo.com/53c8c22753ff50e183b6c0c9c69dc3a5)

## Cosense Webとの互換性

> [! NOTE]
> ChatoraはCosenseの[PAT](https://scrapbox.io/help-jp/Personal_Access_Token)で動きます、リアルタイム通信ではありませんので、同時編集時には注意が必要です。

- **プロジェクト関連**
  - [x] プロジェクト一覧取得
  - [x] プロジェクト切り替え
  - [ ] プロジェクト作成
  - [ ] プロジェクト削除
  - [ ] プロジェクトのメンバー一覧取得
  - [ ] プロジェクトのメンバー追加・削除
  - [ ] プロジェクトのメンバー権限変更
  - [ ] プロジェクトの設定変更
- **ページ関連**
  - [x] ページ一覧取得
  - [x] ページ作成
  - [x] ページ更新
  - [x] ページ削除
  - [x] ページ検索
  - [ ] ページの履歴取得
  - [x] ページメタ情報表示
  - [x] ページの関連ページ表示
  - [x] ページのリネーム及び被リンクページの同期
- **記法**
  - [x] デフォルトの基本記法をサポート
    - [x] リンク記法 `[ページ名]`
    - [x] リンク記法 `[ページ名#行ID]`
    - [x] リンク記法 `[/other-project/page]`
    - [x] 外部リンク記法 `[https://example.com]`
    - [x] alt文字付きリンク `[リンク文字 https://example.com]`
    - [x] 強調記法 `[* 強調] [[強調]]`
    - [x] アイコン記法 `[user.icon]`
    - [x] 下線記法 `[_ 消し線]`
    - [x] 斜体記法 `[/ 斜体]`
    - [x] 消し線記法 `[- 消し線]`
    - [x] 引用記法 `> `
    - [x] コードブロック`code:<言語>:` 及び `code:`
    - [x] インラインコード `` `code` ``
    - [x] 画像記法 `[画像URL.png]`
    - [ ] 数式記法 `[$ 数式]`
    - [ ] マーメイド記法 `mermaid:`
    - [x] 動画記法（gyazo) `[Gyazo動画URL]`
    - [ ] 動画記法（gyazo以外) `[動画URL]`
    - [x] ファイルリンク記法 `[https://scrapbox.io/file/<プロジェクト名>/<ファイル名>]`
  - [x] テーブル表示
  - [x] カスタム装飾記法のカスタマイズ
  - [x] 箇条書きの中点表示
- **その他の機能**
  - [x] 補完リンクサジェスト
  - [ ] smart context
  - [ ] export for ai
  - [x] 画像アップロード
  - [x] 画像アップロード（gyazo連携済み）
  - [ ] ファイルアップロード
  - [x] テロメア
  - [x] 既読未読
- **ショートカット回り**
  - [x] アイコン挿入
  - [x] 日付挿入

## 環境

> [! NOTE]
>
> OSに関してはmacOSを推奨します、linuxやwindowsでの動作確認はしていません。

#### 実行環境

|         |         |
| ------- | ------- |
| Neovim  | >= 0.11 |
| Node.js | >= 20   |

### ターミナル

> [! NOTE]
>
> ghostty以外まだ動作確認できていません、ghosttyを推奨します。

| ターミナル               | 画像                                                                                                               |
| ------------------------ | ------------------------------------------------------------------------------------------------------------------ |
| Ghostty                  | 確認済み（作者が常用しているのはここ）                                                                             |
| kitty / WezTerm          | 同じ kitty graphics protocol なので動くはずですが、未確認です                                                      |
| VS Code の内蔵ターミナル | 設定すれば描けます。[VS Codeのターミナル上で画像表示する](docs/FEATURES.md#vs-code-で画像を表示する)を見てください |

## インストール

### 画像関連のパッケージインストール

#### 表示用

アイコン記法や画像リンクをバッファ内に描画するには、対応ターミナル（kitty / Ghostty）と
[ImageMagick](https://imagemagick.org/)のインストールが必要です（`brew install imagemagick`）、そして描画プラグイン[3rd/image.nvim](https://github.com/3rd/image.nvim) が要ります。

```lua
{ '3rd/image.nvim', opts = { processor = 'magick_cli' } },
```

#### アップロード用

クリップボードからアップロード直接画像アップロードするには[pngpaste](https://github.com/jcsalterego/pngpaste)のインストールが必要です。(`brew install pngpaste`)

---

[lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  'qaynam/chatora',
  version = '*',
  cmd = 'Chatora',
  dependencies = { { '3rd/image.nvim', opts = { processor = 'magick_cli' } } },
  config = {
    default_project = 'my-project',
    -- etc...
  },
}
```

`build` は必須です（LSP サーバーを用意します）。手元のリポジトリを使うなら、
`'qaynam/chatora'` の代わりに `dir = '/path/to/chatora'` を指定してください。

## はじめかた

1. `:Chatora` を実行します。初回は PAT の入力を求められるので、`<origin>/settings/personal-access-tokens`
   で発行して貼り付けてください。入力された PAT は、検証したうえで macOS Keychain に保存します。
   なお、環境変数 `COSENSE_PAT` があれば、そちらが優先されます
2. サイドバーからページを選ぶと、`cosense://<project>/<title>` というバッファが開きます
3. あとは普通に編集して `:w` で保存します。`:wq` なら、保存して閉じるところまで一度で済みます

### Slack や Chrome のリンクを chatora で開く（macOS）

Cosense のリンクをクリックしたとき、ブラウザではなく**今動いている chatora** でそのページを
開けます。

```sh
bin/chatora-url-handler install
```

URL を受け取る小さなアプリを作って登録します。あとは**システム設定 → デスクトップとDock →
デフォルトのWebブラウザ**で `Chatora Open` を選んでください。Cosense 以外のリンクは、それまで
使っていたブラウザにそのまま流れます（`chatora-url-handler browser 'Google Chrome'` で変えられます）。詳しくは
[Slack や Chrome のリンクを chatora で開く](docs/FEATURES.md#slack-や-chrome-のリンクを-chatora-で開くmacos)
を見てください。

## コマンド

| コマンド                          | 動作                                                                                          |
| --------------------------------- | --------------------------------------------------------------------------------------------- |
| `:Chatora`                        | サイドバーを開く（初回は認証 → プロジェクト選択）                                             |
| `:Chatora <url>`                  | Cosense のページ URL をそのまま開く                                                           |
| `:Chatora toggle`                 | サイドバーを開閉                                                                              |
| `:Chatora new [title]`            | 新規ページ。title を省くと空のページが開き、1 行目がタイトルになる                            |
| `:Chatora search [query]`         | 全文検索（内蔵ピッカー）                                                                      |
| `:Chatora related`                | 関連ページパネルを開閉                                                                        |
| `:Chatora account`                | アカウントの切り替え・追加                                                                    |
| `:Chatora project [name]`         | プロジェクトの切り替え。名前を渡すとそのプロジェクトを持つアカウントごと切り替える            |
| `:Chatora logout`                 | 現在のアカウントを削除                                                                        |
| `:Chatora log`                    | 診断ログを開く（`log` オプションが必要）                                                      |
| `:Chatora images [redraw\|clear]` | ページの画像の状態を表示する。`redraw` で描き直す、`clear` で取得した画像を全部捨てて取り直す |
| `:Chatora reload`                 | プラグインを再読み込み（開発用）                                                              |
| `:Chatora help`                   | チートシート                                                                                  |

## キーマップ

キーは `keymaps` に、アクション名ごとに全部並んでいます。値はそのまま `vim.keymap.set` に渡すキーで、
並びで書けば 2 つ以上、`false` で無しです。`prefix`（既定 `<leader>c`）は `<leader>c` 系の既定の頭で、
`prefix = false` でその系統をまとめて外せます。`keymaps = false` で 1 つも入れません。

```lua
keymaps = { sidebar = 'gk', follow = { 'gd', '<CR>' }, copy_url = false }
```

自分で割り当てるなら、アクションごとの `<Plug>(chatora-<アクション名>)`（`_` は `-` になります）か、
`require('chatora.actions').<アクション名>()` を使います。ページのキーは `FileType cosense` で付けます。

```lua
require('chatora').setup({ keymaps = false })
vim.keymap.set('n', '<leader>k', '<Plug>(chatora-sidebar)')
vim.api.nvim_create_autocmd('FileType', {
  pattern = 'cosense',
  callback = function(ev)
    vim.keymap.set('n', 'gd', '<Plug>(chatora-follow)', { buffer = ev.buf })
    vim.keymap.set('n', '<leader>p', require('chatora.actions').pull, { buffer = ev.buf })
  end,
})
```

### どこでも

| 既定         | アクション | 動作                 |
| ------------ | ---------- | -------------------- |
| `<leader>ct` | `sidebar`  | サイドバーを開閉     |
| `<leader>cs` | `search`   | ページを検索         |
| `<leader>cn` | `new`      | 新規ページ           |
| `<leader>cp` | `project`  | プロジェクト切り替え |
| `<leader>ca` | `account`  | アカウント切り替え   |
| `<leader>c?` | `help`     | ヘルプ               |

### ページバッファ

| 既定                | アクション                      | 動作                                                                  |
| ------------------- | ------------------------------- | --------------------------------------------------------------------- |
| `gd`                | `follow`                        | リンク先へジャンプ（`[ページ#行ID]` はその行へ、外部 URL はブラウザ） |
| `<leader>cr` / `gR` | `related`                       | 関連ページパネルを開閉                                                |
| `<leader>cR`        | `related_side`                  | 関連ページパネルを下／右に切り替え                                    |
| `<leader>ci`        | `info`                          | ページ情報                                                            |
| `<leader>cf`        | `pull`                          | サーバーの変更を取り込む                                              |
| `<leader>cc` / `]c` | `next_conflict`                 | 次の競合行へ                                                          |
| `]u` / `[u`         | `next_updated` / `prev_updated` | 次 / 前の更新行へ（右端のマークが指している行）                       |
| `<leader>cv`        | `paste_image`                   | クリップボードの画像を貼り付け                                        |
| `<leader>cd`        | `delete`                        | ページを削除（確認あり）                                              |
| `<leader>cI`        | `normalize_indent`              | インデントを半角スペースに揃える                                      |
| `<leader>cy`        | `copy_url`                      | ページ URL をコピー                                                   |
| `<leader>cY`        | `copy_link`                     | リンク記法 `[タイトル]` をコピー                                      |
| `<leader>co`        | `open_in_browser`               | ブラウザで開く                                                        |
| `:w` / `:wq`        |                                 | 保存（同期）                                                          |

### insert モード

| 既定              | アクション    | 動作                                                                          |
| ----------------- | ------------- | ----------------------------------------------------------------------------- |
| `<C-t>`           | `insert_date` | 日時を挿入（書式は `edit.date_format`）                                       |
| `<C-i>` / `<M-i>` | `insert_icon` | アイコンを挿入（[下記](docs/FEATURES.md#アイコン挿入)）                       |
| `[`               |               | `[]` を自動ペア（`edit.autopair`。リンク補完は閉じた `[...]` の中だけで発火） |
| `<Tab>`           |               | テーブル行では本物のタブ、それ以外は元のマッピングに委譲（`edit.table_tab`）  |

### サイドバー

| キー                           | 動作                                                     |
| ------------------------------ | -------------------------------------------------------- |
| `<CR>` / `l`                   | 開く（フォルダーの見出しなら開閉）                       |
| `<Tab>` / `<S-Tab>` / `1`..`9` | タブ切り替え（クリックも可）                             |
| `R`                            | 再読込                                                   |
| `s`                            | 検索                                                     |
| `n`                            | 新規ページ                                               |
| `P`                            | プロジェクト切り替え（他アカウントのプロジェクトも並ぶ） |
| `A`                            | アカウント切り替え                                       |
| `q`                            | 閉じる                                                   |

行頭には保存状態（`✓` / `●`）と未読バー（`▍`）が出ます。未読バーは、最後に開いたあとに
更新されたページに付きます。

### visual モード

選択したうえで記号を押すと、その範囲を囲みます。同じキーをもう一度押した場合は、入れ子にせず
記号だけを書き換えます。

| 押す                   | 結果                                                         |
| ---------------------- | ------------------------------------------------------------ |
| `*`                    | `[* 選択]`                                                   |
| `*` `*` `*`            | `[*** 選択]`（`[*****]` で頭打ち）                           |
| `_` / `-` / `/`        | `[_ 選択]` など（もう一度押すと外れる）                      |
| `[`                    | `[選択]`。リンクは育てるものではないので normal モードに戻る |
| ユーザー定義記法の記号 | `[<記号> 選択]`                                              |

`edit = { surround = false }` を渡すとすべて無効になり、記号のリストを渡すと、その記号だけが有効になります。

## 設定

`setup()`（lazy.nvim なら `opts`）に渡します。既定値と型（LuaLS の `chatora.Config`）は
`lua/chatora/config.lua` にあります。テーブルの代わりに関数を渡すと、プロジェクトごとに違う設定に
できます。[下記](docs/FEATURES.md#プロジェクトごとの設定)

```lua
require('chatora').setup({
  default_project = 'my-project',
  keymaps = { sidebar = 'gk' },
  sidebar = { tabs = { { name = 'すべて' }, { name = 'daily', related = 'daily' } } },
  edit = { autosave = 10 },
  view = { pads = { bullet = '•' } },
})
```

知らないキーがあると、起動時にそう言います。

### 起動時に決まるもの

| オプション           | 既定                    | 意味                                                                                            |
| -------------------- | ----------------------- | ----------------------------------------------------------------------------------------------- |
| `origin`             | `'https://scrapbox.io'` | Cosense の origin                                                                               |
| `default_project`    | なし                    | 最初に開くプロジェクト。未指定なら起動時に選択。`:Chatora project` で切り替えられる             |
| `server_cmd`         | 自動検出                | LSP サーバーの起動コマンド                                                                      |
| `log`                | `false`                 | 診断ログ。`true` で `${XDG_STATE_HOME:-~/.local/state}/chatora/chatora.log`、文字列ならそのパス |
| `notations`          | `{}`                    | ユーザー定義の装飾記法。[下記](docs/FEATURES.md#カスタム装飾記法)                               |
| `keymaps`            | `true`                  | [上記](#キーマップ)。`false` で 1 つも入れない                                                  |
| `open_external_link` | `'confirm'`             | 外部 URL に `follow` したとき。`'always'` は確認なし、`'never'` は何もしない                    |
| `open_video`         | `'browser'`             | 動く Gyazo キャプチャに `follow` したときの行き先。[下記](docs/FEATURES.md#動画を再生する)      |

上の 4 つはサーバーの起動時に渡すので、プロジェクトごとには変えられません。

### `sidebar`

| キー               | 既定          | 意味                                                                                                    |
| ------------------ | ------------- | ------------------------------------------------------------------------------------------------------- |
| `width`            | `32`          | 幅                                                                                                      |
| `separator`        | `true`        | 行ごとの区切り下線。`'#RRGGBB'` で色を指定、`false` で無効                                              |
| `thumbnails`       | `false`       | ページの最初の画像を行頭に出す。画像バックエンドが要る。[下記](docs/FEATURES.md#サイドバーのサムネイル) |
| `refresh_interval` | `60`          | n 秒ごとに一覧を更新。`false` で止める、最短 5 秒                                                       |
| `tabs`             | すべて / 未読 | 上部のタブ。ページのフィルタやリンクで絞ったタブを足せる。[下記](docs/FEATURES.md#サイドバーのタブ)     |

### `related`

| キー        | 既定       | 意味                                                               |
| ----------- | ---------- | ------------------------------------------------------------------ |
| `position`  | `'bottom'` | 関連ページパネルの位置。`'right'` で全高の縦カラム                 |
| `height`    | `8`        | `'bottom'` のときの高さ                                            |
| `width`     | `40`       | `'right'` のときの幅                                               |
| `auto_open` | `true`     | ページを開いたら関連パネルも開く。`q` で閉じると次の `gR` まで抑制 |

### `edit`

| キー           | 既定                                                | 意味                                                                                         |
| -------------- | --------------------------------------------------- | -------------------------------------------------------------------------------------------- |
| `autosave`     | `false`                                             | 編集停止から n 秒後に自動保存                                                                |
| `sync`         | `{ interval = 30, on_focus = true, notify = true }` | 背後での同期。[下記](docs/FEATURES.md#同期と競合)                                            |
| `save_status`  | `true`                                              | 保存状態アイコン。`{ icons = {...}, echo = false }` で調整                                   |
| `completion`   | `'auto'`                                            | `'auto'` は外部エンジンが無いときだけ内蔵補完を有効化。`'native'` は常に、`false` は外部任せ |
| `autopair`     | `true`                                              | `[` で `[]` を入れる                                                                         |
| `table_tab`    | `true`                                              | テーブル行の `<Tab>` は本物のタブ                                                            |
| `surround`     | `true`                                              | visual モードの装飾キー。記号のリストで限定、`false` で無効                                  |
| `paste_indent` | `true`                                              | `p` / `P` で貼った行を、その行の字下げに揃える                                               |
| `date_format`  | `'%Y-%m-%d %H:%M:%S'`                               | `insert_date` が入れる書式（`os.date`）                                                      |

### `view`

| キー                | 既定                               | 意味                                                                                                                                                                                    |
| ------------------- | ---------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `conceal`           | `true`                             | 記法マークアップを隠す。`true` はカーソル行だけ元の記法に戻す。文字列を渡すとそれが `'concealcursor'` になる（`'nc'` なら読んでいる間は戻さない＝カーソル行のインライン画像も消えない） |
| `pads`              | `true`                             | 箇条書きの中点。[下記](docs/FEATURES.md#箇条書き)                                                                                                                                       |
| `telomere`          | `{ bar = true, scrollbar = true }` | 行ごとの更新バーと右端の一覧。[下記](docs/FEATURES.md#テロメア)                                                                                                                         |
| `quote`             | `true`                             | `>` 行の縦棒と背景。[下記](docs/FEATURES.md#引用)                                                                                                                                       |
| `tables`            | `true`                             | `table:` ブロックの罫線。`{ border = false, header = false }`                                                                                                                           |
| `codeblock_numbers` | `true`                             | コードブロックの行番号                                                                                                                                                                  |
| `file_icon`         | `'󰈔'`                              | プロジェクトにアップロードしたファイルへのリンクに付くアイコン。`false` で無し                                                                                                          |
| `title_margin`      | `1`                                | タイトル行の下に入れる仮想空行の数                                                                                                                                                      |
| `spacing`           | `{ line = 0, code = 0 }`           | 行間に挿入する仮想空行                                                                                                                                                                  |

### `image`

| キー           | 既定         | 意味                                                                                                                                                                                        |
| -------------- | ------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `enabled`      | `true`       | 描画バックエンドが使えるときに描く。`false` で無効                                                                                                                                          |
| `backend`      | `'auto'`     | `'auto'` は image.nvim 優先で snacks.nvim にフォールバック。`'image_nvim'` / `'snacks'` で固定、テーブル（か、それを返す関数）で自前。[下記](docs/FEATURES.md#描画バックエンドを差し替える) |
| `height`       | `20`         | 単独行の画像の高さの上限（行数）。小さい画像は元の大きさのまま。文中のインライン画像は常に 1 行                                                                                             |
| `height_large` | `height * 2` | `[[…]]`（大きい記法）の高さ。画像とアイコンの両方に効く                                                                                                                                     |
| `gallery`      | `true`       | 画像だけの行を、同じ大きさのタイルを横に並べて描く。[下記](docs/FEATURES.md#画像だけの行)                                                                                                   |
| `border`       | `true`       | 画像に合成する枠。`{ width = 1, color = '#8888', padding = 12 }`                                                                                                                            |

## 機能

機能ごとの詳しい説明は [docs/FEATURES.md](docs/FEATURES.md) にあります。

|                                                                               |                                                                      |
| ----------------------------------------------------------------------------- | -------------------------------------------------------------------- |
| [同期と競合](docs/FEATURES.md#同期と競合)                                     | 背後で同期し、取り込みは行単位のマージ。競合行は `]c` で回る         |
| [テロメア](docs/FEATURES.md#テロメア)                                         | どこが更新されたかを、行の左のバーと右端のミニマップで示す           |
| [リネームされたページ](docs/FEATURES.md#リネームされたページ)                 | 旧タイトルのリンクはリダイレクトを追って現在のページを開く           |
| [タイトルの変更](docs/FEATURES.md#タイトルの変更)                             | 1 行目を書き換えて改名。リンクの書き換えと、同名ページへの統合を聞く |
| [行リンク](docs/FEATURES.md#行リンク)                                         | `[ページ名#行ID]` はその行にカーソルを置いて開く                     |
| [別プロジェクトのページ](docs/FEATURES.md#別プロジェクトのページ)             | `[/other-project/page]` を開く。書けないプロジェクトはそう言う       |
| [赤リンク](docs/FEATURES.md#赤リンク)                                         | 実体のないページへのリンクを色で示す                                 |
| [箇条書き](docs/FEATURES.md#箇条書き)                                         | インデント 1 文字が 1 段。中点を仮想テキストで描く                   |
| [引用](docs/FEATURES.md#引用)                                                 | `>` を縦棒に置き換える                                               |
| [カスタム装飾記法](docs/FEATURES.md#カスタム装飾記法)                         | `[<記号> 本文]` の記号を自分で定義する                               |
| [動画を再生する](docs/FEATURES.md#動画を再生する)                             | Gyazo の動画を `gd` で好きなプレイヤーへ渡す                         |
| [ファイルへのリンク](docs/FEATURES.md#ファイルへのリンク)                     | アップロードしたファイルへのリンクにアイコンを出す                   |
| [記法の色](docs/FEATURES.md#記法の色)                                         | colorscheme から借りつつ、同じ色を二度使わない                       |
| [画像の表示](docs/FEATURES.md#画像の表示)                                     | 対応ターミナルと描画プラグインがあればバッファ内に描く               |
| [画像だけの行](docs/FEATURES.md#画像だけの行)                                 | 同じ大きさのタイルを横に並べ、入らなければ折り返す                   |
| [描画バックエンドを差し替える](docs/FEATURES.md#描画バックエンドを差し替える) | image.nvim / snacks.nvim / 自前のバックエンド                        |
| [画像の貼り付け](docs/FEATURES.md#画像の貼り付け)                             | クリップボードの画像をアップロードして記法を書く                     |
| [ページ情報](docs/FEATURES.md#ページ情報)                                     | 作成者・更新・被リンク・閲覧数などを 1 枚に                          |
| [アイコン挿入](docs/FEATURES.md#アイコン挿入)                                 | 押した場所で意味が変わるアイコンキー                                 |
| [保存状態の表示](docs/FEATURES.md#保存状態の表示)                             | トーストではなく小さなアイコンで伝える                               |
| [サイドバーとプロジェクト](docs/FEATURES.md#サイドバーとプロジェクト)         | サイドバーは今見ているページのプロジェクトを映す                     |
| [サイドバーのタブ](docs/FEATURES.md#サイドバーのタブ)                         | サイドバーに出すリストを選ぶ                                         |
| [連携](docs/FEATURES.md#連携)                                                 | telescope、シェルから起動、Cosense のリンクを chatora で開く         |

## トラブルシューティング

### `<C-i>` でアイコンが挿入されない

端末が `<C-i>` を `<Tab>` と別のキーとして送るのは、kitty keyboard protocol を話すときだけです。
それ以外では両方が**同じバイト**で届き、`<Tab>` は補完プラグインが持っているため、アイコンでは
なく補完メニューが出ます。

- kitty / Ghostty / WezTerm はそのまま対応。**tmux 越しなら `set -g extended-keys on` が必要**
- 既定でもう一つ入っている **`<M-i>`（Alt+i）** を使う。どのプラグインとも競合しない
- Ghostty なら `keybind = cmd+i=text:\x1bi` で Cmd+I を `<M-i>` として送れる

なお、chatora が `<Tab>` を奪うことはありません。テーブル行のときだけ本物のタブを挿入し
（`expandtab` のままではセル区切りにならないためです）、それ以外は元々そのキーを持っていた
マッピングに委譲します。

### 何かが読み込めない（ページ・画像・関連ページ）或いはHTTPエラーが出た場合

`log = true` を設定してから `:Chatora log` を開いてください。**2xx 以外のレスポンスはすべて**、
メソッド・URL・status 付きで記録してあります。chatora は失敗を値に変えて UI を静かに保つ設計で、
読めないページは「存在しないページ」に、取れない画像は「描かれない画像」になります。そのため、
何が起きたのかはこのログでしか分かりません。

画像が出ない場合は、対応ターミナルと描画プラグインの両方が必要です
（[画像の表示](docs/FEATURES.md#画像の表示)）。

### コードブロックに色が付かない

必要なのは **treesitter のパーサー**であって、その言語の LSP ではありません。`code:index.php` は
`index.php` をファイル名として読んで `php` に解決し、その言語のパーサーがあるときだけ色を付けます。
パーサーが無ければ何も起こらず、エラーにもなりません。そのため、`:TSInstall php` を実行するか、
nvim-treesitter に `auto_install = true` を渡しておいてください。

なお、`:TSInstall` で取ってこられる言語であれば、色が付かないときに chatora が一度だけ知らせます。

PHP には癖があります。tree-sitter の `php` は `<?php` の**外側を HTML として読む**ため、開きタグの
無いスニペットには色が付きません。chatora はそういうブロックを `php_only`（同じ文法をコードから
読むほう）で読むので、`:TSInstall php php_only` と両方を入れておけば、どちらの書き方でも色が
付きます。

その他の問題は自由にissueを投げてください。🙌

### 保存が競合で止まる

同じ行がサーバー側でも編集されています。`]c` で競合行へ飛んで直してから、もう一度 `:w` して
ください。詳しくは[同期と競合](docs/FEATURES.md#同期と競合)を見てください。

## 開発

設計の要点とテストの回し方は [CONTRIBUTING.md](CONTRIBUTING.md) にあります。

`:Chatora reload` を使うと、nvim を再起動せずにプラグインを入れ替えられます。LSP を止め、chatora の
ウィンドウとバッファを畳み、`package.loaded` から chatora のモジュールを落としたうえで、同じ
オプションで `setup()` をやり直します。ただし、**サーバー側を変えたときは先に `bun run build`
が必要です**。クライアントはサーバーのプロセスを起動し直すだけで、ビルドまではしません。

```sh
bun run verify           # typecheck + テスト + build + lint + smoke + E2E
bun test                 # core + server の単体テスト
nvim --headless --clean -u NORC -c "luafile tests/smoke.lua"
bun tests/e2e/run.ts     # 偽 Cosense サーバー + headless nvim
```

## クレジット

- [helpfeel/cosense-cli](https://github.com/helpfeel/cosense-cli)
- [cosense-toolbox/parser](https://www.npmjs.com/package/@cosense-toolbox/parser)
- [3rd/image.nvim](https://github.com/3rd/image.nvim) と
  [folke/snacks.nvim](https://github.com/folke/snacks.nvim)
- [petertriho/nvim-scrollbar](https://github.com/petertriho/nvim-scrollbar)
- [folke/lazy.nvim](https://github.com/folke/lazy.nvim)

## ライセンス

[MIT](LICENSE)
