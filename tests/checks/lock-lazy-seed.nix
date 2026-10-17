# Which lazy.nvim nvimx-lock extracts against (#32): the one flake.lock pins -- what the built
# neovim loads -- not always nvimx's own input. Two layers, because recursive nix cannot run in a
# build: the `nix eval` expression that reads the pin is evaluated for real here, at check
# evaluation time (like lib.nix's blinkSrc), while the CLI around it runs against a stub `nix`, as
# in checks.lock-app. Each seed is a copy of lazy.nvim carrying a marker the fixture configs turn
# into a plugin name, so plugins.json shows which seed an extraction really ran against.
{
  pkgs,
  nvimxLib,
  lazy-nvim,
  ...
}:
let
  seedOf =
    lockDir:
    import ../../nix/lib/locked-lazy-seed.nix {
      inherit lockDir;
      sources = ../../nix/lib/sources.nix;
    };
  # Compared against a literal fetchTree rather than `lazy-nvim`, so bumping nvimx's own input
  # never breaks this. The rev is the one basic-config's fixture flake.lock pins.
  fixtureLazy = builtins.fetchTree {
    type = "github";
    owner = "folke";
    repo = "lazy.nvim";
    rev = "306a05526ada86a7b30af95c5cc81ffba93fef97";
    narHash = "sha256-5A4kducPwKb5fKX4oSUFvo898P0dqfsqqLxFaXBsbQY=";
  };
  # lazy.nvim plus a marker file (read with io.open) and a same-size Lua module (read through
  # vim.loader, step 2b): a vim.loader cache keyed by path, size and mtime cannot tell them apart.
  mkSeed =
    v:
    pkgs.runCommand "lazy-seed-${v}" { } ''
      cp -r ${lazy-nvim} $out
      chmod -R u+w $out
      echo ${v} > $out/NVIMX_SEED_MARKER
      printf 'return "%s"' ${v} > $out/lua/nvimx_seed_marker.lua
    '';
  seedA = mkSeed "a";
  seedB = mkSeed "b";
  seedX = mkSeed "x";
  # The pre-lock seed of step 2b is seedX instead of nvimx's own input.
  lockAppX = import ../../nix/lib/lock-app.nix {
    inherit pkgs;
    lazyNvimSeed = seedX;
  };
  # `eval` is the seed lookup: it answers with NVIMX_STUB_SEED until a `flake update` has run and
  # NVIMX_STUB_SEED_AFTER from then on, and fails first on NVIMX_STUB_FAIL. Anything else is
  # recorded and writes a fixture flake.lock, as lock-app's stub does.
  stubNix = pkgs.writeShellScriptBin "nix" ''
    case "$1" in
      eval)
        printf '%s\n' "$NVIMX_LOCK_DIR" >> "$NVIMX_STUB_EVAL"
        if [ -n "''${NVIMX_STUB_FAIL:-}" ]; then
          echo "error: stub nix was told to fail" >&2
          exit "$NVIMX_STUB_FAIL"
        fi
        if [ -e "$NVIMX_STUB_STATE/updated" ]; then
          printf '%s' "$NVIMX_STUB_SEED_AFTER"
        else
          printf '%s' "$NVIMX_STUB_SEED"
        fi
        ;;
      *)
        printf '%s\n' "$*" >> "$NVIMX_STUB_ARGV"
        if [ "$2" = update ]; then touch "$NVIMX_STUB_STATE/updated"; fi
        cp "$NVIMX_STUB_LOCK" flake.lock
        chmod u+w flake.lock
        ;;
    esac
  '';
in
pkgs.runCommand "lock-lazy-seed" {
  nativeBuildInputs = [
    pkgs.jq
    nvimxLib.lockApp
    stubNix
  ];
  fx = ../fixtures/basic-config;
  seeds = ../fixtures/lazy-seed;
  inherit lockAppX;
  lazyInput = "${lazy-nvim}";
  seedA = "${seedA}";
  seedB = "${seedB}";
  pinned = seedOf ../fixtures/basic-config/nvimx-lock;
  unpinned = seedOf ../fixtures/lazy-seed/no-lazy;
  fixtureLazy = "${fixtureLazy}";
} "source ${./scripts/lock-lazy-seed.sh}"
