# The lazyNvim slot itself (#49). A spec is allowed to list lazy.nvim -- lazy's own docs
# tell people to -- and it used to make genflake write `inputs.lazy-nvim` twice, so the
# generated flake died at `nix flake lock` with a duplicate-attribute error naming
# neither the plugin nor the spec line. lazy.nvim cannot become an ordinary plugin
# instead: make-env.nix's farm (nix/lib/make-env.nix:122-133) always puts one `lazy.nvim`
# entry in front of pluginDrvs, and linkFarm is last-wins, so a second entry would
# silently replace nvimx's own foundation -- exactly what make-env.nix:47-48 and
# docs/architecture.md's plugin-derivation section say never happens. So the spec entry
# decides the *existing* input instead, and this check owns that slot. The spec-field
# matrix on ordinary plugins is checks.resolve-golden's (#29), the input_url precedence
# ladder is checks.genflake-golden's, and URL shapes are checks.resolve-sources' (#28);
# none of the three ever sees lazyNvim carrying a ref.
{
  pkgs,
  lazy-nvim,
  mkTagRepoSh,
  ...
}:
let
  # Importing the golden flake IS the regression test for the original bug: a
  # duplicate attribute is a *parse* error in Nix, so a golden that reintroduced the
  # second `lazy-nvim` would fail here, at evaluation, before any builder runs -- and
  # `nix eval .#checks.aarch64-darwin.resolve-lazy-self.drvPath` catches it on a
  # system this machine cannot build for. The diff in the builder is what proves
  # genflake still produces exactly this file. The parseFlakeRef type assert is the
  # same one checks.resolve-sources and checks.genflake-golden use (#28/#29): a github
  # or git ref, never a degraded `path:` / `indirect` node that only dies later in
  # nix/lib/sources.nix.
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
