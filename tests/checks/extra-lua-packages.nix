# extraLuaPackages (#27): a rock has to be require-able from a built neovim, so this starts
# neovim and requires a pure-Lua rock (LUA_PATH) and a C rock (LUA_CPATH). Degraded mode: the
# farm is the lazy.nvim seed alone, nothing is fetchTree'd, and rocks do not depend on the lock.
{
  pkgs,
  nvimxLib,
  self,
  home-manager,
  ...
}:
let
  inherit (pkgs) lib;
  mkEnv =
    args:
    nvimxLib.makeEnv (
      {
        package = pkgs.neovim-unwrapped;
        lockDir = ../fixtures/basic-config/no-such-lock;
      }
      // args
    );
  # Both kinds of rock plus extraPackages in one wrapProgram call. Neither rock ships with
  # neovim (unlike lpeg, which would resolve with no LUA_CPATH at all).
  both = mkEnv {
    extraPackages = [ pkgs.hello ];
    extraLuaPackages = ps: [
      ps.inspect
      ps.luautf8
    ];
  };
  # Negative control: extraPackages alone must switch on no Lua wiring.
  onlyPath = mkEnv { extraPackages = [ pkgs.hello ]; };
  # The default is a no-op: the wrapper must not mention LUA_PATH / LUA_CPATH at all.
  untouched = mkEnv { };
  # The module's pass-through. checks.hm-module-lua-packages cannot catch a dropped
  # extraLuaPackages: mkHmCheck asserts nothing, and makeEnv's formal has a default, so the
  # option would be silently ignored. module.lua catches it. (Dropping it further down, in
  # make-env.nix or wrapper.nix, trips the noLua assertion first, with a misleading message.)
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
            extraLuaPackages = ps: [ ps.inspect ];
          };
        }
      ];
    }).config.programs.nvimx.env.wrapped;
  # Without passthru.lua there is no Lua for rocks to match, so it must be refused rather than
  # guessed (an ABI mismatch would only show at runtime). A stub stands in for an
  # already-wrapped pkgs.neovim, independent of what nixpkgs puts in its passthru.
  noLua = pkgs.runCommand "nvimx-neovim-without-lua" { } "mkdir -p $out/bin";
  wraps = args: (builtins.tryEval (builtins.seq (mkEnv args).wrapped.drvPath null)).success;
  failures =
    lib.optional (wraps {
      package = noLua;
      extraLuaPackages = ps: [ ps.inspect ];
    }) "a neovim package with no passthru.lua must be refused when rocks are asked for"
    # ... and only then: laziness keeps the throw away from users who never set the option
    # (see nix/lib/wrapper.nix).
    ++ lib.optional (
      !(wraps { package = noLua; })
    ) "a neovim package with no passthru.lua must still wrap when no rocks are asked for";
in
pkgs.runCommand "extra-lua-packages" { } (
  if failures == [ ] then
    ''
      export HOME=$TMPDIR

      # An empty list must leave the environment alone. Not "sets it to something
      # harmless" -- absent, so that the wrapper stays what it was before #27.
      for w in ${untouched.wrapped} ${onlyPath.wrapped}; do
        # grep -q exits 2 on a missing file, which inside an `if` is indistinguishable
        # from "no match" and does not trip set -e. Without this the assert could pass
        # vacuously.
        test -f "$w/bin/nvim"
        if grep -q LUA_ "$w/bin/nvim"; then
          echo "an empty extraLuaPackages must not touch LUA_PATH / LUA_CPATH: $w" >&2
          exit 1
        fi
      done

      cat > rocks.lua <<'LUA'
      local function has(s, sub)
        return s:find(sub, 1, true) ~= nil
      end
      assert(require("inspect"), "a pure-Lua rock must be require-able (LUA_PATH)")
      assert(require("lua-utf8").len("ab") == 2, "a C rock must be loadable (LUA_CPATH)")
      -- makeWrapper's --prefix drops empty components, so a trailing ";;" cannot be
      -- smuggled in through the value; --set-default is what keeps the interpreter's
      -- own default path alive. Without it a single rock would take out require("jit.dump").
      assert(has(package.path, "./?.lua"), "default package.path lost: " .. package.path)
      assert(has(package.cpath, "./?.so"), "default package.cpath lost: " .. package.cpath)
      -- extraPackages still reaches PATH from the same wrapProgram call ...
      assert(vim.fn.executable("hello") == 1, "extraPackages did not survive alongside rocks")
      -- ... and the rock env's own bin/ does not. Putting an interpreter on PATH is
      -- extraPackages' job, and this option must not start doing it. (Which is also why
      -- this check must never put a Lua on the builder's PATH itself.)
      assert(vim.fn.executable("luajit") == 0, "the rock env leaked onto PATH")
      LUA
      # env -u: the "the interpreter default survived" asserts only mean that if the
      # builder hands nvim no LUA_PATH / LUA_CPATH of its own. Nothing sets them today,
      # but the assert is about --set-default, so do not let the environment answer for it.
      env -u LUA_PATH -u LUA_CPATH ${both.wrapped}/bin/nvim --clean -l rocks.lua

      # --prefix, not --set: a LUA_PATH the user already exports has to survive.
      cat > user.lua <<'LUA'
      assert(package.path:find("/user/?.lua", 1, true), "an exported LUA_PATH was clobbered: " .. package.path)
      assert(package.cpath:find("/user/?.so", 1, true), "an exported LUA_CPATH was clobbered: " .. package.cpath)
      LUA
      LUA_PATH='/user/?.lua' LUA_CPATH='/user/?.so' ${both.wrapped}/bin/nvim --clean -l user.lua

      # Negative control: the same rock must not resolve without the option.
      cat > norocks.lua <<'LUA'
      assert(not pcall(require, "inspect"), "inspect resolved with no extraLuaPackages")
      assert(vim.fn.executable("hello") == 1, "extraPackages did not reach PATH")
      LUA
      env -u LUA_PATH -u LUA_CPATH ${onlyPath.wrapped}/bin/nvim --clean -l norocks.lua

      # The hm module really hands the option to makeEnv (see moduleWrapped above).
      cat > module.lua <<'LUA'
      assert(require("inspect"), "the hm module did not pass extraLuaPackages through")
      LUA
      ${moduleWrapped}/bin/nvim --clean -l module.lua

      touch $out
    ''
  else
    ''
      ${lib.concatMapStringsSep "\n" (f: "echo ${lib.escapeShellArg f} >&2") failures}
      exit 1
    ''
)
