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
  # Same shape as the module's programs.nvimx.plugins, so it can be passed straight through
  plugins ? { },
}:
let
  inherit (pkgs) lib;
  overrides = plugins.overrides or { };
  nixpkgsFallback = plugins.nixpkgsFallback or [ ];
  hasLock =
    builtins.pathExists (lockDir + "/plugins.json") && builtins.pathExists (lockDir + "/flake.lock");
  pluginsDb = builtins.fromJSON (builtins.readFile (lockDir + "/plugins.json"));
  getSource = import ./sources.nix { inherit lockDir; };
  mkPluginDrv = import ./plugin-drv.nix { inherit pkgs; };
  resolvePlugin = import ./resolve-plugin.nix { inherit pkgs; };
  mkFarm = import ./farm.nix { inherit pkgs; };
  mkBootstrap = import ./bootstrap.nix { inherit pkgs; };
  mkWrapper = import ./wrapper.nix { inherit pkgs; };

  lazyNvimDrv = mkPluginDrv {
    name = "lazy.nvim";
    src = if hasLock then getSource pluginsDb.lazyNvim.inputName else lazyNvimSeed;
  };

  # overrides / nixpkgsFallback only ever apply to plugins from the lock: lazy.nvim itself is
  # nvimx's own foundation, not a plugin the user declared.
  pluginDrvs =
    if hasLock then
      lib.mapAttrs (
        name: p:
        resolvePlugin {
          inherit name overrides nixpkgsFallback;
          src = getSource p.inputName;
          build = p.build or { kind = "none"; };
        }
      ) pluginsDb.plugins
    else
      { };

  # A name that matches nothing in the lock is a typo that would otherwise be a silent no-op.
  # Reported rather than thrown: it must not break the degraded (no lock) path.
  unknownPluginNames =
    if hasLock then
      builtins.filter (n: !(pluginsDb.plugins ? ${n})) (
        lib.unique (builtins.attrNames overrides ++ nixpkgsFallback)
      )
    else
      [ ];

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
    unknownPluginNames
    hasLock
    ;
}
