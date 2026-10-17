# extraWrapperArgs (#72): user makeWrapper arguments appended to the one wrapProgram call.
# Checked at runtime, not by reading the build command (that would pin the quoting, not the
# promise). Pinned: each element arrives as one argument, user arguments come after nvimx's,
# and they share the call with extraPackages / extraLuaPackages without costing either. Nothing
# protects nvimx's own PATH or LUA_PATH from a user --set, and that is pinned too.
# Degraded mode as in checks.extra-lua-packages.
{
  pkgs,
  nvimxLib,
  self,
  home-manager,
  ...
}:
let
  mkEnv =
    args:
    nvimxLib.makeEnv (
      {
        package = pkgs.neovim-unwrapped;
        lockDir = ../fixtures/basic-config/no-such-lock;
      }
      // args
    );
  # Trips the usual careless quotings (space, `;`, `'`, `"`, `$HOME`, `*`). The script spells it
  # out again by hand so one mistake cannot hide on both sides.
  awkward = "a b;c$HOME'd\"e *";
  # extraPackages / extraLuaPackages give each user argument something of nvimx's to land
  # after: PATH before hello's bin/, LUA_PATH before the rock env, --cmd after bootstrap.lua.
  all = mkEnv {
    extraPackages = [ pkgs.hello ];
    extraLuaPackages = ps: [ ps.inspect ];
    extraWrapperArgs = [
      "--set"
      "NVIMX_TEST_ESCAPE"
      awkward
      "--prefix"
      "PATH"
      ":"
      "/nvimx-test/prefix"
      "--suffix"
      "PATH"
      ":"
      "/nvimx-test/suffix"
      "--prefix"
      "LUA_PATH"
      ";"
      "/nvimx-test/?.lua"
      "--add-flags"
      "--cmd 'lua vim.g.nvimx_test_after_bootstrap = package.preload.lazy ~= nil'"
    ];
  };
  # A user --set PATH replaces nvimx's, extraPackages included. Nothing protects nvimx's own
  # arguments, as documented; changing that has to change this check knowingly.
  overridden = mkEnv {
    extraPackages = [ pkgs.hello ];
    extraWrapperArgs = [
      "--set"
      "PATH"
      "/nvimx-test/only"
    ];
  };
  # A user --set LUA_PATH replaces the rocks' path and, without ";;", LuaJIT's default too, while
  # LUA_CPATH stays (README "Wrapper arguments"). luautf8 is a C rock, so it answers for LUA_CPATH.
  luaOverridden = mkEnv {
    extraLuaPackages = ps: [
      ps.inspect
      ps.luautf8
    ];
    extraWrapperArgs = [
      "--set"
      "LUA_PATH"
      "/nvimx-test/?.lua"
    ];
  };
  # ... and with ";;" the interpreter default comes back, the rocks still do not.
  luaOverriddenDefault = mkEnv {
    extraLuaPackages = ps: [ ps.inspect ];
    extraWrapperArgs = [
      "--set"
      "LUA_PATH"
      "/nvimx-test/?.lua;;"
    ];
  };
  # Control: no arguments, so what all.lua sees is known to come from the wrapper.
  untouched = mkEnv { };
  # The module's pass-through, for the reason checks.extra-lua-packages' moduleWrapped gives;
  # here the drop has no other symptom at all, so the module-built wrapper is run.
  moduleWrapped =
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
            lockDir = ../fixtures/basic-config/no-such-lock;
            extraWrapperArgs = [
              "--set"
              "NVIMX_TEST_MODULE"
              "from the module"
            ];
          };
        }
      ];
    }).config.programs.nvimx.env.wrapped;
in
pkgs.runCommand "extra-wrapper-args" {
  allWrapped = all.wrapped;
  overriddenWrapped = overridden.wrapped;
  luaOverriddenWrapped = luaOverridden.wrapped;
  luaOverriddenDefaultWrapped = luaOverriddenDefault.wrapped;
  untouchedWrapped = untouched.wrapped;
  inherit moduleWrapped;
} "source ${./scripts/extra-wrapper-args.sh}"
