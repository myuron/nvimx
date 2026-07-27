# linkFarm "nvimx-plugins": directory name = the plugin name derived by lazy.
# lazy.nvim itself is always present as one entry (the shared target of the rtp prepend
# and the dataFile symlink).
{ pkgs }:
{ entries }:
pkgs.linkFarm "nvimx-plugins" entries
