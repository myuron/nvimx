# nvimx-lock: a script that runs extract → resolve → flake generation → nix flake lock in one go.
# Locking is an online operation (the build is fully pure and offline).
# TODO (Phase 6): --import-lazy-lock
{ pkgs, lazyNvimSeed }:
let
  luaDir = ../../lua/nvimx;
in
pkgs.writeShellApplication {
  name = "nvimx-lock";
  runtimeInputs = [
    pkgs.coreutils
    pkgs.diffutils # cmp, for the convergence pass below
    # git ls-remote is how resolve.lua resolves a `version` constraint (#23): it is an external
    # git invocation, not nix's built-in fetcher, so nvimx-lock has to guarantee it is on PATH
    # itself rather than betting on the user's environment happening to have one (and one new
    # enough to support `git ls-remote --refs`).
    pkgs.git
    pkgs.neovim-unwrapped
    pkgs.nixfmt-rfc-style
  ];
  text = ''
    usage() {
      echo "usage: nvimx-lock --config <configDir> --out <lockDir> [--update [name...]]" >&2
      exit 2
    }

    config=""
    out=""
    update_mode=0
    update_all=0
    update_names=()
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
        --update)
          update_mode=1
          shift
          got=0
          while [ $# -gt 0 ] && [ "''${1#--}" = "$1" ]; do
            update_names+=("$1")
            got=1
            shift
          done
          # A --update that took no names at all is the "update everything" marker. It has to be
          # recorded separately: several --update occurrences collapse into one names array, so
          # the marker cannot be recovered from the array's length afterwards.
          [ "$got" -eq 1 ] || update_all=1
          ;;
        *)
          usage
          ;;
      esac
    done
    # A bare --update and a named --update <name> must not both survive to resolve.lua: its own
    # parser reconstructs "update everything" from whether any name at all was collected, and a
    # mix like `--update --update foo` would silently collapse into "just foo" there. Rejecting
    # the combination here, before that reconstruction happens, is the only place it can still be
    # told apart from a plain named update (#24's plan review caught this).
    if [ "$update_all" -eq 1 ] && [ "''${#update_names[@]}" -gt 0 ]; then
      echo "nvimx-lock: --update takes either no names (update everything) or names, not both" >&2
      usage
    fi
    [ -n "$config" ] && [ -n "$out" ] || usage
    # --update is a lock's forward motion, not its beginning: mixing it with a first-ever lock
    # would leave resolve.lua with no previous decisions to force away from in the first place.
    # Checked against the raw --out argument, before `mkdir -p "$out"` / `realpath "$out"` below,
    # so that a run that fails this guard creates nothing -- not even an empty output directory.
    if [ "$update_mode" -eq 1 ]; then
      if [ ! -f "$out/plugins.json" ] || [ ! -f "$out/flake.lock" ]; then
        echo "nvimx-lock: no existing lock to update; run nvimx-lock first" >&2
        exit 2
      fi
    fi
    config=$(realpath "$config")
    mkdir -p "$out"
    out=$(realpath "$out")

    # TODO: if the existing lock pins lazy.nvim, use that as the seed (to avoid skew).
    # For now nvimx's own flake input is always used as the seed.
    seed="${lazyNvimSeed}"

    sandbox=$(mktemp -d)
    # --update's summary (below) is a before/after diff, so the "before" half has to be snapshot
    # ahead of any of the steps that are about to move it.
    if [ "$update_mode" -eq 1 ]; then
      cp "$out/flake.lock" "$sandbox/flake.lock.before"
      cp "$out/plugins.json" "$sandbox/plugins.json.before"
    fi
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
    # --update [name...] (#24): update_all cannot be recovered from update_names' length (see the
    # parser above), so it is looked at directly here too, rather than re-deriving the mode.
    if [ "$update_mode" -eq 1 ]; then
      if [ "$update_all" -eq 1 ]; then
        resolve_args+=(--update)
      else
        for name in "''${update_names[@]}"; do
          resolve_args+=(--update "$name")
        done
      fi
      resolve_args+=(--update-plan "$sandbox/update-plan.txt")
    fi
    # resolve.lua reports non-fatal problems (a build nvimx cannot run, a `defaults.version`
    # constraint no tag on some plugin's remote could satisfy) on stderr. They are held back and
    # re-printed after `nix flake lock`, whose output is long enough to scroll them out of sight
    # otherwise (#22). An explicit `version` that cannot be satisfied is fatal instead (#23).
    # A Lua error must stay fatal, so surface the log and keep the exit code.
    rc=0
    # ''${a[@]+"''${a[@]}"}: an empty array is an unset variable under `set -u`
    nvim -l "${luaDir}/resolve.lua" "$sandbox/raw-spec.json" "$out/plugins.json" \
      --lazy "$seed" \
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

    # --update (#24): the plan resolve.lua wrote above is exactly the inputs whose previous
    # decision was force-discarded, so this is what actually walks them forward -- `nix flake
    # lock` just ran above and cannot move an input whose URL did not change (a branch/tag
    # tracker whose ref carries no rev). `xargs` is deliberately not used here: it comes from
    # findutils, which is not in runtimeInputs (only coreutils is), so a plain `mapfile` reads
    # the plan instead.
    if [ "$update_mode" -eq 1 ]; then
      mapfile -t update_inputs < "$sandbox/update-plan.txt"
      if [ "''${#update_inputs[@]}" -gt 0 ]; then
        echo "nvimx-lock: updating ''${#update_inputs[@]} input(s) with nix flake update" >&2
        (cd "$out" && nix flake update "''${update_inputs[@]}")
      fi
    fi

    # A plugin pinned for the first time (or right after its spec changed) has no usable rev in
    # flake.lock when the resolve above runs, so its freeze had to be deferred. Resolve once more
    # now that flake.lock has caught up, and redo the flake only if that actually changed
    # something. One retry is enough: the third resolve would read back the same flake.lock and
    # produce the same file, so this is already the fixed point.
    # The log is overwritten on purpose: only this run's warnings are shown. resolve.lua is
    # written so that the two runs report the same set of problems -- in particular a `pin` that
    # only freezes here still warns about an unvalidated `version` on the first run, and a
    # `defaults.version` fallback still has nothing to freeze onto and so is re-queried and
    # re-reported here too (#23) -- so nothing a user needs is lost with the log that gets
    # replaced. A fallback's resolvedRef stays null rather than recording that it fell back, which
    # is exactly what makes the second run's report line up with the first one.
    # One exception: a fallback on a `pin = true` plugin does get something to freeze onto here,
    # so its resolvedRef stops being null and the fallback line drops out of the second run. The
    # "pinned; version constraint is not validated" warning takes its place and still says the
    # constraint did not decide the rev, so the user is not left thinking it did.
    # Deliberately not passed here: any of the --update flags. This second resolve's whole job is
    # to freeze onto whatever `nix flake lock` (and, in --update mode, `nix flake update` above)
    # just settled on -- passing --update again would force[] the same names right back to null
    # and the two passes would never converge. #25's --import-lazy-lock will need this same
    # exclusion for its own flag if it ever restructures resolve_args into something both resolve
    # calls share.
    rc=0
    nvim -l "${luaDir}/resolve.lua" "$sandbox/raw-spec.json" "$sandbox/plugins2.json" \
      --prev "$out/plugins.json" --lock "$out/flake.lock" --lazy "$seed" \
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

    # update-summary.lua's own failure is deliberately left fatal (not downgraded to a warning,
    # #24): every lock file above is already written by this point, so a non-zero exit here is a
    # bug in the summary itself, not a failed lock -- but letting it fail loudly is how that bug
    # gets noticed instead of silently going unreported. Re-running nvimx-lock afterwards is safe
    # either way: the lock is already done, and a second --update run just reports "no plugins
    # updated".
    if [ "$update_mode" -eq 1 ]; then
      nvim -l "${luaDir}/update-summary.lua" \
        "$sandbox/plugins.json.before" "$out/plugins.json" \
        "$sandbox/flake.lock.before" "$out/flake.lock" \
        ''${update_names[@]+"''${update_names[@]}"}
    fi

    echo "nvimx-lock: done. commit $out/{plugins.json,flake.nix,flake.lock}" >&2
  '';
}
