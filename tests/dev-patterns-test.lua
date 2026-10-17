-- Runtime test driver for devPatterns in the generated bootstrap.lua (#74), run via
-- `nvim --clean -l` by checks.dev-patterns. Offline, like dev-path-test.lua: every spec entry is
-- `lazy = true`, so directories are only ever *resolved*, never read.
--
--   arg[1]  the generated bootstrap.lua to exercise
--   arg[2]  that env's farm
--   arg[3]  the devPath the bootstrap was built with (an existing directory in the store)
--
-- The env's devPatterns are { "folke/tokyo", "nvim-lua", "folke/lazy" }.

local bootstrap, farm, dev_root = arg[1], arg[2], arg[3]
assert(bootstrap and farm and dev_root, "usage: nvim --clean -l dev-patterns-test.lua <bootstrap.lua> <farm> <devPath>")

local function eq(a, b, msg)
  assert(a == b, (msg or "not equal") .. (": got %s, want %s"):format(tostring(a), tostring(b)))
end

dofile(bootstrap)

require("lazy").setup({
  { "folke/tokyonight.nvim", lazy = true },
  -- No such directory under dev_root: a match still routes there (no fallback).
  { "nvim-lua/plenary.nvim", lazy = true },
  -- Matches "nvim-lua" but opts out.
  { "nvim-lua/popup.nvim", dev = false, lazy = true },
  -- Same owner as tokyonight, but the pattern is "folke/tokyo": substring, not owner match.
  { "folke/todo-comments.nvim", lazy = true },
  -- The url matches "folke/tokyo", yet a spec dir short-circuits lazy before dev.path.
  { "folke/tokyodir.nvim", dir = "/nvimx-test/tokyodir", lazy = true },
})

local plugins = require("lazy.core.config").plugins

eq(plugins["tokyonight.nvim"].dir, dev_root .. "/tokyonight.nvim", "pattern match -> devPath")
-- "nvim-lua" only matches as a plain substring: as a Lua pattern the "-" is a quantifier and
-- the find on "https://github.com/nvim-lua/plenary.nvim.git" returns nil (lazy meta.lua:223).
eq(plugins["plenary.nvim"].dir, dev_root .. "/plenary.nvim", "plain substring match, no fallback")
assert(
  plugins["popup.nvim"].dir:sub(1, #dev_root + 1) ~= dev_root .. "/",
  "dev = false must opt out of devPatterns: " .. plugins["popup.nvim"].dir
)
eq(plugins["todo-comments.nvim"].dir, farm .. "/todo-comments.nvim", "non-matching plugin stays in the farm")
eq(plugins["tokyodir.nvim"].dir, "/nvimx-test/tokyodir", "spec dir beats devPatterns")
-- "folke/lazy" matches lazy.nvim's url, but its dir is overwritten with Config.me afterwards.
eq(plugins["lazy.nvim"].dir, farm .. "/lazy.nvim", "lazy.nvim is never moved")

print("dev-patterns-test: all assertions passed")
