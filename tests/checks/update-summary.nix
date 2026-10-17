# Offline coverage of update-summary.lua (#24): a pure text transform over four JSON
# snapshots, so this needs nothing beyond neovim-unwrapped -- no git, no `nix flake *`.
{
  pkgs,
  ...
}:
pkgs.runCommand "update-summary" {
  # jq is only for this check's own fixture tweaking (the tag-pairing case below);
  # update-summary.lua itself needs nothing beyond neovim-unwrapped.
  nativeBuildInputs = [
    pkgs.neovim-unwrapped
    pkgs.jq
  ];
  lua = ../../lua/nvimx;
  fx = ../fixtures/update;
  lsfx = ../fixtures/lazy-self;
} "source ${./scripts/update-summary.sh}"
