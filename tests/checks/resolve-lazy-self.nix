# The lazyNvim slot itself (#49). A spec may list lazy.nvim (lazy's docs say to), and it used
# to make genflake write `inputs.lazy-nvim` twice. It cannot become an ordinary plugin either:
# make-env.nix's farm always puts nvimx's own `lazy.nvim` first and linkFarm is last-wins. So
# the spec entry decides the *existing* input instead, and this check owns that slot -- the
# checks resolve-golden (#29), genflake-golden and resolve-sources (#28) never see lazyNvim
# carrying a ref.
{
  pkgs,
  lazy-nvim,
  mkTagRepoSh,
  ...
}:
let
  # Importing the golden flake IS the regression test for the original bug: a duplicate
  # attribute is a parse error, so it fails at evaluation (darwin included, via drvPath).
  # The type assert is the one checks.resolve-sources uses (#28).
  goldenFlake = import ../fixtures/lazy-self/golden/tag.flake.nix;
  refTypes = builtins.mapAttrs (_: i: (builtins.parseFlakeRef i.url).type) goldenFlake.inputs;
  badTypes = pkgs.lib.filterAttrs (_: t: t != "github" && t != "git") refTypes;
  checkedRefTypes =
    if badTypes == { } then
      refTypes
    else
      throw "generated flake inputs are not github/git refs: ${builtins.toJSON badTypes}";
in
pkgs.runCommand "resolve-lazy-self" {
  nativeBuildInputs = [
    pkgs.neovim-unwrapped
    pkgs.jq
    pkgs.git
  ];
  # Forced while the derivation is instantiated, so
  # `nix eval .#checks.aarch64-darwin.resolve-lazy-self.drvPath` is enough to catch
  # an unparseable or degraded URL on a system this machine cannot build for.
  refTypes = builtins.toJSON checkedRefTypes;
  lua = ../../lua/nvimx;
  fx = ../fixtures/lazy-self;
  lazy = lazy-nvim;
} (mkTagRepoSh + "source ${./scripts/resolve-lazy-self.sh}")
