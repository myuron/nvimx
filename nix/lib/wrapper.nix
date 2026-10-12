# wrapProgram the user-selected neovim (an unwrapped style package) and inject bootstrap.lua
{ pkgs }:
{
  package,
  bootstrap,
  extraPackages ? [ ],
  extraLuaPackages ? (_: [ ]),
  extraWrapperArgs ? [ ],
  withPython3 ? null,
  withRuby ? null,
  withNodeJs ? null,
  extraPython3Packages ? (_: [ ]),
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
  # never reaches the throw above. What forces it is the list coming back non-empty (luaEnv then
  # needs lua.withPackages), or the function strictly using the set to compute it. Either alone is
  # enough: `_: [ someRock ]` throws without ever touching ps, while `ps: lib.optionals false
  # [ ps.foo ]` returns [ ] without forcing ps and does not. A syntactic mention is not a force.
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
  # Provider hosts (#73). nix/lib/providers.nix decides what there is to say; here it only has to
  # reach wrapProgram. The Lua goes in as a second --cmd, after the bootstrap's and before the
  # user's config, so vim.g.<prog>_host_prog is a default that init.lua can still overwrite.
  # A file rather than an inline `--cmd "lua ..."`: --add-flags splices its value into the
  # wrapper script as shell text, and a path has nothing in it to quote.
  # lib.escapeShellArgs [ ] is "", so with every provider left at null this contributes nothing
  # and the filter below drops it -- see the note on trailingWrapperArgs.
  providers = import ./providers.nix { inherit pkgs; } {
    inherit
      package
      withPython3
      withRuby
      withNodeJs
      extraPython3Packages
      ;
  };
  providerWrapperArgs = lib.escapeShellArgs (
    lib.optionals (providers.rc != null) [
      "--add-flags"
      "--cmd 'luafile ${providers.rc}'"
    ]
    ++ providers.wrapperArgs
  );
  # extraWrapperArgs (#72) go last, after everything nvimx passes itself. makeWrapper handles its
  # arguments in order -- environment blocks are written out as it meets them, flags are collected
  # in the same order onto the final exec line -- so last means the user has the final word: a
  # --prefix PATH lands in front of extraPackages, a --set PATH replaces what was built up for
  # it, and an --add-flags follows the --cmd 'luafile <bootstrap>' below. That is what an escape
  # hatch is for, and nothing here guards against it.
  # They are free-form user text, hence lib.escapeShellArgs: each list element reaches
  # wrapProgram as one argument, whatever is in it. Do not "simplify" this to a plain join.
  # Joined onto luaWrapperArgs rather than given a continuation line of its own, and filtered so
  # that an empty side contributes no separator: with no extraWrapperArgs the postBuild text is
  # then byte for byte what it was before the option existed, so the derivation -- not merely the
  # script it produces -- is unchanged, and the last continuation line still ends without a
  # backslash to swallow the `ln -s` under it.
  trailingWrapperArgs = lib.concatStringsSep " " (
    lib.filter (s: s != "") [
      luaWrapperArgs
      providerWrapperArgs
      (lib.escapeShellArgs extraWrapperArgs)
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
      ${trailingWrapperArgs}
    ${lib.optionalString vimAlias "ln -s $out/bin/nvim $out/bin/vim"}
    ${lib.optionalString viAlias "ln -s $out/bin/nvim $out/bin/vi"}
  '';
}
