# Every URL form a lazy spec can put on a plugin, end to end: raw-spec -> resolve -> genflake,
# against a golden plugins.json and flake.nix (#28). Offline: no fixture names a reachable
# remote and none carries a `version` (that is checks.resolve-semver's). URL shapes only --
# the spec-field matrix is checks.resolve-golden / checks.genflake-golden's (#29).
{
  pkgs,
  lazy-nvim,
  ...
}:
let
  # The golden flake *is* the accept matrix, so every URL in it must parse as a flake ref --
  # asserted at evaluation time (no IFD: the golden is a source file). The reject side is
  # checks.source-parse's.
  goldenFlake = import ../fixtures/source-urls/golden/ok.flake.nix;
  refTypes = builtins.mapAttrs (_: i: (builtins.parseFlakeRef i.url).type) goldenFlake.inputs;
  # Parsing is too weak: it accepts `github:o/r/tree/main` (ref "tree/main") and bare names
  # (`indirect`), and an unparseable input degrades to a `path:` node that only dies later in
  # nix/lib/sources.nix. Every emitted input must be a github or git ref.
  badTypes = pkgs.lib.filterAttrs (_: t: t != "github" && t != "git") refTypes;
  checkedRefTypes =
    if badTypes == { } then
      refTypes
    else
      throw "generated flake inputs are not github/git refs: ${builtins.toJSON badTypes}";
in
pkgs.runCommand "resolve-sources" {
  nativeBuildInputs = [
    pkgs.neovim-unwrapped
    pkgs.jq
  ];
  # Forced while the derivation is instantiated, so
  # `nix eval .#checks.aarch64-darwin.resolve-sources.drvPath` is enough to catch an
  # unparseable or degraded URL on a system this machine cannot build for.
  refTypes = builtins.toJSON checkedRefTypes;
  lua = ../../lua/nvimx;
  fx = ../fixtures/source-urls;
  lazy = lazy-nvim;
} "source ${./scripts/resolve-sources.sh}"
