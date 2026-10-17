# env.check (#79): start the exact wrapped neovim headless, offline, with the user's config,
# load every plugin in the farm and fail on any startup error. The driver is
# lua/nvimx/startup-check.lua; this file is the sandbox around it.
#
# The runner is exposed as passthru.runner so tests can run the very same script and assert
# that it fails: building the check only ever shows that it passes.
{ pkgs }:
{
  env,
  configDir,
  ignoreErrors ? [ ],
}:
let
  inherit (pkgs) lib;
  # A path literal is copied to the store under a stable name; a derivation (writeTextDir, ...)
  # passes through as its store path. An absolute string is not accepted: in pure mode Nix
  # refuses it at evaluation with its own clear error, rather than a confusing cp failure inside
  # the sandbox.
  src =
    if builtins.hasContext (toString configDir) then
      toString configDir
    else
      builtins.path {
        path = configDir;
        name = "nvimx-check-config";
      };

  runner = pkgs.writeShellScript "nvimx-check" ''
    set -eu
    tmp=$(mktemp -d)
    export HOME="$tmp/home" XDG_CONFIG_HOME="$tmp/config" XDG_DATA_HOME="$tmp/data" \
      XDG_STATE_HOME="$tmp/state" XDG_CACHE_HOME="$tmp/cache"
    mkdir -p "$HOME" "$XDG_CONFIG_HOME" "$XDG_DATA_HOME/nvim/lazy" "$XDG_STATE_HOME" "$XDG_CACHE_HOME"
    # A writable copy: the store copy is read-only and plugins may write into their config dir.
    cp -R ${src} "$XDG_CONFIG_HOME/nvim"
    chmod -R u+w "$XDG_CONFIG_HOME/nvim"
    # What the hm module's xdg.dataFile does, so the standard lazy bootstrap snippet never clones.
    ln -s ${env.farm}/lazy.nvim "$XDG_DATA_HOME/nvim/lazy/lazy.nvim"

    # rc is captured explicitly so that set -e does not abort before it is mapped below.
    # -k: a busy-looping config ignores SIGTERM, so it needs a SIGKILL behind it.
    rc=0
    NVIMX_CHECK=1 \
      NVIMX_CHECK_FARM=${env.farm} \
      NVIMX_CHECK_IGNORE=${lib.escapeShellArg (builtins.toJSON ignoreErrors)} \
      NVIMX_CHECK_SENTINEL="$tmp/passed" \
      ${pkgs.coreutils}/bin/timeout -k 10 120 ${env.wrapped}/bin/nvim --headless \
      --cmd "luafile ${../../lua/nvimx/startup-check.lua}" < /dev/null || rc=$?

    case $rc in
      124 | 137)
        echo "[nvimx] check: timed out after 120s" >&2
        exit 1
        ;;
      0)
        if [ ! -e "$tmp/passed" ]; then
          echo "[nvimx] check: neovim exited before the check finished (something ran :qa / :cq during startup)" >&2
          exit 1
        fi
        ;;
      *)
        # the driver already printed why
        exit "$rc"
        ;;
    esac
  '';
in
pkgs.runCommand "nvimx-check" { passthru = { inherit runner; }; } ''
  ${runner}
  touch $out
''
