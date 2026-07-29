-- A lazy.nvim-style config whose plugins declare builds nvimx cannot run: an ex command and a
-- Lua callback. Neither can execute inside the nix build sandbox, so `nvimx-lock` has to say so
-- rather than let the plugins misbehave at runtime (#22, checks.resolve-build-warnings).
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
})
