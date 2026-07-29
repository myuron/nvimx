# nvimx-lock: a script that runs extract → resolve → flake generation → nix flake lock in one go.
# Locking is an online operation (the build is fully pure and offline).
# TODO (Phase 6): --update [name...], --import-lazy-lock
{ pkgs, lazyNvimSeed }:
let
  luaDir = ../../lua/nvimx;
in
pkgs.writeShellApplication {
  name = "nvimx-lock";
  runtimeInputs = [
    pkgs.coreutils
    pkgs.diffutils # cmp, for the convergence pass below
    pkgs.neovim-unwrapped
    pkgs.nixfmt-rfc-style
  ];
  text = ''
    usage() {
      echo "usage: nvimx-lock --config <configDir> --out <lockDir>" >&2
      exit 2
    }

    config=""
    out=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --config)
          config="$2"
          shift 2
          ;;
        --out)
          out="$2"
          shift 2
          ;;
        *)
          usage
          ;;
      esac
    done
    [ -n "$config" ] && [ -n "$out" ] || usage
    config=$(realpath "$config")
    mkdir -p "$out"
    out=$(realpath "$out")

    # TODO: if the existing lock pins lazy.nvim, use that as the seed (to avoid skew).
    # For now nvimx's own flake input is always used as the seed.
    seed="${lazyNvimSeed}"

    sandbox=$(mktemp -d)
    # resolve.lua's warnings are held back until the very end (see the resolve step below).
    # Print them from the trap when a later step failed before we got there -- otherwise
    # removing the sandbox would swallow them entirely (#22).
    resolve_log_shown=0
    cleanup() {
      if [ "$resolve_log_shown" -eq 0 ] && [ -s "$sandbox/resolve.log" ]; then
        cat "$sandbox/resolve.log" >&2
      fi
      rm -rf "$sandbox"
    }
    trap cleanup EXIT
    mkdir -p "$sandbox/config" "$sandbox/data/nvim/lazy" "$sandbox/state" "$sandbox/cache"
    ln -sfT "$config" "$sandbox/config/nvim"
    ln -sfT "$seed" "$sandbox/data/nvim/lazy/lazy.nvim"

    echo "nvimx-lock: extracting spec from $config" >&2
    # extract.lua exits 0 when it captures setup, and exits 1 from VimEnter when it does not.
    # The timeout plus closing stdin is a safety net for unexpected cases where it still
    # stays in the event loop (#3).
    env \
      XDG_CONFIG_HOME="$sandbox/config" \
      XDG_DATA_HOME="$sandbox/data" \
      XDG_STATE_HOME="$sandbox/state" \
      XDG_CACHE_HOME="$sandbox/cache" \
      NVIMX_LAZY_SEED="$seed" \
      NVIMX_OUT="$sandbox/raw-spec.json" \
      timeout 120 nvim --headless --cmd "luafile ${luaDir}/extract.lua" < /dev/null

    echo "nvimx-lock: resolving plugins" >&2
    # Whatever the previous lock decided is an input to this one: resolve.lua carries already
    # resolved refs forward and freezes `pin = true` plugins onto the rev in flake.lock. Deciding
    # whether that state exists is this script's job, not resolve.lua's -- it only reads what it
    # is handed. --prev may point at the output path because resolve.lua reads before it writes.
    resolve_args=()
    if [ -f "$out/plugins.json" ]; then
      resolve_args+=(--prev "$out/plugins.json")
    fi
    if [ -f "$out/flake.lock" ]; then
      resolve_args+=(--lock "$out/flake.lock")
    fi
    # resolve.lua reports non-fatal problems (a build nvimx cannot run, an unresolved version
    # constraint) on stderr. They are held back and re-printed after `nix flake lock`, whose
    # output is long enough to scroll them out of sight otherwise (#22).
    # A Lua error must stay fatal, so surface the log and keep the exit code.
    rc=0
    # ''${a[@]+"''${a[@]}"}: an empty array is an unset variable under `set -u`
    nvim -l "${luaDir}/resolve.lua" "$sandbox/raw-spec.json" "$out/plugins.json" \
      ''${resolve_args[@]+"''${resolve_args[@]}"} \
      2> "$sandbox/resolve.log" || rc=$?
    if [ "$rc" -ne 0 ]; then
      cat "$sandbox/resolve.log" >&2
      resolve_log_shown=1
      exit "$rc"
    fi

    echo "nvimx-lock: generating lock flake" >&2
    nvim -l "${luaDir}/genflake.lua" "$out/plugins.json" "$out/flake.nix"
    nixfmt "$out/flake.nix"

    echo "nvimx-lock: pinning with nix flake lock" >&2
    (cd "$out" && nix flake lock)

    # A plugin pinned for the first time (or right after its spec changed) has no usable rev in
    # flake.lock when the resolve above runs, so its freeze had to be deferred. Resolve once more
    # now that flake.lock has caught up, and redo the flake only if that actually changed
    # something. One retry is enough: the third resolve would read back the same flake.lock and
    # produce the same file, so this is already the fixed point.
    # The log is overwritten on purpose -- the second run repeats the same warnings verbatim.
    rc=0
    nvim -l "${luaDir}/resolve.lua" "$sandbox/raw-spec.json" "$sandbox/plugins2.json" \
      --prev "$out/plugins.json" --lock "$out/flake.lock" \
      2> "$sandbox/resolve.log" || rc=$?
    if [ "$rc" -ne 0 ]; then
      cat "$sandbox/resolve.log" >&2
      resolve_log_shown=1
      exit "$rc"
    fi
    if ! cmp -s "$sandbox/plugins2.json" "$out/plugins.json"; then
      echo "nvimx-lock: freezing pinned plugins" >&2
      mv "$sandbox/plugins2.json" "$out/plugins.json"
      nvim -l "${luaDir}/genflake.lua" "$out/plugins.json" "$out/flake.nix"
      nixfmt "$out/flake.nix"
      (cd "$out" && nix flake lock)
    fi

    if [ -s "$sandbox/resolve.log" ]; then
      cat "$sandbox/resolve.log" >&2
    fi
    resolve_log_shown=1

    echo "nvimx-lock: done. commit $out/{plugins.json,flake.nix,flake.lock}" >&2
  '';
}
