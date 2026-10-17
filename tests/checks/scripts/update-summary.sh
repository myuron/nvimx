# shellcheck shell=bash disable=SC2154
# Body of checks.update-summary, sourced by the runCommand in ../update-summary.nix.
# $lua $fx $lsfx come from that derivation's env.
export HOME=$TMPDIR
# #49's spec-derived-lazyNvim cases reuse fx's flake.lock.summary-{before,after}.json
# pair (the lazy-nvim node move they already carry, 9c9c...->3f3f...) with their own
# plugins.json halves here -- the same cross-fixture reuse checks.resolve-update
# already does with tests/fixtures/merge/.

# Named mode: tokyonight.nvim and lazy.nvim were asked for; plenary.nvim moved
# without being named and without an explanation on offer, so it is both listed
# and counted in the warning. telescope.nvim's version constraint resolving for the
# first time, and old.nvim/new.nvim being removed/added, are never warned about.
nvim -l "$lua"/update-summary.lua \
  "$fx"/plugins.json.before "$fx"/plugins.json.after \
  "$fx"/flake.lock.summary-before.json "$fx"/flake.lock.summary-after.json \
  tokyonight.nvim lazy.nvim 2>summary-named.txt
diff -u "$fx"/golden/summary-named.txt summary-named.txt

# Full-update mode: every plugin is listed, including the ones that did not move
# (nui.nvim's pinned-skip, vim-fugitive's commit-pinned) -- there is no
# "unrequested" concept here, so no warning line is ever printed. tokyonight.nvim
# is also `pin = true`, but its rev genuinely differs between the two snapshots, so
# it is reported as `updated` rather than swallowed as a skip -- the fixture doubles
# as coverage for classify()'s pin/commit branches being gated on rb == ra (the
# dedicated regression cases below test the same gate in named mode, where a
# swallowed move would otherwise be silent rather than just misclassified).
nvim -l "$lua"/update-summary.lua \
  "$fx"/plugins.json.before "$fx"/plugins.json.after \
  "$fx"/flake.lock.summary-before.json "$fx"/flake.lock.summary-after.json \
  2>summary-all.txt
diff -u "$fx"/golden/summary-all.txt summary-all.txt
if grep -q '^nvimx-lock: warning:' summary-all.txt; then
  echo "a full update must never print the unnamed-input warning" >&2
  exit 1
fi

# Nothing moved (the same snapshot fed in as both before and after): a single line
# rather than an empty or misleading "0 updated" summary.
nvim -l "$lua"/update-summary.lua \
  "$fx"/plugins.json.before "$fx"/plugins.json.before \
  "$fx"/flake.lock.summary-before.json "$fx"/flake.lock.summary-before.json \
  tokyonight.nvim 2>summary-none.txt
diff -u "$fx"/golden/summary-none.txt summary-none.txt

# A full update where every unpinned plugin was already at rest must still report
# its pinned-skips (§3.4 of the plan says so explicitly: "must always" be shown) --
# the "no plugins updated" shortcut above must not swallow that just because
# nothing counted as updated/added/removed.
nvim -l "$lua"/update-summary.lua \
  "$fx"/plugins.json.before "$fx"/plugins.json.before \
  "$fx"/flake.lock.summary-before.json "$fx"/flake.lock.summary-before.json \
  2>summary-all-at-rest.txt
grep -q 'pinned: tokyonight.nvim' summary-all-at-rest.txt
grep -q 'pinned: nui.nvim' summary-all-at-rest.txt
if grep -q '^nvimx-lock: no plugins updated' summary-all-at-rest.txt; then
  echo "a pinned-skip must not be swallowed by the 'no plugins updated' shortcut" >&2
  exit 1
fi

# The ref-pairing rule is limited to tag-ref-vs-tag-ref (§3.4 of the plan): a pin's
# thaw-then-refreeze is 40-hex on both sides, and must not double up as
# "aaaa... -> bbbb... (aaaa... -> bbbb...)" -- tokyonight.nvim's line above already
# pins that it does not. This checks the positive case: when both sides really are
# refs/tags/..., they are shown paired, with the rev move alongside in parens.
jq '.plugins["telescope.nvim"].resolvedRef = "refs/tags/0.1.7"' \
  "$fx"/plugins.json.before >plugins-tagpair-before.json
jq '.plugins["telescope.nvim"].resolvedRef = "refs/tags/0.1.8"' \
  "$fx"/plugins.json.after >plugins-tagpair-after.json
