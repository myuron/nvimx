# shellcheck shell=bash disable=SC2154
# Body of checks.resolve-sources, sourced by the runCommand in ../resolve-sources.nix.
# $lua $fx $lazy come from that derivation's env.
export HOME=$TMPDIR

# (1) accept matrix: normalization, then the flake it produces.
nvim -l "$lua"/resolve.lua "$fx"/raw-spec-ok.json ok.json --lazy "$lazy" 2>ok.log
diff -u "$fx"/golden/ok.plugins.json ok.json
nvim -l "$lua"/genflake.lua ok.json ok-flake.nix
diff -u "$fx"/golden/ok.flake.nix ok-flake.nix
# a matrix of valid URLs has nothing to say
if [ -s ok.log ]; then
  echo "a valid source URL must not warn, got:" >&2
  cat ok.log >&2
  exit 1
fi
# the two transports github.com can be reached over must not collapse into one:
# https becomes a github: input, ssh stays a git one so the user's keys still apply
jq -e '.plugins["short.nvim"].source.type == "github"' ok.json >/dev/null
jq -e '.plugins["scpgh.nvim"].source
       == { type: "git", url: "ssh://git@github.com/o/scpgh.nvim.git" }' ok.json >/dev/null
# #28 validates, it does not reclassify. A URL that already locks today keeps the
# exact source struct it has now, or everyone using that form silently loses their
# resolvedRef to a spec-identity change. None of these three appears in any other
# fixture, so nothing else in the tree would catch it (checks.source-parse carries
# the same three as unit cases; this is the end-to-end half).
jq -e '.plugins["httpgh.nvim"].source.type == "git"' ok.json >/dev/null
jq -e '.plugins["upperhost.nvim"].source.type == "git"' ok.json >/dev/null
jq -e '.plugins["trailing.nvim"].source.repo == "trailing.nvim/"' ok.json >/dev/null

# (2) reject matrix. One run reports every bad URL at once (fail_plugin +
# report_resolve_errors), so the whole matrix comes out of a single invocation.
# Only the *shape* of the output is pinned here; the wording lives in
# checks.source-parse, so a reworded message is a one-file change.
rc=0
nvim -l "$lua"/resolve.lua "$fx"/raw-spec-bad.json bad.json --lazy "$lazy" 2>bad.log || rc=$?
cat bad.log >&2
if [ "$rc" -eq 0 ]; then
  echo "resolve.lua accepted a source URL it cannot turn into a flake input" >&2
  exit 1
fi
# a failed resolve must not leave a partial plugins.json behind
if [ -e bad.json ]; then
  echo "resolve.lua wrote plugins.json for a failed run" >&2
  exit 1
fi
# one line per bad plugin, so adding a case to raw-spec-bad.json without teaching
# source.lua to reject it cannot pass by accident. Derived once into `total` (and
# `with_url`, its two deliberate exceptions subtracted) and reused below, rather
# than repeating `jq '.plugins | length'` and hardcoding what it comes out to --
# adding a case to raw-spec-bad.json without this would otherwise fail two of the
# three counts below with an opaque mismatch instead of one clear one.
total="$(jq '.plugins | length' "$fx"/raw-spec-bad.json)"
grep '^\[nvimx\] resolve failed: plugin ' bad.log >failed.log
[ "$(wc -l <failed.log)" -eq "$total" ]
# report_resolve_errors sorts by plugin name, and that ordering is the only reason
# this output is reproducible at all -- the main loop walks the spec with pairs()
LC_ALL=C sort -c failed.log
# every line names its plugin *and* the offending URL: the point of the whole issue.
# nourl/emptyurl are the two deliberate exceptions (§3.3) -- there is no URL to
# quote when the spec has none -- so they are excluded by name rather than by
# weakening the rule for the rest.
grep -v -e '"nourl\.nvim"' -e '"emptyurl\.nvim"' failed.log >withurl.log
with_url=$((total - 2))
[ "$(wc -l <withurl.log)" -eq "$with_url" ]
[ "$(grep -c 'unsupported source URL "[^"]' withurl.log)" -eq "$with_url" ]
touch "$out"
