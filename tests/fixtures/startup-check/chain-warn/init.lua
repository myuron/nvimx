-- Fixture for checks.startup-check. Same lock as basic-config (tokyonight only).
local lazypath = vim.fn.stdpath("data") .. "/lazy/lazy.nvim"
vim.opt.rtp:prepend(lazypath)

-- Two chained wrappers (one filtering) and only a WARN: must pass.
require("lazy").setup({
  {
    "folke/tokyonight.nvim",
    lazy = false,
    config = function()
      local first = vim.notify
      vim.notify = function(m, l, o)
        if m:find("noise") then
          return
        end
        return first(m, l, o)
      end
      local second = vim.notify
      vim.notify = function(m, l, o)
        return second(m, l, o)
      end
      vim.notify("nvimx-check: just a warning", vim.log.levels.WARN)
    end,
  },
})
