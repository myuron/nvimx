# The whole loop a user runs, with no network (#30): config -> extract -> resolve -> genflake
# -> real `nix flake lock` -> makeEnv build -> the wrapped neovim launching. "Offline" means
# build-time: evaluating the flake still fetches its own pinned inputs, as every check does
# (lazy-nvim is one of them). No other check builds an env AND launches it with a user config,
# or runs a real nix: checks.lock-app stands a stub in for it.
#
# The env is built from tests/fixtures/e2e-offline/nvimx-lock, whose flake.lock holds relative
# `path:` nodes (nix/lib/sources.nix reads them) instead of github ones, so the three vendored
# plugins need no fetch. The pipeline never writes path sources, so plugins.json / flake.nix are
# real pipeline output (step 1 re-derives them) and only flake.lock is written by hand:
#   F=tests/fixtures/e2e-offline
#   jq --slurpfile p $F/nvimx-lock/plugins.json '
#    ($p[0].plugins | to_entries | map({key: .value.inputName, value: {flake: false,
#      locked: {path: ("../plugins/" + .key), type: "path"},
#      original: {path: ("../plugins/" + .key), type: "path"}, parent: []}}) | from_entries) as $pn
#    | {nodes: ($pn + {"lazy-nvim": .nodes["lazy-nvim"],
#        root: {inputs: ((($pn|keys) + ["lazy-nvim"]) | map({key: ., value: .}) | from_entries)}}),
#       root: "root", version: 7}' flake.lock > $F/nvimx-lock/flake.lock
# Its lazy-nvim node is nvimx's own, so bumping the lazy-nvim input means regenerating it
# (the eval-time failure below says so): otherwise evaluation would fetch a second lazy.nvim.
{
  pkgs,
  nvimxLib,
  lazy-nvim,
  ...
}:
let
  inherit (pkgs) lib;
  fx = ../fixtures/e2e-offline;
  env = nvimxLib.makeEnv {
    package = pkgs.neovim-unwrapped;
    lockDir = fx + "/nvimx-lock";
  };
  readJson = p: builtins.fromJSON (builtins.readFile p);
  fixtureLock = readJson (fx + "/nvimx-lock/flake.lock");
  ownLock = readJson ../../flake.lock;
  pluginsDb = readJson (fx + "/nvimx-lock/plugins.json");
  # The tie between the fixture and what the check launches is a plain readFile of source files
  # (never IFD), forced into the derivation through `failures` as in checks.genflake-golden, so
  # that `nix eval ...aarch64-darwin...drvPath` catches it too.
  pluginNodes = lib.mapAttrsToList (_: p: p.inputName) pluginsDb.plugins;
  nonLazyNodes = lib.filterAttrs (
    n: _: n != "root" && n != pluginsDb.lazyNvim.inputName
  ) fixtureLock.nodes;
  failures =
    lib.optional
      (
        (fixtureLock.nodes.${pluginsDb.lazyNvim.inputName}.locked or null)
        != ownLock.nodes.${pluginsDb.lazyNvim.inputName}.locked
      )
      "the fixture's lazy-nvim node differs from nvimx's own flake.lock: regenerate it (see the header of tests/checks/e2e-offline.nix), or evaluation fetches another lazy.nvim"
    ++
      lib.optional
        (
          lib.sort (a: b: a < b) (builtins.attrNames fixtureLock.nodes.root.inputs)
          != lib.sort (a: b: a < b) (pluginNodes ++ [ pluginsDb.lazyNvim.inputName ])
        )
        "the fixture flake.lock root.inputs must be the plugins.json inputNames plus lazy-nvim, no stale or missing node"
    ++
      lib.optional
        (
          !lib.all (
            n: n.locked.type == "path" && !(n.locked ? narHash) && !(lib.hasPrefix "/" n.locked.path)
          ) (builtins.attrValues nonLazyNodes)
        )
        "every plugin node of the fixture flake.lock must be a relative path: node, or the check needs network";
  # Any git call is a failure: the shim logs it and exits 1.
  gitShim = pkgs.writeShellScriptBin "git" ''
    echo "git $*" >> "$GIT_LOG"
    exit 1
  '';
in
assert failures == [ ] || throw (lib.concatStringsSep "\n" failures);
pkgs.runCommand "e2e-offline" {
  nativeBuildInputs = [
    pkgs.neovim-unwrapped
    pkgs.jq
    pkgs.git
    pkgs.nix
    pkgs.nixfmt
    nvimxLib.lockApp
  ];
  lazy = lazy-nvim;
  lua = ../../lua/nvimx;
  inherit fx gitShim;
  inherit (env) farm wrapped;
  ownLock = ../../flake.lock;
  probe = ../e2e-offline-test.lua;
  # Step 3 runs a real nix on a private store. Switch to `if pkgs.stdenv.isLinux then "1" else ""`
  # only if the first darwin CI run shows that store cannot be used there.
  runLockLoop = "1";
} "source ${./scripts/e2e-offline.sh}"
