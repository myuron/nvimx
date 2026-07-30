-- lazy's own config template recommends `defaults.version = false` ("a lot the plugin that
-- support versioning, have outdated releases"), and git.lua:141 folds that into the same nil as
-- leaving it unset. nvimx must not record `false` as a constraint (#42).
-- Never built, only extracted and resolved, so it ships no nvimx-lock/ directory.
local lazypath = vim.fn.stdpath("data") .. "/lazy/lazy.nvim"
if not (vim.uv or vim.loop).fs_stat(lazypath) then
  local lazyrepo = "https://github.com/folke/lazy.nvim.git"
  vim.fn.system({ "git", "clone", "--filter=blob:none", lazyrepo, lazypath })
end
vim.opt.rtp:prepend(lazypath)

require("lazy").setup({
  { "folke/tokyonight.nvim" },
  { "nvim-telescope/telescope.nvim", version = "^0.1" },
}, {
  defaults = { version = false },
})
