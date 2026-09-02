# セキュリティ

## 脆弱性の報告

公開の Issue ではなく、GitHub の
[Security advisory](https://github.com/qaynam/chatora/security/advisories/new) から報告して
ください。個人で管理しているプロジェクトなので、返事に数日かかることがあります。

**報告に PAT やアクセスキーそのものを貼らないでください。** 再現手順だけで十分です。

## chatora が扱う資格情報

- PAT の保存先は **macOS Keychain だけ**です（`security` コマンド経由、サービス名 `chatora`）。
  設定ファイルにもリポジトリにも書きません。環境変数 `COSENSE_PAT` があればそちらを優先します
- PAT は、ログにもエラーメッセージにも LSP のレスポンスにも入れません
- 認証ヘッダーは、リクエスト先が session の origin と同一のときだけ付けます。リダイレクトで
  別の origin に出た時点で外します
- 画像などの取得は LSP サーバー側で行い、キャッシュは `$XDG_CACHE_HOME/chatora/assets` に
  置きます
- ページの本文とタイトルは**信頼できない入力**として扱います。外部コマンドを呼ぶときは
  argv 配列で渡し、シェルを経由しません

## 診断ログについて

`log = true` を設定すると、リクエストのメソッド・URL・status がファイルに記録されます。PAT は
記録しませんが、**ページのタイトルや URL は残ります**。共有する前に中身を確認してください。
