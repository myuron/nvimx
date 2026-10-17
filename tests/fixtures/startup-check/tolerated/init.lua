-- Fixture for checks.startup-check. Same lock as basic-config (tokyonight only).
local lazypath = vim.fn.stdpath("data") .. "/lazy/lazy.nvim"
vim.opt.rtp:prepend(lazypath)

-- None of this is a failure: stderr noise, a silent! error, a dev plugin with no working tree.
require("lazy").setup({ { "folke/tokyonight.nvim", lazy = false } })

io.stderr:write("Downloading Copilot server ...\n")
vim.cmd("silent! colorscheme no-such-scheme")
-- v:errmsg is set although nothing was shown: it is not a failure signal (#79)
assert(vim.v.errmsg ~= "")
