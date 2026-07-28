# The single place where "a plugin name + its locked src" becomes a derivation.
#
# Resolution order (docs/architecture.md, "Plugin derivations"):
#   1. plugins.overrides."<name>"   -- per-user escape hatch, wins over everything
#   2. plugins.nixpkgsFallback      -- per-user opt-in: take the nixpkgs package as-is
#   3. nix/build-registry/          -- shipped defaults (not implemented yet, #19)
#   4. the generic build            -- plugin-drv.nix
#
# A user's explicit opt-in beats a shipped default, hence 1 and 2 above 3.
{ pkgs }:
let
  inherit (pkgs) lib;
  mkPluginDrv = import ./plugin-drv.nix { inherit pkgs; };

  # nixpkgs names a vimPlugins attribute after the upstream repo with "." replaced by "-",
  # usually lowercased (telescope.nvim -> telescope-nvim). The verbatim name is tried first
  # so attributes that keep their upstream casing (LazyVim, LuaSnip) still resolve.
  fromNixpkgs =
    name:
    let
      normalized = lib.toLower (builtins.replaceStrings [ "." ] [ "-" ] name);
    in
    pkgs.vimPlugins.${name} or pkgs.vimPlugins.${normalized} or (throw ''
      nvimx: plugins.nixpkgsFallback lists "${name}", but nixpkgs has no matching
      vimPlugins attribute (tried "${name}" and "${normalized}").

      If the package exists under a different attribute name, point at it directly:

        programs.nvimx.plugins.overrides."${name}" = { pkgs, ... }: pkgs.vimPlugins.<attr>;
    '');
in
{
  name,
  src,
  build ? {
    kind = "none";
  },
  overrides ? { },
  nixpkgsFallback ? [ ],
}:
let
  generic = mkPluginDrv { inherit name src build; };

  # What nvimx would use if the plugin had no override. Kept as a lazy binding on purpose:
  # mkPluginDrv *throws at evaluation time* for a build that needs the network, and rescuing
  # exactly those plugins is what these escape hatches are for. Forcing this eagerly would
  # make the throw unavoidable and the escape hatch useless.
  base = if lib.elem name nixpkgsFallback then fromNixpkgs name else generic;
in
if overrides ? ${name} then
  overrides.${name} {
    inherit
      pkgs
      name
      src
      build
      ;
    defaultDrv = base;
  }
else
  base
