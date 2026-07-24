# nvimx lib エントリ
{ pkgs }:
{
  makeEnv = import ./make-env.nix { inherit pkgs; };
}
