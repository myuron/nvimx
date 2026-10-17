# withPython3 / withRuby / withNodeJs / extraPython3Packages (#73). Like
# extraLuaPackages the promise is a runtime one -- a host that neovim can actually start
# and talk to -- so this starts the wrapped neovim and uses each provider, rather than
# reading vim.g.*_host_prog back and believing it. That distinction is the point for
# node: its host_prog can be set perfectly and the provider still fail, because neovim
# runs it as `node <host>` and needs node on PATH (measured: "'node' is not
# executable"). Each option has three states, so the wrappers below are chosen to tell
# them apart: `on` (all true), `off` (all false), `mixed` (one of each), `untouched`
# (all null, the default). Degraded mode for the same reason as checks.extra-lua-packages:
# nothing here depends on the lock, so not one plugin source is fetchTree'd.
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
  # six: a pure-Python package that pynvim does not pull in (its own dependencies are
  # msgpack and greenlet), so importing it proves extraPython3Packages reached the
  # host rather than riding along with pynvim.
  pythonPackages = ps: [ ps.six ];
  # Everything on, with an extraPackages entry so that there is a --prefix PATH of
  # nvimx's for the providers' --suffix PATH to be told apart from.
  on = mkEnv {
    withPython3 = true;
    extraPython3Packages = pythonPackages;
    withRuby = true;
    withNodeJs = true;
    extraPackages = [ pkgs.hello ];
  };
  off = mkEnv {
    withPython3 = false;
    withRuby = false;
    withNodeJs = false;
  };
  # One of each state, on three different providers: python3 off, ruby not mentioned,
  # node on. `on` and `off` alone cannot see one option leaking into another -- a
  # runtimeDeps that put ruby on PATH whenever *any* provider is on, or a null that
  # falls through to the false branch -- because in them all three always agree.
  mixed = mkEnv {
    withPython3 = false;
    withNodeJs = true;
  };
  # The control, and the proof that the default is a genuine no-op: no provider file,
  # no vim.g.* of nvimx's, nothing new on PATH. (That the derivation itself is
  # unchanged, not merely the script, is shown by the drvPath comparison in the plan's
  # verification steps -- like checks.extra-lua-packages' `untouched`, this is the
  # cheap standing proxy for that, not a proof of it.)
  untouched = mkEnv { };
  # Order against extraWrapperArgs: the provider arguments come before the user's, so
  # a --cmd of the user's runs after nvimx's provider file and can read -- or replace
  # -- what it set. withRuby = false, so that seeing the order costs no host build.
  ordered = mkEnv {
    withRuby = false;
    extraWrapperArgs = [
      "--add-flags"
      "--cmd 'lua vim.g.nvimx_test_seen = vim.g.loaded_ruby_provider'"
    ];
  };
  # Evaluates the module with the given programs.nvimx settings. The results are read
  # through .config (the wrapper, the warnings) and, for moduleEval, .options (the
  # declared defaults). Degraded lockDir, to stay offline.
  evalHm =
    nvimxConfig:
    home-manager.lib.homeManagerConfiguration {
      inherit pkgs;
      modules = [
        self.homeModules.nvimx
        {
          # The three home.* settings homeManagerConfiguration requires, same values
          # mkHmCheck uses. Only .config and .options are read; no activation package
          # is built.
          home.username = "nvimx-test";
          home.homeDirectory = "/home/nvimx-test";
          home.stateVersion = "25.05";
          programs.nvimx = {
            enable = true;
            configDir = ../fixtures/basic-config;
            lockDir = ../fixtures/basic-config/no-such-lock;
          }
          // nvimxConfig;
        }
      ];
    };
  # The module's pass-through, for the reason checks.extra-lua-packages' moduleWrapped
  # gives: mkHmCheck asserts nothing, and the four formals in nix/lib/make-env.nix all
  # carry defaults, so dropping any one of them from the `inherit (cfg)` list in
  # nix/home-manager/default.nix type-checks, builds, and silently ignores the option.
  # All four are set, each to something module.lua can see, so that each drop has its
  # own failing assert: python3 on, a package for it, ruby off, node off.
  # Two of the four drops are reported somewhere else first, though. Without
  # withPython3 or without extraPython3Packages, unusedPython3Packages flips, so the
  # evaluation-level warning asserts in `failures` fail before module.lua is ever
  # run ("must not warn when withPython3 = true" / "must warn about
  # extraPython3Packages ..."), naming the symptom rather than the dropped word.
  # module.lua's first two asserts are the backstop for the day those two change.
  moduleEval = evalHm {
    withPython3 = true;
    extraPython3Packages = pythonPackages;
    withRuby = false;
    withNodeJs = false;
  };
  moduleWrapped = moduleEval.config.programs.nvimx.env.wrapped;
  # extraPython3Packages without withPython3: the silent no-op the warning exists for.
  forgotten = evalHm { extraPython3Packages = pythonPackages; };
  warnsAboutPython = eval: lib.any (lib.hasInfix "extraPython3Packages") eval.config.warnings;
  # A stub for a neovim package nvimx knows nothing about. The hosts are separate
  # processes, so unlike extraLuaPackages nothing here may ask the package for a
  # passthru (lua, version, meta, ...): users bring their own neovim, and
  # wrapNeovimUnstable -- which nix/lib/providers.nix reaches into for rubyEnv -- is
  # exactly the kind of function that might.
  stub = pkgs.runCommand "nvimx-neovim-stub" { } "mkdir -p $out/bin";
  wraps = args: (builtins.tryEval (builtins.seq (mkEnv args).wrapped.drvPath null)).success;
  failures =
    lib.optional (
      !(wraps {
        package = stub;
        withPython3 = true;
        withRuby = true;
        withNodeJs = true;
      })
    ) "the provider hosts must not depend on anything the neovim package exposes"
    # The declared defaults, read out of the declaration rather than observed: no
    # behavioural assert here can tell a module default of null from one of false.
    # moduleEval sets all three explicitly, `forgotten` warns under either, and
    # `untouched` goes through makeEnv's defaults, not the module's. null is what
    # keeps an existing user's wrapper unchanged, so a default of false --
    # programs.neovim's -- would silently switch their providers off.
    ++
      lib.concatMap
        (
          n:
          lib.optional (
            moduleEval.options.programs.nvimx.${n}.default != null
          ) "${n} must be declared with default = null"
        )
        [
          "withPython3"
          "withRuby"
          "withNodeJs"
        ]
    # unusedPython3Packages, all six corners: withPython3 null / true / false, each with the
    # default (no packages) and with packages. The pair that matters most: packages with no
    # host must be reported, and the same packages with a host must not. The two `false`
    # corners tell `withPython3 != true` apart from its look-alikes: with packages it
    # separates it from `withPython3 == null` (the packages of an explicitly disabled host
    # are just as unused), without packages from a test that warns on `false` alone.
    ++ lib.optional ((mkEnv { }).unusedPython3Packages
    ) "the default extraPython3Packages must not be reported as unused"
    ++ lib.optional ((mkEnv { withPython3 = true; }).unusedPython3Packages
    ) "withPython3 = true alone must not be reported as unused packages"
    ++ lib.optional ((mkEnv { withPython3 = false; }).unusedPython3Packages
    ) "withPython3 = false alone must not be reported as unused packages"
    ++ lib.optional (
      !(mkEnv { extraPython3Packages = pythonPackages; }).unusedPython3Packages
    ) "extraPython3Packages without withPython3 = true must be reported as unused"
    ++ lib.optional (
      !(mkEnv {
        withPython3 = false;
        extraPython3Packages = pythonPackages;
      }).unusedPython3Packages
    ) "extraPython3Packages with withPython3 = false must be reported as unused"
    ++ lib.optional on.unusedPython3Packages "extraPython3Packages with withPython3 = true must not be reported as unused"
    # ... and the module has to turn the report into a warning, and only then.
    ++ lib.optional (
      !(warnsAboutPython forgotten)
    ) "the module must warn about extraPython3Packages without withPython3 = true"
    ++ lib.optional (warnsAboutPython moduleEval) "the module must not warn when withPython3 = true";
