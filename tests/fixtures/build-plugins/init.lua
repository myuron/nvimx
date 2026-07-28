-- A lazy.nvim-style config whose plugin needs a shell build step.
-- telescope-fzf-native's Makefile is a single `$(CC) -shared src/fzf.c -o build/libfzf.so`,
-- so it builds offline inside the nix sandbox on both linux and darwin.
local lazypath = vim.fn.stdpath("data") .. "/lazy/lazy.nvim"
if not (vim.uv or vim.loop).fs_stat(lazypath) then
  local lazyrepo = "https://github.com/folke/lazy.nvim.git"
  vim.fn.system({ "git", "clone", "--filter=blob:none", lazyrepo, lazypath })
end
vim.opt.rtp:prepend(lazypath)

require("lazy").setup({
  {
    "nvim-telescope/telescope-fzf-native.nvim",
    build = "make",
  },
})
