# Pure unit test of lua/nvimx/version.lua (#23): no git, no jq, no network, and no
# fixture files -- tests/semver-select-test.lua carries its own fixed tag sets inline.
# Drives the real lua/lazy/manage/semver.lua from the seed, the same way resolve.lua
# does, so a change in lazy's own semver behavior shows up here (like extractor-snapshot
# does for the extractor).
{
  pkgs,
  lazy-nvim,
  ...
}:
pkgs.runCommand "semver-select"
  {
    nativeBuildInputs = [ pkgs.neovim-unwrapped ];
  }
  ''
    nvim -l ${../semver-select-test.lua} ${../../lua/nvimx/version.lua} \
      ${lazy-nvim}/lua/lazy/manage/semver.lua
    touch $out
  ''
