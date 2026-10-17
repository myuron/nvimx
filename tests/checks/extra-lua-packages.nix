# extraLuaPackages: the promise is a runtime one -- a rock has to be require-able from a
# built neovim -- so this really starts neovim and requires one, a pure-Lua rock for
# LUA_PATH and a C rock for LUA_CPATH. Deliberately built in degraded mode: the farm is
# then the lazy.nvim seed alone, so not one plugin source is fetchTree'd, and rocks do
# not depend on the lock at all.
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
  # Both kinds of rock and an extraPackages entry at once: a single wrapProgram call has
  # to carry all three, which is what "composes with extraPackages" has to mean.
  # inspect is pure Lua (LUA_PATH) and luautf8 is compiled (LUA_CPATH); neither is
  # bundled with neovim, so requiring them proves the wiring. lpeg would not: neovim
  # ships and preloads it, so require("lpeg") succeeds with no LUA_CPATH at all.
  both = mkEnv {
    extraPackages = [ pkgs.hello ];
    extraLuaPackages = ps: [
      ps.inspect
      ps.luautf8
    ];
  };
  # The negative control, and the proof that the two options stay independent:
  # extraPackages alone must switch on no Lua wiring whatsoever.
  onlyPath = mkEnv { extraPackages = [ pkgs.hello ]; };
  # The default has to be a genuine no-op: with no rocks asked for the wrapper script
  # must not mention LUA_PATH / LUA_CPATH at all. (Byte-for-byte identity with the
  # pre-#27 wrapper -- modulo the wrapper's own store path, which necessarily changes --
  # was verified by hand at implementation time; this assert is the cheap standing proxy
  # for it, not a proof of it.)
  untouched = mkEnv { };
  # The module's pass-through, read back at evaluation level. checks.hm-module-lua-packages
  # exercises the same option but cannot fail on this: mkHmCheck returns only an
  # activationPackage and asserts nothing about it, so dropping extraLuaPackages from
  # makeEnv's argument list in nix/home-manager/default.nix leaves it green -- the option
  # still type-checks, is silently ignored, and the package still builds. The formal in
  # nix/lib/make-env.nix carries a default, so a missing argument is never an error; the
  # absent `...` only rejects arguments makeEnv does not declare, the opposite direction.
  # This check is what catches that drop, and it catches it here: module.lua fails with
  # its own message. A neighbouring regression -- dropping extraLuaPackages from
  # mkWrapper's argument list in nix/lib/make-env.nix, or from wrapper.nix itself -- is
  # caught earlier instead, by the noLua assertion below, because a wrapper that never
  # applies extraLuaPackages also never rejects a package without passthru.lua. That
  # message ("must be refused when rocks are asked for") is then true but points at the
  # wrong symptom, so read this comment before believing it.
  # Degraded lockDir again, to stay offline.
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
            extraLuaPackages = ps: [ ps.inspect ];
          };
        }
      ];
    }).config.programs.nvimx.env.wrapped;
  # A neovim package with no passthru.lua cannot say which Lua a rock has to match, so
  # it must be refused rather than quietly matched against pkgs.lua51Packages -- an ABI
  # mismatch that would only surface as a load error at runtime. A stub stands in for
  # the real case (an already-wrapped pkgs.neovim) so the check does not depend on what
  # nixpkgs happens to put in that wrapper's passthru today.
  noLua = pkgs.runCommand "nvimx-neovim-without-lua" { } "mkdir -p $out/bin";
  wraps = args: (builtins.tryEval (builtins.seq (mkEnv args).wrapped.drvPath null)).success;
  failures =
    lib.optional (wraps {
      package = noLua;
      extraLuaPackages = ps: [ ps.inspect ];
    }) "a neovim package with no passthru.lua must be refused when rocks are asked for"
    # ... and only then: the default (_: [ ]) discards its argument, so laziness has to
    # keep the throw out of the way of everyone who never touches this option. The line
    # is drawn at forcing, not at mentioning -- see the comment in nix/lib/wrapper.nix
    # for which shapes land on which side of it.
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
