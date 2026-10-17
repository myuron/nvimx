# Merging with the previous lock is what makes plugins.json a lock rather than a report:
# a decision already made must survive the next run, and `pin = true` must freeze (#18).
# resolve.lua is the only stage that carries state, so driving it directly covers the
# whole contract offline -- the `nix flake lock` around it needs the network and is
# stubbed out here by a hand-written tests/fixtures/merge/flake.lock.
{
  pkgs,
  lazy-nvim,
  ...
}:
pkgs.runCommand "resolve-merge" {
  nativeBuildInputs = [
    pkgs.neovim-unwrapped
    pkgs.jq
  ];
  lua = ../../lua/nvimx;
  fx = ../fixtures/merge;
  lazy = lazy-nvim;
  mergeConfig = ../fixtures/merge-config;
  extractLua = ../../lua/nvimx/extract.lua;
} "source ${./scripts/resolve-merge.sh}"
