-- Unit test driver for lua/nvimx/source.lua, run via `nvim -l` by checks.source-parse.
-- Entirely offline and self-contained: no fixture files, no git, no network. arg[1] is the path
-- to source.lua, dofile()d here the same way resolve.lua does it.
--
-- This is the *only* place a rejection's exact wording is pinned (docs/plans/28-validate-plugin-
-- sources.md §5.4): checks.resolve-sources (the end-to-end check) deliberately checks the shape
-- of the failure output only -- line count, sort order, plugin name and URL present -- not its
-- text, so a reworded message is a one-file change instead of two.
--
-- source.parse never raises (it returns `nil, err`, the same convention
-- lua/nvimx/version.lua's select_tag uses, for the same reason: severity and reporting are the
-- caller's call, not this pure layer's), so no case here needs pcall -- success and failure are
-- both driven through the same two-return-value shape.
--
-- Failure is a plain Lua error from assert(): letting the script die non-zero is enough to fail
-- the pkgs.runCommand check that drives this file.

local src_path = arg[1]
assert(src_path, "usage: nvim -l source-parse-test.lua <source.lua>")

local src_mod = dofile(src_path)

local function eq(a, b, msg)
  assert(a == b, (msg or "not equal") .. (": got %s, want %s"):format(tostring(a), tostring(b)))
end

