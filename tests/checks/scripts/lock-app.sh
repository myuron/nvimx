# shellcheck shell=bash disable=SC2154
# Body of checks.lock-app, sourced by the runCommand in ../lock-app.nix.
# $fx come from that derivation's env.
export HOME=$TMPDIR
# nvimx-lock realpath's --out, so every path compared against its output has to be
# resolved the same way: $PWD may go through a symlink (darwin's /tmp), which is
# why checks.resolve-import-lazy-lock step 15 says $(realpath cfg) too.
here=$(realpath .)
# A TMPDIR of its own, so that what nvimx-lock's `mktemp -d` leaves behind can be told
# apart from everything else: its sandbox is the only thing here named tmp.*. neovim
# keeps a nvim.<user>/ directory in TMPDIR too, which is why this looks for the name and
# not for an empty directory.
mkdir locktmp
export TMPDIR=$here/locktmp
no_leftover() {
  if [ -n "$(find "$TMPDIR" -mindepth 1 -maxdepth 1 -name 'tmp.*')" ]; then
    echo "nvimx-lock left its sandbox behind in $TMPDIR" >&2
    exit 1
  fi
}
export NVIMX_STUB_LOCK=$fx/nvimx-lock/flake.lock
export NVIMX_STUB_ARGV=$here/argv NVIMX_STUB_CWD=$here/cwd
reset() {
  : >argv
  : >cwd
}
# `! grep -q` would be vacuous: a `!`-negated command never trips errexit.
absent() { # <pattern> <file>
  if grep -q -- "$1" "$2"; then
    echo "unexpected \"$1\" in $2" >&2
    exit 1
  fi
}
# The expected last line of a failed run, built by a function rather than by a bash
# pattern substitution on a variable (nix would read that as its own interpolation here).
fail_line() { # <exit code>
  echo "nvimx-lock: failed (exit $1) -- look for the error above; it may sit above the import report and warnings"
}

# 1. First lock: one `nix flake lock`, with an explicit path: ref, run from inside
# the lock dir. The generated files equal the committed fixture lock, which is what
# makes the stub's flake.lock a faithful stand-in for the rest of this check.
reset
nvimx-lock --config "$fx" --out first 2>first.log
no_leftover
[ "$(cat argv)" = "flake lock path:." ]
[ "$(cat cwd)" = "$here/first" ]
cmp first/plugins.json "$fx"/nvimx-lock/plugins.json
cmp first/flake.nix "$fx"/nvimx-lock/flake.nix
[ "$(tail -n 1 first.log)" = "nvimx-lock: done. commit $here/first/{plugins.json,flake.nix,flake.lock}" ]
absent 'nvimx-lock: note:' first.log
absent 'nvimx-lock: failed' first.log

# 2. --update: the second call site, `nix flake update`, carries the same ref.
reset
nvimx-lock --config "$fx" --out first --update 2>update.log
printf '%s\n' 'flake lock path:.' 'flake update --flake path:. lazy-nvim tokyonight-nvim' >want-argv
diff -u want-argv argv
[ "$(sort -u cwd)" = "$here/first" ]

# 3. The third call site only runs when the convergence pass changes plugins.json.
# A first-time `pin = true` does that: nothing to freeze onto until the stub's
# flake.lock exists. tests/fixtures/merge-config has a pin too, but also a
# `version`, which needs git ls-remote -- hence a config written here. The `build`
# is there for step 4: it gives resolve.lua a warning to hold back.
mkdir pincfg
cat >pincfg/init.lua <<'LUA'
vim.opt.rtp:prepend(vim.fn.stdpath("data") .. "/lazy/lazy.nvim")
require("lazy").setup({ { "folke/tokyonight.nvim", pin = true, build = ":Foo" } })
LUA
reset
nvimx-lock --config pincfg --out pinned 2>pinned.log
printf '%s\n' 'flake lock path:.' 'flake lock path:.' >want-argv
diff -u want-argv argv
[ "$(sort -u cwd)" = "$here/pinned" ]
grep -q '^nvimx-lock: freezing pinned plugins$' pinned.log
jq -e '.plugins["tokyonight.nvim"].resolvedRef | test("^[0-9a-f]{40}$")' pinned/plugins.json >/dev/null

