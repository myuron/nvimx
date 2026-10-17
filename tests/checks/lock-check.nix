# nvimx-lock --check (#78), end to end: that it spots every kind of stale lock, prints the report
# the README promises, and does so without writing, without nix and without the network. Recursive
# nix cannot run in a build, so `nix` is a stub as in checks.lock-app -- but a different one: it
# *generates* flake.lock from the flake.nix in its cwd (input names from the nixfmt'd lines, a
# locked.rev derived from the name so `pin = true` can freeze). checks.lock-app's fixed
# flake.lock would be rejected by --check's flake.lock input-set rule for any other plugin set.
# The stub also proves "--check never runs nix": it records argv, which has to stay empty. The
# build sandbox has no network, which together with deleting the `version` remote proves it never
# runs git ls-remote either (a non-offline resolve would fail there). The nixfmt layout the stub
# parses is the one checks.genflake-golden pins, so a formatter change fails loudly here.
{
  pkgs,
  nvimxLib,
  mkTagRepoSh,
  ...
}:
let
  stubNix = pkgs.writeShellScriptBin "nix" ''
    printf '%s\n' "$*" >> "$NVIMX_STUB_ARGV"
    for n in $(${pkgs.gnused}/bin/sed -n 's/^    \(.*\) = {$/\1/p' flake.nix); do
      echo "$n $(echo "$n" | ${pkgs.coreutils}/bin/sha1sum | ${pkgs.coreutils}/bin/cut -c1-40)"
    done | ${pkgs.jq}/bin/jq -R -s '
      split("\n") | map(select(. != "") | split(" ")) as $p
      | { version: 7, root: "root",
          nodes: ({ root: { inputs: ($p | map({ key: .[0], value: .[0] }) | from_entries) } }
                  + ($p | map({ key: .[0], value: { flake: false, locked: { rev: .[1] } } }) | from_entries)) }
    ' > flake.lock
    chmod u+w flake.lock
  '';
in
pkgs.runCommand "lock-check" {
  nativeBuildInputs = [
    pkgs.git
    pkgs.jq
    nvimxLib.lockApp
    stubNix
  ];
} (mkTagRepoSh + "source ${./scripts/lock-check.sh}")
