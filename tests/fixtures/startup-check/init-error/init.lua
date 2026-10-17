-- Fixture for checks.startup-check. Same lock as basic-config (tokyonight only).
local lazypath = vim.fn.stdpath("data") .. "/lazy/lazy.nvim"
vim.opt.rtp:prepend(lazypath)

require("lazy").setup({ { "folke/tokyonight.nvim", lazy = false } })

error("nvimx-check: init boom")
