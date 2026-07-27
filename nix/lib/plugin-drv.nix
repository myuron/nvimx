# 1 plugin = 1 derivation.
# Default: cp, plus helptags generation if doc/ exists.
# TODO (Phase 5): running build (shell), build-registry, overrides, nixpkgsFallback
{ pkgs }:
{ name, src }:
pkgs.runCommand "nvimx-plugin-${name}"
  {
    nativeBuildInputs = [ pkgs.neovim-unwrapped ];
  }
  ''
    cp -r ${src} $out
    chmod -R u+w $out
    if [ -d $out/doc ]; then
      export HOME=$TMPDIR
      nvim --clean --headless "+helptags $out/doc" +qa!
    fi
  ''
