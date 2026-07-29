-- A lazy.nvim-style config with nvim-treesitter, whose parsers cannot be produced by the
-- generic plugin build: upstream expects :TSInstall to compile them at runtime into
-- user-owned state. nvimx merges grammars from nixpkgs into the plugin instead
-- (programs.nvimx.treesitter.grammars, nix/lib/treesitter.nix).
local lazypath = vim.fn.stdpath("data") .. "/lazy/lazy.nvim"
if not (vim.uv or vim.loop).fs_stat(lazypath) then
  local lazyrepo = "https://github.com/folke/lazy.nvim.git"
  vim.fn.system({ "git", "clone", "--filter=blob:none", lazyrepo, lazypath })
end
vim.opt.rtp:prepend(lazypath)

require("lazy").setup({
  {
    "nvim-treesitter/nvim-treesitter",
  },
})