# 4. #71's actual symptom. When `nix` fails, the held-back warnings still come out
# (#22) -- after nix's own error, which is how the error got buried. The exit code
# survives the trap, and the very last line now says the run failed. The stub exits 7,
# not 1: the other failures in this check are 1 and 2, so only this tells "the original
# code is kept" apart from "anything non-zero becomes 1" -- in the exit status and
# in the number the last line prints.
reset
rc=0
NVIMX_STUB_FAIL=7 nvimx-lock --config pincfg --out failed 2>failed.log || rc=$?
[ "$rc" -eq 7 ]
[ "$(tail -n 1 failed.log)" = "$(fail_line 7)" ]
[ ! -e failed/flake.lock ]
no_leftover
err_at=$(grep -n '^error: stub nix was told to fail$' failed.log | cut -d: -f1)
warn_at=$(grep -n '^\[nvimx\] warning: plugin "tokyonight.nvim"' failed.log | cut -d: -f1)
[ "$err_at" -lt "$warn_at" ]
[ "$(grep -c '^nvimx-lock: failed' failed.log)" -eq 1 ]
absent '^nvimx-lock: done' failed.log

# 4b. The same failure on the path #71 was actually reported on: --import-lazy-lock.
# The import report is held back like the warnings are, so it lands after nix's
# error too, and the failure line still has to come last. The report is printed
# exactly once (#81: it used to come out twice, because pass 2 had not truncated
# resolve.log yet and the lines sat in both it and import.log).
cat >lazy-lock.json <<'JSON'
{ "tokyonight.nvim": { "branch": "main", "commit": "1234123412341234123412341234123412341234" } }
JSON
reset
rc=0
NVIMX_STUB_FAIL=7 nvimx-lock --config pincfg --out failed-import \
  --import-lazy-lock lazy-lock.json 2>failed-import.log || rc=$?
[ "$rc" -eq 7 ]
[ "$(tail -n 1 failed-import.log)" = "$(fail_line 7)" ]
[ "$(grep -c '^nvimx-lock: failed' failed-import.log)" -eq 1 ]
[ "$(grep -c '^\[nvimx\] import: ' failed-import.log)" -eq 2 ]
err_at=$(grep -n '^error: stub nix was told to fail$' failed-import.log | cut -d: -f1)
import_first=$(grep -n '^\[nvimx\] import: ' failed-import.log | head -n 1 | cut -d: -f1)
import_last=$(grep -n '^\[nvimx\] import: ' failed-import.log | tail -n 1 | cut -d: -f1)
[ "$err_at" -lt "$import_first" ]
[ "$import_last" -lt "$(wc -l <failed-import.log)" ]

# 4c. An exit code above 128 means the child was killed by a signal (the stub's 130
# stands in for nix dying of one; a real Ctrl-C makes nix exit 1 instead). A killed
# process leaves no error to scroll up to, so the last line says so instead of
# pointing at one. The code itself is kept, as in step 4.
reset
rc=0
NVIMX_STUB_FAIL=130 nvimx-lock --config pincfg --out signalled 2>signalled.log || rc=$?
[ "$rc" -eq 130 ]
[ "$(tail -n 1 signalled.log)" = 'nvimx-lock: stopped by a signal (exit 130)' ]
absent '^nvimx-lock: failed' signalled.log
no_leftover

# 4d. The failure can also come from the other `nix` call sites, which step 4 never
# reaches: the stub only fails at its first call there. Here `nix flake update` (the
# second call under --update) fails; the lock files from `first` are already written,
# so the run is a real half-finished one (#81).
cp -r first upd-fail
reset
rc=0
NVIMX_STUB_FAIL=7 NVIMX_STUB_FAIL_AT=2 nvimx-lock --config "$fx" --out upd-fail --update 2>upd-fail.log || rc=$?
printf '%s\n' 'flake lock path:.' 'flake update --flake path:. lazy-nvim tokyonight-nvim' >want-argv
diff -u want-argv argv
[ "$rc" -eq 7 ]
[ "$(tail -n 1 upd-fail.log)" = "$(fail_line 7)" ]
absent '^nvimx-lock: done' upd-fail.log
no_leftover

