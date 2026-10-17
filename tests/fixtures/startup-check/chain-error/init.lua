-- Fixture for checks.startup-check. Same lock as basic-config (tokyonight only).
local lazypath = vim.fn.stdpath("data") .. "/lazy/lazy.nvim"
vim.opt.rtp:prepend(lazypath)

-- The common chaining pattern; a filter drops "noise" but not the ERROR under test.
require("lazy").setup({
  {
    "folke/tokyonight.nvim",
    lazy = false,
    config = function()
      local orig = vim.notify
      vim.notify = function(m, l, o)
        if m:find("noise") then
          return
        end
        return orig(m, l, o)
      end
      vim.notify("nvimx-check: chained error", vim.log.levels.ERROR)
    end,
  },
})
