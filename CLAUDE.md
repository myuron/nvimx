# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 目的

- neovimで使用されているLuaの柔軟性を活かしつつ、nixの再現性を享受する最強のnix x neovim managerを作る

## 要件

- home-manager moduleを提供し、ユーザーのdotfilesに組み込めること。
- lazy.nvim形式のluaを解析し、必要なpluginを取得し、flake.lockにpinすること。
- neovim本体は、nixpkgsのneovimか、neovim-overlayかはユーザーが自由に選択でき、nvimxと統合できること。

## 開発コマンド

- `nix flake check` : 全チェック(hm-module / hm-module-degrade / wrapper-aliases / extractor-snapshot / extractor-no-setup)を実行。オフライン・純粋に動作する。
- `nix build .#checks.x86_64-linux.<name>` : 単一チェックのみ実行(例: `extractor-snapshot`)。
- `nix fmt` : treefmt-nix (nixfmt) でNixコードをフォーマット。コミット前に実行すること。Luaは対象外(stylua/luacheck未導入)。
- `nix run .#lock -- --config <dir> --out <lockDir>` : lockパイプライン。これだけはネットワークが必要。
- `nix run .#skills-install` : agent skills をローカル (`.claude/`) にインストール。

## 構成メモ

- `flake.nix` は `x86_64-linux` / `x86_64-darwin` の複数 system に対応(`forAllSystems = nixpkgs.lib.genAttrs systems`)。system 依存 output を追加する際は `forAllSystems (system: ...)` でラップすること。
- `docs/architecture.md` は将来構想を含む設計書であり、現状のコードと一致しない箇所がある(存在しないファイル・checkの記述あり)。現状把握はコードを正とすること。
- degradeモードは要: lockファイル不在でもevalは絶対に失敗させないこと(`nix/lib/make-env.nix` はlock不在時にseedのみのfarmを組む)。`--impure` は使用禁止。
- extractor (`lua/nvimx/extract.lua`) は実際の `lazy.setup` を実行せず、`package.preload["lazy"]` のshimでspecを捕捉する方式。
- lockパイプラインの抽出対象はgit管理下のファイルのみ。設定ファイルを追加・変更したら `git add` してから `nix run .#lock` を実行すること。
- `nix run .#demo` : サンドボックス化されたnvimを起動して動作確認できる。

## コミュニケーション

- コミュニケーションは日本語で行うこと。

## バージョン管理

- commit messageはconventional commitsに準拠すること
- mainへのpushは禁止。必ずブランチを作成し、PRでマージすること
- commit messageおよびPRは英語で記述すること
