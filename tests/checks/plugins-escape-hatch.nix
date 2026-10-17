# The escape hatches must actually rescue a plugin whose build needs the network --
# that is what build-network.nix's error message promises. All three sit in front of
# the generic build, so the throw must never be reached.
{
  pkgs,
  nvimxLib,
  blinkSrc,
  ...
}:
let
  inherit (pkgs) lib;
  resolve =
    name: extra:
    nvimxLib.resolvePlugin (
      {
        inherit name;
        src = ../fixtures/local-plugin;
        build = {
          kind = "shell";
          cmd = "cargo build --release";
        };
      }
      // extra
    );
  evaluates =
    name: extra: (builtins.tryEval (builtins.seq (resolve name extra).drvPath null)).success;
  failures =
    lib.optional (evaluates "tokyonight.nvim" { }) "a build needing the network must still be rejected"
    ++ lib.optional (
      !(evaluates "tokyonight.nvim" {
        overrides."tokyonight.nvim" =
          { pkgs, ... }:
          pkgs.runCommand "nvimx-hatch" { } "mkdir -p $out";
      })
    ) "plugins.overrides did not rescue a build needing the network"
    ++ lib.optional (
      !(evaluates "tokyonight.nvim" { nixpkgsFallback = [ "tokyonight.nvim" ]; })
    ) "plugins.nixpkgsFallback did not rescue a build needing the network"
    # "fzf" is shipped in nix/build-registry precisely because its declared build
    # downloads a release binary. Its real command (`./install --bin`) is not what
    # is resolved here on purpose: build-network.nix cannot see the fetch inside
    # that script, so it would not exercise the rescue at all
    ++ lib.optional (
      !(evaluates "fzf" { })
    ) "nix/build-registry did not rescue a build needing the network"
    # ... so "blink.cmp" carries the other half: its `cargo build --release` is
    # caught by build-network.nix, and the entry has to keep the throw from being
    # reached. It needs a src with a Cargo.lock, since the entry reads one; only
    # drvPath is forced, so the library itself is not compiled here
    ++ lib.optional (
      !(evaluates "blink.cmp" { src = blinkSrc; })
    ) "nix/build-registry did not rescue blink.cmp's cargo build";
in
pkgs.runCommand "plugins-escape-hatch" { } (
  if failures == [ ] then
    "touch $out"
  else
    ''
      ${lib.concatMapStringsSep "\n" (f: "echo ${lib.escapeShellArg f} >&2") failures}
      exit 1
    ''
)
