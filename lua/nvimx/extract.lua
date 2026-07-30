-- nvimx extractor (Phase 1)
--
-- Usage:
--   NVIMX_LAZY_SEED=<store path of lazy.nvim> NVIMX_OUT=<where to write raw-spec.json> \
--     nvim --headless --cmd "luafile lua/nvimx/extract.lua"
--
-- Installs package.preload["lazy"] before the user's init.lua runs so that
-- require("lazy").setup(spec, opts) is intercepted. The real setup is never called;
-- instead lazy's own Config.setup + Spec.new normalize the spec (recursive import
-- resolution, fragment merging, dependency expansion) and it is dumped to raw-spec.json.
--
-- lazy only applies opts-level defaults (e.g. `defaults.version`) at git-operation time,
-- so they are never written into the plugin object; anything applied that way is
-- materialized per plugin here (#42).

local seed = vim.env.NVIMX_LAZY_SEED
local out = vim.env.NVIMX_OUT

local function fail(msg)
  io.stderr:write("[nvimx] extract failed: " .. tostring(msg) .. "\n")
  os.exit(1)
end

if not out or out == "" then
  fail("NVIMX_OUT is not set")
end

-- Prepend the seed to the rtp in case the user's config has no bootstrap snippet
if seed and seed ~= "" then
  vim.opt.rtp:prepend(seed)
end

-- Disable the opts passed to setup that could cause side effects during extraction.
-- Do not add `defaults` here: `defaults.version` is the user's intent and must reach
-- Config.options unmodified so effective_version() below can materialize it (#42).
local safe_opts = {
  install = { missing = false },
  checker = { enabled = false },
  change_detection = { enabled = false },
  pkg = { enabled = false },
  rocks = { enabled = false, hererocks = false },
  readme = { enabled = false },
}

-- lazy applies `defaults.version` only when it checks out (lua/lazy/manage/git.lua:141), so it is
-- never written into the plugin object -- and by the time :141 runs, `commit` (:127) and `tag`
-- (:133) have already returned. Reproduce that *effective* rule, not the literal condition on
-- :141: recording a constraint that can never decide a ref would only mislead the lock and make
-- resolve.lua warn about a constraint the user never wrote.
-- `p.version == false` is lazy's per-plugin "do not use tags" and must beat the config-wide
-- default, so this tests for nil, not for falsy.
-- dev plugins are excluded by lazy too (git.lua:119-123); resolve.lua already routes them to
-- localPlugins, so no guard is needed here.
---@param p table the plugin object normalized by lazy
---@param default_version string|nil Config.options.defaults.version, false normalized to nil
local function effective_version(p, default_version)
  if p.version ~= nil then
    return p.version
  end
  if default_version == nil or p.branch ~= nil or p.tag ~= nil or p.commit ~= nil then
    return nil
  end
  return default_version
end

---@param p table the plugin object normalized by lazy
---@param default_version string|nil Config.options.defaults.version, false normalized to nil
local function dump_plugin(p, default_version)
  local build = nil
  if p.build ~= nil then
    build = type(p.build) == "string" and p.build or ("<" .. type(p.build) .. ">")
  end
  return {
    name = p.name,
    short = p[1],
    url = p.url,
    dir = p.dev and p.dir or nil,
    dev = p.dev or nil,
    branch = p.branch,
    tag = p.tag,
    commit = p.commit,
    version = effective_version(p, default_version),
    pin = p.pin,
    build = build,
    dependencies = p.dependencies,
    hasCond = (p.cond ~= nil) or nil,
  }
end

local captured = false

local function capture(spec, opts)
  captured = true
  -- Also handle the setup(opts) form, where the spec lives in opts.spec
  if type(spec) == "table" and spec.spec ~= nil and not vim.islist(spec) then
    opts = spec
    spec = opts.spec
  end
  opts = opts or {}

  local Config = require("lazy.core.config")
  Config.setup(vim.tbl_deep_extend("force", {}, opts, safe_opts))
  -- false means "do not use tags", which git.lua:141 folds into the same nil as "unset"
  local default_version = Config.options.defaults.version or nil

  local Plugin = require("lazy.core.plugin")
  local s = Plugin.Spec.new(spec, { pkg = false })

  local plugins = {}
  for name, p in pairs(s.plugins) do
    plugins[name] = dump_plugin(p, default_version)
  end

  local notifs = {}
  for _, n in ipairs(s.notifs or {}) do
    notifs[#notifs + 1] = { msg = n.msg, level = n.level }
  end

  local result = {
    lazyNvim = { source = seed },
    plugins = plugins,
    disabled = vim.tbl_keys(s.disabled or {}),
    notifs = notifs,
  }

  local f = assert(io.open(out, "w"))
  f:write(vim.json.encode(result))
  f:close()
  -- Exit immediately: the rest of init.lua (applying a colorscheme, etc.) would fail
  -- because the plugins are not present
  os.exit(0)
end

package.preload["lazy"] = function()
  return {
    setup = function(spec, opts)
      local ok, err = pcall(capture, spec, opts)
      if not ok then
        fail(err)
      end
    end,
  }
end

-- If setup is called, the os.exit(0) inside capture ends the process, so we only get
-- here when init.lua never called lazy.setup. Left alone, the headless nvim would hang
-- forever waiting on stdin, so exit with a clear error instead (#3).
-- vim.schedule delays this by one tick, giving a setup scheduled inside init.lua a chance to run.
vim.api.nvim_create_autocmd("VimEnter", {
  callback = function()
    vim.schedule(function()
      if not captured then
        fail('config did not call require("lazy").setup(...); nvimx requires a lazy.nvim spec')
      end
    end)
  end,
})
