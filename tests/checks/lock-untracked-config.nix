# nvimx-lock's warning about config files git does not track (#33). Extraction reads the work
# tree, so an untracked spec file is locked just the same; but home-manager deploys configDir
# from the flake source and a git flake only contains indexed files, so the deployed config would
# lack it. Measured with nix on a git flake: committed-then-modified files are visible (with
# work-tree contents), new-but-staged files are visible, untracked and gitignored files are not --
# hence modified tracked files are deliberately NOT flagged (step 3 guards that).
# The stub `nix` is the one from checks.lock-app, duplicated rather than shared so that
# lock-app.nix stays untouched while other lock PRs land.
{
  pkgs,
  nvimxLib,
  ...
}:
let
  stubNix = pkgs.writeShellScriptBin "nix" ''
    cp "$NVIMX_STUB_LOCK" flake.lock
    chmod u+w flake.lock
  '';
in
pkgs.runCommand "lock-untracked-config" {
  nativeBuildInputs = [
    pkgs.git
    pkgs.jq
    nvimxLib.lockApp
    stubNix
  ];
  fx = ../fixtures/basic-config;
} "source ${./scripts/lock-untracked-config.sh}"
