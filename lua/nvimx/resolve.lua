-- nvimx resolver (minimal Phase 2 version)
--
-- Usage:
--   nvim -l resolve.lua <raw-spec.json> <where to write plugins.json> \
--     [--prev <existing plugins.json>] [--lock <existing flake.lock>] [--lazy <lazy.nvim path>]
--
-- Converts raw-spec.json into the plugins.json schema, merging with the previous lock so that
-- refs already decided stay decided (--prev) and `pin = true` plugins get frozen onto the rev
-- the lock currently records (--lock). Both are read up front and the output is written last,
-- so --prev may safely point at the very path being written.
-- --lazy points at a checkout of lazy.nvim (the store path nvimx-lock uses as its seed) and is
-- required whenever a version constraint needs resolving (#23): it is where lazy's own
-- lua/lazy/manage/semver.lua is dofile()d from, so matching stays bit-exact with lazy itself.

local function fail(msg)
  io.stderr:write("[nvimx] resolve failed: " .. tostring(msg) .. "\n")
  os.exit(1)
end

local function usage()
  io.stderr:write(
    "usage: nvim -l resolve.lua <raw-spec.json> <plugins.json> [--prev <plugins.json>] "
      .. "[--lock <flake.lock>] [--lazy <lazy.nvim path>]\n"
  )
  os.exit(2)
end

-- A flag loop rather than fixed positions: #24 (--update [name...]) and #25 (--import-lazy-lock)
-- add themselves here without disturbing the callers that only pass the two positional paths.
local raw_path, out_path, prev_path, lock_path, lazy_path
do
  local positional = {}
  local i = 1
  while i <= #arg do
    local a = arg[i]
    if a == "--prev" or a == "--lock" or a == "--lazy" then
      local value = arg[i + 1]
      if not value then
        io.stderr:write(("[nvimx] resolve: %s needs a path\n"):format(a))
        usage()
      end
      if a == "--prev" then
        prev_path = value
      elseif a == "--lock" then
        lock_path = value
      else
        lazy_path = value
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
local ver = dofile(arg[0]:gsub("resolve%.lua$", "version.lua"))

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
    if Semver.range(item.constraint) == nil then
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
  local i = 1
  while i <= #pending do
    local last = math.min(i + BATCH_SIZE - 1, #pending)
    for j = i, last do
      local item = pending[j]
      if type(item.url) ~= "string" or item.url == "" then
        item.url_missing = true
      else
        item.proc = vim.system(
          { "git", "ls-remote", "--tags", "--refs", item.url },
          { text = true, env = { GIT_TERMINAL_PROMPT = "0" }, timeout = 60000 }
        )
      end
    end
    for j = i, last do
      local item = pending[j]
      if item.url_missing then
        fail_plugin(item.name, ("has no usable url to resolve version constraint %q"):format(tostring(item.constraint)))
      else
        local res = item.proc:wait()
        -- wait() returns nil when the pipes never reach EOF, which happens if the killed git left
        -- a grandchild (ssh, a credential helper) holding them. Treat it as the timeout it is,
        -- rather than letting the next line raise and throw away every other plugin's error.
        if not res then
          fail_plugin(item.name, ("git ls-remote timed out for %s"):format(item.url))
        elseif res.code ~= 0 or (res.signal and res.signal ~= 0) then
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
                ("version constraint %q cannot be satisfied: the remote has no tags (%s)."):format(
                  tostring(item.constraint),
                  item.url
                )
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

-- Fatal version-resolution problems (§3.4): reported together, sorted the same way
-- plugin_warnings is, and only after every warning and note above so the user sees the full
-- picture before the run dies. No output file is written past this point (#18 §3.4's ordering
-- requirement: a failed resolve must not overwrite plugins.json with a partial result).
if #resolve_errors > 0 then
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
