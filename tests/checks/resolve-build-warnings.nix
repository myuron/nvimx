# A build nvimx cannot run (:excmd / Lua callback / list of steps) must be reported at
# lock time, and must stay a warning: locking has to succeed anyway (#22).
# The real lock app ends in `nix flake lock`, which needs the network, so this exercises
# the two offline stages it chains -- extract then resolve -- which is the part under test.
{
  pkgs,
  lazy-nvim,
  ...
}:
pkgs.runCommand "resolve-build-warnings"
  {
    nativeBuildInputs = [
      pkgs.neovim-unwrapped
      pkgs.jq
    ];
  }
  ''
    export HOME=$TMPDIR
    sb=$TMPDIR/sandbox
    mkdir -p $sb/config $sb/data/nvim/lazy $sb/state $sb/cache
    ln -s ${lazy-nvim} $sb/data/nvim/lazy/lazy.nvim

    extract() { # <fixture> <raw-spec output>
      rm -f $sb/config/nvim
      ln -s "$1" $sb/config/nvim
      env \
        XDG_CONFIG_HOME=$sb/config \
        XDG_DATA_HOME=$sb/data \
        XDG_STATE_HOME=$sb/state \
        XDG_CACHE_HOME=$sb/cache \
        NVIMX_LAZY_SEED=${lazy-nvim} \
        NVIMX_OUT="$2" \
        nvim --headless --cmd "luafile ${../../lua/nvimx/extract.lua}"
    }

    extract ${../fixtures/unbuildable-config} $sb/unbuildable.json
    rc=0
    # the whole directory, not the single file: resolve.lua dofile()s json.lua next to it
    nvim -l ${../../lua/nvimx}/resolve.lua $sb/unbuildable.json plugins.json \
      --lazy ${lazy-nvim} 2> stderr.log || rc=$?
    cat stderr.log >&2
    if [ "$rc" -ne 0 ]; then
      echo "resolve.lua must warn, not fail: got rc=$rc" >&2
      exit 1
    fi

    # one warning per plugin, each naming the shape of the build it cannot run.
    # LuaSnip's list build moved to build-steps-config (#36): it is now all-shell and
    # builds silently, so this fixture only covers the two shapes nothing can run at
    # all (verbatim strings, pinned so a rewording of the scalar path is noticed).
    grep -q '^\[nvimx\] warning: plugin "nvim-treesitter": build is a neovim command (":TSUpdate")' stderr.log
    grep -q '^\[nvimx\] warning: plugin "markdown-preview.nvim": build is a Lua function ("<function>")' stderr.log
    n=$(grep -c '^\[nvimx\] warning: plugin ' stderr.log)
    if [ "$n" -ne 2 ]; then
      echo "expected exactly 2 plugin warnings, got $n" >&2
      exit 1
    fi

    # every escape hatch is named, plus the treesitter-specific pointer
    grep -q 'plugins.overrides' stderr.log
    grep -q 'plugins.nixpkgsFallback' stderr.log
    grep -q 'nix/build-registry/' stderr.log
    grep -q 'programs.nvimx.treesitter.grammars' stderr.log

    # the same warnings are recorded in the lock, sorted by plugin name so that
    # re-locking does not reshuffle the array
    jq -e '.warnings | length == 2' plugins.json > /dev/null
    jq -e '.warnings[0] | startswith("plugin \"markdown-preview.nvim\"")' plugins.json > /dev/null
    jq -e '.warnings[1] | startswith("plugin \"nvim-treesitter\"")' plugins.json > /dev/null
    # the "<function>" placeholder must not leak into build.cmd
    jq -e '.plugins["markdown-preview.nvim"].build == { kind: "function" }' plugins.json > /dev/null
    jq -e '.plugins["nvim-treesitter"].build.cmd == ":TSUpdate"' plugins.json > /dev/null

    # ...and the quiet path: a build nvimx *can* run must say nothing at all.
    # Without this, warning about every build would pass every assertion above.
    extract ${../fixtures/build-plugins} $sb/buildable.json
    nvim -l ${../../lua/nvimx}/resolve.lua $sb/buildable.json quiet.json --lazy ${lazy-nvim} 2> quiet.log
    if [ -s quiet.log ]; then
      echo "a shell build must not warn, got:" >&2
      cat quiet.log >&2
      exit 1
    fi
    jq -e '.warnings == []' quiet.json > /dev/null

    # Table-form build (#36): every element is classified and none are lost, the
    # mixed case warns with the step index and the treesitter pointer, the all-shell
    # case is silent, and rockspec/luafile/false get their own kind rather than being
    # run as shell commands (the regression #36's classifier could introduce, #3.4).
    extract ${../fixtures/build-steps-config} $sb/steps.json
    rc=0
    nvim -l ${../../lua/nvimx}/resolve.lua $sb/steps.json steps-plugins.json \
      --lazy ${lazy-nvim} 2> steps.log || rc=$?
    cat steps.log >&2
    if [ "$rc" -ne 0 ]; then
      echo "resolve.lua must warn, not fail, on table-form builds: got rc=$rc" >&2
      exit 1
    fi

    # mixed table: no step lost, order preserved, and it counts as unbuildable
    jq -e '.plugins["nvim-treesitter"].build.kind == "steps"' steps-plugins.json > /dev/null
    jq -e '.plugins["nvim-treesitter"].build.steps | length == 2' steps-plugins.json > /dev/null
    jq -e '.plugins["nvim-treesitter"].build.steps[0] == { kind: "shell", cmd: "make" }' \
      steps-plugins.json > /dev/null
    jq -e '.plugins["nvim-treesitter"].build.steps[1] == { kind: "excmd", cmd: ":TSUpdate" }' \
      steps-plugins.json > /dev/null
    grep -q 'plugin "nvim-treesitter": build is a list of 2 steps and 1 of them cannot be run at build time' \
      steps.log
    grep -q 'step 2 is a neovim command (":TSUpdate")' steps.log
    grep -q 'the remaining shell step still runs' steps.log
    grep -q 'programs.nvimx.treesitter.grammars' steps.log

    # all-shell table: silent, and not folded into a scalar shell build
    jq -e '.plugins["LuaSnip"].build.kind == "steps"' steps-plugins.json > /dev/null
    jq -e '.plugins["LuaSnip"].build.steps[0] == { kind: "shell", cmd: "make install_jsregexp" }' \
      steps-plugins.json > /dev/null
    if grep -q 'plugin "LuaSnip"' steps.log; then
      echo "an all-shell table build must not warn" >&2
      exit 1
    fi

    # all-unrunnable table: 2 of 2, both clauses present
    jq -e '.plugins["all-unbuildable.nvim"].build.kind == "steps"' steps-plugins.json > /dev/null
    grep -q 'plugin "all-unbuildable.nvim": build is a list of 2 steps and 2 of them cannot be run at build time' \
      steps.log
    grep -q 'step 1 is a Lua function' steps.log
    grep -q 'step 2 is a neovim command (":Foo")' steps.log

    # false: no false-positive warning (pre-#36 regression: "<boolean>" used to warn)
    jq -e '.plugins["no-build.nvim"].build == { kind: "none" }' steps-plugins.json > /dev/null
    if grep -q 'plugin "no-build.nvim"' steps.log; then
      echo "build = false must not warn" >&2
      exit 1
    fi

    # rockspec / luafile: their own kind, never "shell" (pre-#36 regression: these
    # used to be recorded as shell.cmd and executed as such)
    jq -e '.plugins["rockspec-build.nvim"].build == { kind: "rockspec" }' steps-plugins.json > /dev/null
    jq -e '.plugins["luafile-build.nvim"].build == { kind: "luafile", cmd: "install.lua" }' \
      steps-plugins.json > /dev/null
    # #27: the rockspec warning has to name the cure, the way the nvim-treesitter one
    # already does. Pinned verbatim -- this is a shipped message, and the whole point
    # is that it says where to go. (build_warning's scalar wording is pinned the same
    # way in the unbuildable-config block above.)
    grep -q '^\[nvimx\] warning: plugin "rockspec-build.nvim": build is a luarocks build ("rockspec") and cannot be run at build time\. nvimx never runs luarocks -- add the rock with programs.nvimx.extraLuaPackages instead$' steps.log
    # ... and only that shape gets it: a *.lua build has no rock to add, so pointing it
    # at extraLuaPackages would be wrong.
    if grep -q 'plugin "luafile-build.nvim".*extraLuaPackages' steps.log; then
      echo "the extraLuaPackages pointer must be specific to rockspec builds" >&2
      exit 1
    fi
    grep -q 'plugin "luafile-build.nvim"' steps.log
    # ... and the table form reaches the same cure: has_rockspec has to look inside
    # the steps list, not just at the scalar kind. { "make", "rockspec" } is #36's own
    # example shape, so this is the branch that would otherwise go untested.
    jq -e '.plugins["rockspec-steps.nvim"].build.steps[1] == { kind: "rockspec" }' \
      steps-plugins.json > /dev/null
    grep -q '^\[nvimx\] warning: plugin "rockspec-steps.nvim": build is a list of 2 steps and 1 of them cannot be run at build time: step 2 is a luarocks build; the remaining shell step still runs\. nvimx never runs luarocks -- add the rock with programs.nvimx.extraLuaPackages instead$' steps.log

    # The warnings also have to reach plugins.json, one per plugin and sorted by name,
    # or the committed lock would churn on every run. `false` and the all-shell LuaSnip
    # are the quiet paths and must not appear.
    jq -e '.warnings | length == 5' steps-plugins.json > /dev/null
    jq -e '.warnings[0] | startswith("plugin \"all-unbuildable.nvim\"")' steps-plugins.json > /dev/null
    jq -e '.warnings[1] | startswith("plugin \"luafile-build.nvim\"")' steps-plugins.json > /dev/null
    jq -e '.warnings[2] | startswith("plugin \"nvim-treesitter\"")' steps-plugins.json > /dev/null
    jq -e '.warnings[3] | startswith("plugin \"rockspec-build.nvim\"")' steps-plugins.json > /dev/null
    jq -e '.warnings[4] | startswith("plugin \"rockspec-steps.nvim\"")' steps-plugins.json > /dev/null

    touch $out
  ''
