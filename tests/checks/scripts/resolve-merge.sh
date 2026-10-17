# shellcheck shell=bash disable=SC2154
# Body of checks.resolve-merge, sourced by the runCommand in ../resolve-merge.nix.
# $lua $fx $lazy $mergeConfig $extractLua come from that derivation's env.
export HOME=$TMPDIR
# the whole directory, not the single file: resolve.lua dofile()s json.lua next to it
# None of the resolves below end up with anything pending (telescope.nvim, the
# only plugin here with a `version`, does not have one anymore -- see its
# raw-spec's _comment), so --lazy is never actually consulted. It is passed on
# every call anyway so that this file stays correct if that ever changes.

# The first resolve of a lock run cannot freeze anything: there is no previous
# plugins.json to tell whether the flake.lock next to it still describes this spec.
nvim -l "$lua"/resolve.lua "$fx"/raw-spec-base.json pass1.json --lock "$fx"/flake.lock \
  --lazy "$lazy" 2>pass1.log
jq -e '.plugins["tokyonight.nvim"].resolvedRef == null' pass1.json >/dev/null
jq -e '.plugins["custom.nvim"].resolvedRef == null' pass1.json >/dev/null

# The second one -- the pass nvimx-lock runs once `nix flake lock` has caught up --
# is what freezes them, and is the steady state. golden/base.plugins.json is that
# state written out for review: pin / dependencies plus both frozen revs.
nvim -l "$lua"/resolve.lua "$fx"/raw-spec-base.json out1.json \
  --prev pass1.json --lock "$fx"/flake.lock --lazy "$lazy" 2>out1.log
diff -u "$fx"/golden/base.plugins.json out1.json

# "Running lock twice with no config change produces a byte-identical plugins.json":
# the steady state has to be a fixed point, or the convergence pass would never end.
nvim -l "$lua"/resolve.lua "$fx"/raw-spec-base.json out2.json \
  --prev out1.json --lock "$fx"/flake.lock --lazy "$lazy" 2>out2.log
cmp out1.json out2.json
# warnings are derived every run and never merged, so they repeat verbatim
diff -u out1.log out2.log

# "A pinned plugin keeps its ref after an unrelated plugin is added."
nvim -l "$lua"/resolve.lua "$fx"/raw-spec-added.json out3.json \
  --prev out1.json --lock "$fx"/flake.lock --lazy "$lazy" 2>/dev/null
for pinned in tokyonight.nvim custom.nvim; do
  diff -u \
    <(jq -S --arg n "$pinned" '.plugins[$n]' out1.json) \
    <(jq -S --arg n "$pinned" '.plugins[$n]' out3.json)
done
# a plugin with no previous decision starts out unresolved
jq -e '.plugins["nvim-cmp"].resolvedRef == null' out3.json >/dev/null
# ...and the newcomer is itself pinned, with no node in flake.lock -- the state
# every pin is in on its first lock. Even on the pass that would freeze it (it is
# in --prev now, and its spec has not moved) there is no rev to freeze onto, so
# the freeze must quietly leave it null instead of failing or inventing one.
nvim -l "$lua"/resolve.lua "$fx"/raw-spec-added.json out3b.json \
  --prev out3.json --lock "$fx"/flake.lock --lazy "$lazy" 2>/dev/null
jq -e '.plugins["nvim-cmp"].pin == true' out3b.json >/dev/null
jq -e '.plugins["nvim-cmp"].resolvedRef == null' out3b.json >/dev/null

# "Removing a plugin from the config removes it from plugins.json and the
# generated flake." Nothing else may move: back to base is back to out1 byte for byte.
nvim -l "$lua"/resolve.lua "$fx"/raw-spec-base.json out4.json \
  --prev out3.json --lock "$fx"/flake.lock --lazy "$lazy" 2>/dev/null
cmp out1.json out4.json
nvim -l "$lua"/genflake.lua out3.json flake-added.nix
nvim -l "$lua"/genflake.lua out4.json flake-base.nix
grep -q 'nvim-cmp = {' flake-added.nix
if grep -q 'nvim-cmp' flake-base.nix; then
  echo "the removed plugin is still an input of the generated flake" >&2
  exit 1
fi
# and the frozen rev must actually reach the URL, for both source types --
# otherwise a bare `nix flake update` in lockDir would walk a pin forward.
# custom.nvim's URL is host + a single path segment (no owner/repo split), which is
# exactly the shape #28's source.lua must keep passing through as git-type rather
# than rejecting or folding into github-type -- this grep is also that regression
# guard, since a normalization change here would show up as a different URL.
grep -q 'url = "github:folke/tokyonight.nvim/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";' flake-base.nix
grep -q 'url = "git+https://git.example.com/custom.nvim.git?ref=trunk&rev=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";' flake-base.nix

