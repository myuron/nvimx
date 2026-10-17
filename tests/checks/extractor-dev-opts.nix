# #74: the spec's own lazy dev.patterns / dev.path / dev.fallback are overridden by nvimx at
# runtime, so extract.lua turns them into a notif (resolve.lua then prints it as a warning and
# records it in plugins.json). Three fixtures because dev.fallback = true with a missing checkout
# turns a matched plugin back into a remote that resolve could not lock offline. The no-dev-opts
# negative case is already pinned by checks.extractor-snapshot (basic-config's golden has notifs).
{
  pkgs,
  lazy-nvim,
  ...
}:
pkgs.runCommand "extractor-dev-opts" {
  nativeBuildInputs = [
    pkgs.neovim-unwrapped
    pkgs.jq
  ];
  devOptsConfig = ../fixtures/dev-opts-config;
  devOptsFallbackConfig = ../fixtures/dev-opts-fallback-config;
  devOptsDefaultsConfig = ../fixtures/dev-opts-defaults-config;
  lazy = lazy-nvim;
  extractLua = ../../lua/nvimx/extract.lua;
  lua = ../../lua/nvimx;
} "source ${./scripts/extractor-dev-opts.sh}"
