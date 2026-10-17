# Offline, end-to-end coverage of semver resolution (#23): git ls-remote against local
# repos this check creates itself, so no network is needed and no fixture ever names a
# real, reachable remote. Destructive steps (removing a repo to prove a carried ref
# needs no further network access) are kept last, since several earlier steps still need
# those repos alive.
{
  pkgs,
  lazy-nvim,
  mkTagRepoSh,
  ...
}:
pkgs.runCommand "resolve-semver" {
  nativeBuildInputs = [
    pkgs.neovim-unwrapped
    pkgs.jq
    pkgs.git
  ];
  lua = ../../lua/nvimx;
  fx = ../fixtures/semver;
  lazy = lazy-nvim;
  mergeConfig = ../fixtures/merge-config;
} (mkTagRepoSh + "source ${./scripts/resolve-semver.sh}")
