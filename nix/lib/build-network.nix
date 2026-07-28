# Detection of build commands that cannot possibly run inside the nix sandbox.
#
# A `build = "..."` recorded by resolve.lua is an arbitrary shell command written for a
# machine with a network connection. Commands that reach out to a package registry
# (cargo/npm/go/...) can never work in a sandboxed build, so nvimx refuses them at
# evaluation time with an actionable message instead of letting them die later with an
# opaque fetch error.
#
# This is a heuristic on a shell string, not a shell parser. Known blind spots, all of
# which fail *open* (the build is attempted and dies in the sandbox):
#   - an interpreter hiding the real command: `sh -c "npm install"`, `bash install.sh`
#   - a Makefile or script that fetches internally: `make deps`
#   - a tool aliased to an unusual name
# Failing open is the deliberate trade-off: a false positive is a hard evaluation failure
# for the user, so detection only fires on evidence it can actually see.
#
# Everything here is a pure function of the command string so that flake checks can
# exercise it directly (see checks.build-network-detect).
{ lib }:
let
  # Tools whose normal invocation downloads dependencies. Matched against the *first word*
  # of each command segment only: a substring match would misfire on things like
  # `make git-stamp`, and a false positive here is a hard build failure for the user.
  networkTools = [
    # language package managers / build tools that resolve dependencies on the fly
    "cargo"
    "npm"
    "npx"
    "yarn"
    "pnpm"
    "bun"
    "go"
    "pip"
    "pip3"
    "poetry"
    "luarocks"
    "gem"
    "bundle"
    "composer"
    "mvn"
    "gradle"
    "dotnet"
    # explicit fetchers
    "curl"
    "wget"
    "git"
    "nix"
  ];

  # Why each tool cannot run here. Most download; git is rejected for a second reason too,
  # so saying "downloads from the network" about it would be misleading.
  reasons = {
    git = "needs network access, or a .git directory that the locked source tree does not have";
  };

  # Shell wrappers that only prefix the real command. `sudo` is meaningless in a sandbox but
  # is listed anyway: its job here is to expose the `cargo` in `sudo cargo build`.
  wrappers = [
    "env"
    "exec"
    "command"
    "nice"
    "nohup"
    "stdbuf"
    "sudo"
    "time"
    "timeout"
    "xargs"
  ];

  isAssignment = word: builtins.match "[A-Za-z_][A-Za-z0-9_]*=.*" word != null;
  isFlag = word: lib.hasPrefix "-" word;
  # `timeout 60` / `sleep 2s`: an argument consumed by a wrapper, not the real command
  isDuration = word: builtins.match "[0-9]+[smhd]?" word != null;

  # Strip leading `VAR=x` assignments and wrapper commands so `env FOO=1 cargo build` and
  # `timeout 60 curl ...` still resolve to `cargo` / `curl`. Flags and durations are only
  # skipped once a wrapper has been seen -- otherwise `make -j4` would lose its head word.
  stripPrefixes =
    words: sawWrapper:
    if words == [ ] then
      [ ]
    else
      let
        word = builtins.head words;
        rest = builtins.tail words;
      in
      if isAssignment word then
        stripPrefixes rest sawWrapper
      else if builtins.elem word wrappers then
        stripPrefixes rest true
      else if sawWrapper && (isFlag word || isDuration word) then
        stripPrefixes rest true
      else
        words;

  # `{ cmake ..` / `/usr/bin/curl` → `cmake` / `curl`
  normalizeWord =
    word:
    let
      unbracketed = builtins.head (builtins.match "[({]*(.*)" word);
    in
    lib.last (lib.splitString "/" unbracketed);

  wordsOf =
    segment:
    builtins.filter (w: w != "") (
      lib.splitString " " (builtins.replaceStrings [ "\t" ] [ " " ] segment)
    );

  toolOf =
    segment:
    let
      words = stripPrefixes (wordsOf segment) false;
    in
    if words == [ ] then
      null
    else
      let
        head = normalizeWord (builtins.head words);
      in
      if builtins.elem head networkTools then head else null;

  # Quoted text is data, not commands: `echo "done; git skipped"` must not read as a git
  # invocation. Collapse every quoted run to a single placeholder word before splitting.
  stripQuoted =
    cmd:
    lib.concatStrings (
      map (part: if builtins.isString part then part else "Q") (builtins.split "'[^']*'|\"[^\"]*\"" cmd)
    );

  # Segment separators. `(`, `)` and backticks are included so that command substitution
  # (`make VERSION=$(git describe)`) is inspected rather than swallowed by the outer command.
  # builtins.split returns the separators as nested lists; keep the plain strings only.
  segmentsOf = cmd: builtins.filter builtins.isString (builtins.split "[;&|`()\n\r]+" cmd);
in
{
  # cmd string → the name of the offending tool, or null when the command looks offline-safe
  detect =
    cmd:
    let
      hits = builtins.filter (t: t != null) (map toolOf (segmentsOf (stripQuoted cmd)));
    in
    if hits == [ ] then null else builtins.head hits;

  # { name, cmd, tool } → the error message shown when a build cannot be run
  message =
    {
      name,
      cmd,
      tool,
    }:
    ''
      nvimx: plugin "${name}" cannot be built automatically.

        build = ${builtins.toJSON cmd}

      This command runs `${tool}`, which ${reasons.${tool} or "downloads from the network"}.
      Nix builds run in a sandbox with no network access, so nvimx refuses it here rather
      than failing later with an opaque fetch error.

      The escape hatches, in the order nvimx applies them:
        - programs.nvimx.plugins.overrides."${name}" = { pkgs, src, ... }: <your derivation>;
        - programs.nvimx.plugins.nixpkgsFallback = [ "${name}" ];
        - a recipe under nix/build-registry/ (reuses a nixpkgs vimPlugins build with the
          locked src) -- not implemented yet, nvimx issue #19

      See docs/architecture.md ("Plugin derivations") for details.
    '';
}
