# 機能

chatora が何をするかを機能ごとに。設定できる項目そのものの一覧は
[README の設定](../README.md#設定)にある。

## 同期と競合

開いているページは背後でサーバーと同期する。**取り込みは上書きではなくマージで、ローカルで
書いた内容が消えることはない。**

```lua
sync = { interval = 30, on_focus = true, notify = true }  -- 既定
sync = false                                              -- 手動（<leader>cf）だけにする
```

- `interval` — ポーリング間隔（秒）。**画面に出ているバッファだけ**を回し、離れると止まり、
  戻ると再開する
- `on_focus` — ページに入った瞬間にも一度同期する
- `notify` — 取り込んだ内容・競合件数を通知する

マージは三方向（`base` = 最後に取得した状態 / `ours` = バッファ / `theirs` = サーバーの現在）で、
突き合わせは行テキストではなく**行 ID** で行う。ローカル側の編集は行 ID に紐づけ直され、
リモート側は最初から ID を持っているので、リモートの並べ替え・挿入・削除に引きずられない。

| 状況 | 結果 |
|---|---|
| 別々の行を編集 | 両方入る |
| 同じ行を同じ内容に編集 | 競合しない |
| 同じ行を違う内容に編集 | **ローカルを残す** + 競合として印を付ける |
| ローカルで編集した行をサーバーが削除 | **ローカルの行を残す** + 競合 |
| ローカルで削除した行をサーバーが編集 | サーバーの行が戻る + 競合 |

最後の 1 つだけローカルの意思が通らない。削除はやり直せるが、消えた文章は戻せないため。

競合した行は行ハイライトと行末の `◆ サーバー: …` で示す。**バッファには `<<<<<<<` のような
マーカーを一切書き込まない** — バッファは常に保存される内容とバイト単位で一致している必要が
あるため。`]c` で次の競合へ飛べる。

保存時に競合が出た場合は書き込みを行わず、マージ結果を表示したうえでバッファを未保存のまま
残す。直してからもう一度 `:w` すればよい。

> 書き込みは公式の `page-edit-for-ai` API（preview → submit）。この API はクライアント側の
> バージョン token を受け取らず、サーバーが preview 時点の状態と突き合わせて
> `409 NotFastForward` を返す。chatora はそれを受けて取り直し → 三方向マージ → 再送するので、
> 本当に同じ行が衝突したときだけ保存が止まる。

## テロメア

行の左に、その行がいつ書かれたかを表すバーを出す（Cosense の[テロメア](https://scrapbox.io/help-jp/テロメア)）。
ページ全体の更新時刻では分からない **どこが** 変わったのかを、これだけが答える。

| 見た目 | 意味 | ハイライトグループ |
|---|---|---|
| 太さ | 新しい行ほど太い。1 セルを 8 段階（`▏▎▍▌▋▊▉█`）に使い、直近 1 時間が `█`、季節をまたぐと `▏` | — |
| 青 | 前回の訪問より後に更新された行（＝未読） | `ChatoraTelomereUnread` |
| 濃い青 | このバッファを開いた後に更新された行（＝同期で入ってきた） | `ChatoraTelomereUpdated` |
| 地の色 | 前回の訪問より前から変わっていない行 | `ChatoraTelomere` |
| 変更色 | 自分が編集した、まだ保存していない行 | `ChatoraTelomereLocal` |

バーはサインカラムに描く。`signcolumn` が `no` のウィンドウだけ `yes:1` に上げる。

#### ページ全体のどこが変わったか

サインカラムのバーは画面に出ている行の話しかしない。ページ全体のどこに更新があるかは、
ウィンドウ右端のスクロールバーが示す（Cosense がブラウザのスクロールバーに重ねているものと同じ）。

- **淡い帯** — いま画面に出ている範囲。長さはページに対する画面の割合で決まり（ブラウザの
  スクロールバーと同じ）、スクロールしても伸び縮みせず位置だけが動く
- **色付きのマーク** — 更新のある行の位置。ページ全体を高さに写すので、**画面外の更新も見える**
  （IDE のミニマップと同じ考え方）
- `]u` / `[u` でその行を順に辿れる。`mouse` が有効ならバーのクリックでもそこへ飛ぶ

バーは幅 1 セルのフローティングウィンドウで、ページのウィンドウの右端に重ねる（ページの行に
仮想テキストとして描くと、画面に出ていない行のマークは描きようがないため）。

1 画面に収まるページには出さない（スクロールする先が無く、全行のバーがもう見えているため）。
全行が更新済みのときはマークを出さない（全部に印が付いても指し示すものがないため）。

```lua
telomere = { bar = true, scrollbar = false }  -- 右端のマークだけやめる
telomere = false                              -- どちらも出さない
```

色はどれも `default = true` で定義するので、カラースキームの後に
`vim.api.nvim_set_hl(0, 'ChatoraTelomereUnread', { fg = '#89a3ff' })` のように上書きできる。

## リネームされたページ

Cosense はページをリネームしても旧タイトルで到達できるようにし、現在のタイトルへリダイレクト
する。リネーム前に書かれたリンクを踏むとこれに当たるので、ページ取得は `followRename` を付け、
**同一オリジンのリダイレクトだけを追う**。

リクエストには資格情報が乗っているので、リダイレクト先が別ホストなら追わずに失敗させる
（`redirect: 'manual'`）。追跡は 3 ホップまで。

## 行リンク

`[ページ名#<行ID>]` はページの中の 1 行を指す。`gd` するとそのページを開き、**その行にカーソルを
置く**（画面中央に寄せる）。行が既に消えていればページの先頭に開く。

タイトル自体が `#` を含むことはあるので（`[C#入門]` は 1 ページ）、行 ID の形（16 進 24 桁）に
一致する末尾だけを行参照として扱う。

## 別プロジェクトのページ

`[/other-project/page]` に `gd` すると、そのプロジェクトのページが開く。Cosense は公開
プロジェクトを誰でも読めて、書けるのはメンバーだけなので、**自分がメンバーでないプロジェクトの
ページは読み取り専用で開く**。バッファは `nomodifiable` になり、statusline には `読み取り専用`
と出る。同期のポーリングも回さない。

メンバーかどうかはプロジェクトのロスターで判定する。ロスター自体が読めなかったときは書き込み可能
として開く — 編集できるバッファを誤って固めるより、保存がサーバーに断られるほうが原因が分かる。

編集しようとすると理由を通知する。`'modifiable'` を落としただけだと Neovim は `E21` を返すが、
それは「オプションが設定されている」としか言わず、**どのプロジェクトの権限が無いのか**は伝えない。

## 赤リンク

実体のないページを指すリンクは色を変えて示す（`ChatoraLinkEmpty`、既定は赤）。

判定はプロジェクトのタイトル索引（`search/titles`）で行う。この API は 1 回に最大 10000 件しか
返さず続きを `x-following-id` で示すので、chatora は最後まで辿ってから突き合わせる。突き合わせは
Cosense 自身と同じ畳み方（小文字化 + 空白をアンダースコアに）なので、`[Side Kanban]` と
`[side_kanban]` は同じページとして扱われる。

索引は**メモリとディスクの両方に 5 分キャッシュ**する（`${XDG_STATE_HOME:-~/.local/state}/chatora/titles/`）。
数千件で数百 KB あるので、nvim を起動するたびに取り直すと最初のページのリンク判定がそのぶん遅れる
— ブラウザ版が同じ索引を Cache API に置いているのと同じ理由。

キャッシュを長くできるのは、**このセッションが知ったことを索引にその場で反映する**から:

| 出来事 | 索引 |
|---|---|
| 新規ページを保存した | そのタイトルを追加（リンクが即座に赤でなくなる） |
| ページを削除した | 取り除く |
| リンクを辿った先が存在しなかった | 取り除く（リクエスト無し） |

**判定自体はリクエストを増やさない。** 1 ページに 100 リンクあっても、索引を 1 回引いたあとは
すべてメモリ上の照合。索引の取得も LSP サーバー（別プロセス）で走るので、Neovim のバッファは
止まらない。

## 箇条書き

Cosense はインデント **1 文字**が 1 段。半角スペース・タブ・全角スペースのどれも 1 段として
数える（Cosense 自身がそう数える）。各段に中点を描く。

3 つは幅が違う（1 セル / 1 セル / 2 セル）ので、**足りない分を仮想テキストで補って 1 段を
一定幅に揃える**。これが無いと、スペースで書いた行とタブや全角スペースで書いた行が同じ段でも
別の深さに見え、貼り付けと手打ちが混ざった箇条書きがばらばらになる。ページバッファは
`tabstop = 1` にしてある — タブ 1 個が 1 段である以上、1 セルで描くのが正しく、それより広い
タブ停止位置ではタブの幅が開始桁で変わってしまい補正できない。

```lua
pads = {
  bullet = '•',      -- 中点のグリフ
  guide = false,     -- 文字を渡すと上位レベルに縦線を引く（Cosense には無い）
  spacing = true,    -- 段ごとの字下げ
  gap = 0,           -- 中点と本文の間の追加余白
}
```

中点はインライン仮想テキストとして**最後のインデント文字の手前**に描く。そのため中点を
2 セル幅で描くフォントでも本文の 1 文字目を潰さず、`gap = 0` でも本文との間にインデント
1 文字分が残る。空のリスト項目にカーソルを置いたとき、その位置は兄弟行の本文が始まる桁と
一致する。

`1.` で始まる行は自前の番号を持つので中点を描かない。

インデント文字そのものを揃えたいときは `<leader>cI`。全段を半角スペース 1 個ずつに書き換える
（段数は変えない）。描画は元から揃うので見た目のためには要らない — 手で編集しづらい混在ページ
向け。**インデントのある全行を編集する**ので、次の保存でその全部が送られる。

## 引用

`> 引用` の `>` を縦棒に置き換え、本文を淡く落とす。

```lua
quote = {
  bar = '▌',                                   -- 太さはグリフで決まる: ▏ ▎ ▍ ▌ ┃ │
  hl = { fg = '#4493f8' },                     -- 縦棒（ChatoraQuoteBar）
  text_hl = { fg = '#9198a1', italic = true }, -- 引用本文（ChatoraQuoteText）
  dim = false,                                 -- 本文はそのままにして縦棒だけ出す
  wrap = false,                                -- 折り返し行への追従をやめる
}
```

`hl` / `text_hl` は `nvim_set_hl` にそのまま渡る。省略するとどちらも `Comment` にリンクする。
縦棒は conceal ではなく overlay なので、カーソルがその行に来ても消えない。

`wrap = true`（既定）のとき、折り返された引用の 2 行目以降にも縦棒が続くよう、ページの
ウィンドウに `breakindent` と `breakindentopt=shift:2` を設定する。この字下げが無いと縦棒が
折り返し行の 1 文字目を潰すため、追従が要らなければ `wrap = false` にする。

## カスタム装飾記法

`[<記号> 本文]` の記号を自分で定義できる。

```lua
notations = {
  ['|'] = { name = 'highlight', hl = { bg = '#3a3a00', bold = true } },
  ['='] = { name = 'boxed',     hl = { link = 'WarningMsg' } },
  ['@'] = { name = 'heading', icon = '📌', hl = { bold = true }, rule = true },
}
```

| フィールド | 意味 |
|---|---|
| キー | 1 文字の記号。公式記法の記号（`* / - _ $ [`）とは衝突不可 |
| `name` | 英数字と `_` のみ。semantic token の型名になる |
| `hl` | `nvim_set_hl` にそのまま渡る（`:colorscheme` 変更後も再適用）。キー名も `nvim_set_hl` のもの — 文字色は `fg`（`textColor` などは無い） |
| `icon` | 開きマーカーを置き換えて表示する 1 文字。カーソル行では元の記号が見える |
| `rule` | `true` でその行の下にウィンドウの右端まで届く罫線を引く。色は `rule_hl` |

#### 記号の連なりと重ねがけ

Cosense のマーカーは 1 文字ではなく記号の連なりで、**その全部が効く**。web が記号ごとに CSS
クラス（`deco-!` `deco-{`…）を出して重ねるのと同じように、chatora も記号ごとにハイライトを
重ねる。

```
[|* 特徴]      -- highlight（上の例）と 太字
[|= 両方]      -- highlight と boxed が重なる
[!' お願い]    -- ! だけ設定していれば ! の見た目。' は何もしない
```

重なったときの優先順位は次のとおり。ぶつからない属性（片方が `bg`、もう片方が `fg` と `bold`）は
そのまま合成される。

1. **先に書いた記号が勝つ** — `[|= x]` と `[=| x]` で `fg` の取り合いになったら、それぞれ
   `|` と `=` の `fg` になる
2. カスタム記法は公式記法（`*` `/` `-` `_`）より上 — 明示的に設定したものが勝つ

Cosense が記号として認める文字（`!"#%&'()*+,-./{|}<>_~`）は、設定していなくても連なりの一部と
して読み飛ばす。`[!' お願い]` が「`!' お願い` というページへのリンク」に落ちることはない。逆に
設定していない記号だけの `[' x]` は、これまでどおりリンクとして扱う。

Neovim の conceal 置換は 1 文字までなので、`icon` が複数文字なら警告して `icon` だけ無視する
（`name` / `hl` は活きる）。記号が 1 文字でない・`name` が不正・公式記法と衝突する場合は
エントリごと無視する。`hl` を Neovim が受け付けなかった場合（キー名の間違いなど）はその旨と
原因のキー名を知らせる。いずれも `vim.notify` で伝え、プラグインは落とさない。

## 動画を再生する

Gyazo の動画（GIF キャプチャを含む）は本文には静止画で出る。端末は動画を再生できないので、
`gd` したときの行き先を `video` で決める。

```lua
video = 'open'                          -- macOS の既定のプレイヤー
video = { 'mpv', '--loop', '{url}' }    -- コマンドと引数（'{url}' が置き換わる）
video = function(url)                   -- 自分で決める。false を返すとブラウザに回す
  vim.system({ 'mpv', url }, { detach = true })
  return true
end
video = false                           -- 既定。ほかのリンクと同じくブラウザ
```

渡ってくる URL は、素の Gyazo なら `https://i.gyazo.com/<hash>.mp4`（プレイヤーがそのまま
再生できる）、チーム Gyazo なら oembed が返すプレイヤーページ。どちらを渡せるかは Gyazo 側の
都合で、`/api/oembed-proxy/gyazo` の応答から決めている。

## ファイルへのリンク

Cosense にアップロードしたファイル（`https://<origin>/files/<id>.<ext>`）へのリンクは、開き
括弧の位置にアイコンが出る。

```
[report.html https://scrapbox.io/files/….html]   -- 󰈔 report.html
```

括弧はもともと隠れているので、行の幅は変わらない。アイコンは `file_icon` で変えられる
（conceal の置換は 1 文字までなので、1 文字でないものは無視して単に隠す）。

## 記法の色

既定は colorscheme から借りるが、**同じ色が二度使われないことを保証する**。Cosense が
フォントサイズで付ける強調の段階を、ターミナルでは色で表すしかないため、リンクの色や他の段階と
被ると別の意味に読めてしまう。

| 記法 | 既定の見た目 |
|---|---|
| `[link]` / `[/proj/page]` | リンク色（下線なし） |
| 外部 URL | 同じ色 + **下線** |
| `` `code` `` / `code:js` | 灰色の背景バッジ（文字色はそのまま） |
| `[* 見出し]` | 太字のみ |
| `[** 見出し]` | 太字 + 色（リンク色とは必ず別） |
| `[*** 見出し]` 以上 | 太字 + さらに別の色 |
| 実体のないページへのリンク | `ChatoraLinkEmpty`（既定は赤） |

バッジの背景は `Normal` の背景から一段ずらして作る（暗いテーマでは明るく、明るいテーマでは
暗く）。`CursorLine` を借りるとカーソル行でバッジが消えるため。

すべて `default = true` で定義しているので `:hi` で上書きできる:

```lua
vim.api.nvim_set_hl(0, '@lsp.type.bold3.cosense', { fg = '#ff8700', bold = true })
vim.api.nvim_set_hl(0, '@lsp.type.code.cosense', { bg = '#303030' })
```

## 画像の表示

アイコン記法や画像リンクをバッファ内に描画するには、対応ターミナル（kitty / Ghostty）と
ImageMagick（`brew install imagemagick`）、そして描画プラグインが要る。

```lua
-- 推奨: image.nvim（magick_cli プロセッサなら luarocks 不要）
{ '3rd/image.nvim', opts = { processor = 'magick_cli' } },
-- 代替: snacks.nvim の image モジュール（両方あれば image.nvim 優先）
```

画像の取得は chatora の LSP サーバーが PAT 付きで行いローカルにキャッシュするため、
プライベートプロジェクトのアイコンも表示できる。

`[[…]]`（大きい記法）は画像にもアイコンにも効く。`[[name.icon]]` が単独で行にあるときは
`image_height_large` の大きさで描き、文中にあるときは 1 行のまま（インラインの行に背の高い
グリフを置く場所が無いため）。

#GIF は**最初のフレームだけ**を描く。端末のグラフィックプロトコルは静止画しか合成せず、
image.nvim も snacks.nvim もアニメーションはしない。加えて ImageMagick はフレームを指定しないと
1 フレームにつき 1 ファイル書き出す（`a.gif` → `a-0.png`, `a-1.png`…）ので、指定しないと描画側が
渡されたパスに何も見つけられない。サーバー側で `[0]` を切り出して PNG にしてから渡している。

Gyazo の URL は Cosense と同じく `/api/oembed-proxy/gyazo` で解決する。`https://gyazo.com/<hash>`
から `https://i.gyazo.com/<hash>.png` を組み立てる方法だと、GIF（Gyazo 上は video 扱い）が 404 に
なり、チーム Gyazo（`https://<team>.gyazo.com/<hash>`）に至っては組み立てようがない。oembed が
返す `url`（写真）または `thumbnail_url`（動画の静止画）を使うので、どちらも描ける。

## 画像だけの行

`[img1] [img2] [img3]` のように画像しか無い行は、web だと横に流れて折り返す。ターミナルの
描画バックエンドは画像を **1 行分のインライン仮想テキスト**か**行の下の仮想行**のどちらかで
しか描けないため、次の二択になる。

| | 横並び | 大きさ |
|---|---|---|
| `image_gallery = false` | ✅ | ❌ 1 行 |
| `image_gallery = true`（既定） | ❌ 縦に積む | ✅ |

積むときは各画像を行のインデントに揃えるので、階段状にならず一列になる。

## 描画バックエンドを差し替える

どのプロトコル（kitty / sixel / iTerm）で送るかは image.nvim や snacks.nvim 側の設定で、
chatora はそのどちらを使うかを選ぶだけ。

```lua
image_backend = 'auto'        -- 既定。image.nvim があればそれ、無ければ snacks
image_backend = 'image_nvim'  -- 固定
image_backend = 'snacks'
```

**端末ごとに変えたいとき**は関数を渡す。描画のたびに呼ばれ、名前を返しても、後述のバックエンド
そのものを返してもよい。

```lua
-- kitty プロトコルが通る端末では snacks、通らない VS Code では sixel に設定した image.nvim
image_backend = function()
  return vim.env.TERM_PROGRAM == 'vscode' and 'image_nvim' or 'snacks'
end
```

どのプロトコルで送るかは image.nvim / snacks の設定であって chatora からは見えない。image.nvim を
`backend = 'sixel'` にすると **その nvim では常に sixel** になるので、`'auto'`（image.nvim 優先）の
ままだと kitty しか解さない端末（Ghostty など。Ghostty は sixel デコーダを持たない）で何も出なく
なる。両方の端末を行き来するなら上の形にする。

```lua
-- 端末が sixel しか受けないなら image.nvim 側で指定する（chatora の設定ではない）
require('image').setup({ backend = 'sixel', processor = 'magick_cli' })
```

| 端末 | 通るプロトコル | 使うもの |
|---|---|---|
| kitty / Ghostty / WezTerm | kitty graphics | snacks か image.nvim（`backend = 'kitty'`） |
| VS Code 統合ターミナル | sixel・iTerm IIP（kitty は実装途中） | image.nvim（`backend = 'sixel'`） |

どちらのプラグインも「この端末はグラフィックスに対応しているか」を環境変数で判定するので、
VS Code の統合ターミナルのように判定から漏れる端末では描画をやめてしまう。VS Code 側は
`terminal.integrated.enableImages`（要 GPU アクセラレーション）で kitty / sixel / iTerm の
いずれも受けるので、判定のほうを外す:

```lua
{ 'folke/snacks.nvim', opts = { image = { force = true } } }  -- 判定を無視して送る
```

それでも合わないときは、自分で描くものを渡せる。テーブル（読み込み順の都合があるなら、それを
返す関数）で `place` を実装する:

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

`place` の無いテーブルを渡した場合は一度だけ警告して既定のバックエンドに戻る。

## 画像の貼り付け

`<leader>cv` でクリップボードの画像をアップロードし、カーソルの下の行に画像記法を書き込む。
アップロード中はその行にスピナーが出る。

Neovim のレジスタはテキストしか持てないので、画像のバイト列を取り出すのに外部ツールが要る
（最初に見つかったものを使う）。

| プラットフォーム | ツール |
|---|---|
| macOS | `pngpaste`（`brew install pngpaste`）。無ければ標準の `osascript` |
| Wayland | `wl-paste` |
| X11 | `xclip` |

行き先はプロジェクト側の設定（`/api/projects/<name>` の `uploadImageTo`）で決まり、
アップロードごとに読み直すのでプロジェクトを切り替えれば行き先も切り替わる。

| `uploadImageTo` | 行き先 | 挿入される記法 |
|---|---|---|
| `gcs` | プロジェクト自身のファイル領域 | `[https://scrapbox.io/files/….png]` |
| `gyazo` | Gyazo | `[https://gyazo.com/…]` |

PAT ではこの設定を読めない（`/api/projects/<name>` が 401 を返す）。読めなかったときは
プロジェクト自身のファイル領域を使う — Cosense の Gyazo トークン発行はブラウザのセッションを
前提としており、PAT では通らないため。片方が失敗したらもう片方を試す。

## ページ情報

`<leader>ci` で開く。よく見るものが上、横線で区切って下に行くほど細かくなる。

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

日時は相対表記に丸める。作成者・最終更新者のアイコンを名前の左に描く（画像を描けるターミナル
のみ。描けなくても名前は出るし桁もずれない）。共同編集者の行は、作成者・最終更新者以外に
編集した人がいるときだけ出る。

ページ本文には著者の id しか入っていないので、名前は `/api/projects/<name>/users` で解決し、
プロジェクト単位に 10 分キャッシュする。

## アイコン挿入

アイコンキーは押した場所で意味が変わる。

| 状況 | 挿入されるもの |
|---|---|
| リンク補完が開いていて候補が選択されている | その候補のアイコン `[候補.icon]`（書きかけの `[...]` ごと置換） |
| それ以外 | 自分のアイコン `[自分.icon]` |

blink.cmp / nvim-cmp / 組み込み補完のどれでも動く。ターミナルのポップアップには画像を描けない
ので、補完メニューの中にアイコンは出ない。

## 保存状態の表示

保存の成否はトーストではなく小さなアイコンで伝える: サイドバーの `●` マーク、コマンドラインへの
一行 echo、そして statusline コンポーネント。

```lua
-- 素の statusline
vim.o.statusline = "%f %{%v:lua.require'chatora.status'.component()%}"
```

`component()` はアイコンだけを返す。ページの数値も出すなら `page_info()`:

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
バッファでは空文字（条件を書かずにそのまま置ける）。色は `page_info_hl()` がハイライトグループ名
で返す。

Cosense の日時はサーバー側のコピーの話なので、ローカルに未保存の変更があると黙って嘘になる。
そのため未保存のときは先頭にバッジが付く。

| 状態 | `page_info()` | `page_info_hl()` |
|---|---|---|
| 保存済み | `更新 43分前 · 閲覧 39` | `ChatoraStatusMuted` |
| 未保存 | `● 未保存 · 更新 43分前 · 閲覧 39` | `ChatoraStatusDirty` |
| 保存中 | `◍ 保存中 · …` | `ChatoraStatusPending` |
| 保存失敗 | `✗ 保存失敗 · …` | `ChatoraStatusError` |

更新時刻だけなら `require('chatora.status').updated(bufnr)`。色を自前で付けるなら
`require('chatora.status').icon(bufnr)` がアイコンとハイライトグループ名を返す。

## サイドバーとプロジェクト

サイドバーは**今見ているページのプロジェクト**を映す。別プロジェクトのリンクを `gd` で開いたり
`:Chatora open <url>` を叩くと一覧もそちらへ移り、元のページに戻れば一覧も戻る。カーソルは
動かさない。

一度読んだプロジェクトの一覧は nvim を終了するまで保持するので、行き来にリクエストは要らない
（1 ページあたり約 600 バイト。100 件で 66KB、2000 件で 1.2MB）。

`P` のピッカーは保存済み全アカウントのプロジェクトを並べ、アカウント名を先頭の列に出す。選ぶと
[必要ならアカウントごと](#シェルから起動)切り替わる。

## サイドバーのタブ

```lua
sidebar_tabs = {
  { label = 'すべて' },
  { label = '未読', filter = 'me', unread_only = true },
  { label = '自分', filter = { type = 'icon', value = 'your-name' } },
}
```

`filter` は `'me'`（自分の保存済み Cosense フィルタ。無ければ自分の名前の icon フィルタ）か
`{ type, value }`。`sidebar_tabs = false` でタブなしの単一リストになる。

## 連携

### telescope

同じ全文検索を telescope のピッカーとしても使える。

```lua
require('telescope').load_extension('chatora')
```

`:Telescope chatora search`（`:Telescope chatora` も同じ）。並び順は Cosense の pageRank を
そのまま使い、telescope 側では一致箇所のハイライトだけを行う。プレビューはページ本文で、
ヒット行に飛んで `TelescopePreviewMatch` でマークする。`dynamic_preview_title = true` を
設定していればプレビューの枠にページ名が出る。

`:Chatora search` は telescope が無くても動く内蔵ピッカーで、こちらとは別物。

### シェルから起動

`bin/chatora` が `nvim +Chatora` のランチャー。

```sh
alias chatora='/path/to/chatora/bin/chatora'
```

```sh
chatora                                       # サイドバー（設定のプロジェクト）
chatora -p my-project                         # そのプロジェクトを開く
chatora https://scrapbox.io/proj/Page_Title   # そのページを開く
```

`-p`（`--project`）で渡したプロジェクトが今のアカウントに無ければ、**保存済みの他アカウントを
順に当たって、持っているアカウントに切り替えてから**開く。URL 指定も同じで、URL の中の
プロジェクト名からアカウントを決める。どのアカウントにも無いプロジェクトはそのまま開く —
公開プロジェクトなら読み取り専用で読める。

残りの引数はそのまま nvim に渡る（`chatora -p proj notes.md`）。
