# The lock app itself, end to end (#71): what nix/lib/lock-app.nix hands its `nix` calls, what
# the EXIT trap prints, and everything after them -- no other check gets past those calls,
# since recursive nix cannot run in a build. `nix` comes from the caller's PATH, so a stub
# stands in: it records argv and cwd, fails on NVIMX_STUB_FAIL, and otherwise writes a fixture
# flake.lock (the convergence pass reads it right after). That the real nix accepts `path:.`
# stays a manual check.
{
  pkgs,
  nvimxLib,
  ...
}:
let
  stubNix = pkgs.writeShellScriptBin "nix" ''
    printf '%s\n' "$*" >> "$NVIMX_STUB_ARGV"
    pwd >> "$NVIMX_STUB_CWD"
    if [ -n "''${NVIMX_STUB_FAIL:-}" ]; then
      echo "error: stub nix was told to fail" >&2
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
} "source ${./scripts/lock-app.sh}"
