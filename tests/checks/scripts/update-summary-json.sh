# shellcheck shell=bash disable=SC2154
# Body of checks.update-summary-json, sourced by the runCommand in ../update-summary-json.nix.
# $lua $fx $lsfx come from that derivation's env.
export HOME=$TMPDIR
sum() { nvim -l "$lua"/update-summary.lua "$@"; }
pj_b=$fx/plugins.json.before
pj_a=$fx/plugins.json.after
lk_b=$fx/flake.lock.summary-before.json
lk_a=$fx/flake.lock.summary-after.json

# 1. Full update. Criterion 2 of #77: --json must not change a single byte of the stderr text,
# so the text goldens of checks.update-summary are compared here too.
sum --json all.json "$pj_b" "$pj_a" "$lk_b" "$lk_a" 2>all.txt
diff -u "$fx"/golden/summary-all.json all.json
diff -u "$fx"/golden/summary-all.txt all.txt

# 2. Named mode: the same filter as the text (requested + anything that moved), and
# plenary.nvim, which moved unnamed, is the one unexplained entry.
sum --json named.json "$pj_b" "$pj_a" "$lk_b" "$lk_a" tokyonight.nvim lazy.nvim 2>named.txt
diff -u "$fx"/golden/summary-named.json named.json
diff -u "$fx"/golden/summary-named.txt named.txt

# 3. Nothing moved: the "no plugins updated" shortcut must not skip the JSON.
sum --json none.json "$pj_b" "$pj_b" "$lk_b" "$lk_b" tokyonight.nvim 2>none.txt
diff -u "$fx"/golden/summary-none.json none.json
diff -u "$fx"/golden/summary-none.txt none.txt

# 4. --plain is a plain lock: JSON only, nothing on stderr, pinned reported as unchanged.
sum --plain --json lock.json "$pj_b" "$pj_a" "$lk_b" "$lk_a" 2>lock.err
diff -u "$fx"/golden/summary-lock.json lock.json
if [ -s lock.err ]; then
  echo "--plain must print nothing on stderr" >&2
  exit 1
fi

# 5. A first lock has empty "before" files. The synthetic lazy.nvim seed would come out as the
# text's "updated: ? -> rev" there, but in the report it is an addition.
echo '{}' >empty.json
sum --plain --json first.json empty.json "$pj_a" empty.json "$lk_a"
diff -u "$fx"/golden/summary-first.json first.json
jq -e '(.added | map(.name) | index("lazy.nvim")) != null and (.updated | map(.name) | index("lazy.nvim")) == null' \
  first.json >/dev/null

# 6. compareUrl is only emitted when it is certain to be a valid link.
tweak() { # <jq filter on plenary.nvim's source> <out>
  jq "$1" "$pj_b" >"tweak-before-$2.json"
  jq "$1" "$pj_a" >"tweak-after-$2.json"
  sum --json "tweak-$2.json" "tweak-before-$2.json" "tweak-after-$2.json" "$lk_b" "$lk_a" 2>/dev/null
}
tweak '.plugins["plenary.nvim"].source = {type: "git", url: "https://example.com/p.git"}' git
jq -e '.updated[] | select(.name == "plenary.nvim") | .compareUrl == null' tweak-git.json >/dev/null
tweak '.plugins["plenary.nvim"].source.repo = "plenary.nvim/"' slash
f1=$(printf 'f1%.0s' $(seq 20))
f2=$(printf 'f2%.0s' $(seq 20))
jq -e --arg u "https://github.com/nvim-lua/plenary.nvim/compare/$f1...$f2" \
  '.updated[] | select(.name == "plenary.nvim") | .compareUrl == $u' tweak-slash.json >/dev/null
tweak '.plugins["plenary.nvim"].source.owner = "nvim lua"' owner
jq -e '.updated[] | select(.name == "plenary.nvim") | .compareUrl == null' tweak-owner.json >/dev/null

# 7. #49: a spec-derived lazy.nvim is a plain plugin entry, and its source comes from lazyNvim.
sum --json lazy-moved.json "$lsfx"/summary-pinned.plugins.json "$lsfx"/summary-moved.plugins.json \
  "$lk_b" "$lk_a" tokyonight.nvim 2>/dev/null
jq -e '(.updated[] | select(.name == "lazy.nvim") | .reason == "spec-changed" and .source.type == "github")
  and .unexplained == []' lazy-moved.json >/dev/null

# 8. Bad arguments and an unwritable path are fatal (lock-app.nix keeps that fatal on purpose).
expect_fail() {
  local rc=0
  "$@" 2>fail.err || rc=$?
  [ "$rc" -ne 0 ]
  grep -q '\[nvimx\] update-summary failed' fail.err
}
expect_fail sum --json --plain "$pj_b" "$pj_a" "$lk_b" "$lk_a"
expect_fail sum --json
expect_fail sum --foo "$pj_b" "$pj_a" "$lk_b" "$lk_a"
expect_fail sum --plain "$pj_b" "$pj_a" "$lk_b" "$lk_a" tokyonight.nvim
expect_fail sum --json nodir/x.json "$pj_b" "$pj_a" "$lk_b" "$lk_a"

touch "$out"
