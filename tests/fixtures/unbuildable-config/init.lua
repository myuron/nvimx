-- A lazy.nvim-style config declaring every build shape nvimx cannot run: an ex command, a Lua
-- callback, and a list of steps. None of them can execute inside the nix build sandbox, so
-- `nvimx-lock` has to say so rather than let the plugins misbehave at runtime
-- (#22, checks.resolve-build-warnings).
-- Never built, only extracted and resolved, so it ships no nvimx-lock/ directory.
local lazypath = vim.fn.stdpath("data") .. "/lazy/lazy.nvim"
if not (vim.uv or vim.loop).fs_stat(lazypath) then
  local lazyrepo = "https://github.com/folke/lazy.nvim.git"
  vim.fn.system({ "git", "clone", "--filter=blob:none", lazyrepo, lazypath })
end
vim.opt.rtp:prepend(lazypath)

require("lazy").setup({
  {
    "nvim-treesitter/nvim-treesitter",
    build = ":TSUpdate",
  },
  {
    "iamcco/markdown-preview.nvim",
    build = function()
      vim.fn["mkdp#util#install"]()
    end,
  },
  {
    -- lazy also accepts a list of build steps; extract.lua records it as "<table>"
    "L3MON4D3/LuaSnip",
    build = { "make install_jsregexp" },
  },
})
