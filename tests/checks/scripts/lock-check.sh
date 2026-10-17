# shellcheck shell=bash disable=SC2154,SC2016
# Body of checks.lock-check, sourced by the runCommand in ../lock-check.nix (mkrepo comes from
# the mkTagRepoSh prelude). Helpers mirror checks.lock-app's: its own TMPDIR so that a sandbox
# nvimx-lock leaves behind can be told apart, and a stub nix that records argv.
export HOME=$TMPDIR
here=$(realpath .)
mkdir locktmp
export TMPDIR=$here/locktmp
no_leftover() {
  if [ -n "$(find "$TMPDIR" -mindepth 1 -maxdepth 1 -name 'tmp.*')" ]; then
    echo "nvimx-lock left its sandbox behind in $TMPDIR" >&2
    exit 1
  fi
}
export NVIMX_STUB_ARGV=$here/argv
: >argv
# `! grep -q` would be vacuous: a `!`-negated command never trips errexit.
absent() { # <pattern> <file>
  if grep -q -- "$1" "$2"; then
    echo "unexpected \"$1\" in $2" >&2
    exit 1
  fi
}
fail_line() { # <exit code>
  echo "nvimx-lock: failed (exit $1) -- look for the error above; it may sit above the import report and warnings"
}
# mkcfg <dir>: a config whose lazy spec is read from stdin.
mkcfg() {
  mkdir -p "$1"
  {
    echo 'vim.opt.rtp:prepend(vim.fn.stdpath("data") .. "/lazy/lazy.nvim")'
    echo 'require("lazy").setup({'
    cat
    echo '})'
  } >"$1/init.lua"
}
base_spec() {
  cat <<LUA
{ "folke/tokyonight.nvim", pin = true },
{ url = "file://$TMPDIR/remote", name = "tagged.nvim", version = "^1" },
{ dir = "/nvimx-fixture/localdir", name = "localdir.nvim" },
{ "nvim-lua/plenary.nvim" },
LUA
}
# check <config> <lockdir> <tag>: runs --check, leaves rc, <tag>.out and <tag>.log behind.
check() {
  : >argv
  rc=0
  nvimx-lock --config "$1" --out "$2" --check >"$3.out" 2>"$3.log" || rc=$?
  [ ! -s "$3.out" ]
  [ ! -s argv ]
  no_leftover
}
# stale_block <tag>: the report out of <tag>.log, header through the last line.
stale_block() {
  sed -n '/^\[nvimx\] lock is stale:$/,$p' "$1.log"
}
last_line() { tail -n 1 "$1.log"; }

mkrepo "$TMPDIR/remote" v1.0.0 v1.1.0
base_spec | mkcfg cfg

# 1. A fresh lock passes: exit 0, the documented last line, nothing written, no nix call. The
# lock really holds a frozen pin and a resolved tag, so this also shows resolvedRef is ignored
# rather than merely null on both sides.
nvimx-lock --config cfg --out lock 2>lock.log
jq -e '.plugins["tokyonight.nvim"].resolvedRef | test("^[0-9a-f]{40}$")' lock/plugins.json >/dev/null
jq -e '.plugins["tagged.nvim"].resolvedRef | startswith("refs/tags/")' lock/plugins.json >/dev/null
rm -rf lock.snap && cp -a lock lock.snap
check cfg lock c1
[ "$rc" -eq 0 ]
[ "$(last_line c1)" = "nvimx-lock: lock is up to date" ]
absent 'lock is stale' c1.log
diff -r lock lock.snap

# 2. Offline: with the `version` remote gone, a non-offline resolve would fail in git ls-remote.
rm -rf "$TMPDIR/remote"
check cfg lock c2
[ "$rc" -eq 0 ]
[ "$(last_line c2)" = "nvimx-lock: lock is up to date" ]

# 3. Right after --update.
mkrepo "$TMPDIR/remote" v1.0.0 v1.1.0
nvimx-lock --config cfg --out lock --update 2>update.log
rm -rf lock.snap && cp -a lock lock.snap
check cfg lock c3
[ "$rc" -eq 0 ]
[ "$(last_line c3)" = "nvimx-lock: lock is up to date" ]
diff -r lock lock.snap

