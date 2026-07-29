# nvimx's shipped build recipes, keyed by the plugin name lazy derives (= the farm entry name).
#
# The registry is the "we already know how this one has to be built" layer: a plugin whose
# declared build is wrong, absent, or impossible inside the sandbox gets a working derivation
# without the user configuring anything. It sits *below* the per-user escape hatches --
# resolution order (nix/lib/resolve-plugin.nix):
#
#   plugins.overrides > plugins.nixpkgsFallback > this registry > the generic build
#
# so a user can always outrank, replace, or bypass an entry.
#
# ## Shape of an entry
#
# One file per plugin, named after the plugin plus ".nix", listed in the attrset below. An entry
# is a function with exactly the same shape as a `plugins.overrides` entry, so a recipe can move
# between the two unchanged. Always accept `...`: more arguments may be added later.
#
#   pkgs         the package set the env is being built for
#   name         the plugin name (= this entry's key)
#   src          the locked source tree
#   build        the build recorded in plugins.json ({ kind, cmd })
#   mkPluginDrv  the generic builder ({ name, src, build } -> drv): the shortest route to
#                "the usual treatment, but with the build command corrected"
#   defaultDrv   what nvimx would have built without this entry (mkPluginDrv applied to the
#                arguments above). Lazy on purpose: mkPluginDrv throws at evaluation time for a
#                build that needs the network, so an entry rescuing such a plugin must simply
#                not touch it
#
# ## Adding an entry
#
# 1. Write nix/build-registry/<plugin name>.nix and add it to the attrset below.
# 2. Cover it in `checks.build-registry` in flake.nix.
#
# What belongs here, given that an entry applies automatically to every user:
#
# - It must build offline. That is the whole point: rescuing a build the sandbox cannot run.
# - It must hold for *any* rev the user may have pinned. The lock pins the plugin, not this
#   registry, so a recipe that greps upstream source text breaks the day upstream reformats it.
#   Version-sensitive patching belongs in a user's `plugins.overrides`.
# - It must keep building from the locked src. Substituting `pkgs.vimPlugins.<attr>` wholesale
#   detaches the plugin from its pin, which is exactly why `plugins.nixpkgsFallback` is opt-in.
#   Taking a *companion binary* from nixpkgs (fzf.nix) is the one carve-out: when the artifact a
#   build downloads cannot be produced offline from the locked src either, nixpkgs' build of the
#   same program is the closest thing to it, and the plugin's own files still come from the lock.
# - Keying is by name alone, so an entry doubles as an assertion that the plugin really is the
#   one it is named after. Where the name is generic enough to collide, say so in the build
#   rather than silently mistreating someone else's plugin (again fzf.nix).
{
  "telescope-fzf-native.nvim" = import ./telescope-fzf-native.nvim.nix;
  "fzf" = import ./fzf.nix;
}
