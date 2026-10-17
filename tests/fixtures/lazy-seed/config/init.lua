-- The spec depends on which lazy.nvim nvimx-lock linked in, so plugins.json records which seed
-- the extraction actually ran against (#32).
local lazypath = vim.fn.stdpath("data") .. "/lazy/lazy.nvim"
vim.opt.rtp:prepend(lazypath)
local f = io.open(lazypath .. "/NVIMX_SEED_MARKER")
local which = f and f:read("*l") or "input"
if f then
  f:close()
end
require("lazy").setup({ { "nvimx-test/seed-" .. which .. ".nvim" } })
