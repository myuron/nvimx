-- Pure helpers for resolving a lazy.nvim-style `version` constraint against a remote's tag list.
--
-- This layer never touches the network or the filesystem: parse_ls_remote only turns already
-- fetched `git ls-remote` output into tag names, and select_tag only picks the winning one out of
-- an already fetched tag list. Both are therefore easy to drive from a unit test with fixed
-- input (checks.semver-select), independent of the network and of resolve.lua's own I/O.
--
-- lazy.nvim's own `lua/lazy/manage/semver.lua` (M.version / M.range / M.last) is the ground truth
-- for matching -- this file does not reimplement it, and does not dofile() it either: the caller
-- passes it in (resolve.lua dofile()s it from the seed given via --lazy; tests/semver-select-test.lua
-- dofile()s it directly from the same seed). Keeping the load out of this file is what lets it stay
-- pure and lets a test drive it with the exact module lazy itself ships.

local M = {}

-- `SHA\trefs/tags/NAME` lines, as produced by `git ls-remote --tags --refs <url>`, into tag names.
-- `--refs` already drops the peeled `^{}` lines for annotated tags, but a leftover one (or a
-- differently invoked ls-remote) is skipped defensively rather than trusted to not occur.
-- Sorted ascending so that select_tag's tie-break among equal-value tags (e.g. "1.2.3" and
-- "v1.2.3") does not depend on the order git happened to list them in.
---@param stdout string raw stdout of `git ls-remote --tags --refs <url>`
---@return string[] tag names, ascending
function M.parse_ls_remote(stdout)
  local tags = {}
  for line in (stdout or ""):gmatch("[^\n]+") do
    local ref = line:match("^%x+%s+(.+)$")
    if ref and ref:sub(1, 10) == "refs/tags/" and ref:sub(-3) ~= "^{}" then
      tags[#tags + 1] = ref:sub(11)
    end
  end
  table.sort(tags)
  return tags
end

-- Picks the tag that wins a lazy.nvim version constraint out of a tag list.
--
-- Failure is reported as `nil, detail` rather than raised, because the three ways this can fail
-- (bad constraint syntax, no tags at all, no matching tag) carry different severity in resolve.lua
-- depending on where the constraint came from (§3.4 of the plan) -- that decision belongs to the
-- caller, not here.
---@param Semver table lua/lazy/manage/semver.lua's module table (M.version / M.range / M.last)
---@param tags string[] tag names (order does not matter -- this function sorts its own copy)
---@param constraint string a lazy `version` string, e.g. "^1.2", "*", "1.2.3"
---@return string? tag the winning tag's original name (verbatim, not renormalized), or nil on failure
---@return table? detail present iff the first return is nil:
---  { kind = "no-range" } -- constraint is not valid lazy.nvim semver syntax
---  { kind = "no-tags" } -- the remote has no tags at all
---  { kind = "no-match", parsed, newest } -- tags exist but none satisfy the range;
---    `parsed` is how many of them parsed as semver at all, `newest` is up to the 10 highest of
---    those (by semver order, descending), given as their original tag names
function M.select_tag(Semver, tags, constraint)
  local range = Semver.range(constraint)
  if not range then
    return nil, { kind = "no-range" }
  end
  if #tags == 0 then
    return nil, { kind = "no-tags" }
  end

  local sorted = {}
  for _, t in ipairs(tags) do
    sorted[#sorted + 1] = t
  end
  table.sort(sorted)

  local parsed = {}
  for _, t in ipairs(sorted) do
    local v = Semver.version(t)
    if v then
      parsed[#parsed + 1] = v
    end
  end

  local matched = {}
  for _, v in ipairs(parsed) do
    if range:matches(v) then
      matched[#matched + 1] = v
    end
  end

  if #matched > 0 then
    local winner = Semver.last(matched)
    return winner.input, nil
  end

  table.sort(parsed, function(a, b)
    return a > b
  end)
  local newest = {}
  for i = 1, math.min(10, #parsed) do
    newest[#newest + 1] = parsed[i].input
  end
  return nil, { kind = "no-match", parsed = #parsed, newest = newest }
end

return M
