-- Fixture for checks.startup-check. Same lock as basic-config (tokyonight only).
local lazypath = vim.fn.stdpath("data") .. "/lazy/lazy.nvim"
vim.opt.rtp:prepend(lazypath)

-- Quits during startup: nvim exits 0 before the driver finishes, which must not pass.
require("lazy").setup({ { "folke/tokyonight.nvim", lazy = false } })

vim.cmd("autocmd VimEnter * ++once qall!")
vim.api.nvim_create_autocmd("VimEnter", {
  callback = function()
    error("nvimx-check: early quit")
  end,
})
