{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixpkgs-unstable";
    treefmt-nix.url = "github:numtide/treefmt-nix";
    agent-skills.url = "github:Kyure-A/agent-skills-nix";
    anthropic-skills.url = "github:anthropics/skills";
    anthropic-skills.flake = false;
    lazy-nvim.url = "github:folke/lazy.nvim";
    lazy-nvim.flake = false;
    # For the hm module checks. The module itself does not depend on home-manager
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
      # x86_64-darwin is out of scope: nixpkgs 26.11 dropped support for it
      systems = [
        "x86_64-linux"
        "aarch64-darwin"
      ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
      pkgsFor = system: import nixpkgs { inherit system; };
      nvimxLibFor =
        system:
        import ./nix/lib {
          pkgs = pkgsFor system;
          lazyNvimSeed = lazy-nvim;
        };

      # The agent skills catalog / allowlist / selection do not depend on pkgs.
      # Only the bundle does, so it is assembled on the apps side.
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
        description = "home-manager dotfiles template with nvimx integrated";
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
        let
          pkgs = pkgsFor system;
        in
        treefmt-nix.lib.mkWrapper pkgs {
          projectRootFile = "flake.nix";
          programs = {
            nixfmt.enable = true;
            # stylua picks up the repo-root stylua.toml because treefmt runs from the tree root and
            # stylua reads its cwd -- it does not search upwards unless asked (see stylua.toml).
            # Deliberately not setting programs.stylua.settings: doing so would make treefmt-nix
            # generate a
            # store-path stylua.toml and pass it via --config-path, which wins over (and
            # silently ignores) the repo's stylua.toml -- editors and CI would then disagree.
            # The cost of that choice: treefmt caches on the file plus the command, so editing
            # stylua.toml or .luacheckrc does not invalidate anything. Use `nix fmt --
            # --clear-cache` after changing them. CI passes --ci, which implies --no-cache.
            stylua.enable = true;
            # stylua rewrites files, luacheck only reads them. treefmt applies formatters
            # matching the same file in ascending priority order, so pin the order explicitly
            # (omitting it falls back to name order, which runs luacheck before stylua).
            stylua.priority = 1;
          };
          # luacheck is a linter, not a formatter, so treefmt-nix has no programs.luacheck.
          # treefmt only requires a formatter to accept paths and exit non-zero on failure;
          # luacheck never rewrites files, so it fits as-is (upstream does the same for
          # shellcheck / statix / yamllint, etc.). Configuration comes from .luacheckrc.
          settings.formatter.luacheck = {
            command = pkgs.luaPackages.luacheck;
            includes = [ "*.lua" ];
            priority = 2;
          };
        }
      );

      checks = forAllSystems (
        system:
        import ./tests/checks {
          pkgs = pkgsFor system;
          nvimxLib = nvimxLibFor system;
          inherit self lazy-nvim home-manager;
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
