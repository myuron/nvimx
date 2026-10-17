# plugins.overrides / plugins.nixpkgsFallback through the module's option types
# (attrsOf (functionTo package) / listOf str), which the lib-level checks bypass.
# Both are set for the same plugin on purpose: the override then patches the
# nixpkgs package, so the two must compose, not just evaluate.
{
  mkHmCheck,
  ...
}:
mkHmCheck {
  configDir = ../fixtures/basic-config;
  lockDir = ../fixtures/basic-config/nvimx-lock;
  plugins = {
    nixpkgsFallback = [ "tokyonight.nvim" ];
    overrides."tokyonight.nvim" =
      { defaultDrv, ... }:
      defaultDrv.overrideAttrs (o: {
        postInstall = (o.postInstall or "") + "touch $out/nvimx-hm-marker\n";
      });
  };
}
