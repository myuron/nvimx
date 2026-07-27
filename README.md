# nvimx

neovim の Lua の柔軟性と nix の再現性を両立する nix x neovim manager。

- lazy.nvim 形式の lua config を**無修正のまま**解析し、必要な plugin を flake.lock に pin する
- build は完全 pure(ネットワーク不要、`--impure` 不要)。lock が同じなら何度 switch しても同一結果
- neovim 本体は nixpkgs / neovim-nightly-overlay などから自由に選択できる

## 対応プラットフォーム

`x86_64-linux` / `aarch64-darwin` (Apple Silicon)。

Intel Mac (`x86_64-darwin`) は非対応。nixpkgs 26.11 が同 platform のサポートを打ち切ったため。

## home-manager での導入

### 1. flake input に nvimx を追加

dotfiles の `flake.nix`:

```nix
{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixpkgs-unstable";
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nvimx.url = "github:myuron/nvimx";
  };

  outputs =
    { nixpkgs, home-manager, nvimx, ... }:
    {
      homeConfigurations."myuser" = home-manager.lib.homeManagerConfiguration {
        # macOS (Apple Silicon) は "aarch64-darwin"
        pkgs = import nixpkgs { system = "x86_64-linux"; };
        modules = [
          nvimx.homeModules.nvimx
          {
            programs.nvimx = {
              enable = true;
              configDir = ./nvim;            # lazy.nvim 形式の lua config
              lockDir = ./nvim/nvimx-lock;   # nvimx-lock の生成物置き場
              lock.projectDir = "~/dotfiles"; # 引数なし `nvimx-lock` の対象
            };
          }
        ];
      };
    };
}
```

ゼロから始める場合は template も使える:

```sh
nix flake new --template github:myuron/nvimx ~/dotfiles
```

### 2. plugin を lock

```sh
cd ~/dotfiles
nix run github:myuron/nvimx#lock -- --config ./nvim --out ./nvim/nvimx-lock
git add nvim/nvimx-lock
```

headless nvim が lazy.nvim の spec を実評価して plugin 一覧を抽出し、
`plugins.json` / `flake.nix` / `flake.lock` を生成する。

### 3. switch

```sh
home-manager switch --flake .
```

これで `nvim` が PATH に入り、全 plugin が /nix/store から読み込まれる
(lazy.nvim の git/install パイプラインは完全にスキップされる)。

lock を忘れて switch しても失敗はせず、**degrade ビルド**(lazy.nvim のみ)で起動する。
`nvimx-lock` コマンドは degrade 時も PATH に入るので、
`nvimx-lock` → commit → 再 switch で完全状態に到達できる。手順の順序はどちらが先でもよい。

### plugin の追加

1. lua に spec を書く
2. `git add` (git 未追跡ファイルは抽出対象にならないため)
3. `nvimx-lock`(新規 plugin のみ fetch。既存 pin は不変)
4. commit → `home-manager switch`

## 主なオプション

```nix
programs.nvimx = {
  enable = true;

  # neovim 本体 (-unwrapped 系 derivation)
  package = pkgs.neovim-unwrapped;
  # package = inputs.neovim-nightly-overlay.packages.x86_64-linux.default;

  configDir = ./nvim;
  lockDir = ./nvim/nvimx-lock;

  manageConfig = true;   # true: config を store から配備(再現性重視、既定)
                         # false: ~/.config/nvim はユーザー管理

  vimAlias = false;      # true: `vim` コマンドで wrapped nvim を起動
  viAlias = false;       # true: `vi` コマンドで wrapped nvim を起動

  extraPackages = [ pkgs.ripgrep ];  # wrapper の PATH に前置 (lsp 等)

  lock = {
    installCommand = true;         # nvimx-lock を home.packages に追加
    projectDir = "~/dotfiles";     # 引数なし実行時の対象作業ツリー
    configDirRelative = "nvim";
    lockDirRelative = "nvim/nvimx-lock";
  };
};
```

### オプション一覧

`programs.nvimx.*`:

| オプション | 型 | 既定値 | 説明 |
| --- | --- | --- | --- |
| `enable` | `bool` | `false` | nvimx (nix x neovim manager) を有効化する。 |
| `package` | `package` | `pkgs.neovim-unwrapped` | neovim 本体 (-unwrapped 系 derivation)。neovim-nightly-overlay のものなども指定可。 |
| `configDir` | `nullOr path` | `null` | `init.lua` を含む lua config ディレクトリ。`manageConfig = true` のとき `xdg.configFile` で store から配備される。 |
| `lockDir` | `path` | (必須) | `nvimx-lock` が生成した `plugins.json` / `flake.nix` / `flake.lock` の置き場所。未生成 (lock 不在) の場合は degrade ビルドになる。 |
| `manageConfig` | `bool` | `true` | `true`: `configDir` を `xdg.configFile` で store から配備する (再現性重視、既定)。`false`: `~/.config/nvim` はユーザー管理 (高速イテレーション派)。 |
| `vimAlias` | `bool` | `false` | `vim` コマンドで wrapped neovim を起動する symlink を追加する。 |
| `viAlias` | `bool` | `false` | `vi` コマンドで wrapped neovim を起動する symlink を追加する。 |
| `extraPackages` | `listOf package` | `[ ]` | wrapper の PATH に前置するパッケージ (ripgrep, lsp 等)。 |
| `env` | `attrs` | (自動構築) | `makeEnv` の結果 (`farm` / `bootstrap` / `wrapped` / `hasLock`)。既定では上記オプションから自動構築される。上級者向けの直接指定口。 |

`programs.nvimx.lock.*`:

| オプション | 型 | 既定値 | 説明 |
| --- | --- | --- | --- |
| `lock.installCommand` | `bool` | `true` | `nvimx-lock` コマンドを `home.packages` に追加する。 |
| `lock.projectDir` | `nullOr str` | `null` | dotfiles リポジトリの作業ツリー。指定すると引数なしの `nvimx-lock` が `configDirRelative` / `lockDirRelative` を対象に実行される。 |
| `lock.configDirRelative` | `str` | `"nvim"` | `projectDir` から見た `configDir` の相対パス。 |
| `lock.lockDirRelative` | `str` | `"nvim/nvimx-lock"` | `projectDir` から見た `lockDir` の相対パス。 |

## 仕組み

lock 時 (`nvimx-lock`) にのみネットワークを使い、headless nvim がユーザーの
lazy spec を実評価 → plugin 一覧を `plugins.json` に、pin を `flake.lock` に永続化する。
build 時はそれらを読むだけの完全 pure 評価で、
plugin ごとの derivation → linkFarm → bootstrap.lua 注入済み wrapped neovim を構築する。

詳細は [docs/architecture.md](docs/architecture.md) を参照。

## 開発状況

実装フェーズ([docs/architecture.md](docs/architecture.md) 参照)のうち
Phase 4(home-manager module + template)まで完了。以下は今後対応予定:

- build 付き plugin(telescope-fzf-native 等)のフル対応、treesitter grammar 統合
- `nvimx-lock --update [name...]` / semver 解決 / `--import-lazy-lock`
- devPlugins(ローカル開発 plugin)、extraLuaPackages
