# The lock app itself, end to end (#71): what nix/lib/lock-app.nix hands its `nix` calls, what
# the EXIT trap prints, and everything after them -- no other check gets past those calls,
# since recursive nix cannot run in a build. `nix` comes from the caller's PATH, so a stub
# stands in: it answers the seed lookup (`eval`, #32) with nvimx's own lazy.nvim (not recorded
# in argv, so it is not counted as a call), records argv and cwd, fails on the NVIMX_STUB_FAIL_AT-th
# call (default 1) when NVIMX_STUB_FAIL is set (#81: the later call sites need a failure of their
# own), can corrupt the update snapshot (NVIMX_STUB_CORRUPT_BEFORE) or wait for a pipe reader to
# be gone before failing (NVIMX_STUB_WAIT_FOR), and otherwise writes a fixture
# flake.lock (the convergence pass reads it right after). That the real nix accepts `path:.`
# stays a manual check.
{
  pkgs,
  nvimxLib,
  lazy-nvim,
  ...
}:
let
  stubNix = pkgs.writeShellScriptBin "nix" ''
    if [ "$1" = eval ]; then
      printf '%s' "$NVIMX_STUB_SEED"
      exit 0
    fi
    printf '%s\n' "$*" >> "$NVIMX_STUB_ARGV"
    pwd >> "$NVIMX_STUB_CWD"
    # Test-only hook for step 7's summary failure: nothing in nvimx-lock reads the snapshot
    # but update-summary.lua, so corrupting it fails exactly that step.
    if [ -n "''${NVIMX_STUB_CORRUPT_BEFORE:-}" ]; then
      for f in "$TMPDIR"/tmp.*/flake.lock.before; do
        if [ -e "$f" ]; then echo 'not json' > "$f"; fi
      done
    fi
    calls=$(wc -l < "$NVIMX_STUB_ARGV")
    if [ -n "''${NVIMX_STUB_FAIL:-}" ] && [ "$calls" -eq "''${NVIMX_STUB_FAIL_AT:-1}" ]; then
      echo "error: stub nix was told to fail" >&2
      # Step 4f: hold the exit until the reader has closed the pipe, so the trap is
      # guaranteed to be the first writer that hits it.
      if [ -n "''${NVIMX_STUB_WAIT_FOR:-}" ]; then
        for _ in $(seq 100); do
          if [ -e "$NVIMX_STUB_WAIT_FOR" ]; then break; fi
          sleep 0.1
        done
      fi
      exit "$NVIMX_STUB_FAIL"
    fi
    cp "$NVIMX_STUB_LOCK" flake.lock
    chmod u+w flake.lock
  '';
in
pkgs.runCommand "lock-app" {
  nativeBuildInputs = [
    pkgs.git
    pkgs.jq
    nvimxLib.lockApp
    stubNix
  ];
  fx = ../fixtures/basic-config;
  NVIMX_STUB_SEED = "${lazy-nvim}";
} "source ${./scripts/lock-app.sh}"
