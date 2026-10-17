-- Standard lazy bootstrap with its clone guard: under nvimx stdpath("data")/lazy/lazy.nvim is a
-- symlink into the farm, so a clone here would mean the farm was not wired up (checks.e2e-offline
-- puts a git shim on PATH that fails the check if it is ever called).
local lazypath = vim.fn.stdpath("data") .. "/lazy/lazy.nvim"
if not (vim.uv or vim.loop).fs_stat(lazypath) then
  local lazyrepo = "https://github.com/folke/lazy.nvim.git"
  vim.fn.system({ "git", "clone", "--filter=blob:none", lazyrepo, lazypath })
end
vim.opt.rtp:prepend(lazypath)

-- nvimx-e2e is a fake owner and is never fetched. url_format is lazy's default, spelled out so
-- that checks.e2e-offline can swap exactly this string for file:// remotes. Keep each top-level
-- spec on one line: the check deletes beta with a line-based sed.
require("lazy").setup({
  { "nvimx-e2e/alpha.nvim", lazy = false, pin = true },
  { "nvimx-e2e/beta.nvim", cmd = "BetaHi", dependencies = { "nvimx-e2e/gamma.nvim" } },
}, { git = { url_format = "https://github.com/%s.git" } })
