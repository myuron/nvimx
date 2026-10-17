# Builds that need the network must be rejected at evaluation time, with a message
# naming the escape hatches -- and offline builds must not be caught by mistake
{
  pkgs,
  nvimxLib,
  ...
}:
let
  inherit (pkgs) lib;
  inherit (nvimxLib) buildNetwork mkPluginDrv;
  cases = [
    {
      cmd = "make";
      want = null;
    }
    {
      cmd = "cmake --build build";
      want = null;
    }
    {
      cmd = "cd deps && make";
      want = null;
    }
    {
      cmd = "make CFLAGS=-O2";
      want = null;
    }
    {
      cmd = "./install.sh";
      want = null;
    }
    # command substitution must not be mistaken for the outer command...
    {
      cmd = "make -j$(nproc)";
      want = null;
    }
    # ...but it must still be inspected
    {
      cmd = "make VERSION=$(git describe)";
      want = "git";
    }
    # quoted text is data, not a command
    {
      cmd = "echo \"done; git skipped\"";
      want = null;
    }
    {
      cmd = "make CFLAGS=\"-O2 -g\"";
      want = null;
    }
    {
      cmd = "cargo build --release";
      want = "cargo";
    }
    {
      cmd = "npm install";
      want = "npm";
    }
    {
      cmd = "env FOO=1 cargo build";
      want = "cargo";
    }
    # a wrapper's own flags and duration argument must be stepped over
    {
      cmd = "env -i cargo build";
      want = "cargo";
    }
    {
      cmd = "timeout 60 curl -O https://example.com/x";
      want = "curl";
    }
    {
      cmd = "make && curl -O https://example.com/x";
      want = "curl";
    }
    {
      cmd = "git submodule update --init";
      want = "git";
    }
  ];
  misclassified = builtins.filter (c: buildNetwork.detect c.cmd != c.want) cases;
  message = buildNetwork.message {
    name = "demo.nvim";
    cmd = "cargo build --release";
    tool = "cargo";
  };
  hatches = [
    "nix/build-registry/"
    "plugins.overrides"
    "plugins.nixpkgsFallback"
  ];
  evaluates =
    cmd:
    (builtins.tryEval (
      builtins.seq
        (mkPluginDrv {
          name = "demo.nvim";
          src = ../fixtures/empty-config;
          build = {
            kind = "shell";
            inherit cmd;
          };
        }).drvPath
        null
    )).success;
  # Detection has to apply to every shell step of a "steps" build, not just a scalar
  # one (#36): a network step anywhere in the list must throw, and an all-offline
  # "steps" build must not be caught by mistake.
  evaluatesSteps =
    steps:
    (builtins.tryEval (
      builtins.seq
        (mkPluginDrv {
          name = "demo.nvim";
          src = ../fixtures/empty-config;
          build = {
            kind = "steps";
            inherit steps;
          };
        }).drvPath
        null
    )).success;
  failures =
    map (
      c: "misclassified ${builtins.toJSON c.cmd}: got ${builtins.toJSON (buildNetwork.detect c.cmd)}"
    ) misclassified
    ++ map (h: "the error message does not mention ${h}") (
      builtins.filter (h: !lib.hasInfix h message) hatches
    )
    ++ lib.optional (evaluates "cargo build --release") "mkPluginDrv did not throw for a network build"
    ++ lib.optional (!evaluates "make") "mkPluginDrv threw for an offline build"
    ++ lib.optional (evaluatesSteps [
      {
        kind = "shell";
        cmd = "make";
      }
      {
        kind = "shell";
        cmd = "cargo build --release";
      }
    ]) "mkPluginDrv did not throw for a network step inside a \"steps\" build"
    ++ lib.optional (
      !evaluatesSteps [
        {
          kind = "shell";
          cmd = "make";
        }
        {
          kind = "excmd";
          cmd = ":TSUpdate";
        }
      ]
    ) "mkPluginDrv threw for an all-offline \"steps\" build";
in
pkgs.runCommand "build-network-detect" { } (
  if failures == [ ] then
    "touch $out"
  else
    ''
      ${lib.concatMapStringsSep "\n" (f: "echo ${lib.escapeShellArg f} >&2") failures}
      exit 1
    ''
)
