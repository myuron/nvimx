# Offline coverage of `--import-lazy-lock` (#25). Deliberately without pkgs.git:
# resolve.lua's semver path fails outright when git is not on PATH, so "the resolve
# exits 0" is itself the proof that a seeded resolvedRef closed #23's gate and no
# ls-remote was ever attempted. Every fixture url is unreachable on top of that, for the
# same reason. --lazy is never passed either, which is the other half of the same
# statement: a migrating config needs neither.
{
  pkgs,
  nvimxLib,
  lazy-nvim,
  ...
}:
pkgs.runCommand "resolve-import-lazy-lock" {
  nativeBuildInputs = [
    pkgs.neovim-unwrapped
    pkgs.jq
    nvimxLib.lockApp
  ];
  lua = ../../lua/nvimx;
  fx = ../fixtures/import-lazy-lock;
  basicConfig = ../fixtures/basic-config;
  lazy = lazy-nvim;
  extractLua = ../../lua/nvimx/extract.lua;
} "source ${./scripts/resolve-import-lazy-lock.sh}"
