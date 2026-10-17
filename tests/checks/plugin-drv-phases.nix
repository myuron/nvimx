# Phase behavior per build.kind, and the reasons plugin-drv sets dontFixup.
# Hermetic: the source is a local fixture, so nothing here needs the network.
{
  pkgs,
  nvimxLib,
  ...
}:
let
  mkLocal =
    build:
    nvimxLib.mkPluginDrv {
      name = "local-plugin";
      src = ../fixtures/local-plugin;
      inherit build;
    };
  shell = mkLocal {
    kind = "shell";
    cmd = "make";
  };
  excmd = mkLocal {
    kind = "excmd";
    cmd = ":TSUpdate";
  };
  none = mkLocal { kind = "none"; };
  # Two ordered shell steps: step 2 only appends if step 1's file exists, so a mis-ordered or
  # dropped step fails the build. The `&&` shape is deliberate: a trailing no-op in the step
  # subshell would swallow its failure, so this also guards how that subshell is written.
  orderedSteps = mkLocal {
    kind = "steps";
    steps = [
      {
        kind = "shell";
        cmd = "mkdir -p build && echo one > build/order.txt";
      }
      {
        kind = "shell";
        cmd = "test -f build/order.txt && echo two >> build/order.txt";
      }
    ];
  };
  # A mix of runnable and unrunnable steps. Step 1's `cd lua` must not leak into step
  # 3's `make` (which needs to run at the plugin root to find the Makefile) or into
  # installPhase (#45) -- and the skipped excmd step must not break the steps after it.
  mixedSteps = mkLocal {
    kind = "steps";
    steps = [
      {
        kind = "shell";
        cmd = "cd lua && touch inner";
      }
      {
        kind = "excmd";
        cmd = ":TSUpdate";
      }
      {
        kind = "shell";
        cmd = "make";
      }
    ];
  };
  # No step in this list can run at build time, so this must behave exactly like
  # kind = "none": no build/ directory, helptags only.
  allUnrunnableSteps = mkLocal {
    kind = "steps";
    steps = [
      {
        kind = "excmd";
        cmd = ":Foo";
      }
      { kind = "function"; }
    ];
  };
  # #45: a scalar build that `cd`s must not leak that directory into installPhase (it used to
  # produce a $out holding only lua/'s contents).
  cwdLeak = mkLocal {
    kind = "shell";
    cmd = "cd lua && touch marker";
  };
in
pkgs.runCommand "plugin-drv-phases" { } ''
  # only kind == "shell" / "steps" (with a shell step in it) runs a build
  test -f ${shell}/build/artifact.txt
  test ! -e ${excmd}/build
  test ! -e ${none}/build

  for p in ${shell} ${excmd} ${none} ${orderedSteps} ${mixedSteps} ${allUnrunnableSteps} ${cwdLeak}; do
    # helptags are generated for every kind
    test -f "$p/doc/tags"
    # doc/ must stay at the plugin root: stdenv's move-docs hook would relocate it
    # to share/doc/ and break :h
    test ! -e "$p/share"
    # upstream files must survive verbatim: patchShebangs rewrites this line into
    # `env -S  -l`, dropping the interpreter
    grep -qF '#!/usr/bin/env -S nvim -l' "$p/scripts/run"
  done

  # steps run in declared order: step 2 could only have appended if step 1 already ran
  test "$(cat ${orderedSteps}/build/order.txt)" = "$(printf 'one\ntwo\n')"

  # mixed: the shell steps ran (at the plugin root, not inside lua/) and the excmd
  # step in between was skipped without breaking the shell step after it
  test -f ${mixedSteps}/lua/inner
  test -f ${mixedSteps}/build/artifact.txt

  # all steps unrunnable: no build ran at all
  test ! -e ${allUnrunnableSteps}/build

  # #45: a `cd` inside one build step/subshell must not survive into installPhase --
  # the whole tree (not just lua/) must still reach $out
  test -f ${cwdLeak}/lua/marker
  test -f ${cwdLeak}/Makefile
  test -f ${cwdLeak}/doc/tags

  touch $out
''
