# vimAlias / viAlias: the wrapper must grow vim / vi symlinks
{
  pkgs,
  nvimxLib,
  ...
}:
let
  env = nvimxLib.makeEnv {
    package = pkgs.neovim-unwrapped;
    lockDir = ../fixtures/basic-config/nvimx-lock;
    vimAlias = true;
    viAlias = true;
  };
in
pkgs.runCommand "wrapper-aliases" { } ''
  test -L ${env.wrapped}/bin/vim
  test -L ${env.wrapped}/bin/vi
  touch $out
''
