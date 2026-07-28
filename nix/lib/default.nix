# nvimx lib entry point
{ pkgs, lazyNvimSeed }:
{
  makeEnv = import ./make-env.nix { inherit pkgs lazyNvimSeed; };
  # Exposed so that checks can build a single plugin
  mkPluginDrv = import ./plugin-drv.nix { inherit pkgs; };
  # The generic build plus the overrides / nixpkgsFallback escape hatches
  resolvePlugin = import ./resolve-plugin.nix { inherit pkgs; };
  buildNetwork = import ./build-network.nix { inherit (pkgs) lib; };
  lockApp = import ./lock-app.nix { inherit pkgs lazyNvimSeed; };
}
