# The core of env assembly: builds the farm / bootstrap / wrapped neovim fully purely
# from plugins.json + flake.lock (lockDir).
# When the lock is absent it degrades (farm = the lazy.nvim seed only),
# because failing evaluation would leave you without the lock command itself — a chicken-and-egg problem.
{ pkgs, lazyNvimSeed }:
{
  package,
  lockDir,
  extraPackages ? [ ],
  # A function over the Lua package set of `package` (ps: [ ps.foo ]), the same shape as
  # home-manager's programs.neovim.extraLuaPackages. Threaded straight to the wrapper, which is
  # what knows which Lua the chosen neovim links against.
  extraLuaPackages ? (_: [ ]),
  # Extra makeWrapper arguments, appended after nvimx's own (programs.nvimx.extraWrapperArgs).
  # Threaded straight to the wrapper like the two above, and like them it gets no output of its
  # own -- it is visible only through `wrapped`.
  extraWrapperArgs ? [ ],
  # Remote-plugin provider hosts (#73): null leaves neovim's own discovery alone, true builds the
  # host and sets vim.g.<prog>_host_prog, false sets vim.g.loaded_<prog>_provider = 0. Four flat
  # arguments rather than a `providers = { ... }` attrset, for the reason devPlugins / devPath
  # give below: they map 1:1 onto the module's options, which are flat because
  # programs.neovim's are. Threaded straight to the wrapper, which hands them to providers.nix.
  withPython3 ? null,
  withRuby ? null,
  withNodeJs ? null,
  # A function over pkgs.python3's package set (ps: [ ps.foo ]), the same shape as
  # programs.neovim.extraPython3Packages. Only reaches a host when withPython3 = true.
  extraPython3Packages ? (_: [ ]),
  vimAlias ? false,
  viAlias ? false,
  # Same shape as the module's programs.nvimx.plugins, so it can be passed straight through
  plugins ? { },
  # Likewise for programs.nvimx.treesitter
  treesitter ? { },
  # Plugin names to load from a working tree under devPath instead of the Nix store. Flat
  # scalars rather than a `dev = { ... }` attrset: unlike plugins / treesitter these are two
  # independent top-level options, and they map 1:1 onto the module's own two options.
  devPlugins ? [ ],
  devPath ? "~/projects",
  # Substrings of a plugin's url that route it to <devPath>/<name> (#74), like lazy's
  # dev.patterns. Flat for the same reason as the two above.
  devPatterns ? [ ],
}:
let
  inherit (pkgs) lib;
  overrides = plugins.overrides or { };
  nixpkgsFallback = plugins.nixpkgsFallback or [ ];
  grammars = treesitter.grammars or null;
  hasLock =
    builtins.pathExists (lockDir + "/plugins.json") && builtins.pathExists (lockDir + "/flake.lock");
  pluginsDb = builtins.fromJSON (builtins.readFile (lockDir + "/plugins.json"));
  getSource = import ./sources.nix { inherit lockDir; };
  mkPluginDrv = import ./plugin-drv.nix { inherit pkgs; };
  resolvePlugin = import ./resolve-plugin.nix { inherit pkgs; };
  mkFarm = import ./farm.nix { inherit pkgs; };
  mkTreesitter = import ./treesitter.nix { inherit pkgs; };
  mkBootstrap = import ./bootstrap.nix { inherit pkgs; };
  mkWrapper = import ./wrapper.nix { inherit pkgs; };

  lazyNvimDrv = mkPluginDrv {
    name = "lazy.nvim";
    src = if hasLock then getSource pluginsDb.lazyNvim.inputName else lazyNvimSeed;
  };

  # overrides / nixpkgsFallback only ever apply to plugins from the lock: lazy.nvim itself is
  # nvimx's own foundation, not a plugin the user declared.
  resolvedDrvs =
    if hasLock then
      lib.mapAttrs (
        name: p:
        resolvePlugin {
          inherit name overrides nixpkgsFallback;
          src = getSource p.inputName;
          build = p.build or { kind = "none"; };
        }
      ) pluginsDb.plugins
    else
      { };

  treesitterName = "nvim-treesitter";

  # Grammars are merged on top of whatever resolution produced, so an override or a
  # nixpkgsFallback for nvim-treesitter still decides what the plugin itself is.
  # grammars = null leaves the plugin exactly as resolved (the opt-out).
  pluginDrvs =
    resolvedDrvs
    // lib.optionalAttrs (grammars != null && resolvedDrvs ? ${treesitterName}) {
      ${treesitterName} = mkTreesitter {
        plugin = resolvedDrvs.${treesitterName};
        inherit grammars;
      };
    };

  # Selecting grammars without nvim-treesitter in the lock does nothing at all, which is
  # worth saying out loud. Reported rather than thrown, like unknownPluginNames, and only
  # when there is a lock to judge against (the degraded path has its own warning).
  treesitterWithoutPlugin = hasLock && grammars != null && !(resolvedDrvs ? ${treesitterName});

  # A name that matches nothing in the lock is a typo that would otherwise be a silent no-op.
  # Reported rather than thrown: it must not break the degraded (no lock) path.
  unknownPluginNames =
    if hasLock then
      builtins.filter (n: !(pluginsDb.plugins ? ${n})) (
        lib.unique (builtins.attrNames overrides ++ nixpkgsFallback)
      )
    else
      [ ];

  # localPlugins: the plugins the spec marked dev/dir, which resolve.lua deliberately keeps out
  # of the lock (there is nothing to pin). They have no farm entry either, so without a dev dir
  # they resolve to a store path that does not exist. Guarded by hasLock like every other
  # pluginsDb read, and tolerant of a plugins.json written before the key existed.
  localPlugins = if hasLock then pluginsDb.localPlugins or { } else { };

  # Name -> working-tree directory, handed to bootstrap.lua. Only the *keys* of localPlugins are
  # used; the recorded localPlugins[*].dir is deliberately NOT -- reading it could not change a
  # single resolved directory. A `dir` the user wrote in the spec short-circuits lazy before
  # dev.path is ever consulted (lua/lazy/core/meta.lua:214-217), so the only entries this map can
  # actually decide are the bare `dev = true` ones, which is exactly what devPath is for. Since
  # #56, an entry here carries no value at all -- the key is the only information localPlugins
  # holds. A plugins.json committed before #56 may still carry a dir, but this map has never read
  # that value, whatever shape it was in. Every value here is therefore <devPath>/<name>, and
  # nothing machine-specific out of plugins.json reaches bootstrap.lua.
  # (Which is not the same as devPath deciding where every dev plugin loads from: for a spec
  # entry that sets `dir`, lazy short-circuits on that dir and never reaches this map. The option
  # descriptions say so.)
  devDirs = lib.genAttrs (lib.unique (devPlugins ++ builtins.attrNames localPlugins)) (
    n: "${devPath}/${n}"
  );

  # Same rationale as unknownPluginNames: a name matching nothing is a typo that would otherwise
  # be a silent no-op. Reported rather than thrown so it cannot break the degraded (no lock)
  # path, and only computed when there is a lock to judge against.
  unknownDevPluginNames =
    if hasLock then
      builtins.filter (n: !(pluginsDb.plugins ? ${n}) && !(localPlugins ? ${n})) (lib.unique devPlugins)
    else
      [ ];

  farm = mkFarm {
    entries = [
      {
        name = "lazy.nvim";
        path = lazyNvimDrv;
      }
    ]
    ++ lib.mapAttrsToList (name: drv: {
      inherit name;
      path = drv;
    }) pluginDrvs;
  };

  # extraPython3Packages only ever reaches a host that withPython3 = true builds, so naming
  # packages without it is a silent no-op -- and an easy one to walk into: home-manager's
  # programs.neovim defaulted withPython3 to true before stateVersion 26.05, so a config written
  # against it can carry extraPython3Packages and no withPython3 line at all. Reported rather than
  # thrown, like unknownPluginNames. Comparing against [ ] looks at the list's length and nothing
  # in it, so this line forces no element of the list by itself; the default (_: [ ]) never
  # touches the package set at all.
  unusedPython3Packages = withPython3 != true && extraPython3Packages pkgs.python3.pkgs != [ ];

  bootstrap = mkBootstrap {
    inherit
      farm
      devDirs
      devPath
      devPatterns
      ;
  };
  wrapped = mkWrapper {
    inherit
      package
      bootstrap
      extraPackages
      extraLuaPackages
      extraWrapperArgs
      withPython3
      withRuby
      withNodeJs
      extraPython3Packages
      vimAlias
      viAlias
      ;
  };
in
{
  inherit
    farm
    bootstrap
    wrapped
    pluginDrvs
    unknownPluginNames
    treesitterWithoutPlugin
    devDirs
    devPatterns
    unknownDevPluginNames
    unusedPython3Packages
    hasLock
    ;
}
