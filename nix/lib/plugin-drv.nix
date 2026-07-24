# 1 plugin = 1 derivation。
# デフォルト: cp + doc/ があれば helptags 生成。
# TODO (Phase 5): build (shell) 実行、build-registry、overrides、nixpkgsFallback
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
