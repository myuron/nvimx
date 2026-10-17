# nix/build-registry: a shipped recipe must fix a plugin up with no user configuration,
# must lose to both per-user hatches, and must leave every other plugin on the generic
# path -- including when its entry is removed.
{
  pkgs,
  nvimxLib,
  blinkSrc,
  ...
}:
let
  inherit (pkgs) lib;
  # End to end: the fixture spec declares no build at all (as many real specs do),
  # so build/libfzf.so can only come from the registry entry.
  env = nvimxLib.makeEnv {
    package = pkgs.neovim-unwrapped;
    lockDir = ../fixtures/registry-plugins/nvimx-lock;
  };
  # Resolved against the real upstream tree (pkgs.fzf.src, already a dependency of the entry):
  # the entry checks the tree it is handed, and upstream bin/ already has other files in it.
  fzf = nvimxLib.resolvePlugin {
    name = "fzf";
    src = pkgs.fzf.src;
    build = {
      kind = "shell";
      cmd = "./install --bin";
    };
  };
  # nvim-treesitter: the entry must ignore the declared build, even one that would fail, so the
  # plugin never reaches the generic buildPhase (#36: its `make` cannot run in the sandbox).
  treesitterEntry = nvimxLib.resolvePlugin {
    name = "nvim-treesitter";
    src = ../fixtures/local-plugin;
    build = {
      kind = "shell";
      cmd = "exit 1";
    };
  };
  # blink.cmp: the one entry that *produces* a compiled artifact, so it is built for real from
  # blinkSrc (./lib.nix). The declared build is the one build-network.nix rejects.
  blinkEntry = nvimxLib.resolvePlugin {
    name = "blink.cmp";
    src = blinkSrc;
    build = {
      kind = "shell";
      cmd = "cargo build --release";
    };
  };
  blinkLib = "libblink_cmp_fuzzy${pkgs.stdenv.hostPlatform.extensions.sharedLibrary}";
  # The entry.s two documented refusals for a rev it cannot handle; they must stay refusals
  # rather than silently becoming a plain (and doomed) build.
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
  # The mechanism itself, against a stub registry so it does not depend on what is shipped
  # today. Compared by outPath, so nothing below is built.
  pname = "telescope-fzf-native.nvim";
  mkGeneric =
    n:
    nvimxLib.mkPluginDrv {
      name = n;
      src = ../fixtures/local-plugin;
      build = {
        kind = "none";
      };
    };
  resolve =
    n: extra:
    nvimxLib.resolvePlugin (
      {
        name = n;
        src = ../fixtures/local-plugin;
        build = {
          kind = "none";
        };
      }
      // extra
    );
  stubDrv = pkgs.runCommand "nvimx-registry-stub" { } "mkdir -p $out";
  stub.${pname} = _: stubDrv;
  # An entry gets its plugin plus the generic builder. Also fed to `overrides` below: the two
  # contracts are identical, so the same function must work in both positions.
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
      !(blinkRefuses ../fixtures/local-plugin)
    ) "blink.cmp without a Cargo.lock should be refused, not built"
    ++ lib.optional (
      !(blinkRefuses ../fixtures/cargo-git-lock)
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
)
