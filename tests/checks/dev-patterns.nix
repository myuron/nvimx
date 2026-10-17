# devPatterns (#74), in the two halves of checks.dev-plugins: evaluation (`failures`) and a real
# lazy.nvim reading back each plugin's resolved directory. The matching rule is lazy's own
# dev.patterns (lua/lazy/core/meta.lua:221-228), emulated inside the bootstrap's dev.path
# function; checks.dev-plugins stays unchanged and guards that an empty list is a no-op.
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
  noLock = ../fixtures/basic-config/no-such-lock;
  plain = nvimxLib.makeEnv {
    package = pkgs.neovim-unwrapped;
    lockDir = noLock;
  };
  # devPatterns alone must not add names to devDirs: unknownDevPluginNames relies on devDirs
  # meaning "plugin names".
  patternsOnly = nvimxLib.makeEnv {
    package = pkgs.neovim-unwrapped;
    lockDir = noLock;
    devPatterns = [ "folke" ];
  };
  # mkHmCheck asserts nothing, so a dropped pass-through is only visible by reading it back.
  moduleDevPatterns =
    (home-manager.lib.homeManagerConfiguration {
      inherit pkgs;
      modules = [
        self.homeModules.nvimx
        {
          home.username = "nvimx-test";
          home.homeDirectory = "/home/nvimx-test";
          home.stateVersion = "25.05";
          programs.nvimx = {
            enable = true;
            configDir = ../fixtures/basic-config;
            lockDir = ../fixtures/basic-config/nvimx-lock;
            devPatterns = [ "folke" ];
          };
        }
      ];
    }).config.programs.nvimx.env.devPatterns;
  # Runtime half, degraded mode (offline; devPatterns does not depend on the lock).
  patternEnv = nvimxLib.makeEnv {
    package = pkgs.neovim-unwrapped;
    lockDir = noLock;
    devPatterns = [
      "folke/tokyo"
      "nvim-lua"
      "folke/lazy"
    ];
    devPath = "${devRoot}";
  };
  failures =
    lib.optional (plain.devPatterns != [ ]) "devPatterns must default to empty"
    ++ lib.optional (patternsOnly.devDirs != { }) "devPatterns must not leak into devDirs"
    ++ lib.optional (
      moduleDevPatterns != [ "folke" ]
    ) "the hm module must pass devPatterns through to makeEnv";
in
pkgs.runCommand "dev-patterns"
  {
    nativeBuildInputs = [ pkgs.neovim-unwrapped ];
  }
  (
    if failures == [ ] then
      ''
        export HOME=$TMPDIR

        # The matcher shipped, rather than only the pre-#74 function form.
        grep -qF 'matches_dev_pattern' ${patternEnv.bootstrap}

        nvim --clean -l ${../dev-patterns-test.lua} ${patternEnv.bootstrap} \
          ${patternEnv.farm} ${devRoot}

        touch $out
      ''
    else
      ''
        ${lib.concatMapStringsSep "\n" (f: "echo ${lib.escapeShellArg f} >&2") failures}
        exit 1
      ''
  )
