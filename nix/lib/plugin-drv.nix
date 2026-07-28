# 1 plugin = 1 derivation.
# Copies the source, runs the recorded shell build if there is one, and generates
# helptags when doc/ exists.
#
# build.kind (recorded by resolve.lua):
#   "none"              → no build phase
#   "shell"             → build.cmd runs in the unpacked source directory
#   "excmd" / "function" → cannot be run automatically; helptags only (warned at lock time, #22)
#
# Tools available to a shell build: whatever stdenv provides (cc, gnumake, coreutils,
# gnused/gnugrep/gawk, findutils, tar/gzip/bzip2/xz, patch, diffutils, bash) plus cmake and
# pkg-config. Anything beyond that needs the build-registry / overrides escape hatches.
#
# TODO (Phase 5): build-registry, overrides, nixpkgsFallback
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
  isShell = (build.kind or "none") == "shell";
  cmd = build.cmd or "";
  # Fail at evaluation time: a build needing the network can never succeed in the sandbox,
  # and an explicit message beats an opaque fetch error from deep inside the build log.
  networkTool = if isShell then buildNetwork.detect cmd else null;
in
if networkTool != null then
  throw (
    buildNetwork.message {
      inherit name cmd;
      tool = networkTool;
    }
  )
else
  # Most plugins are pure lua and have no build step at all: keep the C toolchain out of
  # their build closure (it is a meaningful download, especially on darwin).
  (if isShell then pkgs.stdenv else pkgs.stdenvNoCC).mkDerivation {
    name = "nvimx-plugin-${name}";
    inherit src;

    nativeBuildInputs = [
      pkgs.neovim-unwrapped
    ]
    ++ lib.optionals isShell [
      pkgs.cmake
      pkgs.pkg-config
    ];

    # The recorded build command is the single source of truth: never let a configure script
    # shipped by the plugin (or cmake's setup hook) take over a phase.
    dontConfigure = true;
    dontUseCmakeConfigure = true;

    # A plugin tree must reach the farm exactly as upstream shipped it. The default fixup
    # hooks are actively harmful here: move-docs relocates doc/ to share/doc/ (breaking :h)
    # and patchShebangs rewrites files such as `#!/usr/bin/env -S nvim -l`.
    dontFixup = true;

    dontBuild = !isShell;
    buildPhase = lib.optionalString isShell ''
      runHook preBuild
      ${cmd}
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
