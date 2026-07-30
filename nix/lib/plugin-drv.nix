# 1 plugin = 1 derivation.
# Copies the source, runs the recorded shell step(s) if there are any, and generates
# helptags when doc/ exists.
#
# build.kind (recorded by resolve.lua):
#   "none"                          → no build phase
#   "shell"                         → build.cmd runs in the unpacked source directory
#   "steps"                         → build.steps runs in order; only the "shell" steps among
#                                     them execute (each in its own subshell, see below), the
#                                     rest are skipped (resolve.lua warns at lock time)
#   "excmd" / "function" / "rockspec" / "luafile"
#                                   → cannot be run automatically; helptags only (resolve.lua
#                                     warns at lock time)
#
# Every shell step -- scalar or from a "steps" list -- runs in its own `( ... )` subshell, one
# per line inside the parens rather than `( cmd )` on a single line: a trailing `#` comment in
# `cmd` would otherwise swallow the closing paren and fail to parse. The leading `:` keeps an
# empty or comment-only cmd from becoming an empty subshell, which is also a parse error. It has
# to lead rather than trail: a trailing one would become the subshell's exit status and hide a
# failing step whose cmd is an AND-OR list (`set -e` does not fire on `a && b` when `a` fails, so
# `( false && x` / `: )` exits 0). This matches lazy's own
# per-step semantics (lua/lazy/manage/task/plugin.lua:32-40 spawns a fresh shell per step with
# cwd fixed to the plugin dir) and keeps a `cd` inside one step from leaking into the next step
# or into installPhase (#45).
#
# Tools available to a shell build: whatever stdenv provides (cc, gnumake, coreutils,
# gnused/gnugrep/gawk, findutils, tar/gzip/bzip2/xz, patch, diffutils, bash) plus cmake and
# pkg-config. Anything beyond that needs the build-registry / overrides escape hatches.
#
# This is only the *generic* path: which plugins reach it is decided by resolve-plugin.nix.
{ pkgs }:
let
  inherit (pkgs) lib;
  buildNetwork = import ./build-network.nix { inherit lib; };
in
{
  name,
  src,
  build ? {
    kind = "none";
  },
}:
let
  # Normalize to a single shape: a list of { kind, cmd? } steps. A scalar build (shell / excmd /
  # function / rockspec / luafile) is a 1-element list, matching lazy's own normalization
  # (task/plugin.lua:64 treats a scalar build the same as a 1-element list). Steps are numbered
  # from an actual "steps" build only: a 1-element scalar list has no meaningful index to show
  # in an error message.
  isStepsBuild = (build.kind or "none") == "steps";
  steps =
    if isStepsBuild then
      build.steps or [ ]
    else if (build.kind or "none") == "none" then
      [ ]
    else
      [ build ];
  indexedSteps = lib.imap1 (i: s: s // { index = if isStepsBuild then i else null; }) steps;
  shellSteps = builtins.filter (s: (s.kind or "none") == "shell") indexedSteps;
  anyShell = shellSteps != [ ];
  # Fail at evaluation time: a build step needing the network can never succeed in the sandbox,
  # and an explicit message beats an opaque fetch error from deep inside the build log. Checked
  # per step so that a network command anywhere in a "steps" list is caught, not just a scalar one.
  networkSteps = builtins.filter (s: buildNetwork.detect (s.cmd or "") != null) shellSteps;
  firstNetworkStep = if networkSteps == [ ] then null else builtins.head networkSteps;
in
if firstNetworkStep != null then
  throw (
    buildNetwork.message {
      inherit name;
      cmd = firstNetworkStep.cmd;
      tool = buildNetwork.detect firstNetworkStep.cmd;
      step = firstNetworkStep.index;
    }
  )
else
  # Most plugins are pure lua and have no build step at all: keep the C toolchain out of
  # their build closure (it is a meaningful download, especially on darwin).
  (if anyShell then pkgs.stdenv else pkgs.stdenvNoCC).mkDerivation {
    name = "nvimx-plugin-${name}";
    inherit src;

    nativeBuildInputs = [
      pkgs.neovim-unwrapped
    ]
    ++ lib.optionals anyShell [
      pkgs.cmake
      pkgs.pkg-config
    ];

    # The recorded build command(s) are the single source of truth: never let a configure script
    # shipped by the plugin (or cmake's setup hook) take over a phase.
    dontConfigure = true;
    dontUseCmakeConfigure = true;

    # A plugin tree must reach the farm exactly as upstream shipped it. The default fixup
    # hooks are actively harmful here: move-docs relocates doc/ to share/doc/ (breaking :h)
    # and patchShebangs rewrites files such as `#!/usr/bin/env -S nvim -l`.
    dontFixup = true;

    dontBuild = !anyShell;
    buildPhase = lib.optionalString anyShell ''
      runHook preBuild
      ${lib.concatMapStringsSep "\n" (s: "(\n:\n${s.cmd or ""}\n)") shellSteps}
      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall
      mkdir -p $out
      cp -r . $out
      chmod -R u+w $out
      if [ -d $out/doc ]; then
        export HOME=$TMPDIR
        nvim --clean --headless "+helptags $out/doc" +qa!
      fi
      runHook postInstall
    '';
  }
