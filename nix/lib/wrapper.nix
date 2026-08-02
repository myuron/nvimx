# wrapProgram the user-selected neovim (an unwrapped style package) and inject bootstrap.lua
{ pkgs }:
{
  package,
  bootstrap,
  extraPackages ? [ ],
  extraLuaPackages ? (_: [ ]),
  vimAlias ? false,
  viAlias ? false,
}:
let
  inherit (pkgs) lib;

  # The Lua the chosen neovim is actually built against -- the only package set whose rocks are
  # guaranteed to match it. nixpkgs exposes it as passthru.lua (LuaJIT, i.e. Lua 5.1, today), and
  # every -unwrapped-shaped derivation that goes through overrideAttrs keeps that passthru, so a
  # neovim-nightly-overlay package works the same way. Reaching for a fixed pkgs.lua51Packages
  # instead would mix interpreters -- exactly what nixpkgs keeps the sets separate to avoid.
  lua =
    package.lua or (throw ''
      nvimx: extraLuaPackages is set, but ${package.name or "the neovim package"} exposes no
      passthru.lua, so nvimx cannot tell which Lua the rocks would have to match.
      Point programs.nvimx.package at an -unwrapped style derivation (pkgs.neovim-unwrapped, or
      a neovim-nightly-overlay package); an already-wrapped pkgs.neovim has no passthru.lua.
    '');
  # Applied lazily: the default (_: [ ]) discards its argument, so a package with no passthru.lua
  # never reaches the throw above. What forces it is the function *touching* the set, not the list
  # coming back non-empty -- `ps: lib.optionals false [ ps.foo ]` throws too. That is the intended
  # side of the line: reaching into the rock set at all is what needs a matching interpreter.
  luaPackages = extraLuaPackages lua.pkgs;
  luaEnv = lua.withPackages (_: luaPackages);
  # ";;" is Lua's "and the interpreter's compiled-in default path here". It cannot ride along in
  # the --prefix value: makeWrapper splits that value on the separator and drops empty components,
  # so a trailing ";;" disappears. --set-default puts it in the variable instead (the wrapper emits
  # its blocks in argument order), and the --prefix blocks then prepend to it. Without this, adding
  # a single rock would silently drop LuaJIT's own package.path -- require("jit.dump") and friends.
  luaWrapperArgs = lib.optionalString (luaPackages != [ ]) (
    lib.concatStringsSep " " [
      "--set-default LUA_PATH ';;'"
      "--set-default LUA_CPATH ';;'"
      "--prefix LUA_PATH ';' ${lib.escapeShellArg (lua.pkgs.luaLib.genLuaPathAbsStr luaEnv)}"
      "--prefix LUA_CPATH ';' ${lib.escapeShellArg (lua.pkgs.luaLib.genLuaCPathAbsStr luaEnv)}"
    ]
  );
in
pkgs.symlinkJoin {
  name = "nvimx-neovim";
  paths = [ package ];
  nativeBuildInputs = [ pkgs.makeWrapper ];
  postBuild = ''
    wrapProgram $out/bin/nvim \
      --add-flags "--cmd 'luafile ${bootstrap}'" \
      ${lib.optionalString (extraPackages != [ ]) "--prefix PATH : ${lib.makeBinPath extraPackages}"} \
      ${luaWrapperArgs}
    ${lib.optionalString vimAlias "ln -s $out/bin/nvim $out/bin/vim"}
    ${lib.optionalString viAlias "ln -s $out/bin/nvim $out/bin/vi"}
  '';
}