nvim -l "$lua"/update-summary.lua \
  plugins-tagpair-before.json plugins-tagpair-after.json \
  "$fx"/flake.lock.summary-before.json "$fx"/flake.lock.summary-after.json \
  2>summary-tagpair.txt
grep -q 'updated: telescope.nvim refs/tags/0.1.7 -> refs/tags/0.1.8 (c0c0c0c -> e0e0e0e)' \
  summary-tagpair.txt

# A `commit`-pinned plugin is only "cannot have moved" while its rev actually did
# not move: if the spec's `commit` itself was edited (and the rev moved with it),
# named mode must still report it -- as an ordinary "(spec changed)" line, not
# silence -- rather than falling into "unchanged (commit-pinned in spec)" as if
# nothing happened. This is the regression case for classify()'s pin/commit
# branches being gated on rb == ra.
jq '.plugins["vim-fugitive"].commit = "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"' \
  "$fx"/plugins.json.after >plugins-commitmove-after.json
jq '.nodes["vim-fugitive"].locked.rev = "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"' \
  "$fx"/flake.lock.summary-after.json >lock-commitmove-after.json
nvim -l "$lua"/update-summary.lua \
  "$fx"/plugins.json.before plugins-commitmove-after.json \
  "$fx"/flake.lock.summary-before.json lock-commitmove-after.json \
  tokyonight.nvim 2>summary-commitmove.txt
grep -q 'updated: vim-fugitive ddddddd -> eeeeeee (spec changed)' summary-commitmove.txt

# Symmetrically, a pinned (but unnamed) input whose rev moved anyway -- some
# anomaly, not a `--update` this run even asked for -- must be caught by the
# unnamed-move warning, not hidden behind "pinned (skipped)" as if it were still
# frozen. This is Done when 4's safety net; silence here is exactly the bug.
jq '.nodes["nui-nvim"].locked.rev = "9999999999999999999999999999999999999999"' \
  "$fx"/flake.lock.summary-after.json >lock-pinmove-after.json
nvim -l "$lua"/update-summary.lua \
  "$fx"/plugins.json.before "$fx"/plugins.json.after \
  "$fx"/flake.lock.summary-before.json lock-pinmove-after.json \
  tokyonight.nvim 2>summary-pinmove.txt
grep -q 'updated: nui.nvim c3c3c3c -> 9999999' summary-pinmove.txt
grep -q '^nvimx-lock: warning:.*nui.nvim' summary-pinmove.txt

# Dropping `pin` from an unnamed plugin's spec thaws it (resolve.lua's merge sets
# resolvedRef back to null) and a plain `nix flake lock` then moves its URL to
# HEAD -- a legitimate move docs/architecture.md itself documents ("Removing pin
# thaws the plugin"), not an anomaly. `pin` is not one of identity_fields, so
# same_identity alone cannot catch this: it must be its own reason, reported as
# `updated ... (unpinned)` and excluded from the unnamed-move warning.
jq '.plugins["nui.nvim"].pin = true
    | .plugins["nui.nvim"].resolvedRef = "c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3"' \
  "$fx"/plugins.json.before >plugins-unpin-before.json
jq '.plugins["nui.nvim"].pin = null | .plugins["nui.nvim"].resolvedRef = null' \
  "$fx"/plugins.json.after >plugins-unpin-after.json
jq '.nodes["nui-nvim"].locked.rev = "8888888888888888888888888888888888888888"' \
  "$fx"/flake.lock.summary-after.json >lock-unpin-after.json
nvim -l "$lua"/update-summary.lua \
  plugins-unpin-before.json plugins-unpin-after.json \
  "$fx"/flake.lock.summary-before.json lock-unpin-after.json \
  tokyonight.nvim 2>summary-unpin.txt
grep -q 'updated: nui.nvim c3c3c3c -> 8888888 (unpinned)' summary-unpin.txt
if grep -q '^nvimx-lock: warning:.*nui.nvim' summary-unpin.txt; then
  echo "an unpin is a legitimate, self-explaining move and must not be warned about" >&2
  exit 1
fi

