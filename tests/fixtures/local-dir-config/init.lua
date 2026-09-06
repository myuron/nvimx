-- A lazy.nvim-style config whose spec sets `dir` without `dev` (#47), for
-- checks.extractor-local-dir. The first fixture config to use dev/dir at all -- every other
-- tests/fixtures/*/init.lua is remote-only, which is a large part of why this gap survived.
-- Never built, only extracted and resolved, so it ships no nvimx-lock/ directory.
--
-- dirabs / dirtilde / dirrel are the three ways Util.norm can leave a dir the spec wrote
-- (lua/lazy/core/meta.lua:216-217): an absolute path verbatim, a "~" expanded against the
-- extracting machine's $HOME, and a relative path left relative. nvimx records exactly what lazy
-- produced and absolutizes nothing -- doing otherwise would make nvimx point somewhere lazy does
-- not. dirnoname and sibling.nvim below are not shapes but separate axes (no url at all; a path
-- that only the trailing slash in the predicate keeps out of lazy's root). None of the
-- directories has to exist: lazy's dev.fallback is false and nothing checks.
--
-- tokyonight.nvim carries a tag so that the defaults.version below never reaches it (extract.lua's
-- effective_version stops at tag). That leaves the local plugins as the only carriers of a version
-- constraint, which is one of the two ways a routing regression kills the check's resolve -- the
-- other being dirnoname, which has no url for source.parse to work with. Either way the resolve
-- exits non-zero, which is what lets the check run with neither git nor --lazy and treat "exit 0"
-- as the assertion. (In practice dirnoname's error is the one that surfaces, because
-- report_resolve_errors() runs first; the check still asserts the constraints exist so that the
-- second route does not quietly disappear.)
local lazypath = vim.fn.stdpath("data") .. "/lazy/lazy.nvim"
if not (vim.uv or vim.loop).fs_stat(lazypath) then
  local lazyrepo = "https://github.com/folke/lazy.nvim.git"
  vim.fn.system({ "git", "clone", "--filter=blob:none", lazyrepo, lazypath })
end
vim.opt.rtp:prepend(lazypath)

require("lazy").setup({
  -- An ordinary remote plugin. lazy still fills in its dir (<root>/<name>), and it must NOT be
  -- recorded: dumping p.dir unconditionally routes this one -- and every other remote plugin --
  -- into localPlugins, leaving `plugins` empty while the resolve still exits 0.
  { "folke/tokyonight.nvim", tag = "v1.0.0" },
  -- #47 itself: a dir with no dev, in each of the three shapes.
  { "o/dirabs.nvim", dir = "/nvimx-fixture/dirabs" },
  { "o/dirtilde.nvim", dir = "~/nvimx-fixture/dirtilde" },
  { "o/dirrel.nvim", dir = "nvimx-fixture/dirrel" },
  -- The most natural way to write a dir-only plugin: no repo shorthand, because there is no repo.
  -- lazy names it after the path's basename and leaves url unset, which used to make resolve.lua
  -- fail outright with "has no url" -- locking this config was impossible, not merely wasteful.
  { dir = "/nvimx-fixture/dirnoname" },
  -- A sibling of lazy's own root, built from stdpath so it tracks whatever root the sandbox has.
  -- This is what makes the trailing slash in the predicate's prefix load-bearing: <root> is
  -- ".../nvim/lazy", so "<root>/" does not match ".../nvim/lazy-sibling/..." but "<root>" does.
  -- Degrade the prefix and this plugin silently stops being recorded.
  { "o/sibling.nvim", dir = vim.fn.stdpath("data") .. "/lazy-sibling/sibling.nvim" },
  -- dev with no dir of its own: unchanged by #47, kept so the check pins that the new predicate
  -- still routes it. Its dir comes from lazy's own dev.path, not from the spec.
  { "o/bare.nvim", dev = true },
}, {
  -- #42 materializes this onto every plugin whose ref is not already decided. It is how #47
  -- surfaced: a dir-only plugin used to carry it all the way into #23's gate.
  defaults = { version = "*" },
})
