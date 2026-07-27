# CLAUDE.md

## 目的

- neovimで使用されているLuaの柔軟性を活かしつつ、nixの再現性を享受する最強のnix x neovim managerを作る

## 要件

- home-manager moduleを提供し、ユーザーのdotfilesに組み込めること。
- lazy.nvim形式のluaを解析し、必要なpluginを取得し、flake.lockにpinすること。
- neovim本体は、nixpkgsのneovimか、neovim-overlayかはユーザーが自由に選択でき、nvimxと統合できること。

## 構成メモ

- `flake.nix` は `x86_64-linux` / `aarch64-darwin` の複数systemに対応している(`forAllSystems = nixpkgs.lib.genAttrs systems`)。system依存のoutput(`lib` / `packages` / `formatter` / `checks` / `apps`)を追加する際は必ず `forAllSystems (system: ...)` でラップすること。`homeModules` / `templates` はpkgs非依存なのでsystem別にしない。
- `x86_64-darwin` (Intel Mac) は対象外。nixpkgs 26.11 がサポートを打ち切っており、`nixpkgs-unstable` をpinしている限り評価時点で `throw` する。Intel Macで使いたい場合はユーザー側で `nixpkgs-26.05-darwin` を指定してもらう(同ブランチも2026年末でEOL)。
- CI (`.github/workflows/ci.yml`) は上記2systemに対応するrunner (`ubuntu-latest` / `macos-latest`) のmatrixで回す。macOSのrunner labelは廃止サイクルが速いため、追加・変更時は必ず現行の [GitHub-hosted runners](https://docs.github.com/en/actions/reference/runners/github-hosted-runners) に存在するlabelか確認すること。**廃止済みlabelを指定してもジョブはエラーにならず、永久にqueuedのまま残る**(過去に `macos-13` でこれが発生)。
- ローカル(Linux)の `nix flake check` は他systemを `omitted these incompatible systems` でスキップするため、darwin側の評価エラーは検出できない。darwin側を触ったら `nix eval .#checks.aarch64-darwin.<name>.drvPath` で評価だけ確認すること。

## コミュニケーション

- コミュニケーションは日本語で行うこと。

## バージョン管理

- commit messageはconventional commitsに準拠すること
- mainへのpushは禁止。必ずブランチを作成し、PRでマージすること
- commit messageおよびPRは英語で記述すること