in
pkgs.runCommand "providers" { } (
  if failures == [ ] then
    ''
      export HOME=$TMPDIR

      # The default must leave the wrapper alone: no provider file among its flags.
      # test -f first, for the reason checks.extra-lua-packages gives (grep -q on a
      # missing file is indistinguishable from "no match" inside an `if`).
      test -f ${untouched.wrapped}/bin/nvim
      if grep -q providers ${untouched.wrapped}/bin/nvim; then
        echo "with every provider left at null the wrapper must not mention providers" >&2
        exit 1
      fi

      cat > untouched.lua <<'LUA'
      for _, prog in ipairs({ "python3", "ruby", "node" }) do
        assert(vim.g[prog .. "_host_prog"] == nil, prog .. ": host_prog is set with the option at null")
        assert(vim.g["loaded_" .. prog .. "_provider"] == nil, prog .. ": provider disabled with the option at null")
      end
      -- The control for everything on.lua concludes: the builder has none of the three
      -- interpreters, so a provider that works in on.lua got its host from the wrapper.
      for _, exe in ipairs({ "python3", "ruby", "node" }) do
        assert(vim.fn.executable(exe) == 0, "the builder's PATH already has " .. exe .. "; on.lua proves nothing")
      end
      assert(vim.fn.has("python3") == 0 and vim.fn.has("ruby") == 0, "a provider works with no option set")
      LUA
      ${untouched.wrapped}/bin/nvim --clean -l untouched.lua

      cat > on.lua <<'LUA'
      local function in_store(p)
        return type(p) == "string" and p:find("${builtins.storeDir}/", 1, true) == 1
      end
      for _, prog in ipairs({ "python3", "ruby", "node" }) do
        assert(in_store(vim.g[prog .. "_host_prog"]), prog .. ": host_prog is not a store path: " .. vim.inspect(vim.g[prog .. "_host_prog"]))
        assert(vim.g["loaded_" .. prog .. "_provider"] == nil, prog .. ": disabled and enabled at once")
      end

      -- Each host has to start and answer, not merely be named.
      assert(vim.fn.has("python3") == 1, "the python3 provider is not usable")
      assert(vim.fn.py3eval("1 + 1") == 2, "the python3 host did not evaluate")
      assert(vim.fn.py3eval('__import__("six").__name__') == "six", "extraPython3Packages did not reach the python3 host")
      assert(vim.fn.has("ruby") == 1, "the ruby provider is not usable")
      assert(vim.fn.rubyeval("1 + 1") == 2, "the ruby host did not evaluate")
      -- Not has("node"): with g:node_host_prog set, provider#node#Detect returns it as
      -- it stands (measured: has("node") is already 1 before the host is ever started),
      -- so it says nothing about whether the host runs. Requiring the host starts the
      -- process, as a node remote plugin's first call does, and returns its channel.
      -- This is the assert that fails without node on PATH.
      assert(vim.fn["remote#host#Require"]("node") > 0, "the node host did not start")

      -- PATH: the hosts' entries are appended (--suffix), so extraPackages -- and
      -- anything the user already had -- stays in front of them.
      local path = vim.split(vim.env.PATH, ":", { plain = true })
      assert(vim.uv.fs_stat(path[1] .. "/hello"), "extraPackages must stay at the front of PATH: " .. vim.env.PATH)
      assert(vim.uv.fs_stat(path[#path - 1] .. "/ruby"), "the ruby env must be appended to PATH: " .. vim.env.PATH)
      assert(vim.uv.fs_stat(path[#path] .. "/node"), "nodejs must be appended to PATH: " .. vim.env.PATH)
      -- python3 is executed through host_prog and needs nothing on PATH; the option
      -- must not start putting an interpreter there (that is extraPackages' job).
      assert(vim.fn.executable("python3") == 0, "the python3 host leaked onto PATH")
      -- Deliberately not nixpkgs' wrapper: the ruby host runs without GEM_HOME, and a
      -- GEM_HOME here would be exported to every process neovim starts.
      assert(vim.env.GEM_HOME == nil, "GEM_HOME must not be set: " .. tostring(vim.env.GEM_HOME))
      LUA
      ${on.wrapped}/bin/nvim --clean -l on.lua

      # The host is started through a wrapper that drops PYTHONPATH / PYTHONSAFEPATH,
      # so that a PYTHONPATH exported for a project cannot be imported into it (and
      # shadow pynvim). Everything in on.lua passes with host_prog pointed straight at
      # the interpreter instead, so this needs a run of its own, with the variables
      # set. vim.env is read back first, for both: it is the control that the variables
      # did reach neovim, without which the two asserts after it would pass vacuously.
      cat > pythonpath.lua <<'LUA'
      assert(vim.env.PYTHONPATH == "/nvimx-test/pythonpath", "PYTHONPATH did not reach neovim; the asserts below prove nothing")
      assert(vim.env.PYTHONSAFEPATH == "1", "PYTHONSAFEPATH did not reach neovim; the last assert proves nothing")
      assert(vim.fn.py3eval('__import__("os").environ.get("PYTHONPATH")') == vim.NIL, "PYTHONPATH leaked into the python3 host")
      assert(vim.fn.py3eval('__import__("os").environ.get("PYTHONSAFEPATH")') == vim.NIL, "PYTHONSAFEPATH leaked into the python3 host")
      LUA
      PYTHONPATH=/nvimx-test/pythonpath PYTHONSAFEPATH=1 ${on.wrapped}/bin/nvim --clean -l pythonpath.lua

      # The use case the issue names: a Python remote plugin, registered with
      # :UpdateRemotePlugins and then called. -u NORC rather than --clean on purpose:
      # runtime/plugin/rplugin.vim skips loading the manifest when --clean is among
      # the arguments, and :UpdateRemotePlugins then has no path to write to. The
      # manifest lands in $HOME/.local/share/nvim, and HOME is this build's TMPDIR.
      mkdir -p plug/rplugin/python3
      cat > plug/rplugin/python3/nvimx_test.py <<'PY'
      import pynvim


      @pynvim.plugin
      class NvimxTest(object):
          def __init__(self, nvim):
              self.nvim = nvim

          @pynvim.function("NvimxTestHello", sync=True)
          def hello(self, args):
              return "hello from python"
      PY
      cat > register.lua <<'LUA'
      vim.opt.rtp:append(vim.uv.cwd() .. "/plug")
      vim.cmd("runtime! plugin/rplugin.vim")
      vim.cmd("UpdateRemotePlugins")
      LUA
      ${on.wrapped}/bin/nvim -u NORC -l register.lua
      cat > call.lua <<'LUA'
      vim.opt.rtp:append(vim.uv.cwd() .. "/plug")
      vim.cmd("runtime! plugin/rplugin.vim")
      assert(vim.fn.NvimxTestHello() == "hello from python", "the remote plugin did not answer")
      LUA
      ${on.wrapped}/bin/nvim -u NORC -l call.lua

      cat > off.lua <<'LUA'
      for _, prog in ipairs({ "python3", "ruby", "node" }) do
        assert(vim.g["loaded_" .. prog .. "_provider"] == 0, prog .. ": false must disable the provider")
        assert(vim.g[prog .. "_host_prog"] == nil, prog .. ": a disabled provider must not get a host")
      end
      assert(vim.fn.executable("ruby") == 0 and vim.fn.executable("node") == 0, "a disabled provider put its interpreter on PATH")
      LUA
      ${off.wrapped}/bin/nvim --clean -l off.lua

      cat > mixed.lua <<'LUA'
      assert(vim.g.loaded_python3_provider == 0 and vim.g.python3_host_prog == nil, "python3 = false")
      assert(vim.g.loaded_ruby_provider == nil and vim.g.ruby_host_prog == nil, "ruby was not mentioned and must be left alone")
      assert(vim.g.loaded_node_provider == nil and vim.g.node_host_prog ~= nil, "node = true")
      assert(vim.fn.executable("node") == 1, "node = true must put node on PATH")
      assert(vim.fn.executable("ruby") == 0, "ruby reached PATH without withRuby = true")
      LUA
      ${mixed.wrapped}/bin/nvim --clean -l mixed.lua

      cat > ordered.lua <<'LUA'
      -- nil would mean the user's --cmd ran before nvimx's provider file.
      assert(vim.g.nvimx_test_seen == 0, "extraWrapperArgs must come after the provider arguments: " .. vim.inspect(vim.g.nvimx_test_seen))
      LUA
      ${ordered.wrapped}/bin/nvim --clean -l ordered.lua

      # The hm module really hands all four options to makeEnv (see moduleWrapped above).
      cat > module.lua <<'LUA'
      assert(vim.fn.has("python3") == 1, "the hm module did not pass withPython3 through")
      assert(vim.fn.py3eval('__import__("six").__name__') == "six", "the hm module did not pass extraPython3Packages through")
      assert(vim.g.loaded_ruby_provider == 0, "the hm module did not pass withRuby through")
      assert(vim.g.loaded_node_provider == 0, "the hm module did not pass withNodeJs through")
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
