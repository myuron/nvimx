-- Classifies and validates the plugin source URL lazy.nvim normalized onto a raw-spec entry (#28).
--
-- This layer never touches the network or the filesystem: M.parse is a pure string -> struct
-- function, so the whole accept/reject matrix can be driven from a unit test with no fixture, no
-- nvim startup and no git (checks.source-parse), the same split lua/nvimx/version.lua has with
-- checks.semver-select.
--
-- Failure is reported as `nil, err` rather than raised, for the same reason
-- lua/nvimx/version.lua's select_tag gives: the severity of a bad URL, and when to report it, is
-- resolve.lua's call, not this file's -- resolve.lua's parse_source wraps every call in
-- fail_plugin() so one lock run can collect every plugin's bad URL at once instead of dying on
-- whichever one pairs() visits first.
--
-- The accept matrix is docs/architecture.md's "lazy spec -> flake input URL mapping" table; keep
-- the two in sync. `?` and `#` are rejected unconditionally (case D below) because genflake.lua
-- owns the query string: it appends `?ref=...&rev=...` itself from branch/tag/commit, so a source
-- URL that already carries one would double up into an unparseable flake ref. `${` is rejected the
-- same unconditional way (case D2): genflake.lua interpolates the URL into flake.nix with Lua's
-- `%q`, which does not escape `${`, so a URL containing it would land in the generated flake.nix
-- as a live Nix string interpolation and die with an unrelated "undefined variable" error.
--
-- The one deliberate normalization here is scp-style `user@host:path` -> `ssh://user@host/path`
-- (case 5 below): that form is otherwise unparseable as a nix flake ref (it degrades to a `path:`
-- input that only fails later, at build time, in nix/lib/sources.nix -- see the plan's §1.3).
-- Every other accepted shape is stored byte-for-byte as given: this file classifies, it does not
-- reformat, so a URL that already locks correctly today keeps the exact `source` struct it has
-- now (docs/plans/28-validate-plugin-sources.md §3.4's invariant -- changing so much as a
-- trailing slash would flip `same_identity` in resolve.lua and discard the plugin's resolvedRef).

local M = {}

---@param url string the raw url, unquoted, for %q interpolation into the message
---@param detail string
local function unsupported(url, detail)
  return ("unsupported source URL %q: %s"):format(url, detail)
end

-- github.com, but only the exact shape the github type can express: this regex is kept
-- byte-for-byte the pre-#28 one (https-only, host case-sensitive) so the accept range never
-- widens -- see §3.4 of the plan for why that matters.
--
-- Returns owner, rest, path when the URL matches https://github.com/<owner>/<anything>, nil
-- otherwise. `rest` is the raw remainder after `<owner>/` (`.git` not yet stripped); `path` is
-- `owner .. "/" .. rest` -- the raw remainder after `github.com/`, owner included -- what the
-- reject message quotes: it is easier to act on an error that echoes the input verbatim (§3.3 of
-- the plan) than one reassembled from `repo`, which by the time it exists has had its own
-- trailing `.git` stripped by the caller.
---@param url string
---@return string? owner
---@return string? rest
---@return string? path
local function github_owner_repo(url)
  local owner, rest = url:match("^https://github%.com/([^/]+)/(.+)$")
  if not owner then
    return nil
  end
  return owner, rest, owner .. "/" .. rest
end

-- Splits a scheme-prefixed URL into scheme, authority and path. `authority` is everything up to
-- the first "/" after "://"; `path` is that "/" onward (or "" when there is none). Concatenating
-- authority and path always reconstructs the original remainder byte-for-byte, which is what lets
-- the file:// case below reassemble its body from the two pieces instead of matching a third time.
-- One pattern with three captures rather than two (one to test for a scheme, a second -- repeating
-- the same scheme character class -- to also split the remainder): a failed match already returns
-- nil for every capture, which is exactly the nil scheme the caller's `if scheme then` needs.
---@param url string
---@return string? scheme
---@return string? authority
---@return string? path
local function split_scheme(url)
  return url:match("^(%a[%w+.-]*)://([^/]*)(.*)$")
end

-- scp-style `user@host:path` (no scheme at all). The only shape this file rewrites: it is not a
-- valid nix flake ref as-is (git+user@host:path degrades to a `path:` input -- §1.3 of the plan),
-- so it is normalized to ssh://user@host/path, which is. `path` starting with "/" is not this
-- form -- the caller falls through to the local-path / catch-all cases instead.
--
-- `user@` is mandatory here (every accept-matrix row, the module comment above, docs/architecture.md
-- and reject case K's own message all only ever describe `user@host:path`), so the capture requires
-- at least one byte before the "@" rather than making the whole group optional. Without that
-- requirement, any scheme-less string with a colon anywhere in it -- "myplugin:main",
-- "gitea.internal:8080" -- would silently rewrite to an ssh:// URL nobody asked for; those forms
-- are left to fall through to reject case K below, same as before this file existed.
---@param url string
---@return string? normalized the ssh:// form, or nil when url is not this shape
local function parse_scp(url)
  local user, host, path = url:match("^([^/@:]+@)([^/:]+):(.+)$")
  if user and path:sub(1, 1) ~= "/" then
    return "ssh://" .. user .. host .. "/" .. path
  end
  return nil
end

-- Turns a lazy-normalized plugin source URL into a `source` struct, or `nil, err` when nvimx has
-- no way to pin it as a flake input. See docs/plans/28-validate-plugin-sources.md §3.2 for the
-- full accept matrix this function implements, and §3.3 for the reject matrix / message wording.
---@param url unknown p.url from raw-spec.json -- may be any JSON type, not just string
---@return table? source { type = "github", owner, repo } or { type = "git", url }
---@return string? err present iff the first return is nil
function M.parse(url)
  if type(url) ~= "string" then
    return nil, "has no url. lazy derives one from the spec, so a raw spec without it is malformed"
  end
  if url == "" then
    return nil, "has an empty url. lazy derives one from the spec, so a raw spec with an empty one is malformed"
  end
  if url:find("%s") then
    return nil, unsupported(url, "it contains whitespace")
  end
  if url:find("[?#]") then
    return nil,
      unsupported(
        url,
        "it carries a query string or fragment. nvimx builds ?ref= and ?rev= itself from branch/tag/commit, so the source URL must not have one"
      )
  end
  if url:find("${", 1, true) then
    return nil,
      unsupported(
        url,
        'it contains "${", which genflake.lua writes into flake.nix with %q -- %q does not escape'
          .. ' "${", so it would land in the generated Nix source as a live string interpolation'
          .. " instead of literal text"
      )
  end

  local owner, rest, path = github_owner_repo(url)
  if owner then
    local repo = rest:gsub("%.git$", "")
    -- At most one more path segment, and a lone trailing "/" is kept rather than stripped: it is
    -- already part of a working lock today (§3.4 of the plan) and stripping it would change the
    -- source struct, discarding that lock's resolvedRef.
    if repo:match("^[^/]+/?$") then
      return { type = "github", owner = owner, repo = repo }
    end
    local msg = unsupported(
      url,
      ("a github.com URL must be exactly https://github.com/<owner>/<repo>, but its path is %q"):format(path)
    )
    if path:find("://", 1, true) then
      -- A full URL pasted into the short spec form (`{ "https://host/o/r" }`) gets run through
      -- lazy's git.url_format and lands here mangled (docs/plans/28-validate-plugin-sources.md
      -- §1.1) -- worth a pointer to the fix, since the fatal message alone does not explain why a
      -- github.com URL is the one that showed up.
      msg = msg
        .. '. A full URL written in the short spec form is expanded by lazy\'s git.url_format -- write it as url = "..." instead'
    end
    return nil, msg
  end

  local scheme, authority, schemePath = split_scheme(url)
  if scheme then
    local lower = scheme:lower()
    if lower ~= "https" and lower ~= "http" and lower ~= "ssh" and lower ~= "git" and lower ~= "file" then
      return nil,
        unsupported(
          url,
          ("scheme %q is not a git transport nvimx can pin. Use one of https, http, ssh, git, file"):format(scheme)
        )
    end
    if lower == "file" then
      local body = authority .. schemePath
      if body:sub(1, 1) ~= "/" then
        -- The real cause is a non-empty authority (`file://home/me/repo.git` has authority
        -- "home"), not a relative path: file:// needs three slashes -- an *empty* authority --
        -- before the absolute path even starts, so quote what nvimx actually saw there rather
        -- than mischaracterizing it as a bare relative path.
        return nil,
          unsupported(
            url,
            ("a file:// URL needs an empty authority, but %q comes right after file://"):format(authority)
              .. " -- write file:///... (three slashes) for an absolute path"
          )
      end
      -- Stored verbatim: file:// locks a machine-local absolute path, so this is inherently
      -- machine-dependent, but checks.resolve-semver depends on it being accepted (§1.4 of the
      -- plan) and nothing here can validate the path exists without touching the filesystem.
      return { type = "git", url = url }
    end
    if authority == "" then
      return nil, unsupported(url, "it has no host")
    end
    -- The part of the authority after the last "@" (or the whole authority, when there is no
    -- "@") is host[:port]. nix's flake-ref grammar requires anything after that ":" to be an
    -- all-digit port -- "ssh://git@github.com:o/r.git" (the classic mistake of mechanically
    -- prefixing an scp form with "ssh://") parses authority "git@github.com:o" here, and
    -- `builtins.parseFlakeRef "git+ssh://git@github.com:o/r.git"` fails with "is not an absolute
    -- path" because "o" is not a port. Reject it here instead of letting it through to fail
    -- opaquely at `nix flake lock` -- the whole point of #28.
    local hostpart = authority
    local at = authority:find("@[^@]*$")
    if at then
      hostpart = authority:sub(at + 1)
    end
    local port = hostpart:match(":([^:]*)$")
    if port and not port:match("^%d+$") then
      return nil,
        unsupported(
          url,
          ("its authority %q has a non-numeric port %q -- nix's flake ref grammar requires everything after the last %q in the authority to be all digits"):format(
            authority,
            port,
            ":"
          )
        )
    end
    -- Grammar-external characters: nix's flake-ref URL parser rejects these outright (verified
    -- against `builtins.parseFlakeRef`), so a URL carrying one already fails today, just later
    -- and less legibly (`is not an absolute path`, naming neither this plugin nor the character
    -- at fault). Reject it here, at the same point every other grammar violation in this branch
    -- is caught.
    local badchar = (authority .. schemePath):match('([%[%]{}<>%^`\\"|])')
    if badchar then
      return nil, unsupported(url, ("it contains %q, which is not valid in a nix flake ref URL"):format(badchar))
    end
    -- Empty, and a lone "/" (host, but nothing after it): both name a host with no repository
    -- path to clone. The one-byte-shorter empty-string form was already rejected before this
    -- fix; "https://git.example.com/" slipped through it because "/" ~= "".
    if schemePath == "" or schemePath == "/" then
      return nil, unsupported(url, "it names a host but no repository path")
    end
    return { type = "git", url = url }
  end

  local scp = parse_scp(url)
  if scp then
    return { type = "git", url = scp }
  end

  if url:match("^[/~.]") then
    return nil,
      unsupported(
        url,
        'it is a local path, not a git URL. Use dir = "..." with dev = true for a plugin you keep on disk, or file:///... for a local git remote'
      )
  end

  return nil,
    unsupported(
      url,
      "it has no scheme and is not the scp-style user@host:path form (user@host:/abs/path also"
        .. " lands here: only a home-relative path after the colon is normalized)"
    )
end

return M
