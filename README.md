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

## 設定

### カスタマイズアノテーションの書き方

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
