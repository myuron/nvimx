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

-- Non-fatal problems are both recorded in plugins.json (for the lock) and written to stderr
-- (for the person running nvimx-lock, who would otherwise never learn about them).
-- The "[nvimx] " prefix matches extract.lua's fail().
local warnings = {}
local function warn(msg)
  warnings[#warnings + 1] = msg
  io.stderr:write("[nvimx] warning: " .. msg .. "\n")
end

local function note(line)
  io.stderr:write("[nvimx] " .. line .. "\n")
end

for _, n in ipairs(raw.notifs or {}) do
  warn(n.msg)
end

local plugins = {}
local local_plugins = {}
local seen_inputs = {}
-- Per-plugin warnings are collected rather than emitted inline: raw.plugins is traversed with
-- pairs(), so emitting as we go would give the warnings array a different order on every run and
-- churn the user's committed plugins.json. Sorted by plugin name below.
local plugin_warnings = {}
local unbuildable = false

local function warn_plugin(name, msg)
  plugin_warnings[#plugin_warnings + 1] = { name = name, msg = ("plugin %q: %s"):format(name, msg) }
end

-- How to name a build that is not a shell command. `kind` alone is too coarse: extract.lua
-- records *any* non-string build as "<type>" and resolve.lua files them all under "function",
-- but lazy accepts a list of build steps as well as a callback, and calling that a Lua function
-- would be wrong. The recorded placeholder is the only thing left to go on.
local build_phrasing = {
  ["<function>"] = "a Lua function",
  ["<table>"] = "a list of build steps",
}

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
      warn_plugin(name, ("version constraint %q is not resolved yet (TODO: semver)"):format(tostring(p.version)))
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

    -- Only "shell" can run inside the nix build sandbox; plugin-drv.nix installs the rest with
    -- helptags only. Say so here rather than letting the plugin misbehave at runtime (#22).
    -- p.build is kept out of plugins.json for the function case on purpose: the schema documents
    -- build.cmd as a command to run, and "<function>" is a placeholder, not one.
    if build.kind == "excmd" or build.kind == "function" then
      unbuildable = true
      local what = build.kind == "excmd" and "a neovim command" or (build_phrasing[p.build] or "not a shell command")
      local msg = ("build is %s (%q) and cannot be run at build time"):format(what, p.build)
      -- nvim-treesitter's `:TSUpdate` is by far the most common build of this shape, and nvimx
      -- already has a purpose-built answer for it, so point there instead of at the generic hatches.
      if name == "nvim-treesitter" then
        msg = msg .. ". nvimx merges parsers from nixpkgs instead -- set programs.nvimx.treesitter.grammars"
      end
      warn_plugin(name, msg)
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

-- table.sort is not stable, so the message is the tiebreaker: a plugin can produce more than one
-- warning (an unresolved version *and* an unbuildable build), and their relative order must not
-- depend on how pairs() happened to walk the table.
table.sort(plugin_warnings, function(a, b)
  if a.name ~= b.name then
    return a.name < b.name
  end
  return a.msg < b.msg
end)
for _, w in ipairs(plugin_warnings) do
  warn(w.msg)
end

-- The escape hatches, in the order resolve-plugin.nix applies them. Emitted once, and to stderr
-- only: repeating this block inside plugins.json on every lock would be noise.
if unbuildable then
  note('these plugins are installed with helptags only. To give them a real build:')
  note('  - programs.nvimx.plugins.overrides."<name>" = { pkgs, src, ... }: <your derivation>;')
  note('  - programs.nvimx.plugins.nixpkgsFallback = [ "<name>" ];')
  note("  - a recipe under nix/build-registry/, if this plugin is common enough that nvimx")
  note("    should ship one")
  note('See docs/architecture.md ("Plugin derivations").')
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
