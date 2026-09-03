<div align="center">

# Chatora

<a href="https://gyazo.com/ffd4dd701f2241264fb6b5587f523480">
  <img src="https://i.gyazo.com/ffd4dd701f2241264fb6b5587f523480.png" width="140" alt="Chatora" />
</a>

Cosense（旧 Scrapbox）を Neovim から読み書きするためのプラグイン

</div>

## デモ

[![Image from Gyazo](https://i.gyazo.com/37dd99cd83a884213a5d1422d93667d2.gif)](https://gyazo.com/37dd99cd83a884213a5d1422d93667d2)

**記法比較**

[![Image from Gyazo](https://gyazo.com/64a2afa81502a5152d53530239ae5950.png)](https://gyazo.com/64a2afa81502a5152d53530239ae5950)
[![Image from Gyazo](https://gyazo.com/68b9ab61aebd4976a1ac66be235cc7ea.png)](https://gyazo.com/68b9ab61aebd4976a1ac66be235cc7ea)
[![Image from Gyazo](https://gyazo.com/5424457517ae6a2f9cca2d5c7592c03b.png)](https://gyazo.com/5424457517ae6a2f9cca2d5c7592c03b)

## 名前の由來

- 日本語の茶トラ猫から来ている
- [![Image from Gyazo](https://i.gyazo.com/53c8c22753ff50e183b6c0c9c69dc3a5.gif)](https://gyazo.com/53c8c22753ff50e183b6c0c9c69dc3a5)

## 特長

- **編集はローカル、同期はマージ**
  - 開いているページは、バックグラウンドでサーバーと同期します
  - 取り込みは上書きではなく行 ID ベースの三方向マージなので、書きかけの内容が消えることはありません
- **記法のハイライト**
  - 装飾・リンク・コードブロック・テーブル・引用・画像を、LSP semantic tokens で描きます
  - マークアップはカーソル行以外では隠すので、Cosense の web 版に近い見た目になります
- **リンク補完と定義ジャンプ**
  - Cosense の web 版と同じく、リンク補完も赤リンクも使えます
  - `[` や `#` で候補が出て、`gd` でそのページへジャンプできます
- **テロメア**
  - 行ごとの更新の新しさを、左端のバーで示します。誰かが書き換えた行も、まだ保存していない行も一目で分かります
- **画像のインライン表示と貼り付け**
  - 対応ターミナルなら本文中に描画します。クリップボードの画像は、`<leader>cv` でそのままアップロードできます
- **Cosense のエディタ操作**
  - `<C-t>` で日時挿入、`<C-i>` でアイコン挿入、`[` は自動でペアになり、visual モードでは `*` や `[` を押して選択を囲めます
- **PAT 認証・複数アカウント**
  - PAT は macOS Keychain に保存し、`:Chatora account` で切り替えられます

## 必要なもの

|         |                             |
| ------- | --------------------------- |
| Neovim  | >= 0.11                     |
| Node.js | >= 20（LSP サーバーの実行） |

このほか、[ImageMagick](https://imagemagick.org/) と画像描画プラグインがあれば画像を表示でき
（[画像の表示](docs/FEATURES.md#画像の表示)）、クリップボード取り出しツールがあれば画像を貼り付け
られます（[画像の貼り付け](docs/FEATURES.md#画像の貼り付け)）。どちらも任意です。

PAT の保存先が macOS Keychain なので、**アカウントの追加と切り替えは macOS でしか動きません**。
Linux や Windows でも、環境変数 `COSENSE_PAT` に PAT を入れておけば読み書きそのものは動きます。
他の OS の資格情報ストアには対応していません。

### ターミナル

テキストの読み書きはどのターミナルでも動きます。ターミナルによって変わるのは、画像を描けるか
どうかだけです。

| ターミナル               | 画像                                                                                            |
| ------------------------ | ----------------------------------------------------------------------------------------------- |
| Ghostty                  | 確認済み（作者が常用しているのはここ）                                                          |
| kitty / WezTerm          | 同じ kitty graphics protocol なので動くはずですが、未確認です                                   |
| VS Code の内蔵ターミナル | 設定すれば描けます。[VS Code で画像を出す](docs/FEATURES.md#vs-code-で画像を出す)を見てください |
| そのほか                 | kitty graphics protocol か sixel のどちらかを話せば描けます                                     |

## インストール

[lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  'qaynam/chatora',
  version = '*',
  build = 'sh scripts/install-server.sh',
  cmd = 'Chatora',
  -- 画像を出すなら（任意）。snacks.nvim を既に入れているなら、そちらでも描けます
  dependencies = { { '3rd/image.nvim', opts = { processor = 'magick_cli' } } },
  opts = {
    project = 'your-project',  -- 省略すると起動時に選択モーダルが表示される
    -- その他のオプションは下記を参照してください
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
使っていたブラウザにそのまま流れます。詳しくは
[Slack や Chrome のリンクを chatora で開く](docs/FEATURES.md#slack-や-chrome-のリンクを-chatora-で開くmacos)
を見てください。

## コマンド

| コマンド                  | 動作                                                                               |
| ------------------------- | ---------------------------------------------------------------------------------- |
| `:Chatora`                | サイドバーを開く（初回は認証 → プロジェクト選択）                                  |
| `:Chatora <url>`          | Cosense のページ URL をそのまま開く                                                |
| `:Chatora toggle`         | サイドバーを開閉                                                                   |
| `:Chatora new [title]`    | 新規ページ（title 省略時は入力プロンプト）                                         |
| `:Chatora search [query]` | 全文検索（内蔵ピッカー）                                                           |
| `:Chatora related`        | 関連ページパネルを開閉                                                             |
| `:Chatora account`        | アカウントの切り替え・追加                                                         |
| `:Chatora project [name]` | プロジェクトの切り替え。名前を渡すとそのプロジェクトを持つアカウントごと切り替える |
| `:Chatora logout`         | 現在のアカウントを削除                                                             |
| `:Chatora log`            | 診断ログを開く（`log` オプションが必要）                                           |
| `:Chatora reload`         | プラグインを再読み込み（開発用）                                                   |
| `:Chatora help`           | チートシート                                                                       |

## キーマップ

### グローバル（`<leader>c`）

`keymaps.prefix`（既定は `<leader>c`）の下にまとめて並びます。`prefix = false` を渡すと、
グローバルのキーマップを一つも登録しません。

| キー         | 動作                             | アクション名       |
| ------------ | -------------------------------- | ------------------ |
| `<leader>ct` | サイドバーを開閉                 | `toggle`           |
| `<leader>cs` | ページを検索                     | `search`           |
| `<leader>cn` | 新規ページ                       | `new`              |
| `<leader>cr` | 関連ページを開閉                 | `related`          |
| `<leader>cR` | 関連ページを下／右に切り替え     | `related_side`     |
| `<leader>ci` | ページ情報                       | `info`             |
| `<leader>cf` | サーバーの変更を取り込む         | `pull`             |
| `<leader>cc` | 次の競合行へ                     | `next_conflict`    |
| `<leader>cv` | クリップボードの画像を貼り付け   | `paste_image`      |
| `<leader>cd` | ページを削除（確認あり）         | `delete`           |
| `<leader>cI` | インデントを半角スペースに揃える | `normalize_indent` |
| `<leader>cy` | ページ URL をコピー              | `copy_url`         |
| `<leader>cY` | リンク記法 `[タイトル]` をコピー | `copy_link`        |
| `<leader>co` | ブラウザで開く                   | `open_in_browser`  |
| `<leader>ca` | アカウント切り替え               | `account`          |
| `<leader>cp` | プロジェクト切り替え             | `project`          |
| `<leader>c?` | ヘルプ                           | `help`             |

個別に変えたい場合は、アクション名をキーにして書きます。

```lua
keymaps = { info = '<leader>ck', copy_url = false }
```

### ページバッファ

| キー         | 動作                                                                  |
| ------------ | --------------------------------------------------------------------- |
| `gd`         | リンク先へジャンプ（`[ページ#行ID]` はその行へ、外部 URL はブラウザ） |
| `gR`         | 関連ページパネルを開閉                                                |
| `gs`         | ページを検索                                                          |
| `]c`         | 次の競合行へ                                                          |
| `]u` / `[u`  | 次 / 前の更新行へ（右端のマークが指している行）                       |
| `:w` / `:wq` | 保存（同期）                                                          |

### サイドバー

| キー                           | 動作                                                     |
| ------------------------------ | -------------------------------------------------------- |
| `<CR>` / `l`                   | 開く                                                     |
| `<Tab>` / `<S-Tab>` / `1`..`9` | タブ切り替え（クリックも可）                             |
| `R`                            | 再読込                                                   |
| `s`                            | 検索                                                     |
| `n`                            | 新規ページ                                               |
| `P`                            | プロジェクト切り替え（他アカウントのプロジェクトも並ぶ） |
| `A`                            | アカウント切り替え                                       |
| `q`                            | 閉じる                                                   |

行頭には保存状態（`✓` / `●`）と未読バー（`▍`）が出ます。未読バーは、最後に開いたあとに
更新されたページに付きます。

### insert モード

| キー              | 動作                                                        |
| ----------------- | ----------------------------------------------------------- |
| `<C-t>`           | 日時を挿入                                                  |
| `<C-i>` / `<M-i>` | アイコンを挿入（[下記](docs/FEATURES.md#アイコン挿入)）     |
| `[`               | `[]` を自動ペア（リンク補完はこの閉じたペアの中でのみ発火） |
| `<Tab>`           | テーブル行では本物のタブ、それ以外は元のマッピングに委譲    |

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

`surround = false` を渡すとすべて無効になり、記号のリストを渡すと、その記号だけが有効になります。

## 設定

`setup()`（lazy.nvim なら `opts`）に渡します。既定値は `lua/chatora/config.lua` にまとまっています。

### 接続

| オプション   | 既定                    | 意味                                                                                            |
| ------------ | ----------------------- | ----------------------------------------------------------------------------------------------- |
| `origin`     | `'https://scrapbox.io'` | Cosense の origin                                                                               |
| `project`    | なし                    | 固定するプロジェクト。未指定なら起動時に選択                                                    |
| `server_cmd` | 自動検出                | LSP サーバーの起動コマンド                                                                      |
| `log`        | `false`                 | 診断ログ。`true` で `${XDG_STATE_HOME:-~/.local/state}/chatora/chatora.log`、文字列ならそのパス |

### サイドバー・関連ページ

| オプション          | 既定          | 意味                                                               |
| ------------------- | ------------- | ------------------------------------------------------------------ |
| `sidebar_width`     | `32`          | 幅                                                                 |
| `sidebar_tabs`      | すべて / 未読 | 上部のタブ。[下記](docs/FEATURES.md#サイドバーのタブ)              |
| `sidebar_separator` | `true`        | 行ごとの区切り下線。`'#RRGGBB'` で色を指定、`false` で無効         |
| `sidebar_poll`      | `60`          | n 秒ごとに自動更新。`false` で無効、最短 5 秒                      |
| `related_position`  | `'bottom'`    | 関連ページパネルの位置。`'right'` で全高の縦カラム                 |
| `related_height`    | `8`           | `'bottom'` のときの高さ                                            |
| `related_width`     | `40`          | `'right'` のときの幅                                               |
| `related_auto_open` | `true`        | ページを開いたら関連パネルも開く。`q` で閉じると次の `gR` まで抑制 |

### 編集・保存

| オプション      | 既定                                                | 意味                                                                                         |
| --------------- | --------------------------------------------------- | -------------------------------------------------------------------------------------------- |
| `sync`          | `{ interval = 30, on_focus = true, notify = true }` | 背後での同期。[下記](docs/FEATURES.md#同期と競合)                                            |
| `autosave`      | `false`                                             | 編集停止から n 秒後に自動保存                                                                |
| `status`        | `true`                                              | 保存状態アイコン。`{ icons = {...}, echo = false }` で調整                                   |
| `keymaps`       | `true`                                              | キーマップ全般。`{ insert_date, insert_icon, date_format, autopair, table_tab, prefix }`     |
| `surround`      | `true`                                              | visual モードの装飾キー。記号のリストで限定、`false` で無効                                  |
| `completion`    | `'auto'`                                            | `'auto'` は外部エンジンが無いときだけ内蔵補完を有効化。`'native'` は常に、`false` は外部任せ |
| `external_link` | `'confirm'`                                         | 外部 URL 上の `gd`。`'open'` は確認なし、`'ignore'` は何もしない                             |
| `video`         | `false`                                             | 動く Gyazo キャプチャ上の `gd` の行き先。[下記](docs/FEATURES.md#動画を再生する)             |

### 表示

| オプション          | 既定                               | 意味                                                                                                                                                                                    |
| ------------------- | ---------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `conceal`           | `true`                             | 記法マークアップを隠す。`true` はカーソル行だけ元の記法に戻す。文字列を渡すとそれが `'concealcursor'` になる（`'nc'` なら読んでいる間は戻さない＝カーソル行のインライン画像も消えない） |
| `pads`              | `true`                             | 箇条書きの中点。[下記](docs/FEATURES.md#箇条書き)                                                                                                                                       |
| `telomere`          | `{ bar = true, scrollbar = true }` | 行ごとの更新バーと右端の一覧。[下記](docs/FEATURES.md#テロメア)                                                                                                                         |
| `quote`             | `true`                             | `>` 行の縦棒。[下記](docs/FEATURES.md#引用)                                                                                                                                             |
| `tables`            | `true`                             | `table:` ブロックの罫線。`{ border = false, header = false }`                                                                                                                           |
| `codeblock_numbers` | `true`                             | コードブロックの行番号                                                                                                                                                                  |
| `file_icon`         | `'󰈔'`                              | プロジェクトにアップロードしたファイルへのリンクに付くアイコン。`false` で無し                                                                                                          |
| `title_margin`      | `1`                                | タイトル行の下に入れる仮想空行の数                                                                                                                                                      |
| `spacing`           | `{ line = 0, code = 0 }`           | 行間に挿入する仮想空行                                                                                                                                                                  |
| `notations`         | `{}`                               | ユーザー定義の装飾記法。[下記](docs/FEATURES.md#カスタム装飾記法)                                                                                                                       |

### 画像

| オプション           | 既定               | 意味                                                                                                                                                                                        |
| -------------------- | ------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `images`             | `'auto'`           | 描画バックエンドが使えるときだけ描く。`false` で無効                                                                                                                                        |
| `image_backend`      | `'auto'`           | `'auto'` は image.nvim 優先で snacks.nvim にフォールバック。`'image_nvim'` / `'snacks'` で固定、テーブル（か、それを返す関数）で自前。[下記](docs/FEATURES.md#描画バックエンドを差し替える) |
| `image_height`       | `20`               | 単独行の画像の高さ（行数）。文中のインライン画像は常に 1 行                                                                                                                                 |
| `image_height_large` | `image_height * 2` | `[[…]]`（大きい記法）の高さ。画像とアイコンの両方に効く                                                                                                                                     |
| `image_gallery`      | `true`             | 画像だけの行を、同じ大きさのタイルを横に並べて描く。[下記](docs/FEATURES.md#画像だけの行)                                                                                                                             |
| `image_border`       | `true`             | 画像に合成する枠。`{ width = 1, color = '#8888', padding = 12 }`                                                                                                                            |

## 機能

機能ごとの詳しい説明は [docs/FEATURES.md](docs/FEATURES.md) にあります。

|                                                                               |                                                                |
| ----------------------------------------------------------------------------- | -------------------------------------------------------------- |
| [同期と競合](docs/FEATURES.md#同期と競合)                                     | 背後で同期し、取り込みは行単位のマージ。競合行は `]c` で回る   |
| [テロメア](docs/FEATURES.md#テロメア)                                         | どこが更新されたかを、行の左のバーと右端のミニマップで示す     |
| [リネームされたページ](docs/FEATURES.md#リネームされたページ)                 | 旧タイトルのリンクはリダイレクトを追って現在のページを開く     |
| [行リンク](docs/FEATURES.md#行リンク)                                         | `[ページ名#行ID]` はその行にカーソルを置いて開く               |
| [別プロジェクトのページ](docs/FEATURES.md#別プロジェクトのページ)             | `[/other-project/page]` を開く。書けないプロジェクトはそう言う |
| [赤リンク](docs/FEATURES.md#赤リンク)                                         | 実体のないページへのリンクを色で示す                           |
| [箇条書き](docs/FEATURES.md#箇条書き)                                         | インデント 1 文字が 1 段。中点を仮想テキストで描く             |
| [引用](docs/FEATURES.md#引用)                                                 | `>` を縦棒に置き換える                                         |
| [カスタム装飾記法](docs/FEATURES.md#カスタム装飾記法)                         | `[<記号> 本文]` の記号を自分で定義する                         |
| [動画を再生する](docs/FEATURES.md#動画を再生する)                             | Gyazo の動画を `gd` で好きなプレイヤーへ渡す                   |
| [ファイルへのリンク](docs/FEATURES.md#ファイルへのリンク)                     | アップロードしたファイルへのリンクにアイコンを出す             |
| [記法の色](docs/FEATURES.md#記法の色)                                         | colorscheme から借りつつ、同じ色を二度使わない                 |
| [画像の表示](docs/FEATURES.md#画像の表示)                                     | 対応ターミナルと描画プラグインがあればバッファ内に描く         |
| [画像だけの行](docs/FEATURES.md#画像だけの行)                                 | 横に並べるか、大きく縦に積むかの二択                           |
| [描画バックエンドを差し替える](docs/FEATURES.md#描画バックエンドを差し替える) | image.nvim / snacks.nvim / 自前のバックエンド                  |
| [画像の貼り付け](docs/FEATURES.md#画像の貼り付け)                             | クリップボードの画像をアップロードして記法を書く               |
| [ページ情報](docs/FEATURES.md#ページ情報)                                     | 作成者・更新・被リンク・閲覧数などを 1 枚に                    |
| [アイコン挿入](docs/FEATURES.md#アイコン挿入)                                 | 押した場所で意味が変わるアイコンキー                           |
| [保存状態の表示](docs/FEATURES.md#保存状態の表示)                             | トーストではなく小さなアイコンで伝える                         |
| [サイドバーとプロジェクト](docs/FEATURES.md#サイドバーとプロジェクト)         | サイドバーは今見ているページのプロジェクトを映す               |
| [サイドバーのタブ](docs/FEATURES.md#サイドバーのタブ)                         | サイドバーに出すリストを選ぶ                                   |
| [連携](docs/FEATURES.md#連携)                                                 | telescope、シェルから起動、Cosense のリンクを chatora で開く   |

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
