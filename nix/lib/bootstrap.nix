# Generates bootstrap.lua by replacing @farm@ / @devDirs@ in bootstrap.lua.in
{ pkgs }:
{
  farm,
  # Plugin name -> working-tree directory, for plugins under local development. Rendered straight
  # into the Lua source, so it goes through lib.generators.toLua rather than string concatenation:
  # the keys are plugin names and the values are user-supplied paths, neither of which this file
  # should be quoting by hand.
  devDirs ? { },
}:
pkgs.writeText "nvimx-bootstrap.lua" (
  builtins.replaceStrings
    [ "@farm@" "@devDirs@" ]
    [
      "${farm}"
      (pkgs.lib.generators.toLua { } devDirs)
    ]
    (builtins.readFile ../../lua/nvimx/bootstrap.lua.in)
)
