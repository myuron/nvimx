# nvim-treesitter + grammars, merged into a single derivation.
#
# The parsers are the one part of nvim-treesitter the generic plugin build can never produce:
# upstream compiles them at runtime (`:TSInstall`) into user-owned state, which is exactly the
# kind of mutable state nvimx exists to avoid. So the grammars come from nixpkgs (already built,
# already cached) and are merged into the plugin tree with symlinkJoin, keeping everything in a
# single farm entry -- a second rtp entry was rejected because it breaks under
# `performance.rtp.reset` (docs/architecture.md).
#
# Grammar source: `pkgs.vimPlugins.nvim-treesitter.grammarPlugins`. It is keyed by
# nvim-treesitter's own language names and already lays each grammar out as `parser/<lang>.so`,
# which is precisely what neovim looks for on the runtimepath. `pkgs.tree-sitter-grammars` is the
# same set of derivations one layer down (nixpkgs derives the former from the latter), but named
# `tree-sitter-<lang>` and shaped as a bare `parser` file, so using it would mean re-deriving both
# the naming and the layout that nixpkgs already gets right.
#
# Queries live in the *locked* plugin tree, never in nixpkgs': whatever rev the user pinned is
# what highlights their buffers. nvim-treesitter's `main` branch keeps them under
# `runtime/queries/<lang>`, off the runtimepath, and links only the installed languages into
# place at `:TSInstall` time -- so this does the same linking at build time, for the selected
# languages only. On the `master` layout `queries/<lang>` already sits at the plugin root and the
# link is skipped.
#
# Known limitation: the grammar revs come from nixpkgs and the plugin rev from the user's lock,
# so the two are close but not identical (documented in the README).
{ pkgs }:
{
  # The derivation nvimx resolved for nvim-treesitter (overrides / nixpkgsFallback / generic)
  plugin,
  # "all" or a list of nvim-treesitter language names
  grammars,
  # Injectable so that checks do not depend on which grammars nixpkgs ships today
  grammarPlugins ? pkgs.vimPlugins.nvim-treesitter.grammarPlugins,
}:
let
  inherit (pkgs) lib;

  lookup =
    name:
    grammarPlugins.${name} or (throw ''
      nvimx: treesitter.grammars lists "${name}", but nixpkgs has no nvim-treesitter grammar
      under that name (pkgs.vimPlugins.nvim-treesitter.grammarPlugins).

      Use nvim-treesitter's own language name, which is what `:TSInstall` takes -- underscores
      and all ("c_sharp", not "c-sharp"). `treesitter.grammars = "all"` takes every grammar
      nixpkgs ships.
    '');

  requested = if grammars == "all" then builtins.attrNames grammarPlugins else grammars;

  # A grammar may need another one to be present (angular pulls in html, and so on).
  # nvim-treesitter expands `requires` the same way when installing, so match it here rather
  # than leave the user to discover the missing parser at runtime.
  languages = map (e: e.key) (
    builtins.genericClosure {
      startSet = map (key: { inherit key; }) requested;
      operator =
        { key }:
        map (dep: { key = dep; }) (
          builtins.filter (dep: grammarPlugins ? ${dep}) ((lookup key).requires or [ ])
        );
    }
  );
in
pkgs.symlinkJoin {
  name = "nvimx-plugin-nvim-treesitter";
  # The plugin comes first so that anything it ships wins over a grammar's copy
  paths = [ plugin ] ++ map lookup languages;
  postBuild = ''
    for lang in ${lib.escapeShellArgs languages}; do
      # `main` layout only: parked outside the runtimepath, linked in per installed language
      if [ -d "$out/runtime/queries/$lang" ] && [ ! -e "$out/queries/$lang" ]; then
        mkdir -p "$out/queries"
        ln -s "../runtime/queries/$lang" "$out/queries/$lang"
      fi
    done
  '';
}