# 4. Added / removed / changed. One run per edit, asserting exactly its own line, so one rule
# cannot mask another; then all edits at once for the full report.
single() { # <tag> <expected report line> <sed script applied to the base spec>
  base_spec | sed "$3" | mkcfg "cfg-$1"
  check "cfg-$1" lock "s-$1"
  [ "$rc" -eq 1 ]
  printf '%s\n' '[nvimx] lock is stale:' "$2" "nvimx-lock: run nvimx-lock without --check to refresh $here/lock" >"s-$1.want"
  stale_block "s-$1" | diff -u "s-$1.want" -
  absent 'nvimx-lock: failed' "s-$1.log"
  diff -r lock lock.snap
}
single add '  missing from lock: oil.nvim' '$a{ "stevearc/oil.nvim" },'
single del '  no longer in spec: plenary.nvim' '/plenary/d'
single ver '  spec changed:      tagged.nvim (version "^1" -> "^2")' 's/"\^1"/"^2"/'
single build '  spec changed:      tokyonight.nvim (build changed)' 's/pin = true/pin = true, build = ":Foo"/'
single remote '  spec changed:      localdir.nvim (no longer a local plugin)' 's|{ dir = .*|{ "x/localdir.nvim" },|'
single local '  spec changed:      plenary.nvim (now a local plugin)' 's|{ "nvim-lua/plenary.nvim" }|{ dir = "/nvimx-fixture/plenary", name = "plenary.nvim" }|'

base_spec | sed -e '$a{ "stevearc/oil.nvim" },' -e '/plenary/d' -e 's/"\^1"/"^2"/' \
  -e 's/pin = true/pin = true, build = ":Foo"/' -e 's|{ dir = .*|{ "x/localdir.nvim" },|' | mkcfg cfg-all
check cfg-all lock c4
[ "$rc" -eq 1 ]
cat >c4.want <<WANT
[nvimx] lock is stale:
  missing from lock: oil.nvim
  no longer in spec: plenary.nvim
  spec changed:      localdir.nvim (no longer a local plugin)
  spec changed:      tagged.nvim (version "^1" -> "^2")
  spec changed:      tokyonight.nvim (build changed)
nvimx-lock: run nvimx-lock without --check to refresh $here/lock
WANT
stale_block c4 | diff -u c4.want -
absent 'nvimx-lock: failed' c4.log
diff -r lock lock.snap

# 5. plugins.json and flake.lock out of sync: an input the plugins.json needs is gone, and one
# nothing claims is present.
cp -a lock lock5
jq 'del(.nodes.root.inputs["tokyonight-nvim"]) | .nodes.root.inputs.stray = "stray"' lock/flake.lock >lock5/flake.lock
check cfg lock5 c5
[ "$rc" -eq 1 ]
cat >c5.want <<WANT
[nvimx] lock is stale:
  not in flake.lock: tokyonight.nvim
  flake.lock only:   stray
nvimx-lock: run nvimx-lock without --check to refresh $here/lock5
WANT
stale_block c5 | diff -u c5.want -

# 6. No lock at all is stale too (so `--check || nvimx-lock` bootstraps), reported against the
# raw --out, and nothing is created.
check cfg nolock c6
[ "$rc" -eq 1 ]
cat >c6.want <<'WANT'
[nvimx] lock is stale:
  no lock in nolock (plugins.json and flake.lock are both needed)
nvimx-lock: run nvimx-lock without --check to refresh nolock
WANT
stale_block c6 | diff -u c6.want -
[ ! -e nolock ]

# 7. --check never writes, so it refuses the flags whose point is to.
: >argv
for flags in "--update" "--import-lazy-lock x" "--summary-json sj.json"; do
  rc=0
  # shellcheck disable=SC2086
  nvimx-lock --config cfg --out never --check $flags 2>c7.log || rc=$?
  [ "$rc" -eq 2 ]
  grep -q 'cannot be combined' c7.log
  absent 'nvimx-lock: failed' c7.log
  [ ! -e never ]
  [ ! -e sj.json ]
done
[ ! -s argv ]
no_leftover

