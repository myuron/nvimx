# build.kind == "shell": the recorded command must actually run, and its artifact
# must reach both the plugin derivation and the farm
{
  pkgs,
  nvimxLib,
  ...
}:
let
  env = nvimxLib.makeEnv {
    package = pkgs.neovim-unwrapped;
    lockDir = ../fixtures/build-plugins/nvimx-lock;
  };
in
pkgs.runCommand "build-shell" { } ''
  test -f ${env.pluginDrvs."telescope-fzf-native.nvim"}/build/libfzf.so
  test -f ${env.farm}/telescope-fzf-native.nvim/build/libfzf.so
  touch $out
''
