-- update-summary.lua: reports what an `nvimx-lock --update` run actually moved (#24's plan, §3.4).
--
-- Usage:
--   nvim -l update-summary.lua [--json <path>] [--plain] <plugins.json before> <plugins.json after> \
--     <flake.lock before> <flake.lock after> [name...]
--
-- Pure text processing over the four JSON snapshots nvimx-lock takes around a lock run: no
-- network, no external process. [name...] is exactly the list of names --update was given; an
-- empty list means a bare --update (update everything). lock-app.nix calls this file for every
-- --update, and for a plain lock only when --summary-json was given (#77); its own non-zero exit
-- is deliberately left fatal for the whole run (see lock-app.nix's comment next to the call).
--
-- --json <path> additionally writes a machine-readable report (#77, schema v1; see README). It is
-- written before any stderr text, and the stderr text is byte-identical with or without it.
-- --plain is the plain-lock flavour: no stderr text at all, mode "lock", pinned reported as
-- unchanged (a plain lock skips nothing), and no names. Unlike resolve.lua, json.lua is a pure
-- module, so it is dofile()d for its deterministic encoder.
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

local usage = "usage: nvim -l update-summary.lua [--json <path>] [--plain] <plugins.json before> "
  .. "<plugins.json after> <flake.lock before> <flake.lock after> [name...]"

local json_path, plain = nil, false
local argi = 1
while arg[argi] and arg[argi]:sub(1, 2) == "--" do
  local opt = arg[argi]
  if opt == "--json" then
    local v = arg[argi + 1]
    if not v or v == "" or v:sub(1, 2) == "--" then
      die(usage)
    end
    json_path = v
    argi = argi + 2
  elseif opt == "--plain" then
    plain = true
    argi = argi + 1
  else
    die(usage)
  end
end

local plugins_before_path, plugins_after_path, lock_before_path, lock_after_path =
  arg[argi], arg[argi + 1], arg[argi + 2], arg[argi + 3]
if not (plugins_before_path and plugins_after_path and lock_before_path and lock_after_path) then
  die(usage)
end

local requested = {}
for i = argi + 4, #arg do
  requested[#requested + 1] = arg[i]
end
if plain and #requested > 0 then
  die(usage)
end

local json = dofile((arg[0]:gsub("update%-summary%.lua$", "json.lua")))

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

-- The same two classifiers resolve.lua's own `is_frozen_rev` / `is_tag_ref` are: not shared as a
-- module because each is three lines, and this file has no other reason to load resolve.lua.
local function is_frozen_rev(v)
  return type(v) == "string" and #v == 40 and v:match("^%x+$") ~= nil
end

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

-- The name a spec plugin uses for lazy.nvim itself (#49). resolve.lua declares the same constant
-- for the same reason -- not shared as a module, per this file's own header comment on why it
-- copies rather than requires resolve.lua's helpers.
local LAZY_NAME = "lazy.nvim"

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

-- #49: whether either snapshot's lazyNvim came from the spec (synthetic == false) rather than
-- nvimx's own default. Checked on both sides, not just one, so a spec lazy.nvim entry that was
-- just added or just removed between the two snapshots is still injected below and classified
-- normally, instead of falling through to the old synthetic-seed-only branch near the end of this
-- file just because the side that happens to still be (or already be) synthetic looked first.
local function is_spec_lazy(doc)
  return type(doc.lazyNvim) == "table" and doc.lazyNvim.synthetic == false
end
local lazy_is_spec = is_spec_lazy(plugins_before_doc) or is_spec_lazy(plugins_after_doc)
if lazy_is_spec then
  -- The read-side mirror of resolve.lua's own write-side routing: lazyNvim lives outside
  -- `plugins`, but a spec lazy.nvim entry decides the very same "lazy-nvim" input an ordinary
  -- `plugins["lazy.nvim"]` entry would. Injecting it back in here, at the single point where both
  -- snapshots are read, lets classify() below treat it exactly like any other plugin --
  -- same_identity, the pin/commit gates, the "spec changed" / "unpinned" reasons, all of it --
  -- with no dedicated branch of its own.
  --
  -- Each side is injected only when it is actually a table. The *after* snapshot is always
  -- resolve.lua's own fresh output, which always writes a `lazyNvim` table -- but the *before*
  -- snapshot is whatever plugins.json the caller already had on disk (lock-app.nix passes the
  -- committed one, not necessarily something resolve.lua just wrote), so it gets no such guarantee
  -- and is defended the same way every other field this file reads from either snapshot already is
  -- (read_json, plugins_before/plugins_after themselves, lazy_input_name, is_spec_lazy above): a
  -- `vim.NIL` or missing `lazyNvim` on an untrusted before snapshot must not reach classify() below
  -- and crash it on `before_entry.resolvedRef` -- update-summary.lua's own non-zero exit is fatal
  -- to the whole nvimx-lock run in lock-app.nix, so one bad before file would make an already
  -- completed lock look like it failed.
  --
  -- classify()'s added/removed branches can never fire for lazy.nvim either way: they key off
  -- `rb`/`ra`, the flake.lock "lazy-nvim" node's rev, and that node exists on both sides of every
  -- --update run (there is no lock state to add or remove, only a spec entry). Past that point a
  -- mixed pair (one side still synthetic, e.g. right after the spec entry was added or removed) is
  -- just another plugin to classify(): which reason (if any) its move gets is decided entirely by
  -- that function's existing reason chain at the bottom of classify() -- not restated here,
  -- because a prose retelling of that chain is what got this comment wrong twice already as the
  -- chain grew cases (and a line number for it went stale the moment this very comment grew).
  -- The one case worth spelling out is the simplest: a bare `{ "folke/lazy.nvim" }` with no ref
  -- fields of its own is field-for-field identical to the synthetic literal, so same_identity is
  -- true and it reports plain `unchanged` (or an unannotated move, if the rev moved anyway).
  if type(plugins_before_doc.lazyNvim) == "table" then
    plugins_before[LAZY_NAME] = plugins_before_doc.lazyNvim
  end
  if type(plugins_after_doc.lazyNvim) == "table" then
    plugins_after[LAZY_NAME] = plugins_after_doc.lazyNvim
  end
end

-- mode_all: a bare --update (argv has no names at all). requested_set / lazy_requested: the
-- parsed argv, same split resolve.lua's own name validation uses. #49: "lazy.nvim" is only routed
-- to the separate lazy_requested flag when it is *not* a spec plugin -- lazy_is_spec routes it
-- into requested_set like any other name instead, since classify() (used for every other plugin)
-- only ever consults requested_set, never lazy_requested.
local mode_all = #requested == 0
local requested_set = {}
local lazy_requested = false
for _, n in ipairs(requested) do
  if n == LAZY_NAME and not lazy_is_spec then
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
---@return { kind: string, text: string, requested: boolean, explained: boolean, entry: table }|nil
local function classify(name)
  local before_entry = plugins_before[name]
  local after_entry = plugins_after[name]
  local input_name = (after_entry and after_entry.inputName) or (before_entry and before_entry.inputName)
  if not input_name then
    return nil
  end
  local rb, ra = locked_rev_before(input_name), locked_rev_after(input_name)
  local requested_here = requested_set[name] == true

  -- The JSON entry (#77) is built beside the text, never from it, so the text stays untouched.
  -- Added takes its source from the after side, removed from the before side, updated from
  -- whichever side has one (after first).
  local ref_before = before_entry and norm(before_entry.resolvedRef) or nil
  local ref_after = after_entry and norm(after_entry.resolvedRef) or nil
  local function entry(kind, reason_code)
    local e = { name = name, inputName = input_name, reason = reason_code }
    local a_src = after_entry and after_entry.source
    local b_src = before_entry and before_entry.source
    if kind == "added" then
      e.source, e.from, e.to, e.fromRef, e.toRef = a_src, nil, ra, nil, ref_after
    elseif kind == "removed" then
      e.source, e.from, e.to, e.fromRef, e.toRef = b_src, rb, nil, ref_before, nil
    else
      e.source, e.from, e.to, e.fromRef, e.toRef = is_null(a_src) and b_src or a_src, rb, ra, ref_before, ref_after
    end
    return e
  end

  if ra ~= nil and rb == nil and after_entry then
    return { kind = "added", text = ("added: %s -> %s"):format(name, short(ra)), entry = entry("added") }
  end
  if rb ~= nil and ra == nil then
    return { kind = "removed", text = ("removed: %s (was %s)"):format(name, short(rb)), entry = entry("removed") }
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
  if is_tag_ref(ref_before) and is_tag_ref(ref_after) and ref_before ~= ref_after then
    return {
      kind = "updated",
      text = ("updated: %s %s -> %s (%s -> %s)"):format(name, ref_before, ref_after, short(rb), short(ra)),
      requested = requested_here,
      explained = true,
      entry = entry("updated", "tag-changed"),
    }
  end

  local reason, reason_code = nil, nil
  if ref_before == nil and is_tag_ref(ref_after) then
    reason = ("version constraint resolved: %s"):format(ref_after)
    reason_code = "version-resolved"
  elseif
    before_entry
    and after_entry
    and is_true(before_entry.pin)
    and is_frozen_rev(ref_before)
    and not is_true(after_entry.pin)
    and ref_after == nil
  then
    -- `pin` is deliberately not one of identity_fields (dropping it must not itself invalidate a
    -- carried ref -- see resolve.lua's merge comment), so same_identity below never catches an
    -- unpin on its own. But dropping `pin` does thaw the freeze (resolve.lua's merge sets
    -- resolvedRef back to null), and the URL then goes back to tracking a branch/tag, which a
    -- plain `nix flake lock` moves to HEAD -- a legitimate move with nothing else to explain it.
    reason = "unpinned"
    reason_code = "unpinned"
  elseif before_entry and after_entry and not same_identity(before_entry, after_entry) then
    reason = "spec changed"
    reason_code = "spec-changed"
  end

  local text = ("updated: %s %s -> %s"):format(name, short(rb), short(ra))
  if reason then
    text = text .. " (" .. reason .. ")"
  end
  return {
    kind = "updated",
    text = text,
    requested = requested_here,
    explained = reason ~= nil,
    entry = entry("updated", reason_code),
  }
end

-- JSON buckets (#77), filled next to the text's lines/counts with the very same inclusion rule.
-- A plain lock (--plain) skips nothing, so a pinned plugin there is just unchanged.
local buckets = { updated = {}, added = {}, removed = {}, unchanged = {}, skippedPinned = {} }

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
      if c.kind == "updated" or c.kind == "added" or c.kind == "removed" then
        local b = buckets[c.kind]
        b[#b + 1] = c.entry
      elseif c.kind == "pinned" and not plain then
        buckets.skippedPinned[#buckets.skippedPinned + 1] = name
      else
        buckets.unchanged[#buckets.unchanged + 1] = name
      end
    end
  end
end

-- The synthetic lazy.nvim seed input (§3.6 of the plan): always reported for a full update, and
-- in named mode when the user actually asked to move it with `--update lazy.nvim`. It is also a
-- valid target of the unnamed-move safety net (docs/architecture.md calls it an "input" like any
-- other): named mode with lazy.nvim neither requested nor mentioned still has to surface it if it
-- moved anyway, exactly as an unrequested plugin would -- lazy has no spec to check a reason
-- against, so an unrequested move is always unexplained.
--
-- #49: this whole block only applies when `not lazy_is_spec`. When the spec has its own lazy.nvim,
-- the injection above already put it in plugins_before/plugins_after under the name "lazy.nvim",
-- so the main classify() loop already reported it -- with a real reason to check against
-- ("spec changed" and the rest), not the "always unexplained" rule this block hard-codes. Running
-- both would print lazy.nvim twice.
if not lazy_is_spec then
  local lazy_rb, lazy_ra = locked_rev_before(lazy_input_name), locked_rev_after(lazy_input_name)
  local lazy_moved = lazy_rb ~= lazy_ra
  if mode_all or lazy_requested or lazy_moved then
    if lazy_moved then
      -- The seed has no plugins.json entry, so its JSON entry is built here from lazyNvim. A
      -- first lock (no lazy-nvim node before) is an addition, not the text's "? -> rev" update.
      local lazy_doc = type(plugins_after_doc.lazyNvim) == "table" and plugins_after_doc.lazyNvim
        or type(plugins_before_doc.lazyNvim) == "table" and plugins_before_doc.lazyNvim
        or {}
      local e = {
        name = LAZY_NAME,
        inputName = lazy_input_name,
        source = lazy_doc.source,
        from = lazy_rb,
        to = lazy_ra,
      }
      if lazy_rb == nil and lazy_ra ~= nil then
        buckets.added[#buckets.added + 1] = e
      else
        buckets.updated[#buckets.updated + 1] = e
      end
      lines[#lines + 1] = ("updated: lazy.nvim (seed) %s -> %s"):format(short(lazy_rb), short(lazy_ra))
      counts.updated = counts.updated + 1
      if not mode_all and not lazy_requested then
        warn_names[#warn_names + 1] = "lazy.nvim"
      end
    else
      buckets.unchanged[#buckets.unchanged + 1] = LAZY_NAME
      lines[#lines + 1] = "unchanged: lazy.nvim (seed)"
      counts.unchanged = counts.unchanged + 1
    end
  end
end

-- #77: the machine-readable report. Written before any text so that the text's early exits below
-- cannot skip it, and built from the same buckets the text was. `from`/`to` are the full revs.

-- A compare link only when it is certain to be valid: a github source whose owner and repo
-- (one trailing "/" allowed, as source.lua keeps it) are plain names, and both revs known.
local function compare_url(e)
  local src = e.source
  if type(src) ~= "table" or src.type ~= "github" or type(e.from) ~= "string" or type(e.to) ~= "string" then
    return vim.NIL
  end
  local owner, repo = src.owner, src.repo
  if type(owner) ~= "string" or type(repo) ~= "string" then
    return vim.NIL
  end
  repo = repo:gsub("/$", "")
  if not (owner:match("^[%w._-]+$") and repo:match("^[%w._-]+$")) then
    return vim.NIL
  end
  return ("https://github.com/%s/%s/compare/%s...%s"):format(owner, repo, e.from, e.to)
end

local function nn(v)
  if v == nil then
    return vim.NIL
  end
  return v
end

local function entries(list)
  table.sort(list, function(a, b)
    return a.name < b.name
  end)
  local out = {}
  for i, e in ipairs(list) do
    out[i] = {
      name = e.name,
      inputName = e.inputName,
      source = nn(e.source),
      from = nn(e.from),
      to = nn(e.to),
      fromRef = nn(e.fromRef),
      toRef = nn(e.toRef),
      reason = nn(e.reason),
      compareUrl = list == buckets.updated and compare_url(e) or vim.NIL,
    }
  end
  return json.array(out)
end

local function sorted_names(list)
  table.sort(list)
  return json.array(list)
end

if json_path then
  local req, seen_req = {}, {}
  if not plain then
    for _, n in ipairs(requested) do
      if not seen_req[n] then
        seen_req[n] = true
        req[#req + 1] = n
      end
    end
  end
  local unexplained = {}
  if not plain and not mode_all then
    for _, n in ipairs(warn_names) do
      unexplained[#unexplained + 1] = n
    end
  end
  local doc = {
    added = entries(buckets.added),
    mode = plain and "lock" or (mode_all and "update-all" or "update-named"),
    removed = entries(buckets.removed),
    requested = sorted_names(req),
    schemaVersion = 1,
    skippedPinned = sorted_names(buckets.skippedPinned),
    unchanged = sorted_names(buckets.unchanged),
    unexplained = sorted_names(unexplained),
    updated = entries(buckets.updated),
  }
  local f, err = io.open(json_path, "w")
  if not f then
    die("cannot write " .. json_path .. ": " .. tostring(err))
  end
  local ok, werr = f:write(json.encode(doc))
  if not ok then
    die("cannot write " .. json_path .. ": " .. tostring(werr))
  end
  local cok, cerr = f:close()
  if not cok then
    die("cannot write " .. json_path .. ": " .. tostring(cerr))
  end
end
if plain then
  os.exit(0)
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
