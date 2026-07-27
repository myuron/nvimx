# wrapProgram the user-selected neovim (an unwrapped style package) and inject bootstrap.lua
{ pkgs }:
{
  package,
  bootstrap,
  extraPackages ? [ ],
  vimAlias ? false,
  viAlias ? false,
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
      ${lib.optionalString (extraPackages != [ ]) "--prefix PATH : ${lib.makeBinPath extraPackages}"}
    ${lib.optionalString vimAlias "ln -s $out/bin/nvim $out/bin/vim"}
    ${lib.optionalString viAlias "ln -s $out/bin/nvim $out/bin/vi"}
  '';
}
