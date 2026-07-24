# env 組み立ての中核: plugins.json + flake.lock (lockDir) から
# farm / bootstrap / wrapped neovim を完全 pure に構築する。
{ pkgs }:
{
  package,
  lockDir,
}:
let
  inherit (pkgs) lib;
  pluginsDb = builtins.fromJSON (builtins.readFile (lockDir + "/plugins.json"));
  getSource = import ./sources.nix { inherit lockDir; };
  mkPluginDrv = import ./plugin-drv.nix { inherit pkgs; };
  mkFarm = import ./farm.nix { inherit pkgs; };
  mkBootstrap = import ./bootstrap.nix { inherit pkgs; };
  mkWrapper = import ./wrapper.nix { inherit pkgs; };

  lazyNvimDrv = mkPluginDrv {
    name = "lazy.nvim";
    src = getSource pluginsDb.lazyNvim.inputName;
  };

  pluginDrvs = lib.mapAttrs (
    name: p:
    mkPluginDrv {
      inherit name;
      src = getSource p.inputName;
    }
  ) pluginsDb.plugins;

  farm = mkFarm {
    entries = [
      {
        name = "lazy.nvim";
        path = lazyNvimDrv;
      }
    ]
    ++ lib.mapAttrsToList (name: drv: {
      inherit name;
      path = drv;
    }) pluginDrvs;
  };

  bootstrap = mkBootstrap { inherit farm; };
  wrapped = mkWrapper { inherit package bootstrap; };
in
{
  inherit
    farm
    bootstrap
    wrapped
    pluginDrvs
    ;
}