# Editing the spec beats the pin: the user asked for another branch, so the frozen
# rev is dropped. Editing metadata that cannot influence a ref (dependencies) does
# not, or every such edit would silently unpin a plugin.
nvim -l "$lua"/resolve.lua "$fx"/raw-spec-branch-changed.json out5.json \
  --prev out1.json --lock "$fx"/flake.lock --lazy "$lazy" 2>/dev/null
jq -e '.plugins["tokyonight.nvim"].resolvedRef == null' out5.json >/dev/null
jq -e '.plugins["tokyonight.nvim"].branch == "master"' out5.json >/dev/null
jq -e '.plugins["custom.nvim"].resolvedRef
       == "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"' out5.json >/dev/null
jq -e '.plugins["custom.nvim"].dependencies == ["plenary.nvim"]' out5.json >/dev/null
jq -e '.plugins["telescope.nvim"].dependencies == ["plenary.nvim"]' out5.json >/dev/null

# Taking `pin` away must thaw the plugin. Nothing else in the spec changes here
# (jq deletes exactly the one key), so without this the frozen rev would ride
# along on the unchanged-identity path forever -- and since the rev is part of the
# input URL, not even `nix flake update` could break it out again.
jq 'del(.plugins["tokyonight.nvim"].pin)' "$fx"/raw-spec-base.json >raw-spec-unpinned.json
nvim -l "$lua"/resolve.lua raw-spec-unpinned.json out8.json \
  --prev out1.json --lock "$fx"/flake.lock --lazy "$lazy" 2>/dev/null
jq -e '.plugins["tokyonight.nvim"].pin == null' out8.json >/dev/null
jq -e '.plugins["tokyonight.nvim"].resolvedRef == null' out8.json >/dev/null
# only the unpinned one thaws; the plugin that is still pinned keeps its rev
jq -e '.plugins["custom.nvim"].resolvedRef
       == "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"' out8.json >/dev/null

# `pin` + `version` is a trap: the pin freezes whatever rev the lock holds and
# nothing ever checks it against the range, so it has to say so -- and say it on
# both passes, because nvimx-lock keeps only the second one's log. Both passes are
# given a prev that already carries the constraint with resolvedRef null (the
# state a lock made just before #23 landed would be in), so the freeze wins over
# the constraint on both passes, and no ls-remote is attempted on either one --
# the pin+version interaction with an actual first-ever resolve (no prev at all)
# is checks.resolve-semver step 13(b)'s job, since that one does need a real (if
# local) remote to prove ls-remote really is skipped.
jq '.plugins["tokyonight.nvim"].version = "^1.0"' "$fx"/raw-spec-base.json >raw-spec-pinned-version.json
jq '.plugins["tokyonight.nvim"].version = "^1.0" | .plugins["tokyonight.nvim"].resolvedRef = null' \
  "$fx"/golden/base.plugins.json >prev-pinned-version.json
nvim -l "$lua"/resolve.lua raw-spec-pinned-version.json out9a.json \
  --prev prev-pinned-version.json --lock "$fx"/flake.lock --lazy "$lazy" 2>out9a.log
nvim -l "$lua"/resolve.lua raw-spec-pinned-version.json out9b.json \
  --prev out9a.json --lock "$fx"/flake.lock --lazy "$lazy" 2>out9b.log
# the freeze wins over the constraint on both passes
jq -e '.plugins["tokyonight.nvim"].resolvedRef
       == "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"' out9a.json >/dev/null
jq -e '.plugins["tokyonight.nvim"].resolvedRef
       == "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"' out9b.json >/dev/null
# ...and it did not silence the constraint on the way through, on either stream
for f in out9a out9b; do
  grep -q '^\[nvimx\] warning: plugin "tokyonight.nvim": pinned; version constraint "\^1.0" is not validated (pin wins)$' $f.log
  jq -e '.warnings | any(. == "plugin \"tokyonight.nvim\": pinned; version constraint \"^1.0\" is not validated (pin wins)")' $f.json >/dev/null
done
# both passes say exactly the same thing, which is what makes overwriting the
# first pass's log in nvimx-lock safe
diff -u out9a.log out9b.log

# A plugins.json written before these fields existed must still be readable, and
# the decision it records must win over the rev in flake.lock (a resolvedRef that
# is already set is never recomputed -- that is the whole point of the merge).
nvim -l "$lua"/resolve.lua "$fx"/raw-spec-base.json out6.json \
  --prev "$fx"/prev-v1.json --lock "$fx"/flake.lock --lazy "$lazy" 2>/dev/null
jq -e '.plugins["tokyonight.nvim"].resolvedRef
       == "1111111111111111111111111111111111111111"' out6.json >/dev/null
jq -e '.plugins["tokyonight.nvim"].pin == true' out6.json >/dev/null
jq -e '.plugins["tokyonight.nvim"].dependencies == []' out6.json >/dev/null
# not in the old prev at all, so there is nothing to trust yet
jq -e '.plugins["custom.nvim"].resolvedRef == null' out6.json >/dev/null

