# Offline coverage of update-summary.lua's --json / --plain output (#77): a bot consumes this
# schema, so it is pinned byte for byte against goldens. neovim-unwrapped + jq only.
{
  pkgs,
  ...
}:
pkgs.runCommand "update-summary-json" {
  nativeBuildInputs = [
    pkgs.neovim-unwrapped
    pkgs.jq
  ];
  lua = ../../lua/nvimx;
  fx = ../fixtures/update;
  lsfx = ../fixtures/lazy-self;
} "source ${./scripts/update-summary-json.sh}"
