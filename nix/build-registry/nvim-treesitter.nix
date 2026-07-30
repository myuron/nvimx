# nvim-treesitter/nvim-treesitter: the declared build is ignored, unconditionally.
#
# The most common spec for this plugin is `build = { "make", ":TSUpdate" }` (or `build =
# ":TSUpdate"` alone). On the default branch (`main`), `make`'s Makefile has `.DEFAULT_GOAL :=
# all` with `all: lua query docs tests`, and *every* one of those targets fetches something
# (nvim nightly, emmylua, ts_query_ls, highlight-assertions, plentest via curl / git clone) before
# it does anything else -- so it fails in the sandbox every time, and the bare `make` string does
# not contain any of the tokens nix/lib/build-network.nix looks for, so evaluation would not catch
# it either; it would die deep in the build log. (The legacy `master` branch is harmless -- its
# `build` target is `echo "Do nothing"` -- but nvimx cannot tell which branch a given lock is
# tracking from the recorded build alone, so treat every rev the same way.)
#
# `:TSUpdate` cannot run in the sandbox regardless of branch (no network to fetch parsers with),
# and is already handled generically as an unrunnable excmd/step.
#
# nvimx does not need either of them: parsers are supplied by `programs.nvimx.treesitter.grammars`
# (nix/lib/treesitter.nix), which merges prebuilt grammars from nixpkgs into this same plugin
# *after* resolution. So the right treatment here is exactly the generic no-build path -- copy +
# helptags -- which also means this entry does not have to special-case which build shape the
# spec happens to declare.
#
# One consequence worth stating: an all-shell declaration such as `build = { "make" }` looks
# runnable to resolve.lua, so nothing warns at lock time and this entry drops it silently. That is
# the one shape where nvimx skips a build without saying so, and it is limited to this plugin,
# where running it could not have worked.
{
  name,
  src,
  mkPluginDrv,
  ...
}:
mkPluginDrv {
  inherit name src;
  build = {
    kind = "none";
  };
}
