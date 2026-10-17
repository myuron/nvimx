# The spec-field matrix, raw-spec -> resolve (#29). checks.genflake-golden takes this check's
# golden output as its input, so the two compose end to end while a red check still names the
# stage that broke. Offline: versioned.nvim's url is rewritten to a local tag repo (mkTagRepoSh)
# and back, so the golden never records a build path. URL shapes are checks.resolve-sources'.
{
  pkgs,
  lazy-nvim,
  mkTagRepoSh,
  ...
}:
pkgs.runCommand "resolve-golden" {
  nativeBuildInputs = [
    pkgs.neovim-unwrapped
    pkgs.jq
    pkgs.git
  ];
  lua = ../../lua/nvimx;
  fx = ../fixtures/spec-matrix;
  lazy = lazy-nvim;
} (mkTagRepoSh + "source ${./scripts/resolve-golden.sh}")
