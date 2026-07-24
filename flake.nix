{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixpkgs-unstable";
    treefmt-nix.url = "github:numtide/treefmt-nix";
    agent-skills.url = "github:Kyure-A/agent-skills-nix";
    anthropic-skills.url = "github:anthropics/skills";
    anthropic-skills.flake = false;
    lazy-nvim.url = "github:folke/lazy.nvim";
    lazy-nvim.flake = false;
  };

  outputs =
    {
      self,
      nixpkgs,
      treefmt-nix,
      agent-skills,
      anthropic-skills,
      lazy-nvim,
    }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs { inherit system; };
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
      bundle = agentLib.mkBundle { inherit pkgs selection; };
      localTargets = {
        claude = agentLib.defaultLocalTargets.claude // {
          enable = true;
        };
      };
      nvimxLib = import ./nix/lib { inherit pkgs; };
    in
    {
      lib = nvimxLib // {
        lazyNvimSeed = lazy-nvim;
      };

      packages.${system}.demo =
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

      formatter.${system} = treefmt-nix.lib.mkWrapper pkgs {
        projectRootFile = "flake.nix";
        programs = {
          nixfmt.enable = true;
        };
      };
      apps.${system} = {
        skills-install = {
          type = "app";
          program = "${
            agentLib.mkLocalInstallScript {
              inherit pkgs bundle;
              targets = localTargets;
            }
          }/bin/skills-install-local";
        };
      };
    };
}
