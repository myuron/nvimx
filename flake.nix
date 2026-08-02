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
        let
          pkgs = pkgsFor system;
          nvimxLib = nvimxLibFor system;
          # An upstream blink.cmp tree for checks.build-registry / checks.plugins-escape-hatch,
          # pinned here rather than taken from pkgs.vimPlugins.blink-cmp.src. The entry reads the
          # plugin's Cargo.lock *at evaluation time*, so handing it a derivation would make both
          # checks import-from-derivation: `nix flake check` would then need IFD enabled, and the
          # `tryEval` in plugins-escape-hatch could no longer report its own failure (an IFD build
          # error is not catchable). A fetchTree is already a store path at eval, so neither
          # applies. Real srcs reach the entry the same way -- nix/lib/sources.nix fetchTree's the
          # flake inputs -- so this is also the shape users actually get.
          # rev = v1.10.2; the narHash is the one nixpkgs records for the same tree.
          blinkSrc = builtins.fetchTree {
            type = "github";
            owner = "Saghen";
            repo = "blink.cmp";
            rev = "78336bc89ee5365633bcf754d93df01678b5c08f";
            narHash = "sha256-C1FpyGw0f35NdHvDUGPXxmKdOgw3SpIteK1gAjVy6Ns=";
          };
          # A git repo usable as a `version` constraint's remote with no network at all (#23),
          # shared by checks.resolve-semver and checks.extractor-defaults-version. `git+file://`
          # (not a bare path) is what nix's flake ref parser accepts for a local remote, so any
          # caller building a flake input URL from one of these repos has to add that prefix
          # itself -- genflake.lua already does, since it prepends "git+" to every git-type source.
          # Tags are annotated (`tag -a`) so the same repo exercises both the `--refs` filtering
          # and nix's own peeling of an annotated tag to its commit (see the plan's §1.3).
          mkTagRepoSh = ''
            # mkrepo <dir> [tag...]
            mkrepo() {
              local d="$1"
              shift
              mkdir -p "$d"
              git init -q -b main "$d"
              git -C "$d" -c user.name=nvimx -c user.email=nvimx@example.com commit -q --allow-empty -m init
              for t in "$@"; do
                git -C "$d" -c user.name=nvimx -c user.email=nvimx@example.com tag -a "$t" -m "$t"
              done
            }
          '';
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
          # devPlugins / devPath set through the module, all the way to a build: this is the only
          # check that actually builds the wrapper and the generated bootstrap.lua with a
          # non-empty devDirs against a real lock. checks.dev-plugins' moduleDevDirs also goes
          # through the module, but only reads back .config.programs.nvimx.env.devDirs and never
          # builds anything. Uses the same basic-config lock hm-module already builds, so it adds
          # no fetch of its own.
          hm-module-dev = mkHmCheck {
            configDir = ./tests/fixtures/basic-config;
            lockDir = ./tests/fixtures/basic-config/nvimx-lock;
            devPlugins = [ "tokyonight.nvim" ];
            devPath = "~/projects";
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
              # Two shell steps, ordered: step 2 only appends if step 1's file is already there, so
              # a mis-ordered or dropped step fails the build (its `&&` list ends non-zero, which
              # the subshell propagates), and the assert below pins the contents either way.
              # The `&&` shape is deliberate -- it is exactly what a trailing no-op inside the
              # subshell would swallow, so this case also guards how that subshell is written.
              orderedSteps = mkLocal {
                kind = "steps";
                steps = [
                  {
                    kind = "shell";
                    cmd = "mkdir -p build && echo one > build/order.txt";
                  }
                  {
                    kind = "shell";
                    cmd = "test -f build/order.txt && echo two >> build/order.txt";
                  }
                ];
              };
              # A mix of runnable and unrunnable steps. Step 1's `cd lua` must not leak into step
              # 3's `make` (which needs to run at the plugin root to find the Makefile) or into
              # installPhase (#45) -- and the skipped excmd step must not break the steps after it.
              mixedSteps = mkLocal {
                kind = "steps";
                steps = [
                  {
                    kind = "shell";
                    cmd = "cd lua && touch inner";
                  }
                  {
                    kind = "excmd";
                    cmd = ":TSUpdate";
                  }
                  {
                    kind = "shell";
                    cmd = "make";
                  }
                ];
              };
              # No step in this list can run at build time, so this must behave exactly like
              # kind = "none": no build/ directory, helptags only.
              allUnrunnableSteps = mkLocal {
                kind = "steps";
                steps = [
                  {
                    kind = "excmd";
                    cmd = ":Foo";
                  }
                  { kind = "function"; }
                ];
              };
              # The #45 regression: a scalar build that `cd`s must not leak that directory into
              # installPhase. Before the fix this produced a $out containing only lua/'s contents
              # (Makefile, doc/ and the marker's siblings all gone).
              cwdLeak = mkLocal {
                kind = "shell";
                cmd = "cd lua && touch marker";
              };
            in
            pkgs.runCommand "plugin-drv-phases" { } ''
              # only kind == "shell" / "steps" (with a shell step in it) runs a build
              test -f ${shell}/build/artifact.txt
              test ! -e ${excmd}/build
              test ! -e ${none}/build

              for p in ${shell} ${excmd} ${none} ${orderedSteps} ${mixedSteps} ${allUnrunnableSteps} ${cwdLeak}; do
                # helptags are generated for every kind
                test -f "$p/doc/tags"
                # doc/ must stay at the plugin root: stdenv's move-docs hook would relocate it
                # to share/doc/ and break :h
                test ! -e "$p/share"
                # upstream files must survive verbatim: patchShebangs rewrites this line into
                # `env -S  -l`, dropping the interpreter
                grep -qF '#!/usr/bin/env -S nvim -l' "$p/scripts/run"
              done

              # steps run in declared order: step 2 could only have appended if step 1 already ran
              test "$(cat ${orderedSteps}/build/order.txt)" = "$(printf 'one\ntwo\n')"

              # mixed: the shell steps ran (at the plugin root, not inside lua/) and the excmd
              # step in between was skipped without breaking the shell step after it
              test -f ${mixedSteps}/lua/inner
              test -f ${mixedSteps}/build/artifact.txt

              # all steps unrunnable: no build ran at all
              test ! -e ${allUnrunnableSteps}/build

              # #45: a `cd` inside one build step/subshell must not survive into installPhase --
              # the whole tree (not just lua/) must still reach $out
              test -f ${cwdLeak}/lua/marker
              test -f ${cwdLeak}/Makefile
              test -f ${cwdLeak}/doc/tags

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
              # Detection has to apply to every shell step of a "steps" build, not just a scalar
              # one (#36): a network step anywhere in the list must throw, and an all-offline
              # "steps" build must not be caught by mistake.
              evaluatesSteps =
                steps:
                (builtins.tryEval (
                  builtins.seq
                    (mkPluginDrv {
                      name = "demo.nvim";
                      src = ./tests/fixtures/empty-config;
                      build = {
                        kind = "steps";
                        inherit steps;
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
                ++ lib.optional (!evaluates "make") "mkPluginDrv threw for an offline build"
                ++ lib.optional (evaluatesSteps [
                  {
                    kind = "shell";
                    cmd = "make";
                  }
                  {
                    kind = "shell";
                    cmd = "cargo build --release";
                  }
                ]) "mkPluginDrv did not throw for a network step inside a \"steps\" build"
                ++ lib.optional (
                  !evaluatesSteps [
                    {
                      kind = "shell";
                      cmd = "make";
                    }
                    {
                      kind = "excmd";
                      cmd = ":TSUpdate";
                    }
                  ]
                ) "mkPluginDrv threw for an all-offline \"steps\" build";
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
              # nvim-treesitter: the entry must ignore whatever build the spec declared, even one
              # that would fail if it ran -- proof that this plugin never reaches the generic
              # build's buildPhase at all (#36's decision on nvim-treesitter's own `make`, which
              # is unrunnable in the sandbox on the `main` branch layout).
              treesitterEntry = nvimxLib.resolvePlugin {
                name = "nvim-treesitter";
                src = ./tests/fixtures/local-plugin;
                build = {
                  kind = "shell";
                  cmd = "exit 1";
                };
              };
              # blink.cmp: the one entry that has to *produce* a compiled artifact from the
              # locked src, so it is resolved against a real upstream tree (blinkSrc above) and
              # actually built. The declared build is the one build-network.nix rejects, which is
              # what the entry is rescuing.
              blinkEntry = nvimxLib.resolvePlugin {
                name = "blink.cmp";
                src = blinkSrc;
                build = {
                  kind = "shell";
                  cmd = "cargo build --release";
                };
              };
              blinkLib = "libblink_cmp_fuzzy${pkgs.stdenv.hostPlatform.extensions.sharedLibrary}";
              # Both refusals the entry can raise before it builds anything. They are the entry's
              # documented behaviour for a rev it cannot handle, so they have to keep being
              # refusals rather than silently becoming a plain (and doomed) build.
              blinkRefuses =
                src:
                !(builtins.tryEval (
                  builtins.seq
                    (nvimxLib.resolvePlugin {
                      name = "blink.cmp";
                      inherit src;
                      build = {
                        kind = "none";
                      };
                    }).drvPath
                    null
                )).success;
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
                ) "an override's defaultDrv should be the registry entry's result"
                # local-plugin has no Cargo.lock, so it stands in for a fork or a namesake
                ++ lib.optional (
                  !(blinkRefuses ./tests/fixtures/local-plugin)
                ) "blink.cmp without a Cargo.lock should be refused, not built"
                ++ lib.optional (
                  !(blinkRefuses ./tests/fixtures/cargo-git-lock)
                ) "blink.cmp with a git dependency in Cargo.lock should be refused, not built";
            in
            pkgs.runCommand "build-registry" { nativeBuildInputs = [ pkgs.neovim-unwrapped ]; } (
              if failures == [ ] then
                ''
                  # the spec declares no build, so only the registry can have produced this
                  test -f ${env.farm}/telescope-fzf-native.nvim/build/libfzf.so
                  # ... and here the entry stands in for a binary the sandbox cannot download,
                  # without disturbing what upstream already ships next to it
                  test -x ${fzf}/bin/fzf
                  test -f ${fzf}/bin/fzf-tmux
                  test -f ${fzf}/plugin/fzf.vim
                  # the declared build ("exit 1") never ran -- the entry replaced it with copy +
                  # helptags, so this only exists if the fixture's src reached $out untouched
                  test -f ${treesitterEntry}/lua/local-plugin.lua
                  test -f ${treesitterEntry}/doc/tags
                  # blink.cmp: the library, built offline where the loader looks for it ...
                  test -f ${blinkEntry}/target/release/${blinkLib}
                  test -f ${blinkEntry}/lua/blink/cmp/fuzzy/rust/init.lua
                  # ... and *no* version file beside it, which is what keeps blink from deciding
                  # at every startup that the locally built library is out of date
                  test ! -e ${blinkEntry}/target/release/version
                  # the promise is a runtime one, and it is blink's own decision procedure that
                  # has to come out right -- not just "the file is there" -- so ask it
                  export HOME=$TMPDIR
                  cat > blink.lua <<'LUA'
                  local done, result
                  require('blink.cmp.fuzzy.download').ensure_downloaded(function(err, impl)
                    done, result = true, { err = err, impl = impl }
                  end)
                  assert(vim.wait(30000, function() return done end), 'ensure_downloaded never returned')
                  assert(result.err == nil, 'ensure_downloaded failed: ' .. tostring(result.err))
                  assert(result.impl == 'rust', 'blink.cmp did not pick the rust matcher: ' .. tostring(result.impl))
                  LUA
                  nvim --clean --cmd 'set rtp+=${blinkEntry}' -l blink.lua
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
                ) "nix/build-registry did not rescue a build needing the network"
                # ... so "blink.cmp" carries the other half: its `cargo build --release` is
                # caught by build-network.nix, and the entry has to keep the throw from being
                # reached. It needs a src with a Cargo.lock, since the entry reads one; only
                # drvPath is forced, so the library itself is not compiled here
                ++ lib.optional (
                  !(evaluates "blink.cmp" { src = blinkSrc; })
                ) "nix/build-registry did not rescue blink.cmp's cargo build";
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
          # Pure unit test of lua/nvimx/version.lua (#23): no git, no jq, no network, and no
          # fixture files -- tests/semver-select-test.lua carries its own fixed tag sets inline.
          # Drives the real lua/lazy/manage/semver.lua from the seed, the same way resolve.lua
          # does, so a change in lazy's own semver behavior shows up here (like extractor-snapshot
          # does for the extractor).
          semver-select =
            pkgs.runCommand "semver-select"
              {
                nativeBuildInputs = [ pkgs.neovim-unwrapped ];
              }
              ''
                nvim -l ${./tests/semver-select-test.lua} ${./lua/nvimx/version.lua} \
                  ${lazy-nvim}/lua/lazy/manage/semver.lua
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
                  pkgs.git
                ];
              }
              (
                mkTagRepoSh
                + ''
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

                  # `versionFromDefaults` (#23): present, and true, exactly on the plugins whose
                  # version came from `defaults.version` -- not on ones with their own `version`
                  # (telescope.nvim), and not on ones the default never reaches at all.
                  jq -e '.plugins["tokyonight.nvim"].versionFromDefaults == true' $sb/defaults.json > /dev/null
                  jq -e '.plugins["plenary.nvim"].versionFromDefaults == true' $sb/defaults.json > /dev/null
                  jq -e '.plugins["telescope.nvim"] | has("versionFromDefaults") | not' $sb/defaults.json > /dev/null
                  jq -e '.plugins["trouble.nvim"] | has("versionFromDefaults") | not' $sb/defaults.json > /dev/null
                  jq -e '.plugins["which-key.nvim"] | has("versionFromDefaults") | not' $sb/defaults.json > /dev/null
                  jq -e '.plugins["flash.nvim"] | has("versionFromDefaults") | not' $sb/defaults.json > /dev/null
                  jq -e '.plugins["noice.nvim"] | has("versionFromDefaults") | not' $sb/defaults.json > /dev/null

                  # plugins.json: the issue's "Done when" is about the lock, so resolve it too.
                  # A real ls-remote needs a real remote, and the sandbox has no network at all, so
                  # the three plugins that reach ls-remote are pointed at local git repos instead
                  # (the same offline approach checks.resolve-semver uses for its own coverage).
                  # plugins whose version never reaches the gate at all (trouble/which-key/flash/
                  # noice, via branch/tag/commit/false respectively) are untouched: if the gate ever
                  # regressed to let one of them through, ls-remote against their real (github) urls
                  # would fail here with no network, and the check would fail loudly instead of
                  # silently doing the wrong thing.
                  mkrepo $sb/tagged v1.0.0 v2.0.0
                  mkrepo $sb/untagged
                  mkrepo $sb/telescope 0.1.5 0.1.8
                  jq \
                    --arg tagged "file://$sb/tagged" \
                    --arg untagged "file://$sb/untagged" \
                    --arg telescope "file://$sb/telescope" \
                    '.plugins["plenary.nvim"].url = $tagged
                     | .plugins["tokyonight.nvim"].url = $untagged
                     | .plugins["telescope.nvim"].url = $telescope' \
                    $sb/defaults.json > $sb/defaults-online.json
                  nvim -l ${./lua/nvimx}/resolve.lua $sb/defaults-online.json plugins.json \
                    --lazy ${lazy-nvim} 2> resolve.log
                  cat resolve.log >&2

                  jq -e '.plugins["tokyonight.nvim"].version == "*"' plugins.json > /dev/null
                  # no tags on tokyonight.nvim's remote: a defaults-derived constraint falls back to
                  # HEAD rather than failing the lock (#42's goal 1, the reason this check exists,
                  # verified again now that #23 could have broken it)
                  jq -e '.plugins["tokyonight.nvim"].resolvedRef == null' plugins.json > /dev/null
                  jq -e '.plugins["plenary.nvim"].version == "*"' plugins.json > /dev/null
                  jq -e '.plugins["plenary.nvim"].resolvedRef == "refs/tags/v2.0.0"' plugins.json > /dev/null
                  jq -e '.plugins["telescope.nvim"].version == "^0.1"' plugins.json > /dev/null
                  jq -e '.plugins["telescope.nvim"].resolvedRef == "refs/tags/0.1.8"' plugins.json > /dev/null
                  jq -e '.plugins["noice.nvim"].version == null' plugins.json > /dev/null
                  jq -e '.plugins["trouble.nvim"].version == null' plugins.json > /dev/null
                  jq -e '.plugins["which-key.nvim"].version == null' plugins.json > /dev/null
                  jq -e '.plugins["flash.nvim"].version == null' plugins.json > /dev/null
                  jq -e '[.plugins[] | select(.version != null)] | length == 3' plugins.json > /dev/null
                  # the fallback must not show up as a per-plugin warning in the lock (§3.4.5 of the
                  # #23 plan) -- only as the aggregated stderr line checked below
                  jq -e '.warnings == []' plugins.json > /dev/null
                  grep -q 'follow the default branch' resolve.log

                  # defaults.version = false must be indistinguishable from "unset" (#42 goal 3)
                  extract ${./tests/fixtures/defaults-version-false-config} $sb/false.json
                  jq -e '.plugins["tokyonight.nvim"] | has("version") | not' $sb/false.json > /dev/null
                  jq -e '.plugins["telescope.nvim"].version == "^0.1"' $sb/false.json > /dev/null

                  touch $out
                ''
              );
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
                  --lazy ${lazy-nvim} 2> stderr.log || rc=$?
                cat stderr.log >&2
                if [ "$rc" -ne 0 ]; then
                  echo "resolve.lua must warn, not fail: got rc=$rc" >&2
                  exit 1
                fi

                # one warning per plugin, each naming the shape of the build it cannot run.
                # LuaSnip's list build moved to build-steps-config (#36): it is now all-shell and
                # builds silently, so this fixture only covers the two shapes nothing can run at
                # all (verbatim strings, pinned so a rewording of the scalar path is noticed).
                grep -q '^\[nvimx\] warning: plugin "nvim-treesitter": build is a neovim command (":TSUpdate")' stderr.log
                grep -q '^\[nvimx\] warning: plugin "markdown-preview.nvim": build is a Lua function ("<function>")' stderr.log
                n=$(grep -c '^\[nvimx\] warning: plugin ' stderr.log)
                if [ "$n" -ne 2 ]; then
                  echo "expected exactly 2 plugin warnings, got $n" >&2
                  exit 1
                fi

                # every escape hatch is named, plus the treesitter-specific pointer
                grep -q 'plugins.overrides' stderr.log
                grep -q 'plugins.nixpkgsFallback' stderr.log
                grep -q 'nix/build-registry/' stderr.log
                grep -q 'programs.nvimx.treesitter.grammars' stderr.log

                # the same warnings are recorded in the lock, sorted by plugin name so that
                # re-locking does not reshuffle the array
                jq -e '.warnings | length == 2' plugins.json > /dev/null
                jq -e '.warnings[0] | startswith("plugin \"markdown-preview.nvim\"")' plugins.json > /dev/null
                jq -e '.warnings[1] | startswith("plugin \"nvim-treesitter\"")' plugins.json > /dev/null
                # the "<function>" placeholder must not leak into build.cmd
                jq -e '.plugins["markdown-preview.nvim"].build == { kind: "function" }' plugins.json > /dev/null
                jq -e '.plugins["nvim-treesitter"].build.cmd == ":TSUpdate"' plugins.json > /dev/null

                # ...and the quiet path: a build nvimx *can* run must say nothing at all.
                # Without this, warning about every build would pass every assertion above.
                extract ${./tests/fixtures/build-plugins} $sb/buildable.json
                nvim -l ${./lua/nvimx}/resolve.lua $sb/buildable.json quiet.json --lazy ${lazy-nvim} 2> quiet.log
                if [ -s quiet.log ]; then
                  echo "a shell build must not warn, got:" >&2
                  cat quiet.log >&2
                  exit 1
                fi
                jq -e '.warnings == []' quiet.json > /dev/null

                # Table-form build (#36): every element is classified and none are lost, the
                # mixed case warns with the step index and the treesitter pointer, the all-shell
                # case is silent, and rockspec/luafile/false get their own kind rather than being
                # run as shell commands (the regression #36's classifier could introduce, #3.4).
                extract ${./tests/fixtures/build-steps-config} $sb/steps.json
                rc=0
                nvim -l ${./lua/nvimx}/resolve.lua $sb/steps.json steps-plugins.json \
                  --lazy ${lazy-nvim} 2> steps.log || rc=$?
                cat steps.log >&2
                if [ "$rc" -ne 0 ]; then
                  echo "resolve.lua must warn, not fail, on table-form builds: got rc=$rc" >&2
                  exit 1
                fi

                # mixed table: no step lost, order preserved, and it counts as unbuildable
                jq -e '.plugins["nvim-treesitter"].build.kind == "steps"' steps-plugins.json > /dev/null
                jq -e '.plugins["nvim-treesitter"].build.steps | length == 2' steps-plugins.json > /dev/null
                jq -e '.plugins["nvim-treesitter"].build.steps[0] == { kind: "shell", cmd: "make" }' \
                  steps-plugins.json > /dev/null
                jq -e '.plugins["nvim-treesitter"].build.steps[1] == { kind: "excmd", cmd: ":TSUpdate" }' \
                  steps-plugins.json > /dev/null
                grep -q 'plugin "nvim-treesitter": build is a list of 2 steps and 1 of them cannot be run at build time' \
                  steps.log
                grep -q 'step 2 is a neovim command (":TSUpdate")' steps.log
                grep -q 'the remaining shell step still runs' steps.log
                grep -q 'programs.nvimx.treesitter.grammars' steps.log

                # all-shell table: silent, and not folded into a scalar shell build
                jq -e '.plugins["LuaSnip"].build.kind == "steps"' steps-plugins.json > /dev/null
                jq -e '.plugins["LuaSnip"].build.steps[0] == { kind: "shell", cmd: "make install_jsregexp" }' \
                  steps-plugins.json > /dev/null
                if grep -q 'plugin "LuaSnip"' steps.log; then
                  echo "an all-shell table build must not warn" >&2
                  exit 1
                fi

                # all-unrunnable table: 2 of 2, both clauses present
                jq -e '.plugins["all-unbuildable.nvim"].build.kind == "steps"' steps-plugins.json > /dev/null
                grep -q 'plugin "all-unbuildable.nvim": build is a list of 2 steps and 2 of them cannot be run at build time' \
                  steps.log
                grep -q 'step 1 is a Lua function' steps.log
                grep -q 'step 2 is a neovim command (":Foo")' steps.log

                # false: no false-positive warning (pre-#36 regression: "<boolean>" used to warn)
                jq -e '.plugins["no-build.nvim"].build == { kind: "none" }' steps-plugins.json > /dev/null
                if grep -q 'plugin "no-build.nvim"' steps.log; then
                  echo "build = false must not warn" >&2
                  exit 1
                fi

                # rockspec / luafile: their own kind, never "shell" (pre-#36 regression: these
                # used to be recorded as shell.cmd and executed as such)
                jq -e '.plugins["rockspec-build.nvim"].build == { kind: "rockspec" }' steps-plugins.json > /dev/null
                jq -e '.plugins["luafile-build.nvim"].build == { kind: "luafile", cmd: "install.lua" }' \
                  steps-plugins.json > /dev/null
                grep -q 'plugin "rockspec-build.nvim"' steps.log
                grep -q 'plugin "luafile-build.nvim"' steps.log

                # The warnings also have to reach plugins.json, one per plugin and sorted by name,
                # or the committed lock would churn on every run. `false` and the all-shell LuaSnip
                # are the quiet paths and must not appear.
                jq -e '.warnings | length == 4' steps-plugins.json > /dev/null
                jq -e '.warnings[0] | startswith("plugin \"all-unbuildable.nvim\"")' steps-plugins.json > /dev/null
                jq -e '.warnings[1] | startswith("plugin \"luafile-build.nvim\"")' steps-plugins.json > /dev/null
                jq -e '.warnings[2] | startswith("plugin \"nvim-treesitter\"")' steps-plugins.json > /dev/null
                jq -e '.warnings[3] | startswith("plugin \"rockspec-build.nvim\"")' steps-plugins.json > /dev/null

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
                # None of the resolves below end up with anything pending (telescope.nvim, the
                # only plugin here with a `version`, does not have one anymore -- see its
                # raw-spec's _comment), so --lazy is never actually consulted. It is passed on
                # every call anyway so that this file stays correct if that ever changes.
                lazy=${lazy-nvim}

                # The first resolve of a lock run cannot freeze anything: there is no previous
                # plugins.json to tell whether the flake.lock next to it still describes this spec.
                nvim -l $lua/resolve.lua $fx/raw-spec-base.json pass1.json --lock $fx/flake.lock \
                  --lazy $lazy 2> pass1.log
                jq -e '.plugins["tokyonight.nvim"].resolvedRef == null' pass1.json > /dev/null
                jq -e '.plugins["custom.nvim"].resolvedRef == null' pass1.json > /dev/null

                # The second one -- the pass nvimx-lock runs once `nix flake lock` has caught up --
                # is what freezes them, and is the steady state. golden/base.plugins.json is that
                # state written out for review: pin / dependencies plus both frozen revs.
                nvim -l $lua/resolve.lua $fx/raw-spec-base.json out1.json \
                  --prev pass1.json --lock $fx/flake.lock --lazy $lazy 2> out1.log
                diff -u $fx/golden/base.plugins.json out1.json

                # "Running lock twice with no config change produces a byte-identical plugins.json":
                # the steady state has to be a fixed point, or the convergence pass would never end.
                nvim -l $lua/resolve.lua $fx/raw-spec-base.json out2.json \
                  --prev out1.json --lock $fx/flake.lock --lazy $lazy 2> out2.log
                cmp out1.json out2.json
                # warnings are derived every run and never merged, so they repeat verbatim
                diff -u out1.log out2.log

                # "A pinned plugin keeps its ref after an unrelated plugin is added."
                nvim -l $lua/resolve.lua $fx/raw-spec-added.json out3.json \
                  --prev out1.json --lock $fx/flake.lock --lazy $lazy 2> /dev/null
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
                  --prev out3.json --lock $fx/flake.lock --lazy $lazy 2> /dev/null
                jq -e '.plugins["nvim-cmp"].pin == true' out3b.json > /dev/null
                jq -e '.plugins["nvim-cmp"].resolvedRef == null' out3b.json > /dev/null

                # "Removing a plugin from the config removes it from plugins.json and the
                # generated flake." Nothing else may move: back to base is back to out1 byte for byte.
                nvim -l $lua/resolve.lua $fx/raw-spec-base.json out4.json \
                  --prev out3.json --lock $fx/flake.lock --lazy $lazy 2> /dev/null
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
                  --prev out1.json --lock $fx/flake.lock --lazy $lazy 2> /dev/null
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
                  --prev out1.json --lock $fx/flake.lock --lazy $lazy 2> /dev/null
                jq -e '.plugins["tokyonight.nvim"].pin == null' out8.json > /dev/null
                jq -e '.plugins["tokyonight.nvim"].resolvedRef == null' out8.json > /dev/null
                # only the unpinned one thaws; the plugin that is still pinned keeps its rev
                jq -e '.plugins["custom.nvim"].resolvedRef
                       == "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"' out8.json > /dev/null

                # `pin` + `version` is a trap: the pin freezes whatever rev the lock holds and
                # nothing ever checks it against the range, so it has to say so -- and say it on
                # both passes, because nvimx-lock keeps only the second one's log. Both passes are
                # given a prev that already carries the constraint with resolvedRef null (the
                # state a lock made just before #23 landed would be in), so the freeze wins over
                # the constraint on both passes, and no ls-remote is attempted on either one --
                # the pin+version interaction with an actual first-ever resolve (no prev at all)
                # is checks.resolve-semver step 13(b)'s job, since that one does need a real (if
                # local) remote to prove ls-remote really is skipped.
                jq '.plugins["tokyonight.nvim"].version = "^1.0"' $fx/raw-spec-base.json > raw-spec-pinned-version.json
                jq '.plugins["tokyonight.nvim"].version = "^1.0" | .plugins["tokyonight.nvim"].resolvedRef = null' \
                  $fx/golden/base.plugins.json > prev-pinned-version.json
                nvim -l $lua/resolve.lua raw-spec-pinned-version.json out9a.json \
                  --prev prev-pinned-version.json --lock $fx/flake.lock --lazy $lazy 2> out9a.log
                nvim -l $lua/resolve.lua raw-spec-pinned-version.json out9b.json \
                  --prev out9a.json --lock $fx/flake.lock --lazy $lazy 2> out9b.log
                # the freeze wins over the constraint on both passes
                jq -e '.plugins["tokyonight.nvim"].resolvedRef
                       == "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"' out9a.json > /dev/null
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
                  --prev $fx/prev-v1.json --lock $fx/flake.lock --lazy $lazy 2> /dev/null
                jq -e '.plugins["tokyonight.nvim"].resolvedRef
                       == "1111111111111111111111111111111111111111"' out6.json > /dev/null
                jq -e '.plugins["tokyonight.nvim"].pin == true' out6.json > /dev/null
                jq -e '.plugins["tokyonight.nvim"].dependencies == []' out6.json > /dev/null
                # not in the old prev at all, so there is nothing to trust yet
                jq -e '.plugins["custom.nvim"].resolvedRef == null' out6.json > /dev/null

                # A carried resolvedRef -- whatever put it there -- must not be re-decided or
                # warned about while the spec identity is unchanged. This is deliberately not
                # version-specific (telescope.nvim has no `version` in this fixture): the point is
                # that the merge carries *any* resolvedRef unconditionally. The semver-specific
                # version of this (a version constraint whose already-resolved tag ref survives a
                # lock with no config change, proven against a real remote so ls-remote's absence
                # is actually checked) is checks.resolve-semver step 5.
                jq '.plugins["telescope.nvim"].resolvedRef = "refs/tags/0.1.8"' out1.json > resolved-prev.json
                nvim -l $lua/resolve.lua $fx/raw-spec-base.json out7.json \
                  --prev resolved-prev.json --lock $fx/flake.lock --lazy $lazy 2> resolved.log
                jq -e '.plugins["telescope.nvim"].resolvedRef == "refs/tags/0.1.8"' out7.json > /dev/null
                jq -e '.warnings == []' out7.json > /dev/null
                if [ -s resolved.log ]; then
                  echo "a carried resolvedRef must not warn, got:" >&2
                  cat resolved.log >&2
                  exit 1
                fi

                # A prev nvimx cannot read must stop the run. Regenerating from scratch instead
                # would quietly throw away every pinned rev in it, so say what to do and fail.
                for bad in prev-broken prev-future; do
                  rc=0
                  nvim -l $lua/resolve.lua $fx/raw-spec-base.json bad.json --prev $fx/$bad.json \
                    --lazy $lazy 2> $bad.log || rc=$?
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
                # extract's own contract: version survives lazy's normalization intact
                jq -e '.plugins["telescope.nvim"].version == "^0.1"' $sb/raw-spec.json > /dev/null
                # Resolving that constraint needs a real remote (checks.resolve-semver step 14
                # already covers it end to end, offline, against a local repo); this check is
                # about pin / dependencies / optional surviving extract -> resolve, not semver, so
                # the constraint is dropped before resolving to keep this check network-free.
                jq 'del(.plugins["telescope.nvim"].version)' $sb/raw-spec.json > $sb/raw-spec-no-version.json
                nvim -l $lua/resolve.lua $sb/raw-spec-no-version.json extracted.json --lazy $lazy 2> /dev/null
                jq -e '.plugins["tokyonight.nvim"].pin == true' extracted.json > /dev/null
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
          # Offline, end-to-end coverage of semver resolution (#23): git ls-remote against local
          # repos this check creates itself, so no network is needed and no fixture ever names a
          # real, reachable remote. Destructive steps (removing a repo to prove a carried ref
          # needs no further network access) are kept last, since several earlier steps still need
          # those repos alive.
          resolve-semver =
            pkgs.runCommand "resolve-semver"
              {
                nativeBuildInputs = [
                  pkgs.neovim-unwrapped
                  pkgs.jq
                  pkgs.git
                ];
              }
              (
                mkTagRepoSh
                + ''
                  export HOME=$TMPDIR
                  lua=${./lua/nvimx}
                  fx=${./tests/fixtures/semver}
                  lazy=${lazy-nvim}
                  sb=$TMPDIR/sandbox

                  # 1. Three remotes: tagged (a real tag set to resolve against), untagged (a real
                  # remote with zero tags -- classification B), and a small one just for the E2E
                  # step's telescope.nvim dependency.
                  mkrepo $sb/tagged v1.0.0 v1.2.0 v1.2.5 v2.0.0 v2.1.0-beta stable
                  mkrepo $sb/untagged
                  mkrepo $sb/telescope 0.1.5 0.1.8

                  # 2. Explicit constraint, success path. gh.nvim has no `version` at all (a github
                  # type plugin), proving the gate does not send it to ls-remote regardless of type.
                  jq --arg u "file://$sb/tagged" \
                    '.plugins["tagged.nvim"].url = $u | .plugins["pinned.nvim"].url = $u' \
                    $fx/raw-spec-explicit.json > explicit.json
                  nvim -l $lua/resolve.lua explicit.json out-explicit.json --lazy $lazy 2> explicit.log
                  if [ -s explicit.log ]; then
                    echo "an explicit constraint that resolves cleanly must not warn, got:" >&2
                    cat explicit.log >&2
                    exit 1
                  fi
                  jq -e '.plugins["tagged.nvim"].resolvedRef == "refs/tags/v1.2.5"' out-explicit.json > /dev/null
                  jq -e '.warnings == []' out-explicit.json > /dev/null
                  jq -e '.plugins["gh.nvim"].source.type == "github"' out-explicit.json > /dev/null
                  jq -e '.plugins["gh.nvim"].version == null' out-explicit.json > /dev/null
                  jq -e '.plugins["gh.nvim"].resolvedRef == null' out-explicit.json > /dev/null
                  # 13(a). pinned.nvim resolves exactly the same way on its first lock, and the
                  # "pin wins" warning does not fire -- the constraint really was validated.
                  jq -e '.plugins["pinned.nvim"].resolvedRef == "refs/tags/v1.2.5"' out-explicit.json > /dev/null

                  # 3. The resolved tag reaches the generated flake's input URL.
                  nvim -l $lua/genflake.lua out-explicit.json flake-explicit.nix
                  grep -q 'ref=refs/tags/v1.2.5' flake-explicit.nix

                  # 4. Editing the constraint re-resolves against the same remote (spec identity
                  # includes `version`; tests/fixtures/merge's coverage of this fact is metadata-only,
                  # this is the semver-constrained case). $sb/tagged must stay alive for this.
                  jq --arg u "file://$sb/tagged" \
                    '.plugins["tagged.nvim"].url = $u | .plugins["pinned.nvim"].url = $u
                     | .plugins["tagged.nvim"].version = "~1.0"' \
                    $fx/raw-spec-explicit.json > step4.json
                  nvim -l $lua/resolve.lua step4.json out-step4.json --prev out-explicit.json --lazy $lazy \
                    2> /dev/null
                  jq -e '.plugins["tagged.nvim"].resolvedRef == "refs/tags/v1.0.0"' out-step4.json > /dev/null

                  # 5. --prev carries an already-resolved tag ref forward with no ls-remote at all --
                  # proven by rewriting it to a value ls-remote could never have produced right now
                  # ("^1.2" no longer resolves to v1.0.0) and checking that value survives untouched.
                  jq '.plugins["tagged.nvim"].resolvedRef = "refs/tags/v1.0.0"' out-explicit.json > prev-step5.json
                  nvim -l $lua/resolve.lua explicit.json out-step5.json --prev prev-step5.json --lazy $lazy \
                    2> /dev/null
                  jq -e '.plugins["tagged.nvim"].resolvedRef == "refs/tags/v1.0.0"' out-step5.json > /dev/null

                  # 6. Classification A: an explicit constraint no tag on a real (if local) remote
                  # satisfies is fatal, with the plugin name, constraint, url and candidate tags.
                  jq --arg u "file://$sb/tagged" \
                    '.plugins["tagged.nvim"].url = $u | .plugins["pinned.nvim"].url = $u
                     | .plugins["tagged.nvim"].version = "^9"' \
                    $fx/raw-spec-explicit.json > step6.json
                  rc=0
                  nvim -l $lua/resolve.lua step6.json out-step6.json --lazy $lazy 2> step6.log || rc=$?
                  if [ "$rc" -eq 0 ]; then
                    echo "an unsatisfiable explicit constraint must fail the lock" >&2
                    exit 1
                  fi
                  [ ! -e out-step6.json ]
                  grep -q 'plugin "tagged.nvim"' step6.log
                  grep -q 'no tag matches version constraint "\^9"' step6.log
                  grep -q 'newest' step6.log

                  # 7. Classification B: an explicit constraint on a remote with no tags at all.
                  jq --arg u "file://$sb/untagged" '.plugins["untagged.nvim"].url = $u' \
                    $fx/raw-spec-explicit-untagged.json > step7.json
                  rc=0
                  nvim -l $lua/resolve.lua step7.json out-step7.json --lazy $lazy 2> step7.log || rc=$?
                  if [ "$rc" -eq 0 ]; then
                    echo "an explicit constraint on a tagless remote must fail the lock" >&2
                    exit 1
                  fi
                  grep -q 'the remote has no tags' step7.log

                  # 8. Classification C: git ls-remote itself fails (bad url), fatal regardless of
                  # where the constraint came from.
                  jq '.plugins["untagged.nvim"].url = "file:///nvimx-nonexistent/step8"' \
                    $fx/raw-spec-explicit-untagged.json > step8.json
                  rc=0
                  nvim -l $lua/resolve.lua step8.json out-step8.json --lazy $lazy 2> step8.log || rc=$?
                  if [ "$rc" -eq 0 ]; then
                    echo "a git ls-remote failure must fail the lock" >&2
                    exit 1
                  fi
                  grep -q 'git ls-remote failed' step8.log

                  # 9. Classification D: a constraint lazy.manage.semver cannot parse must be caught
                  # before ls-remote -- the url is unreachable, so if D were detected after the fetch
                  # this would report classification C's message instead.
                  rc=0
                  nvim -l $lua/resolve.lua $fx/raw-spec-badrange.json out-step9.json --lazy $lazy \
                    2> step9.log || rc=$?
                  if [ "$rc" -eq 0 ]; then
                    echo "an unparseable constraint must fail the lock" >&2
                    exit 1
                  fi
                  grep -q 'not valid lazy.nvim semver syntax' step9.log
                  if grep -q 'git ls-remote failed' step9.log; then
                    echo "classification D must be decided before any network access" >&2
                    exit 1
                  fi

                  # 10. A defaults.version-derived constraint falls back to HEAD instead of failing
                  # the lock, on the very same remotes step 6/7 just proved are fatal for an explicit
                  # constraint -- the contrast is the point (§3.4 of the plan).
                  jq --arg t "file://$sb/tagged" --arg u "file://$sb/untagged" \
                    '.plugins["tagged.nvim"].url = $t | .plugins["untagged.nvim"].url = $u' \
                    $fx/raw-spec-defaults.json > step10.json
                  nvim -l $lua/resolve.lua step10.json out-step10.json --lazy $lazy 2> step10.log
                  jq -e '.plugins["untagged.nvim"].resolvedRef == null' out-step10.json > /dev/null
                  jq -e '.plugins["tagged.nvim"].resolvedRef == "refs/tags/v2.0.0"' out-step10.json > /dev/null
                  jq -e '.warnings == []' out-step10.json > /dev/null
                  grep -q 'follow the default branch' step10.log

                  # 11. The fallback survives a second pass byte-identically, with the same
                  # aggregated report -- this is what makes overwriting nvimx-lock's first-pass log
                  # with the second one safe for a defaults.version fallback, the same way it already
                  # is for a pin (checks.resolve-merge's out9a/out9b).
                  nvim -l $lua/resolve.lua step10.json out-step11.json --prev out-step10.json --lazy $lazy \
                    2> step11.log
                  cmp out-step10.json out-step11.json
                  diff -u step10.log step11.log

                  # 12. The gate: none of `tag` / `commit` / `version = false` may reach ls-remote,
                  # against urls that do not exist -- if the gate regressed, this would fail with
                  # classification C instead of quietly doing the right thing. No --lazy: nothing is
                  # pending, so it must not be required (see step 15).
                  nvim -l $lua/resolve.lua $fx/raw-spec-gate.json out-step12.json 2> step12.log
                  jq -e '.plugins["tag-and-version.nvim"].resolvedRef == null' out-step12.json > /dev/null
                  jq -e '.plugins["commit-and-version.nvim"].resolvedRef == null' out-step12.json > /dev/null
                  jq -e '.plugins["version-false.nvim"].resolvedRef == null' out-step12.json > /dev/null
                  if [ -s step12.log ]; then
                    echo "the gate must not touch a nonexistent remote nor warn, got:" >&2
                    cat step12.log >&2
                    exit 1
                  fi

                  # 13(b). A prev freeze (pin = true, resolved on an earlier lock) wins over semver
                  # resolution before any ls-remote happens: the url is a nonexistent path, so if the
                  # freeze did not win first, this would fail with classification C.
                  nvim -l $lua/resolve.lua $fx/raw-spec-pinned-frozen.json out-step13b.json \
                    --prev $fx/prev-pinned-unresolved.json --lock $fx/flake.lock --lazy $lazy \
                    2> step13b.log
                  jq -e '.plugins["pinned.nvim"].resolvedRef
                         == "cccccccccccccccccccccccccccccccccccccccc"' out-step13b.json > /dev/null
                  grep -q 'pinned; version constraint "\^1.2" is not validated (pin wins)' step13b.log
                  if grep -q 'git ls-remote failed' step13b.log; then
                    echo "a prev freeze must win before any ls-remote is attempted" >&2
                    exit 1
                  fi

                  # 14. E2E: a real extractor run, through to a real (local) resolution.
                  sb2=$TMPDIR/sandbox2
                  mkdir -p $sb2/config $sb2/data/nvim/lazy $sb2/state $sb2/cache
                  ln -s ${./tests/fixtures/merge-config} $sb2/config/nvim
                  ln -s $lazy $sb2/data/nvim/lazy/lazy.nvim
                  env \
                    XDG_CONFIG_HOME=$sb2/config \
                    XDG_DATA_HOME=$sb2/data \
                    XDG_STATE_HOME=$sb2/state \
                    XDG_CACHE_HOME=$sb2/cache \
                    NVIMX_LAZY_SEED=$lazy \
                    NVIMX_OUT=$sb2/raw-spec.json \
                    nvim --headless --cmd "luafile $lua/extract.lua"
                  jq -e '.plugins["telescope.nvim"].version == "^0.1"' $sb2/raw-spec.json > /dev/null
                  jq --arg u "file://$sb/telescope" '.plugins["telescope.nvim"].url = $u' \
                    $sb2/raw-spec.json > $sb2/raw-spec-patched.json
                  nvim -l $lua/resolve.lua $sb2/raw-spec-patched.json out-step14.json --lazy $lazy \
                    2> step14.log
                  jq -e '.plugins["telescope.nvim"].resolvedRef == "refs/tags/0.1.8"' out-step14.json > /dev/null

                  # 15. --lazy is required exactly when something is pending, not unconditionally.
                  rc=0
                  nvim -l $lua/resolve.lua explicit.json out-step15.json 2> step15.log || rc=$?
                  if [ "$rc" -eq 0 ]; then
                    echo "resolving a pending version constraint without --lazy must fail" >&2
                    exit 1
                  fi
                  grep -q -- '--lazy' step15.log
                  # ...and the converse: nothing pending needs no --lazy at all (step 12 already
                  # relies on this; repeated here so both halves of the contract sit together).
                  nvim -l $lua/resolve.lua $fx/raw-spec-gate.json out-step15b.json 2> step15b.log

                  # 16. Destructive (kept last): a fully carried tag ref needs no further network
                  # access at all, even once the remote it originally came from is gone -- this is
                  # what makes the second nvimx-lock pass, and every unrelated re-lock afterwards,
                  # network-free (#18's identity contract). Not repeated for the defaults-fallback
                  # case (out-step10.json): its resolvedRef stays null on purpose, so it is
                  # re-queried on every run, and would legitimately fail once the remote is gone.
                  rm -rf $sb/tagged $sb/untagged
                  nvim -l $lua/resolve.lua explicit.json out-step16.json --prev out-explicit.json \
                    --lazy $lazy 2> step16.log
                  cmp out-explicit.json out-step16.json
                  if [ -s step16.log ]; then
                    echo "a fully carried resolve must not touch the network nor warn, got:" >&2
                    cat step16.log >&2
                    exit 1
                  fi

                  touch $out
                ''
              );
          # Offline coverage of `--update [name...]` (#24): resolve.lua's name validation,
          # force-set construction, and update-plan output, driven the same way
          # checks.resolve-merge drives the plain merge path. `nix flake lock` / `nix flake
          # update` themselves cannot run inside a nix build (recursive nix), so the actual CLI
          # wiring in lock-app.nix is only exercised here for its argument parser (step 10, which
          # never calls `nix`); the rest is covered by the plan's §6.4 manual verification.
          resolve-update =
            pkgs.runCommand "resolve-update"
              {
                nativeBuildInputs = [
                  pkgs.neovim-unwrapped
                  pkgs.jq
                  pkgs.git
                  nvimxLib.lockApp
                ];
              }
              (
                mkTagRepoSh
                + ''
                  export HOME=$TMPDIR
                  lua=${./lua/nvimx}
                  fx=${./tests/fixtures/update}
                  mfx=${./tests/fixtures/merge}
                  lazy=${lazy-nvim}

                  # 1. Steady state, exactly checks.resolve-merge's own pass1 -> out1 (the golden
                  # comparison for this is resolve-merge's job, not repeated here). This is only
                  # the starting point every --update case below forces a plugin away from.
                  nvim -l $lua/resolve.lua $mfx/raw-spec-base.json pass1.json --lock $mfx/flake.lock \
                    --lazy $lazy 2> /dev/null
                  nvim -l $lua/resolve.lua $mfx/raw-spec-base.json out1.json \
                    --prev pass1.json --lock $mfx/flake.lock --lazy $lazy 2> /dev/null

                  # 2. Naming a pinned plugin thaws just that plugin: the rest of plugins.json is
                  # byte-for-byte the steady state, and the plan names only the one plugin.
                  nvim -l $lua/resolve.lua $mfx/raw-spec-base.json out2.json \
                    --prev out1.json --lock $mfx/flake.lock --lazy $lazy \
                    --update tokyonight.nvim --update-plan plan2.txt 2> /dev/null
                  diff -u $fx/golden/update-pinned.plugins.json out2.json
                  for other in telescope.nvim plenary.nvim custom.nvim; do
                    diff -u \
                      <(jq -S --arg n "$other" '.plugins[$n]' out1.json) \
                      <(jq -S --arg n "$other" '.plugins[$n]' out2.json)
                  done
                  [ "$(cat plan2.txt)" = "tokyonight-nvim" ]

                  # 3. A bare --update thaws everything not pinned: both pinned plugins keep out1's
                  # frozen rev, and the plan is exactly the pinned exclusion made explicit -- the
                  # two unpinned plugins' inputNames plus the synthetic lazy-nvim seed, sorted.
                  nvim -l $lua/resolve.lua $mfx/raw-spec-base.json out3.json \
                    --prev out1.json --lock $mfx/flake.lock --lazy $lazy \
                    --update --update-plan plan3.txt 2> /dev/null
                  jq -e '.plugins["tokyonight.nvim"].resolvedRef
                         == "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"' out3.json > /dev/null
                  jq -e '.plugins["custom.nvim"].resolvedRef
                         == "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"' out3.json > /dev/null
                  printf 'lazy-nvim\nplenary-nvim\ntelescope-nvim\n' > plan3-expected.txt
                  diff -u plan3-expected.txt plan3.txt

                  # 4. --update lazy.nvim moves only the synthetic seed input: plugins.json is
                  # untouched and the plan names only lazy-nvim.
                  nvim -l $lua/resolve.lua $mfx/raw-spec-base.json out4.json \
                    --prev out1.json --lock $mfx/flake.lock --lazy $lazy \
                    --update lazy.nvim --update-plan plan4.txt 2> /dev/null
                  cmp out1.json out4.json
                  [ "$(cat plan4.txt)" = "lazy-nvim" ]

                  # 5. Unknown names are collected and reported together, not one at a time (#23's
                  # convention), and nothing is written -- resolve.lua's "no partial plugins.json on
                  # failure" contract (#18 §3.4) extends to a failed --update. The third name is
                  # spelled as an inputName rather than the display name, to prove the did-you-mean
                  # hint fires without treating it as accepted.
                  rc=0
                  nvim -l $lua/resolve.lua $mfx/raw-spec-base.json out5.json \
                    --prev out1.json --lock $mfx/flake.lock --lazy $lazy \
                    --update no-such-plugin --update also-missing --update tokyonight-nvim \
                    2> out5.log || rc=$?
                  [ "$rc" -ne 0 ]
                  grep -q 'plugin "no-such-plugin": unknown plugin' out5.log
                  grep -q 'plugin "also-missing": unknown plugin' out5.log
                  grep -q 'plugin "tokyonight-nvim": unknown plugin (did you mean "tokyonight.nvim"?)' out5.log
                  [ ! -f out5.json ]

                  # 6. A local (dev/dir) plugin and an unknown name in the same run are reported
                  # together too, not just multiple unknown names.
                  jq '.plugins["local.nvim"] = { "name": "local.nvim", "dev": true, "dir": "/some/path" }' \
                    $mfx/raw-spec-base.json > raw-spec-with-local.json
                  rc=0
                  nvim -l $lua/resolve.lua raw-spec-with-local.json out6.json \
                    --prev out1.json --lock $mfx/flake.lock --lazy $lazy \
                    --update local.nvim --update no-such-plugin 2> out6.log || rc=$?
                  [ "$rc" -ne 0 ]
                  grep -q 'plugin "local.nvim": is a local plugin' out6.log
                  grep -q 'plugin "no-such-plugin": unknown plugin' out6.log
                  [ ! -f out6.json ]

                  # 7. resolve.lua's own defense against mixing a bare --update with a named one
                  # (for anyone driving it by hand -- the CLI itself never reaches this, since
                  # lock-app rejects the same combination first; step 10 below is what proves the
                  # CLI path actually does).
                  rc=0
                  nvim -l $lua/resolve.lua $mfx/raw-spec-base.json out7.json \
                    --prev out1.json --lock $mfx/flake.lock --lazy $lazy \
                    --update --update foo 2> out7.log || rc=$?
                  [ "$rc" -eq 2 ]
                  grep -q -- '--update takes either no names' out7.log

                  # 8. A plugin whose spec fixes `commit` is a no-op when named explicitly (the URL
                  # cannot move either way) but still lands in the update-plan -- harmlessly, since
                  # `nix flake update` cannot move it either. This is the golden fixture for that
                  # decision (§3.2 of the plan).
                  nvim -l $lua/resolve.lua $fx/raw-spec-commit.json out8base.json \
                    --lock $mfx/flake.lock --lazy $lazy 2> /dev/null
                  nvim -l $lua/resolve.lua $fx/raw-spec-commit.json out8.json \
                    --prev out8base.json --lock $mfx/flake.lock --lazy $lazy \
                    --update vim-fugitive --update-plan plan8.txt 2> /dev/null
                  jq -e '.plugins["vim-fugitive"].commit
                         == "dddddddddddddddddddddddddddddddddddddddd"' out8.json > /dev/null
                  [ "$(cat plan8.txt)" = "vim-fugitive" ]

                  # 9. The convergence pass' own re-resolve (no --update, exactly what lock-app.nix
                  # runs after `nix flake update`) is what actually refreezes a thawed pin once
                  # flake.lock has caught up with the new rev, and running it once more from there
                  # must be a fixed point -- the second nvimx-lock pass never needs a third.
                  nvim -l $lua/resolve.lua $mfx/raw-spec-base.json out9a.json \
                    --prev out2.json --lock $fx/flake.lock.after --lazy $lazy 2> /dev/null
                  jq -e '.plugins["tokyonight.nvim"].resolvedRef
                         == "5555555555555555555555555555555555555555"' out9a.json > /dev/null
                  nvim -l $lua/resolve.lua $mfx/raw-spec-base.json out9b.json \
                    --prev out9a.json --lock $fx/flake.lock.after --lazy $lazy 2> /dev/null
                  cmp out9a.json out9b.json

                  # 10. lock-app's own parser rejects the same bare+named mix (§3.1 of the plan):
                  # this is the one place the rejection is provable without ever calling `nix`, and
                  # the exact case the plan review found the previous draft could not actually
                  # reach from the CLI. No real config/out is needed -- the rejection happens before
                  # either is even realpath'd.
                  rc=0
                  nvimx-lock --config /nonexistent-config --out /nonexistent-out \
                    --update --update foo 2> out10.log || rc=$?
                  [ "$rc" -eq 2 ]
                  grep -q 'usage: nvimx-lock' out10.log

                  # 11. A version constraint on a named plugin resolves against a real (if local
                  # and offline) remote exactly as a normal lock would: force only discards the
                  # previous decision, it does not change how the constraint itself is honored.
                  mkrepo $TMPDIR/tagged v1.0.0 v1.2.0 v1.2.5
                  jq --arg u "file://$TMPDIR/tagged" \
                    '.plugins["tagged.nvim"] = { "name": "tagged.nvim", "url": $u, "version": "^1.0" }' \
                    $mfx/raw-spec-base.json > raw-spec-tagged.json
                  jq --arg u "file://$TMPDIR/tagged" \
                    '.plugins["tagged.nvim"] = { "inputName": "tagged-nvim", "resolvedRef": "refs/tags/v1.0.0",
                                                  "branch": null, "tag": null, "commit": null, "version": "^1.0",
                                                  "pin": null, "dependencies": [], "build": { "kind": "none" },
                                                  "source": { "type": "git", "url": $u } }' \
                    out1.json > prev-tagged.json
                  nvim -l $lua/resolve.lua raw-spec-tagged.json out11.json \
                    --prev prev-tagged.json --lazy $lazy \
                    --update tagged.nvim 2> /dev/null
                  jq -e '.plugins["tagged.nvim"].resolvedRef == "refs/tags/v1.2.5"' out11.json > /dev/null

                  touch $out
                ''
              );
          # Offline coverage of update-summary.lua (#24): a pure text transform over four JSON
          # snapshots, so this needs nothing beyond neovim-unwrapped -- no git, no `nix flake *`.
          update-summary =
            pkgs.runCommand "update-summary"
              {
                # jq is only for this check's own fixture tweaking (the tag-pairing case below);
                # update-summary.lua itself needs nothing beyond neovim-unwrapped.
                nativeBuildInputs = [
                  pkgs.neovim-unwrapped
                  pkgs.jq
                ];
              }
              ''
                export HOME=$TMPDIR
                lua=${./lua/nvimx}
                fx=${./tests/fixtures/update}

                # Named mode: tokyonight.nvim and lazy.nvim were asked for; plenary.nvim moved
                # without being named and without an explanation on offer, so it is both listed
                # and counted in the warning. telescope.nvim's version constraint resolving for the
                # first time, and old.nvim/new.nvim being removed/added, are never warned about.
                nvim -l $lua/update-summary.lua \
                  $fx/plugins.json.before $fx/plugins.json.after \
                  $fx/flake.lock.summary-before.json $fx/flake.lock.summary-after.json \
                  tokyonight.nvim lazy.nvim 2> summary-named.txt
                diff -u $fx/golden/summary-named.txt summary-named.txt

                # Full-update mode: every plugin is listed, including the ones that did not move
                # (nui.nvim's pinned-skip, vim-fugitive's commit-pinned) -- there is no
                # "unrequested" concept here, so no warning line is ever printed. tokyonight.nvim
                # is also `pin = true`, but its rev genuinely differs between the two snapshots, so
                # it is reported as `updated` rather than swallowed as a skip -- the fixture doubles
                # as coverage for classify()'s pin/commit branches being gated on rb == ra (the
                # dedicated regression cases below test the same gate in named mode, where a
                # swallowed move would otherwise be silent rather than just misclassified).
                nvim -l $lua/update-summary.lua \
                  $fx/plugins.json.before $fx/plugins.json.after \
                  $fx/flake.lock.summary-before.json $fx/flake.lock.summary-after.json \
                  2> summary-all.txt
                diff -u $fx/golden/summary-all.txt summary-all.txt
                if grep -q '^nvimx-lock: warning:' summary-all.txt; then
                  echo "a full update must never print the unnamed-input warning" >&2
                  exit 1
                fi

                # Nothing moved (the same snapshot fed in as both before and after): a single line
                # rather than an empty or misleading "0 updated" summary.
                nvim -l $lua/update-summary.lua \
                  $fx/plugins.json.before $fx/plugins.json.before \
                  $fx/flake.lock.summary-before.json $fx/flake.lock.summary-before.json \
                  tokyonight.nvim 2> summary-none.txt
                diff -u $fx/golden/summary-none.txt summary-none.txt

                # A full update where every unpinned plugin was already at rest must still report
                # its pinned-skips (§3.4 of the plan says so explicitly: "must always" be shown) --
                # the "no plugins updated" shortcut above must not swallow that just because
                # nothing counted as updated/added/removed.
                nvim -l $lua/update-summary.lua \
                  $fx/plugins.json.before $fx/plugins.json.before \
                  $fx/flake.lock.summary-before.json $fx/flake.lock.summary-before.json \
                  2> summary-all-at-rest.txt
                grep -q 'pinned: tokyonight.nvim' summary-all-at-rest.txt
                grep -q 'pinned: nui.nvim' summary-all-at-rest.txt
                if grep -q '^nvimx-lock: no plugins updated' summary-all-at-rest.txt; then
                  echo "a pinned-skip must not be swallowed by the 'no plugins updated' shortcut" >&2
                  exit 1
                fi

                # The ref-pairing rule is limited to tag-ref-vs-tag-ref (§3.4 of the plan): a pin's
                # thaw-then-refreeze is 40-hex on both sides, and must not double up as
                # "aaaa... -> bbbb... (aaaa... -> bbbb...)" -- tokyonight.nvim's line above already
                # pins that it does not. This checks the positive case: when both sides really are
                # refs/tags/..., they are shown paired, with the rev move alongside in parens.
                jq '.plugins["telescope.nvim"].resolvedRef = "refs/tags/0.1.7"' \
                  $fx/plugins.json.before > plugins-tagpair-before.json
                jq '.plugins["telescope.nvim"].resolvedRef = "refs/tags/0.1.8"' \
                  $fx/plugins.json.after > plugins-tagpair-after.json
                nvim -l $lua/update-summary.lua \
                  plugins-tagpair-before.json plugins-tagpair-after.json \
                  $fx/flake.lock.summary-before.json $fx/flake.lock.summary-after.json \
                  2> summary-tagpair.txt
                grep -q 'updated: telescope.nvim refs/tags/0.1.7 -> refs/tags/0.1.8 (c0c0c0c -> e0e0e0e)' \
                  summary-tagpair.txt

                # A `commit`-pinned plugin is only "cannot have moved" while its rev actually did
                # not move: if the spec's `commit` itself was edited (and the rev moved with it),
                # named mode must still report it -- as an ordinary "(spec changed)" line, not
                # silence -- rather than falling into "unchanged (commit-pinned in spec)" as if
                # nothing happened. This is the regression case for classify()'s pin/commit
                # branches being gated on rb == ra.
                jq '.plugins["vim-fugitive"].commit = "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"' \
                  $fx/plugins.json.after > plugins-commitmove-after.json
                jq '.nodes["vim-fugitive"].locked.rev = "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"' \
                  $fx/flake.lock.summary-after.json > lock-commitmove-after.json
                nvim -l $lua/update-summary.lua \
                  $fx/plugins.json.before plugins-commitmove-after.json \
                  $fx/flake.lock.summary-before.json lock-commitmove-after.json \
                  tokyonight.nvim 2> summary-commitmove.txt
                grep -q 'updated: vim-fugitive ddddddd -> eeeeeee (spec changed)' summary-commitmove.txt

                # Symmetrically, a pinned (but unnamed) input whose rev moved anyway -- some
                # anomaly, not a `--update` this run even asked for -- must be caught by the
                # unnamed-move warning, not hidden behind "pinned (skipped)" as if it were still
                # frozen. This is Done when 4's safety net; silence here is exactly the bug.
                jq '.nodes["nui-nvim"].locked.rev = "9999999999999999999999999999999999999999"' \
                  $fx/flake.lock.summary-after.json > lock-pinmove-after.json
                nvim -l $lua/update-summary.lua \
                  $fx/plugins.json.before $fx/plugins.json.after \
                  $fx/flake.lock.summary-before.json lock-pinmove-after.json \
                  tokyonight.nvim 2> summary-pinmove.txt
                grep -q 'updated: nui.nvim c3c3c3c -> 9999999' summary-pinmove.txt
                grep -q '^nvimx-lock: warning:.*nui.nvim' summary-pinmove.txt

                # Dropping `pin` from an unnamed plugin's spec thaws it (resolve.lua's merge sets
                # resolvedRef back to null) and a plain `nix flake lock` then moves its URL to
                # HEAD -- a legitimate move docs/architecture.md itself documents ("Removing pin
                # thaws the plugin"), not an anomaly. `pin` is not one of identity_fields, so
                # same_identity alone cannot catch this: it must be its own reason, reported as
                # `updated ... (unpinned)` and excluded from the unnamed-move warning.
                jq '.plugins["nui.nvim"].pin = true
                    | .plugins["nui.nvim"].resolvedRef = "c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3"' \
                  $fx/plugins.json.before > plugins-unpin-before.json
                jq '.plugins["nui.nvim"].pin = null | .plugins["nui.nvim"].resolvedRef = null' \
                  $fx/plugins.json.after > plugins-unpin-after.json
                jq '.nodes["nui-nvim"].locked.rev = "8888888888888888888888888888888888888888"' \
                  $fx/flake.lock.summary-after.json > lock-unpin-after.json
                nvim -l $lua/update-summary.lua \
                  plugins-unpin-before.json plugins-unpin-after.json \
                  $fx/flake.lock.summary-before.json lock-unpin-after.json \
                  tokyonight.nvim 2> summary-unpin.txt
                grep -q 'updated: nui.nvim c3c3c3c -> 8888888 (unpinned)' summary-unpin.txt
                if grep -q '^nvimx-lock: warning:.*nui.nvim' summary-unpin.txt; then
                  echo "an unpin is a legitimate, self-explaining move and must not be warned about" >&2
                  exit 1
                fi

                # The synthetic lazy-nvim seed is an input like any other for the safety net
                # (docs/architecture.md: "warns if an unnamed input moved"): named mode without
                # --update lazy.nvim must still surface an unexplained lazy-nvim move, not stay
                # silent just because lazy.nvim has no plugins.json entry to check a reason
                # against. $fx/flake.lock.summary-after.json already moves lazy-nvim relative to
                # summary-before.json, and neither name here is "lazy.nvim".
                nvim -l $lua/update-summary.lua \
                  $fx/plugins.json.before $fx/plugins.json.after \
                  $fx/flake.lock.summary-before.json $fx/flake.lock.summary-after.json \
                  tokyonight.nvim 2> summary-lazy-unrequested.txt
                grep -q 'updated: lazy.nvim (seed) 9c9c9c9 -> 3f3f3f3' summary-lazy-unrequested.txt
                grep -q '^nvimx-lock: warning:.*lazy\.nvim' summary-lazy-unrequested.txt

                touch $out
              '';
          # Offline coverage of `--import-lazy-lock` (#25). Deliberately without pkgs.git:
          # resolve.lua's semver path fails outright when git is not on PATH, so "the resolve
          # exits 0" is itself the proof that a seeded resolvedRef closed #23's gate and no
          # ls-remote was ever attempted. Every fixture url is unreachable on top of that, for the
          # same reason. --lazy is never passed either, which is the other half of the same
          # statement: a migrating config needs neither.
          resolve-import-lazy-lock =
            pkgs.runCommand "resolve-import-lazy-lock"
              {
                nativeBuildInputs = [
                  pkgs.neovim-unwrapped
                  pkgs.jq
                  nvimxLib.lockApp
                ];
              }
              ''
                export HOME=$TMPDIR
                lua=${./lua/nvimx}
                fx=${./tests/fixtures/import-lazy-lock}

                # 1. golden + exact pin. stdout is also captured (used by step 2 below): the
                # progress line resolve.lua prints when it actually resolves a version constraint
                # goes to stdout, not stderr, on purpose (#22) -- see the io.stdout:write next to
                # resolve.lua's "resolving version constraints" message.
                nvim -l $lua/resolve.lua $fx/raw-spec.json out1.json \
                  --import-lazy-lock $fx/lazy-lock.json \
                  > out1.out 2> out1.log
                diff -u $fx/golden/imported.plugins.json out1.json
                # Independent of the golden file: read lazy-lock.json's own commits with jq and
                # compare them one by one against what actually landed in resolvedRef, so a wrong
                # golden could not paper over a wrong implementation.
                for n in plain.nvim git.nvim ver.nvim defver.nvim tag.nvim pinned.nvim; do
                  want=$(jq -r --arg n "$n" '.[$n].commit' $fx/lazy-lock.json)
                  got=$(jq -r --arg n "$n" '.plugins[$n].resolvedRef' out1.json)
                  [ "$want" = "$got" ]
                done

                # 2. #23's gate never fired: primarily proven by step 1 exiting 0 at all (no git on
                # PATH and every url unreachable means any ls-remote attempt is fatal). These greps
                # are a belt-and-suspenders check on top of that, on the right stream this time.
                if grep -q 'resolving version constraints' out1.out; then
                  echo "a seeded resolvedRef must close #23's gate before it ever queues ls-remote" >&2
                  exit 1
                fi
                if grep -q 'ls-remote' out1.log; then
                  echo "no ls-remote should ever run in this offline check" >&2
                  exit 1
                fi

                # 3. The import's own report never leaks into plugins.json's warnings array.
                jq -e '.warnings == []' out1.json > /dev/null

                # 4. Seed exclusion: a spec that already fixes `commit`, a branch mismatch, and a
                # local (dev/dir) plugin all keep resolvedRef null, and commit.nvim's own spec
                # `commit` is untouched.
                jq -e '.plugins["commit.nvim"].resolvedRef == null' out1.json > /dev/null
                jq -e '.plugins["branchy.nvim"].resolvedRef == null' out1.json > /dev/null
                jq -e '.plugins["only-here.nvim"].resolvedRef == null' out1.json > /dev/null
                jq -e '.plugins["commit.nvim"].commit
                       == "dddddddddddddddddddddddddddddddddddddddd"' out1.json > /dev/null

                # 5. The seeded refs reach genflake's generated input URLs, in exactly the forms
                # §7 of the plan predicts (github wins outright; git type combines ref and rev when
                # the spec also names a tag; a spec `commit` beats any seed).
                nvim -l $lua/genflake.lua out1.json flake1.nix
                grep -qF \
                  'url = "github:o/plain.nvim/7777777777777777777777777777777777777777";' flake1.nix
                grep -qF \
                  'url = "git+file:///nvimx-nonexistent/git.nvim?ref=main&rev=4444444444444444444444444444444444444444";' \
                  flake1.nix
                grep -qF \
                  'url = "git+file:///nvimx-nonexistent/tag.nvim?ref=refs/tags/v1.0.0&rev=2222222222222222222222222222222222222222";' \
                  flake1.nix
                grep -qF \
                  'url = "git+file:///nvimx-nonexistent/commit.nvim?rev=dddddddddddddddddddddddddddddddddddddddd";' \
                  flake1.nix

                # 6. Every reporting classification, and nothing unaccounted for.
                grep -q '^\[nvimx\] import: pinned plain.nvim to 777777777777$' out1.log
                grep -q 'import: skipped commit.nvim: the spec already fixes commit dddddddddddd (lazy-lock.json has 555555555555)$' \
                  out1.log
                grep -q 'import: skipped branchy.nvim: the spec is on branch "master" but lazy-lock.json recorded "main"$' \
                  out1.log
                grep -q 'import: skipped local.nvim: it is a local plugin' out1.log
                grep -q 'import: only-here.nvim is not in lazy-lock.json; it will resolve normally$' out1.log
                grep -q 'import: ignored disabled-me.nvim (disabled in the config)$' out1.log
                grep -q 'import: ignored ghost.nvim (not in the config)$' out1.log
                grep -q 'import: ignored git-nvim (not in the config; did you mean "git.nvim"?)$' out1.log
                grep -q 'import: lazy.nvim itself is not imported' out1.log
                grep -q 'import: invalid entry badsha.nvim in lazy-lock.json: commit "not-a-sha" is not a 40-hex sha$' \
                  out1.log
                grep -q 'import: invalid entry nullentry.nvim in lazy-lock.json: value is not an object$' out1.log
                grep -q 'import: version constraint "\^1.2" is not validated for 1 plugin(s) pinned from lazy-lock.json' \
                  out1.log
                # defver.nvim's constraint comes from `defaults.version` (versionFromDefaults =
                # true), so its message uses the "the config-wide ..." phrasing resolve.lua's
                # pin+version warning already established -- not the plain "version
                # constraint" ver.nvim gets above (an explicit `version`). The plan's own sketch of
                # this grep omitted "the config-wide " and so never actually matched; fixed here to
                # check the real, correct message instead of weakening it to fit the typo.
                grep -q 'import: the config-wide version constraint "\*" is not validated for 1 plugin(s) pinned from lazy-lock.json' \
                  out1.log
                grep -q 'import: 6 pinned, 3 skipped, 6 ignored, 1 not in lazy-lock.json$' out1.log
                # No surprise output: exactly 19 lines, every one of them an "import: " note.
                [ "$(grep -c '^\[nvimx\] import: ' out1.log)" -eq 19 ]
                [ "$(wc -l < out1.log)" -eq 19 ]
                # The invariant (§3.6 of the plan): pinned + skipped + ignored accounts for every
                # entry lazy-lock.json has, with nothing silently dropped.
                summary=$(grep 'import: .* pinned,' out1.log)
                pinned=$(echo "$summary" | grep -o '[0-9]* pinned' | grep -o '[0-9]*')
                skipped=$(echo "$summary" | grep -o '[0-9]* skipped' | grep -o '[0-9]*')
                ignored=$(echo "$summary" | grep -o '[0-9]* ignored' | grep -o '[0-9]*')
                total=$(jq 'keys | length' $fx/lazy-lock.json)
                [ "$((pinned + skipped + ignored))" -eq "$total" ]

                # 7. Determinism: raw.plugins and import_db are both walked with pairs(), so this
                # is the proof the sort-then-emit design actually removes that non-determinism.
                nvim -l $lua/resolve.lua $fx/raw-spec.json out1b.json \
                  --import-lazy-lock $fx/lazy-lock.json 2> out1b.log
                diff -u out1.log out1b.log

                # 8. An existing lock always wins over the imported file -- including a `null`
                # resolvedRef, which is itself a decision ("track this ref, nothing to pin").
                nvim -l $lua/resolve.lua $fx/raw-spec.json out2.json \
                  --prev $fx/prev.json --import-lazy-lock $fx/lazy-lock.json 2> out2.log
                jq -e '.plugins["plain.nvim"].resolvedRef
                       == "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"' out2.json > /dev/null
                jq -e '.plugins["tag.nvim"].resolvedRef == null' out2.json > /dev/null
                grep -q 'import: skipped 2 entries already decided by the existing lock$' out2.log

                # 9. `pin = true` plus `version`: the existing "pin wins" warning covers it, so
                # classification 10 must not also mention it (saying it twice would be redundant).
                jq '.plugins["pinned.nvim"].version = "^2.0"' $fx/raw-spec.json > raw-spec-pinver.json
                nvim -l $lua/resolve.lua raw-spec-pinver.json out3.json \
                  --import-lazy-lock $fx/lazy-lock.json 2> out3.log
                jq -e '.plugins["pinned.nvim"].resolvedRef
                       == "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"' out3.json > /dev/null
                grep -q 'pinned; version constraint "\^2.0" is not validated (pin wins)' out3.log
                if grep -q 'is not validated for .* pinned from lazy-lock.json.*pinned\.nvim' out3.log; then
                  echo "pin+version must not be reported twice (once by the pin warning, once by classification 10)" >&2
                  exit 1
                fi

                # 10. Idempotent re-import: every seed from run 1 is already decided, so a second
                # pass with the same lazy-lock.json changes nothing and pins nothing new.
                # local.nvim never reaches plugins.json at all (it lives only in localPlugins), so
                # only 8 of the 9 non-local matched plugins are prev-blocked here, not 9.
                nvim -l $lua/resolve.lua $fx/raw-spec.json out4.json \
                  --prev out1.json --import-lazy-lock $fx/lazy-lock.json 2> out4.log
                cmp out1.json out4.json
                [ "$(grep -c 'import: pinned ' out4.log)" -eq 0 ]
                grep -q 'import: skipped 8 entries already decided by the existing lock$' out4.log

                # 11. The seed's persistence (goal 3's whole point): with no --import-lazy-lock at
                # all, a plain --prev pass reproduces out1.json byte-for-byte and prints nothing --
                # resolvedRef is not part of identity_fields, so a plain lock right after an import
                # never re-litigates it, and the import's own report never lands in plugins.json.
                nvim -l $lua/resolve.lua $fx/raw-spec.json out5.json --prev out1.json 2> out5.log
                cmp out1.json out5.json
                [ ! -s out5.log ]

                # 12. A lazy-lock.json nvimx cannot parse must stop the run, with no partial output
                # written (resolve.lua only ever writes its output once, at the very end).
                rc=0
                nvim -l $lua/resolve.lua $fx/raw-spec.json bad1.json \
                  --import-lazy-lock $fx/lazy-lock-broken.json 2> bad1.log || rc=$?
                [ "$rc" -ne 0 ]
                grep -q 'is not valid JSON' bad1.log
                grep -q ':Lazy restore' bad1.log
                [ ! -f bad1.json ]

                # 13. A missing lazy-lock.json is a hard, explicit error -- never a silent fallback
                # to a plain lock, which is exactly the accident this flag exists to prevent.
                rc=0
                nvim -l $lua/resolve.lua $fx/raw-spec.json bad2.json \
                  --import-lazy-lock $TMPDIR/no-such.json 2> bad2.log || rc=$?
                [ "$rc" -ne 0 ]
                grep -q 'cannot open the lazy-lock.json' bad2.log
                [ ! -f bad2.json ]

                # 13b. Coverage-gap fixtures the plan's review added: an empty object, and a
                # top-level array. Both use a raw-spec with ver.nvim / defver.nvim's `version`
                # stripped (a jq-derived variant, not $fx/raw-spec.json directly): neither of these
                # two lazy-lock fixtures seeds anything at all, so nothing would ever close #23's
                # gate for those two plugins, and this check deliberately has neither git nor
                # --lazy available to resolve them. That is a real gap the plan's own snippet
                # missed (it reused $fx/raw-spec.json as-is here) -- with it, this step would fail
                # needing --lazy on every run, seeded or not, which is a much less useful check
                # than "importing an empty/malformed lock behaves correctly".
                jq 'del(.plugins["ver.nvim"].version,
                        .plugins["defver.nvim"].version,
                        .plugins["defver.nvim"].versionFromDefaults)' \
                  $fx/raw-spec.json > raw-spec-no-version.json

                # {} -- valid and empty: a "nothing to seed" note, and every config plugin still
                # reported as resolving normally (classification 5) plus a summary, even though
                # there was nothing to loop over.
                nvim -l $lua/resolve.lua raw-spec-no-version.json out6.json \
                  --import-lazy-lock $fx/lazy-lock-empty.json 2> out6.log
                grep -q 'import: lazy-lock.json has no entries; nothing to seed$' out6.log
                jq -e '[.plugins[] | .resolvedRef] | all(. == null)' out6.json > /dev/null
                [ "$(grep -c 'is not in lazy-lock.json; it will resolve normally$' out6.log)" -eq 9 ]
                grep -q 'import: 0 pinned, 0 skipped, 0 ignored, 9 not in lazy-lock.json$' out6.log

                # [] -- vim.json.decode returns a table with integer keys for a JSON array, so this
                # is not the hard-error path (a JSON scalar is); every "key" is a number instead of
                # a plugin name, reported as classification 9.
                nvim -l $lua/resolve.lua raw-spec-no-version.json out7.json \
                  --import-lazy-lock $fx/lazy-lock-array.json 2> out7.log
                [ "$(grep -c 'key is not a plugin name' out7.log)" -eq 2 ]

                # 13c. A JSON scalar at the top level (a bare number, string, boolean, or null) is
                # the hard-error counterpart to the array case just above: vim.json.decode returns
                # a plain Lua value whose type is not "table" at all, so it is caught up front
                # rather than falling through to the entry loop and being reported per-entry like
                # the array's classification-9 lines.
                rc=0
                nvim -l $lua/resolve.lua raw-spec-no-version.json bad3.json \
                  --import-lazy-lock $fx/lazy-lock-scalar.json 2> bad3.log || rc=$?
                [ "$rc" -ne 0 ]
                grep -q 'is not a table' bad3.log
                [ ! -f bad3.json ]

                # A top-level `null` is a scalar too (vim.json.decode returns vim.NIL, Lua type
                # "userdata"), but saying so verbatim would mean nothing to a reader -- checked here
                # that the message says "null", the actual JSON word they wrote, instead.
                rc=0
                nvim -l $lua/resolve.lua raw-spec-no-version.json bad4.json \
                  --import-lazy-lock $fx/lazy-lock-null.json 2> bad4.log || rc=$?
                [ "$rc" -ne 0 ]
                grep -q 'is not a table (it decoded to null)' bad4.log
                if grep -q 'userdata' bad4.log; then
                  echo "a top-level null must be reported as null, not as the Lua type it happens to decode to" >&2
                  exit 1
                fi
                [ ! -f bad4.json ]

                # 13d. Classification 9's "no commit" reason has no coverage yet: an entry whose
                # value is an object but has no `commit` key at all (as opposed to badsha.nvim in
                # the main fixture, whose `commit` fails the 40-hex check instead). Built inline
                # rather than folded into $fx/lazy-lock.json itself, so that fixture's
                # exactly-19-lines assertion (check 6, above) is not perturbed.
                cat > lazy-lock-nocommit.json <<'JSON'
                {
                  "nocommit.nvim": { "branch": "main" }
                }
                JSON
                nvim -l $lua/resolve.lua raw-spec-no-version.json out8.json \
                  --import-lazy-lock lazy-lock-nocommit.json 2> out8.log
                grep -q 'import: invalid entry nocommit.nvim in lazy-lock.json: no commit$' out8.log
                grep -q 'import: 0 pinned, 0 skipped, 1 ignored, 9 not in lazy-lock.json$' out8.log

                # 14. lock-app's own parser rejects --update + --import-lazy-lock outright, before
                # --config/--out are even realpath'd -- provable without ever calling `nix`.
                rc=0
                nvimx-lock --config /nonexistent-config --out /nonexistent-out \
                  --update --import-lazy-lock 2> cli1.log || rc=$?
                [ "$rc" -eq 2 ]
                grep -q -- '--import-lazy-lock cannot be combined with --update' cli1.log
                grep -q 'usage: nvimx-lock' cli1.log
                grep -q -- '--import-lazy-lock \[path\]' cli1.log

                # 15. The default path (<configDir>/lazy-lock.json) and an explicit missing path,
                # both fatal before `mkdir -p "$out"` ever runs -- neither leaves an out directory.
                mkdir -p cfg
                rc=0
                nvimx-lock --config cfg --out outdir --import-lazy-lock 2> cli2.log || rc=$?
                [ "$rc" -eq 2 ]
                grep -q "no lazy-lock.json at $(realpath cfg)/lazy-lock.json" cli2.log
                [ ! -e outdir ]

                rc=0
                nvimx-lock --config cfg --out outdir2 --import-lazy-lock /no/such/lazy-lock.json \
                  2> cli3.log || rc=$?
                [ "$rc" -eq 2 ]
                grep -q 'no lazy-lock.json at /no/such/lazy-lock.json' cli3.log
                [ ! -e outdir2 ]

                # 16. Name matching, proven through the real extractor rather than a hand-written
                # raw-spec: extract's derived name and lazy-lock.json's own keys have to agree for
                # any of the above to mean anything about a real config. Includes lazy.nvim's own
                # entry, which every real lazy-lock.json has (the extractor's raw-spec never does),
                # so classification 8 gets one genuine end-to-end exercise too.
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
                cat > basic-lazy-lock.json <<'JSON'
                {
                  "lazy.nvim":       { "branch": "main", "commit": "0000000000000000000000000000000000000000" },
                  "tokyonight.nvim": { "branch": "main", "commit": "1234123412341234123412341234123412341234" }
                }
                JSON
                nvim -l $lua/resolve.lua $sb/raw-spec.json basic-out.json \
                  --import-lazy-lock basic-lazy-lock.json 2> basic-import.log
                jq -e '.plugins["tokyonight.nvim"].resolvedRef
                       == "1234123412341234123412341234123412341234"' basic-out.json > /dev/null
                grep -q 'import: lazy.nvim itself is not imported' basic-import.log

                # 17. Regression guard for lock-app.nix's log-truncation hazard. The real
                # nvimx-lock runs resolve.lua twice -- pass 1 with --import-lazy-lock, then an
                # unconditional convergence pass (deliberately without --import-lazy-lock; see that
                # pass's own comment in lock-app.nix) -- and both redirect stderr with `2>` to the
                # same resolve.log path. `2>` truncates on open, so without lifting pass 1's
                # `[nvimx] import: ...` report out first, pass 2 silently erases it before
                # nvimx-lock ever gets a chance to print it -- exactly the bug this fix closes.
                # The full two-pass pipeline can't run inside this check (it ends in `nix flake
                # lock`, and a nested nix call from within a nix build is recursive nix), so this
                # reproduces just the hazard: run pass 1, lift its import lines out with the same
                # grep lock-app.nix uses, then run a convergence-shaped pass 2 (--prev, no
                # --import-lazy-lock) redirected to the *same* log file, and prove (a) the shared
                # log really did lose every import line, and (b) the lifted-out copy did not. This
                # exists so lock-app.nix's flush_logs/import.log fix can never be "simplified" back
                # into a single shared log file without this check catching it.
                nvim -l $lua/resolve.lua $fx/raw-spec.json seq-out1.json \
                  --import-lazy-lock $fx/lazy-lock.json 2> seq.log
                grep '^\[nvimx\] import: ' seq.log > seq-import.log || true
                nvim -l $lua/resolve.lua $fx/raw-spec.json seq-out2.json \
                  --prev seq-out1.json 2> seq.log
                if grep -q 'import: ' seq.log; then
                  echo "pass 2 was expected to truncate away pass 1's import lines when both redirect to the same path -- that is the exact hazard lock-app.nix's import.log lift-out has to work around" >&2
                  exit 1
                fi
                [ "$(wc -l < seq-import.log)" -eq 19 ]

                touch $out
              '';
          # dev.path is the one forced lazy opt that stops being a constant with #26, so this check
          # has two halves. The first is pure evaluation of makeEnv's new devDirs /
          # unknownDevPluginNames outputs -- neither forces the farm, so it costs nothing and
          # fetches nothing -- in the `failures`-list style of checks.treesitter-grammars. The
          # second runs the *generated bootstrap* through a real lazy.nvim and reads back the
          # directory it resolved each plugin to: the only place the string-vs-function "/<name>"
          # asymmetry of lua/lazy/core/meta.lua:229-231 can actually be caught.
          dev-plugins =
            let
              inherit (pkgs) lib;
              devRoot = ./tests/fixtures/dev-plugins/dev-root;
              # Evaluation half. A lock with a non-empty localPlugins -- one entry with no `dir`
              # and one whose recorded `dir` points somewhere devPath would never produce -- plus
              # one devPlugins name that matches a locked plugin and one that matches nothing.
              locked = nvimxLib.makeEnv {
                package = pkgs.neovim-unwrapped;
                lockDir = ./tests/fixtures/dev-plugins/nvimx-lock;
                devPlugins = [
                  "tokyonight.nvim"
                  "typo.nvim"
                ];
                devPath = "~/proj";
              };
              # The default has to be a genuine no-op: basic-config's localPlugins is empty and
              # nothing is named here, so devDirs must come out empty and bootstrap.lua must keep
              # resolving every plugin under the farm.
              untouched = nvimxLib.makeEnv {
                package = pkgs.neovim-unwrapped;
                lockDir = ./tests/fixtures/basic-config/nvimx-lock;
              };
              # Degraded mode has no lock to judge a name against, so it must never call one a typo.
              degraded = nvimxLib.makeEnv {
                package = pkgs.neovim-unwrapped;
                lockDir = ./tests/fixtures/basic-config/no-such-lock;
                devPlugins = [ "typo.nvim" ];
              };
              # The module's pass-through, read back at evaluation level. checks.hm-module-dev
              # exercises the same options but cannot fail on this: mkHmCheck returns only an
              # activationPackage and asserts nothing about it, so dropping devPlugins or devPath
              # from makeEnv's argument list in nix/home-manager/default.nix leaves it green -- the
              # options still type-check, are silently ignored, and the package still builds.
              # Dropping either one is equally silent: both formals carry defaults
              # (nix/lib/make-env.nix), so a missing argument is never an error -- the absent `...`
              # only rejects arguments makeEnv does not declare, which is the opposite direction.
              # This assertion is the only guard for all three drop combinations. Every other env
              # here calls makeEnv directly and so bypasses the module, which is why this one does
              # not.
              moduleDevDirs =
                (home-manager.lib.homeManagerConfiguration {
                  inherit pkgs;
                  modules = [
                    self.homeModules.nvimx
                    {
                      # The three home.* settings homeManagerConfiguration requires, same values
                      # mkHmCheck uses. Nothing here is built -- only .config is read.
                      home.username = "nvimx-test";
                      home.homeDirectory = "/home/nvimx-test";
                      home.stateVersion = "25.05";
                      programs.nvimx = {
                        enable = true;
                        configDir = ./tests/fixtures/basic-config;
                        lockDir = ./tests/fixtures/basic-config/nvimx-lock;
                        devPlugins = [ "tokyonight.nvim" ];
                        devPath = "~/proj";
                      };
                    }
                  ];
                }).config.programs.nvimx.env.devDirs;
              # Runtime half, deliberately built in degraded mode: the farm is then the lazy.nvim
              # seed alone -- no lock, no fetchTree, fully offline -- while devPlugins / devPath
              # still apply, because they do not depend on the lock at all.
              # dirred.nvim is named here on purpose even though the driver's spec gives it a
              # `dir`: the point is that it gets a dev_dirs entry and lazy still ignores it.
              devEnv = nvimxLib.makeEnv {
                package = pkgs.neovim-unwrapped;
                lockDir = ./tests/fixtures/basic-config/no-such-lock;
                devPlugins = [
                  "tokyonight.nvim"
                  "bare.nvim"
                  "dirred.nvim"
                ];
                devPath = "${devRoot}";
              };
              plainEnv = nvimxLib.makeEnv {
                package = pkgs.neovim-unwrapped;
                lockDir = ./tests/fixtures/basic-config/no-such-lock;
              };
              failures =
                lib.optional (
                  (locked.devDirs."tokyonight.nvim" or null) != "~/proj/tokyonight.nvim"
                ) "a devPlugins name must override a plugin that is in the lock"
                ++ lib.optional (
                  (locked.devDirs."bare.nvim" or null) != "~/proj/bare.nvim"
                ) "a localPlugins key must route to <devPath>/<name>"
                # The fixture records dir = "~/elsewhere/dirred.nvim" for this one precisely so that
                # reading it back would produce a different answer. It is ignored not because it is
                # machine-specific -- a dir the user wrote absolute is kept verbatim -- but because
                # a spec-level dir short-circuits lazy before dev.path is ever consulted
                # (lua/lazy/core/meta.lua:214-217), so reading it could not change any resolved
                # directory. devPath decides, and stays the only thing that does.
                ++ lib.optional (
                  (locked.devDirs."dirred.nvim" or null) != "~/proj/dirred.nvim"
                ) "a localPlugins entry's recorded dir must be ignored: devPath decides"
                # typo.nvim is in this list on purpose. A devPlugins name that matches nothing in
                # the lock still gets a devDirs entry: it is inert (no plugin carries that name, so
                # lazy never looks it up), unknownDevPluginNames is what reports the typo, and
                # filtering it here would tie the dev-dir map to lock validation -- making devDirs
                # mean something different with and without a lock -- for no behavioral gain.
                ++ lib.optional (
                  builtins.attrNames locked.devDirs != [
                    "bare.nvim"
                    "dirred.nvim"
                    "tokyonight.nvim"
                    "typo.nvim"
                  ]
                ) "devDirs must hold exactly the devPlugins names plus the localPlugins keys"
                # The same statement without naming keys, so it keeps holding as the fixture grows:
                # nothing machine-specific out of plugins.json may ever reach a value here.
                ++ lib.optional (
                  !lib.all (lib.hasPrefix "~/proj/") (builtins.attrValues locked.devDirs)
                ) "every devDirs value must sit under devPath, whatever the lock recorded"
                ++ lib.optional (
                  locked.unknownDevPluginNames != [ "typo.nvim" ]
                ) "a devPlugins name in neither the lock nor localPlugins must be reported, and only that one"
                ++ lib.optional (
                  untouched.devDirs != { }
                ) "devDirs must be empty when nothing asked for a dev plugin"
                ++ lib.optional (
                  degraded.unknownDevPluginNames != [ ]
                ) "degraded mode has no lock to judge devPlugins names against, so it must report none"
                ++ lib.optional (
                  moduleDevDirs != { "tokyonight.nvim" = "~/proj/tokyonight.nvim"; }
                ) "the hm module must pass devPlugins / devPath through to makeEnv";
            in
            pkgs.runCommand "dev-plugins"
              {
                nativeBuildInputs = [ pkgs.neovim-unwrapped ];
              }
              (
                if failures == [ ] then
                  ''
                    export HOME=$TMPDIR

                    # The working tree really is a directory in the store, so the dev dir asserted
                    # on below is not merely a string that happens to match.
                    test -f ${devRoot}/tokyonight.nvim/lua/tokyonight-dev.lua

                    # What shipped is the function form, not a string. Guards against a revert to
                    # `path = farm` that would still pass every evaluation-level assertion above.
                    grep -qF 'dev_dirs[plugin.name]' ${plainEnv.bootstrap}

                    # With devPlugins: the named plugins resolve to their working trees (both the
                    # devPlugins one and the spec's own bare `dev = true`), everything else still
                    # to the farm. The driver additionally pins dirred.nvim to the `dir` its spec
                    # writes, proving lazy short-circuits past the dev_dirs entry devEnv gave it.
                    nvim --clean -l ${./tests/dev-path-test.lua} ${devEnv.bootstrap} \
                      ${devEnv.farm} ${devRoot}/tokyonight.nvim ${devEnv.farm}/plenary.nvim \
                      ${devRoot}/bare.nvim

                    # Without: every plugin dev.path decides resolves to <farm>/<name>, byte for
                    # byte what the old `path = farm` string produced. This is #26's "with no dev
                    # plugins, the generated bootstrap.lua is functionally identical to today's".
                    nvim --clean -l ${./tests/dev-path-test.lua} ${plainEnv.bootstrap} \
                      ${plainEnv.farm} ${plainEnv.farm}/tokyonight.nvim ${plainEnv.farm}/plenary.nvim \
                      ${plainEnv.farm}/bare.nvim

                    touch $out
                  ''
                else
                  ''
                    ${lib.concatMapStringsSep "\n" (f: "echo ${lib.escapeShellArg f} >&2") failures}
                    exit 1
                  ''
              );
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
