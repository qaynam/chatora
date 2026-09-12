<div align="center">

# Chatora

<a href="https://gyazo.com/ffd4dd701f2241264fb6b5587f523480">
  <img src="https://i.gyazo.com/ffd4dd701f2241264fb6b5587f523480.png" width="100" alt="Chatora" />
</a>

Cosense（旧 Scrapbox）を Neovim から読み書きするための **非公式** プラグイン

</div>

## デモ

[![Image from Gyazo](https://i.gyazo.com/37dd99cd83a884213a5d1422d93667d2.gif)](https://gyazo.com/37dd99cd83a884213a5d1422d93667d2)

## 名前の由來

- 日本語の茶トラ猫から来ている
- [![Image from Gyazo](https://i.gyazo.com/53c8c22753ff50e183b6c0c9c69dc3a5.gif)](https://gyazo.com/53c8c22753ff50e183b6c0c9c69dc3a5)

## Cosense Webとの互換性

> [!NOTE]
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

> [!NOTE]
> macOSを推奨します（理由：まだlinuxやwindowsでの動作確認はしていません）

#### 実行環境

|         |         |
| ------- | ------- |
| Neovim  | >= 0.11 |
| Node.js | >= 20   |

### ターミナル

> [!NOTE]
> ghosttyを推奨します。（理由：ghostty以外まだ動作確認できていません）

| ターミナル               | 画像                                                                                                               |
| ------------------------ | ------------------------------------------------------------------------------------------------------------------ |
| Ghostty                  | 確認済み                                                                                                           |
| kitty / WezTerm          | 同じ kitty graphics protocol なので動くはずですが、未確認です                                                      |
| VS Code の内蔵ターミナル | 設定すれば描けます。[VS Codeのターミナル上で画像表示する](docs/FEATURES.md#vs-code-で画像を表示する)を見てください |

## インストール

### 画像表示用パッケージインストール

アイコン記法や画像リンクをバッファ内に描画するには、対応ターミナル（kitty / Ghostty）と[ImageMagick](https://imagemagick.org/)のインストールが必要です（`brew install imagemagick`）、そして描画プラグイン[3rd/image.nvim](https://github.com/3rd/image.nvim) が必要です。

```lua
{ '3rd/image.nvim', opts = { processor = 'magick_cli' } },
```

### 画像・ファイルアップロード用パッケージインストール

クリップボードから直接画像アップロードするには[pngpaste](https://github.com/jcsalterego/pngpaste)のインストールが必要です。(`brew install pngpaste`)

---

[lazy.nvim](https://github.com/folke/lazy.nvim)の設定

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

## Chatora CLI

コマンドラインから直接Chatoraを起動できるように `bin/chatora`を用意しています。
lazy.vimをインストールしたら、一緒ににダウンロードされると思うので、PATHに追加しておくと便利です。

```sh
使い方: chatora [-p <project>] [open] [<url>] [nvim の引数...]

  chatora                                    サイドバー（設定のプロジェクト）
  chatora -p my-project                      そのプロジェクトのサイドバー
  chatora https://scrapbox.io/proj/Page      そのページ（open を前に付けても同じ）
  chatora -p my-project notes.md             残りの引数は nvim へ
```

## Chatora URL Handler

> [!NOTE]
> MacOS でのみ動作します。

`bin/chatora-url-handler` を使うと、SlackやDiscordのようなサードパーティアプリからcosenseリンクを開くときに、ブラウザではなく、現在開いているchatoraセッションで開くことができます。

Chatora CLI同様こちらもlazy.vimでダウンロードされるので、ダウンロードパスから以下のコマンドを実行してくだいさい。

```sh
bin/chatora-url-handler install
```

そしてmacOSの設定からChatoraをデフォルトのブラウザに設定してください。

[![Image from Gyazo](https://i.gyazo.com/a882d7cf2f86e6cde83f665f4be211e2.png)](https://gyazo.com/a882d7cf2f86e6cde83f665f4be211e2)

### Fallback URLも指定もできます

chatora-url-handlerはscrapbox.ioというoriginだけハンドリングしてchatoraセッションに飛ばします、他のurlはブラウザにfallbackされます、

```sh
chatora-url-handler browser <browser_name>
```

[![Image from Gyazo](https://i.gyazo.com/a7e0451a7b5103acd19715701ef59a95.png)](https://gyazo.com/a7e0451a7b5103acd19715701ef59a95)

## コマンド

| コマンド                          | 動作                                                                                                                    |
| --------------------------------- | ----------------------------------------------------------------------------------------------------------------------- |
| `:Chatora`                        | サイドバーを開く                                                                                                        |
| `:Chatora <url>`                  | Cosense のページ URL をそのまま開く                                                                                     |
| `:Chatora toggle`                 | サイドバーを開閉                                                                                                        |
| `:Chatora new [title]`            | 新規ページ（title を省くと空のページが開きます）                                                                        |
| `:Chatora search [query]`         | cosenseの全文検索 (queryを省くこともできます）（注：telescopeに依存しています）                                         |
| `:Chatora related`                | 関連ページパネルを開閉                                                                                                  |
| `:Chatora account`                | アカウントの切り替え・追加                                                                                              |
| `:Chatora project [name]`         | プロジェクトの切り替え（nameは省くことができます）                                                                      |
| `:Chatora logout`                 | 現在のアカウント（PAT）を削除                                                                                           |
| `:Chatora log`                    | 診断ログを開く（デバッグ用の`log` オプションを有効にする必要があります）                                                |
| `:Chatora images [redraw\|clear]` | `redraw` でバッファー上の描き直します、`clear` で取得してキャッシュファイルに保存していいる画像を全部捨てて取り直します |
| `:Chatora reload`                 | プラグインを再読み込み                                                                                                  |
| `:Chatora help`                   | チートシート                                                                                                            |

## キーマップ

キーは `keymaps` に、アクション名ごとに並んでいます。値はそのまま `vim.keymap.set` に渡すので、
リストで書けば 2 つ以上に割り当てられますし、`false` にすればそのアクションだけ外せます。`prefix` は
`<leader>c` 系の頭で、`prefix = false` にするとその系統がまとめて外れます。

```lua
require('chatora').setup({
  keymaps = {
    prefix = '<leader>c',      -- <prefix> 系の頭。false でこの系統を全部外す
    sidebar = 'gk',            -- 既定を別のキーにする
    follow = { 'gd', '<CR>' }, -- 2 つ以上に割り当てる
    copy_url = false,          -- このアクションだけ外す
  },
})
```

`keymaps = false` を渡すと 1 つも入りません。ただし `<Plug>(chatora-<アクション名>)` はそれでも定義
されるので、自分で全部書きたいときはこれを使います（アクション名の `_` は `-` になります）。
`require('chatora.actions').<アクション名>()` を直接呼んでも同じです。ページバッファのキーはバッファ
ごとに付くので、`FileType cosense` で設定してください。

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
| `<leader>ci`        | `info`                          | ページ情報（作成者・更新者・被リンクなど）                            |
| `<leader>cf`        | `pull`                          | サーバーの変更を取り込む（マージ）                                    |
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
| `<C-i>` / `<M-i>` | `insert_icon` | アイコンを挿入（[アイコン挿入](docs/FEATURES.md#アイコン挿入)）               |
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

行頭には保存状態（`✓` / `●`）と未読バー（`▍`）が出ます。未読バーは、最後に開いたあとに更新された
ページに付きます。

### visual モード

選択したうえで記号を押すと、その範囲を囲みます。同じキーをもう一度押した場合は、入れ子にせず記号
だけを書き換えます。

| 押す                   | 結果                                                         |
| ---------------------- | ------------------------------------------------------------ |
| `*`                    | `[* 選択]`                                                   |
| `*` `*` `*`            | `[*** 選択]`（`[*****]` で頭打ち）                           |
| `_` / `-` / `/`        | `[_ 選択]` など（もう一度押すと外れる）                      |
| `[`                    | `[選択]`。リンクは育てるものではないので normal モードに戻る |
| ユーザー定義記法の記号 | `[<記号> 選択]`                                              |

`edit = { surround = false }` を渡すとすべて無効になり、記号のリストを渡すと、その記号だけが有効に
なります。

## 設定

`setup()`（lazy.nvim なら `opts`）に渡します。書いたキーだけが上書きされるので、変えたいところだけ
書けば残りは既定のままです。テーブルの代わりに関数を渡すと、プロジェクトごとに違う設定にできます
（[プロジェクトごとの設定](docs/FEATURES.md#プロジェクトごとの設定)）。知らないキーがあったときは、
起動時にそう知らせます。

既定値は以下のとおりです。

```lua
require('chatora').setup({
  origin = 'https://scrapbox.io', -- Cosense の origin
  default_project = nil,          -- 最初に開くプロジェクト。nil なら起動時に選びます
  server_cmd = nil,               -- LSP サーバーの起動コマンド。nil なら自分で探します
  log = false,                    -- 診断ログ。true で既定のパス、文字列ならそのパスに書きます
  notations = {},                 -- ユーザー定義の装飾記法。下の「カスタマイズアノテーションの書き方」
  keymaps = true,                 -- 上の「キーマップ」。false で 1 つも入れません
  open_external_link = 'confirm', -- 外部 URL を開くとき。'always' は確認なし、'never' は何もしません
  open_video = 'browser',         -- 動く Gyazo キャプチャの行き先。コマンドのリストや関数も渡せます

  sidebar = {
    width = 32,            -- 幅
    separator = true,      -- 行ごとの区切り線。'#RRGGBB' で色を指定、false で無し
    thumbnails = false,    -- 各ページの最初の画像を行頭に出します（画像バックエンドが要ります）
    refresh_interval = 60, -- 一覧を取り直す間隔（秒）。false で止まります（最短 5 秒）
    tabs = {               -- 上部のタブ。フィルタやリンクで絞ったタブを足せます
      { name = 'すべて' },
      { name = '未読', mine = true, unread = true },
    },
  },

  related = {
    position = 'bottom', -- 関連ページパネルの位置。'right' なら全高の縦カラム
    height = 8,          -- 'bottom' のときの高さ
    width = 40,          -- 'right' のときの幅
    auto_open = true,    -- ページを開いたら関連パネルも開きます
  },

  edit = {
    autosave = false,                                         -- 編集が止まって n 秒後に保存。false で手動だけ
    sync = { interval = 30, on_focus = true, notify = true }, -- 背後での同期
    save_status = true,                                       -- 保存状態のアイコン。{ icons = {...}, echo = false } で調整
    completion = 'auto',                                      -- 'auto' は外部エンジンが無いときだけ内蔵補完を使います
    autopair = true,                                          -- `[` で `[]` を入れます
    table_tab = true,                                         -- テーブル行の <Tab> は本物のタブ
    surround = true,                                          -- visual モードの装飾キー。記号のリストで限定できます
    paste_indent = true,                                      -- p / P で貼った行を、その行の字下げに揃えます
    date_format = '%Y-%m-%d %H:%M:%S',                        -- insert_date が入れる書式（os.date）
  },

  view = {
    conceal = true,                              -- 記法のマークアップを隠し、カーソル行だけ元に戻します
    pads = true,                                 -- 箇条書きの中点
    quote = true,                                -- `>` 行の縦棒と背景
    telomere = { bar = true, scrollbar = true }, -- 行ごとの更新バーと、右端の一覧
    tables = true,                               -- table: ブロックの罫線。{ border = false, header = false }
    codeblock_numbers = true,                    -- コードブロックの行番号
    file_icon = '󰈔',                             -- アップロード済みファイルへのリンクに付くアイコン
    title_margin = 1,                            -- タイトル行の下に入れる仮想空行の数
    spacing = { line = 0, code = 0 },            -- 行間に入れる仮想空行
  },

  image = {
    enabled = true,     -- 描画バックエンドが使えるときに描きます
    backend = 'auto',   -- 'auto' は image.nvim を優先し、無ければ snacks.nvim に落ちます
    height = 20,        -- 単独行の画像の高さの上限（行数）。小さい画像はそのままです
    height_large = nil, -- `[[…]]` の高さ。nil なら height の 2 倍
    gallery = true,     -- 画像だけの行を、同じ大きさのタイルで横に並べます
    border = true,      -- 画像に合成する枠。{ width = 1, color = '#8888', padding = 12 }
  },
})
```

`origin` `server_cmd` `log` `notations` の 4 つは LSP サーバーの起動時に渡すので、プロジェクトごとには
変えられません。`sidebar.tabs` や `image.backend` のように中身のある値は
[docs/FEATURES.md](docs/FEATURES.md) に節があります。

### カスタマイズアノテーションの書き方

`notations` に記号を並べると、`[<記号> 本文]` を自分の記法として読ませられます。Cosense の web 版では
記号ごとのクラスが付いた装飾になるので、見た目はプロジェクトの CSS 次第です。

```lua
require('chatora').setup({
  notations = {
    ['|'] = { name = 'highlight', hl = { bg = '#3a3a00', bold = true } },
    ['='] = { name = 'boxed', hl = { link = 'WarningMsg' } },
    ['@'] = { name = 'heading', icon = '📌', hl = { bold = true }, rule = true },
  },
})
```

| フィールド | 意味                                                                    |
| ---------- | ----------------------------------------------------------------------- |
| キー       | 1 文字の記号です。公式記法の記号（`* / - _ $ [`）とは衝突できません     |
| `name`     | 英数字と `_` だけです。semantic token の型名になります                  |
| `hl`       | `nvim_set_hl` にそのまま渡ります。文字色は `fg` です                    |
| `icon`     | 開きマーカーの代わりに出す 1 文字です。カーソル行では元の記号が見えます |
| `rule`     | `true` でその行の下に罫線を引きます。色は `rule_hl` です                |

記号は連ねられます。`[|* 特徴]` なら highlight と太字の両方が効きます。属性がぶつかったときは先に
書いた記号が勝ち、カスタム記法は公式記法（`*` `/` `-` `_`）より上です。

設定を間違えてもプラグインは落ちません。おかしなエントリだけを無視して `vim.notify` で知らせます。
詳しくは[カスタム装飾記法](docs/FEATURES.md#カスタム装飾記法)を見てください。

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
