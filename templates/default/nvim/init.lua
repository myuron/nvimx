-- The standard lazy.nvim bootstrap snippet works as-is.
-- Under nvimx, stdpath("data")/lazy/lazy.nvim is a symlink into the farm in
-- /nix/store, so the git clone never runs.
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
