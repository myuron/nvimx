-- nvimx resolver (minimal Phase 2 version)
--
-- Usage:
--   nvim -l resolve.lua <raw-spec.json> <where to write plugins.json> \
--     [--prev <existing plugins.json>] [--lock <existing flake.lock>] [--lazy <lazy.nvim path>] \
--     [--update [<name>]]... [--update-plan <path>] [--import-lazy-lock <lazy-lock.json>]
--
-- Converts raw-spec.json into the plugins.json schema, merging with the previous lock so that
-- refs already decided stay decided (--prev) and `pin = true` plugins get frozen onto the rev
-- the lock currently records (--lock). Both are read up front and the output is written last,
-- so --prev may safely point at the very path being written.
-- --lazy points at a checkout of lazy.nvim (the store path nvimx-lock uses as its seed) and is
-- required whenever a version constraint needs resolving (#23): it is where lazy's own
-- lua/lazy/manage/semver.lua is dofile()d from, so matching stays bit-exact with lazy itself.
-- --import-lazy-lock reads an existing lazy.nvim lock and seeds each matching plugin's
-- `resolvedRef` with the commit lazy already recorded (#25), so migrating from plain lazy.nvim
-- pins exactly the plugin set the user is running today. Only plugins with no previous decision
-- at all are seeded -- an existing --prev entry always wins. The seed is written to `resolvedRef`
-- only, never to `commit` or `branch`: those are part of the spec identity, so writing there
-- would make the next plain lock discard the seed as a spec change.

local function fail(msg)
  io.stderr:write("[nvimx] resolve failed: " .. tostring(msg) .. "\n")
  os.exit(1)
end

local function usage()
  io.stderr:write(
    "usage: nvim -l resolve.lua <raw-spec.json> <plugins.json> [--prev <plugins.json>] "
      .. "[--lock <flake.lock>] [--lazy <lazy.nvim path>] [--update [<name>]]... "
      .. "[--update-plan <path>] [--import-lazy-lock <path>]\n"
  )
  os.exit(2)
end

-- A flag loop rather than fixed positions: #24 added --update / --update-plan here, and #25
-- (--import-lazy-lock) can add itself the same way without disturbing the callers that only pass
-- the two positional paths.
local raw_path, out_path, prev_path, lock_path, lazy_path, update_plan_path, import_path
local update_all = false
local update_names = {}
do
  local saw_bare_update = false
  local saw_named_update = false
  local positional = {}
  local i = 1
  while i <= #arg do
    local a = arg[i]
    if a == "--prev" or a == "--lock" or a == "--lazy" or a == "--update-plan" or a == "--import-lazy-lock" then
      local value = arg[i + 1]
      if not value then
        io.stderr:write(("[nvimx] resolve: %s needs a path\n"):format(a))
        usage()
      end
      if a == "--prev" then
        prev_path = value
      elseif a == "--lock" then
        lock_path = value
      elseif a == "--lazy" then
        lazy_path = value
      elseif a == "--import-lazy-lock" then
        import_path = value
      else
        update_plan_path = value
      end
      i = i + 2
    elseif a == "--update" then
      -- One-token lookahead, repeatable (#24): a following argument that does not itself start
      -- with "--" is a name to update, consumed right here; anything else (another flag, or the
      -- end of argv) means this occurrence is the "update everything" marker.
      local value = arg[i + 1]
      if value and value:sub(1, 2) ~= "--" then
        update_names[#update_names + 1] = value
        saw_named_update = true
        i = i + 2
      else
        update_all = true
        saw_bare_update = true
        i = i + 1
      end
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
  -- lock-app.nix rejects this same combination itself, before resolve.lua is ever invoked (its
  -- own bare `--update` and named `--update <name>` cannot both survive its parser -- see its
  -- comment for why letting it reach here would silently collapse into "just the names"). This
  -- copy only matters for someone driving resolve.lua by hand.
  if saw_bare_update and saw_named_update then
    io.stderr:write("[nvimx] resolve: --update takes either no names (update everything) or names, not both\n")
    usage()
  end
end

local json = dofile(arg[0]:gsub("resolve%.lua$", "json.lua"))
local ver = dofile(arg[0]:gsub("resolve%.lua$", "version.lua"))

-- The default advice is prev-specific (checks.resolve-merge greps "is not valid JSON" and "run
-- nvimx-lock again", so its wording must stay byte-identical); --import-lazy-lock's own advice
-- (#25) is passed in explicitly instead of changing the default.
local JSON_ADVICE_LOCK = "Fix the file, or delete it and run nvimx-lock again -- deleting it loses the pinned revs."
local JSON_ADVICE_IMPORT =
  "Fix the file, or regenerate it with :Lazy restore in lazy.nvim -- nvimx will not guess the commits."

local function read_json(path, what, advice)
  local f = io.open(path, "r")
  if not f then
    fail(("cannot open %s: %s"):format(what, path))
  end
  local text = f:read("*a")
  f:close()
  local ok, decoded = pcall(vim.json.decode, text)
  if not ok then
    -- Silently regenerating would drop every pinned rev, so this has to be fatal.
    fail(("%s is not valid JSON (%s): %s. "):format(what, path, decoded) .. (advice or JSON_ADVICE_LOCK))
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

-- --import-lazy-lock (#25): lazy.nvim's own lock file, parsed up front like --prev / --lock so
-- the seed step in the main loop below can look plugins up by name. Nothing is reported here --
-- reporting needs raw.plugins (to tell "not in the config" from "disabled" from "lazy.nvim
-- itself"), which is not walked until after the main loop, so every finding here is only
-- collected, never printed, until the dedicated report block near the end of this file.
--
-- import_db is nil when --import-lazy-lock was not passed at all (the seed step below is then a
-- no-op) and a (possibly empty) table otherwise, name -> { commit, branch }. import_bad holds
-- every entry that could not be understood, `{ name, reason }`, name-order not yet meaningful
-- (pairs() order; sorted at report time).
local import_db = nil
local import_bad = {}
if import_path then
  local decoded = read_json(import_path, "the lazy-lock.json", JSON_ADVICE_IMPORT)
  -- vim.json.decode of a top-level JSON array returns a table with integer keys, not a string
  -- keyed one -- so it is *not* caught here. It falls through to the entry loop below instead,
  -- where every "key" turns out to be a number and is reported as classification 9's
  -- "key is not a plugin name". That is deliberate (only a JSON scalar -- a bare number, string,
  -- or boolean -- is a hard error): dropping a whole migration's worth of data because the file
  -- happens to be a JSON array would be a worse failure mode than reporting every entry as bad.
  if type(decoded) ~= "table" then
    -- vim.json.decode of a top-level JSON `null` returns vim.NIL, whose Lua type is "userdata" --
    -- true, but meaningless to a user reading this message. Say "null" instead, the actual JSON
    -- word they wrote.
    local decoded_desc = decoded == vim.NIL and "null" or ("a " .. type(decoded))
    fail(("the lazy-lock.json (%s) is not a table (it decoded to %s)"):format(import_path, decoded_desc))
  end
  import_db = {}
  for name, v in pairs(decoded) do
    if type(name) ~= "string" then
      import_bad[#import_bad + 1] = { name = tostring(name), reason = "key is not a plugin name" }
    elseif type(v) ~= "table" then
      -- Catches vim.NIL too (a JSON `null` value): its Lua type is "userdata", not "table", so
      -- this branch is reached and .commit is never indexed into it.
      import_bad[#import_bad + 1] = { name = name, reason = "value is not an object" }
    elseif is_null(v.commit) or type(v.commit) ~= "string" then
      import_bad[#import_bad + 1] = { name = name, reason = "no commit" }
    elseif not is_frozen_rev(v.commit) then
      import_bad[#import_bad + 1] = { name = name, reason = ("commit %q is not a 40-hex sha"):format(v.commit) }
    else
      import_db[name] = { commit = v.commit, branch = type(v.branch) == "string" and v.branch or nil }
    end
  end
end

-- Collected while the main loop below runs, then sorted and reported (#25's report block).
local import_seeded = {} -- name -> true, for plugins whose resolvedRef this run seeded
local import_pinned = {} -- { name, commit }[], classification 1
local import_skipped = {} -- { name, reason }[], classifications 2/3
local import_prev_blocked = 0 -- classification 4's count (an aggregate, not a per-name list)
-- name -> true, for every import_db-matched, non-local plugin the main loop below classified into
-- import_pinned / import_skipped / import_prev_blocked (whichever it was). Used only by the report
-- loop's explicit else bucket (plan §3.6, review item 7): that loop walks the same names again from
-- raw.plugins, and checking this table is what lets it tell "already accounted for" apart from
-- "fell through unclassified" without depending on its own `p.dev or p.dir` check staying in sync
-- with this loop's, by construction rather than by two distant conditions matching textually.
local import_accounted = {}

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

-- Plugins whose previous decision must be thrown away and re-resolved. Populated below, once
-- --update's name validation has run (#24): an explicit name forces just that plugin (even if
-- pinned or commit-fixed); a bare --update forces everything that is not `pin = true`. Empty,
-- and never touched, on a plain lock.
local force = {}

-- Normalize into a form usable as a flake input name ([^A-Za-z0-9_-] → "-")
local function to_input_name(name)
  return (name:gsub("[^%w_-]", "-"))
end

-- Convert the git URL normalized by lazy into a source struct (github gets its own type)
local function parse_source(name, url)
  if type(url) ~= "string" then
    fail(("plugin %q has no url. lazy derives one from the spec, so a raw spec without it is malformed"):format(name))
  end
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
-- pin / dependencies / build are deliberately excluded: they are metadata that never
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

local function short_sha(s)
  -- A raw spec can be malformed by hand (or by a future bug upstream of here) into a `commit`
  -- that is not a string at all; s:sub would crash on it. tostring() degrades to something
  -- readable instead of taking the whole run down over what is, at worst, a confusing message.
  if type(s) ~= "string" then
    return tostring(s)
  end
  return s:sub(1, 12)
end

-- Whether a lazy-lock.json entry may seed this plugin's resolvedRef (§3.4 of #25's plan).
-- Returns true, or false plus the reason to report. Only called for a plugin with no previous
-- decision at all (the caller already checked that against the raw prev_plugins[name], not the
-- force-aware `prev` local -- see the seed step itself for why that distinction matters).
local function seedable(entry, imp)
  if not is_null(entry.commit) then
    -- `commit` is part of the spec identity and genflake.lua prefers it over resolvedRef, so a
    -- spec that already fixes one makes any seed here dead weight -- and if the two disagree,
    -- the spec's own commit is what actually wins, which is worth calling out.
    local extra = ""
    if entry.commit ~= imp.commit then
      extra = (" (lazy-lock.json has %s)"):format(short_sha(imp.commit))
    end
    return false, ("the spec already fixes commit %s%s"):format(short_sha(entry.commit), extra)
  end
  local b = norm(entry.branch)
  if b and imp.branch and b ~= imp.branch then
    -- The spec's branch was changed after lazy-lock.json was written -- evidence the user wants
    -- something other than what lazy last recorded, so the spec wins (same principle as
    -- same_identity: an edited spec always beats a past decision).
    return false, ("the spec is on branch %q but lazy-lock.json recorded %q"):format(b, imp.branch)
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

-- Fatal, per-plugin problems (§3.4 of #23's plan): unlike `warn`, these do not let the lock
-- succeed. Collected rather than raised immediately, and printed together right before exiting,
-- so a single lock run surfaces every problem at once instead of dying on the first one pairs()
-- happens to visit.
local resolve_errors = {}
local function fail_plugin(name, msg)
  resolve_errors[#resolve_errors + 1] = { name = name, msg = ("plugin %q: %s"):format(name, msg) }
end

-- Sorts and prints every fatal problem collected in resolve_errors so far (if any), then exits 1.
-- Split out of the version-resolution failure block near the end of this file (#24) so that
-- --update's name validation -- which has to run before the main loop below, so an unknown name
-- never survives long enough to spend a git ls-remote on it -- can call it too, giving both kinds
-- of fatal problem the same "collect everything, then report once" behavior #23 established.
local function report_resolve_errors()
  if #resolve_errors == 0 then
    return
  end
  table.sort(resolve_errors, function(a, b)
    if a.name ~= b.name then
      return a.name < b.name
    end
    return a.msg < b.msg
  end)
  for _, e in ipairs(resolve_errors) do
    io.stderr:write("[nvimx] resolve failed: " .. e.msg .. "\n")
  end
  os.exit(1)
end

-- The first `n` lines of `s`, joined for a one-line stderr message (git's own stderr can be
-- several lines; the whole thing would be noisy next to a per-plugin fatal error).
local function first_lines(s, n)
  local out = {}
  for line in (s or ""):gmatch("[^\n]+") do
    out[#out + 1] = line
    if #out >= n then
      break
    end
  end
  return table.concat(out, " / ")
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

-- Plugins whose `version` still needs a decision, and every plugin that has a `version` at all
-- (the latter for the pin+version warning below, which must fire independent of whether this run
-- is the one that resolves it). Filled in the loop below, resolved in a batch after it (#23).
local pending = {}
local versioned = {}

local function warn_plugin(name, msg)
  plugin_warnings[#plugin_warnings + 1] = { name = name, msg = ("plugin %q: %s"):format(name, msg) }
end

-- Classify a single build element/scalar using lazy's own dispatch order
-- (lua/lazy/manage/task/plugin.lua:67-81): function → rockspec → excmd → *.lua → shell.
-- extract.lua turns any non-string element into a "<type>" placeholder, so a leading "<" is the
-- only way a function (or other non-string) can show up here.
---@param v string one build element/scalar, as dumped by extract.lua
---@return table { kind, cmd? }
local function classify_step(v)
  if type(v) ~= "string" or v:sub(1, 1) == "<" then
    return { kind = "function" }
  elseif v == "rockspec" then
    return { kind = "rockspec" }
  elseif v:sub(1, 1) == ":" then
    return { kind = "excmd", cmd = v }
  elseif v:match("%.lua$") then
    return { kind = "luafile", cmd = v }
  else
    return { kind = "shell", cmd = v }
  end
end

-- `false` and unset both mean "no build" (task/plugin.lua:57); a table is expanded into `steps`
-- (an empty table collapses to `none` -- there is nothing to run either way); anything else is a
-- single-element `steps` list once classified. Nesting never occurs: `steps[].kind` is never
-- itself "none" or "steps".
---@param b string|string[]|false|nil the raw build field, as dumped by extract.lua
---@return table { kind, cmd? } | { kind = "steps", steps }
local function classify_build(b)
  if b == false or b == nil then
    return { kind = "none" }
  elseif type(b) == "table" then
    local steps = {}
    for _, v in ipairs(b) do
      steps[#steps + 1] = classify_step(v)
    end
    if #steps == 0 then
      return { kind = "none" }
    end
    return { kind = "steps", steps = json.array(steps) }
  else
    return classify_step(b)
  end
end

-- How to name a build step that is not a shell command, keyed by `kind` rather than by the
-- extract.lua placeholder: a table build's elements are classified individually now, and
-- "<table>" itself never reaches here (it is expanded into steps before classification).
local build_phrasing = {
  ["function"] = "a Lua function",
  ["excmd"] = "a neovim command",
  ["rockspec"] = "a luarocks build",
  ["luafile"] = "a Lua file",
}

-- Steps of a "steps" build that cannot run at build time, in declared order.
---@param build table the classified build ({ kind = "steps", steps } or a scalar shape)
---@return table[] { index, kind, cmd? }[]
local function unrunnable_steps(build)
  local out = {}
  if build.kind ~= "steps" then
    return out
  end
  for i, s in ipairs(build.steps) do
    if s.kind ~= "shell" then
      out[#out + 1] = { index = i, kind = s.kind, cmd = s.cmd }
    end
  end
  return out
end

-- One clause describing a single unrunnable step, e.g. `step 2 is a neovim command (":TSUpdate")`.
---@param s table one element of unrunnable_steps' result
---@return string
local function step_clause(s)
  local what = build_phrasing[s.kind] or "not a shell command"
  if s.cmd then
    return ("step %d is %s (%q)"):format(s.index, what, s.cmd)
  end
  return ("step %d is %s"):format(s.index, what)
end

-- The full message for a plugin whose build cannot run entirely (scalar excmd/function/rockspec/
-- luafile) or only partially (some steps of a "steps" build). Scalar wording is kept byte-for-byte
-- identical to before this file grew `steps` support (checks.resolve-build-warnings pins it).
---@param name string
---@param build table the classified build
---@return string
local function build_warning(name, build)
  if build.kind ~= "steps" then
    local what = build_phrasing[build.kind] or "not a shell command"
    -- "rockspec" carries no cmd because the spec's whole build *is* that word, so quote it as
    -- written. The "<...>" form means "the spec had something that is not a string" and would be
    -- a lie here; `function` keeps it because that is what the spec did have.
    local cmd = build.cmd or (build.kind == "rockspec" and "rockspec") or ("<" .. build.kind .. ">")
    local msg = ("build is %s (%q) and cannot be run at build time"):format(what, cmd)
    if name == "nvim-treesitter" then
      msg = msg .. ". nvimx merges parsers from nixpkgs instead -- set programs.nvimx.treesitter.grammars"
    end
    return msg
  end

  local unrunnable = unrunnable_steps(build)
  local total = #build.steps
  local shell_count = total - #unrunnable
  local clauses = {}
  for _, s in ipairs(unrunnable) do
    clauses[#clauses + 1] = step_clause(s)
  end
  local remaining
  if shell_count == 0 then
    remaining = "none of them run"
  elseif shell_count == 1 then
    remaining = "the remaining shell step still runs"
  else
    remaining = ("the remaining %d shell steps still run"):format(shell_count)
  end
  local msg = ("build is a list of %d steps and %d of them cannot be run at build time: %s; %s"):format(
    total,
    #unrunnable,
    table.concat(clauses, "; "),
    remaining
  )
  if name == "nvim-treesitter" then
    msg = msg .. ". nvimx merges parsers from nixpkgs instead -- set programs.nvimx.treesitter.grammars"
  end
  return msg
end

-- #24: `--update [name...]`'s name validation and force-set construction. Every requested name
-- is checked, and any problem is collected via fail_plugin, *before* the main loop below ever
-- gets a chance to run -- an unknown name must not survive long enough to spend a git ls-remote
-- on it. report_resolve_errors() prints everything collected so far and exits if any name was
-- bad, so nothing past this point (including plugins.json) is ever written for a failed --update.
local lazy_requested = false
if update_all or #update_names > 0 then
  -- Display name -> inputName, for a "did you mean" hint when someone types the inputName
  -- (e.g. "tokyonight-nvim") instead of the display name resolve.lua and --update both key on.
  local input_name_lookup = {}
  for rn in pairs(raw.plugins or {}) do
    input_name_lookup[to_input_name(rn)] = rn
  end

  for _, name in ipairs(update_names) do
    if name == "lazy.nvim" then
      -- Accepted, but it is not a spec plugin: it becomes an update-plan entry for the synthetic
      -- lazy-nvim input directly (below), never a `force` entry.
      lazy_requested = true
    else
      local p = (raw.plugins or {})[name]
      if p == nil then
        local hint = input_name_lookup[name]
        local msg = "unknown plugin"
        if hint then
          msg = msg .. (" (did you mean %q?)"):format(hint)
        end
        fail_plugin(name, msg)
      elseif p.dev or p.dir then
        fail_plugin(name, "is a local plugin (dev/dir); nothing to lock or update")
      else
        -- Named, even if `pin` or `commit` is set: naming a plugin explicitly is what overrides
        -- both (§3.2 of the plan). A `commit`-fixed plugin still ends up here and in the
        -- update-plan -- harmlessly, since its URL cannot move either way.
        force[name] = true
      end
    end
  end
  report_resolve_errors()

  if update_all then
    for rn, p in pairs(raw.plugins or {}) do
      if not (p.dev or p.dir) and not is_true(p.pin) then
        force[rn] = true
      end
    end
  end
end

for name, p in pairs(raw.plugins or {}) do
  if p.dev or p.dir then
    local_plugins[name] = { dir = p.dir }
  else
    local input_name = to_input_name(name)
    if seen_inputs[input_name] then
      error(("input name collision: %s (%s / %s)"):format(input_name, name, seen_inputs[input_name]))
    end
    seen_inputs[input_name] = name

    local build = classify_build(p.build)

    -- Only "shell" steps can run inside the nix build sandbox; plugin-drv.nix installs the rest
    -- with helptags only. Say so here rather than letting the plugin misbehave at runtime (#22).
    -- A build entirely made of shell steps (scalar "shell" or an all-shell "steps") warns about
    -- nothing at all.
    local has_unrunnable = (build.kind ~= "none" and build.kind ~= "shell" and build.kind ~= "steps")
      or (build.kind == "steps" and #unrunnable_steps(build) > 0)
    if has_unrunnable then
      unbuildable = true
      warn_plugin(name, build_warning(name, build))
    end

    local entry = {
      inputName = input_name,
      source = parse_source(name, p.url),
      branch = p.branch or vim.NIL,
      tag = p.tag or vim.NIL,
      commit = p.commit or vim.NIL,
      version = p.version or vim.NIL,
      pin = p.pin or vim.NIL,
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
      -- Caveat (#23): a `pin = true` plugin that also carries `version` and gets resolved on its
      -- very first lock (no rev in flake.lock yet to freeze onto) ends up with a "refs/tags/..."
      -- resolvedRef instead of a 40-hex one -- and unlike a 40-hex freeze, that URL can move if
      -- the upstream repo moves the tag, since resolving a tag ref to a commit is nix's fetcher's
      -- job, done fresh on every `nix flake lock`. It is not the same guarantee as the 40-hex
      -- case above, and is accepted as such (docs/architecture.md's pin row has the same note).
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

    -- --import-lazy-lock (#25): seed this plugin's resolvedRef from lazy-lock.json, but only when
    -- there is truly no previous decision to override. This has to run before #23's gate just
    -- below: a non-null resolvedRef closes that gate, which is exactly what lets a
    -- `defaults.version` migration need no ls-remote at all (the whole point of seeding here
    -- rather than after semver resolution runs).
    --
    -- The check is against the raw prev_plugins[name], deliberately not the `prev` local computed
    -- above: `prev` is nil whenever force[name] is set (see its definition), which would make
    -- `--update foo --import-lazy-lock ...` seed foo right back to lazy's old commit -- reversing
    -- what --update just asked for. The CLI (lock-app.nix) rejects the combination outright, but
    -- resolve.lua's own semantics still have to be right for anyone driving it by hand.
    -- A `prev` entry with resolvedRef == null still blocks the seed: null is itself a decision
    -- ("track this ref, nothing to pin"), and overwriting it with an old commit would silently
    -- revert a plugin that is meant to keep moving.
    --
    -- Risk worth recording here (docs/architecture.md's `--import-lazy-lock` caveat points back at
    -- this comment): seeding a git-type (non-GitHub) plugin whose spec also names a `tag` produces
    -- a genflake URL with both `ref` and `rev` set (`?ref=refs/tags/<t>&rev=<sha>`), because
    -- genflake's git-type branch fills in `ref` from `tag`/`branch` whenever one is not already
    -- implied by the rev, and a seeded resolvedRef does not suppress that. Most git servers resolve
    -- an unadvertised rev fine regardless of `ref`, but one that refuses to would fail at
    -- `nix flake lock`, naming the input -- the same failure mode the README documents for a plain
    -- branchless git URL.
    if import_db and not (prev_plugins and prev_plugins[name] ~= nil) then
      local imp = import_db[name]
      if imp then
        import_accounted[name] = true
        local ok, why = seedable(entry, imp)
        if ok then
          entry.resolvedRef = imp.commit
          import_seeded[name] = true
          import_pinned[#import_pinned + 1] = { name = name, commit = imp.commit }
        else
          import_skipped[#import_skipped + 1] = { name = name, reason = why }
        end
      end
    elseif import_db and import_db[name] then
      import_accounted[name] = true
      import_prev_blocked = import_prev_blocked + 1
    end

    -- Gate for semver resolution (#23): every plugin with a version constraint still needing a
    -- decision is queued rather than resolved right here, so that ls-remote can be batched and
    -- parallelized across all of them once the whole spec has been walked (§3.2 of the plan).
    --
    -- The condition's subject is the raw `p.version`, not `entry.version`, and that is not
    -- interchangeable: entry.version = p.version or vim.NIL, and vim.NIL is a userdata, which is
    -- truthy in Lua. So `entry.version` reads as truthy for *every* plugin, including ones with no
    -- version at all or with `version = false` -- gating on it would send every unresolved plugin
    -- into ls-remote and then crash on Semver.range(nil). `p.version` is nil/false exactly when
    -- there is no constraint to honor, so it is what has to be tested.
    -- `commit` / `tag` win over `version` (matching lazy's own get_target dispatch order), so a
    -- plugin that also names one of those is left out of the gate even though it has a version.
    if p.version and is_null(entry.resolvedRef) and is_null(entry.commit) and is_null(entry.tag) then
      pending[#pending + 1] = {
        name = name,
        entry = entry,
        url = p.url,
        constraint = p.version,
        from_defaults = p.versionFromDefaults,
      }
    end
    -- Every plugin with a version constraint needs the pin+version warning check below, whether
    -- or not this run is the one resolving it (a pin-frozen entry never enters `pending` at all).
    if p.version then
      versioned[#versioned + 1] =
        { name = name, entry = entry, constraint = p.version, from_defaults = p.versionFromDefaults }
    end

    plugins[name] = entry
  end
end

-- Semver resolution (#23). Everything above only *queued* the plugins that need it; the actual
-- git ls-remote traffic happens here, once, so it can be parallelized across all of them rather
-- than one plugin at a time.
--
-- fallbacks[constraint] collects the names of plugins whose `defaults.version`-derived constraint
-- matched nothing (§3.4.5): reported as one aggregated stderr line per distinct constraint string,
-- never as a per-plugin warning (that would make plugins.json unreadable for a config using
-- `defaults = { version = "*" }`, since it would list every tagless plugin every single lock).
local fallbacks = {}
local function add_fallback(constraint, name)
  fallbacks[constraint] = fallbacks[constraint] or {}
  fallbacks[constraint][#fallbacks[constraint] + 1] = name
end

if #pending > 0 then
  -- Loading lazy's semver module is deferred to exactly here (not done unconditionally at the
  -- top of the file) so that a raw-spec with no version constraints at all never requires --lazy.
  if not lazy_path or lazy_path == "" then
    fail("a version constraint needs --lazy <lazy.nvim path>")
  end
  local semver_path = lazy_path:gsub("/+$", "") .. "/lua/lazy/manage/semver.lua"
  local ok, mod = pcall(dofile, semver_path)
  if not ok or type(mod) ~= "table" then
    fail(
      ("cannot load lazy.nvim's semver module from --lazy %s (tried %s): %s"):format(
        lazy_path,
        semver_path,
        tostring(mod)
      )
    )
  end
  local Semver = mod

  -- Classify grammar errors (classification D) before any network access, for every pending
  -- constraint at once. This has to happen strictly before ls-remote: doing it lazily (only
  -- inside select_tag, after the fetch) would make a bad constraint on an unreachable URL report
  -- as a ls-remote failure instead, so the same config could be classified D or C depending on
  -- whether the network happens to be up -- exactly the non-determinism §3.4.4 rules out.
  local syntax_ok = {}
  for _, item in ipairs(pending) do
    if type(item.constraint) ~= "string" then
      -- Semver.range indexes its argument, so a non-string raises rather than returning nil --
      -- which would abort the whole run and discard every other plugin's error. `version = 1.2`
      -- with the quotes forgotten is an easy Lua typo and lazy passes it through unvalidated.
      fail_plugin(
        item.name,
        ('version constraint %s is not a string. lazy version constraints are strings, like "^1.2".'):format(
          tostring(item.constraint)
        )
      )
    elseif Semver.range(item.constraint) == nil then
      fail_plugin(
        item.name,
        ('version constraint %q is not valid lazy.nvim semver syntax (supported: *, 1.2.3, =1.2.3, >1.2.3, >=1.2.3, ^1.2, ~1.2, 1.x, "1.2 - 2.0"). %q is not supported.'):format(
          tostring(item.constraint),
          tostring(item.constraint)
        )
      )
    else
      syntax_ok[#syntax_ok + 1] = item
    end
  end
  pending = syntax_ok

  table.sort(pending, function(a, b)
    return a.name < b.name
  end)

  if #pending > 0 then
    -- stdout, not stderr: nvimx-lock holds resolve.lua's stderr back until the very end (#22), so
    -- a progress line belongs on stdout to actually be seen while ls-remote is in flight.
    io.stdout:write(("nvimx-lock: resolving version constraints for %d plugin(s)\n"):format(#pending))
  end

  local BATCH_SIZE = 8
  local LS_REMOTE_TIMEOUT_S = 60
  local i = 1
  while i <= #pending do
    local last = math.min(i + BATCH_SIZE - 1, #pending)
    for j = i, last do
      local item = pending[j]
      if type(item.url) ~= "string" or item.url == "" then
        item.url_missing = true
      else
        -- vim.system raises rather than returning an error when git is not on PATH. lock-app.nix
        -- puts it there, but a hand-run resolve.lua should say which tool is missing instead of
        -- producing a traceback and discarding every other plugin's error.
        local spawned, proc = pcall(
          vim.system,
          { "git", "ls-remote", "--tags", "--refs", item.url },
          { text = true, env = { GIT_TERMINAL_PROMPT = "0" }, timeout = LS_REMOTE_TIMEOUT_S * 1000 }
        )
        if spawned then
          item.proc = proc
        else
          item.spawn_error = tostring(proc)
        end
      end
    end
    for j = i, last do
      local item = pending[j]
      if item.url_missing then
        fail_plugin(item.name, ("has no usable url to resolve version constraint %q"):format(tostring(item.constraint)))
      elseif item.spawn_error then
        fail_plugin(item.name, ("could not run git ls-remote (is git on PATH?): %s"):format(item.spawn_error))
      else
        local res = item.proc:wait()
        -- wait() returns nil when the pipes never reach EOF, which happens if the killed git left
        -- a grandchild (ssh, a credential helper) holding them. Treat it as the timeout it is,
        -- rather than letting the next line raise and throw away every other plugin's error.
        if not res then
          fail_plugin(item.name, ("git ls-remote timed out for %s"):format(item.url))
        elseif res.code == 124 or (res.signal and res.signal ~= 0) then
          -- vim.system reports a timeout as exit 124 plus the signal it killed git with. Saying
          -- "exit 124" instead would make the reader look up a convention to learn they waited too
          -- long.
          fail_plugin(
            item.name,
            ("git ls-remote timed out for %s after %ds: %s"):format(
              item.url,
              LS_REMOTE_TIMEOUT_S,
              first_lines(res.stderr, 3)
            )
          )
        elseif res.code ~= 0 then
          fail_plugin(
            item.name,
            ("git ls-remote failed for %s (exit %d): %s"):format(item.url, res.code, first_lines(res.stderr, 3))
          )
        else
          local tags = ver.parse_ls_remote(res.stdout)
          local tag, detail = ver.select_tag(Semver, tags, item.constraint)
          if tag then
            item.entry.resolvedRef = "refs/tags/" .. tag
          elseif detail.kind == "no-tags" then
            if item.from_defaults then
              add_fallback(item.constraint, item.name)
            else
              fail_plugin(
                item.name,
                (
                  "version constraint %q cannot be satisfied: the remote has no tags (%s). "
                  .. "Drop the constraint, set version = false, or move it to defaults = { version = ... } "
                  .. "so that a plugin without tags falls back to its branch instead of failing the lock."
                ):format(tostring(item.constraint), item.url)
              )
            end
          else -- "no-match"
            if item.from_defaults then
              add_fallback(item.constraint, item.name)
            else
              local newest = #detail.newest > 0 and table.concat(detail.newest, ", ") or "(none)"
              fail_plugin(
                item.name,
                ("no tag matches version constraint %q (%s). %d tags parsed; newest: %s. "):format(
                  tostring(item.constraint),
                  item.url,
                  detail.parsed,
                  newest
                )
                  .. "If this plugin does not use semver tags, drop `version` or set `version = false`."
              )
            end
          end
        end
      end
    end
    i = last + 1
  end
end

-- Fallbacks are grouped by constraint string (in practice always one, since `defaults.version` is
-- a single config-wide value) and reported as one aggregated line each, sorted so the message is
-- deterministic across runs with the same set of tagless plugins.
do
  local constraints = {}
  for c in pairs(fallbacks) do
    constraints[#constraints + 1] = c
  end
  table.sort(constraints)
  for _, c in ipairs(constraints) do
    local names = fallbacks[c]
    table.sort(names)
    note(
      ("no tag matches the config-wide version constraint %q for %d plugin(s), so they follow the "):format(c, #names)
        .. ("default branch instead (lazy.nvim does the same): %s"):format(table.concat(names, ", "))
    )
  end
end

-- The pin+version warning (§3.4.6): decided last, once every constraint has actually been
-- resolved (or has fallen back), so that a plugin resolving for the first time on this very run
-- is not warned about as if it were still unresolved. Sorted by name for the same reason
-- plugin_warnings is: deterministic output regardless of pairs() traversal order.
table.sort(versioned, function(a, b)
  return a.name < b.name
end)
for _, item in ipairs(versioned) do
  if is_true(item.entry.pin) and not is_tag_ref(norm(item.entry.resolvedRef)) then
    -- pin beats the constraint: the rev is whatever the lock happens to hold, and nothing ever
    -- checks it against the range. Frozen silently, this is a trap.
    local subject = item.from_defaults and "the config-wide version constraint %q" or "version constraint %q"
    warn_plugin(item.name, ("pinned; " .. subject .. " is not validated (pin wins)"):format(tostring(item.constraint)))
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

-- --import-lazy-lock's report (#25). Everything here is note() -- stderr only, never the
-- warnings array: an import is a one-shot migration, and baking this run's circumstances into
-- the committed plugins.json would only produce a diff that the next plain lock deletes again.
-- Collected above rather than emitted inline, because both raw.plugins and import_db are walked
-- with pairs(): sorted here so two identical runs print identical stderr.
if import_db then
  local raw_plugins = raw.plugins or {}
  local disabled_set = {}
  for _, dn in ipairs(raw.disabled or {}) do
    disabled_set[dn] = true
  end
  local bad_names = {}
  for _, b in ipairs(import_bad) do
    bad_names[b.name] = true
  end

  -- lazy-lock side: every import_db entry the main merge loop above never saw at all. A name it
  -- did see (a plain plugin, not dev/dir) was already sorted into import_pinned/import_skipped/
  -- import_prev_blocked there, so this loop's matched-plugin branch below only double-checks that
  -- against import_accounted rather than doing nothing.
  local ignored_disabled, ignored_missing, local_skipped = {}, {}, {}
  local lazy_self = false
  -- Explicit else bucket (plan §3.6, review item 7): a name that matched a real, non-local config
  -- plugin (`p ~= nil` and not `p.dev or p.dir`) but that import_accounted has no record of would
  -- mean the main merge loop above fell through without sorting it into import_pinned,
  -- import_skipped, or import_prev_blocked -- silently dropping it from the
  -- `pinned + skipped + ignored == total` invariant. That cannot currently happen (the main loop's
  -- own `if imp then ... elseif import_db[name] then` already covers every matched name), but this
  -- bucket exists so a future change to either loop's matching logic drifting out of sync with the
  -- other is reported and counted instead of silently disappearing.
  local unaccounted = {}
  local lock_names = {}
  for n in pairs(import_db) do
    lock_names[#lock_names + 1] = n
  end
  table.sort(lock_names)
  local input_name_lookup = {}
  for rn in pairs(raw_plugins) do
    input_name_lookup[to_input_name(rn)] = rn
  end
  for _, n in ipairs(lock_names) do
    local p = raw_plugins[n]
    if p == nil then
      if n == "lazy.nvim" then
        -- nvimx pins lazy.nvim through its own synthetic flake input, never through a config
        -- plugin entry (raw.plugins has no "lazy.nvim" key at all -- extract.lua never adds
        -- one), so lazy-lock.json's own entry for itself is always unmatched. Called out with
        -- its own message (classification 8) rather than folded into "not in the config": it is
        -- not a config mistake, every lazy-lock.json has this entry.
        lazy_self = true
      elseif disabled_set[n] then
        ignored_disabled[#ignored_disabled + 1] = n
      else
        ignored_missing[#ignored_missing + 1] = { name = n, hint = input_name_lookup[to_input_name(n)] }
      end
    elseif p.dev or p.dir then
      local_skipped[#local_skipped + 1] = n
    elseif not import_accounted[n] then
      unaccounted[#unaccounted + 1] = n
    end
  end

  -- config side: plugins with no lazy-lock.json entry at all (classification 5). A plugin whose
  -- entry was invalid (classification 9) is deliberately excluded here (`not bad_names[rn]`): it
  -- was already reported as broken, and saying "also not in lazy-lock.json" about the very same
  -- plugin would be a second, contradictory statement about the one entry (§3.6 of the plan).
  local not_in_lock = {}
  for rn, p in pairs(raw_plugins) do
    if not (p.dev or p.dir) and import_db[rn] == nil and not bad_names[rn] then
      not_in_lock[#not_in_lock + 1] = rn
    end
  end
  table.sort(not_in_lock)

  if next(import_db) == nil and #import_bad == 0 then
    note("import: lazy-lock.json has no entries; nothing to seed")
  end

  -- Classification 1.
  table.sort(import_pinned, function(a, b)
    return a.name < b.name
  end)
  for _, e in ipairs(import_pinned) do
    note(("import: pinned %s to %s"):format(e.name, short_sha(e.commit)))
  end

  -- Classifications 2 and 3 share one message shape (seedable() already built the full reason),
  -- so they share one sorted list too.
  table.sort(import_skipped, function(a, b)
    return a.name < b.name
  end)
  for _, e in ipairs(import_skipped) do
    note(("import: skipped %s: %s"):format(e.name, e.reason))
  end

  -- Classification 3L.
  table.sort(local_skipped)
  for _, n in ipairs(local_skipped) do
    note(("import: skipped %s: it is a local plugin (dev/dir), so there is nothing to pin"):format(n))
  end

  -- Classification 4: one aggregate line, not one per plugin -- a config with a healthy-sized
  -- lock re-imported after every plugin already has a decision would otherwise print a line per
  -- plugin on every single run.
  if import_prev_blocked > 0 then
    note(
      ("import: skipped %d %s already decided by the existing lock"):format(
        import_prev_blocked,
        import_prev_blocked == 1 and "entry" or "entries"
      )
    )
  end

  -- Classification 5: always shown, even when lazy-lock.json is empty or has no entries at all --
  -- every config plugin genuinely does resolve normally in that case, and that is worth stating
  -- rather than leaving the reader to infer it from "nothing to seed" alone.
  for _, n in ipairs(not_in_lock) do
    note(("import: %s is not in lazy-lock.json; it will resolve normally"):format(n))
  end

  -- Classification 6.
  table.sort(ignored_disabled)
  for _, n in ipairs(ignored_disabled) do
    note(("import: ignored %s (disabled in the config)"):format(n))
  end

  -- Classification 7.
  table.sort(ignored_missing, function(a, b)
    return a.name < b.name
  end)
  for _, e in ipairs(ignored_missing) do
    if e.hint then
      note(("import: ignored %s (not in the config; did you mean %q?)"):format(e.name, e.hint))
    else
      note(("import: ignored %s (not in the config)"):format(e.name))
    end
  end

  -- Classification 8.
  if lazy_self then
    note("import: lazy.nvim itself is not imported (nvimx pins lazy.nvim through its own flake input)")
  end

  -- Classification 7-equivalent (plan §3.6, review item 7): see `unaccounted`'s own comment above
  -- for why this branch should be unreachable. Worded and counted like classification 7 (ignored)
  -- rather than given a whole new bucket, since from the user's point of view it is the same
  -- "nvimx has nothing decided for this" outcome -- the only thing that would make this fire is a
  -- bug in nvimx itself.
  table.sort(unaccounted)
  for _, n in ipairs(unaccounted) do
    note(
      ("import: ignored %s (matched a config plugin but was not accounted for by the import merge; "):format(n)
        .. "this is a bug in nvimx, please report it)"
    )
  end

  -- Classification 9.
  table.sort(import_bad, function(a, b)
    return a.name < b.name
  end)
  for _, b in ipairs(import_bad) do
    note(("import: invalid entry %s in lazy-lock.json: %s"):format(b.name, b.reason))
  end

  -- Classification 10: plugins whose `version` constraint was never actually checked, because a
  -- seed closed #23's gate before ls-remote ever ran for them. `versioned` is already sorted by
  -- name (just above, for the pin+version warning). Grouped by (constraint, from_defaults) rather
  -- than by constraint alone: two plugins can share the literal string "*" for different reasons
  -- (one explicit, one via `defaults.version`), and that distinction is worth keeping visible.
  -- `pin = true` plugins are excluded: they already got the "pinned; version constraint ... is
  -- not validated (pin wins)" warning above, and this would only repeat it.
  local by_constraint = {}
  local constraint_order = {}
  for _, item in ipairs(versioned) do
    if import_seeded[item.name] and not is_true(item.entry.pin) then
      local key = tostring(item.from_defaults) .. "\0" .. tostring(item.constraint)
      if not by_constraint[key] then
        by_constraint[key] = { constraint = item.constraint, from_defaults = item.from_defaults, names = {} }
        constraint_order[#constraint_order + 1] = key
      end
      local names = by_constraint[key].names
      names[#names + 1] = item.name
    end
  end
  table.sort(constraint_order, function(a, b)
    local ca, cb = by_constraint[a].constraint, by_constraint[b].constraint
    if ca ~= cb then
      return ca < cb
    end
    return a < b
  end)
  for _, key in ipairs(constraint_order) do
    local group = by_constraint[key]
    table.sort(group.names)
    -- `<PREFIX>` follows the same distinction the pin+version warning above draws (resolve.lua's
    -- own convention): explicit `version` gets "version constraint", `defaults.version` gets "the
    -- config-wide version constraint". `<name>` in the advice clause is a literal placeholder, not
    -- a stand-in for one of the plugin names -- those are listed afterwards instead.
    local subject = group.from_defaults and "the config-wide version constraint %q" or "version constraint %q"
    note(
      (
        "import: "
        .. subject
        .. " is not validated for %d plugin(s) pinned from lazy-lock.json "
        .. "(run nvimx-lock --update <name> to resolve it again): %s"
      ):format(tostring(group.constraint), #group.names, table.concat(group.names, ", "))
    )
  end

  -- Summary: the invariant §3.6 of the plan wants provable is
  -- `pinned + skipped + ignored == lazy-lock.json's total entry count`, so nothing is ever
  -- silently dropped.
  note(
    ("import: %d pinned, %d skipped, %d ignored, %d not in lazy-lock.json"):format(
      #import_pinned,
      #import_skipped + #local_skipped + import_prev_blocked,
      #ignored_disabled + #ignored_missing + (lazy_self and 1 or 0) + #import_bad + #unaccounted,
      #not_in_lock
    )
  )
end

-- Fatal version-resolution problems (§3.4): reported together, sorted the same way
-- plugin_warnings is, and only after every warning and note above so the user sees the full
-- picture before the run dies. No output file is written past this point (#18 §3.4's ordering
-- requirement: a failed resolve must not overwrite plugins.json with a partial result).
report_resolve_errors()

-- The escape hatches, in the order resolve-plugin.nix applies them. Emitted once, and to stderr
-- only: repeating this block inside plugins.json on every lock would be noise.
if unbuildable then
  note("these plugins are installed with helptags only, or with some build steps skipped. To give them a real build:")
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

-- --update-plan (#24, lock-app's own internal flag): the inputNames lock-app should hand to
-- `nix flake update`, one per line, sorted so the file is deterministic. This is exactly the
-- force set that passed name validation above -- lock-app never recomputes it -- plus the
-- synthetic lazy-nvim input whenever a full update or an explicit `--update lazy.nvim` asked
-- for it (§3.3 / §3.6 of the plan).
if update_plan_path then
  local plan_names = {}
  for name, entry in pairs(plugins) do
    if force[name] then
      plan_names[#plan_names + 1] = entry.inputName
    end
  end
  if update_all or lazy_requested then
    plan_names[#plan_names + 1] = result.lazyNvim.inputName
  end
  table.sort(plan_names)
  local pf = assert(io.open(update_plan_path, "w"))
  for _, n in ipairs(plan_names) do
    pf:write(n .. "\n")
  end
  pf:close()
end
