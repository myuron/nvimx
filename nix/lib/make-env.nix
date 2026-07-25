# env 組み立ての中核: plugins.json + flake.lock (lockDir) から
# farm / bootstrap / wrapped neovim を完全 pure に構築する。
# lock 不在時は degrade ビルド (farm = lazy.nvim シードのみ)。
# eval を失敗させると lock コマンド自体が手に入らず鶏卵になるため。
{ pkgs, lazyNvimSeed }:
{
  package,
  lockDir,
  appName ? "nvim",
  extraPackages ? [ ],
  vimAlias ? false,
  viAlias ? false,
}:
let
  inherit (pkgs) lib;
  hasLock =
    builtins.pathExists (lockDir + "/plugins.json") && builtins.pathExists (lockDir + "/flake.lock");
  pluginsDb = builtins.fromJSON (builtins.readFile (lockDir + "/plugins.json"));
  getSource = import ./sources.nix { inherit lockDir; };
  mkPluginDrv = import ./plugin-drv.nix { inherit pkgs; };
  mkFarm = import ./farm.nix { inherit pkgs; };
  mkBootstrap = import ./bootstrap.nix { inherit pkgs; };
  mkWrapper = import ./wrapper.nix { inherit pkgs; };

  lazyNvimDrv = mkPluginDrv {
    name = "lazy.nvim";
    src = if hasLock then getSource pluginsDb.lazyNvim.inputName else lazyNvimSeed;
  };

  pluginDrvs =
    if hasLock then
      lib.mapAttrs (
        name: p:
        mkPluginDrv {
          inherit name;
          src = getSource p.inputName;
        }
      ) pluginsDb.plugins
    else
      { };

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
  wrapped = mkWrapper {
    inherit
      package
      bootstrap
      appName
      extraPackages
      vimAlias
      viAlias
      ;
  };
in
{
  inherit
    farm
    bootstrap
    wrapped
    pluginDrvs
    hasLock
    ;
}
