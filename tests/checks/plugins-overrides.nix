# plugins.overrides: patching the default derivation, replacing it outright, and
# outranking a nixpkgsFallback configured for the same plugin
{
  pkgs,
  nvimxLib,
  ...
}:
let
  inherit (pkgs) lib;
  mkEnv =
    plugins:
    nvimxLib.makeEnv {
      package = pkgs.neovim-unwrapped;
      lockDir = ../fixtures/basic-config/nvimx-lock;
      inherit plugins;
    };
  patched = mkEnv {
    overrides."tokyonight.nvim" =
      { defaultDrv, ... }:
      defaultDrv.overrideAttrs (o: {
        postInstall = (o.postInstall or "") + "touch $out/nvimx-override-marker\n";
      });
  };
  replaced = mkEnv {
    overrides."tokyonight.nvim" =
      { pkgs, src, ... }:
      pkgs.runCommand "nvimx-custom-tokyonight" { } ''
        mkdir -p $out
        cp ${src}/README.md $out/
        touch $out/nvimx-custom
      '';
  };
  precedence = mkEnv {
    nixpkgsFallback = [ "tokyonight.nvim" ];
    overrides."tokyonight.nvim" =
      _:
      pkgs.runCommand "nvimx-override-wins" { } ''
        mkdir -p $out
        touch $out/nvimx-override-wins
      '';
  };
  # An identity override receives whatever nvimx would have used otherwise -- with a
  # fallback configured that is the nixpkgs package, not the generic build.
  # Compared by outPath so the check does not have to build it.
  identity = mkEnv {
    nixpkgsFallback = [ "tokyonight.nvim" ];
    overrides."tokyonight.nvim" = { defaultDrv, ... }: defaultDrv;
  };
  # a typo must not be a silent no-op: the module turns this into a warning
  unknown = (mkEnv { nixpkgsFallback = [ "no-such.nvim" ]; }).unknownPluginNames;
  failures =
    lib.optional (
      identity.pluginDrvs."tokyonight.nvim".outPath != pkgs.vimPlugins.tokyonight-nvim.outPath
    ) "an override's defaultDrv should be the nixpkgsFallback package when one is configured"
    ++ lib.optional (
      unknown != [ "no-such.nvim" ]
    ) "a name absent from the lock should show up in unknownPluginNames";
in
pkgs.runCommand "plugins-overrides" { } (
  if failures == [ ] then
    ''
      # overrideAttrs-style patch: the default build still ran, plus the added step
      test -f ${patched.farm}/tokyonight.nvim/nvimx-override-marker
      test -d ${patched.farm}/tokyonight.nvim/lua

      # wholesale replacement: only the override's output reaches the farm
      test -f ${replaced.farm}/tokyonight.nvim/nvimx-custom
      test -f ${replaced.farm}/tokyonight.nvim/README.md
      test ! -e ${replaced.farm}/tokyonight.nvim/lua

      # overrides > nixpkgsFallback
      test -f ${precedence.farm}/tokyonight.nvim/nvimx-override-wins
      touch $out
    ''
  else
    ''
      ${lib.concatMapStringsSep "\n" (f: "echo ${lib.escapeShellArg f} >&2") failures}
      exit 1
    ''
)
