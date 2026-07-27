-- nvimx resolver (minimal Phase 2 version)
--
-- Usage: nvim -l resolve.lua <raw-spec.json> <where to write plugins.json>
--
-- Converts raw-spec.json into the plugins.json schema.
-- TODO: resolve version (semver) via git ls-remote, and merge with an existing
-- plugins.json while preserving pins

local raw_path, out_path = arg[1], arg[2]
assert(raw_path and out_path, "usage: nvim -l resolve.lua <raw-spec.json> <plugins.json>")

local json = dofile(arg[0]:gsub("resolve%.lua$", "json.lua"))

local function read_json(path)
  local f = assert(io.open(path, "r"))
  local text = f:read("*a")
  f:close()
  return vim.json.decode(text)
end

local raw = read_json(raw_path)

-- Normalize into a form usable as a flake input name ([^A-Za-z0-9_-] → "-")
local function to_input_name(name)
  return (name:gsub("[^%w_-]", "-"))
end

-- Convert the git URL normalized by lazy into a source struct (github gets its own type)
local function parse_source(url)
  local owner, repo = url:match("^https://github%.com/([^/]+)/(.+)$")
  if owner then
    repo = repo:gsub("%.git$", "")
    return { type = "github", owner = owner, repo = repo }
  end
  return { type = "git", url = url }
end

local warnings = {}
for _, n in ipairs(raw.notifs or {}) do
  warnings[#warnings + 1] = n.msg
end

local plugins = {}
local local_plugins = {}
local seen_inputs = {}

for name, p in pairs(raw.plugins or {}) do
  if p.dev or p.dir then
    local_plugins[name] = { dir = p.dir }
  else
    local input_name = to_input_name(name)
    if seen_inputs[input_name] then
      error(("input name collision: %s (%s / %s)"):format(input_name, name, seen_inputs[input_name]))
    end
    seen_inputs[input_name] = name

    if p.version then
      warnings[#warnings + 1] = ("plugin %s: version constraint %q is not resolved yet (TODO: semver)"):format(
        name,
        tostring(p.version)
      )
    end

    local build = { kind = "none" }
    if type(p.build) == "string" then
      if p.build:sub(1, 1) == "<" then
        build = { kind = "function" }
      elseif p.build:sub(1, 1) == ":" then
        build = { kind = "excmd", cmd = p.build }
      else
        build = { kind = "shell", cmd = p.build }
      end
    end

    plugins[name] = {
      inputName = input_name,
      source = parse_source(p.url),
      branch = p.branch or vim.NIL,
      tag = p.tag or vim.NIL,
      commit = p.commit or vim.NIL,
      version = p.version or vim.NIL,
      resolvedRef = vim.NIL,
      build = build,
    }
  end
end

local result = {
  schemaVersion = 1,
  lazyNvim = {
    inputName = "lazy-nvim",
    synthetic = true,
    source = { type = "github", owner = "folke", repo = "lazy.nvim" },
  },
  plugins = json.object(plugins),
  localPlugins = json.object(local_plugins),
  warnings = json.array(warnings),
}

local f = assert(io.open(out_path, "w"))
f:write(json.encode(result))
f:close()
