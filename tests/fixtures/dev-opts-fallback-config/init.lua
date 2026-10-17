-- dev.patterns plus dev.fallback = true: with no checkout on the extracting machine the matched plugin reverts to a remote (meta.lua:232-235), which resolve could not lock offline, hence extract only.
-- Never built, only extracted (checks.extractor-dev-opts, #74), so it ships no nvimx-lock/.
local lazypath = vim.fn.stdpath("data") .. "/lazy/lazy.nvim"
if not (vim.uv or vim.loop).fs_stat(lazypath) then
  local lazyrepo = "https://github.com/folke/lazy.nvim.git"
  vim.fn.system({ "git", "clone", "--filter=blob:none", lazyrepo, lazypath })
end
vim.opt.rtp:prepend(lazypath)

require("lazy").setup({ { "folke/tokyonight.nvim" } }, {
  dev = { patterns = { "folke" }, fallback = true },
})
