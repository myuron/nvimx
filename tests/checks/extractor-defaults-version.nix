# `defaults.version` is a config-wide opts key that lazy only ever applies at
# git-operation time (lua/lazy/manage/git.lua:141), so extract.lua has to materialize it
# per plugin or the constraint never reaches plugins.json and the config silently tracks
# HEAD (#42). Self-contained in the store like extractor-snapshot, so no network is needed.
{
  pkgs,
  lazy-nvim,
  mkTagRepoSh,
  ...
}:
pkgs.runCommand "extractor-defaults-version" {
  nativeBuildInputs = [
    pkgs.neovim-unwrapped
    pkgs.jq
    pkgs.git
  ];
  lazy = lazy-nvim;
  extractLua = ../../lua/nvimx/extract.lua;
  defaultsConfig = ../fixtures/defaults-version-config;
  lua = ../../lua/nvimx;
  defaultsFalseConfig = ../fixtures/defaults-version-false-config;
} (mkTagRepoSh + "source ${./scripts/extractor-defaults-version.sh}")
