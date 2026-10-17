-- Fixture for checks.startup-check. Same lock as basic-config (tokyonight only).
local lazypath = vim.fn.stdpath("data") .. "/lazy/lazy.nvim"
vim.opt.rtp:prepend(lazypath)

-- nvim-notify style: vim.notify is a table with __call, not a function. The ERROR must still
-- be recorded.
require("lazy").setup({
  {
    "folke/tokyonight.nvim",
    lazy = false,
    config = function()
      vim.notify = setmetatable({}, { __call = function() end })
      vim.notify("nvimx-check: callable notifier error", vim.log.levels.ERROR)
    end,
  },
})
