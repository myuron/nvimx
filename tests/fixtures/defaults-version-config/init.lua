-- A lazy.nvim-style config that sets a config-wide `defaults.version` instead of writing
-- `version` on each plugin. lazy applies this only when it checks out
-- (lua/lazy/manage/git.lua:141), so it never reaches the plugin object -- nvimx has to
-- materialize it at extraction time or the whole config silently tracks HEAD (#42).
-- Never built, only extracted and resolved, so it ships no nvimx-lock/ directory.
local lazypath = vim.fn.stdpath("data") .. "/lazy/lazy.nvim"
if not (vim.uv or vim.loop).fs_stat(lazypath) then
  local lazyrepo = "https://github.com/folke/lazy.nvim.git"
  vim.fn.system({ "git", "clone", "--filter=blob:none", lazyrepo, lazypath })
end
vim.opt.rtp:prepend(lazypath)

require("lazy").setup({
  -- eligible: the config-wide default is the only thing that decides its ref
  { "folke/tokyonight.nvim" },
  -- its own constraint wins, and its dependency is expanded by lazy and *is* eligible
  { "nvim-telescope/telescope.nvim", version = "^0.1", dependencies = { "nvim-lua/plenary.nvim" } },
  -- branch / tag / commit all decide the ref themselves; lazy never consults the default
  { "folke/trouble.nvim", branch = "dev" },
  { "folke/which-key.nvim", tag = "v3.0.0" },
  { "folke/flash.nvim", commit = "cbf1cb041a0e806c9f70e5b0b13d68f4dc26cfe8" },
  -- lazy's per-plugin opt-out ("do not use tags"), which must beat the config-wide default
  { "folke/noice.nvim", version = false },
}, {
  defaults = { version = "*" },
})
