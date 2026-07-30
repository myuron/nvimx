-- Unit test driver for lua/nvimx/version.lua, run via `nvim -l` by checks.semver-select.
-- Entirely offline and self-contained: no fixture files, no git, no network. arg[1] is the path
-- to version.lua, arg[2] is the path to the seed's lua/lazy/manage/semver.lua -- both dofile()d
-- here exactly the way resolve.lua does it, so the test exercises the real module lazy ships.
--
-- Failure is a plain Lua error from assert(): letting the script die non-zero is enough to fail
-- the pkgs.runCommand check that drives this file.

local ver_path, semver_path = arg[1], arg[2]
assert(ver_path and semver_path, "usage: nvim -l semver-select-test.lua <version.lua> <lazy semver.lua>")

local ver = dofile(ver_path)
local Semver = dofile(semver_path)

local function eq(a, b, msg)
  assert(a == b, (msg or "not equal") .. (": got %s, want %s"):format(tostring(a), tostring(b)))
end

-- select_tag: success cases, all against the same tag set.
local tags = { "stable", "v1.0.0", "v1.2.0", "v1.2.5", "v2.0.0", "v2.1.0-beta" }

local cases = {
  { "*", "v2.0.0" }, -- non-prerelease constraint never picks the prerelease tag
  { "^1.2", "v1.2.5" },
  { "~1.2", "v1.2.5" },
  { ">=1.2.0", "v2.0.0" },
  { "=1.2.0", "v1.2.0" },
  { "1.2.0", "v1.2.0" },
  -- a constraint that itself names a prerelease matches only that same prerelease (§1.2 of the plan)
  { "2.1.0-beta", "v2.1.0-beta" },
}
for _, c in ipairs(cases) do
  local constraint, want = c[1], c[2]
  local tag, detail = ver.select_tag(Semver, tags, constraint)
  eq(tag, want, ("select_tag(%q)"):format(constraint))
  assert(detail == nil, ("select_tag(%q) unexpectedly returned a detail"):format(constraint))
end

-- select_tag: failure cases and their `kind`.
do
  local tag, detail = ver.select_tag(Semver, tags, "^9")
  assert(tag == nil, "select_tag(^9) should not match")
  eq(detail.kind, "no-match", "select_tag(^9) kind")
  eq(detail.parsed, 5, "select_tag(^9) parsed count") -- "stable" does not parse as semver
  eq(#detail.newest, 5, "select_tag(^9) newest count")
  -- newest is semver-descending: 2.1.0-beta's (major, minor, patch) outranks 2.0.0's, even though
  -- it carries a prerelease tag -- this module's ordering is on (major, minor, patch) first.
  local want_newest = { "v2.1.0-beta", "v2.0.0", "v1.2.5", "v1.2.0", "v1.0.0" }
  for i, w in ipairs(want_newest) do
    eq(detail.newest[i], w, ("select_tag(^9) newest[%d]"):format(i))
  end
end

do
  local tag, detail = ver.select_tag(Semver, {}, "*")
  assert(tag == nil, "select_tag with no tags should not match")
  eq(detail.kind, "no-tags", "select_tag with no tags kind")
end

for _, bad in ipairs({ "<1.0", "foo" }) do
  local tag, detail = ver.select_tag(Semver, tags, bad)
  assert(tag == nil, ("select_tag(%q) should not match"):format(bad))
  eq(detail.kind, "no-range", ("select_tag(%q) kind"):format(bad))
end

-- Tie-break stability: "1.2.3" and "v1.2.3" are the same version (build metadata aside, and
-- neither has any); select_tag must return the same one regardless of the order they are given
-- in, because it sorts its own copy of the tag list before resolving ties (§3.3 of the plan).
for _, order in ipairs({
  { "1.2.3", "v1.2.3" },
  { "v1.2.3", "1.2.3" },
}) do
  local tag = ver.select_tag(Semver, order, "*")
  eq(tag, "1.2.3", "tie-break must be independent of input order")
end

-- parse_ls_remote
do
  local out = ver.parse_ls_remote(
    "aaaa1111111111111111111111111111111111\trefs/tags/v1.0.0\n"
      .. "bbbb2222222222222222222222222222222222\trefs/tags/v2.0.0\n"
  )
  eq(#out, 2, "parse_ls_remote normal line count")
  eq(out[1], "v1.0.0", "parse_ls_remote[1]")
  eq(out[2], "v2.0.0", "parse_ls_remote[2]")
end

do
  -- A peeled annotated-tag line (only ever produced without --refs, but skipped defensively
  -- regardless) must not turn into a fake tag named "v1.0.0^{}".
  local out = ver.parse_ls_remote(
    "aaaa1111111111111111111111111111111111\trefs/tags/v1.0.0\n"
      .. "cccc3333333333333333333333333333333333\trefs/tags/v1.0.0^{}\n"
  )
  eq(#out, 1, "parse_ls_remote peeled-line count")
  eq(out[1], "v1.0.0", "parse_ls_remote peeled-line survivor")
end

eq(#ver.parse_ls_remote(""), 0, "parse_ls_remote empty output")

do
  -- No trailing newline: gmatch("[^\n]+") must still see the last line.
  local out = ver.parse_ls_remote("aaaa1111111111111111111111111111111111\trefs/tags/v1.0.0")
  eq(#out, 1, "parse_ls_remote no trailing newline")
  eq(out[1], "v1.0.0", "parse_ls_remote no trailing newline value")
end

do
  -- git's own output order does not matter: parse_ls_remote always returns it sorted.
  local out = ver.parse_ls_remote(
    "aaaa1111111111111111111111111111111111\trefs/tags/v2.0.0\n"
      .. "bbbb2222222222222222222222222222222222\trefs/tags/v1.0.0\n"
  )
  eq(out[1], "v1.0.0", "parse_ls_remote sorts regardless of git's order [1]")
  eq(out[2], "v2.0.0", "parse_ls_remote sorts regardless of git's order [2]")
end

print("semver-select-test: all assertions passed")
