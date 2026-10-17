# plugins.json -> flake.nix, on two inputs (#29). The first is checks.resolve-golden's
# own golden output, which is what makes the two checks compose into the end-to-end
# statement neither makes alone. The second is a hand-written plugins.json holding
# shapes resolve.lua cannot currently emit -- one plugin carrying `commit`,
# `resolvedRef`, `tag` and `branch` at once -- because that is the only way to pin
# input_url's precedence: one ladder on the github side (commit > resolvedRef > tag >
# branch), and two independent slots on the git side (rev: commit > 40-hex
# resolvedRef; ref: symbolic resolvedRef > tag > branch). Before this check, swapping
# two rungs left all 29 checks green -- no fixture in the tree carried `commit` and
# `resolvedRef` on the same plugin, so nothing could tell the two apart.
# Every field in that fixture that is not the winning one exists only to lose -- the
# github side (gh-commit.nvim's resolvedRef/tag/branch, gh-resolved.nvim's tag/branch,
# gh-tag.nvim's branch) just as much as the git side (git-commit.nvim's resolvedRef,
# git-symbolic.nvim's tag, git-symbolic/git-tag's branch). None of them changes a
# single byte of the golden, but together they enforce one total order across the
# ladder. Individually some are redundant with another plugin's field, but which
# fields are redundant shifts whenever the ladder changes, so never delete one
# just because it is not the winner -- that is exactly the regression they catch.
# No git, no jq, no network: this stage is a pure text transform.
{
  pkgs,
  ...
}:
let
  # Same evaluation-time guard checks.resolve-sources uses (#28): a golden is a source
  # file, so importing it is a plain readFile and never IFD, and the derivation below
  # is what proves the generated flake still equals it. parseFlakeRef succeeding is
  # too weak on its own -- it accepts `github:o/r/tree/main` and bare `just-a-name` --
  # so the *type* is asserted as well: anything that is not github/git has silently
  # degraded to an `indirect` or `path:` node that only dies later, in sources.nix.
  goldenFlakes = {
    matrix = import ../fixtures/spec-matrix/golden/matrix.flake.nix;
    priority = import ../fixtures/spec-matrix/golden/priority.flake.nix;
  };
  refTypes = builtins.mapAttrs (
    _: f: builtins.mapAttrs (_: i: (builtins.parseFlakeRef i.url).type) f.inputs
  ) goldenFlakes;
  badTypes = builtins.mapAttrs (
    _: ts: pkgs.lib.filterAttrs (_: t: t != "github" && t != "git") ts
  ) refTypes;
  checkedRefTypes =
    if builtins.all (v: v == { }) (builtins.attrValues badTypes) then
      refTypes
    else
      throw "generated flake inputs are not github/git refs: ${builtins.toJSON badTypes}";
in
pkgs.runCommand "genflake-golden"
  {
    nativeBuildInputs = [ pkgs.neovim-unwrapped ];
    # Forced while the derivation is instantiated, so
    # `nix eval .#checks.aarch64-darwin.genflake-golden.drvPath` is enough to catch a
    # degraded URL on a system this machine cannot build for.
    refTypes = builtins.toJSON checkedRefTypes;
  }
  ''
    export HOME=$TMPDIR
    lua=${../../lua/nvimx}
    fx=${../fixtures/spec-matrix}

    nvim -l $lua/genflake.lua $fx/golden/matrix.plugins.json matrix.nix
    diff -u $fx/golden/matrix.flake.nix matrix.nix

    nvim -l $lua/genflake.lua $fx/priority.plugins.json priority.nix
    diff -u $fx/golden/priority.flake.nix priority.nix
    touch $out
  ''
