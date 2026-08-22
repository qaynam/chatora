# chatora 🐈

Cosense（旧 Scrapbox）の Neovim クライアント。

- 左サイドバーにページ一覧、右に本物の Neovim エディタ
- `@cosense-toolbox/parser` による記法ハイライト（LSP semantic tokens）
- リンク補完・定義ジャンプ・関連ページ（1-hop / 2-hop）・検索
- PAT 認証（macOS Keychain 保存、公式 cosense-cli の `~/.cosense/settings.json` 読み取り互換）
- 書き込みは公式 `page-edit-for-ai` API（preview → submit）

設計は [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) を参照。