# 8. Errors are not "stale": they keep the failure line and never print the report header.
cp -a lock lock8
jq '.schemaVersion = 2' lock/plugins.json >lock8/plugins.json
check cfg lock8 c8a
[ "$rc" -ne 0 ]
[ "$(last_line c8a)" = "$(fail_line "$rc")" ]
absent 'lock is stale' c8a.log
mkdir cfg-nosetup
echo '-- no lazy.setup here' >cfg-nosetup/init.lua
check cfg-nosetup lock c8b
[ "$rc" -eq 1 ]
[ "$(last_line c8b)" = "$(fail_line 1)" ]
absent 'lock is stale' c8b.log
# A number is not a version constraint; the grammar check still runs under --offline.
base_spec | sed 's/"\^1"/1.2/' | mkcfg cfg-badver
check cfg-badver lock c8c
[ "$rc" -ne 0 ]
[ "$(last_line c8c)" = "$(fail_line "$rc")" ]
absent 'lock is stale' c8c.log

# 9. lazy.nvim's own entry (#49) lives outside plugins/localPlugins, so it must not be part of the
# name map the other rules use.
# a. Locked without it, then the spec adds it: exactly one line, with the absent synthetic-literal
# keys reading as null.
base_spec | mkcfg cfg9
nvimx-lock --config cfg9 --out lock9a 2>/dev/null
{
  base_spec
  echo '{ "folke/lazy.nvim", tag = "v11.0.0" },'
} | mkcfg cfg9a
check cfg9a lock9a c9a
[ "$rc" -eq 1 ]
printf '%s\n' '[nvimx] lock is stale:' \
  '  spec changed:      lazy.nvim (synthetic true -> false, tag null -> "v11.0.0")' \
  "nvimx-lock: run nvimx-lock without --check to refresh $here/lock9a" >c9a.want
stale_block c9a | diff -u c9a.want -
# b. A spec lazy.nvim that is locked is fresh (no build/dependencies asymmetry for the self-entry).
nvimx-lock --config cfg9a --out lock9b 2>/dev/null
check cfg9a lock9b c9b
[ "$rc" -eq 0 ]
# c. A local lazy.nvim: localPlugins["lazy.nvim"] and the synthetic lazyNvim coexist.
{
  base_spec
  echo '{ "folke/lazy.nvim", dir = "/nvimx-fixture/lazy.nvim" },'
} | mkcfg cfg9c
nvimx-lock --config cfg9c --out lock9c 2>/dev/null
check cfg9c lock9c c9c
[ "$rc" -eq 0 ]

# 10. Untracked spec files (#33, shared with the plain lock through one function): --check warns
# about them too -- a hook `--check || nvimx-lock` would otherwise pass silently -- but the
# warning is only a warning: exit code, empty stdout and the verdict as last line are unchanged.
git init -q -b main repo
base_spec | mkcfg repo/nvim
git -C repo add nvim/init.lua
git -C repo -c user.name=t -c user.email=t@t commit -q -m init
nvimx-lock --config repo/nvim --out lock10 2>/dev/null
echo notes >repo/nvim/notes.txt
check repo/nvim lock10 c10a
[ "$rc" -eq 0 ]
grep -q '^nvimx-lock: warning: 1 file(s) under .* are not tracked by git' c10a.log
grep -qxF 'nvimx-lock: warning:   notes.txt' c10a.log
[ "$(last_line c10a)" = "nvimx-lock: lock is up to date" ]
# Stale and untracked at once: both are reported, the refresh hint still comes last.
echo '-- changed' >>repo/nvim/init.lua
sed -i 's/"\^1"/"^2"/' repo/nvim/init.lua
check repo/nvim lock10 c10b
[ "$rc" -eq 1 ]
grep -qxF 'nvimx-lock: warning:   notes.txt' c10b.log
[ "$(last_line c10b)" = "nvimx-lock: run nvimx-lock without --check to refresh $here/lock10" ]
# Tracked, nothing to warn about.
git -C repo add nvim/notes.txt nvim/init.lua
check repo/nvim lock10 c10c
absent 'nvimx-lock: warning' c10c.log

touch "$out"
