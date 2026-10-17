# The spec-field matrix, end to end but split in two: raw-spec -> resolve here, and
# plugins.json -> genflake in checks.genflake-golden below. The two meet on one file --
# tests/fixtures/spec-matrix/golden/matrix.plugins.json is this check's output and that
# one's input -- so "resolve's output turns into that flake" still holds transitively,
# while a red check names which stage broke (#29).
# Fully offline: every url here is unreachable except versioned.nvim's, which is
# rewritten to a local git repo this check creates itself (the same mkTagRepoSh
# checks.resolve-semver uses) and rewritten back afterwards, so the golden never records
# a build-directory path. URL *shapes* are checks.resolve-sources' matrix (#28), not
# this one's -- there is exactly one non-GitHub url here.
{
  pkgs,
  lazy-nvim,
  mkTagRepoSh,
  ...
}:
pkgs.runCommand "resolve-golden" {
  nativeBuildInputs = [
    pkgs.neovim-unwrapped
    pkgs.jq
    pkgs.git
  ];
  lua = ../../lua/nvimx;
  fx = ../fixtures/spec-matrix;
  lazy = lazy-nvim;
} (mkTagRepoSh + "source ${./scripts/resolve-golden.sh}")
