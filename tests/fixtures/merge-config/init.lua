-- A lazy.nvim-style config whose spec carries the fields resolve.lua used to throw away:
-- `pin`, `dependencies` and `version`. Used by checks.resolve-merge to verify that they survive
-- the whole extract -> resolve path, not just the hand-written raw-specs under tests/fixtures/merge.
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
})
