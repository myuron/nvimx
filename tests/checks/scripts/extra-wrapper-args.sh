# shellcheck shell=bash disable=SC2154
# Body of checks.extra-wrapper-args, sourced by the runCommand in ../extra-wrapper-args.nix.
# $allWrapped $overriddenWrapped $luaOverriddenWrapped $luaOverriddenDefaultWrapped
# $untouchedWrapped $moduleWrapped come from that derivation's env.
export HOME=$TMPDIR

cat >all.lua <<'LUA'
-- Escaping: one list element, one argument, byte for byte.
local want = [[a b;c$HOME'd"e *]]
assert(vim.env.NVIMX_TEST_ESCAPE == want, "extraWrapperArgs value mangled: " .. vim.inspect(vim.env.NVIMX_TEST_ESCAPE))

-- Order against extraPackages: the user's --prefix PATH comes after nvimx's, so it
-- ends up in front of it, and the two share one wrapProgram call.
local path = vim.split(vim.env.PATH, ":", { plain = true })
assert(path[1] == "/nvimx-test/prefix", "extraWrapperArgs must come after nvimx's own PATH argument: " .. vim.env.PATH)
assert(vim.uv.fs_stat(path[2] .. "/hello"), "extraPackages must sit right behind the user's --prefix: " .. vim.env.PATH)
-- --suffix PATH is the issue's own example of what extraPackages cannot express.
assert(path[#path] == "/nvimx-test/suffix", "--suffix PATH did not reach the end of PATH: " .. vim.env.PATH)

-- Order against extraLuaPackages. Were the user's --prefix LUA_PATH emitted first,
-- it would not just land behind the rocks: it would set LUA_PATH before nvimx's
-- --set-default ';;' could, and the interpreter's default path would be gone too.
assert(package.path:find("/nvimx-test/?.lua;", 1, true) == 1, "extraWrapperArgs must come after the rock arguments: " .. package.path)
assert(require("inspect"), "extraLuaPackages did not survive alongside extraWrapperArgs")
assert(package.path:find("./?.lua", 1, true), "default package.path lost: " .. package.path)

-- Order against the bootstrap: flags are prepended in argument order, so the user's
-- --cmd runs once bootstrap.lua has installed package.preload["lazy"]. nil would
-- mean the flag never arrived, false that it ran too early.
assert(vim.g.nvimx_test_after_bootstrap == true, "the user's --add-flags must follow nvimx's --cmd: " .. vim.inspect(vim.g.nvimx_test_after_bootstrap))
LUA
# env -u for the reason checks.extra-lua-packages gives: the LUA_PATH asserts are
# about what the wrapper does to an unset variable.
env -u LUA_PATH -u LUA_CPATH "$allWrapped"/bin/nvim --clean -l all.lua

cat >overridden.lua <<'LUA'
assert(vim.env.PATH == "/nvimx-test/only", "a --set PATH after nvimx's arguments must win, extraPackages included: " .. vim.env.PATH)
LUA
"$overriddenWrapped"/bin/nvim --clean -l overridden.lua

# env -u as for all.lua: these asserts are about what the wrapper does to an unset variable.
cat >lua-overridden.lua <<'LUA'
assert(package.path == "/nvimx-test/?.lua", "a --set LUA_PATH must replace the whole path: " .. package.path)
assert(not pcall(require, "inspect"), "--set LUA_PATH was expected to discard the rocks' Lua modules")
assert(require("lua-utf8").len("ab") == 2, "--set LUA_PATH must leave LUA_CPATH alone")
LUA
env -u LUA_PATH -u LUA_CPATH "$luaOverriddenWrapped"/bin/nvim --clean -l lua-overridden.lua

cat >lua-overridden-default.lua <<'LUA'
assert(package.path:find("/nvimx-test/?.lua;", 1, true) == 1, "the user's LUA_PATH must come first: " .. package.path)
assert(package.path:find("./?.lua", 1, true), "';;' in a --set LUA_PATH must bring the default back: " .. package.path)
assert(not pcall(require, "inspect"), "';;' must not bring the rocks back")
LUA
env -u LUA_PATH -u LUA_CPATH "$luaOverriddenDefaultWrapped"/bin/nvim --clean -l lua-overridden-default.lua

cat >untouched.lua <<'LUA'
assert(vim.env.NVIMX_TEST_ESCAPE == nil, "the builder leaks NVIMX_TEST_ESCAPE; all.lua proves nothing")
assert(not vim.env.PATH:find("/nvimx-test/", 1, true), "the builder's PATH already holds the test entries: " .. vim.env.PATH)
assert(vim.g.nvimx_test_after_bootstrap == nil, "the marker is set without any extraWrapperArgs")
LUA
"$untouchedWrapped"/bin/nvim --clean -l untouched.lua

# The hm module really hands the option to makeEnv (see moduleWrapped above).
cat >module.lua <<'LUA'
assert(vim.env.NVIMX_TEST_MODULE == "from the module", "the hm module did not pass extraWrapperArgs through")
LUA
"$moduleWrapped"/bin/nvim --clean -l module.lua

touch "$out"
