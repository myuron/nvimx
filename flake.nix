{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixpkgs-unstable";
    treefmt-nix.url = "github:numtide/treefmt-nix";
    agent-skills.url = "github:Kyure-A/agent-skills-nix";
    anthropic-skills.url = "github:anthropics/skills";
    anthropic-skills.flake = false;
    lazy-nvim.url = "github:folke/lazy.nvim";
    lazy-nvim.flake = false;
    # hm module の checks 用。module 自体は home-manager に依存しない
    home-manager.url = "github:nix-community/home-manager";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs =
    {
      self,
      nixpkgs,
      treefmt-nix,
      agent-skills,
      anthropic-skills,
      lazy-nvim,
      home-manager,
    }:
    let
      systems = [
        "x86_64-linux"
        "x86_64-darwin"
      ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
      pkgsFor = system: import nixpkgs { inherit system; };
      nvimxLibFor =
        system:
        import ./nix/lib {
          pkgs = pkgsFor system;
          lazyNvimSeed = lazy-nvim;
        };

      # agent skills 関連は pkgs 非依存 (bundle のみ pkgs 依存なので apps 内で組む)
      agentLib = agent-skills.lib.agent-skills;
      sources = {
        anthropic = {
          path = anthropic-skills;
          subdir = "skills";
        };
      };
      catalog = agentLib.discoverCatalog sources;
      allowlist = agentLib.allowlistFor {
        inherit catalog sources;
        enable = [
          "doc-coauthoring"
          "skill-creator"
        ];
      };
      selection = agentLib.selectSkills {
        inherit catalog allowlist sources;
        skills = { };
      };
      localTargets = {
        claude = agentLib.defaultLocalTargets.claude // {
          enable = true;
        };
      };
    in
    {
      lib = forAllSystems (
        system:
        (nvimxLibFor system)
        // {
          lazyNvimSeed = lazy-nvim;
        }
      );

      homeModules = rec {
        nvimx = import ./nix/home-manager { lazyNvimSeed = lazy-nvim; };
        default = nvimx;
      };

      templates.default = {
        path = ./templates/default;
        description = "nvimx を組み込んだ home-manager dotfiles の雛形";
      };

      packages = forAllSystems (
        system:
        let
          pkgs = pkgsFor system;
          nvimxLib = nvimxLibFor system;
        in
        {
          demo =
            let
              env = nvimxLib.makeEnv {
                package = pkgs.neovim-unwrapped;
                lockDir = ./tests/fixtures/basic-config/nvimx-lock;
              };
              configDir = ./tests/fixtures/basic-config;
            in
            pkgs.writeShellApplication {
              name = "nvim";
              text = ''
                base="''${XDG_CACHE_HOME:-$HOME/.cache}/nvimx-demo"
                mkdir -p "$base/config" "$base/data/nvim/lazy" "$base/state" "$base/cache"
                ln -sfT ${configDir} "$base/config/nvim"
                ln -sfT ${env.farm}/lazy.nvim "$base/data/nvim/lazy/lazy.nvim"
                export XDG_CONFIG_HOME="$base/config"
                export XDG_DATA_HOME="$base/data"
                export XDG_STATE_HOME="$base/state"
                export XDG_CACHE_HOME="$base/cache"
                exec ${env.wrapped}/bin/nvim "$@"
              '';
            };
        }
      );

      formatter = forAllSystems (
        system:
        treefmt-nix.lib.mkWrapper (pkgsFor system) {
          projectRootFile = "flake.nix";
          programs = {
            nixfmt.enable = true;
          };
        }
      );

      checks = forAllSystems (
        system:
        let
          pkgs = pkgsFor system;
          nvimxLib = nvimxLibFor system;
          # fixture config で hm module を実際に評価・ビルドする
          mkHmCheck =
            nvimxConfig:
            (home-manager.lib.homeManagerConfiguration {
              inherit pkgs;
              modules = [
                self.homeModules.nvimx
                {
                  home.username = "nvimx-test";
                  home.homeDirectory = "/home/nvimx-test";
                  home.stateVersion = "25.05";
                  programs.nvimx = {
                    enable = true;
                  }
                  // nvimxConfig;
                }
              ];
            }).activationPackage;
        in
        {
          # lock あり: farm / wrapper / dataFile 配備まで一式ビルドできること
          hm-module = mkHmCheck {
            configDir = ./tests/fixtures/basic-config;
            lockDir = ./tests/fixtures/basic-config/nvimx-lock;
            vimAlias = true;
            viAlias = true;
            lock.projectDir = "~/dotfiles";
          };
          # lock 不在: degrade ビルドで eval が通り切ること (鶏卵問題の検証)
          hm-module-degrade = mkHmCheck {
            configDir = ./tests/fixtures/basic-config;
            lockDir = ./tests/fixtures/basic-config/no-such-lock;
          };
          # vimAlias / viAlias: wrapper に vim / vi の symlink が生えること
          wrapper-aliases =
            let
              env = nvimxLib.makeEnv {
                package = pkgs.neovim-unwrapped;
                lockDir = ./tests/fixtures/basic-config/nvimx-lock;
                vimAlias = true;
                viAlias = true;
              };
            in
            pkgs.runCommand "wrapper-aliases" { } ''
              test -L ${env.wrapped}/bin/vim
              test -L ${env.wrapped}/bin/vi
              touch $out
            '';
          # fixture config に対する抽出結果のスナップショット比較。
          # 全て store 内 (fixture + seed + neovim) で完結するためネットワーク不要。
          extractor-snapshot =
            pkgs.runCommand "extractor-snapshot"
              {
                nativeBuildInputs = [
                  pkgs.neovim-unwrapped
                  pkgs.jq
                ];
              }
              ''
                export HOME=$TMPDIR
                sb=$TMPDIR/sandbox
                mkdir -p $sb/config $sb/data/nvim/lazy $sb/state $sb/cache
                ln -s ${./tests/fixtures/basic-config} $sb/config/nvim
                ln -s ${lazy-nvim} $sb/data/nvim/lazy/lazy.nvim
                env \
                  XDG_CONFIG_HOME=$sb/config \
                  XDG_DATA_HOME=$sb/data \
                  XDG_STATE_HOME=$sb/state \
                  XDG_CACHE_HOME=$sb/cache \
                  NVIMX_LAZY_SEED=${lazy-nvim} \
                  NVIMX_OUT=$sb/raw-spec.json \
                  nvim --headless --cmd "luafile ${./lua/nvimx/extract.lua}"
                # lazyNvim.source は store path を含み seed 更新で変わるため除外して比較
                jq -S 'del(.lazyNvim)' $sb/raw-spec.json > got.json
                diff -u ${./tests/fixtures/golden/basic-config.raw-spec.json} got.json
                touch $out
              '';
          # lazy.setup を呼ばない config でハングせず明確なエラーで非ゼロ終了すること (#3)
          extractor-no-setup =
            pkgs.runCommand "extractor-no-setup"
              {
                nativeBuildInputs = [
                  pkgs.neovim-unwrapped
                  # darwin sandbox で timeout / grep を確実に解決するため明示
                  pkgs.coreutils
                ];
              }
              ''
                export HOME=$TMPDIR
                sb=$TMPDIR/sandbox
                mkdir -p $sb/config $sb/data/nvim/lazy $sb/state $sb/cache
                ln -s ${./tests/fixtures/empty-config} $sb/config/nvim
                ln -s ${lazy-nvim} $sb/data/nvim/lazy/lazy.nvim
                rc=0
                env \
                  XDG_CONFIG_HOME=$sb/config \
                  XDG_DATA_HOME=$sb/data \
                  XDG_STATE_HOME=$sb/state \
                  XDG_CACHE_HOME=$sb/cache \
                  NVIMX_LAZY_SEED=${lazy-nvim} \
                  NVIMX_OUT=$sb/raw-spec.json \
                  timeout 60 nvim --headless --cmd "luafile ${./lua/nvimx/extract.lua}" \
                  2> stderr.log < /dev/null || rc=$?
                cat stderr.log >&2
                if [ "$rc" -eq 0 ] || [ "$rc" -eq 124 ]; then
                  echo "expected fast non-zero exit, got rc=$rc" >&2
                  exit 1
                fi
                grep -q 'did not call require("lazy").setup' stderr.log
                touch $out
              '';
        }
      );

      apps = forAllSystems (
        system:
        let
          pkgs = pkgsFor system;
          nvimxLib = nvimxLibFor system;
          bundle = agentLib.mkBundle { inherit pkgs selection; };
        in
        {
          lock = {
            type = "app";
            program = "${nvimxLib.lockApp}/bin/nvimx-lock";
          };
          skills-install = {
            type = "app";
            program = "${
              agentLib.mkLocalInstallScript {
                inherit pkgs bundle;
                targets = localTargets;
              }
            }/bin/skills-install-local";
          };
        }
      );
    };
}
