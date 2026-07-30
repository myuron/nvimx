-- update-summary.lua: reports what an `nvimx-lock --update` run actually moved (#24's plan, §3.4).
--
-- Usage:
--   nvim -l update-summary.lua <plugins.json before> <plugins.json after> \
--     <flake.lock before> <flake.lock after> [name...]
--
-- Pure text processing over the four JSON snapshots nvimx-lock takes around an --update run: no
-- network, no external process. [name...] is exactly the list of names --update was given; an
-- empty list means a bare --update (update everything). lock-app.nix only ever calls this file
-- when --update was used at all -- a plain `nvimx-lock` never runs it, and its own non-zero exit
-- is deliberately left fatal for the whole run (see lock-app.nix's comment next to the call).
--
-- This is deliberately standalone rather than requiring resolve.lua: resolve.lua is a CLI in its
-- own right (dofile()ing it would re-run its own argument parsing against this file's own argv),
-- and the handful of pure helpers needed here (is_null/norm, is_tag_ref, same_identity, a
-- flake.lock reader) are a few lines each, so copying them keeps this file readable top to bottom
-- on its own rather than reaching into resolve.lua's internals.

local function die(msg)
  io.stderr:write("[nvimx] update-summary failed: " .. tostring(msg) .. "\n")
  os.exit(1)
end

local plugins_before_path, plugins_after_path, lock_before_path, lock_after_path = arg[1], arg[2], arg[3], arg[4]
if not (plugins_before_path and plugins_after_path and lock_before_path and lock_after_path) then
  die(
    "usage: nvim -l update-summary.lua <plugins.json before> <plugins.json after> "
      .. "<flake.lock before> <flake.lock after> [name...]"
  )
end

local requested = {}
for i = 5, #arg do
  requested[#requested + 1] = arg[i]
end

-- Only a genuinely unreadable file is fatal here: this file runs after every lock artifact has
-- already been written, so a bug in it must not look like the lock itself failed by hiding behind
-- a swallowed error -- but it also must not choke on a merely unusual (not malformed) shape.
-- Missing/oddly-typed fields are treated as absent everywhere below, not as reasons to abort.
local function read_json(path)
  local f = io.open(path, "r")
  if not f then
    die("cannot open " .. path)
  end
  local text = f:read("*a")
  f:close()
  local ok, decoded = pcall(vim.json.decode, text)
  if not ok then
    die(("%s is not valid JSON: %s"):format(path, decoded))
  end
  if type(decoded) ~= "table" then
    die(path .. " is not a JSON object")
  end
  return decoded
end

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

-- The same classifier resolve.lua's own `is_tag_ref` is: not shared as a module because it is
-- three lines, and this file has no other reason to load resolve.lua. Unlike resolve.lua, this
-- file never needs to tell a frozen 40-hex rev apart from anything else -- a rev move with no
-- tag ref on either side is simply the default case below, pin-frozen or not.
local function is_tag_ref(v)
  return type(v) == "string" and v:sub(1, 10) == "refs/tags/"
end

-- The same fields resolve.lua's `identity_fields` / `source_fields` are: what decides which ref a
-- plugin resolves to, used below only to word the "(spec changed)" reason on an unrequested move.
local identity_fields = { "branch", "tag", "commit", "version" }
local source_fields = { "type", "owner", "repo", "url" }

local function same_identity(a, b)
  if type(a) ~= "table" or type(b) ~= "table" then
    return false
  end
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

-- flake.lock read exactly the way resolve.lua's `locked_rev` and nix/lib/sources.nix do:
-- root -> inputs.<inputName> -> nodes.<n>.locked.rev.
local function make_locked_rev(lock)
  local nodes = type(lock.nodes) == "table" and lock.nodes or {}
  local root = lock.root and nodes[lock.root]
  local root_inputs = (type(root) == "table" and type(root.inputs) == "table") and root.inputs or {}
  return function(input_name)
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

local function short(rev)
  if type(rev) ~= "string" then
    return "?"
  end
  return rev:sub(1, 7)
end

local plugins_before_doc = read_json(plugins_before_path)
local plugins_after_doc = read_json(plugins_after_path)
local lock_before_doc = read_json(lock_before_path)
local lock_after_doc = read_json(lock_after_path)

local plugins_before = type(plugins_before_doc.plugins) == "table" and plugins_before_doc.plugins or {}
local plugins_after = type(plugins_after_doc.plugins) == "table" and plugins_after_doc.plugins or {}
local locked_rev_before = make_locked_rev(lock_before_doc)
local locked_rev_after = make_locked_rev(lock_after_doc)

-- lazyNvim.inputName is always "lazy-nvim" (resolve.lua writes it as a literal), but reading it
-- back rather than hard-coding keeps this file from silently going stale if that ever changes.
local lazy_input_name = (type(plugins_after_doc.lazyNvim) == "table" and plugins_after_doc.lazyNvim.inputName)
  or (type(plugins_before_doc.lazyNvim) == "table" and plugins_before_doc.lazyNvim.inputName)
  or "lazy-nvim"

-- mode_all: a bare --update (argv has no names at all). requested_set / lazy_requested: the
-- parsed argv, same split resolve.lua's own name validation uses (§3.1 of the plan: "lazy.nvim"
-- is a name for the synthetic seed input, never a spec plugin).
local mode_all = #requested == 0
local requested_set = {}
local lazy_requested = false
for _, n in ipairs(requested) do
  if n == "lazy.nvim" then
    lazy_requested = true
  else
    requested_set[n] = true
  end
end

-- Every plugin name either snapshot knows about. Anything present in only one side is exactly
-- what "added" / "removed" mean below.
local all_names = {}
local seen_name = {}
for n in pairs(plugins_before) do
  seen_name[n] = true
  all_names[#all_names + 1] = n
end
for n in pairs(plugins_after) do
  if not seen_name[n] then
    seen_name[n] = true
    all_names[#all_names + 1] = n
  end
end
table.sort(all_names)

-- Classifies one plugin name into a single summary line: added, then removed, then -- only when
-- the rev did *not* move -- pinned-skip or commit-pinned, then a rev move (annotated with why,
-- when the move explains itself), and finally unchanged. This is one gate stricter than a literal
-- reading of §3.4 / §5.3's priority list: pinned-skip and commit-pinned are claims that the rev
-- cannot have moved, so a plugin whose rev moved anyway (the spec's `commit` was edited, or some
-- anomaly moved an unrequested pinned input) must fall through to the rev-moved branch instead of
-- being reported as if nothing happened -- otherwise the move goes unreported entirely in named
-- mode, silencing exactly the safety net §3.4 (Done when 4) requires.
---@param name string
---@return { kind: string, text: string, requested: boolean, explained: boolean }|nil
local function classify(name)
  local before_entry = plugins_before[name]
  local after_entry = plugins_after[name]
  local input_name = (after_entry and after_entry.inputName) or (before_entry and before_entry.inputName)
  if not input_name then
    return nil
  end
  local rb, ra = locked_rev_before(input_name), locked_rev_after(input_name)
  local requested_here = requested_set[name] == true

  if ra ~= nil and rb == nil and after_entry then
    return { kind = "added", text = ("added: %s -> %s"):format(name, short(ra)) }
  end
  if rb ~= nil and ra == nil then
    return { kind = "removed", text = ("removed: %s (was %s)"):format(name, short(rb)) }
  end

  -- pinned-skip and commit-pinned are both claims that the rev *cannot* have moved on its own --
  -- so both are gated on rb == ra. A pin or a fixed `commit` that nonetheless has a moved rev
  -- (the spec's `commit` was edited, or some anomaly moved an unrequested pinned input) must
  -- fall through to the rev-moved path below instead of being reported as if nothing happened;
  -- otherwise a real move goes unreported entirely in named mode (neither shown nor warned about,
  -- the exact safety net §3.4 of the plan exists to provide).
  if rb == ra then
    if after_entry and is_true(after_entry.pin) and not requested_here then
      return {
        kind = "pinned",
        text = ("pinned: %s (skipped; run `nvimx-lock --update %s` to move it)"):format(name, name),
      }
    end

    if after_entry and not is_null(after_entry.commit) then
      return { kind = "unchanged", text = ("unchanged: %s (commit-pinned in spec)"):format(name) }
    end

    return { kind = "unchanged", text = ("unchanged: %s"):format(name), requested = requested_here }
  end

  -- The rev moved: work out whether the move explains itself (§3.4), so a legitimate move that
  -- --update did not cause is never mistaken for the safety net this summary exists to provide.
  local ref_before = before_entry and norm(before_entry.resolvedRef) or nil
  local ref_after = after_entry and norm(after_entry.resolvedRef) or nil

  if is_tag_ref(ref_before) and is_tag_ref(ref_after) and ref_before ~= ref_after then
    return {
      kind = "updated",
      text = ("updated: %s %s -> %s (%s -> %s)"):format(name, ref_before, ref_after, short(rb), short(ra)),
      requested = requested_here,
      explained = true,
    }
  end

  local reason = nil
  if ref_before == nil and is_tag_ref(ref_after) then
    reason = ("version constraint resolved: %s"):format(ref_after)
  elseif before_entry and after_entry and not same_identity(before_entry, after_entry) then
    reason = "spec changed"
  end

  local text = ("updated: %s %s -> %s"):format(name, short(rb), short(ra))
  if reason then
    text = text .. " (" .. reason .. ")"
  end
  return { kind = "updated", text = text, requested = requested_here, explained = reason ~= nil }
end

local lines = {}
local counts = { updated = 0, unchanged = 0, pinned = 0, added = 0, removed = 0 }
local warn_names = {}

for _, name in ipairs(all_names) do
  local c = classify(name)
  if c then
    -- Full-update mode reports every plugin. Named mode reports only what the user asked about,
    -- plus anything that actually moved (added / removed / updated) -- an untouched, unrequested
    -- plugin carries no signal there (§3.4 of the plan).
    local include = mode_all or c.kind == "added" or c.kind == "removed" or c.kind == "updated" or requested_set[name]
    if include then
      lines[#lines + 1] = c.text
      counts[c.kind] = counts[c.kind] + 1
      if c.kind == "updated" and not c.requested and not c.explained then
        warn_names[#warn_names + 1] = name
      end
    end
  end
end

-- The synthetic lazy.nvim seed input (§3.6 of the plan): always reported for a full update, and
-- in named mode only when the user actually asked to move it with `--update lazy.nvim`.
if mode_all or lazy_requested then
  local rb, ra = locked_rev_before(lazy_input_name), locked_rev_after(lazy_input_name)
  if rb ~= ra then
    lines[#lines + 1] = ("updated: lazy.nvim (seed) %s -> %s"):format(short(rb), short(ra))
    counts.updated = counts.updated + 1
  else
    lines[#lines + 1] = "unchanged: lazy.nvim (seed)"
    counts.unchanged = counts.unchanged + 1
  end
end

-- "Nothing moved" collapses to a single line, but only when there is truly nothing to say: a
-- pinned plugin being skipped must always be reported (§3.4 of the plan), even on a full update
-- where every other plugin also happened to be at rest already, since that skip is exactly the
-- kind of thing `--update <name>` exists to override.
local total_moved = counts.updated + counts.added + counts.removed
if total_moved == 0 and counts.pinned == 0 then
  io.stderr:write("nvimx-lock: no plugins updated (all up to date)\n")
  os.exit(0)
end

io.stderr:write("nvimx-lock: update summary\n")
for _, l in ipairs(lines) do
  io.stderr:write("  " .. l .. "\n")
end

if not mode_all and #warn_names > 0 then
  table.sort(warn_names)
  io.stderr:write(
    ("nvimx-lock: warning: %d input(s) moved without being named: %s\n"):format(
      #warn_names,
      table.concat(warn_names, ", ")
    )
  )
end

local count_order = { "updated", "unchanged", "pinned", "added", "removed" }
local count_parts = {}
for _, k in ipairs(count_order) do
  if counts[k] > 0 then
    count_parts[#count_parts + 1] = ("%d %s"):format(counts[k], k)
  end
end
io.stderr:write("  " .. table.concat(count_parts, ", ") .. "\n")
