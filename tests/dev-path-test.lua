-- Runtime test driver for the dev.path function in the generated bootstrap.lua (#26), run via
-- `nvim --clean -l` by checks.dev-plugins. Entirely offline: every spec entry below is
-- `lazy = true` and the bootstrap already forces install.missing = false, so the plugin
-- directories only ever have to be *resolved* -- nothing is fetched, sourced, or required.
--
-- Failure is a plain Lua error from assert(): letting the script die non-zero is enough to fail
-- the pkgs.runCommand check that drives this file.
--
--   arg[1]  the generated bootstrap.lua to exercise
--   arg[2]  that env's farm
--   arg[3]  the directory tokyonight.nvim must resolve to
--   arg[4]  the directory plenary.nvim must resolve to
--   arg[5]  the directory bare.nvim (a spec-level `dev = true`) must resolve to

-- The `dir` the spec below writes for dirred.nvim. Absolute on purpose: Util.norm leaves it
-- alone, so the expected value is a constant and nothing here depends on $HOME.
local DIRRED_DIR = "/nvimx-test/dirred"

local bootstrap, farm, want_tokyonight, want_plenary, want_bare = arg[1], arg[2], arg[3], arg[4], arg[5]
assert(
  bootstrap and farm and want_tokyonight and want_plenary and want_bare,
  "usage: nvim --clean -l dev-path-test.lua <bootstrap.lua> <farm> <tokyonight dir> <plenary dir> <bare dir>"
)

local function eq(a, b, msg)
  assert(a == b, (msg or "not equal") .. (": got %s, want %s"):format(tostring(a), tostring(b)))
end

-- Installs the preload shim, exactly as the wrapper's --cmd luafile does at runtime, so the
-- require("lazy") below goes through it and setup() sees the forced opts -- dev.path among them.
dofile(bootstrap)

require("lazy").setup({
  { "folke/tokyonight.nvim", lazy = true },
  { "nvim-lua/plenary.nvim", lazy = true },
  -- A spec-level dev plugin with no dir of its own: dev.path decides where it lives.
  { "o/bare.nvim", dev = true, lazy = true },
  -- ... and one that writes its own dir: lazy must short-circuit on it (meta.lua:214-217) and
  -- never consult dev.path, even though the check gives this name a dev_dirs entry too.
  { "o/dirred.nvim", dev = true, dir = DIRRED_DIR, lazy = true },
})

local plugins = require("lazy.core.config").plugins

-- The one contract this file exists for: lazy appends "/<name>" only to the *string* form of
-- dev.path (lua/lazy/core/meta.lua:229-231), so the function form has to return the full plugin
-- directory itself. A function returning the farm root would collapse onto it every plugin that
-- takes the fallback branch -- so with an empty dev_dirs all three of these fail, and with a
-- populated one whichever of them dev_dirs does not cover.
eq(plugins["tokyonight.nvim"].dir, want_tokyonight, "tokyonight.nvim")
eq(plugins["plenary.nvim"].dir, want_plenary, "plenary.nvim")
eq(plugins["bare.nvim"].dir, want_bare, "bare.nvim")

-- The fact make-env's whole devDirs design rests on, pinned at runtime rather than merely argued
-- for in the plan: a spec-level `dir` short-circuits lazy before dev.path is consulted, so this
-- plugin ignores its dev_dirs entry entirely. If a seed bump ever stopped short-circuiting, the
-- rationale for not reading localPlugins[*].dir would collapse -- and this line would go red
-- instead of nix flake check staying green.
eq(plugins["dirred.nvim"].dir, DIRRED_DIR, "dirred.nvim (spec dir must beat dev.path)")

-- A different contract, not a third case of the one above: lazy.nvim's own dir never comes from
-- dev.path at all. The real setup adds { "folke/lazy.nvim" } to the spec (lua/lazy/core/plugin.lua
-- :333) and then overwrites lazy.dir with Config.me right after parsing (:338-341), Config.me being
-- derived from where lazy itself was loaded from (lua/lazy/core/config.lua:299-300). So this pins
-- the bootstrap's own rtp prepend instead: nvimx's lazy.nvim has to be the farm's copy. It would
-- fail if the prepend were dropped or aimed elsewhere -- and it is unaffected by dev_dirs, which is
-- exactly why naming "lazy.nvim" in devPlugins does nothing.
eq(plugins["lazy.nvim"].dir, farm .. "/lazy.nvim", "lazy.nvim")

print("dev-path-test: all assertions passed")
