# ユーザー選択の neovim (unwrapped 系) を wrapProgram し、bootstrap.lua を注入する
{ pkgs }:
{ package, bootstrap }:
pkgs.symlinkJoin {
  name = "nvimx-neovim";
  paths = [ package ];
  nativeBuildInputs = [ pkgs.makeWrapper ];
  postBuild = ''
    wrapProgram $out/bin/nvim \
      --add-flags "--cmd 'luafile ${bootstrap}'"
  '';
}
