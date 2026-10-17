# Generates bootstrap.lua by replacing @farm@ / @devDirs@ / @devPath@ / @devPatterns@ in bootstrap.lua.in
{ pkgs }:
{
  farm,
  # Plugin name -> working-tree directory, for plugins under local development. Rendered straight
  # into the Lua source, so it goes through lib.generators.toLua rather than string concatenation:
  # the keys are plugin names and the values are user-supplied paths, neither of which this file
  # should be quoting by hand.
  devDirs ? { },
  # programs.nvimx.devPath / devPatterns (#74), rendered the same way: user-supplied strings.
  devPath ? "~/projects",
  devPatterns ? [ ],
}:
pkgs.writeText "nvimx-bootstrap.lua" (
  builtins.replaceStrings
    [
      "@farm@"
      "@devDirs@"
      "@devPath@"
      "@devPatterns@"
    ]
    [
      "${farm}"
      (pkgs.lib.generators.toLua { } devDirs)
      (pkgs.lib.generators.toLua { } devPath)
      (pkgs.lib.generators.toLua { } devPatterns)
    ]
    (builtins.readFile ../../lua/nvimx/bootstrap.lua.in)
)
