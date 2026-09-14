<div align="center">

# Chatora

<a href="https://gyazo.com/ffd4dd701f2241264fb6b5587f523480">
  <img src="https://i.gyazo.com/ffd4dd701f2241264fb6b5587f523480.png" width="100" alt="Chatora" />
</a>

Cosense（旧 Scrapbox）を Neovim から読み書きする非公式プラグイン

</div>

Chatora は、Cosense のページを Neovim のバッファとして開き、普段の編集操作で読んだり書いたり
するためのプラグインです。ページの閲覧・編集だけでなく、リンクの移動、ページ検索、関連ページの
表示、画像の貼り付けにも対応しています。

> [!NOTE]
> Chatora は Cosense の [Personal Access Token（PAT）](https://scrapbox.io/help-jp/Personal_Access_Token)
> を使って API に接続します。リアルタイム通信ではないため、同じページを複数の場所で同時に編集する
> ときは、競合に注意してください。

詳しい機能は、[高度な機能](docs/advanced.md)、[設定ガイド](docs/configuration.md)、[外部連携](docs/integrations.md) に分けて説明しています。

## 目次

- [デモ](#デモ)
- [名前の由来](#名前の由来)
- [対応している機能](#対応している機能)
- [動作環境](#動作環境)
- [インストール](#インストール)
- [基本操作](#基本操作)
- [設定](#設定)
- [コマンドラインから起動する](#コマンドラインから起動する)
- [telescope.nvim と連携する](#telescopenvim-と連携する)
- [macOS で Cosense のリンクを開く](#macos-で-cosense-のリンクを開く)
- [トラブルシューティング](#トラブルシューティング)
- [クレジット](#クレジット)
- [ライセンス](#ライセンス)

## デモ

[![Chatora のデモ](https://i.gyazo.com/37dd99cd83a884213a5d1422d93667d2.gif)](https://gyazo.com/37dd99cd83a884213a5d1422d93667d2)

## 名前の由来

「Chatora」は、日本語の「茶トラ猫」に由来します。

[![Chatora の名前の由来](https://i.gyazo.com/53c8c22753ff50e183b6c0c9c69dc3a5.gif)](https://gyazo.com/53c8c22753ff50e183b6c0c9c69dc3a5)

## 対応している機能

### プロジェクト

- [x] プロジェクト一覧の取得
- [x] プロジェクトの切り替え
- [ ] プロジェクトの作成・削除
- [ ] メンバー一覧の取得、メンバーの追加・削除
- [ ] メンバー権限の変更、プロジェクト設定の変更

### ページ

- [x] ページ一覧の表示
- [x] ページの作成・更新・削除
- [x] ページ検索
- [x] ページ情報の表示
- [x] 関連ページの表示
- [x] ページのリネームと、被リンクの更新
- [ ] ページ履歴の取得

### Cosense の記法

- [x] 基本的な記法
  - [x] ページリンク <code>[ページ名]</code>
  - [x] 行リンク <code>[ページ名#行ID]</code>
  - [x] 別プロジェクトへのリンク <code>[/other-project/page]</code>
  - [x] 外部リンク <code>[https://example.com]</code>
  - [x] リンク文字を指定した外部リンク <code>[リンク文字 https://example.com]</code>
  - [x] 強調 <code>[* 強調]</code>、<code>[[強調]]</code>
  - [x] アイコン <code>[user.icon]</code>
  - [x] 下線 <code>[_ 下線]</code>
  - [x] 斜体 <code>[/ 斜体]</code>
  - [x] 打ち消し線 <code>[- 打ち消し線]</code>
  - [x] 引用 <code>&gt; </code>
  - [x] コードブロック <code>code:&lt;言語&gt;:</code>、<code>code:</code>
  - [x] インラインコード <code>&#96;code&#96;</code>
  - [x] 画像 <code>[画像URL.png]</code>
  - [x] Gyazo 動画 <code>[Gyazo動画URL]</code>
  - [x] Cosense のファイルリンク <code>[https://scrapbox.io/file/&lt;プロジェクト名&gt;/&lt;ファイル名&gt;]</code>
  - [ ] 数式 <code>[$ 数式]</code>
  - [ ] Mermaid <code>mermaid:</code>
  - [ ] Gyazo 以外の動画 <code>[動画URL]</code>
- [x] テーブルの表示
- [x] カスタム装飾記法
- [x] 箇条書きの中点表示

### その他

- [x] ページリンクの補完
- [x] 画像のアップロード（Cosense のファイル領域、Gyazo）
- [x] テロメア（行ごとの更新表示）
- [x] 既読・未読の表示
- [x] アイコン・日時の挿入
- [ ] ファイルのアップロード
- [ ] <code>smart context</code>
- [ ] <code>export for ai</code>

## 動作環境

| ソフトウェア | バージョン |
| --- | --- |
| Neovim | 0.11 以上 |
| Node.js | 20 以上 |

現在は macOS と Ghostty を主な動作確認環境としています。

| ターミナル | 状況 |
| --- | --- |
| Ghostty | 確認済み |
| kitty / WezTerm | kitty graphics protocol に対応していますが、未確認です |
| VS Code の内蔵ターミナル | 設定が必要です。詳しくは [画像の表示](docs/advanced.md#画像の表示) を参照してください |

画像を表示するには、kitty graphics protocol に対応したターミナル（kitty / Ghostty など）と、
画像表示用のプラグイン（[3rd/image.nvim](https://github.com/3rd/image.nvim) など）が必要です。

## インストール

lazy.nvim では、次のように設定します。

~~~lua
{
  'qaynam/chatora',
  version = '*',
  cmd = 'Chatora',
  dependencies = {
    { '3rd/image.nvim', opts = { processor = 'magick_cli' } },
  },
  opts = {
    default_project = 'my-project',
  },
}
~~~

画像を表示する場合は、[ImageMagick](https://imagemagick.org/) もインストールしてください。

~~~sh
brew install imagemagick
~~~

クリップボードから画像を貼り付ける場合は、macOS では [pngpaste](https://github.com/jcsalterego/pngpaste) が必要です。

~~~sh
brew install pngpaste
~~~

Linux で画像を貼り付ける場合は、環境に応じて <code>wl-paste</code> または <code>xclip</code> が利用されます。

初回起動時に PAT の入力を求められます。macOS では、入力した PAT が Chatora の認証情報として保存
され、以後の接続に使われます。複数の PAT を登録した場合は、<code>:Chatora account</code> で切り替えられます。

## 基本操作

### コマンド

| コマンド | 動作 |
| --- | --- |
| <code>:Chatora</code> | サイドバーを開く。初回は PAT 認証とプロジェクト選択を行います |
| <code>:Chatora &lt;url&gt;</code> | Cosense のページ URL を開く |
| <code>:Chatora open [url]</code> | サイドバー、または指定したページを開く |
| <code>:Chatora toggle</code> | サイドバーを開閉する |
| <code>:Chatora new [title]</code> | 新しいページを開く。タイトルを省略すると、1 行目がタイトルになります |
| <code>:Chatora search [query]</code> | ページを検索する。検索語を省略すると入力欄が開きます |
| <code>:Chatora related</code> | 関連ページパネルを開閉する |
| <code>:Chatora project [name]</code> | プロジェクトを切り替える |
| <code>:Chatora account</code> | アカウントを切り替える、または追加する |
| <code>:Chatora logout</code> | 現在のアカウントの PAT を削除する |
| <code>:Chatora images [redraw&#124;clear]</code> | 画像の状態を表示する。<code>redraw</code> で再描画し、<code>clear</code> でキャッシュを削除して再取得します |
| <code>:Chatora help</code> | 操作一覧を表示する |
| <code>:Chatora log</code> | 診断ログを開く。<code>log</code> オプションを有効にしている場合に使えます |
| <code>:Chatora reload</code> | Neovim を再起動せずにプラグインを再読み込みする |

### キーマップ

既定のキーマップは <code>keymaps</code> にまとめられています。設定値はそのまま
<code>vim.keymap.set</code> に渡されるため、配列を指定すれば複数のキーに割り当てられます。
<code>false</code> を指定すると、そのアクションのキーマップを無効にできます。

<code>prefix</code> は <code>&lt;leader&gt;c</code> 系の先頭部分です。<code>prefix = false</code> にすると、
<code>&lt;leader&gt;c</code> 系のキーマップをまとめて無効にできます。

~~~lua
require('chatora').setup({
  keymaps = {
    prefix = '<leader>c',
    sidebar = 'gk',
    follow = { 'gd', '<CR>' },
    copy_url = false,
  },
})
~~~

<code>keymaps = false</code> を指定すると、既定のキーマップは登録されません。ただし、
<code>&lt;Plug&gt;(chatora-&lt;アクション名&gt;)</code> は利用できるため、自分でキーマップを定義できます。
アクション名に <code>_</code> が含まれる場合、<code>&lt;Plug&gt;</code> では <code>-</code> に置き換わります。

~~~lua
require('chatora').setup({ keymaps = false })

vim.keymap.set('n', '<leader>k', '<Plug>(chatora-sidebar)')
vim.api.nvim_create_autocmd('FileType', {
  pattern = 'cosense',
  callback = function(ev)
    vim.keymap.set('n', 'gd', '<Plug>(chatora-follow)', { buffer = ev.buf })
    vim.keymap.set('n', '<leader>p', require('chatora.actions').pull, { buffer = ev.buf })
  end,
})
~~~

<code>require('chatora.actions').&lt;アクション名&gt;()</code> を直接呼び出すこともできます。ページバッファの
キーマップはバッファごとに設定されるため、独自に設定する場合は <code>FileType cosense</code> を利用してください。

#### Neovim 全体

| 既定のキー | アクション | 動作 |
| --- | --- | --- |
| <code>&lt;leader&gt;ct</code> | <code>sidebar</code> | サイドバーを開閉 |
| <code>&lt;leader&gt;cs</code> | <code>search</code> | ページを検索 |
| <code>&lt;leader&gt;cn</code> | <code>new</code> | 新しいページを開く |
| <code>&lt;leader&gt;cp</code> | <code>project</code> | プロジェクトを切り替える |
| <code>&lt;leader&gt;ca</code> | <code>account</code> | アカウントを切り替える |
| <code>&lt;leader&gt;c?</code> | <code>help</code> | ヘルプを開く |

#### ページバッファ

| 既定のキー | アクション | 動作 |
| --- | --- | --- |
| <code>gd</code> | <code>follow</code> | リンク先へ移動する。行リンクは該当行へ、外部 URL はブラウザで開きます |
| <code>&lt;leader&gt;cr</code> / <code>gR</code> | <code>related</code> | 関連ページパネルを開閉 |
| <code>&lt;leader&gt;cR</code> | <code>related_side</code> | 関連ページパネルの位置を下／右で切り替え |
| <code>&lt;leader&gt;ci</code> | <code>info</code> | ページ情報を表示 |
| <code>&lt;leader&gt;cf</code> | <code>pull</code> | サーバーの変更を取り込む |
| <code>&lt;leader&gt;cc</code> / <code>]c</code> | <code>next_conflict</code> | 次の競合行へ移動 |
| <code>]u</code> / <code>[u</code> | <code>next_updated</code> / <code>prev_updated</code> | 次／前の更新行へ移動 |
| <code>&lt;leader&gt;cv</code> | <code>paste_image</code> | クリップボードの画像を貼り付け |
| <code>&lt;leader&gt;cd</code> | <code>delete</code> | ページを削除（確認あり） |
| <code>&lt;leader&gt;cI</code> | <code>normalize_indent</code> | インデントを半角スペースに揃える |
| <code>&lt;leader&gt;cy</code> | <code>copy_url</code> | ページ URL をコピー |
| <code>&lt;leader&gt;cY</code> | <code>copy_link</code> | <code>[タイトル]</code> の形式でリンクをコピー |
| <code>&lt;leader&gt;co</code> | <code>open_in_browser</code> | ページをブラウザで開く |
| <code>:w</code> / <code>:wq</code> | — | ページを保存する |

#### Insert モード

| 既定のキー | 動作 |
| --- | --- |
| <code>&lt;C-t&gt;</code> | 日時を挿入 |
| <code>&lt;C-i&gt;</code> / <code>&lt;M-i&gt;</code> | アイコンを挿入 |
| <code>[</code> | <code>[]</code> を自動的に補完 |
| <code>&lt;Tab&gt;</code> | テーブル行ではタブを入力し、それ以外では既存のマッピングに委譲 |

#### サイドバー

| キー | 動作 |
| --- | --- |
| <code>&lt;CR&gt;</code> / <code>l</code> | ページを開く。フォルダーの見出しでは開閉します |
| <code>&lt;Tab&gt;</code> / <code>&lt;S-Tab&gt;</code> / <code>1</code>〜<code>9</code> | タブを切り替える |
| <code>R</code> | 一覧を再読み込み |
| <code>s</code> | ページを検索 |
| <code>n</code> | 新しいページを開く |
| <code>P</code> | プロジェクトを切り替える |
| <code>A</code> | アカウントを切り替える |
| <code>q</code> | サイドバーを閉じる |

サイドバーの行頭には、保存状態（<code>✓</code> / <code>●</code>）と未読マーク（<code>▍</code>）が表示されます。
未読マークは、最後に開いてから更新されたページに付きます。

#### Visual モード

テキストを選択して記号を押すと、その範囲を装飾記法で囲みます。同じキーをもう一度押すと、
入れ子にはせず、装飾の種類だけを変更します。

| キー | 結果 |
| --- | --- |
| <code>*</code> | <code>[* 選択範囲]</code> |
| <code>*</code> を複数回 | <code>[*** 選択範囲]</code>（<code>[*****]</code> まで） |
| <code>_</code> / <code>-</code> / <code>/</code> | <code>[_ 選択範囲]</code> など |
| <code>[</code> | <code>[選択範囲]</code> |
| ユーザー定義の記号 | <code>[&lt;記号&gt; 選択範囲]</code> |

<code>edit = { surround = false }</code> を指定すると無効にできます。記号のリストを指定すると、
その記号だけを有効にできます。

## 設定

<code>setup()</code> に設定を渡します。lazy.nvim を使う場合は <code>opts</code> に指定できます。
指定した項目だけが既定値から変更されるため、必要な項目だけを設定してください。

~~~lua
require('chatora').setup({
  origin = 'https://scrapbox.io', -- Cosense の URL
  default_project = nil,          -- 起動時に開くプロジェクト。nil なら選択画面を表示
  server_cmd = nil,               -- LSP サーバーの起動コマンド。nil なら自動検出
  log = false,                    -- 診断ログ。true で既定の場所、文字列で保存先を指定
  notations = {},                 -- ユーザー定義の装飾記法
  keymaps = true,                 -- false で既定のキーマップを無効化
  open_external_link = 'confirm', -- 外部 URL を開くときの確認。'always' / 'never' も指定可能
  open_video = 'browser',         -- Gyazo 動画の開き先

  sidebar = {
    width = 32,            -- サイドバーの幅
    separator = true,      -- 行ごとの区切り線。色文字列または false も指定可能
    thumbnails = false,    -- 各ページの最初の画像を表示（画像バックエンドが必要）
    refresh_interval = 60, -- 一覧を更新する間隔（秒）。false で自動更新を停止
    tabs = {
      { name = 'すべて' },
      { name = '未読', mine = true, unread = true },
    },
  },

  related = {
    position = 'bottom', -- 関連ページパネルの位置。'right' で右側に表示
    height = 8,          -- 下に表示するときの高さ
    width = 40,          -- 右に表示するときの幅
    auto_open = true,    -- ページを開いたときに自動表示
  },

  edit = {
    autosave = false,                                         -- 編集が止まってから保存するまでの秒数
    sync = { interval = 30, on_focus = true, notify = true }, -- サーバーとの自動同期
    save_status = true,                                       -- 保存状態を表示
    completion = 'auto',                                      -- 外部補完がないときだけ内蔵補完を使う
    autopair = true,                                          -- [ を入力すると [] を挿入
    table_tab = true,                                         -- テーブル行の <Tab> に本物のタブを使う
    surround = true,                                          -- Visual モードの装飾
    paste_indent = true,                                      -- 貼り付けた行のインデントを揃える
    paste_link = true,                                        -- 貼り付けたページ URL をリンク記法に変換
    date_format = '%Y-%m-%d %H:%M:%S',                        -- 日時の書式（os.date）
  },

  view = {
    conceal = true,                              -- 記法のマークアップを隠す
    pads = true,                                 -- 箇条書きの中点
    quote = true,                                -- 引用の縦棒と背景
    telomere = { bar = true, scrollbar = true }, -- 行ごとの更新バーとスクロールバー
    tables = true,                               -- テーブルの罫線
    codeblock_numbers = true,                    -- コードブロックの行番号
    file_icon = '󰈔',                             -- アップロード済みファイルのアイコン
    title_margin = 1,                            -- タイトル下の余白
    spacing = { line = 0, code = 0 },            -- 行間の余白
  },

  image = {
    enabled = true,     -- 画像表示を有効化
    backend = 'auto',   -- image.nvim を優先し、なければ snacks.nvim を使用
    height = 20,        -- 単独行の画像の高さの上限
    height_large = nil, -- [[…]] の画像の高さ。nil なら height の 2 倍
    gallery = true,     -- 画像だけの行をタイル状に表示
    border = true,      -- 画像の枠
  },
})
~~~

<code>origin</code>、<code>server_cmd</code>、<code>log</code>、<code>notations</code> は LSP サーバーの起動時に
読み込まれるため、プロジェクトごとには変更できません。<code>sidebar.tabs</code> や
<code>image.backend</code> などの詳しい設定は [高度な機能](docs/advanced.md) と [設定ガイド](docs/configuration.md) にまとめています。

### 装飾記法をカスタマイズする

<code>notations</code> に記号を追加すると、<code>[&lt;記号&gt; 本文]</code> を独自の装飾記法として扱えます。

~~~lua
require('chatora').setup({
  notations = {
    ['|'] = { name = 'highlight', hl = { bg = '#3a3a00', bold = true } },
    ['='] = { name = 'boxed', hl = { link = 'WarningMsg' } },
    ['@'] = { name = 'heading', icon = '📌', hl = { bold = true }, rule = true },
  },
})
~~~

| 項目 | 説明 |
| --- | --- |
| キー | 1 文字の記号。公式記法（<code>*</code>、<code>/</code>、<code>-</code>、<code>_</code>、<code>$</code>、<code>[</code>）は使用できません |
| <code>name</code> | 英数字と <code>_</code> のみ。semantic token の型名になります |
| <code>hl</code> | <code>nvim_set_hl</code> に渡すハイライト設定 |
| <code>icon</code> | 開始記号の代わりに表示する 1 文字 |
| <code>rule</code> | <code>true</code> で行の下に罫線を表示 |

## コマンドラインから起動する

<code>bin/chatora</code> を使うと、ターミナルから Chatora を起動できます。lazy.nvim でインストールした
場合は、プラグインのインストール先にある <code>bin</code> ディレクトリを PATH に追加すると便利です。

~~~sh
chatora                         # 設定したプロジェクトのサイドバーを開く
chatora -p my-project           # 指定したプロジェクトを開く
chatora https://scrapbox.io/proj/Page_Title
chatora open https://scrapbox.io/proj/Page
chatora -p my-project notes.md  # そのほかの引数は nvim に渡す
~~~

<code>-p</code>（<code>--project</code>）で指定したプロジェクトが現在のアカウントにない場合、保存済みの
別アカウントを確認し、見つかったアカウントに切り替えて開きます。公開プロジェクトは、メンバーで
なくても読み取り専用で開けます。

詳しい使い方は <code>chatora --help</code> で確認できます。

## telescope.nvim と連携する

Cosense の全文検索を telescope.nvim のピッカーで使うこともできます。

~~~lua
require('telescope').load_extension('chatora')
~~~

設定後、<code>:Telescope chatora search</code>（<code>:Telescope chatora</code> でも同じ）で検索できます。
Chatora に内蔵されている <code>:Chatora search</code> とは別の検索画面です。

## macOS で Cosense のリンクを開く

<code>bin/chatora-url-handler</code> を使うと、Slack や Discord などでクリックした Cosense のリンクを、
ブラウザではなく、起動中の Chatora で開けます。macOS のみ対応しています。

~~~sh
bin/chatora-url-handler install
~~~

インストール後、macOS の「システム設定 → デスクトップと Dock → デフォルトの Web ブラウザ」で
<code>Chatora Open</code> を選択してください。

Cosense 以外の URL は、登録時に選択したブラウザへ転送されます。転送先を変更する場合は、次の
コマンドを実行します。

~~~sh
chatora-url-handler browser
~~~

対象にする origin は <code>~/.local/share/chatora/url-handler/origins</code> に 1 行ずつ記述します。
既定値は <code>scrapbox.io</code> です。現在の設定は <code>chatora-url-handler status</code>、
アンインストールは <code>chatora-url-handler uninstall</code> で確認・実行できます。

## トラブルシューティング

### <code>&lt;C-i&gt;</code> でアイコンを挿入できない

端末が <code>&lt;C-i&gt;</code> と <code>&lt;Tab&gt;</code> を区別して入力できない場合があります。その場合は、
既定で用意されている <code>&lt;M-i&gt;</code>（Alt+i）を使ってください。

kitty、Ghostty、WezTerm では通常そのまま動作します。tmux 越しに使う場合は、次の設定が必要に
なることがあります。

~~~tmux
set -g extended-keys on
~~~

Ghostty では、次の設定で Cmd+I を <code>&lt;M-i&gt;</code> として送信できます。

~~~ini
keybind = cmd+i=text:\x1bi
~~~

### ページや画像を読み込めない、HTTP エラーが出る

<code>log = true</code> を設定してから <code>:Chatora log</code> を実行してください。HTTP レスポンスと
エラーの詳細を確認できます。

画像が表示されない場合は、対応するターミナル、ImageMagick、画像表示プラグインがそろっているか
確認してください。画像の詳しい設定は [画像の表示](docs/advanced.md#画像の表示) を参照してください。

### コードブロックに色が付かない

必要なのは、その言語の LSP ではなく Tree-sitter のパーサーです。たとえば PHP なら、次を実行
してください。

~~~vim
:TSInstall php php_only
~~~

言語は <code>code:&lt;ファイル名&gt;</code> の拡張子から決まります。拡張子に対応する filetype が
無い場合は、拡張子そのものを言語として扱います。パーサーが存在しない <code>mdx</code> は
Markdown として読みます。JSX は Markdown の HTML 埋め込みとして色が付きます。

ブロックの中に別の言語が埋め込まれている場合（Markdown の中のコードフェンス、Markdown の
frontmatter、HTML の中の JavaScript など）も、埋め込み側の言語で色を付けます。ただし、その言語の
パーサーが必要です。

### 保存時に競合が発生する

同じ行をサーバー側でも編集している可能性があります。<code>]c</code> で競合行へ移動し、内容を確認・
修正してから、もう一度 <code>:w</code> で保存してください。

## クレジット

- [helpfeel/cosense-cli](https://github.com/helpfeel/cosense-cli)
- [cosense-toolbox/parser](https://www.npmjs.com/package/@cosense-toolbox/parser)
- [3rd/image.nvim](https://github.com/3rd/image.nvim)
- [folke/snacks.nvim](https://github.com/folke/snacks.nvim)
- [petertriho/nvim-scrollbar](https://github.com/petertriho/nvim-scrollbar)
- [folke/lazy.nvim](https://github.com/folke/lazy.nvim)

## ライセンス

[MIT](LICENSE)
