# 設定ガイド

Chatora の設定項目と、サイドバーを拡張する方法を説明します。
基本設定の一覧は [README の設定](../README.md#設定) を参照してください。

## プロジェクトごとの設定

`setup()` に関数を渡すと、プロジェクトが決まるたびに `{ project = 名前 }` を引数として呼び出します。
その関数が返したテーブルが、該当プロジェクトの設定になります。起動時は `project = nil` で呼び出されるため、
`default_project` や `origin` もここで返せます。設定はプロジェクトごとに記憶されるため、移動するたびに
関数を呼び直すことはありません。
`origin`、`notations`、`log`、`server_cmd` はサーバーの起動時に渡されるため、プロジェクトごとには変更できません。

```lua
require('chatora').setup(function(ctx)
  local tabs = { { name = 'すべて' }, { name = '未読', mine = true, unread = true } }
  if ctx.project == 'my-project' then
    tabs[#tabs + 1] = { name = 'ロードマップ', related = 'ロードマップ' }
  end
  return { default_project = 'my-project', edit = { autosave = 10 }, sidebar = { tabs = tabs } }
end)
```


## サイドバーのタブ

サイドバー上部のタブは `sidebar.tabs` で設定します。既定では「すべて」と「未読」が表示されます。

```lua
sidebar = { tabs = {
  { name = 'すべて', icon = '📖' },
  { name = '未読', icon = '📩', mine = true, unread = true },
  { name = 'sakura', filter = 'sakura' },
  { name = 'ロードマップ', related = 'ロードマップ' },
} }
```

| キー      | 説明                                                                                                                                                                          |
| --------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `name`    | タブの名前                                                                                                                                                                    |
| `icon`    | 名前の前に表示するアイコン                                                                                                                                                    |
| `filter`  | Web のフィルターと同じ形式。ページタイトルを指定し、そのタイトルの `.icon` 記法を含むページと、そのユーザーが編集したページに絞ります |
| `mine`    | 自分のページに絞ります。`filter = '自分の名前'` と同じで、Web に保存したフィルターがあればそれを使います          |
| `related` | 指定したページと 1 hop（1 段階）のリンクでつながる関連ページを表示します。配列で複数指定すると、1 つの一覧にまとめます |
| `pages`   | 一覧の内容を自分で作る関数。[pages の使い方](#pages-の使い方) を参照してください                 |
| `unread`  | 未読ページだけを表示します。`filter` と組み合わせない場合は、プロジェクト全体を 100 件ずつ取得します。自動取得は 500 件までで、続きは下までスクロールしたときに取得します |
| `folders` | タブ内をフォルダーに分けます。[folders の使い方](#folders-の使い方) を参照してください             |

`filter` は `{ type = 'icon', value = 'sakura' }` の形式でも指定できます。`sidebar.tabs = false` にすると、
タブのない単一リストになります。未知のキーがある場合は、起動時に通知します。タブの内容を決めるキー
（`filter` / `mine` / `related` / `pages` / `folders`）は 1 つだけ指定してください。複数指定した場合も通知します。

設定後にタブを追加することもできます。

```lua
require('chatora').add_tab({ name = 'sakura', filter = 'sakura' })
```

### pages の使い方

`pages` に関数を渡すと、一覧の内容を自分で決められます。関数は `ctx` を 1 つ受け取り、タイトルの
配列（文字列または `{ title = ... }` のテーブル）を `return` するか、あとから `ctx.done(list)` に渡します。
どちらか一方だけを使い、両方指定した場合は `return` の値が優先されます。`ctx.done` は `vim.system` の
コールバック内から呼ぶこともできます。サーバーへ問い合わせる場合は `require('chatora.lsp').request`
を使えます。固定の一覧であれば、関数の代わりに配列を直接指定できます。

| `ctx` のキー | 説明                                                   |
| ------------ | ------------------------------------------------------ |
| `project`    | 現在のプロジェクト名                                   |
| `done(list)` | 非同期に結果を渡す。`done(nil, '理由')` で失敗を通知する |
| `log(...)`   | [ログの記録](#ログの記録) を参照してください             |

### ログの記録

処理の進捗は `ctx.log(...)` で記録できます。どこから呼び出しても安全で、`:messages` に表示されます。
`:Chatora log`（`log = true` の場合）にもサーバーのログと一緒に残ります。`vim.system` のコールバック内で
`vim.notify` を呼ぶと、Neovim のメインループ外で実行されるため、失敗して表示されないことがあります。

```lua
-- 決まったページを並べる
{ name = 'よく見る', pages = function()
  return { 'ホーム', 'TODO', 'ロードマップ' }
end },

-- 全文検索の結果を並べる
{ name = '#tag', pages = function(ctx)
  require('chatora.lsp').request('chatora/search', { project = ctx.project, query = '#tag' }, function(_, res)
    ctx.done(res and res.pages or {})
  end)
end },
```

行に `action` を指定すると、`<CR>` でページを開く代わりに、その関数を呼び出します。呼び出し時には
編集用ウィンドウがカレントになるため、そのまま `:edit` などを実行できます。関数には、その行と
ウィンドウが引数として渡されます。これを使うと、Cosense と関係のない項目もサイドバーに表示できます。

```lua
{ name = 'メモ帳', pages = function()
  return {
    { title = 'today.md', action = function()
      vim.cmd.edit(vim.fn.expand('~/notes/today.md'))
    end },
  }
end },
```

`chatora/search` は `{ project, query, mode = 'fulltext' | 'vector' }`、`chatora/listPages` は
`{ project, skip, limit, filterType, filterValue }`、`chatora/relatedPages` は `{ project, title }` を
受け取ります。いずれも `{ ok = true, pages = ... }` を返し、`relatedPages` では `links1hop` に結果が入ります。

### folders の使い方

`folders` を使うと、1 つのタブをフォルダーに分けられます。フォルダーには前述のキーをそのまま指定でき、
見出しの行で `<CR>` を押すと開閉します。フォルダーの内容は初めて開いたときに取得され、閉じたままの
フォルダーは取得されません。`open = false` で閉じた状態から開始できます。フォルダーの中にさらに
`folders` を指定すると入れ子になり、深さに応じて字下げして表示されます。

`folders` には関数も渡せます。`pages` と同じ形式で、フォルダーの配列を返すか `ctx.done` に渡すと、
その配列がフォルダーとして表示されます。外部 API の結果からツリーを組み立てることもできます。`R` で
再読み込みすると、この関数も再実行されます。

```lua
{ name = 'kanban', folders = function(ctx)
  vim.system({ 'curl', '-s', 'https://example.com/api/projects' }, { text = true }, function(out)
    local folders = {}
    for _, p in ipairs(vim.json.decode(out.stdout).projects) do
      folders[#folders + 1] = { name = p.title, folders = {
        { name = 'todo', pages = p.todo },   -- タイトルの並び
        { name = 'done', pages = p.done, open = false },
      } }
    end
    ctx.done(folders)
  end)
end },
```

```lua
{ name = 'custom', folders = {
  { name = 'daily', icon = '📅', related = 'daily' },
  { name = 'note', filter = 'note' },
  { name = 'random', open = false, pages = function() return { 'ホーム', 'TODO' } end },
} },
```


## サイドバーのサムネイル

`sidebar.thumbnails = true` にすると、ページの最初の画像を 1 行分の高さで行頭に表示します。Cosense Web の
一覧に表示されるサムネイルと同じ画像を正方形に切り抜くため、どの行でも幅がそろいます。画像は画面に
表示されている行の分だけ取得し、スクロールして表示された行を順次追加します。

画像の描画バックエンド（image.nvim / snacks.nvim）がない場合、サムネイルは表示されません。ImageMagick が
ない場合は切り抜きを行わず、そのまま表示します。

独自に作成した行やフォルダーにも `image` を指定できます。URL のほか、`~/notes/x.png` のような
このマシン上のファイルパスも指定できます。

```lua
{ name = 'obsidian', image = '~/Pictures/obsidian.png', pages = function()
  return { { title = 'today.md', image = '~/notes/today.png', action = ... } }
end },
```
