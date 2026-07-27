# Generates bootstrap.lua by replacing @farm@ in bootstrap.lua.in with the real farm path
{ pkgs }:
{ farm }:
pkgs.writeText "nvimx-bootstrap.lua" (
  builtins.replaceStrings [ "@farm@" ] [ "${farm}" ] (
    builtins.readFile ../../lua/nvimx/bootstrap.lua.in
  )
)
