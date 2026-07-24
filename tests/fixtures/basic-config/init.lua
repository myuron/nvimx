-- 最小の lazy.nvim 形式 config。標準的な bootstrap snippet をそのまま使う
-- (nvimx 環境では stdpath("data")/lazy/lazy.nvim が farm への symlink になるため clone は走らない)
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