# 4e. ... and the convergence pass's `nix flake lock` (the second call of a first-time
# pin). Pass 2's resolve.log has replaced pass 1's by then: its warning must be shown
# once, after nix's error, not lost and not doubled (#81).
reset
rc=0
NVIMX_STUB_FAIL=7 NVIMX_STUB_FAIL_AT=2 nvimx-lock --config pincfg --out conv-fail 2>conv-fail.log || rc=$?
printf '%s\n' 'flake lock path:.' 'flake lock path:.' >want-argv
diff -u want-argv argv
[ "$rc" -eq 7 ]
grep -q '^nvimx-lock: freezing pinned plugins$' conv-fail.log
[ "$(grep -c '^\[nvimx\] warning: plugin "tokyonight.nvim"' conv-fail.log)" -eq 1 ]
err_at=$(grep -n '^error: stub nix was told to fail$' conv-fail.log | cut -d: -f1)
warn_at=$(grep -n '^\[nvimx\] warning: plugin "tokyonight.nvim"' conv-fail.log | cut -d: -f1)
[ "$err_at" -lt "$warn_at" ]
[ "$(tail -n 1 conv-fail.log)" = "$(fail_line 7)" ]
no_leftover

# 5. A failure before `nix` is ever reached ends the same way (the trap is what
# prints the line, not the nix step).
mkdir nosetup
echo 'vim.g.nvimx_no_setup = true' >nosetup/init.lua
reset
rc=0
nvimx-lock --config nosetup --out nosetup-out 2>nosetup.log || rc=$?
[ "$rc" -eq 1 ]
[ "$(tail -n 1 nosetup.log)" = "$(fail_line 1)" ]
[ ! -s argv ]
no_leftover

# 6. A usage error exits before the trap is installed, so it gets no failure line.
rc=0
nvimx-lock --config "$fx" 2>usage.log || rc=$?
[ "$rc" -eq 2 ]
absent 'nvimx-lock: failed' usage.log

# 7. The `git add` note. Inside a work tree, with any of the three files untracked,
# the lock still succeeds and says so; once all three are tracked it says nothing. Read-only throughout: the index is whatever the user left it as.
git init -q -b main repo
mkdir repo/nvim
cp "$fx"/init.lua repo/nvim/
lockdir=$here/repo/nvim/nvimx-lock
note_cmd="nvimx-lock: note:   git -C \"$lockdir\" add plugins.json flake.nix flake.lock"
nvimx-lock --config repo/nvim --out repo/nvim/nvimx-lock 2>untracked.log
[ "$(grep -c '^nvimx-lock: note:' untracked.log)" -eq 3 ]
grep -qxF "$note_cmd" untracked.log
[ "$(tail -n 1 untracked.log)" = 'nvimx-lock: note: home-manager switch cannot see it and builds the degraded (lazy.nvim-only) neovim instead' ]
# git's own complaint about the untracked files (`error: pathspec ...`) is not the
# user's business: the probe's output is discarded, only its verdict is used.
absent 'pathspec' untracked.log
[ "$(git -C repo status --porcelain)" = "?? nvim/" ]
# --update ends with the same note, after its summary: the note is the last thing
# any successful run prints, not something only a plain lock does.
nvimx-lock --config repo/nvim --out repo/nvim/nvimx-lock --update 2>untracked-update.log
grep -q '^nvimx-lock: no plugins updated' untracked-update.log
grep -qxF "$note_cmd" untracked-update.log
[ "$(tail -n 1 untracked-update.log)" = 'nvimx-lock: note: home-manager switch cannot see it and builds the degraded (lazy.nvim-only) neovim instead' ]
[ "$(git -C repo status --porcelain)" = "?? nvim/" ]
# Each of the three files on its own is enough to trigger a note: one state per
# file, with only that file missing from the index. A single partial state would
# let a check narrowed to one file (whichever) pass unnoticed. Which note differs:
# the build reads plugins.json and flake.lock (hasLock) but never flake.nix, so
# only the first two may claim a degraded build -- an untracked flake.nix alone
# gets the two-line note that just asks for it to be added.
for missing in plugins.json flake.nix flake.lock; do
  git -C repo add nvim/nvimx-lock
  git -C repo rm -q --cached nvim/nvimx-lock/$missing
  nvimx-lock --config repo/nvim --out repo/nvim/nvimx-lock 2>partial-$missing.log
  if [ "$missing" = flake.nix ]; then
    [ "$(grep -c '^nvimx-lock: note:' partial-$missing.log)" -eq 2 ]
    [ "$(tail -n 1 partial-$missing.log)" = "nvimx-lock: note:   git -C \"$lockdir\" add flake.nix" ]
    absent 'degraded' partial-$missing.log
  else
    [ "$(grep -c '^nvimx-lock: note:' partial-$missing.log)" -eq 3 ]
    grep -qxF "$note_cmd" partial-$missing.log
  fi
