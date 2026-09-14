# 外部連携

Chatora を他のツールや macOS と組み合わせて使う方法を説明します。

## 目次

- [Export for AI](#export-for-ai)
- [telescope.nvim](#telescopenvim)
- [シェルから起動](#シェルから起動)
- [Slack や Chrome のリンクを Chatora で開く（macOS）](#slack-や-chrome-のリンクを-chatora-で開くmacos)

## Export for AI

Cosense の Smart Context と同じ書き出しです。`<leader>ce` または `:Chatora export` を実行すると、
開いているページとそのリンク先をまとめた 1 つのテキストファイルを作成し、別のウィンドウで開きます。
AI に読ませたい文脈を、そのまま渡せます。

引数を省略すると、対象のページ数を添えた選択肢が表示されます。

| 選択         | 含まれるページ                               |
| ------------ | -------------------------------------------- |
| 1 hop リンク | ページ自身と、そこからリンクしているページ   |
| 2 hop リンク | それに加えて、リンク先がリンクしているページ |

`:Chatora export 1hop` のように指定すると、選択を省略できます。

書き出し先は `$XDG_CACHE_HOME/chatora/export/<プロジェクト>/<タイトル>-1hop.txt` です（既定は
`~/.cache/chatora/export/…`）。同じページを書き出し直すと上書きします。開いたバッファから `:w` で
任意の場所へ保存できます。

> [!NOTE]
> Cosense Web にある「一時的な URL を生成」は Chatora にはありません。この API はブラウザの
> セッションでのみ動作し、PAT では 401 が返るためです。書き出されるファイルの内容は同じものです。

## telescope.nvim

同じ検索機能を、telescope.nvim のピッカーからも利用できます。

```lua
require('telescope').load_extension('chatora')
```

`:Telescope chatora search`（`:Telescope chatora` でも同じ）で開きます。結果は Cosense の pageRank 順に
並び、telescope.nvim 側では一致箇所だけをハイライトします。プレビューにはページ本文を表示し、ヒットした行へ
移動して `TelescopePreviewMatch` でマークします。`dynamic_preview_title = true` を設定している場合は、
プレビュー枠にページ名が表示されます。

`:Chatora search` は telescope が無くても動く内蔵ピッカーで、こちらとは別物です。

## シェルから起動

`bin/chatora` は `nvim +Chatora` を起動するランチャーです。

```sh
alias chatora='/path/to/chatora/bin/chatora'
```

```sh
chatora                                       # サイドバー（設定のプロジェクト）
chatora -p my-project                         # そのプロジェクトを開く
chatora https://scrapbox.io/proj/Page_Title   # そのページを開く
chatora open https://scrapbox.io/proj/Page    # 同じ（:Chatora open と同じ綴り）
```

`-p`（`--project`）で指定したプロジェクトが現在のアカウントにない場合、保存済みの別アカウントを順に
確認し、**プロジェクトを所有するアカウントに切り替えてから**開きます。URL を指定した場合も同様に、
URL に含まれるプロジェクト名からアカウントを決定します。どのアカウントにもないプロジェクトはそのまま
開きます。公開プロジェクトであれば、読み取り専用で閲覧できます。

URL やファイルではない単語（`chatora toggle` など）は、Neovim にファイル名として渡さず、エラーにします。
URL はオプションの直後に 1 つだけ指定できます。後ろに置いた場合は認識されません（`-o` は Neovim の
横分割オプションなので、`chatora -o <url>` では URL がファイルとして開かれます）。`chatora --help` で
使い方を確認できます。

## Slack や Chrome のリンクを Chatora で開く（macOS）

Cosense のリンクをクリックしたとき、ブラウザではなく**起動中の Chatora** でそのページを開けます。

```sh
bin/chatora-url-handler install
```

インストールすると、現在の既定ブラウザを記録したうえで、URL を受け取る小さなアプリを
`~/Applications/Chatora Open.app` に作成し、`http` / `https` のハンドラとして登録します。最後に
**システム設定 → デスクトップと Dock → デフォルトの Web ブラウザ**で `Chatora Open` を選んでください。
この操作だけ手動で行う必要があるのは、macOS が既定ブラウザを変更する API を提供していないためです。

以後、クリックした Cosense のページリンクは起動中の Chatora に渡され、tmux のペインとターミナルが
前面に表示されます。ターミナルは Neovim の環境変数から検出するため、tmux 内でも前面に表示できます。
それ以外のリンクは、記録しておいたブラウザへ渡されます。Chatora が起動していない場合や処理に失敗
した場合も同じです。既定ブラウザを記録しているため、リンクが「どこも開かない」状態にはなりません。

Chatora 自身がブラウザで開く操作（外部リンクの `gd` や、ページをブラウザで開く）は、既定ブラウザではなく
記録しておいたブラウザへ直接渡します。既定ブラウザに渡すと、Chatora 自身へ戻ってきてしまうためです。

対象にする origin は `~/.local/share/chatora/url-handler/origins` に 1 行ずつ記述します。既定値は
`scrapbox.io` です。現在の設定は `chatora-url-handler status`、元に戻す場合は
`chatora-url-handler uninstall` で確認・実行できます。

Cosense 以外のリンクを渡すブラウザは、`install` のときにターミナルの一覧から番号で選択します。
現在の既定ブラウザには印が付き、Enter でそのまま決定できます。あとから変更する場合は
`chatora-url-handler browser` を実行します。同じ一覧が表示されます。一覧には、https の URL を受け取って
HTML を開くアプリ、つまりシステム設定でブラウザとして表示されるアプリと Safari が含まれます。
スクリプトから使う場合は、`browser 'Google Chrome'` や `install --browser com.google.Chrome` のように、
アプリ名または bundle id を直接指定できます。存在しないアプリを指定した場合は、設定を変更しません。
記録したブラウザがあとから削除されていても Safari に渡すため、リンクを開けなくなることはありません。

配布物をダウンロードしないため、署名や公証は必要ありません。ダウンロードしたアプリに付く
Gatekeeper の quarantine 属性がなく、`osacompile` が ad-hoc 署名まで行うためです。
