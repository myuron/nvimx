-- A lazy.nvim-style config whose plugin needs a compiled artifact but declares no build at all.
-- Lazy would leave telescope-fzf-native unusable here; nvimx's build registry knows the plugin
-- and builds build/libfzf.so anyway (nix/build-registry/telescope-fzf-native.nvim.nix).
local lazypath = vim.fn.stdpath("data") .. "/lazy/lazy.nvim"
if not (vim.uv or vim.loop).fs_stat(lazypath) then
  local lazyrepo = "https://github.com/folke/lazy.nvim.git"
  vim.fn.system({ "git", "clone", "--filter=blob:none", lazyrepo, lazypath })
end
vim.opt.rtp:prepend(lazypath)

require("lazy").setup({
  {
    "nvim-telescope/telescope-fzf-native.nvim",
  },
})
