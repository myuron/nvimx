-- Fixture for checks.startup-check. Same lock as basic-config (tokyonight only).
local lazypath = vim.fn.stdpath("data") .. "/lazy/lazy.nvim"
vim.opt.rtp:prepend(lazypath)

-- lazy = true: startup never loads it, only the check's load-all step runs its config
require("lazy").setup({
  {
    "folke/tokyonight.nvim",
    lazy = true,
    config = function()
      error("nvimx-check: config boom")
    end,
  },
})
