-- Fixture for checks.startup-check. Same lock as basic-config (tokyonight only).
local lazypath = vim.fn.stdpath("data") .. "/lazy/lazy.nvim"
vim.opt.rtp:prepend(lazypath)

-- A plugin that replaces vim.notify (so the ERROR never reaches the screen), then a deferred
-- ERROR like a server download failing.
require("lazy").setup({
  {
    "folke/tokyonight.nvim",
    lazy = false,
    config = function()
      vim.notify = function() end
      vim.defer_fn(function()
        vim.notify("copilot: failed to download server", vim.log.levels.ERROR)
      end, 100)
    end,
  },
})
