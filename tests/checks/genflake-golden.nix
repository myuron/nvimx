# plugins.json -> flake.nix, on two inputs (#29). The first is checks.resolve-golden's golden
# output, so the two checks compose into one end-to-end statement. The second is hand-written
# to pin input_url's precedence (github: commit > resolvedRef > tag > branch; git: rev =
# commit > 40-hex resolvedRef, ref = symbolic resolvedRef > tag > branch). Every losing field
# in it exists only to lose -- never delete one for not being the winner.
# No git, no jq, no network: this stage is a pure text transform.
{
  pkgs,
  ...
}:
let
  # Same evaluation-time guard as checks.resolve-sources (#28): importing a golden is a plain
  # readFile, not IFD. parseFlakeRef alone is too weak (it accepts `github:o/r/tree/main` and
  # bare names), so the type must be github/git, not a degraded `indirect` / `path:` node.
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
