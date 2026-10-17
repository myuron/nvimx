# Remote-plugin provider hosts (python3 / ruby / node) for the wrapped neovim (#73).
# Returns what nix/lib/wrapper.nix needs and nothing else: `rc`, a Lua file to run with --cmd
# (null when there is nothing to say), `wrapperArgs`, a flat list of makeWrapper arguments, and
# `manifest`, the build-time remote-plugin manifest (#85; null unless a host is true, see below).
#
# Each with* argument has three states, and the third is why this file writes its own lines
# instead of reusing wrapNeovimUnstable's providerLuaRc, which only knows two:
#   null  -> say nothing. neovim searches for a host itself at first use, exactly as it did
#            before this option existed. This is the default, so that nobody's provider changes
#            under them, and so that the wrapper derivation stays byte for byte what it was.
#   true  -> build the host from nixpkgs and point vim.g.<prog>_host_prog at it.
#   false -> vim.g.loaded_<prog>_provider = 0: the provider is off, and neovim skips the search.
# true and false mean what they mean in home-manager's programs.neovim, so a value carried over
# from there keeps its meaning; null is the state programs.neovim does not have.
#
# true additionally registers the remote plugins of that host at build time (nix/lib/rplugin-manifest.nix)
# and has the rc load the result. null and false change nothing, so those wrappers stay as they were.
{ pkgs }:
{
  package,
  withPython3 ? null,
  withRuby ? null,
  withNodeJs ? null,
  extraPython3Packages ? (_: [ ]),
  # For the remote-plugin manifest (#85): the plugin farm to register from, and the farm entries
  # left to :UpdateRemotePlugins (dev plugins). Without a farm there is no manifest.
  farm ? null,
  rpluginExclude ? [ ],
}:
let
  inherit (pkgs) lib;

  # pkgs.python3, the interpreter nixpkgs' own wrapper uses. Unlike Lua (see `lua` in
  # wrapper.nix) the host is a separate process speaking msgpack-rpc, so it does not have to
  # match anything inside the chosen neovim.
  python3Env = pkgs.python3.withPackages (ps: [ ps.pynvim ] ++ extraPython3Packages ps);
  # The interpreter behind a wrapper that drops PYTHONPATH / PYTHONSAFEPATH, the same two
  # nixpkgs' hostPython3 drops: a PYTHONPATH exported for a project (a devShell, a direnv
  # activation) would otherwise be imported into the host and could shadow pynvim itself.
  hostPython3 =
    pkgs.runCommand "nvimx-host-${python3Env.name}" { nativeBuildInputs = [ pkgs.makeWrapper ]; }
      ''
        makeWrapper ${python3Env.interpreter} $out/bin/nvim-python3 \
          --unset PYTHONPATH --unset PYTHONSAFEPATH
      '';

  # The one piece borrowed from nixpkgs' wrapper rather than built here: the Gemfile / gemset.nix
  # that pin the neovim gem live next to that wrapper (pkgs/applications/editors/neovim/
  # ruby_provider), and the wrapper exposes the bundlerEnv built from them as an attribute. It
  # does not depend on `package` at all -- any argument gives the same derivation -- so nothing
  # is assumed about the chosen neovim, and only this attribute is forced, never the wrapper
  # itself.
  # `or null` and then a test for null, not `or (throw ...)`: this guards against the shape of
  # the wrapper's result changing, in either direction it can -- the attribute going away, or
  # being there with nothing in it (a null would get past `or` and surface as "cannot coerce
  # null to a string"). Every nixpkgs from 24.11 on has a real bundlerEnv here. 24.05 and
  # earlier never get this far: their wrapper has a required argument the call below does not
  # pass, and that error is raised before any attribute is looked at.
  borrowedRubyEnv = (pkgs.wrapNeovimUnstable package { }).rubyEnv or null;
  rubyEnv =
    if borrowedRubyEnv != null then
      borrowedRubyEnv
    else
      throw ''
        nvimx: withRuby = true, but this nixpkgs' wrapNeovimUnstable exposes no rubyEnv, so nvimx
        has no Ruby host to point neovim at. Leave withRuby unset and set vim.g.ruby_host_prog
        yourself, to the bin/neovim-ruby-host of a bundlerEnv holding the neovim gem.
      '';

  # One provider, one line -- or none. `exec` is only forced when the provider is on.
  line =
    prog: enabled: exec:
    if enabled == null then
      [ ]
    else if enabled then
      [ "vim.g.${prog}_host_prog = ${lib.generators.toLua { } exec}" ]
    else
      [ "vim.g.loaded_${prog}_provider = 0" ];
  lines =
    line "python3" withPython3 "${hostPython3}/bin/nvim-python3"
    ++ line "ruby" withRuby "${rubyEnv}/bin/neovim-ruby-host"
    ++ line "node" withNodeJs "${pkgs.neovim-node-client}/bin/neovim-node-host";

  # What goes on PATH for a provider that is on. --suffix, not --prefix: these are fallbacks,
  # and a node or ruby the user already has on PATH -- or one named in extraPackages -- stays
  # in front.
  #   node: required. neovim starts the host as `node <host>` (provider#node#Require), so
  #         g:node_host_prog alone fails with "'node' is not executable".
  #   ruby: not required to run the host, which carries its own interpreter. It is what
  #         :checkhealth looks for (`ruby` and `gem` on PATH), and without it a working provider
  #         is reported as missing.
  # python3 needs nothing: g:python3_host_prog is executed directly.
  runtimeDeps =
    lib.optional (withRuby == true) rubyEnv ++ lib.optional (withNodeJs == true) pkgs.nodejs;

  # The hosts that are on, i.e. the ones whose remote plugins get registered at build time (#85).
  # null and false register nothing and leave the rc and the wrapper exactly as they were.
  manifestHosts = lib.concatLists [
    (lib.optional (withPython3 == true) "python3")
    (lib.optional (withRuby == true) "ruby")
    (lib.optional (withNodeJs == true) "node")
  ];
  # Today's rc: the vim.g.*_host_prog lines. Also what the manifest derivation runs with --cmd.
  hostRc = pkgs.writeText "nvimx-providers.lua" (lib.concatStringsSep "\n" lines + "\n");
  manifest =
    if farm != null && manifestHosts != [ ] then
      import ./rplugin-manifest.nix { inherit pkgs; } {
        inherit package farm hostRc;
        hosts = manifestHosts;
        path = runtimeDeps;
        exclude = rpluginExclude;
      }
    else
      null;
  loadLine = "dofile(${lib.generators.toLua { } "${../../lua/nvimx/rplugin-load.lua}"})(${
    lib.generators.toLua { } {
      manifest = "${manifest}";
      hosts = manifestHosts;
      store = builtins.storeDir + "/";
    }
  })";
in
{
  inherit manifest;
  rc =
    if lines == [ ] then
      null
    else if manifest == null then
      hostRc
    else
      pkgs.writeText "nvimx-providers.lua" (lib.concatStringsSep "\n" (lines ++ [ loadLine ]) + "\n");
  wrapperArgs = lib.optionals (runtimeDeps != [ ]) [
    "--suffix"
    "PATH"
    ":"
    (lib.makeBinPath runtimeDeps)
  ];
}
