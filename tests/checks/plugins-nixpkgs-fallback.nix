# plugins.nixpkgsFallback: the plugin comes from pkgs.vimPlugins instead of the lock,
# including the "." -> "-" attribute-name normalization
{
  pkgs,
  nvimxLib,
  ...
}:
let
  inherit (pkgs) lib;
  env = nvimxLib.makeEnv {
    package = pkgs.neovim-unwrapped;
    lockDir = ../fixtures/build-plugins/nvimx-lock;
    plugins.nixpkgsFallback = [ "telescope-fzf-native.nvim" ];
  };
  # nixpkgs has no single spelling for a vimPlugins attribute, so every spelling
  # the lookup tries must work. Compared by outPath: nothing here has to be built.
  resolveByName =
    name:
    nvimxLib.resolvePlugin {
      inherit name;
      src = ../fixtures/local-plugin;
      nixpkgsFallback = [ name ];
    };
  nameCases = [
    {
      name = "LazyVim"; # verbatim
      want = pkgs.vimPlugins.LazyVim;
    }
    {
      name = "CopilotChat.nvim"; # "." -> "-", casing preserved
      want = pkgs.vimPlugins.CopilotChat-nvim;
    }
    {
      name = "telescope.nvim"; # "." -> "-", lowercased
      want = pkgs.vimPlugins.telescope-nvim;
    }
  ];
  misresolved = builtins.filter (c: (resolveByName c.name).outPath != c.want.outPath) nameCases;
  # a name matching no vimPlugins attribute must fail loudly, not silently build
  unknownEvaluates =
    (builtins.tryEval (builtins.seq (resolveByName "no-such-plugin.nvim").drvPath null)).success;
  failures =
    lib.optional
      (
        env.pluginDrvs."telescope-fzf-native.nvim".outPath
        != pkgs.vimPlugins.telescope-fzf-native-nvim.outPath
      )
      "nixpkgsFallback did not resolve telescope-fzf-native.nvim to pkgs.vimPlugins.telescope-fzf-native-nvim"
    ++ map (c: "nixpkgsFallback resolved ${builtins.toJSON c.name} to the wrong attribute") misresolved
    ++ lib.optional unknownEvaluates "nixpkgsFallback did not throw for a name absent from vimPlugins";
in
pkgs.runCommand "plugins-nixpkgs-fallback" { } (
  if failures == [ ] then
    ''
      # nixpkgs lays a vim plugin out at $out (rtpPath = "."), so it drops into the
      # farm as-is and stays usable
      test -f ${env.farm}/telescope-fzf-native.nvim/build/libfzf.so
      touch $out
    ''
  else
    ''
      ${lib.concatMapStringsSep "\n" (f: "echo ${lib.escapeShellArg f} >&2") failures}
      exit 1
    ''
)