# A carried resolvedRef -- whatever put it there -- must not be re-decided or
# warned about while the spec identity is unchanged. This is deliberately not
# version-specific (telescope.nvim has no `version` in this fixture): the point is
# that the merge carries *any* resolvedRef unconditionally. The semver-specific
# version of this (a version constraint whose already-resolved tag ref survives a
# lock with no config change, proven against a real remote so ls-remote's absence
# is actually checked) is checks.resolve-semver step 5.
jq '.plugins["telescope.nvim"].resolvedRef = "refs/tags/0.1.8"' out1.json >resolved-prev.json
nvim -l "$lua"/resolve.lua "$fx"/raw-spec-base.json out7.json \
  --prev resolved-prev.json --lock "$fx"/flake.lock --lazy "$lazy" 2>resolved.log
jq -e '.plugins["telescope.nvim"].resolvedRef == "refs/tags/0.1.8"' out7.json >/dev/null
jq -e '.warnings == []' out7.json >/dev/null
if [ -s resolved.log ]; then
  echo "a carried resolvedRef must not warn, got:" >&2
  cat resolved.log >&2
  exit 1
fi

# A prev nvimx cannot read must stop the run. Regenerating from scratch instead
# would quietly throw away every pinned rev in it, so say what to do and fail.
for bad in prev-broken prev-future; do
  rc=0
  nvim -l "$lua"/resolve.lua "$fx"/raw-spec-base.json bad.json --prev "$fx"/$bad.json \
    --lazy "$lazy" 2>$bad.log || rc=$?
  cat $bad.log >&2
  if [ "$rc" -eq 0 ]; then
    echo "resolve.lua silently accepted $bad.json" >&2
    exit 1
  fi
  grep -q 'run nvimx-lock again' $bad.log
done
grep -q 'is not valid JSON' prev-broken.log
grep -q 'schemaVersion 2' prev-future.log

# Everything above starts from a hand-written raw-spec, so one case goes through
# the real extractor to prove pin / dependencies / version survive lazy's
# normalization too.
sb=$TMPDIR/sandbox
mkdir -p "$sb"/config "$sb"/data/nvim/lazy "$sb"/state "$sb"/cache
ln -s "$mergeConfig" "$sb"/config/nvim
ln -s "$lazy" "$sb"/data/nvim/lazy/lazy.nvim
env \
  XDG_CONFIG_HOME="$sb"/config \
  XDG_DATA_HOME="$sb"/data \
  XDG_STATE_HOME="$sb"/state \
  XDG_CACHE_HOME="$sb"/cache \
  NVIMX_LAZY_SEED="$lazy" \
  NVIMX_OUT="$sb"/raw-spec.json \
  nvim --headless --cmd "luafile $extractLua"
# guards against dump_plugin in extract.lua reintroducing `optional`: a plugins.json
# regression alone would not catch this, since resolve.lua's entry construction does
# not propagate unlisted raw-spec keys.
# This is vacuous unless merge-config keeps a plugin whose `optional` folds to false
# rather than nil -- lazy's own encoder drops nil keys, so a spec without the
# plenary optional fragment would leave nothing for this to find.
jq -e 'all(.plugins[]; has("optional") | not)' "$sb"/raw-spec.json >/dev/null
# extract's own contract: version survives lazy's normalization intact
jq -e '.plugins["telescope.nvim"].version == "^0.1"' "$sb"/raw-spec.json >/dev/null
# Resolving that constraint needs a real remote (checks.resolve-semver step 14
# already covers it end to end, offline, against a local repo); this check is
# about pin / dependencies / optional surviving extract -> resolve, not semver, so
# the constraint is dropped before resolving to keep this check network-free.
jq 'del(.plugins["telescope.nvim"].version)' "$sb"/raw-spec.json >"$sb"/raw-spec-no-version.json
nvim -l "$lua"/resolve.lua "$sb"/raw-spec-no-version.json extracted.json --lazy "$lazy" 2>/dev/null
jq -e '.plugins["tokyonight.nvim"].pin == true' extracted.json >/dev/null
jq -e '.plugins["telescope.nvim"].dependencies == ["plenary.nvim"]' extracted.json >/dev/null
# ...and stay absent when the spec does not set them. `optional` is not among
# them: it is not a field that stays absent, it never exists in the schema at all.
jq -e '.plugins["plenary.nvim"].pin == null' extracted.json >/dev/null
jq -e '.plugins["plenary.nvim"].dependencies == []' extracted.json >/dev/null
# guards against resolve.lua's entry construction reintroducing `optional`
jq -e 'all(.plugins[]; has("optional") | not)' extracted.json >/dev/null
# optional-only: lazy's Meta:fix_optional drops it, so nvimx must not lock it either
jq -e '.plugins | has("which-key.nvim") | not' extracted.json >/dev/null
# an optional fragment mixed with a non-optional one still gets locked
jq -e '.plugins | has("plenary.nvim")' extracted.json >/dev/null
touch "$out"
