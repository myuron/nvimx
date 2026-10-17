# extraWrapperArgs (#72): the user's own makeWrapper arguments, appended to the one
# wrapProgram call. Like extraLuaPackages the promise is a runtime one, and like
# extraPackages and extraLuaPackages this argument has no makeEnv output of its own. Its
# text could be read back from wrapped's build command at evaluation time, but that would
# pin how lib.escapeShellArgs happens to quote it rather than the promise, so the check
# starts the wrapped neovim and looks at the environment it actually got. Three promises
# are pinned: each list element arrives as one argument whatever characters it holds
# (lib.escapeShellArgs), the arguments come after nvimx's own so that they act on what
# nvimx set up, and they sit in the same call as extraPackages / extraLuaPackages without
# costing either. Degraded mode for the same reason as checks.extra-lua-packages: nothing
# here depends on the lock, so not one plugin source is fetchTree'd.
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
  # A value picked to trip the usual careless quotings: a space and a `;` for a bare
  # join, a `'` for naive single-quoting, a `"` and a `$HOME` for naive double-quoting,
  # a `*` for anything left unquoted. all.lua spells the same value out a second time
  # by hand rather than having it interpolated from here, so that one mistake cannot
  # hide on both sides.
  awkward = "a b;c$HOME'd\"e *";
  # Everything at once. extraPackages and extraLuaPackages are set so that there is
  # something of nvimx's for each user argument to land after, which is how
  # "after" gets observed: --prefix PATH has to end up in front of hello's bin/,
  # --prefix LUA_PATH in front of the rock env, and the --cmd has to run once
  # bootstrap.lua has already installed package.preload["lazy"].
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
  # The escape hatch taken all the way: a --set after nvimx's --prefix PATH replaces
  # it, extraPackages included. Nothing protects nvimx's own arguments, on purpose, and
  # the option description and the README both say so -- this pins the PATH half of
  # that: a later guard on PATH, or a reordering, has to come here and change the
  # documented contract knowingly.
  overridden = mkEnv {
    extraPackages = [ pkgs.hello ];
    extraWrapperArgs = [
      "--set"
      "PATH"
      "/nvimx-test/only"
    ];
  };
  # The control: a wrapper that was given no arguments, checked for the absence of the
  # variable, the PATH entries and the marker all.lua looks for, so that those are known
  # to come from the wrapper and not from the builder.
  untouched = mkEnv { };
  # The module's pass-through. checks.hm-module-wrapper-args exercises the same option
  # but cannot fail on this, for exactly the reason checks.extra-lua-packages'
  # moduleWrapped gives: mkHmCheck asserts nothing, and the formal in
  # nix/lib/make-env.nix has a default, so dropping extraWrapperArgs from the
  # `inherit (cfg)` list in nix/home-manager/default.nix type-checks, builds, and
  # silently ignores the option. And where extraLuaPackages at least has a second
  # symptom (the passthru.lua throw), this option has no such thing: the drop shows nowhere
  # but in the module-built wrapper, which is why that gets run. The neighbouring drop --
  # from mkWrapper's inherit list in nix/lib/make-env.nix -- is caught by all.lua, and
  # dropping the formal from nix/lib/wrapper.nix or nix/lib/make-env.nix is an
  # evaluation error: an undefined variable while its use is still there, an unexpected
  # argument once that is gone as well, since neither function takes `...`. Degraded
  # lockDir again, to stay offline.
  moduleWrapped =
    (home-manager.lib.homeManagerConfiguration {
      inherit pkgs;
      modules = [
        self.homeModules.nvimx
        {
          # The three home.* settings homeManagerConfiguration requires, same values
          # mkHmCheck uses. Only .config is read; no activation package is built.
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
  untouchedWrapped = untouched.wrapped;
  inherit moduleWrapped;
} "source ${./scripts/extra-wrapper-args.sh}"
