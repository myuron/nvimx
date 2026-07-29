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
          # Actually evaluate and build the hm module against a fixture config
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
          # With a lock: the whole set (farm / wrapper / dataFile deployment) must build
          hm-module = mkHmCheck {
            configDir = ./tests/fixtures/basic-config;
            lockDir = ./tests/fixtures/basic-config/nvimx-lock;
            vimAlias = true;
            viAlias = true;
            lock.projectDir = "~/dotfiles";
          };
          # Without a lock: evaluation must still succeed via the degraded build
          # (verifies the chicken-and-egg problem is solved)
          hm-module-degrade = mkHmCheck {
            configDir = ./tests/fixtures/basic-config;
            lockDir = ./tests/fixtures/basic-config/no-such-lock;
          };
          # plugins.overrides / plugins.nixpkgsFallback through the module's option types
          # (attrsOf (functionTo package) / listOf str), which the lib-level checks bypass.
          # Both are set for the same plugin on purpose: the override then patches the
          # nixpkgs package, so the two must compose, not just evaluate.
          hm-module-plugins = mkHmCheck {
            configDir = ./tests/fixtures/basic-config;
            lockDir = ./tests/fixtures/basic-config/nvimx-lock;
            plugins = {
              nixpkgsFallback = [ "tokyonight.nvim" ];
              overrides."tokyonight.nvim" =
                { defaultDrv, ... }:
                defaultDrv.overrideAttrs (o: {
                  postInstall = (o.postInstall or "") + "touch $out/nvimx-hm-marker\n";
                });
            };
          };
          # treesitter.grammars through the module's option type
          # (nullOr (either (enum [ "all" ]) (listOf str))), which the lib-level check bypasses
          hm-module-treesitter = mkHmCheck {
            configDir = ./tests/fixtures/treesitter-config;
            lockDir = ./tests/fixtures/treesitter-config/nvimx-lock;
            treesitter.grammars = [ "lua" ];
          };
          # vimAlias / viAlias: the wrapper must grow vim / vi symlinks
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
          # build.kind == "shell": the recorded command must actually run, and its artifact
          # must reach both the plugin derivation and the farm
          build-shell =
            let
              env = nvimxLib.makeEnv {
                package = pkgs.neovim-unwrapped;
                lockDir = ./tests/fixtures/build-plugins/nvimx-lock;
              };
            in
            pkgs.runCommand "build-shell" { } ''
              test -f ${env.pluginDrvs."telescope-fzf-native.nvim"}/build/libfzf.so
              test -f ${env.farm}/telescope-fzf-native.nvim/build/libfzf.so
              touch $out
            '';
          # Phase behavior per build.kind, and the reasons plugin-drv sets dontFixup.
          # Hermetic: the source is a local fixture, so nothing here needs the network.
          plugin-drv-phases =
            let
              mkLocal =
                build:
                nvimxLib.mkPluginDrv {
                  name = "local-plugin";
                  src = ./tests/fixtures/local-plugin;
                  inherit build;
                };
              shell = mkLocal {
                kind = "shell";
                cmd = "make";
              };
              excmd = mkLocal {
                kind = "excmd";
                cmd = ":TSUpdate";
              };
              none = mkLocal { kind = "none"; };
            in
            pkgs.runCommand "plugin-drv-phases" { } ''
              # only kind == "shell" runs a build
              test -f ${shell}/build/artifact.txt
              test ! -e ${excmd}/build
              test ! -e ${none}/build

              for p in ${shell} ${excmd} ${none}; do
                # helptags are generated for every kind
                test -f "$p/doc/tags"
                # doc/ must stay at the plugin root: stdenv's move-docs hook would relocate it
                # to share/doc/ and break :h
                test ! -e "$p/share"
                # upstream files must survive verbatim: patchShebangs rewrites this line into
                # `env -S  -l`, dropping the interpreter
                grep -qF '#!/usr/bin/env -S nvim -l' "$p/scripts/run"
              done
              touch $out
            '';
          # Builds that need the network must be rejected at evaluation time, with a message
          # naming the escape hatches -- and offline builds must not be caught by mistake
          build-network-detect =
            let
              inherit (pkgs) lib;
              inherit (nvimxLib) buildNetwork mkPluginDrv;
              cases = [
                {
                  cmd = "make";
                  want = null;
                }
                {
                  cmd = "cmake --build build";
                  want = null;
                }
                {
                  cmd = "cd deps && make";
                  want = null;
                }
                {
                  cmd = "make CFLAGS=-O2";
                  want = null;
                }
                {
                  cmd = "./install.sh";
                  want = null;
                }
                # command substitution must not be mistaken for the outer command...
                {
                  cmd = "make -j$(nproc)";
                  want = null;
                }
                # ...but it must still be inspected
                {
                  cmd = "make VERSION=$(git describe)";
                  want = "git";
                }
                # quoted text is data, not a command
                {
                  cmd = "echo \"done; git skipped\"";
                  want = null;
                }
                {
                  cmd = "make CFLAGS=\"-O2 -g\"";
                  want = null;
                }
                {
                  cmd = "cargo build --release";
                  want = "cargo";
                }
                {
                  cmd = "npm install";
                  want = "npm";
                }
                {
                  cmd = "env FOO=1 cargo build";
                  want = "cargo";
                }
                # a wrapper's own flags and duration argument must be stepped over
                {
                  cmd = "env -i cargo build";
                  want = "cargo";
                }
                {
                  cmd = "timeout 60 curl -O https://example.com/x";
                  want = "curl";
                }
                {
                  cmd = "make && curl -O https://example.com/x";
                  want = "curl";
                }
                {
                  cmd = "git submodule update --init";
                  want = "git";
                }
              ];
              misclassified = builtins.filter (c: buildNetwork.detect c.cmd != c.want) cases;
              message = buildNetwork.message {
                name = "demo.nvim";
                cmd = "cargo build --release";
                tool = "cargo";
              };
              hatches = [
                "nix/build-registry/"
                "plugins.overrides"
                "plugins.nixpkgsFallback"
              ];
              evaluates =
                cmd:
                (builtins.tryEval (
                  builtins.seq
                    (mkPluginDrv {
                      name = "demo.nvim";
                      src = ./tests/fixtures/empty-config;
                      build = {
                        kind = "shell";
                        inherit cmd;
                      };
                    }).drvPath
                    null
                )).success;
              failures =
                map (
                  c: "misclassified ${builtins.toJSON c.cmd}: got ${builtins.toJSON (buildNetwork.detect c.cmd)}"
                ) misclassified
                ++ map (h: "the error message does not mention ${h}") (
                  builtins.filter (h: !lib.hasInfix h message) hatches
                )
                ++ lib.optional (evaluates "cargo build --release") "mkPluginDrv did not throw for a network build"
                ++ lib.optional (!evaluates "make") "mkPluginDrv threw for an offline build";
            in
            pkgs.runCommand "build-network-detect" { } (
              if failures == [ ] then
                "touch $out"
              else
                ''
                  ${lib.concatMapStringsSep "\n" (f: "echo ${lib.escapeShellArg f} >&2") failures}
                  exit 1
                ''
            );
          # plugins.overrides: patching the default derivation, replacing it outright, and
          # outranking a nixpkgsFallback configured for the same plugin
          plugins-overrides =
            let
              inherit (pkgs) lib;
              mkEnv =
                plugins:
                nvimxLib.makeEnv {
                  package = pkgs.neovim-unwrapped;
                  lockDir = ./tests/fixtures/basic-config/nvimx-lock;
                  inherit plugins;
                };
              patched = mkEnv {
                overrides."tokyonight.nvim" =
                  { defaultDrv, ... }:
                  defaultDrv.overrideAttrs (o: {
                    postInstall = (o.postInstall or "") + "touch $out/nvimx-override-marker\n";
                  });
              };
              replaced = mkEnv {
                overrides."tokyonight.nvim" =
                  { pkgs, src, ... }:
                  pkgs.runCommand "nvimx-custom-tokyonight" { } ''
                    mkdir -p $out
                    cp ${src}/README.md $out/
                    touch $out/nvimx-custom
                  '';
              };
              precedence = mkEnv {
                nixpkgsFallback = [ "tokyonight.nvim" ];
                overrides."tokyonight.nvim" =
                  _:
                  pkgs.runCommand "nvimx-override-wins" { } ''
                    mkdir -p $out
                    touch $out/nvimx-override-wins
                  '';
              };
              # An identity override receives whatever nvimx would have used otherwise -- with a
              # fallback configured that is the nixpkgs package, not the generic build.
              # Compared by outPath so the check does not have to build it.
              identity = mkEnv {
                nixpkgsFallback = [ "tokyonight.nvim" ];
                overrides."tokyonight.nvim" = { defaultDrv, ... }: defaultDrv;
              };
              # a typo must not be a silent no-op: the module turns this into a warning
              unknown = (mkEnv { nixpkgsFallback = [ "no-such.nvim" ]; }).unknownPluginNames;
              failures =
                lib.optional (
                  identity.pluginDrvs."tokyonight.nvim".outPath != pkgs.vimPlugins.tokyonight-nvim.outPath
                ) "an override's defaultDrv should be the nixpkgsFallback package when one is configured"
                ++ lib.optional (
                  unknown != [ "no-such.nvim" ]
                ) "a name absent from the lock should show up in unknownPluginNames";
            in
            pkgs.runCommand "plugins-overrides" { } (
              if failures == [ ] then
                ''
                  # overrideAttrs-style patch: the default build still ran, plus the added step
                  test -f ${patched.farm}/tokyonight.nvim/nvimx-override-marker
                  test -d ${patched.farm}/tokyonight.nvim/lua

                  # wholesale replacement: only the override's output reaches the farm
                  test -f ${replaced.farm}/tokyonight.nvim/nvimx-custom
                  test -f ${replaced.farm}/tokyonight.nvim/README.md
                  test ! -e ${replaced.farm}/tokyonight.nvim/lua

                  # overrides > nixpkgsFallback
                  test -f ${precedence.farm}/tokyonight.nvim/nvimx-override-wins
                  touch $out
                ''
              else
                ''
                  ${lib.concatMapStringsSep "\n" (f: "echo ${lib.escapeShellArg f} >&2") failures}
                  exit 1
                ''
            );
          # plugins.nixpkgsFallback: the plugin comes from pkgs.vimPlugins instead of the lock,
          # including the "." -> "-" attribute-name normalization
          plugins-nixpkgs-fallback =
            let
              inherit (pkgs) lib;
              env = nvimxLib.makeEnv {
                package = pkgs.neovim-unwrapped;
                lockDir = ./tests/fixtures/build-plugins/nvimx-lock;
                plugins.nixpkgsFallback = [ "telescope-fzf-native.nvim" ];
              };
              # nixpkgs has no single spelling for a vimPlugins attribute, so every spelling
              # the lookup tries must work. Compared by outPath: nothing here has to be built.
              resolveByName =
                name:
                nvimxLib.resolvePlugin {
                  inherit name;
                  src = ./tests/fixtures/local-plugin;
                  nixpkgsFallback = [ name ];
                };
              nameCases = [
                {
                  name = "LazyVim"; # verbatim
                  want = pkgs.vimPlugins.LazyVim;
                }
                {
                  name = "CopilotChat.nvim"; # "." -> "-", casing preserved
                  want = pkgs.vimPlugins.CopilotChat-nvim;
                }
                {
                  name = "telescope.nvim"; # "." -> "-", lowercased
                  want = pkgs.vimPlugins.telescope-nvim;
                }
              ];
              misresolved = builtins.filter (c: (resolveByName c.name).outPath != c.want.outPath) nameCases;
              # a name matching no vimPlugins attribute must fail loudly, not silently build
              unknownEvaluates =
                (builtins.tryEval (builtins.seq (resolveByName "no-such-plugin.nvim").drvPath null)).success;
              failures =
                lib.optional
                  (
                    env.pluginDrvs."telescope-fzf-native.nvim".outPath
                    != pkgs.vimPlugins.telescope-fzf-native-nvim.outPath
                  )
                  "nixpkgsFallback did not resolve telescope-fzf-native.nvim to pkgs.vimPlugins.telescope-fzf-native-nvim"
                ++ map (c: "nixpkgsFallback resolved ${builtins.toJSON c.name} to the wrong attribute") misresolved
                ++ lib.optional unknownEvaluates "nixpkgsFallback did not throw for a name absent from vimPlugins";
            in
            pkgs.runCommand "plugins-nixpkgs-fallback" { } (
              if failures == [ ] then
                ''
                  # nixpkgs lays a vim plugin out at $out (rtpPath = "."), so it drops into the
                  # farm as-is and stays usable
                  test -f ${env.farm}/telescope-fzf-native.nvim/build/libfzf.so
                  touch $out
                ''
              else
                ''
                  ${lib.concatMapStringsSep "\n" (f: "echo ${lib.escapeShellArg f} >&2") failures}
                  exit 1
                ''
            );
          # nix/build-registry: a shipped recipe must fix a plugin up with no user configuration,
          # must lose to both per-user hatches, and must leave every other plugin on the generic
          # path -- including when its entry is removed.
          build-registry =
            let
              inherit (pkgs) lib;
              # End to end: the fixture spec declares no build at all (as many real specs do),
              # so build/libfzf.so can only come from the registry entry.
              env = nvimxLib.makeEnv {
                package = pkgs.neovim-unwrapped;
                lockDir = ./tests/fixtures/registry-plugins/nvimx-lock;
              };
              # The entry replaces a build that downloads its artifact, so nothing here is
              # fetched. Resolved against the real upstream tree (pkgs.fzf is already a
              # dependency of the entry, so its src costs nothing extra): the entry checks the
              # tree it was handed, and bin/ exists there with other files in it.
              fzf = nvimxLib.resolvePlugin {
                name = "fzf";
                src = pkgs.fzf.src;
                build = {
                  kind = "shell";
                  cmd = "./install --bin";
                };
              };
              # The mechanism itself, checked against a stub registry so that it does not depend
              # on which plugins happen to be shipped today. Compared by outPath: nothing below
              # has to be built.
              pname = "telescope-fzf-native.nvim";
              mkGeneric =
                n:
                nvimxLib.mkPluginDrv {
                  name = n;
                  src = ./tests/fixtures/local-plugin;
                  build = {
                    kind = "none";
                  };
                };
              resolve =
                n: extra:
                nvimxLib.resolvePlugin (
                  {
                    name = n;
                    src = ./tests/fixtures/local-plugin;
                    build = {
                      kind = "none";
                    };
                  }
                  // extra
                );
              stubDrv = pkgs.runCommand "nvimx-registry-stub" { } "mkdir -p $out";
              stub.${pname} = _: stubDrv;
              # An entry must be handed the plugin it is keyed by, plus the generic builder.
              # Fed to `overrides` further down as well: the two contracts are meant to be
              # identical, so the very same function has to work in both positions.
              echoArgs.${pname} =
                {
                  name,
                  src,
                  mkPluginDrv,
                  ...
                }:
                mkPluginDrv {
                  inherit name src;
                  build = {
                    kind = "none";
                  };
                };
              echoDefault.${pname} = { defaultDrv, ... }: defaultDrv;
              failures =
                lib.optional (
                  (resolve pname { registry = stub; }).outPath != stubDrv.outPath
                ) "a registry entry did not win over the generic build"
                ++ lib.optional (
                  (resolve pname { registry = echoArgs; }).outPath != (mkGeneric pname).outPath
                ) "a registry entry did not receive name / src / mkPluginDrv"
                ++ lib.optional (
                  (resolve pname { registry = echoDefault; }).outPath != (mkGeneric pname).outPath
                ) "a registry entry's defaultDrv should be the generic build"
                # the documented way out of a shipped recipe: rebuild with mkPluginDrv
                ++ lib.optional (
                  (resolve pname { overrides = echoArgs; }).outPath != (mkGeneric pname).outPath
                ) "an override did not receive name / src / mkPluginDrv"
                ++ lib.optional (
                  (resolve pname { registry = { }; }).outPath != (mkGeneric pname).outPath
                ) "removing an entry should fall back to the generic build"
                ++ lib.optional (
                  (resolve "no-such.nvim" { }).outPath != (mkGeneric "no-such.nvim").outPath
                ) "a plugin the shipped registry does not cover should take the generic build"
                ++ lib.optional (
                  (resolve pname {
                    registry = stub;
                    nixpkgsFallback = [ pname ];
                  }).outPath != pkgs.vimPlugins.telescope-fzf-native-nvim.outPath
                ) "plugins.nixpkgsFallback should outrank the registry"
                ++ lib.optional (
                  (resolve pname {
                    registry = stub;
                    overrides.${pname} = { defaultDrv, ... }: defaultDrv;
                  }).outPath != stubDrv.outPath
                ) "an override's defaultDrv should be the registry entry's result";
            in
            pkgs.runCommand "build-registry" { } (
              if failures == [ ] then
                ''
                  # the spec declares no build, so only the registry can have produced this
                  test -f ${env.farm}/telescope-fzf-native.nvim/build/libfzf.so
                  # ... and here the entry stands in for a binary the sandbox cannot download,
                  # without disturbing what upstream already ships next to it
                  test -x ${fzf}/bin/fzf
                  test -f ${fzf}/bin/fzf-tmux
                  test -f ${fzf}/plugin/fzf.vim
                  touch $out
                ''
              else
                ''
                  ${lib.concatMapStringsSep "\n" (f: "echo ${lib.escapeShellArg f} >&2") failures}
                  exit 1
                ''
            );
          # The escape hatches must actually rescue a plugin whose build needs the network --
          # that is what build-network.nix's error message promises. All three sit in front of
          # the generic build, so the throw must never be reached.
          plugins-escape-hatch =
            let
              inherit (pkgs) lib;
              resolve =
                name: extra:
                nvimxLib.resolvePlugin (
                  {
                    inherit name;
                    src = ./tests/fixtures/local-plugin;
                    build = {
                      kind = "shell";
                      cmd = "cargo build --release";
                    };
                  }
                  // extra
                );
              evaluates =
                name: extra: (builtins.tryEval (builtins.seq (resolve name extra).drvPath null)).success;
              failures =
                lib.optional (evaluates "tokyonight.nvim" { }) "a build needing the network must still be rejected"
                ++ lib.optional (
                  !(evaluates "tokyonight.nvim" {
                    overrides."tokyonight.nvim" =
                      { pkgs, ... }:
                      pkgs.runCommand "nvimx-hatch" { } "mkdir -p $out";
                  })
                ) "plugins.overrides did not rescue a build needing the network"
                ++ lib.optional (
                  !(evaluates "tokyonight.nvim" { nixpkgsFallback = [ "tokyonight.nvim" ]; })
                ) "plugins.nixpkgsFallback did not rescue a build needing the network"
                # "fzf" is shipped in nix/build-registry precisely because its declared build
                # downloads a release binary. Its real command (`./install --bin`) is not what
                # is resolved here on purpose: build-network.nix cannot see the fetch inside
                # that script, so it would not exercise the rescue at all
                ++ lib.optional (
                  !(evaluates "fzf" { })
                ) "nix/build-registry did not rescue a build needing the network";
            in
            pkgs.runCommand "plugins-escape-hatch" { } (
              if failures == [ ] then
                "touch $out"
              else
                ''
                  ${lib.concatMapStringsSep "\n" (f: "echo ${lib.escapeShellArg f} >&2") failures}
                  exit 1
                ''
            );
          # treesitter.grammars: the parsers are the one thing the generic build cannot produce,
          # and the promise is a runtime one -- neovim must find and load them with no install
          # step -- so this really starts neovim and parses with them.
          treesitter-grammars =
            let
              inherit (pkgs) lib;
              mkEnv =
                args:
                nvimxLib.makeEnv (
                  {
                    package = pkgs.neovim-unwrapped;
                    lockDir = ./tests/fixtures/treesitter-config/nvimx-lock;
                  }
                  // args
                );
              merged = mkEnv {
                treesitter.grammars = [
                  "lua"
                  "nix"
                ];
              };
              # null is the opt-out: nvim-treesitter stays exactly as it was resolved
              plain = mkEnv { treesitter.grammars = null; };
              # The merge sits on top of resolution, so an override still decides what the
              # plugin itself is -- and grammars land on that.
              overridden = mkEnv {
                treesitter.grammars = [ "lua" ];
                plugins.overrides."nvim-treesitter" =
                  _:
                  pkgs.runCommand "nvimx-custom-treesitter" { } ''
                    mkdir -p $out/lua
                    touch $out/nvimx-custom
                  '';
              };
              # A grammar that needs another one must pull it in, the way nvim-treesitter's own
              # installer expands `requires`. Checked against stubs so it does not depend on
              # which grammars happen to declare a dependency today.
              mkStub =
                name: requires:
                pkgs.runCommand "nvimx-stub-grammar-${name}" { passthru = { inherit requires; }; } ''
                  mkdir -p $out/parser
                  touch $out/parser/${name}.so
                '';
              stubGrammars = {
                alpha = mkStub "alpha" [ "beta" ];
                beta = mkStub "beta" [ ];
              };
              stubbed = nvimxLib.mkTreesitter {
                plugin = pkgs.runCommand "nvimx-stub-treesitter" { } "mkdir -p $out/lua";
                grammars = [ "alpha" ];
                grammarPlugins = stubGrammars;
              };
              stubbedAll = nvimxLib.mkTreesitter {
                plugin = pkgs.runCommand "nvimx-stub-treesitter" { } "mkdir -p $out/lua";
                grammars = "all";
                grammarPlugins = stubGrammars;
              };
              evaluates =
                grammars:
                (builtins.tryEval (
                  builtins.seq (mkEnv { treesitter.grammars = grammars; }).pluginDrvs."nvim-treesitter".drvPath null
                )).success;
              # Selecting grammars without nvim-treesitter in the lock is a no-op the module warns about
              withoutPlugin =
                (nvimxLib.makeEnv {
                  package = pkgs.neovim-unwrapped;
                  lockDir = ./tests/fixtures/basic-config/nvimx-lock;
                  treesitter.grammars = [ "lua" ];
                }).treesitterWithoutPlugin;
              failures =
                lib.optional (
                  !(evaluates "all")
                ) ''treesitter.grammars = "all" should evaluate against the real nixpkgs grammar set''
                ++ lib.optional (evaluates [
                  "no-such-language"
                ]) "an unknown grammar name should throw, not build without the parser"
                ++ lib.optional (!withoutPlugin) "grammars without nvim-treesitter in the lock should be reported"
                ++ lib.optional ((mkEnv { }).treesitterWithoutPlugin
                ) "grammars left at null should never be reported as unused";
            in
            pkgs.runCommand "treesitter-grammars"
              {
                nativeBuildInputs = [ pkgs.neovim-unwrapped ];
              }
              (
                if failures == [ ] then
                  ''
                    ts=${merged.farm}/nvim-treesitter

                    # the plugin tree survives the merge whole
                    test -f "$ts/lua/nvim-treesitter/install.lua"
                    test -f "$ts/doc/tags"

                    # ... and the parsers land where neovim looks for them
                    test -e "$ts/parser/lua.so"
                    test -e "$ts/parser/nix.so"

                    # queries come from the locked plugin. On the `main` layout they sit off the
                    # runtimepath under runtime/, linked in per selected language
                    test -f "$ts/queries/lua/highlights.scm"

                    # null leaves nvim-treesitter parserless, exactly as upstream ships it
                    test ! -e ${plain.farm}/nvim-treesitter/parser

                    # an override decides the plugin; the grammars still merge onto it
                    test -f ${overridden.farm}/nvim-treesitter/nvimx-custom
                    test -e ${overridden.farm}/nvim-treesitter/parser/lua.so

                    # a grammar's own dependencies come along, both when named and under "all"
                    test -e ${stubbed}/parser/alpha.so
                    test -e ${stubbed}/parser/beta.so
                    test -e ${stubbedAll}/parser/alpha.so
                    test -e ${stubbedAll}/parser/beta.so

                    # the point of all of the above: a real neovim loads the parsers off the
                    # runtimepath and parses with them, with no :TSInstall anywhere
                    export HOME=$TMPDIR
                    cat > parse.lua <<'EOF'
                    local ts = arg[1]
                    vim.opt.rtp:prepend(ts)
                    -- neovim bundles a parser and queries for lua (but not for nix), so every
                    -- lookup below is pinned to the merged plugin rather than merely satisfied
                    local function found(pat)
                      local hit = vim.api.nvim_get_runtime_file(pat, false)[1]
                      if not hit or not vim.startswith(hit, ts) then
                        error(pat .. ": not found under " .. ts .. " (got " .. tostring(hit) .. ")")
                      end
                      return hit
                    end
                    for _, lang in ipairs({ "lua", "nix" }) do
                      -- loads the shared object: fails outright on an ABI mismatch
                      vim.treesitter.language.add(lang, { path = found("parser/" .. lang .. ".so") })
                      local tree = vim.treesitter.get_string_parser("", lang):parse()[1]
                      assert(tree:root(), lang .. ": parsed no tree")
                      found("queries/" .. lang .. "/highlights.scm")
                      assert(vim.treesitter.query.get(lang, "highlights"), lang .. ": no highlights query")
                    end
                    EOF
                    nvim --clean --headless -l parse.lua "$ts"
                    touch $out
                  ''
                else
                  ''
                    ${lib.concatMapStringsSep "\n" (f: "echo ${lib.escapeShellArg f} >&2") failures}
                    exit 1
                  ''
              );
          # Snapshot comparison of the extraction result for a fixture config.
          # Everything is self-contained in the store (fixture + seed + neovim), so no network is needed.
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
                # lazyNvim.source contains a store path that changes when the seed is updated, so exclude it
                jq -S 'del(.lazyNvim)' $sb/raw-spec.json > got.json
                diff -u ${./tests/fixtures/golden/basic-config.raw-spec.json} got.json
                touch $out
              '';
          # A config that never calls lazy.setup must not hang; it must exit non-zero with a clear error (#3)
          extractor-no-setup =
            pkgs.runCommand "extractor-no-setup"
              {
                nativeBuildInputs = [
                  pkgs.neovim-unwrapped
                  # timeout is not on PATH inside the darwin sandbox, so pull it in explicitly
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
