# The build-time remote-plugin manifest (#85). The promise is a remote plugin that answers with no
# :UpdateRemotePlugins -- on a fresh profile, right after a plugin update, and next to whatever
# manifest the user already has -- on nixpkgs' patched neovim and on an upstream-shaped one.
# Scenarios (the script has them in order):
#   A  fresh HOME.
#   B  a user manifest left over from the previous plugin version, plus a dev plugin registered
#      from a working tree. Without the loader's removal step the old module wins pynvim's
#      basename-keyed import and answers with the old version, and the old autocmd spec has no
#      handler.
#   C  a user manifest naming the same paths (the user ran :UpdateRemotePlugins this generation).
#      Upstream's remote#host#RegisterPlugin throws on that; nixpkgs' patch returns instead.
#   E  --clean loads nothing, as for runtime's own manifest.
#   F  g:loaded_remote_plugins set before plugins load: runtime's rplugin.vim finishes early, but
#      SourcePost still fires, so the loader must not switch rplugin back on.
#   G  ruby and node hosts at run time.
# `upstream` strips nixpkgs' system_rplugin_manifest.patch from the runtime, for generation and run
# time alike, which covers a neovim-nightly-overlay package without depending on one.
# The hosts and fetches are those of checks.providers. Generation is non-fatal for a plugin that
# fails to register (it is left out, as with programs.neovim), so the manifest assertions here are
# the only thing that goes red when node's PATH does not reach generation.
{
  pkgs,
  nvimxLib,
  self,
  home-manager,
  ...
}:
let
  inherit (pkgs) lib;
  fixture = ../fixtures/rplugin-plugin;
  mkPlugin =
    version:
    pkgs.runCommand "nvimx-rplugin-${version}" { } ''
      cp -r ${fixture} $out
      chmod -R u+w $out
      substituteInPlace $out/rplugin/python3/nvimx_rplugin_test.py --replace-fail @version@ ${version}
    '';
  # The basic-config lock (only tokyonight.nvim), the plugin replaced outright as in
  # checks.plugins-overrides.
  mkEnv =
    package: version: extra:
    nvimxLib.makeEnv (
      {
        inherit package;
        lockDir = ../fixtures/basic-config/nvimx-lock;
        withPython3 = true;
        plugins.overrides."tokyonight.nvim" = _: mkPlugin version;
      }
      // extra
    );

  # An upstream-shaped neovim without rebuilding it: the same binary on a runtime with the
  # nixpkgs patch reverted. If nixpkgs drops the patch, the runtime is copied unchanged, which
  # then already is upstream's.
  upstreamRuntime = pkgs.runCommand "nvimx-upstream-runtime" { } ''
    cp -r ${pkgs.neovim-unwrapped}/share/nvim/runtime $out
    chmod -R u+w $out
    ${lib.concatMapStringsSep "\n"
      (p: ''
        patch -R -p2 -d $out < ${p}
      '')
      (
        lib.filter (
          p: lib.hasSuffix "system_rplugin_manifest.patch" (toString p)
        ) pkgs.neovim-unwrapped.patches
      )
    }
    # controls: without these the upstream runs below could pass vacuously
    grep -q "is already registered" $out/autoload/remote/host.vim
    ! grep -q NVIM_SYSTEM_RPLUGIN_MANIFEST $out/plugin/rplugin.vim
  '';
  upstreamNeovim = pkgs.symlinkJoin {
    name = "neovim-upstream-runtime";
    # the first path wins bin/nvim
    paths = [
      (pkgs.writeShellScriptBin "nvim" ''VIMRUNTIME=${upstreamRuntime} exec ${pkgs.neovim-unwrapped}/bin/nvim "$@"'')
      pkgs.neovim-unwrapped
    ];
  };

  v1 = mkEnv pkgs.neovim-unwrapped "v1" { };
  v2 = mkEnv pkgs.neovim-unwrapped "v2" { };
  v2u = mkEnv upstreamNeovim "v2" { };
  # devPlugins: left to :UpdateRemotePlugins, so the manifest registers nothing
  dev = mkEnv pkgs.neovim-unwrapped "v2" { devPlugins = [ "tokyonight.nvim" ]; };
  multi = mkEnv pkgs.neovim-unwrapped "v2" {
    withNodeJs = true;
    withRuby = true;
  };
  untouched = mkEnv pkgs.neovim-unwrapped "v2" { withPython3 = null; };
  off = mkEnv pkgs.neovim-unwrapped "v2" {
    withPython3 = false;
    withRuby = false;
    withNodeJs = false;
  };

  moduleEval = home-manager.lib.homeManagerConfiguration {
    inherit pkgs;
    modules = [
      self.homeModules.nvimx
      {
        home.username = "nvimx-test";
        home.homeDirectory = "/home/nvimx-test";
        home.stateVersion = "25.05";
        programs.nvimx = {
          enable = true;
          configDir = ../fixtures/basic-config;
          lockDir = ../fixtures/basic-config/no-such-lock;
          withPython3 = true;
        };
      }
    ];
  };

  failures =
    lib.optional (
      untouched.wrapped.rpluginManifest != null
    ) "withPython3 = null must not build a manifest"
    ++ lib.optional (off.wrapped.rpluginManifest != null) "every host false must not build a manifest"
    ++ lib.optional (
      moduleEval.config.programs.nvimx.env.wrapped.rpluginManifest == null
    ) "the hm module's withPython3 = true must reach the manifest";
in
pkgs.runCommand "rplugin-manifest"
  {
    nativeBuildInputs = [ pkgs.gnugrep ];
    v1Manifest = v1.wrapped.rpluginManifest;
    v1Plugin = v1.pluginDrvs."tokyonight.nvim";
    v2Manifest = v2.wrapped.rpluginManifest;
    v2Plugin = v2.pluginDrvs."tokyonight.nvim";
    devManifest = dev.wrapped.rpluginManifest;
    multiManifest = multi.wrapped.rpluginManifest;
    v2Wrapped = v2.wrapped;
    v2uWrapped = v2u.wrapped;
    multiWrapped = multi.wrapped;
    untouchedWrapped = untouched.wrapped;
    offWrapped = off.wrapped;
    inherit upstreamNeovim upstreamRuntime;
    initLua = ../fixtures/rplugin-config/init.lua;
    driver = ../rplugin-manifest-test.lua;
    failures = lib.concatStringsSep "\n" failures;
  }
  ''
    if [ -n "$failures" ]; then
      echo "$failures" >&2
      exit 1
    fi
    source ${./scripts/rplugin-manifest.sh}
  ''
