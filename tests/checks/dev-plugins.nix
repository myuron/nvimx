# dev.path is the one forced lazy opt that stops being a constant with #26, so this check
# has two halves. The first is pure evaluation of makeEnv's new devDirs /
# unknownDevPluginNames outputs -- neither forces the farm, so it costs nothing and
# fetches nothing -- in the `failures`-list style of checks.treesitter-grammars. The
# second runs the *generated bootstrap* through a real lazy.nvim and reads back the
# directory it resolved each plugin to: the only place the string-vs-function "/<name>"
# asymmetry of lua/lazy/core/meta.lua:229-231 can actually be caught.
{
  pkgs,
  nvimxLib,
  self,
  home-manager,
  ...
}:
let
  inherit (pkgs) lib;
  devRoot = ../fixtures/dev-plugins/dev-root;
  # Same evaluation-time *read* checks.resolve-sources and checks.genflake-golden use:
  # the fixture is a source file, so reading it is a plain readFile and never IFD. The
  # guard half does not carry over -- those two throw while the derivation is
  # instantiated, so `nix eval .#checks....drvPath` catches them, while this one lands
  # in `failures` like every other assertion here and surfaces on build instead. The
  # assertion below is what proves the value it holds still matters. #56 made
  # resolve.lua record `{ }` for every local plugin, so no lock this repo produces
  # still carries a dir here at all, and two edits then make the "recorded dir must be
  # ignored" assertion pass for the wrong reason: strip the fixture's dir to "match
  # reality" and there is nothing left to ignore, or set it to what devPath would
  # produce and reading it would give the same answer as ignoring it. What the dir
  # stands for is a plugins.json committed before #56, a shape make-env has to keep
  # tolerating for as long as anyone still has one checked in.
  dirredRecordedDir =
    (builtins.fromJSON (builtins.readFile ../fixtures/dev-plugins/nvimx-lock/plugins.json))
    .localPlugins."dirred.nvim".dir or null;
  # Evaluation half. A lock with a non-empty localPlugins -- one entry with no `dir`
  # and one whose recorded `dir` points somewhere devPath would never produce -- plus
  # one devPlugins name that matches a locked plugin and one that matches nothing.
  # typo.nvim is listed twice on purpose: both devDirs and unknownDevPluginNames must
  # dedupe, the way unknownPluginNames does, or the warning repeats a name per
  # occurrence -- which is what two modules each naming the same plugin produces.
  locked = nvimxLib.makeEnv {
    package = pkgs.neovim-unwrapped;
    lockDir = ../fixtures/dev-plugins/nvimx-lock;
    devPlugins = [
      "tokyonight.nvim"
      "typo.nvim"
      "typo.nvim"
    ];
    devPath = "~/proj";
  };
  # The default has to be a genuine no-op: basic-config's localPlugins is empty and
  # nothing is named here, so devDirs must come out empty and bootstrap.lua must keep
  # resolving every plugin under the farm.
  untouched = nvimxLib.makeEnv {
    package = pkgs.neovim-unwrapped;
    lockDir = ../fixtures/basic-config/nvimx-lock;
  };
  # Degraded mode has no lock to judge a name against, so it must never call one a typo.
  degraded = nvimxLib.makeEnv {
    package = pkgs.neovim-unwrapped;
    lockDir = ../fixtures/basic-config/no-such-lock;
    devPlugins = [ "typo.nvim" ];
  };
  # The module's pass-through, read back at evaluation level. checks.hm-module-dev
  # exercises the same options but cannot fail on this: mkHmCheck returns only an
  # activationPackage and asserts nothing about it, so dropping devPlugins or devPath
  # from makeEnv's argument list in nix/home-manager/default.nix leaves it green -- the
  # options still type-check, are silently ignored, and the package still builds.
  # Dropping either one is equally silent: both formals carry defaults
  # (nix/lib/make-env.nix), so a missing argument is never an error -- the absent `...`
  # only rejects arguments makeEnv does not declare, which is the opposite direction.
  # This assertion is the only guard for all three drop combinations. Every other env
  # here calls makeEnv directly and so bypasses the module, which is why this one does
  # not.
  moduleDevDirs =
    (home-manager.lib.homeManagerConfiguration {
      inherit pkgs;
      modules = [
        self.homeModules.nvimx
        {
          # The three home.* settings homeManagerConfiguration requires, same values
          # mkHmCheck uses. Nothing here is built -- only .config is read.
          home.username = "nvimx-test";
          home.homeDirectory = "/home/nvimx-test";
          home.stateVersion = "25.05";
          programs.nvimx = {
            enable = true;
            configDir = ../fixtures/basic-config;
            lockDir = ../fixtures/basic-config/nvimx-lock;
            devPlugins = [ "tokyonight.nvim" ];
            devPath = "~/proj";
          };
        }
      ];
    }).config.programs.nvimx.env.devDirs;
  # Runtime half, deliberately built in degraded mode: the farm is then the lazy.nvim
  # seed alone -- no lock, no fetchTree, fully offline -- while devPlugins / devPath
  # still apply, because they do not depend on the lock at all.
  # dirred.nvim is named here on purpose even though the driver's spec gives it a
  # `dir`: the point is that it gets a dev_dirs entry and lazy still ignores it.
  devEnv = nvimxLib.makeEnv {
    package = pkgs.neovim-unwrapped;
    lockDir = ../fixtures/basic-config/no-such-lock;
    devPlugins = [
      "tokyonight.nvim"
      "bare.nvim"
      "dirred.nvim"
    ];
    devPath = "${devRoot}";
  };
  plainEnv = nvimxLib.makeEnv {
    package = pkgs.neovim-unwrapped;
    lockDir = ../fixtures/basic-config/no-such-lock;
  };
  failures =
    lib.optional (
      (locked.devDirs."tokyonight.nvim" or null) != "~/proj/tokyonight.nvim"
    ) "a devPlugins name must override a plugin that is in the lock"
    ++ lib.optional (
      (locked.devDirs."bare.nvim" or null) != "~/proj/bare.nvim"
    ) "a localPlugins key must route to <devPath>/<name>"
    # The fixture records dir = "~/elsewhere/dirred.nvim" for this one precisely so that
    # reading it back would produce a different answer. Since #56 resolve.lua records no
    # dir at all, a value here means a plugins.json committed before that change; back
    # then a dir the spec wrote absolute came through unchanged, which is why this one
    # is ignored not for being machine-specific but because a spec-level dir
    # short-circuits lazy before dev.path is ever consulted (lua/lazy/core/meta.lua:214-217)
    # -- reading it could not change any resolved directory. devPath decides,
    # and stays the only thing that does. dirredRecordedDir above is what keeps this
    # value from being "tidied up" into something devPath could produce, which would
    # leave this assertion passing with nothing left to ignore.
    ++ lib.optional (
      (locked.devDirs."dirred.nvim" or null) != "~/proj/dirred.nvim"
    ) "a localPlugins entry's recorded dir must be ignored: devPath decides"
    ++ lib.optional (
      dirredRecordedDir == null || dirredRecordedDir == "~/proj/dirred.nvim"
    ) "the fixture's dirred.nvim needs a recorded dir devPath could never produce"
    # typo.nvim is in this list on purpose. A devPlugins name that matches nothing in
    # the lock still gets a devDirs entry: it is inert (no plugin carries that name, so
    # lazy never looks it up), unknownDevPluginNames is what reports the typo, and
    # filtering it here would tie the dev-dir map to lock validation -- making devDirs
    # mean something different with and without a lock -- for no behavioral gain.
    ++ lib.optional (
      builtins.attrNames locked.devDirs != [
        "bare.nvim"
        "dirred.nvim"
        "tokyonight.nvim"
        "typo.nvim"
      ]
    ) "devDirs must hold exactly the devPlugins names plus the localPlugins keys"
    # The same statement without naming keys, so it keeps holding as the fixture grows:
    # nothing machine-specific out of plugins.json may ever reach a value here.
    ++ lib.optional (
      !lib.all (lib.hasPrefix "~/proj/") (builtins.attrValues locked.devDirs)
    ) "every devDirs value must sit under devPath, whatever the lock recorded"
    ++ lib.optional (
      locked.unknownDevPluginNames != [ "typo.nvim" ]
    ) "a devPlugins name in neither the lock nor localPlugins must be reported, and only that one"
    ++ lib.optional (
      untouched.devDirs != { }
    ) "devDirs must be empty when nothing asked for a dev plugin"
    ++ lib.optional (
      degraded.unknownDevPluginNames != [ ]
    ) "degraded mode has no lock to judge devPlugins names against, so it must report none"
    ++ lib.optional (
      moduleDevDirs != { "tokyonight.nvim" = "~/proj/tokyonight.nvim"; }
    ) "the hm module must pass devPlugins / devPath through to makeEnv";
