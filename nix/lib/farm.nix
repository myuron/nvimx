# linkFarm "nvimx-plugins": ディレクトリ名 = lazy が導出した plugin 名。
# lazy.nvim 自身も 1 エントリとして常設する (rtp 前置と dataFile symlink の共通ターゲット)。
{ pkgs }:
{ entries }:
pkgs.linkFarm "nvimx-plugins" entries