-- Accept matrix (docs/plans/28-validate-plugin-sources.md §3.2). url_out is the expected
-- source.url for a git-type result (nil for github-type, where owner/repo are checked instead).
local accept_cases = {
  { url = "https://github.com/o/short.nvim.git", type = "github", owner = "o", repo = "short.nvim" },
  { url = "https://github.com/o/nodotgit.nvim", type = "github", owner = "o", repo = "nodotgit.nvim" },
  -- §3.4 invariant: a trailing "/" on a github.com URL is a shape that already locks today, so it
  -- must not be normalized away -- doing so would flip the source struct and discard the pin.
  { url = "https://github.com/o/trailing.nvim/", type = "github", owner = "o", repo = "trailing.nvim/" },
  -- §3.4 invariant: the github regex must stay https-only. Widening it to also match http would
  -- reclassify a URL that is git-type today into github-type, discarding its resolvedRef.
  { url = "http://github.com/o/httpgh.nvim.git", type = "git", url_out = "http://github.com/o/httpgh.nvim.git" },
  -- §3.4 invariant: the github regex must stay host-case-sensitive, for the same reason.
  {
    url = "https://GitHub.com/o/upperhost.nvim",
    type = "git",
    url_out = "https://GitHub.com/o/upperhost.nvim",
  },
  {
    url = "https://github.example.com/o/ghe.nvim.git",
    type = "git",
    url_out = "https://github.example.com/o/ghe.nvim.git",
  },
  {
    url = "https://gitlab.com/g/sub/nested.nvim.git",
    type = "git",
    url_out = "https://gitlab.com/g/sub/nested.nvim.git",
  },
  {
    url = "https://git.sr.ht/~user/tildeuser.nvim",
    type = "git",
    url_out = "https://git.sr.ht/~user/tildeuser.nvim",
  },
  {
    url = "https://git.example.com/single.nvim.git",
    type = "git",
    url_out = "https://git.example.com/single.nvim.git",
  },
  { url = "http://git.example.com/o/http.nvim.git", type = "git", url_out = "http://git.example.com/o/http.nvim.git" },
  -- scp form: the one shape source.parse normalizes rather than passing through verbatim (§3.2 #11-13).
  {
    url = "git@git.example.com:o/scp.nvim.git",
    type = "git",
    url_out = "ssh://git@git.example.com/o/scp.nvim.git",
  },
  {
    url = "git@github.com:o/scpgh.nvim.git",
    type = "git",
    url_out = "ssh://git@github.com/o/scpgh.nvim.git",
  },
  {
    url = "forgejo@git.example.com:o/scpuser.nvim.git",
    type = "git",
    url_out = "ssh://forgejo@git.example.com/o/scpuser.nvim.git",
  },
  {
    url = "ssh://git@git.example.com/o/ssh.nvim.git",
    type = "git",
    url_out = "ssh://git@git.example.com/o/ssh.nvim.git",
  },
  {
    url = "ssh://git@git.example.com:2222/o/sshport.nvim.git",
    type = "git",
    url_out = "ssh://git@git.example.com:2222/o/sshport.nvim.git",
  },
  {
    url = "git://git.example.com/o/gitproto.nvim.git",
    type = "git",
    url_out = "git://git.example.com/o/gitproto.nvim.git",
  },
  {
    url = "file:///nvimx-nonexistent/file.nvim",
    type = "git",
    url_out = "file:///nvimx-nonexistent/file.nvim",
  },
}

for _, c in ipairs(accept_cases) do
  local src, err = src_mod.parse(c.url)
  assert(err == nil, ("parse(%q) unexpectedly failed: %s"):format(c.url, tostring(err)))
  eq(src.type, c.type, ("parse(%q).type"):format(c.url))
  if c.type == "github" then
    eq(src.owner, c.owner, ("parse(%q).owner"):format(c.url))
    eq(src.repo, c.repo, ("parse(%q).repo"):format(c.url))
    eq(src.url, nil, ("parse(%q).url"):format(c.url))
  else
    eq(src.url, c.url_out, ("parse(%q).url"):format(c.url))
    eq(src.owner, nil, ("parse(%q).owner"):format(c.url))
    eq(src.repo, nil, ("parse(%q).repo"):format(c.url))
  end
end

-- Reject matrix (docs/plans/28-validate-plugin-sources.md §3.3): one case per symbol, with the
-- exact wording fixed. Non-string inputs (A) can only be exercised here -- a JSON fixture cannot
-- produce a Lua non-string value other than by omitting the key entirely (nil).
local reject_cases = {
  -- A: not a string at all.
  {
    url = nil,
    err = "has no url. lazy derives one from the spec, so a raw spec without it is malformed",
  },
  { url = 42, err = "has no url. lazy derives one from the spec, so a raw spec without it is malformed" },
  { url = {}, err = "has no url. lazy derives one from the spec, so a raw spec without it is malformed" },
  -- B: empty string.
  {
    url = "",
    err = "has an empty url. lazy derives one from the spec, so a raw spec with an empty one is malformed",
  },
  -- C: whitespace.
  {
    url = "https://git.example.com/o/space nvim.git",
    err = 'unsupported source URL "https://git.example.com/o/space nvim.git": it contains whitespace',
  },
  -- D: query string / fragment (genflake.lua owns "?").
  {
    url = "https://git.example.com/o/query.nvim.git?ref=main",
    err = 'unsupported source URL "https://git.example.com/o/query.nvim.git?ref=main": it carries a query string or fragment. nvimx builds ?ref= and ?rev= itself from branch/tag/commit, so the source URL must not have one',
  },
  {
    url = "https://git.example.com/o/frag.nvim.git#main",
    err = 'unsupported source URL "https://git.example.com/o/frag.nvim.git#main": it carries a query string or fragment. nvimx builds ?ref= and ?rev= itself from branch/tag/commit, so the source URL must not have one',
  },
  -- D2: "${" (genflake.lua writes the URL into flake.nix with Lua's %q, which does not escape it,
  -- so it would become a live Nix string interpolation instead of literal text).
  {
    url = "https://git.example.com/o/antiquote.${var}.nvim.git",
    err = 'unsupported source URL "https://git.example.com/o/antiquote.${var}.nvim.git": it contains "${", which genflake.lua writes into flake.nix with %q -- %q does not escape "${", so it would land in the generated Nix source as a live string interpolation instead of literal text',
  },
  -- E: local path, not a git URL.
  {
    url = "/home/me/repos/barepath.nvim",
    err = 'unsupported source URL "/home/me/repos/barepath.nvim": it is a local path, not a git URL. Use dir = "..." with dev = true for a plugin you keep on disk, or file:///... for a local git remote',
  },
  {
    url = "~/repos/homepath.nvim",
    err = 'unsupported source URL "~/repos/homepath.nvim": it is a local path, not a git URL. Use dir = "..." with dev = true for a plugin you keep on disk, or file:///... for a local git remote',
  },
  -- F: unknown scheme.
  {
    url = "ftp://git.example.com/o/ftp.nvim.git",
    err = 'unsupported source URL "ftp://git.example.com/o/ftp.nvim.git": scheme "ftp" is not a git transport nvimx can pin. Use one of https, http, ssh, git, file',
  },
  -- G: file:// with a relative path. The message names the actual cause (a non-empty authority)
  -- rather than mischaracterizing it as a relative path -- file:// needs an *empty* authority
  -- (three slashes) before the absolute path even starts.
  {
    url = "file://relative/relfile.nvim",
    err = 'unsupported source URL "file://relative/relfile.nvim": a file:// URL needs an empty authority, but "relative" comes right after file:// -- write file:///... (three slashes) for an absolute path',
  },
  -- H: no host.
  {
    url = "https:///o/nohost.nvim.git",
    err = 'unsupported source URL "https:///o/nohost.nvim.git": it has no host',
  },
  -- I: host but no path.
  {
    url = "https://git.example.com",
    err = 'unsupported source URL "https://git.example.com": it names a host but no repository path',
  },
  -- I: host but no path, the one-byte-longer form -- a lone trailing "/" is still "no path",
  -- not a one-segment path. Slipped through before this fix (schemePath == "" was the only check).
  {
    url = "https://git.example.com/",
    err = 'unsupported source URL "https://git.example.com/": it names a host but no repository path',
  },
  -- L: authority names a non-numeric port. The classic mistake of mechanically prefixing an scp
  -- form with "ssh://": `builtins.parseFlakeRef "git+ssh://git@github.com:o/r.git"` fails with
  -- "is not an absolute path" because "o" is not a port -- reject it here instead.
  {
    url = "ssh://git@github.com:o/r.git",
    err = 'unsupported source URL "ssh://git@github.com:o/r.git": its authority "git@github.com:o" has a non-numeric port "o" -- nix\'s flake ref grammar requires everything after the last ":" in the authority to be all digits',
  },
  -- M: a character nix's flake-ref URL parser rejects outright (verified against
  -- builtins.parseFlakeRef).
  {
    url = "https://h|x/o/r.git",
    err = 'unsupported source URL "https://h|x/o/r.git": it contains "|", which is not valid in a nix flake ref URL',
  },
  -- J: github.com URL whose path is not exactly <owner>/<repo> (a browser URL with a ref suffix).
  {
    url = "https://github.com/o/browser.nvim/tree/main",
    err = 'unsupported source URL "https://github.com/o/browser.nvim/tree/main": a github.com URL must be exactly https://github.com/<owner>/<repo>, but its path is "o/browser.nvim/tree/main"',
  },
  -- J': same, but the extra path segment is itself a full URL -- lazy's short-spec-form expansion.
  {
    url = "https://github.com/ssh://git@example.com/o/shortform.nvim.git",
    err = 'unsupported source URL "https://github.com/ssh://git@example.com/o/shortform.nvim.git": a github.com URL must be exactly https://github.com/<owner>/<repo>, but its path is "ssh://git@example.com/o/shortform.nvim.git". A full URL written in the short spec form is expanded by lazy\'s git.url_format -- write it as url = "..." instead',
  },
  -- K: no scheme, not scp-style either.
  {
    url = "just-a-name",
    err = 'unsupported source URL "just-a-name": it has no scheme and is not the scp-style user@host:path form (user@host:/abs/path also lands here: only a home-relative path after the colon is normalized)',
  },
  -- K: scp-style syntax, but the path after the colon is absolute rather than home-relative --
  -- git itself accepts this form, but source.lua only normalizes the home-relative one (§3.2
  -- step 5), so this falls all the way to K rather than being treated as scp-style.
  {
    url = "git@host:/abs/path",
    err = 'unsupported source URL "git@host:/abs/path": it has no scheme and is not the scp-style user@host:path form (user@host:/abs/path also lands here: only a home-relative path after the colon is normalized)',
  },
  -- K: any colon-bearing scheme-less string used to be silently rewritten to ssh:// here, because
  -- the scp pattern's "user@" was optional. "user@" is now mandatory (§3.2 step 5), so a userless
  -- colon form falls all the way to K like any other unrecognized shape.
  {
    url = "gitea.internal:8080",
    err = 'unsupported source URL "gitea.internal:8080": it has no scheme and is not the scp-style user@host:path form (user@host:/abs/path also lands here: only a home-relative path after the colon is normalized)',
  },
}

for _, c in ipairs(reject_cases) do
  local src, err = src_mod.parse(c.url)
  assert(src == nil, ("parse(%s) should have been rejected"):format(tostring(c.url)))
  eq(err, c.err, ("parse(%s) message"):format(tostring(c.url)))
end

print("source-parse-test: all assertions passed")
