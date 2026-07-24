# CLAUDE.md

## 目的

- neovimで使用されているLuaの柔軟性を活かしつつ、nixの再現性を享受する最強のnix x neovim managerを作る

## 要件

- home-manager moduleを提供し、ユーザーのdotfilesに組み込めること。
- lazy.nvim形式のluaを解析し、必要なpluginを取得し、flake.lockにpinすること。
- neovim本体は、nixpkgsのneovimか、neovim-overlayかはユーザーが自由に選択でき、nvimxと統合できること。

## コミュニケーション

- コミュニケーションは日本語で行うこと。

## バージョン管理

- commit messageはconventional commitsに準拠すること
- mainへのpushは禁止。必ずブランチを作成し、PRでマージすること
- commit messageおよびPRは英語で記述すること
