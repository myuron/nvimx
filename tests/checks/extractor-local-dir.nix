# #47: a spec plugin with an explicit `dir` and no `dev` is local to lazy (Meta:_rebuild and
# get_target short-circuit on it), so extract.lua must route it to localPlugins -- not to a
# remote with a flake input and, since #42, a defaults.version that #23 would try to resolve.
# Starts from a real config because lazy fills in plugin.dir for *every* plugin
# (meta.lua:238), so the naive `dir = p.dir` fix would silently empty `plugins`.
# No pkgs.git and no --lazy, so "resolve exits 0" is itself the assertion (as in
# checks.resolve-import-lazy-lock): filing any local plugin as remote fails the resolve.
# The dev/dir consumer side is checks.dev-plugins' (#26).
{
  pkgs,
  lazy-nvim,
  ...
}:
pkgs.runCommand "extractor-local-dir" {
  nativeBuildInputs = [
    pkgs.neovim-unwrapped
    pkgs.jq
  ];
  localDirConfig = ../fixtures/local-dir-config;
  lazy = lazy-nvim;
  extractLua = ../../lua/nvimx/extract.lua;
  lua = ../../lua/nvimx;
} "source ${./scripts/extractor-local-dir.sh}"
