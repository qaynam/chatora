# 機能

chatora が何をするかを、機能ごとに説明します。設定できる項目の一覧は
[README の設定](../README.md#設定)にあります。

ここでは「書く・保存する」「見た目」「移動する」「連携」の順に並べます。

## 書く・保存する

### 同期と競合

開いているページは、背後でサーバーと同期します。取り込みは上書きではなくマージなので、
**ローカルで書いた内容が消えることはありません**。

```lua
sync = { interval = 30, on_focus = true, notify = true }  -- 既定
sync = false                                              -- 手動（<leader>cf）だけにする
```

`interval` はポーリングの間隔（秒）です。画面に出ているバッファだけを回し、離れると止まり、
戻ると再開します。`on_focus` を有効にすると、ページに入った瞬間にも一度同期します。`notify` は、
取り込んだ内容と競合の件数を通知します。

マージは行ごとに、行 ID で突き合わせます。そのため、サーバー側で行が並べ替えられたり挿入されたり
しても、ローカルの編集はもとの行についていきます。

| 状況 | 結果 |
|---|---|
| 別々の行を編集した | 両方入ります |
| 同じ行を同じ内容に編集した | 競合しません |
| 同じ行を違う内容に編集した | **ローカルを残し**、競合の印を付けます |
| ローカルで編集した行をサーバーが削除した | **ローカルの行を残し**、競合の印を付けます |
| ローカルで削除した行をサーバーが編集した | サーバーの行が戻り、競合の印を付けます |

最後の 1 つだけローカルの意思が通りません。削除はやり直せますが、消えた文章は戻せないからです。

競合した行は、行のハイライトと行末の `◆ サーバー: …` で示します。`<<<<<<<` のようなマーカーは
バッファに書き込みません。`]c` で次の競合へ飛べます。

保存のときに競合が出た場合は書き込まず、マージ結果を表示したうえで、バッファを未保存のまま
残します。直してからもう一度 `:w` してください。

### 箇条書き

Cosense はインデント 1 文字が 1 段で、半角スペース・タブ・全角スペースのどれでも 1 段です。
chatora は最後の段に中点を描き、1 段を 1 マスで表します。ページのバッファでは `tabstop` を 1 に
しているのでタブも 1 マスになり、2 マス幅の全角スペースは 1 マスに見せます。そのため、
**どの文字で書いた行も同じ段は同じ深さに見えます**。

```lua
pads = {
  bullet = '•',      -- 中点のグリフ
  guide = false,     -- 文字を渡すと上位レベルに縦線を引く（Cosense には無い）
  spacing = false,   -- true で 1 段を 2 マスに広げる
  gap = 0,           -- 中点と本文の間の追加余白
}
```

`spacing = true` にすると web に近い広めの段になりますが、長い行を折り返したときに 2 行目以降が
本文の位置に揃わなくなります。Neovim の折り返しの字下げは、インデントの文字数しか数えないためです。

`1.` で始まる行は自前の番号を持つので、中点を描きません。

インデントの文字そのものを揃えたいときは `<leader>cI` を使います。全段を半角スペース 1 個ずつに
書き換えます（段数は変えません）。見た目は元から揃うので、手で編集しづらい混在ページ向けです。
**インデントのある全行を編集する**ので、次の保存でその全部が送られます。

### 引用

`> 引用` の `>` を縦棒に置き換え、本文に web と同じ薄い背景を、行の右端まで敷きます。文字の色は
変えません。リストの中では縦棒が中点の隣に立ち、`> ` は隠れます。

```lua
quote = {
  bar = '▌',                                   -- 太さはグリフで決まる: ▏ ▎ ▍ ▌ ┃ │
  hl = { fg = '#4493f8' },                     -- 縦棒（ChatoraQuoteBar）
  text_hl = { bg = '#2a2a2a' },                -- 引用本文（ChatoraQuoteText）
  dim = true,                                  -- 背景ではなく、本文を Comment の色に落とす
  wrap = false,                                -- 折り返し行への追従をやめる
}
```

`hl` と `text_hl` は `nvim_set_hl` にそのまま渡ります。省略すると、背景は colorscheme の地の色から
一段ずらした色になり、縦棒は `Comment` の色でその背景の上に乗ります。`text_hl = false` で縦棒だけに
なります。
縦棒は、カーソルがその行に来ても消えません。

`wrap = true`（既定）のときは、折り返された引用の 2 行目以降にも縦棒と背景が続きます。

### 折り返し

長い行を折り返したとき、2 行目以降は本文の 1 文字目の下から始まります。中点や引用の縦棒の分だけ
字下げして、その字下げに縦棒を続けて描きます（`breakindent`）。

ページのウィンドウでは `linebreak` を切ります。Neovim の `linebreak` は `breakat` の文字（空白や
`.` `@` `/` など）でしか折らないので、日本語の続く塊が丸ごと次の行へ落ちて上の行が空いたり、
`` `@architecture.md` `` のようなコード片が `.` で切れたりするためです。`wrap` そのものは
触りません。

### 画像の貼り付け

`<leader>cv` でクリップボードの画像をアップロードし、カーソルの下の行に画像記法を書き込みます。
アップロード中は、その行にスピナーが出ます。

画像のバイト列を取り出すには外部ツールが要ります。最初に見つかったものを使います。

| プラットフォーム | ツール |
|---|---|
| macOS | `pngpaste`（`brew install pngpaste`）。無ければ標準の `osascript` |
| Wayland | `wl-paste` |
| X11 | `xclip` |

行き先はプロジェクト側の設定（`uploadImageTo`）で決まります。`gcs` ならプロジェクト自身の
ファイル領域に上がり、`[https://scrapbox.io/files/….png]` が入ります。`gyazo` なら Gyazo に
上がり、`[https://gyazo.com/…]` が入ります。設定を読めなかったときはプロジェクト自身のファイル
領域を使い、片方が失敗したらもう片方を試します。

### アイコン挿入

アイコンキー（`<C-i>` / `<M-i>`）は、押した場所で意味が変わります。

| 状況 | 挿入されるもの |
|---|---|
| リンク補完が開いていて候補が選択されている | その候補のアイコン `[候補.icon]`（書きかけの `[...]` ごと置換） |
| それ以外 | 自分のアイコン `[自分.icon]` |

blink.cmp / nvim-cmp / 組み込み補完のどれでも動きます。ターミナルのポップアップには画像を
描けないので、補完メニューの中にアイコンは出ません。

### 保存状態の表示

保存の成否は、トーストではなく小さなアイコンで伝えます。サイドバーの `●` マーク、コマンドライン
への一行 echo、そして statusline のコンポーネントです。

`component()` がアイコンを、`page_info()` がページの数値を返します。

```lua
-- 素の statusline
vim.o.statusline = "%f %{%v:lua.require'chatora.status'.component()%} %{v:lua.require'chatora.status'.page_info()}"

-- lualine
{ sections = { lualine_x = {
  { function() return require('chatora.status').page_info() end,
    color = function() return require('chatora.status').page_info_hl() end },
} } }
```

`page_info()` は `更新 43分前 · 閲覧 39 · 被リンク 6` のようなプレーン文字列を返し、ページ以外の
バッファでは空文字を返します。条件を書かずに、そのまま置けます。色は `page_info_hl()` が
ハイライトグループ名で返します。

Cosense の日時はサーバー側のコピーの話なので、ローカルに未保存の変更があると、そのままでは嘘に
なります。そのため未保存のときは、先頭にバッジが付きます。

| 状態 | `page_info()` | `page_info_hl()` |
|---|---|---|
| 保存済み | `更新 43分前 · 閲覧 39` | `ChatoraStatusMuted` |
| 未保存 | `● 未保存 · 更新 43分前 · 閲覧 39` | `ChatoraStatusDirty` |
| 保存中 | `◍ 保存中 · …` | `ChatoraStatusPending` |
| 保存失敗 | `✗ 保存失敗 · …` | `ChatoraStatusError` |

更新時刻だけなら `require('chatora.status').updated(bufnr)` です。色を自前で付けるなら、
`require('chatora.status').icon(bufnr)` がアイコンとハイライトグループ名を返します。

## 見た目

### 記法の色

既定の色は colorscheme から借りますが、**同じ色を二度使いません**。Cosense がフォントサイズで
付ける強調の段階を、ターミナルでは色で表すしかないので、リンクの色や他の段階と被ると別の意味に
読めてしまうからです。

| 記法 | 既定の見た目 |
|---|---|
| `[link]` / `[/proj/page]` | リンク色（下線なし） |
| 外部 URL | 同じ色 + **下線** |
| `` `code` `` / `code:js` | 灰色の背景バッジ（文字色はそのまま） |
| `[* 見出し]` | 太字のみ |
| `[** 見出し]` | 太字 + 色（リンク色とは必ず別） |
| `[*** 見出し]` 以上 | 太字 + さらに別の色 |
| 実体のないページへのリンク | `ChatoraLinkEmpty`（既定は赤） |

すべて `default = true` で定義しているので、`:hi` で上書きできます。

```lua
vim.api.nvim_set_hl(0, '@lsp.type.bold3.cosense', { fg = '#ff8700', bold = true })
vim.api.nvim_set_hl(0, '@lsp.type.code.cosense', { bg = '#303030' })
```

### テロメア

行の左に、その行がいつ書かれたかを表すバーを出します（Cosense の
[テロメア](https://scrapbox.io/help-jp/テロメア)）。ページ全体の更新時刻では分からない、
**どこが**変わったのかが分かります。

| 見た目 | 意味 | ハイライトグループ |
|---|---|---|
| 太さ | 新しい行ほど太くなります。直近 1 時間が `█`、季節をまたぐと `▏` です | |
| 青 | 前回の訪問より後に更新された行（未読） | `ChatoraTelomereUnread` |
| 濃い青 | このバッファを開いた後に更新された行（同期で入ってきた） | `ChatoraTelomereUpdated` |
| 地の色 | 前回の訪問より前から変わっていない行 | `ChatoraTelomere` |
| 変更色 | 自分が編集した、まだ保存していない行 | `ChatoraTelomereLocal` |

バーはサインカラムに描きます。`signcolumn` が `no` のウィンドウだけ、`yes:1` に上げます。

サインカラムのバーは、画面に出ている行の話しかしません。ページ全体のどこに更新があるかは、
ウィンドウ右端のスクロールバーが示します。淡い帯が今画面に出ている範囲で、色付きのマークが
更新のある行の位置です。ページ全体を高さに写すので、**画面外の更新も見えます**。`]u` / `[u` で
その行を順に辿れ、`mouse` が有効ならバーのクリックでもそこへ飛べます。

1 画面に収まるページには出しません。スクロールする先が無く、全行のバーがもう見えているからです。
全行が更新済みのときも、指し示すものが無いのでマークを出しません。

```lua
telomere = { bar = true, scrollbar = false }  -- 右端のマークだけやめる
telomere = false                              -- どちらも出さない
```

色はどれも `default = true` で定義しているので、colorscheme の後に
`vim.api.nvim_set_hl(0, 'ChatoraTelomereUnread', { fg = '#89a3ff' })` のように上書きできます。

### 赤リンク

実体のないページを指すリンクは、色を変えて示します（`ChatoraLinkEmpty`、既定は赤）。

判定にはプロジェクトのタイトル索引を使い、Cosense 自身と同じ畳み方（小文字化と、空白と
アンダースコアの同一視）で突き合わせます。`[Side Kanban]` と `[side_kanban]` は同じページです。

索引は 5 分キャッシュしますが、このセッションで分かったことはその場で反映します。

| 出来事 | 索引 |
|---|---|
| 新規ページを保存した | そのタイトルを足します（リンクが即座に赤でなくなります） |
| ページを削除した | 取り除きます |
| リンクを辿った先が存在しなかった | 取り除きます |

### カスタム装飾記法

`[<記号> 本文]` の記号を、自分で定義できます。

```lua
notations = {
  ['|'] = { name = 'highlight', hl = { bg = '#3a3a00', bold = true } },
  ['='] = { name = 'boxed',     hl = { link = 'WarningMsg' } },
  ['@'] = { name = 'heading', icon = '📌', hl = { bold = true }, rule = true },
}
```

| フィールド | 意味 |
|---|---|
| キー | 1 文字の記号です。公式記法の記号（`* / - _ $ [`）とは衝突できません |
| `name` | 英数字と `_` のみです。semantic token の型名になります |
| `hl` | `nvim_set_hl` にそのまま渡ります（`:colorscheme` を変えても再適用します）。文字色は `fg` です |
| `icon` | 開きマーカーの代わりに表示する 1 文字です。カーソル行では元の記号が見えます |
| `rule` | `true` で、その行の下にウィンドウの右端まで届く罫線を引きます。色は `rule_hl` です |

記号は連ねられます。Cosense のマーカーは 1 文字ではなく記号の連なりで、その全部が効くからです。

```
[|* 特徴]      -- highlight（上の例）と 太字
[|= 両方]      -- highlight と boxed が重なる
[!' お願い]    -- ! だけ設定していれば ! の見た目。' は何もしない
```

重なったとき、ぶつからない属性（片方が `bg`、もう片方が `fg` と `bold`）はそのまま合成されます。
ぶつかったときは**先に書いた記号が勝ち**、カスタム記法は公式記法（`*` `/` `-` `_`）より上です。

Cosense が記号として認める文字（`!"#%&'()*+,-./{|}<>_~`）は、設定していなくても連なりの一部
として読み飛ばします。そのため `[!' お願い]` が「`!' お願い` というページへのリンク」になることは
ありません。設定していない記号だけの `[' x]` は、これまでどおりリンクです。

設定の誤りでプラグインは落ちません。`icon` が 2 文字以上ならその `icon` だけを、記号が 1 文字で
ない・`name` が不正・公式記法と衝突するならそのエントリごと無視して、`vim.notify` で知らせます。
`hl` を Neovim が受け付けなかったときは、原因のキー名も出します。

### ファイルへのリンク

Cosense にアップロードしたファイル（`https://<origin>/files/<id>.<ext>`）へのリンクには、
開き括弧の位置にアイコンが出ます。

```
[report.html https://scrapbox.io/files/….html]   -- 󰈔 report.html
```

括弧はもともと隠れているので、行の幅は変わりません。アイコンは `file_icon` で変えられます。
1 文字でないものは無視して、単に隠します。

### 画像の表示

アイコン記法や画像リンクをバッファ内に描画するには、対応ターミナル（kitty / Ghostty）と
ImageMagick（`brew install imagemagick`）、そして描画プラグインが要ります。

```lua
-- 推奨: image.nvim（magick_cli プロセッサなら luarocks 不要）
{ '3rd/image.nvim', opts = { processor = 'magick_cli' } },
-- 代替: snacks.nvim の image モジュール（両方あれば image.nvim 優先）
```

画像の取得は chatora の LSP サーバーが PAT 付きで行い、ローカルにキャッシュします。そのため、
プライベートプロジェクトのアイコンも表示できます。

`[[…]]`（大きい記法）は、画像にもアイコンにも効きます。`[[name.icon]]` が単独で行にあるときは
`image_height_large` の大きさで描き、文中にあるときは 1 行のままです。

GIF は最初のフレームだけを描きます。端末のグラフィックプロトコルが静止画しか合成しないからです。
Gyazo は、写真も GIF もチーム Gyazo も描けます。

#### VS Code で画像を出す

VS Code の内蔵ターミナルは sixel と iTerm inline images を話し、kitty graphics protocol は
話しません。そのため snacks.nvim では描けず、image.nvim の sixel バックエンドに切り替える必要が
あります。

1. VS Code の `settings.json` で画像を有効にします。設定したあとは、ターミナルを開き直して
   ください。

   ```json
   { "terminal.integrated.enableImages": true }
   ```

2. image.nvim のバックエンドをターミナルごとに分けます。backend は setup のときに一つ決まるので、
   ここで振り分けておかないと、Ghostty で sixel を送って何も出ないことになります。

   ```lua
   {
     '3rd/image.nvim',
     opts = {
       backend = vim.env.TERM_PROGRAM == 'vscode' and 'sixel' or 'kitty',
       processor = 'magick_cli',
     },
   }
   ```

3. sixel の生成は ImageMagick がやるので、SIXEL コーダー入りのものが要ります。
   `magick -list format | grep -i SIXEL` に `SIXEL* SIXEL rw-` が出れば入っています
   （Homebrew の imagemagick には入っています）。

chatora 側の `image_backend` は、既定の `'auto'` のままで構いません。image.nvim があればそちらが
優先され、プロトコルの選択は上の 2 に任せられます。

### 画像だけの行

`[img1] [img2] [img3]` のように画像しか無い行は、web と同じく、**同じ大きさのタイルを横に並べて**
描きます。写真はタイルいっぱいに広げて、はみ出た分を切り落とします。ウィンドウの幅に入りきらない
分は、次の段に折り返します。

```lua
image_gallery = true                          -- 既定。高さは image_height、タイルは幅 3 : 高さ 4
image_gallery = { rows = 12, aspect = 4 / 3 } -- 高さ 12 行で、横長のタイル
image_gallery = 12                            -- 高さだけ変える
image_gallery = false                         -- 並べず、文中と同じ 1 行の高さで置く
```

`aspect` はタイルの幅を高さで割った値です。並べた 1 枚の絵はサーバーが ImageMagick で作るので、
ImageMagick が無いときは 1 枚ずつ縦に積みます。画像が 1 枚だけの行は切り抜かず、そのままの形で
描きます。

### 描画バックエンドを差し替える

どのプロトコル（kitty / sixel / iTerm）で送るかは image.nvim や snacks.nvim 側の設定で、chatora は
そのどちらを使うかを選ぶだけです。

```lua
image_backend = 'auto'        -- 既定。image.nvim があればそれ、無ければ snacks
image_backend = 'image_nvim'  -- 固定
image_backend = 'snacks'
```

端末ごとに変えたいときは、関数を渡します。描画のたびに呼ばれ、名前を返しても、後述のバックエンド
そのものを返しても構いません。

```lua
-- kitty プロトコルが通る端末では snacks、通らない VS Code では sixel に設定した image.nvim
image_backend = function()
  return vim.env.TERM_PROGRAM == 'vscode' and 'image_nvim' or 'snacks'
end
```

image.nvim を `backend = 'sixel'` にすると、その nvim では常に sixel になります。`'auto'` のままだと
kitty しか解さない端末（Ghostty など）で何も出なくなるので、両方の端末を行き来するなら上の形に
してください。

| 端末 | 通るプロトコル | 使うもの |
|---|---|---|
| kitty / Ghostty / WezTerm | kitty graphics | snacks か image.nvim（`backend = 'kitty'`） |
| VS Code 統合ターミナル | sixel・iTerm IIP | image.nvim（`backend = 'sixel'`） |

どちらのプラグインも、端末がグラフィックスに対応しているかを環境変数で判定します。VS Code の
統合ターミナルのように判定から漏れる端末では、判定のほうを外してください。

```lua
{ 'folke/snacks.nvim', opts = { image = { force = true } } }  -- 判定を無視して送る
```

それでも合わないときは、自分で描くものを渡せます。テーブル（読み込み順の都合があるなら、それを
返す関数）で `place` を実装します。

```lua
image_backend = {
  --- bufnr の (row, col) に path の画像を置き、閉じ方を返す。描けなければ nil。
  --- geom = { row(1始まり), byte_col, byte_end, screen_col, indent_col, indent_screen_col,
  ---          align_indent }、opts = { height | max_height, max_width }。
  --- path は必ずローカルファイル（取得とキャッシュは chatora 側で済んでいる）。
  place = function(bufnr, path, geom, opts)
    local handle = my_renderer.draw(bufnr, path, geom.row, geom.screen_col, opts)
    if not handle then
      return nil
    end
    return {
      close = function() handle:clear() end,
      -- 省略可。true=描けている / false=描けなかった（chatora が描き直す） / nil=不明
      ok = function() return handle:visible() end,
    }
  end,
}
```

`place` の無いテーブルを渡した場合は、一度だけ警告して既定のバックエンドに戻ります。

## 移動する

### 行リンク

`[ページ名#<行ID>]` は、ページの中の 1 行を指します。`gd` するとそのページを開き、**その行に
カーソルを置きます**。行が既に消えていれば、ページの先頭に開きます。

タイトル自体が `#` を含むことはあるので（`[C#入門]` は 1 ページです）、行 ID の形（16 進 24 桁）に
一致する末尾だけを行参照として扱います。

### 別プロジェクトのページ

`[/other-project/page]` に `gd` すると、そのプロジェクトのページが開きます。Cosense は公開
プロジェクトを誰でも読めて、書けるのはメンバーだけです。そのため、**自分がメンバーでない
プロジェクトのページは読み取り専用で開きます**。バッファは `nomodifiable` になり、statusline には
`読み取り専用` と出ます。同期のポーリングも回しません。

編集しようとすると、どのプロジェクトの権限が無いのかを通知します。メンバーかどうかを確かめられ
なかったときは書き込み可能として開き、保存がサーバーに断られたらそう伝えます。

### リネームされたページ

Cosense はページをリネームしても、旧タイトルから現在のページへリダイレクトします。chatora は
これを追うので、リネーム前に書かれたリンクを踏んでも、現在のページが開きます。追うのは同じ
origin の中のリダイレクトだけです。

### 動画を再生する

Gyazo の動画（GIF キャプチャを含む）は、本文には静止画で出ます。端末は動画を再生できないので、
`gd` したときの行き先を `video` で決めます。

```lua
video = 'open'                          -- macOS の既定のプレイヤー
video = { 'mpv', '--loop', '{url}' }    -- コマンドと引数（'{url}' が置き換わる）
video = function(url)                   -- 自分で決める。false を返すとブラウザに回す
  vim.system({ 'mpv', url }, { detach = true })
  return true
end
video = false                           -- 既定。ほかのリンクと同じくブラウザ
```

渡ってくる URL は、素の Gyazo なら `https://i.gyazo.com/<hash>.mp4` で、プレイヤーがそのまま
再生できます。チーム Gyazo なら、プレイヤーページの URL です。

### ページ情報

`<leader>ci` で開きます。よく見るものが上にあり、横線で区切って、下に行くほど細かくなります。

```
  URL          https://scrapbox.io/my-project/設計メモ
  作成         ◍ taro        3日前
  更新         ◍ はなこ      12分前
  共同編集者   ◍ ◍ ken、mika
  ─────────────────────────────────────
  プロジェクト my-project
  ページ履歴   12
  被リンク     6
  ─────────────────────────────────────
  閲覧数       128
  ページランク 1.23
  行数 / 文字数 42 / 1980
  ピン留め     なし
  最終閲覧     5時間前
```

日時は相対表記に丸めます。作成者と最終更新者のアイコンを名前の左に描きます（画像を描ける
ターミナルのみ。描けなくても名前は出て、桁もずれません）。共同編集者の行は、作成者・最終更新者
以外に編集した人がいるときだけ出ます。

### サイドバーとプロジェクト

サイドバーは、**今見ているページのプロジェクト**を映します。別プロジェクトのリンクを `gd` で
開いたり `:Chatora open <url>` を叩いたりすると一覧もそちらへ移り、元のページに戻れば一覧も
戻ります。カーソルは動かしません。

一度読んだプロジェクトの一覧は nvim を終了するまで保持するので、行き来にリクエストは要りません。

`P` のピッカーは、保存済みの全アカウントのプロジェクトを並べ、アカウント名を先頭の列に出します。
選ぶと、[必要ならアカウントごと](#シェルから起動)切り替わります。

### サイドバーのタブ

```lua
sidebar_tabs = {
  { label = 'すべて' },
  { label = '未読', filter = 'me', unread_only = true },
  { label = '自分', filter = { type = 'icon', value = 'your-name' } },
}
```

`filter` は `'me'`（自分の保存済み Cosense フィルタ。無ければ自分の名前の icon フィルタ）か
`{ type, value }` です。`sidebar_tabs = false` で、タブなしの単一リストになります。

## 連携

### telescope

同じ全文検索を、telescope のピッカーとしても使えます。

```lua
require('telescope').load_extension('chatora')
```

`:Telescope chatora search`（`:Telescope chatora` も同じ）で開きます。並び順は Cosense の
pageRank をそのまま使い、telescope 側では一致箇所のハイライトだけを行います。プレビューはページ
本文で、ヒット行に飛んで `TelescopePreviewMatch` でマークします。`dynamic_preview_title = true` を
設定していれば、プレビューの枠にページ名が出ます。

`:Chatora search` は telescope が無くても動く内蔵ピッカーで、こちらとは別物です。

### シェルから起動

`bin/chatora` が `nvim +Chatora` のランチャーです。

```sh
alias chatora='/path/to/chatora/bin/chatora'
```

```sh
chatora                                       # サイドバー（設定のプロジェクト）
chatora -p my-project                         # そのプロジェクトを開く
chatora https://scrapbox.io/proj/Page_Title   # そのページを開く
```

`-p`（`--project`）で渡したプロジェクトが今のアカウントに無ければ、保存済みの他アカウントを順に
当たって、**持っているアカウントに切り替えてから**開きます。URL 指定も同じで、URL の中の
プロジェクト名からアカウントを決めます。どのアカウントにも無いプロジェクトはそのまま開きます。
公開プロジェクトなら、読み取り専用で読めます。

残りの引数は、そのまま nvim に渡ります（`chatora -p proj notes.md`）。

### Slack や Chrome のリンクを chatora で開く（macOS）

Cosense のリンクをクリックしたとき、ブラウザではなく**今動いている chatora** でそのページを
開けます。

```sh
bin/chatora-url-handler install
```

インストールは、今の既定ブラウザを控え、URL を受け取る小さなアプリを
`~/Applications/Chatora Open.app` に作って、`http` / `https` のハンドラとして登録します。最後に
**システム設定 → デスクトップとDock → デフォルトのWebブラウザ**で `Chatora Open` を選んで
ください。ここだけ手動なのは、macOS が既定ブラウザを変える API を閉じているからです。

以後クリックしたリンクは、Cosense のページなら動いている chatora に流れ、tmux のペインと
ターミナルが前面に出ます。それ以外のリンクは、控えておいたブラウザへ行きます。chatora が動いて
いないときや何かに失敗したときも、同じくブラウザへ行きます。既定ブラウザを預かる以上、リンクが
「どこも開かない」にはなりません。

chatora 自身がブラウザで開く操作（外部リンクの `gd` や、ページをブラウザで開く）は、既定ではなく
控えておいたブラウザへ直接渡します。既定に渡すと、自分のところへ戻ってきてしまうためです。

対象にする origin は `~/.local/share/chatora/url-handler/origins` に 1 行 1 件で書きます（既定は
`scrapbox.io`）。今どうなっているかは `chatora-url-handler status` で見え、元に戻すのは
`chatora-url-handler uninstall` です。

配布物をダウンロードしないので、署名も公証も要りません。ダウンロードしていないアプリには
Gatekeeper が見る quarantine 属性が付かず、`osacompile` が ad-hoc 署名まで済ませるからです。
