-- A lazy.nvim-style config declaring the table-form `build` shapes #36 teaches resolve.lua to
-- classify: a mixed table (some steps runnable, some not), an all-shell table (the quiet path,
-- goal 4), an all-unrunnable table, and the three scalar shapes that share the same classifier
-- (`false`, "rockspec", a `*.lua` file). None of these can be fetched, so this fixture is never
-- built, only extracted and resolved (checks.resolve-build-warnings), same as
-- tests/fixtures/unbuildable-config.
local lazypath = vim.fn.stdpath("data") .. "/lazy/lazy.nvim"
if not (vim.uv or vim.loop).fs_stat(lazypath) then
  local lazyrepo = "https://github.com/folke/lazy.nvim.git"
  vim.fn.system({ "git", "clone", "--filter=blob:none", lazyrepo, lazypath })
end
vim.opt.rtp:prepend(lazypath)

require("lazy").setup({
  {
    -- issue #36's own example: a mixed table where "make" can run and ":TSUpdate" cannot. The
    -- shell step still runs, and the treesitter-specific pointer is expected on top of it.
    "nvim-treesitter/nvim-treesitter",
    build = { "make", ":TSUpdate" },
  },
  {
    -- an all-shell table: every element is a shell command, so this must build silently (goal 4)
    -- instead of the pre-#36 "table dropped, warning only" behavior.
    "L3MON4D3/LuaSnip",
    build = { "make install_jsregexp" },
  },
  {
    -- synthetic: a table where nothing can run at build time (a callback and an ex command).
    -- Must behave like the scalar excmd/function cases in unbuildable-config, just phrased as
    -- "2 of 2 steps".
    "example/all-unbuildable.nvim",
    build = {
      function()
        vim.notify("built")
      end,
      ":Foo",
    },
  },
  {
    -- false is lazy's explicit "do not build" (lua/lazy/manage/task/plugin.lua:57), overriding
    -- lazy's own build.lua/build/init.lua auto-detection (task/plugin.lua:9-15). Must resolve to
    -- { kind = "none" } with no warning -- the pre-#36 extractor folded this into "<boolean>" and
    -- warned about it by mistake.
    "example/no-build.nvim",
    build = false,
  },
  {
    -- lazy hands this straight to Rocks.build (task/plugin.lua:69) instead of a shell. nvimx
    -- forces rocks.enabled = false during extraction (extract.lua's safe_opts), so this can never
    -- run in the sandbox either; classified as its own kind rather than executed as a shell
    -- command named "rockspec".
    "example/rockspec-build.nvim",
    build = "rockspec",
  },
  {
    -- a build ending in .lua is loadfile()'d by lazy from inside a live neovim with the plugin
    -- already on the runtimepath (task/plugin.lua:73-79), which the sandbox cannot reproduce;
    -- classified as its own kind rather than executed as a shell command named "install.lua".
    "example/luafile-build.nvim",
    build = "install.lua",
  },
})
