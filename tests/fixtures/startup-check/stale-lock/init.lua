-- Fixture for checks.startup-check. Same lock as basic-config (tokyonight only).
local lazypath = vim.fn.stdpath("data") .. "/lazy/lazy.nvim"
vim.opt.rtp:prepend(lazypath)

-- plenary.nvim is in the spec but not in the lock
require("lazy").setup({
  { "folke/tokyonight.nvim", lazy = false },
  { "nvim-lua/plenary.nvim", lazy = false },
})
