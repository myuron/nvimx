-- nvimx resolver (minimal Phase 2 version)
--
-- Usage:
--   nvim -l resolve.lua <raw-spec.json> <where to write plugins.json> \
--     [--prev <existing plugins.json>] [--lock <existing flake.lock>]
--
-- Converts raw-spec.json into the plugins.json schema, merging with the previous lock so that
-- refs already decided stay decided (--prev) and `pin = true` plugins get frozen onto the rev
-- the lock currently records (--lock). Both are read up front and the output is written last,
-- so --prev may safely point at the very path being written.
-- TODO: resolve version (semver) via git ls-remote

local function fail(msg)
  io.stderr:write("[nvimx] resolve failed: " .. tostring(msg) .. "\n")
  os.exit(1)
end

local function usage()
  io.stderr:write(
    "usage: nvim -l resolve.lua <raw-spec.json> <plugins.json> [--prev <plugins.json>] [--lock <flake.lock>]\n"
  )
  os.exit(2)
end

-- A flag loop rather than fixed positions: #24 (--update [name...]) and #25 (--import-lazy-lock)
-- add themselves here without disturbing the callers that only pass the two positional paths.
local raw_path, out_path, prev_path, lock_path
do
  local positional = {}
  local i = 1
  while i <= #arg do
    local a = arg[i]
    if a == "--prev" or a == "--lock" then
      local value = arg[i + 1]
      if not value then
        io.stderr:write(("[nvimx] resolve: %s needs a path\n"):format(a))
        usage()
      end
      if a == "--prev" then
        prev_path = value
      else
        lock_path = value
      end
      i = i + 2
    elseif a:sub(1, 2) == "--" then
      io.stderr:write(("[nvimx] resolve: unknown option %s\n"):format(a))
      usage()
    else
      positional[#positional + 1] = a
      i = i + 1
    end
  end
  raw_path, out_path = positional[1], positional[2]
  if not raw_path or not out_path or positional[3] then
    usage()
  end
end

local json = dofile(arg[0]:gsub("resolve%.lua$", "json.lua"))

local function read_json(path, what)
  local f = io.open(path, "r")
  if not f then
    fail(("cannot open %s: %s"):format(what, path))
  end
  local text = f:read("*a")
  f:close()
  local ok, decoded = pcall(vim.json.decode, text)
  if not ok then
    -- Silently regenerating would drop every pinned rev, so this has to be fatal.
    fail(
      ("%s is not valid JSON (%s): %s. Fix the file, or delete it and run nvimx-lock again -- "):format(
        what,
        path,
        decoded
      ) .. "deleting it loses the pinned revs."
    )
  end
  return decoded
end

local raw = read_json(raw_path, "the raw spec")

-- vim.NIL and "key absent" mean the same thing everywhere below; normalize once, here.
local function is_null(v)
  return v == nil or v == vim.NIL
end

local function norm(v)
  if is_null(v) then
    return nil
  end
  return v
end

local function is_true(v)
  return not is_null(v) and v ~= false
end

-- A bare 40-hex ref in resolvedRef can only have got there by freezing a pin: the spec's own
-- `commit` is kept in `commit`, and semver resolution writes "refs/tags/<tag>".
local function is_frozen_rev(v)
  return type(v) == "string" and #v == 40 and v:match("^%x+$") ~= nil
end

-- Conversely, a "refs/tags/..." ref is what semver resolution (#23) writes, so it is evidence
-- that the version constraint was actually honored.
local function is_tag_ref(v)
  return type(v) == "string" and v:sub(1, 10) == "refs/tags/"
end

-- The previous lock, when one was passed. Nothing else in this file reads plugins.json.
local prev_plugins = nil
if prev_path then
  local prev = read_json(prev_path, "the existing plugins.json")
  if type(prev) ~= "table" then
    fail(("the existing plugins.json (%s) is not a JSON object"):format(prev_path))
  end
  if prev.schemaVersion ~= 1 then
    fail(
      ("the existing plugins.json (%s) has schemaVersion %s, but this nvimx only understands 1. "):format(
        prev_path,
        tostring(prev.schemaVersion)
      )
        .. "Upgrade nvimx, or delete the file and run nvimx-lock again -- deleting it loses the pinned revs."
    )
  end
  prev_plugins = type(prev.plugins) == "table" and prev.plugins or {}
end

-- flake.lock is read as a pin DB only, exactly the way nix/lib/sources.nix reads it:
-- root node → inputs.<inputName> → nodes.<node>.locked.rev.
local locked_rev
do
  local nodes, root_inputs = {}, {}
  if lock_path then
    local lock = read_json(lock_path, "the existing flake.lock")
    if type(lock) ~= "table" then
      fail(("the existing flake.lock (%s) is not a JSON object"):format(lock_path))
    end
    nodes = type(lock.nodes) == "table" and lock.nodes or {}
    local root = lock.root and nodes[lock.root]
    root_inputs = (type(root) == "table" and type(root.inputs) == "table") and root.inputs or {}
  end
  locked_rev = function(input_name)
    local node_name = root_inputs[input_name]
    if type(node_name) ~= "string" then
      return nil
    end
    local node = nodes[node_name]
    local locked = type(node) == "table" and node.locked or nil
    local rev = type(locked) == "table" and locked.rev or nil
    return type(rev) == "string" and rev or nil
  end
end

-- Plugins whose previous decision must be thrown away and re-resolved. Always empty today;
-- #24 (`nvimx-lock --update [name...]`) fills it from the command line.
local force = {}

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

-- Spec identity: the fields that decide which ref a plugin resolves to. When all of them are
-- unchanged the previous `resolvedRef` is carried over untouched; when any of them changed the
-- user asked for something else, so the ref goes back to null and is resolved again.
-- pin / optional / dependencies / build are deliberately excluded: they are metadata that never
-- influences the ref, and editing them must not invalidate a pin.
local identity_fields = { "branch", "tag", "commit", "version" }
local source_fields = { "type", "owner", "repo", "url" }

local function same_identity(a, b)
  for _, k in ipairs(identity_fields) do
    if norm(a[k]) ~= norm(b[k]) then
      return false
    end
  end
  local sa, sb = a.source, b.source
  if type(sa) ~= "table" or type(sb) ~= "table" then
    return false
  end
  for _, k in ipairs(source_fields) do
    if norm(sa[k]) ~= norm(sb[k]) then
      return false
    end
  end
  return true
end

-- Dependencies are recorded for reference only, so the order lazy happened to produce carries no
-- meaning -- sort it, or an unrelated spec edit would churn the committed plugins.json.
local function sorted_deps(deps)
  local out = {}
  if type(deps) == "table" then
    for _, d in ipairs(deps) do
      if type(d) == "string" then
        out[#out + 1] = d
      end
    end
  end
  table.sort(out)
  return out
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

    local entry = {
      inputName = input_name,
      source = parse_source(p.url),
      branch = p.branch or vim.NIL,
      tag = p.tag or vim.NIL,
      commit = p.commit or vim.NIL,
      version = p.version or vim.NIL,
      pin = p.pin or vim.NIL,
      optional = p.optional or vim.NIL,
      dependencies = json.array(sorted_deps(p.dependencies)),
      resolvedRef = vim.NIL,
      build = build,
    }

    -- Merge with the previous lock. A plugin that is new, that was removed and re-added, or
    -- whose spec identity changed has no decision to inherit and starts over at null.
    local prev = (prev_plugins and not force[name]) and prev_plugins[name] or nil
    local unchanged = prev ~= nil and same_identity(prev, entry)
    if unchanged then
      local carried = norm(prev.resolvedRef)
      -- Dropping `pin` has to drop the freeze with it. pin is not part of the spec identity
      -- because it cannot *decide* a ref -- but a frozen rev exists only because pin put it
      -- there, so carrying it past an unpin would make the freeze permanent: the URL names the
      -- rev, so `nix flake update` cannot move it either, and a non-null resolvedRef would keep
      -- the entry out of semver resolution (#23) forever. Only pin's own 40-hex freeze is
      -- dropped; a "refs/tags/..." from semver did not come from pin and stays.
      if is_frozen_rev(carried) and is_true(prev.pin) and not is_true(entry.pin) then
        carried = nil
      end
      entry.resolvedRef = carried or vim.NIL
    end

    -- `pin = true`: freeze onto the rev the lock currently records, so that even a bare
    -- `nix flake update` in lockDir cannot move it. Skipped when the spec already nails the rev
    -- down (`commit`), when a ref was carried over above, and when the spec changed -- in the
    -- last case flake.lock still holds the rev of the *old* spec, and nvimx-lock resolves a
    -- second time after `nix flake lock` has caught up.
    if is_true(entry.pin) and unchanged and is_null(entry.resolvedRef) and is_null(entry.commit) then
      entry.resolvedRef = locked_rev(input_name) or vim.NIL
    end

    -- What to say about a version constraint. Note this is decided from `pin` rather than from
    -- whether the freeze happened on *this* run: a pin freezes on the second resolve of a lock
    -- run, and nvimx-lock keeps only the second run's log, so a warning that appeared on the
    -- first run alone would never reach the user. Deciding it from pin makes the two runs say
    -- exactly the same thing.
    if p.version then
      if is_true(entry.pin) and not is_tag_ref(norm(entry.resolvedRef)) then
        -- pin beats the constraint: the rev is whatever the lock happens to hold, and nothing
        -- ever checks it against the range. Frozen silently, this is a trap.
        warn_plugin(
          name,
          ("pinned; version constraint %q is not validated (pin wins)"):format(tostring(p.version))
        )
      elseif is_null(entry.resolvedRef) then
        -- Still unresolved after the merge -- exactly the set #23 (semver) has to resolve.
        warn_plugin(name, ("version constraint %q is not resolved yet (TODO: semver)"):format(tostring(p.version)))
      end
    end

    plugins[name] = entry
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
