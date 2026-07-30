-- A lazy.nvim-style config whose spec carries the fields resolve.lua used to throw away:
-- `pin`, `dependencies` and `version`. Used by checks.resolve-merge to verify that they survive
-- the whole extract -> resolve path, not just the hand-written raw-specs under tests/fixtures/merge.
-- It also exercises lazy's `optional` handling: an optional-only plugin must not be locked, while
-- a plugin with a mix of optional and non-optional fragments must still be locked.
-- Never built, only extracted and resolved, so it ships no nvimx-lock/ directory.
local lazypath = vim.fn.stdpath("data") .. "/lazy/lazy.nvim"
if not (vim.uv or vim.loop).fs_stat(lazypath) then
  local lazyrepo = "https://github.com/folke/lazy.nvim.git"
  vim.fn.system({ "git", "clone", "--filter=blob:none", lazyrepo, lazypath })
end
vim.opt.rtp:prepend(lazypath)

require("lazy").setup({
  {
    "folke/tokyonight.nvim",
    pin = true,
  },
  {
    "nvim-telescope/telescope.nvim",
    version = "^0.1",
    dependencies = { "nvim-lua/plenary.nvim" },
  },
  -- optional-only: lazy's Meta:fix_optional drops it, so nvimx must not lock it either
  {
    "folke/which-key.nvim",
    optional = true,
  },
  -- An optional fragment alongside telescope's non-optional dependency on the same plugin:
  -- lazy keeps the plugin (plugin.optional ends up false, never true), so it must be locked.
  -- Do not drop this as redundant with telescope's dependency: `false` is the only value lazy
  -- ever writes for `optional`, and nil keys never reach the raw spec, so checks.resolve-merge's
  -- raw-spec guard against extract.lua reintroducing the field has nothing to catch without it.
  {
    "nvim-lua/plenary.nvim",
    optional = true,
  },
})
