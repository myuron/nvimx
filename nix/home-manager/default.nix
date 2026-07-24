# programs.nvimx: home-manager module。
# lib.makeEnv を内包し、設定 1 箇所で wrapped neovim + nvimx-lock を配備する。
# lazyNvimSeed は nvimx flake の input (flake.nix で部分適用される)。
{ lazyNvimSeed }:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.programs.nvimx;
  nvimxLib = import ../lib { inherit pkgs lazyNvimSeed; };

  # projectDir 指定時は引数なし実行にデフォルトを与えるラッパーを被せる
  lockCommand =
    if cfg.lock.projectDir == null then
      nvimxLib.lockApp
    else
      pkgs.writeShellScriptBin "nvimx-lock" ''
        if [ "$#" -eq 0 ]; then
          project=${lib.escapeShellArg cfg.lock.projectDir}
          project=''${project/#\~/$HOME}
          exec ${nvimxLib.lockApp}/bin/nvimx-lock \
            --config "$project/"${lib.escapeShellArg cfg.lock.configDirRelative} \
            --out "$project/"${lib.escapeShellArg cfg.lock.lockDirRelative}
        fi
        exec ${nvimxLib.lockApp}/bin/nvimx-lock "$@"
      '';
in
{
  options.programs.nvimx = {
    enable = lib.mkEnableOption "nvimx (nix x neovim manager)";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.neovim-unwrapped;
      defaultText = lib.literalExpression "pkgs.neovim-unwrapped";
      description = ''
        neovim 本体 (-unwrapped 系 derivation)。
        neovim-nightly-overlay のものなども指定可。
      '';
    };

    configDir = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      example = lib.literalExpression "./nvim";
      description = ''
        init.lua を含む lua config ディレクトリ。
        manageConfig = true のとき xdg.configFile で store から配備される。
      '';
    };

    lockDir = lib.mkOption {
      type = lib.types.path;
      example = lib.literalExpression "./nvim/nvimx-lock";
      description = ''
        nvimx-lock が生成した plugins.json / flake.nix / flake.lock の置き場所。
        未生成 (lock 不在) の場合は degrade ビルドになる。
      '';
    };

    manageConfig = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        true: configDir を xdg.configFile で store から配備する (再現性重視、既定)。
        false: ~/.config/<appName> はユーザー管理 (高速イテレーション派)。
      '';
    };

    appName = lib.mkOption {
      type = lib.types.str;
      default = "nvim";
      description = ''
        NVIM_APPNAME。"nvimx" 等にすると既存の nvim 環境と併存してお試しできる。
      '';
    };

    extraPackages = lib.mkOption {
      type = lib.types.listOf lib.types.package;
      default = [ ];
      example = lib.literalExpression "[ pkgs.ripgrep pkgs.lua-language-server ]";
      description = "wrapper の PATH に前置するパッケージ (ripgrep, lsp 等)";
    };

    lock = {
      installCommand = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "nvimx-lock コマンドを home.packages に追加する";
      };

      projectDir = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "~/dotfiles";
        description = ''
          dotfiles リポジトリの作業ツリー。指定すると引数なしの
          `nvimx-lock` が configDirRelative / lockDirRelative を対象に実行される。
        '';
      };

      configDirRelative = lib.mkOption {
        type = lib.types.str;
        default = "nvim";
        description = "projectDir から見た configDir の相対パス";
      };

      lockDirRelative = lib.mkOption {
        type = lib.types.str;
        default = "nvim/nvimx-lock";
        description = "projectDir から見た lockDir の相対パス";
      };
    };

    env = lib.mkOption {
      type = lib.types.attrs;
      defaultText = lib.literalExpression "nvimx lib.makeEnv { ... }";
      description = ''
        makeEnv の結果 (farm / bootstrap / wrapped / hasLock)。
        既定では上記オプションから自動構築される。上級者向けの直接指定口。
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.manageConfig -> cfg.configDir != null;
        message = "programs.nvimx: manageConfig = true には configDir の指定が必要です";
      }
    ];

    warnings = lib.optional (!(cfg.env.hasLock or true)) ''
      programs.nvimx: lock files (plugins.json / flake.lock) not found in lockDir.
      Building in degraded mode (lazy.nvim seed only).
      Run `nvimx-lock`, commit the lock files, then re-run home-manager switch.
    '';

    programs.nvimx.env = lib.mkDefault (
      nvimxLib.makeEnv {
        inherit (cfg)
          package
          lockDir
          appName
          extraPackages
          ;
      }
    );

    home.packages = [ cfg.env.wrapped ] ++ lib.optional cfg.lock.installCommand lockCommand;

    xdg.configFile = lib.mkIf cfg.manageConfig {
      ${cfg.appName}.source = cfg.configDir;
    };

    # 標準 bootstrap snippet の fs_stat を成功させ、git clone を無害化する
    xdg.dataFile."${cfg.appName}/lazy/lazy.nvim".source = "${cfg.env.farm}/lazy.nvim";
  };
}
