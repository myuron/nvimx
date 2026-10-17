# Every URL form a lazy spec can put on a plugin, end to end: raw-spec -> resolve ->
# genflake, against a golden plugins.json and a golden flake.nix (#28). Fully offline --
# no fixture here names a reachable remote, and nothing in raw-spec-ok.json carries a
# `version`, so git ls-remote is never reached (constraint resolution is
# checks.resolve-semver's job). URL shapes only: build classification, dependencies, dev
# and version are the matrix #29's genflake-golden is for, not this check's.
{
  pkgs,
  lazy-nvim,
  ...
}:
let
  # The golden flake *is* the accept matrix, so every URL in it has to be something
  # nix's own flake ref parser accepts -- asserted here at evaluation time rather than
  # with a hand-rolled regex in bash. No IFD: the golden is a source file, so importing
  # it is a plain readFile, and the derivation below is what proves the generated flake
  # still equals it. Only the accept side is guarded here; what a *rejected* URL prints
  # is checks.source-parse's job.
  goldenFlake = import ../fixtures/source-urls/golden/ok.flake.nix;
  refTypes = builtins.mapAttrs (_: i: (builtins.parseFlakeRef i.url).type) goldenFlake.inputs;
  # parseFlakeRef succeeding is too weak to mean "nvimx can pin this": it accepts
  # `github:o/r/tree/main` (a github ref whose *ref* is "tree/main" -- a different tree
  # than the user asked for) and bare `just-a-name` (an `indirect` registry lookup).
  # And an input nix cannot parse at all does not fail the lock either: it degrades to a
  # `path:` node with no narHash that only dies later, in nix/lib/sources.nix. Every
  # input this repo emits has to be a github or a git ref, nothing else.
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
