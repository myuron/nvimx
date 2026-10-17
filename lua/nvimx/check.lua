-- nvimx lock staleness check (#78)
--
-- Usage: nvim -l check.lua <candidate plugins.json> <committed plugins.json> <committed flake.lock>
--
-- Compares the plugins.json a lock would write *now* (resolve.lua --offline, run on the current
-- spec by nvimx-lock --check) with the committed lock, and prints one line per difference on
-- stdout. Empty stdout means the lock is up to date.
--
-- Staleness is signalled by stdout, never by the exit code: this script exits 0 both when the lock
-- is fresh and when it is stale, so an uncaught Lua error (exit 1) or a failed read (exit 2) can
-- never masquerade as either answer -- lock-app treats any non-zero exit as a failure.
--
-- Deliberately ignored, because a relock would change them without the spec having moved:
--   * resolvedRef -- the only network/lock-derived field (semver result, pin freeze, import seed,
--     --update). Every spec edit that would change it also changes a compared field (version,
--     branch, tag, commit, pin, source), so ignoring it loses nothing, and the candidate is built
--     offline and has none of them anyway.
--   * warnings -- diagnostics, some of which depend on resolvedRef.
--   * flake.nix -- the build never reads it, and a formatter version bump would flag it falsely.
-- flake.lock is only checked for its *set* of root inputs, not for revs.

local candidate_path, committed_path, flake_lock_path = arg[1], arg[2], arg[3]
assert(
  candidate_path and committed_path and flake_lock_path,
  "usage: nvim -l check.lua <candidate plugins.json> <committed plugins.json> <committed flake.lock>"
)

local function die(msg)
  io.stderr:write("[nvimx] check failed: " .. msg .. "\n")
  os.exit(2)
end

local function read_json(path, what)
  local f = io.open(path, "r")
  if not f then
    die(("cannot read %s (%s)"):format(what, path))
  end
  local text = f:read("*a")
  f:close()
  local ok, decoded = pcall(vim.json.decode, text)
  if not ok or type(decoded) ~= "table" then
    die(
      ("%s is not valid JSON (%s): %s. Fix the file, or delete it and run nvimx-lock again -- deleting it loses the pinned revs."):format(
        what,
        path,
        tostring(decoded)
      )
    )
  end
  return decoded
end

local candidate = read_json(candidate_path, "the candidate plugins.json")
local committed = read_json(committed_path, "the existing plugins.json")
local flake_lock = read_json(flake_lock_path, "the existing flake.lock")

if committed.schemaVersion ~= 1 then
  die(
    ("the existing plugins.json (%s) has schemaVersion %s, but this nvimx only understands 1. "):format(
      committed_path,
      tostring(committed.schemaVersion)
    ) .. "Upgrade nvimx, or delete the file and run nvimx-lock again -- deleting it loses the pinned revs."
  )
end

local IGNORED = { resolvedRef = true }

local function is_null(v)
  return v == nil or v == vim.NIL
end

-- nil and vim.NIL are the same thing (a key one side lacks reads as null on the other), and the
-- key union makes the comparison symmetric. [] and {} both decode to an empty table.
local function deep_equal(a, b)
  if is_null(a) or is_null(b) then
    return is_null(a) and is_null(b)
  end
  if type(a) ~= type(b) then
    return false
  end
  if type(a) ~= "table" then
    return a == b
  end
  local keys = {}
  for k in pairs(a) do
    keys[k] = true
  end
  for k in pairs(b) do
    keys[k] = true
  end
  for k in pairs(keys) do
    if not deep_equal(a[k], b[k]) then
      return false
    end
  end
  return true
end

local function render(v)
  if is_null(v) then
    return "null"
  end
  return vim.json.encode(v)
end

-- The changed fields of two remote entries, as "key old -> new" (tables as "key changed"), sorted
-- by key. Empty when the entries agree.
local function diff_entries(old, new)
  local keys = {}
  for k in pairs(old) do
    keys[#keys + 1] = k
  end
  for k in pairs(new) do
    if old[k] == nil then
      keys[#keys + 1] = k
    end
  end
  table.sort(keys)
  local parts = {}
  for _, k in ipairs(keys) do
    if not IGNORED[k] and not deep_equal(old[k], new[k]) then
      if type(old[k]) == "table" or type(new[k]) == "table" then
        parts[#parts + 1] = k .. " changed"
      else
        parts[#parts + 1] = ("%s %s -> %s"):format(k, render(old[k]), render(new[k]))
      end
    end
  end
  return parts
end

-- name -> entry (remote) or false (local). `lazyNvim` is deliberately not part of this map: it
-- lives outside plugins/localPlugins, and a dev/dir lazy.nvim puts "lazy.nvim" into localPlugins
-- while lazyNvim stays the synthetic literal (#49), so it is compared separately below.
local function name_map(lock)
  local map = {}
  for name, entry in pairs(type(lock.plugins) == "table" and lock.plugins or {}) do
    map[name] = entry
  end
  for name in pairs(type(lock.localPlugins) == "table" and lock.localPlugins or {}) do
    map[name] = false
  end
  return map
end

local function sorted_keys(t)
  local keys = {}
  for k in pairs(t) do
    keys[#keys + 1] = k
  end
  table.sort(keys)
  return keys
end

local want, have = name_map(candidate), name_map(committed)
local missing, removed, changed, no_input, stray = {}, {}, {}, {}, {}

for _, name in ipairs(sorted_keys(want)) do
  if have[name] == nil then
    missing[#missing + 1] = name
  end
end
for _, name in ipairs(sorted_keys(have)) do
  if want[name] == nil then
    removed[#removed + 1] = name
  end
end
for _, name in ipairs(sorted_keys(want)) do
  local new, old = want[name], have[name]
  if old ~= nil then
    if new == false and old ~= false then
      changed[#changed + 1] = { name, "now a local plugin" }
    elseif new ~= false and old == false then
      changed[#changed + 1] = { name, "no longer a local plugin" }
    elseif new ~= false then
      local parts = diff_entries(old, new)
      if #parts > 0 then
        changed[#changed + 1] = { name, table.concat(parts, ", ") }
      end
    end
  end
end

-- lazy.nvim's own entry, on its own footing (see name_map). A committed lazyNvim without a
-- `synthetic` key predates #49, which could only ever write the synthetic literal, and the build
-- reads both identically -- so it is read as synthetic rather than flagged for lacking the key.
local old_lazy = type(committed.lazyNvim) == "table" and committed.lazyNvim or {}
local new_lazy = type(candidate.lazyNvim) == "table" and candidate.lazyNvim or {}
if is_null(old_lazy.synthetic) then
  old_lazy.synthetic = true
end
do
  local parts = diff_entries(old_lazy, new_lazy)
  if #parts > 0 then
    changed[#changed + 1] = { "lazy.nvim", table.concat(parts, ", ") }
    table.sort(changed, function(a, b)
      return a[1] < b[1]
    end)
  end
end

-- flake.lock: only the set of root inputs, against the committed plugins.json's inputNames.
local root_inputs = {}
do
  local nodes = type(flake_lock.nodes) == "table" and flake_lock.nodes or {}
  local root = nodes[flake_lock.root or "root"]
  root = type(root) == "table" and root or {}
  for input in pairs(type(root.inputs) == "table" and root.inputs or {}) do
    root_inputs[input] = true
  end
end
local claimed = {}
local function claim(name, entry)
  if type(entry) == "table" and type(entry.inputName) == "string" then
    claimed[entry.inputName] = true
    if not root_inputs[entry.inputName] then
      no_input[#no_input + 1] = name
    end
  end
end
for _, name in ipairs(sorted_keys(type(committed.plugins) == "table" and committed.plugins or {})) do
  claim(name, committed.plugins[name])
end
claim("lazy.nvim", committed.lazyNvim)
table.sort(no_input)
for _, input in ipairs(sorted_keys(root_inputs)) do
  if not claimed[input] then
    stray[#stray + 1] = input
  end
end

local out = {}
local function emit(label, items, text)
  for _, item in ipairs(items) do
    out[#out + 1] = ("  %-18s %s"):format(label, text(item))
  end
end
local function name_only(item)
  return item
end
emit("missing from lock:", missing, name_only)
emit("no longer in spec:", removed, name_only)
emit("spec changed:", changed, function(item)
  return ("%s (%s)"):format(item[1], item[2])
end)
emit("not in flake.lock:", no_input, name_only)
emit("flake.lock only:", stray, name_only)

if #out > 0 then
  io.stdout:write("[nvimx] lock is stale:\n" .. table.concat(out, "\n") .. "\n")
end
