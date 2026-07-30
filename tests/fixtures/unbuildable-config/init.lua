-- A lazy.nvim-style config declaring build shapes nvimx cannot run at all: an ex command and a
-- Lua callback. Neither can execute inside the nix build sandbox, so `nvimx-lock` has to say so
-- rather than let the plugins misbehave at runtime (#22, checks.resolve-build-warnings).
-- A table-form build is deliberately *not* here since #36: a table whose steps are all shell
-- commands (e.g. `{ "make install_jsregexp" }`) now runs them, so it belongs in
-- tests/fixtures/build-steps-config alongside the other table shapes, not in this "nothing can
-- run" fixture.
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
