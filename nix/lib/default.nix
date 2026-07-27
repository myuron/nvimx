# nvimx lib entry point
{ pkgs, lazyNvimSeed }:
{
  makeEnv = import ./make-env.nix { inherit pkgs lazyNvimSeed; };
  lockApp = import ./lock-app.nix { inherit pkgs lazyNvimSeed; };
}
