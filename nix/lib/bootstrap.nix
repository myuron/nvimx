# bootstrap.lua.in の @farm@ を実 farm パスに置換して生成
{ pkgs }:
{ farm }:
pkgs.writeText "nvimx-bootstrap.lua" (
  builtins.replaceStrings [ "@farm@" ] [ "${farm}" ] (
    builtins.readFile ../../lua/nvimx/bootstrap.lua.in
  )
)
