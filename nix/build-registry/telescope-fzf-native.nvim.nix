# telescope-fzf-native.nvim: build/libfzf.so, a single `cc -shared src/fzf.c`.
#
# The declared build is ignored on purpose. Upstream documents several ways to produce the very
# same build/libfzf.so -- `make`, a two-step cmake invocation, or nothing at all when the spec
# simply forgot the build field -- and the Makefile is the one that needs no generator and no
# network. nixpkgs pins the same `buildPhase = "make"` for its own package.
#
# The Makefile picks the target name from $(OS), so it produces libfzf.so on darwin too, which is
# what the plugin's ffi loader looks for.
{
  name,
  src,
  mkPluginDrv,
  ...
}:
mkPluginDrv {
  inherit name src;
  build = {
    kind = "shell";
    cmd = "make";
  };
}