in
pkgs.runCommand "dev-plugins"
  {
    nativeBuildInputs = [ pkgs.neovim-unwrapped ];
  }
  (
    if failures == [ ] then
      ''
        export HOME=$TMPDIR

        # The working tree really is a directory in the store, so the dev dir asserted
        # on below is not merely a string that happens to match.
        test -f ${devRoot}/tokyonight.nvim/lua/tokyonight-dev.lua

        # What shipped is the function form, not a string. Guards against a revert to
        # `path = farm` that would still pass every evaluation-level assertion above.
        grep -qF 'dev_dirs[plugin.name]' ${plainEnv.bootstrap}

        # With devPlugins: the named plugins resolve to their working trees (both the
        # devPlugins one and the spec's own bare `dev = true`), everything else still
        # to the farm. The driver additionally pins dirred.nvim to the `dir` its spec
        # writes, proving lazy short-circuits past the dev_dirs entry devEnv gave it.
        nvim --clean -l ${../dev-path-test.lua} ${devEnv.bootstrap} \
          ${devEnv.farm} ${devRoot}/tokyonight.nvim ${devEnv.farm}/plenary.nvim \
          ${devRoot}/bare.nvim

        # Without: every plugin dev.path decides resolves to <farm>/<name>, byte for
        # byte what the old `path = farm` string produced. This is #26's "with no dev
        # plugins, the generated bootstrap.lua is functionally identical to today's".
        nvim --clean -l ${../dev-path-test.lua} ${plainEnv.bootstrap} \
          ${plainEnv.farm} ${plainEnv.farm}/tokyonight.nvim ${plainEnv.farm}/plenary.nvim \
          ${plainEnv.farm}/bare.nvim

        touch $out
      ''
    else
      ''
        ${lib.concatMapStringsSep "\n" (f: "echo ${lib.escapeShellArg f} >&2") failures}
        exit 1
      ''
  )
