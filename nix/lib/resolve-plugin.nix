# The single place where "a plugin name + its locked src" becomes a derivation.
#
# Resolution order (docs/architecture.md, "Plugin derivations"):
#   1. plugins.overrides."<name>"   -- per-user escape hatch, wins over everything
#   2. plugins.nixpkgsFallback      -- per-user opt-in: take the nixpkgs package as-is
#   3. nix/build-registry/          -- nvimx's shipped build recipes
#   4. the generic build            -- plugin-drv.nix
#
# A user's explicit opt-in beats a shipped default, hence 1 and 2 above 3.
{ pkgs }:
let
  inherit (pkgs) lib;
  mkPluginDrv = import ./plugin-drv.nix { inherit pkgs; };
  shippedRegistry = import ../build-registry;

  # nixpkgs names a vimPlugins attribute after the upstream repo with "." replaced by "-",
  # but there is no single spelling to normalize to: most are lowercased
  # (telescope.nvim -> telescope-nvim), some keep their upstream casing
  # (CopilotChat.nvim -> CopilotChat-nvim), and some keep the name verbatim (LazyVim).
  # All three are tried, most faithful first.
  fromNixpkgs =
    name:
    let
      dashed = builtins.replaceStrings [ "." ] [ "-" ] name;
      lowered = lib.toLower dashed;
      tried = lib.unique [
        name
        dashed
        lowered
      ];
    in
    pkgs.vimPlugins.${name} or pkgs.vimPlugins.${dashed} or pkgs.vimPlugins.${lowered} or (throw ''
      nvimx: plugins.nixpkgsFallback lists "${name}", but nixpkgs has no matching
      vimPlugins attribute (tried ${lib.concatMapStringsSep ", " (n: "\"${n}\"") tried}).

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
  # Injectable so that checks can exercise the mechanism without depending on which plugins
  # happen to be shipped today
  registry ? shippedRegistry,
}:
let
  generic = mkPluginDrv { inherit name src build; };

  # The arguments a registry entry and a user override are both called with. Identical by
  # design: a recipe can move between the two unchanged. Every consumer of `defaultDrv` keeps
  # it a lazy binding on purpose: mkPluginDrv *throws at evaluation time* for a build that
  # needs the network, and rescuing exactly those plugins is what these hatches are for.
  # Forcing it eagerly would make the throw unavoidable and the hatch useless.
  args = {
    inherit
      pkgs
      name
      src
      build
      mkPluginDrv
      ;
  };

  # What nvimx would use if the plugin had no override.
  base =
    if lib.elem name nixpkgsFallback then
      fromNixpkgs name
    else if registry ? ${name} then
      registry.${name} (args // { defaultDrv = generic; })
    else
      generic;
in
if overrides ? ${name} then overrides.${name} (args // { defaultDrv = base; }) else base
