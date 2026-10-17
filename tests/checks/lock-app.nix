# The lock app itself, end to end (#71). Every other check stops short of the `nix` calls
# in nix/lib/lock-app.nix -- recursive nix cannot run in a build -- so until this check
# nothing pinned what those calls are handed, what the EXIT trap prints, or anything
# after them. `nix` is not in the app's runtimeInputs: it is resolved from the caller's
# PATH, and the sandbox has no real one, so a stub named `nix` stands in. The stub
# records argv and cwd, exits with whatever NVIMX_STUB_FAIL says when told to fail, and
# otherwise drops a fixture flake.lock where the real one would write
# it -- succeeding alone is not enough, because the convergence pass reads
# "$out/flake.lock" right after. What this cannot prove is that the real nix accepts
# `path:.`; that is the plan's §6.4 manual verification.
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
