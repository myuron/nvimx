# Every flake check, one file per check. Each file is a function of the arguments below plus
# the helpers from ./lib.nix (blinkSrc, mkTagRepoSh, mkHmCheck), and returns a derivation.
args@{
  pkgs,
  nvimxLib,
  self,
  lazy-nvim,
  home-manager,
}:
let
  checkArgs = args // import ./lib.nix args;
in
pkgs.lib.genAttrs [
  "hm-module"
  "hm-module-degrade"
  "hm-module-plugins"
  "hm-module-treesitter"
  "hm-module-dev"
  "hm-module-lua-packages"
  "hm-module-wrapper-args"
  "hm-module-providers"
  "hm-module-default-editor"
  "wrapper-aliases"
  "extra-lua-packages"
  "extra-wrapper-args"
  "providers"
  "build-shell"
  "plugin-drv-phases"
  "build-network-detect"
  "plugins-overrides"
  "plugins-nixpkgs-fallback"
  "build-registry"
  "plugins-escape-hatch"
  "treesitter-grammars"
  "extractor-snapshot"
  "extractor-no-setup"
  "semver-select"
  "source-parse"
  "extractor-defaults-version"
  "extractor-local-dir"
  "resolve-build-warnings"
  "resolve-merge"
  "resolve-semver"
  "resolve-update"
  "update-summary"
  "resolve-import-lazy-lock"
  "lock-app"
  "resolve-sources"
  "resolve-golden"
  "genflake-golden"
  "resolve-lazy-self"
  "dev-plugins"
] (name: import (./. + "/${name}.nix") checkArgs)
