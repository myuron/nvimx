# Detection of build commands that cannot possibly run inside the nix sandbox.
#
# A `build = "..."` recorded by resolve.lua is an arbitrary shell command written for a
# machine with a network connection. Commands that reach out to a package registry
# (cargo/npm/go/...) can never work in a sandboxed build, so nvimx refuses them at
# evaluation time with an actionable message instead of letting them die later with an
# opaque fetch error.
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

  # Shell wrappers that only prefix the real command
  wrappers = [
    "env"
    "exec"
    "command"
    "nice"
    "sudo"
    "time"
  ];

  isAssignment = word: builtins.match "[A-Za-z_][A-Za-z0-9_]*=.*" word != null;

  # Strip leading `VAR=x` assignments and wrapper commands so `env FOO=1 cargo build`
  # still resolves to `cargo`.
  stripPrefixes =
    words:
    if words == [ ] then
      [ ]
    else
      let
        word = builtins.head words;
      in
      if isAssignment word || builtins.elem word wrappers then
        stripPrefixes (builtins.tail words)
      else
        words;

  # `(cd build && cmake ..)` / `/usr/bin/curl` → `cmake` / `curl`
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
      words = stripPrefixes (wordsOf segment);
    in
    if words == [ ] then
      null
    else
      let
        head = normalizeWord (builtins.head words);
      in
      if builtins.elem head networkTools then head else null;

  # builtins.split returns the separators as nested lists; keep the plain strings only
  segmentsOf = cmd: builtins.filter builtins.isString (builtins.split "[;&|\n\r]+" cmd);
in
{
  # cmd string → the name of the offending tool, or null when the command looks offline-safe
  detect =
    cmd:
    let
      hits = builtins.filter (t: t != null) (map toolOf (segmentsOf cmd));
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

      This command runs `${tool}`, which downloads from the network. Nix builds run in a
      sandbox with no network access, so nvimx refuses it here rather than failing later
      with an opaque fetch error.

      Use one of these escape hatches:
        - add a recipe under nix/build-registry/ (reuses a nixpkgs vimPlugins build with the locked src)
        - programs.nvimx.plugins.overrides."${name}" = { pkgs, src, defaultDrv }: <your derivation>;
        - programs.nvimx.plugins.nixpkgsFallback = [ "${name}" ];

      See docs/architecture.md ("Plugin derivations") for details.
    '';
}
