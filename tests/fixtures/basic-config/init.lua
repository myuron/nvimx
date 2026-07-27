-- A minimal lazy.nvim-style config. It uses the standard bootstrap snippet as-is
-- (under nvimx, stdpath("data")/lazy/lazy.nvim is a symlink into the farm, so the clone never runs)
local lazypath = vim.fn.stdpath("data") .. "/lazy/lazy.nvim"
if not (vim.uv or vim.loop).fs_stat(lazypath) then
  local lazyrepo = "https://github.com/folke/lazy.nvim.git"
  vim.fn.system({ "git", "clone", "--filter=blob:none", lazyrepo, lazypath })
end
vim.opt.rtp:prepend(lazypath)

vim.g.mapleader = " "

require("lazy").setup({
  {
    "folke/tokyonight.nvim",
    lazy = false,
    priority = 1000,
  },
}, {
  install = { colorscheme = { "tokyonight" } },
})

vim.cmd.colorscheme("tokyonight")
