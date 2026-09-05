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
-- materialized per plugin here (#42), alongside a `versionFromDefaults` flag recording that the
-- constraint did not come from the plugin's own spec (#23; see effective_version below).
--
-- `build` is dumped as string | string[] | false | nil: a scalar or list of steps is kept
-- verbatim (an element that is not a string becomes a "<type>" placeholder), `false` is kept as
-- `false` (lazy's "do not build", lua/lazy/manage/task/plugin.lua:57), and a scalar is otherwise
-- equivalent to a 1-element list (`:64`). Classifying each element (shell / excmd / rockspec /
-- ... ) is resolve.lua's job, not this one's.

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
-- default, so this tests for nil, not for falsy. `tag` and `commit` are typed string?, so a falsy
-- value there is a type error rather than an idiom -- treating it as unset is deliberately not
-- symmetric with lazy, whose early returns test for truthiness.
-- Local plugins are excluded by lazy first of all: git.lua's get_target returns at its very first
-- branch (:118-123), before commit (:127), tag (:133) or defaults.version (:141) are ever
-- consulted. No guard is needed here for that exclusion, because local_dir below captures both
-- `dev = true` plugins and a spec's own explicit `dir` under the same predicate and dump_plugin
-- routes them to resolve.lua's localPlugins branch, which never reads `version` (#47). The one
-- exception is a pathological `dev = true` whose dev.path points back under lazy's own root:
-- local_dir returns nil for that dir, and resolve.lua's `p.dev or p.dir` test falls back to `dev`
-- alone to keep it local -- so `dev` is still dumped below even though `dir` now covers the
-- ordinary cases on its own.
--
-- dump_plugin records whether the returned version came from here (defaults.version) rather than
-- from p.version itself, in a `versionFromDefaults` flag on the raw-spec only (#23). resolve.lua's
-- severity for an unsatisfiable constraint depends on that distinction: one the user actually wrote
-- for this plugin is a mistake worth stopping the lock over, one materialized config-wide is a
-- best-effort lazy itself would silently give up on too. The flag is not part of the plugins.json
-- schema -- it is fully determined by `version` and `defaults.version`, so recording it there would
-- just be a derived field someone could edit into inconsistency.
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

-- An element of a table-form build is a string or a function (lua/lazy/types.lua:34); anything
-- else cannot occur for a real spec but is dumped as a placeholder rather than erroring.
---@param v any one element of a table-form build
---@return string
local function dump_build_step(v)
  return type(v) == "string" and v or ("<" .. type(v) .. ">")
end

-- lazy fills in `dir` for *every* plugin, so `p.dir ~= nil` says nothing about whether the user
-- keeps this plugin in a working tree: Meta:_rebuild short-circuits on a dir the spec wrote
-- (lua/lazy/core/meta.lua:216-217), derives one for `dev = true` (:229-237), and otherwise falls
-- back to `<root>/<name>` (:238). Dumping p.dir unconditionally would therefore send the entire
-- spec down resolve.lua's localPlugins branch and leave `plugins` empty -- silently, with exit 0.
-- What separates the two is the root itself, the same axis lazy uses for `_.is_local`
-- (lua/lazy/core/plugin.lua:244-252): a dir under Config.options.root is one lazy manages.
-- Testing the prefix meta.lua:238 itself builds is what makes that fallback value come back nil,
-- so a `dir` with no `dev` keeps its dir here instead of being locked, fetched and farmed as an
-- ordinary remote plugin (#47).
-- This is deliberately not a promise that nvimx and lazy always classify a plugin the same way:
-- the lock app extracts inside a throwaway XDG sandbox, so a dir written as a literal path under
-- the *user's* runtime root looks local here and remote to lazy at runtime. Nothing available at
-- extraction time closes that gap -- `_.is_local` least of all, since lazy sets it in
-- update_state(), which only the real lazy.setup runs, never Plugin.Spec.new.
---@param p table the plugin object normalized by lazy
---@param root_prefix string Config.options.root .. "/", the same expression meta.lua:238 uses
---@return string|nil the plugin's directory, or nil when lazy would manage it under its own root
local function local_dir(p, root_prefix)
  if type(p.dir) ~= "string" or p.dir:find(root_prefix, 1, true) == 1 then
    return nil
  end
  return p.dir
end

---@param p table the plugin object normalized by lazy
---@param default_version string|nil Config.options.defaults.version, false normalized to nil
---@param root_prefix string Config.options.root .. "/", the same expression meta.lua:238 uses
local function dump_plugin(p, default_version, root_prefix)
  local build = nil
  if p.build == false then
    build = false
  elseif type(p.build) == "table" then
    local steps = {}
    for _, s in ipairs(p.build) do
      steps[#steps + 1] = dump_build_step(s)
    end
    build = steps
  elseif p.build ~= nil then
    build = dump_build_step(p.build)
  end
  local version = effective_version(p, default_version)
  return {
    name = p.name,
    short = p[1],
    url = p.url,
    dir = local_dir(p, root_prefix),
    dev = p.dev or nil,
    branch = p.branch,
    tag = p.tag,
    commit = p.commit,
    version = version,
    -- `or nil`: a config that never uses `defaults.version` must not gain this key at all, so its
    -- raw-spec (and extractor-snapshot's golden) stays byte-for-byte unchanged.
    versionFromDefaults = (version ~= nil and p.version == nil) or nil,
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
  -- meta.lua:238's own fallback expression, captured once: it decides local vs remote below.
  local root_prefix = Config.options.root .. "/"

  local Plugin = require("lazy.core.plugin")
  local s = Plugin.Spec.new(spec, { pkg = false })

  local plugins = {}
  for name, p in pairs(s.plugins) do
    plugins[name] = dump_plugin(p, default_version, root_prefix)
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
