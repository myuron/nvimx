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
          # `defaults.version` is a config-wide opts key that lazy only ever applies at
          # git-operation time (lua/lazy/manage/git.lua:141), so extract.lua has to materialize it
          # per plugin or the constraint never reaches plugins.json and the config silently tracks
          # HEAD (#42). Self-contained in the store like extractor-snapshot, so no network is needed.
          extractor-defaults-version =
            pkgs.runCommand "extractor-defaults-version"
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
                ln -s ${lazy-nvim} $sb/data/nvim/lazy/lazy.nvim

                extract() { # <fixture> <raw-spec output>
                  rm -f $sb/config/nvim
                  ln -s "$1" $sb/config/nvim
                  env \
                    XDG_CONFIG_HOME=$sb/config \
                    XDG_DATA_HOME=$sb/data \
                    XDG_STATE_HOME=$sb/state \
                    XDG_CACHE_HOME=$sb/cache \
                    NVIMX_LAZY_SEED=${lazy-nvim} \
                    NVIMX_OUT="$2" \
                    nvim --headless --cmd "luafile ${./lua/nvimx/extract.lua}"
                }

                extract ${./tests/fixtures/defaults-version-config} $sb/defaults.json

                # raw-spec: extract.lua's own contract, unaffected by #23's resolution
                jq -e '.plugins["tokyonight.nvim"].version == "*"' $sb/defaults.json > /dev/null
                jq -e '.plugins["plenary.nvim"].version == "*"' $sb/defaults.json > /dev/null
                jq -e '.plugins["telescope.nvim"].version == "^0.1"' $sb/defaults.json > /dev/null
                jq -e '.plugins["trouble.nvim"] | has("version") | not' $sb/defaults.json > /dev/null
                jq -e '.plugins["trouble.nvim"].branch == "dev"' $sb/defaults.json > /dev/null
                jq -e '.plugins["which-key.nvim"] | has("version") | not' $sb/defaults.json > /dev/null
                jq -e '.plugins["which-key.nvim"].tag == "v3.0.0"' $sb/defaults.json > /dev/null
                jq -e '.plugins["flash.nvim"] | has("version") | not' $sb/defaults.json > /dev/null
                jq -e '.plugins["flash.nvim"].commit == "cbf1cb041a0e806c9f70e5b0b13d68f4dc26cfe8"' $sb/defaults.json > /dev/null
                # false must not be folded into truthy and turned into "*" (a falsy check would pass this)
                jq -e '.plugins["noice.nvim"].version == false' $sb/defaults.json > /dev/null

                # plugins.json: the issue's "Done when" is about the lock, so resolve it too
                nvim -l ${./lua/nvimx}/resolve.lua $sb/defaults.json plugins.json 2> resolve.log
                jq -e '.plugins["tokyonight.nvim"].version == "*"' plugins.json > /dev/null
                jq -e '.plugins["plenary.nvim"].version == "*"' plugins.json > /dev/null
                jq -e '.plugins["telescope.nvim"].version == "^0.1"' plugins.json > /dev/null
                jq -e '.plugins["noice.nvim"].version == null' plugins.json > /dev/null
                jq -e '.plugins["trouble.nvim"].version == null' plugins.json > /dev/null
                jq -e '.plugins["which-key.nvim"].version == null' plugins.json > /dev/null
                jq -e '.plugins["flash.nvim"].version == null' plugins.json > /dev/null
                # do not grep the warning text: resolve.lua's "is not resolved yet" message is
                # #23's TODO placeholder and will change when semver resolution lands.
                # This whole plugins.json section has to be rebuilt at #23 regardless: it resolves
                # github-type constraints with no network, which #23 turns into a hard error, so
                # resolve will exit non-zero before reaching any of these asserts. #23 replaces it
                # with the local-repo-as-remote approach its own check uses.
                jq -e '[.plugins[] | select(.version != null)] | length == 3' plugins.json > /dev/null

                # defaults.version = false must be indistinguishable from "unset" (#42 goal 3)
                extract ${./tests/fixtures/defaults-version-false-config} $sb/false.json
                jq -e '.plugins["tokyonight.nvim"] | has("version") | not' $sb/false.json > /dev/null
                jq -e '.plugins["telescope.nvim"].version == "^0.1"' $sb/false.json > /dev/null

                touch $out
              '';
          # A build nvimx cannot run (:excmd / Lua callback / list of steps) must be reported at
          # lock time, and must stay a warning: locking has to succeed anyway (#22).
          # The real lock app ends in `nix flake lock`, which needs the network, so this exercises
          # the two offline stages it chains -- extract then resolve -- which is the part under test.
          resolve-build-warnings =
            pkgs.runCommand "resolve-build-warnings"
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
                ln -s ${lazy-nvim} $sb/data/nvim/lazy/lazy.nvim

                extract() { # <fixture> <raw-spec output>
                  rm -f $sb/config/nvim
                  ln -s "$1" $sb/config/nvim
                  env \
                    XDG_CONFIG_HOME=$sb/config \
                    XDG_DATA_HOME=$sb/data \
                    XDG_STATE_HOME=$sb/state \
                    XDG_CACHE_HOME=$sb/cache \
                    NVIMX_LAZY_SEED=${lazy-nvim} \
                    NVIMX_OUT="$2" \
                    nvim --headless --cmd "luafile ${./lua/nvimx/extract.lua}"
                }

                extract ${./tests/fixtures/unbuildable-config} $sb/unbuildable.json
                rc=0
                # the whole directory, not the single file: resolve.lua dofile()s json.lua next to it
                nvim -l ${./lua/nvimx}/resolve.lua $sb/unbuildable.json plugins.json \
                  2> stderr.log || rc=$?
                cat stderr.log >&2
                if [ "$rc" -ne 0 ]; then
                  echo "resolve.lua must warn, not fail: got rc=$rc" >&2
                  exit 1
                fi

                # one warning per plugin, each naming the shape of the build it cannot run
                grep -q '^\[nvimx\] warning: plugin "nvim-treesitter": build is a neovim command (":TSUpdate")' stderr.log
                grep -q '^\[nvimx\] warning: plugin "markdown-preview.nvim": build is a Lua function ("<function>")' stderr.log
                # a list build is not a callback and must not be called one
                grep -q '^\[nvimx\] warning: plugin "LuaSnip": build is a list of build steps ("<table>")' stderr.log
                n=$(grep -c '^\[nvimx\] warning: plugin ' stderr.log)
                if [ "$n" -ne 3 ]; then
                  echo "expected exactly 3 plugin warnings, got $n" >&2
                  exit 1
                fi

                # every escape hatch is named, plus the treesitter-specific pointer
                grep -q 'plugins.overrides' stderr.log
                grep -q 'plugins.nixpkgsFallback' stderr.log
                grep -q 'nix/build-registry/' stderr.log
                grep -q 'programs.nvimx.treesitter.grammars' stderr.log

                # the same warnings are recorded in the lock, sorted by plugin name so that
                # re-locking does not reshuffle the array
                jq -e '.warnings | length == 3' plugins.json > /dev/null
                jq -e '.warnings[0] | startswith("plugin \"LuaSnip\"")' plugins.json > /dev/null
                jq -e '.warnings[1] | startswith("plugin \"markdown-preview.nvim\"")' plugins.json > /dev/null
                jq -e '.warnings[2] | startswith("plugin \"nvim-treesitter\"")' plugins.json > /dev/null
                # the "<function>" / "<table>" placeholder must not leak into build.cmd
                jq -e '.plugins["markdown-preview.nvim"].build == { kind: "function" }' plugins.json > /dev/null
                jq -e '.plugins["LuaSnip"].build == { kind: "function" }' plugins.json > /dev/null
                jq -e '.plugins["nvim-treesitter"].build.cmd == ":TSUpdate"' plugins.json > /dev/null

                # ...and the quiet path: a build nvimx *can* run must say nothing at all.
                # Without this, warning about every build would pass every assertion above.
                extract ${./tests/fixtures/build-plugins} $sb/buildable.json
                nvim -l ${./lua/nvimx}/resolve.lua $sb/buildable.json quiet.json 2> quiet.log
                if [ -s quiet.log ]; then
                  echo "a shell build must not warn, got:" >&2
                  cat quiet.log >&2
                  exit 1
                fi
                jq -e '.warnings == []' quiet.json > /dev/null
                touch $out
              '';
          # Merging with the previous lock is what makes plugins.json a lock rather than a report:
          # a decision already made must survive the next run, and `pin = true` must freeze (#18).
          # resolve.lua is the only stage that carries state, so driving it directly covers the
          # whole contract offline -- the `nix flake lock` around it needs the network and is
          # stubbed out here by a hand-written tests/fixtures/merge/flake.lock.
          resolve-merge =
            pkgs.runCommand "resolve-merge"
              {
                nativeBuildInputs = [
                  pkgs.neovim-unwrapped
                  pkgs.jq
                ];
              }
              ''
                export HOME=$TMPDIR
                # the whole directory, not the single file: resolve.lua dofile()s json.lua next to it
                lua=${./lua/nvimx}
                fx=${./tests/fixtures/merge}

                # The first resolve of a lock run cannot freeze anything: there is no previous
                # plugins.json to tell whether the flake.lock next to it still describes this spec.
                nvim -l $lua/resolve.lua $fx/raw-spec-base.json pass1.json --lock $fx/flake.lock \
                  2> pass1.log
                jq -e '.plugins["tokyonight.nvim"].resolvedRef == null' pass1.json > /dev/null
                jq -e '.plugins["custom.nvim"].resolvedRef == null' pass1.json > /dev/null

                # The second one -- the pass nvimx-lock runs once `nix flake lock` has caught up --
                # is what freezes them, and is the steady state. golden/base.plugins.json is that
                # state written out for review: pin / dependencies plus both frozen revs.
                nvim -l $lua/resolve.lua $fx/raw-spec-base.json out1.json \
                  --prev pass1.json --lock $fx/flake.lock 2> out1.log
                diff -u $fx/golden/base.plugins.json out1.json

                # "Running lock twice with no config change produces a byte-identical plugins.json":
                # the steady state has to be a fixed point, or the convergence pass would never end.
                nvim -l $lua/resolve.lua $fx/raw-spec-base.json out2.json \
                  --prev out1.json --lock $fx/flake.lock 2> out2.log
                cmp out1.json out2.json
                # warnings are derived every run and never merged, so they repeat verbatim
                diff -u out1.log out2.log

                # "A pinned plugin keeps its ref after an unrelated plugin is added."
                nvim -l $lua/resolve.lua $fx/raw-spec-added.json out3.json \
                  --prev out1.json --lock $fx/flake.lock 2> /dev/null
                for pinned in tokyonight.nvim custom.nvim; do
                  diff -u \
                    <(jq -S --arg n "$pinned" '.plugins[$n]' out1.json) \
                    <(jq -S --arg n "$pinned" '.plugins[$n]' out3.json)
                done
                # a plugin with no previous decision starts out unresolved
                jq -e '.plugins["nvim-cmp"].resolvedRef == null' out3.json > /dev/null
                # ...and the newcomer is itself pinned, with no node in flake.lock -- the state
                # every pin is in on its first lock. Even on the pass that would freeze it (it is
                # in --prev now, and its spec has not moved) there is no rev to freeze onto, so
                # the freeze must quietly leave it null instead of failing or inventing one.
                nvim -l $lua/resolve.lua $fx/raw-spec-added.json out3b.json \
                  --prev out3.json --lock $fx/flake.lock 2> /dev/null
                jq -e '.plugins["nvim-cmp"].pin == true' out3b.json > /dev/null
                jq -e '.plugins["nvim-cmp"].resolvedRef == null' out3b.json > /dev/null

                # "Removing a plugin from the config removes it from plugins.json and the
                # generated flake." Nothing else may move: back to base is back to out1 byte for byte.
                nvim -l $lua/resolve.lua $fx/raw-spec-base.json out4.json \
                  --prev out3.json --lock $fx/flake.lock 2> /dev/null
                cmp out1.json out4.json
                nvim -l $lua/genflake.lua out3.json flake-added.nix
                nvim -l $lua/genflake.lua out4.json flake-base.nix
                grep -q 'nvim-cmp = {' flake-added.nix
                if grep -q 'nvim-cmp' flake-base.nix; then
                  echo "the removed plugin is still an input of the generated flake" >&2
                  exit 1
                fi
                # and the frozen rev must actually reach the URL, for both source types --
                # otherwise a bare `nix flake update` in lockDir would walk a pin forward
                grep -q 'url = "github:folke/tokyonight.nvim/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";' flake-base.nix
                grep -q 'url = "git+https://git.example.com/custom.nvim.git?ref=trunk&rev=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";' flake-base.nix

                # Editing the spec beats the pin: the user asked for another branch, so the frozen
                # rev is dropped. Editing metadata that cannot influence a ref (dependencies) does
                # not, or every such edit would silently unpin a plugin.
                nvim -l $lua/resolve.lua $fx/raw-spec-branch-changed.json out5.json \
                  --prev out1.json --lock $fx/flake.lock 2> /dev/null
                jq -e '.plugins["tokyonight.nvim"].resolvedRef == null' out5.json > /dev/null
                jq -e '.plugins["tokyonight.nvim"].branch == "master"' out5.json > /dev/null
                jq -e '.plugins["custom.nvim"].resolvedRef
                       == "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"' out5.json > /dev/null
                jq -e '.plugins["custom.nvim"].dependencies == ["plenary.nvim"]' out5.json > /dev/null
                jq -e '.plugins["telescope.nvim"].dependencies == ["plenary.nvim"]' out5.json > /dev/null

                # Taking `pin` away must thaw the plugin. Nothing else in the spec changes here
                # (jq deletes exactly the one key), so without this the frozen rev would ride
                # along on the unchanged-identity path forever -- and since the rev is part of the
                # input URL, not even `nix flake update` could break it out again.
                jq 'del(.plugins["tokyonight.nvim"].pin)' $fx/raw-spec-base.json > raw-spec-unpinned.json
                nvim -l $lua/resolve.lua raw-spec-unpinned.json out8.json \
                  --prev out1.json --lock $fx/flake.lock 2> /dev/null
                jq -e '.plugins["tokyonight.nvim"].pin == null' out8.json > /dev/null
                jq -e '.plugins["tokyonight.nvim"].resolvedRef == null' out8.json > /dev/null
                # only the unpinned one thaws; the plugin that is still pinned keeps its rev
                jq -e '.plugins["custom.nvim"].resolvedRef
                       == "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"' out8.json > /dev/null

                # `pin` + `version` is a trap: the pin freezes whatever rev the lock holds and
                # nothing ever checks it against the range, so it has to say so -- and say it on
                # both passes, because nvimx-lock keeps only the second one's log.
                jq '.plugins["tokyonight.nvim"].version = "^1.0"' $fx/raw-spec-base.json > raw-spec-pinned-version.json
                nvim -l $lua/resolve.lua raw-spec-pinned-version.json out9a.json \
                  --lock $fx/flake.lock 2> out9a.log
                nvim -l $lua/resolve.lua raw-spec-pinned-version.json out9b.json \
                  --prev out9a.json --lock $fx/flake.lock 2> out9b.log
                # the freeze really did happen between the two passes...
                jq -e '.plugins["tokyonight.nvim"].resolvedRef == null' out9a.json > /dev/null
                jq -e '.plugins["tokyonight.nvim"].resolvedRef
                       == "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"' out9b.json > /dev/null
                # ...and it did not silence the constraint on the way through, on either stream
                for f in out9a out9b; do
                  grep -q '^\[nvimx\] warning: plugin "tokyonight.nvim": pinned; version constraint "\^1.0" is not validated (pin wins)$' $f.log
                  jq -e '.warnings | any(. == "plugin \"tokyonight.nvim\": pinned; version constraint \"^1.0\" is not validated (pin wins)")' $f.json > /dev/null
                done
                # both passes say exactly the same thing, which is what makes overwriting the
                # first pass's log in nvimx-lock safe
                diff -u out9a.log out9b.log

                # A plugins.json written before these fields existed must still be readable, and
                # the decision it records must win over the rev in flake.lock (a resolvedRef that
                # is already set is never recomputed -- that is the whole point of the merge).
                nvim -l $lua/resolve.lua $fx/raw-spec-base.json out6.json \
                  --prev $fx/prev-v1.json --lock $fx/flake.lock 2> /dev/null
                jq -e '.plugins["tokyonight.nvim"].resolvedRef
                       == "1111111111111111111111111111111111111111"' out6.json > /dev/null
                jq -e '.plugins["tokyonight.nvim"].pin == true' out6.json > /dev/null
                jq -e '.plugins["tokyonight.nvim"].dependencies == []' out6.json > /dev/null
                # not in the old prev at all, so there is nothing to trust yet
                jq -e '.plugins["custom.nvim"].resolvedRef == null' out6.json > /dev/null

                # An unresolved version constraint is the one thing #18 leaves to #23, so it warns
                # -- but only while it is still unresolved. Once a ref is on record the merge keeps
                # it and the warning has to go, or every lock would nag about a settled constraint.
                jq '.plugins["telescope.nvim"].resolvedRef = "refs/tags/0.1.8"' out1.json > resolved-prev.json
                nvim -l $lua/resolve.lua $fx/raw-spec-base.json out7.json \
                  --prev resolved-prev.json --lock $fx/flake.lock 2> resolved.log
                jq -e '.plugins["telescope.nvim"].resolvedRef == "refs/tags/0.1.8"' out7.json > /dev/null
                jq -e '.warnings == []' out7.json > /dev/null
                if [ -s resolved.log ]; then
                  echo "a resolved version constraint must not warn, got:" >&2
                  cat resolved.log >&2
                  exit 1
                fi
                grep -q 'version constraint "\^0.1" is not resolved yet' out1.log

                # A prev nvimx cannot read must stop the run. Regenerating from scratch instead
                # would quietly throw away every pinned rev in it, so say what to do and fail.
                for bad in prev-broken prev-future; do
                  rc=0
                  nvim -l $lua/resolve.lua $fx/raw-spec-base.json bad.json --prev $fx/$bad.json \
                    2> $bad.log || rc=$?
                  cat $bad.log >&2
                  if [ "$rc" -eq 0 ]; then
                    echo "resolve.lua silently accepted $bad.json" >&2
                    exit 1
                  fi
                  grep -q 'run nvimx-lock again' $bad.log
                done
                grep -q 'is not valid JSON' prev-broken.log
                grep -q 'schemaVersion 2' prev-future.log

                # Everything above starts from a hand-written raw-spec, so one case goes through
                # the real extractor to prove pin / dependencies / version survive lazy's
                # normalization too.
                sb=$TMPDIR/sandbox
                mkdir -p $sb/config $sb/data/nvim/lazy $sb/state $sb/cache
                ln -s ${./tests/fixtures/merge-config} $sb/config/nvim
                ln -s ${lazy-nvim} $sb/data/nvim/lazy/lazy.nvim
                env \
                  XDG_CONFIG_HOME=$sb/config \
                  XDG_DATA_HOME=$sb/data \
                  XDG_STATE_HOME=$sb/state \
                  XDG_CACHE_HOME=$sb/cache \
                  NVIMX_LAZY_SEED=${lazy-nvim} \
                  NVIMX_OUT=$sb/raw-spec.json \
                  nvim --headless --cmd "luafile ${./lua/nvimx/extract.lua}"
                # guards against dump_plugin in extract.lua reintroducing `optional`: a plugins.json
                # regression alone would not catch this, since resolve.lua's entry construction does
                # not propagate unlisted raw-spec keys.
                # This is vacuous unless merge-config keeps a plugin whose `optional` folds to false
                # rather than nil -- lazy's own encoder drops nil keys, so a spec without the
                # plenary optional fragment would leave nothing for this to find.
                jq -e 'all(.plugins[]; has("optional") | not)' $sb/raw-spec.json > /dev/null
                nvim -l $lua/resolve.lua $sb/raw-spec.json extracted.json 2> /dev/null
                jq -e '.plugins["tokyonight.nvim"].pin == true' extracted.json > /dev/null
                jq -e '.plugins["telescope.nvim"].version == "^0.1"' extracted.json > /dev/null
                jq -e '.plugins["telescope.nvim"].dependencies == ["plenary.nvim"]' extracted.json > /dev/null
                # ...and stay absent when the spec does not set them. `optional` is not among
                # them: it is not a field that stays absent, it never exists in the schema at all.
                jq -e '.plugins["plenary.nvim"].pin == null' extracted.json > /dev/null
                jq -e '.plugins["plenary.nvim"].dependencies == []' extracted.json > /dev/null
                # guards against resolve.lua's entry construction reintroducing `optional`
                jq -e 'all(.plugins[]; has("optional") | not)' extracted.json > /dev/null
                # optional-only: lazy's Meta:fix_optional drops it, so nvimx must not lock it either
                jq -e '.plugins | has("which-key.nvim") | not' extracted.json > /dev/null
                # an optional fragment mixed with a non-optional one still gets locked
                jq -e '.plugins | has("plenary.nvim")' extracted.json > /dev/null
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
