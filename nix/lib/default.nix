# nvimx lib entry point
{ pkgs, lazyNvimSeed }:
{
  makeEnv = import ./make-env.nix { inherit pkgs lazyNvimSeed; };
  # Exposed so that checks (and, later, plugins.overrides) can build a single plugin
  mkPluginDrv = import ./plugin-drv.nix { inherit pkgs; };
  buildNetwork = import ./build-network.nix { inherit (pkgs) lib; };
  lockApp = import ./lock-app.nix { inherit pkgs lazyNvimSeed; };
}
