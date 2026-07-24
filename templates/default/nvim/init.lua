-- 標準的な lazy.nvim bootstrap snippet をそのまま使える。
-- nvimx 環境では stdpath("data")/lazy/lazy.nvim が /nix/store の farm への
-- symlink になるため、git clone は走らない。
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
})

vim.cmd.colorscheme("tokyonight")