done
git -C repo add nvim/nvimx-lock
git -C repo status --porcelain >status.before
# stdout too: with everything tracked the probe would list the three file names there.
nvimx-lock --config repo/nvim --out repo/nvim/nvimx-lock >tracked.out 2>tracked.log
absent 'nvimx-lock: note:' tracked.log
[ ! -s tracked.out ]
git -C repo status --porcelain | diff -u status.before -

# 8. `git rev-parse --is-inside-work-tree` prints "false" and still exits 0 inside
# a bare repository, so the note has to compare the output, not the exit code.
git init -q --bare bare.git
nvimx-lock --config "$fx" --out bare.git/lock 2>bare.log
absent 'nvimx-lock: note:' bare.log

# 9. --summary-json (#77) on a plain first lock: the report is written (relative path, so it is
# resolved against the caller's cwd), in lock mode, and no summary text goes to stderr -- a
# plain lock's stderr is what it was before the flag existed. The first lock has no "before"
# files, so everything is an addition.
reset
nvimx-lock --config "$fx" --out sj1 --summary-json s1.json 2>sj1.log
jq -e '.mode == "lock" and ([.added[].name] == ["lazy.nvim", "tokyonight.nvim"])' s1.json >/dev/null
absent 'update summary' sj1.log
absent 'no plugins updated' sj1.log
no_leftover

# 10. --update with the flag: same report path, and the stderr text is still printed. The stub's
# lock does not move, so nothing is updated.
nvimx-lock --config "$fx" --out sj1 --update --summary-json s2.json 2>sj2.log
jq -e '.mode == "update-all" and .updated == []' s2.json >/dev/null
grep -q 'no plugins updated' sj2.log

# 11. Argument errors exit 2 before anything is created, --out included.
for bad in "--summary-json" "--summary-json --update"; do
  rc=0
  # shellcheck disable=SC2086 # word splitting of $bad is the point
  nvimx-lock --config "$fx" --out sj-bad $bad 2>sj-bad.log || rc=$?
  [ "$rc" -eq 2 ]
  [ ! -e sj-bad ]
done
rc=0
nvimx-lock --config "$fx" --out sj-bad --summary-json no-such-dir/s.json 2>sj-bad.log || rc=$?
[ "$rc" -eq 2 ]
[ ! -e sj-bad ]
mkdir sj-dir
rc=0
nvimx-lock --config "$fx" --out sj-bad --summary-json sj-dir 2>sj-bad.log || rc=$?
[ "$rc" -eq 2 ]
[ ! -e sj-bad ]

# 12. A failed run never leaves a previous report behind, and the failure line stays last.
echo stale >stale.json
reset # the stub fails on the first call counted since the last reset (#81)
rc=0
NVIMX_STUB_FAIL=7 nvimx-lock --config pincfg --out sj-failed --summary-json stale.json 2>sj-failed.log || rc=$?
[ "$rc" -eq 7 ]
[ ! -e stale.json ]
[ "$(tail -n 1 sj-failed.log)" = "$(fail_line 7)" ]

# 12b. The same for an early exit: the stale report is removed above the --update no-lock guard,
# and that guard still creates nothing.
echo stale >stale-early.json
rc=0
nvimx-lock --config "$fx" --out no-such-lock --update --summary-json stale-early.json 2>sj-early.log || rc=$?
[ "$rc" -eq 2 ]
grep -q 'nvimx-lock: no existing lock to update' sj-early.log
[ ! -e stale-early.json ]
[ ! -e no-such-lock ]

# 13. --import-lazy-lock is a plain lock as far as the report goes.
nvimx-lock --config pincfg --out sj3 --import-lazy-lock lazy-lock.json --summary-json s3.json 2>sj3.log
jq -e '.mode == "lock"' s3.json >/dev/null

touch "$out"
