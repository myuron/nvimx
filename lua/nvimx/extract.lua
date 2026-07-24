-- nvimx 抽出器 (Phase 1)
--
-- 使い方:
--   NVIMX_LAZY_SEED=<lazy.nvim の store path> NVIMX_OUT=<raw-spec.json 出力先> \
--     nvim --headless --cmd "luafile lua/nvimx/extract.lua"
--
-- ユーザーの init.lua が実行される前に package.preload["lazy"] を仕込み、
-- require("lazy").setup(spec, opts) を横取り捕捉する。本物の setup は呼ばず、
-- lazy 自身の Config.setup + Spec.new で spec を正規化 (import 再帰解決・
-- fragment マージ・dependencies 展開) して raw-spec.json に dump する。

local seed = vim.env.NVIMX_LAZY_SEED
local out = vim.env.NVIMX_OUT

local function fail(msg)
  io.stderr:write("[nvimx] extract failed: " .. tostring(msg) .. "\n")
  os.exit(1)
end

if not out or out == "" then
  fail("NVIMX_OUT is not set")
end

-- ユーザー config が bootstrap snippet を持たない場合に備え、シードを rtp に前置
if seed and seed ~= "" then
  vim.opt.rtp:prepend(seed)
end

-- setup に渡す opts のうち、抽出時に副作用を起こしうるものを無効化する
local safe_opts = {
  install = { missing = false },
  checker = { enabled = false },
  change_detection = { enabled = false },
  pkg = { enabled = false },
  rocks = { enabled = false, hererocks = false },
  readme = { enabled = false },
}

---@param p table lazy が正規化した plugin オブジェクト
local function dump_plugin(p)
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
    version = p.version,
    pin = p.pin,
    optional = p.optional,
    build = build,
    dependencies = p.dependencies,
    hasCond = (p.cond ~= nil) or nil,
  }
end

local function capture(spec, opts)
  -- setup(opts) 形式 (spec が opts.spec に入る) にも対応
  if type(spec) == "table" and spec.spec ~= nil and not vim.islist(spec) then
    opts = spec
    spec = opts.spec
  end
  opts = opts or {}

  local Config = require("lazy.core.config")
  Config.setup(vim.tbl_deep_extend("force", {}, opts, safe_opts))

  local Plugin = require("lazy.core.plugin")
  local s = Plugin.Spec.new(spec, { pkg = false })

  local plugins = {}
  for name, p in pairs(s.plugins) do
    plugins[name] = dump_plugin(p)
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
  -- init.lua の残り (colorscheme 適用等) は plugin 不在で失敗するため即終了する
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
