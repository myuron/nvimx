# dev.path (#26), in two halves. Evaluation: makeEnv's devDirs / unknownDevPluginNames, which
# force no farm, in the `failures` style of checks.treesitter-grammars. Runtime: the generated
# bootstrap through a real lazy.nvim, reading back each plugin's resolved directory -- the only
# place the string-vs-function "/<name>" asymmetry of lua/lazy/core/meta.lua can be caught.
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
  # A plain readFile of a source file (never IFD), as in checks.resolve-sources. Since #56 no
  # lock records a dir for local plugins; the fixture's dir stands for a plugins.json committed
  # before that, which make-env must keep tolerating. An assertion keeps the value from being
  # "tidied up" into something that would make the ignore-the-dir assertion vacuous.
  dirredRecordedDir =
    (builtins.fromJSON (builtins.readFile ../fixtures/dev-plugins/nvimx-lock/plugins.json))
    .localPlugins."dirred.nvim".dir or null;
  # localPlugins with one entry without `dir` and one with a dir devPath would never produce,
  # plus a devPlugins name in the lock and one in nothing. typo.nvim twice: both outputs must
  # dedupe, or two modules naming the same plugin repeat it in the warning.
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
  # The default is a no-op: empty devDirs, every plugin still under the farm.
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
  # The module's pass-through. checks.hm-module-dev cannot catch a dropped devPlugins / devPath
  # (mkHmCheck asserts nothing, and both makeEnv formals have defaults), so this reads the
  # module's devDirs back; every other env here bypasses the module.
  moduleDevDirs =
    (home-manager.lib.homeManagerConfiguration {
      inherit pkgs;
      modules = [
        self.homeModules.nvimx
        {
          # Same values as mkHmCheck. Only .config is read.
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
  # Runtime half, in degraded mode (offline; devPlugins / devPath do not depend on the lock).
  # dirred.nvim gets a dev_dirs entry even though its spec has a `dir`: lazy must ignore it.
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
    # The fixture records "~/elsewhere/dirred.nvim" so that reading it would differ. A
    # spec-level dir short-circuits lazy before dev.path is consulted, so devPath alone decides.
    ++ lib.optional (
      (locked.devDirs."dirred.nvim" or null) != "~/proj/dirred.nvim"
    ) "a localPlugins entry's recorded dir must be ignored: devPath decides"
    ++ lib.optional (
      dirredRecordedDir == null || dirredRecordedDir == "~/proj/dirred.nvim"
    ) "the fixture's dirred.nvim needs a recorded dir devPath could never produce"
    # typo.nvim stays in devDirs: the entry is inert, unknownDevPluginNames reports it, and
    # filtering it would make devDirs mean different things with and without a lock.
    ++ lib.optional (
      builtins.attrNames locked.devDirs != [
        "bare.nvim"
        "dirred.nvim"
        "tokyonight.nvim"
        "typo.nvim"
      ]
    ) "devDirs must hold exactly the devPlugins names plus the localPlugins keys"
    # The same without naming keys: nothing from plugins.json may reach a value.
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
