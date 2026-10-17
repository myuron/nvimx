-- lazy's own dev.patterns and dev.path, no fallback: lazy assigns the dev dir unconditionally, so the matched plugin is local and nothing is left to lock remotely.
-- Never built, only extracted (checks.extractor-dev-opts, #74), so it ships no nvimx-lock/.
local lazypath = vim.fn.stdpath("data") .. "/lazy/lazy.nvim"
if not (vim.uv or vim.loop).fs_stat(lazypath) then
  local lazyrepo = "https://github.com/folke/lazy.nvim.git"
  vim.fn.system({ "git", "clone", "--filter=blob:none", lazyrepo, lazypath })
end
vim.opt.rtp:prepend(lazypath)

require("lazy").setup({ { "folke/tokyonight.nvim" } }, {
  dev = { patterns = { "folke" }, path = "~/elsewhere" },
})
