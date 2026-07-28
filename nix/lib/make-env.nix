# The core of env assembly: builds the farm / bootstrap / wrapped neovim fully purely
# from plugins.json + flake.lock (lockDir).
# When the lock is absent it degrades (farm = the lazy.nvim seed only),
# because failing evaluation would leave you without the lock command itself — a chicken-and-egg problem.
{ pkgs, lazyNvimSeed }:
{
  package,
  lockDir,
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
          build = p.build or { kind = "none"; };
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
