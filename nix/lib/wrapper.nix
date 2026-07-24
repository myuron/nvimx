# ユーザー選択の neovim (unwrapped 系) を wrapProgram し、bootstrap.lua を注入する
{ pkgs }:
{
  package,
  bootstrap,
  appName ? "nvim",
  extraPackages ? [ ],
}:
let
  inherit (pkgs) lib;
in
pkgs.symlinkJoin {
  name = "nvimx-neovim";
  paths = [ package ];
  nativeBuildInputs = [ pkgs.makeWrapper ];
  postBuild = ''
    wrapProgram $out/bin/nvim \
      --add-flags "--cmd 'luafile ${bootstrap}'" \
      ${lib.optionalString (appName != "nvim") "--set NVIM_APPNAME ${lib.escapeShellArg appName}"} \
      ${lib.optionalString (extraPackages != [ ]) "--prefix PATH : ${lib.makeBinPath extraPackages}"}
  '';
}