# The synthetic lazy-nvim seed is an input like any other for the safety net
# (docs/architecture.md: "warns if an unnamed input moved"): named mode without
# --update lazy.nvim must still surface an unexplained lazy-nvim move, not stay
# silent just because lazy.nvim has no plugins.json entry to check a reason
# against. $fx/flake.lock.summary-after.json already moves lazy-nvim relative to
# summary-before.json, and neither name here is "lazy.nvim".
# This premise -- "lazy.nvim has no plugins.json entry" -- only holds because this
# fixture's lazyNvim is synthetic (plugins.json.{before,after}'s lazyNvim.synthetic
# is true). When the spec has its own lazy.nvim, `synthetic == false` and there IS
# an entry to check a reason against, same as any other plugin -- see #49's cases
# further down, which deliberately break this premise on purpose.
nvim -l "$lua"/update-summary.lua \
  "$fx"/plugins.json.before "$fx"/plugins.json.after \
  "$fx"/flake.lock.summary-before.json "$fx"/flake.lock.summary-after.json \
  tokyonight.nvim 2>summary-lazy-unrequested.txt
grep -q 'updated: lazy.nvim (seed) 9c9c9c9 -> 3f3f3f3' summary-lazy-unrequested.txt
grep -q '^nvimx-lock: warning:.*lazy\.nvim' summary-lazy-unrequested.txt

# #49: when lazyNvim is spec-derived (synthetic == false) rather than nvimx's own
# default, it is injected into plugins_before/plugins_after and classified exactly
# like an ordinary plugin -- with the same "pinned (skipped)" / "spec changed" /
# unnamed-move-safety-net rules -- instead of going through the dedicated
# "lazy.nvim (seed)" branch just above, which only applies while it stays
# synthetic. tests/fixtures/lazy-self/ carries the two plugins.json halves this
# needs (reused from tests/fixtures/update/ for the flake.lock halves, the same
# cross-fixture reuse checks.resolve-update already does with tests/fixtures/merge/).
#
# (a) A bare --update (mode_all, no names) with a `pin = true` lazy.nvim whose rev
# did not move: reported as `pinned: lazy.nvim (skipped ...)`, never as
# `unchanged: lazy.nvim (seed)` -- the label a synthetic lazyNvim would get. Passing
# the same before/after plugins.json and the same before/after flake.lock is
# deliberate: classify()'s pinned branch is gated on rb == ra, so the rev must not
# move for this branch to be reached at all.
nvim -l "$lua"/update-summary.lua \
  "$lsfx"/summary-pinned.plugins.json "$lsfx"/summary-pinned.plugins.json \
  "$fx"/flake.lock.summary-before.json "$fx"/flake.lock.summary-before.json \
  2>summary-lazy-pinned.txt
# shellcheck disable=SC2016 # the backticks are part of the message, not a substitution
grep -q 'pinned: lazy.nvim (skipped; run `nvimx-lock --update lazy.nvim` to move it)' \
  summary-lazy-pinned.txt
if grep -q 'unchanged: lazy.nvim (seed)' summary-lazy-pinned.txt; then
  echo "a spec-derived lazyNvim must be classified like any other plugin, not reported as the synthetic seed" >&2
  exit 1
fi

# (b) Named mode, with a name other than "lazy.nvim" (tokyonight.nvim -- deliberately
# not lazy.nvim itself, which would route through requested_set differently and
# defeat the point): the spec's own lazy.nvim `tag` changed between the two
# snapshots (summary-pinned.plugins.json -> summary-moved.plugins.json, `pin` still
# true), and its rev moved along with the flake.lock pair
# (flake.lock.summary-{before,after}.json's lazy-nvim node). This must be reported
# as an ordinary, self-explaining `(spec changed)` move -- never silence (that would
# be the seed-input branch's "no plugins.json entry to check a reason against"
# excuse, which no longer applies once lazyNvim is spec-derived) and never the
# unnamed-move safety net's warning (that would be the *other* false positive #49
# fixes: a legitimate spec edit misread as an unexplained move).
nvim -l "$lua"/update-summary.lua \
  "$lsfx"/summary-pinned.plugins.json "$lsfx"/summary-moved.plugins.json \
  "$fx"/flake.lock.summary-before.json "$fx"/flake.lock.summary-after.json \
  tokyonight.nvim 2>summary-lazy-moved.txt
grep -q 'updated: lazy.nvim 9c9c9c9 -> 3f3f3f3 (spec changed)' summary-lazy-moved.txt
if grep -q '^nvimx-lock: warning:.*lazy\.nvim' summary-lazy-moved.txt; then
  echo "a spec-derived lazyNvim move that explains itself (spec changed) must not trigger the unnamed-move safety net" >&2
  exit 1
fi

touch "$out"
