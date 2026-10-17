-- nvimx startup check driver (#79)
--
-- Usage (nix/lib/check.nix runs this inside the sandbox):
--   NVIMX_CHECK_FARM=<farm> NVIMX_CHECK_IGNORE=<json list> NVIMX_CHECK_SENTINEL=<file> \
--     nvim --headless --cmd "luafile lua/nvimx/startup-check.lua"
--
-- Runs after the wrapper's own bootstrap --cmd, so package.preload["lazy"] is already in place.
-- Collects every error neovim actually shows (ext_messages), plus ERROR notifications even when a
-- plugin has replaced vim.notify, then loads every farm plugin on VimEnter (a lazy-loaded plugin's
-- broken `config` is otherwise never run) and fails if anything was recorded. On success it writes
-- the sentinel file: a config that quits during startup exits 0 without reaching that point, and
-- the runner must not take that for a pass.
--
-- v:errmsg is deliberately not a signal: `silent!` sets it without showing anything.

local farm = vim.env.NVIMX_CHECK_FARM
local ignore = vim.json.decode(vim.env.NVIMX_CHECK_IGNORE or "[]")
local sentinel = vim.env.NVIMX_CHECK_SENTINEL
local errors = {}
local function record(source, msg)
  errors[#errors + 1] = { source = source, msg = tostring(msg) }
end

local ERROR_KINDS = { emsg = true, echoerr = true, lua_error = true, rpc_error = true }
vim.ui_attach(vim.api.nvim_create_namespace("nvimx-check"), { ext_messages = true }, function(event, kind, content)
  if event == "msg_show" and ERROR_KINDS[kind] then
    local t = {}
    for _, c in ipairs(content) do
      t[#t + 1] = c[2]
    end
    record(kind, table.concat(t))
  end
end)

-- notify guard, for plugins that replace vim.notify (nvim-notify, snacks, noice) and would swallow
-- an ERROR into a float. Every function assigned to vim.notify is stored wrapped and reads return
-- that wrapped function, so `local orig = vim.notify` captures the previous function, never a
-- shared wrapper that would loop back to the current one (a single shared wrapper hangs on the
-- common `local orig = vim.notify; vim.notify = function(...) return orig(...) end` chain).
-- depth: only the outermost call of a chain records, so a chained ERROR counts once.
-- Trade-off: an ERROR is recorded before the user's own filter runs, so one a filter deliberately
-- drops still fails; ignoreErrors is the way out. Limitation: rawget(vim, "notify") sees nil.
-- If vim's metatable is not shaped as expected the guard is skipped; UI collection still works.
local ERROR = vim.log.levels.ERROR
local depth = 0
local function wrap(f)
  return function(msg, level, opts)
    if depth == 0 and type(level) == "number" and level >= ERROR then
      record("vim.notify", msg)
    end
    depth = depth + 1
    local r = { pcall(f, msg, level, opts) }
    depth = depth - 1
    if not r[1] then
      error(r[2], 0)
    end
    return unpack(r, 2, table.maxn(r))
  end
end
-- nvim-notify is `vim.notify = require("notify")`: a table with __call, not a function
local function is_callable(v)
  if type(v) == "function" then
    return true
  end
  local m = getmetatable(v)
  return type(m) == "table" and m.__call ~= nil
end
local mt = getmetatable(vim)
if mt and type(mt.__index) == "function" and mt.__newindex == nil then
  local current = wrap(rawget(vim, "notify"))
  rawset(vim, "notify", nil)
  local index = mt.__index
  mt.__index = function(t, k)
    if k == "notify" then
      return current
    end
    return index(t, k)
  end
  mt.__newindex = function(t, k, v)
    if k == "notify" then
      current = is_callable(v) and wrap(v) or v
      return
    end
    rawset(t, k, v)
  end
end

local skip_msgs = {}
local function finish()
  vim.cmd.redraw()
  vim.schedule(function()
    local notified = {}
    for _, e in ipairs(errors) do
      if e.source == "vim.notify" then
        notified[#notified + 1] = e.msg
      end
    end
    local filters = vim.list_extend(vim.list_extend({}, ignore), skip_msgs)
    local failed = {}
    for _, e in ipairs(errors) do
      local drop = false
      -- the builtin notify echoes an ERROR as echoerr: the same error, already recorded
      if e.source ~= "vim.notify" then
        for _, m in ipairs(notified) do
          if e.msg:find(m, 1, true) then
            drop = true
            break
          end
        end
      end
      for _, s in ipairs(filters) do
        if e.msg:find(s, 1, true) then
          drop = true
          break
        end
      end
      if not drop then
        failed[#failed + 1] = e
      end
    end
    if #failed == 0 then
      io.stderr:write("[nvimx] check passed\n")
      if sentinel then
        local f = assert(io.open(sentinel, "w"))
        f:close()
      end
      vim.cmd("qall!")
    else
      for _, e in ipairs(failed) do
        io.stderr:write("[nvimx] check: " .. e.source .. ": " .. e.msg .. "\n")
      end
      vim.cmd("cquit! 1")
    end
  end)
end

vim.api.nvim_create_autocmd("VimEnter", {
  once = true,
  callback = function()
    vim.schedule(function()
      if not vim.g.lazy_did_setup then
        record("nvimx", "require('lazy').setup() was never called -- is configDir the directory holding init.lua?")
      else
        local lazy = require("lazy")
        local names = {}
        for _, p in ipairs(lazy.plugins()) do
          if p.name ~= "lazy.nvim" then
            if p.dir and vim.startswith(p.dir, farm .. "/") then
              if not p._.installed then
                record("nvimx", p.name .. " is in the spec but has no farm entry -- re-run nvimx-lock")
              elseif p._.cond ~= false then
                names[#names + 1] = p.name
              end
            else
              skip_msgs[#skip_msgs + 1] = "Plugin " .. p.name .. " is not installed"
            end
          end
        end
        local ok, err = pcall(lazy.load, { plugins = names })
        if not ok then
          record("lazy.load", err)
        end
      end
      vim.defer_fn(finish, 1000)
    end)
  end,
})
