-- Same idea as ../config, but the marker comes from a Lua module and vim.loader is on, so a stale
-- bytecode cache from an earlier extraction would be visible in plugins.json (#32).
vim.loader.enable()
local lazypath = vim.fn.stdpath("data") .. "/lazy/lazy.nvim"
vim.opt.rtp:prepend(lazypath)
require("lazy").setup({ { "nvimx-test/seed-" .. require("nvimx_seed_marker") .. ".nvim" } })
