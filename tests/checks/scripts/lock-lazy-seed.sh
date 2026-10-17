# shellcheck shell=bash disable=SC2154
# Body of checks.lock-lazy-seed, sourced by the runCommand in ../lock-lazy-seed.nix.
# $fx $seeds $lockAppX $lazyInput $seedA $seedB $pinned $unpinned $fixtureLazy come from its env.
export HOME=$TMPDIR
# nvimx-lock realpath's --out, so compare against resolved paths (see lock-app.sh).
here=$(realpath .)
mkdir locktmp
export TMPDIR=$here/locktmp
no_leftover() {
  if [ -n "$(find "$TMPDIR" -mindepth 1 -maxdepth 1 -name 'tmp.*')" ]; then
    echo "nvimx-lock left its sandbox behind in $TMPDIR" >&2
    exit 1
  fi
}
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
export NVIMX_STUB_LOCK=$fx/nvimx-lock/flake.lock
export NVIMX_STUB_ARGV=$here/argv NVIMX_STUB_EVAL=$here/evals NVIMX_STUB_STATE=$here/state
# Before every step: the `updated` flag step 4 leaves behind would otherwise make the later
# steps answer with NVIMX_STUB_SEED_AFTER.
reset() {
  : >argv
  : >evals
  rm -rf "$NVIMX_STUB_STATE"
  mkdir "$NVIMX_STUB_STATE"
  unset NVIMX_STUB_FAIL NVIMX_STUB_SEED_AFTER
}
# The only plugin in <dir>/plugins.json
only_plugin() { # <dir> <name>
  [ "$(jq -r '.plugins | keys | join(",")' "$1/plugins.json")" = "$2" ]
}
want_argv() { # <line>...
  printf '%s\n' "$@" >want-argv
  diff -u want-argv argv
}

# 0. The expression layer, evaluated for real: the lazy.nvim pinned in a lock, and "" for one
# that pins none.
[ "$pinned" = "$fixtureLazy" ]
[ -z "$unpinned" ]

# 1. First lock: nothing pins lazy.nvim yet, so nvimx's own input is the seed. The post-lock
# lookup finds the same path, so there is no second extraction.
reset
export NVIMX_STUB_SEED=$lazyInput
nvimx-lock --config "$seeds/config" --out s1 2>s1.log
no_leftover
grep -qxF "nvimx-lock: lazy.nvim seed: $lazyInput (nvimx's own; no lock pins lazy.nvim yet)" s1.log
absent 're-extracting' s1.log
only_plugin s1 seed-input.nvim
[ "$(cat evals)" = "$here/s1" ]
want_argv 'flake lock path:.'

# 2. First lock, but the lock pinned a lazy.nvim other than nvimx's (lazy HEAD of that moment):
# the spec is extracted again against it, and the final plugins.json matches.
reset
export NVIMX_STUB_SEED=$seedA
nvimx-lock --config "$seeds/config" --out s2 2>s2.log
no_leftover
grep -qxF "nvimx-lock: lazy.nvim seed: $seedA (newly pinned in $here/s2/flake.lock); re-extracting spec" s2.log
only_plugin s2 seed-a.nvim
[ "$(wc -l <evals)" -eq 1 ]
want_argv 'flake lock path:.' 'flake lock path:.'

# 2b. The re-extraction must not be served the first run's vim.loader bytecode: both runs load
# the module from the same symlinked path, with the same size and mtime. Only this step covers the
# cache and state wipe; the others read their marker with io.open and would pass without it.
reset
export NVIMX_STUB_SEED=$seedA
"$lockAppX/bin/nvimx-lock" --config "$seeds/loader-config" --out s2b 2>s2b.log
no_leftover
grep -q 're-extracting' s2b.log
only_plugin s2b seed-a.nvim

# 3. Re-lock: the lock pins lazy.nvim, so that is the seed and nothing is extracted twice.
reset
export NVIMX_STUB_SEED=$seedA
nvimx-lock --config "$seeds/config" --out s2 2>s3.log
grep -qxF "nvimx-lock: lazy.nvim seed: $seedA (pinned in $here/s2/flake.lock)" s3.log
absent 're-extracting' s3.log
only_plugin s2 seed-a.nvim
[ "$(wc -l <evals)" -eq 2 ]
want_argv 'flake lock path:.'

# 4. --update moves lazy.nvim: extraction starts from the old pin and is redone against the new.
reset
export NVIMX_STUB_SEED=$seedA NVIMX_STUB_SEED_AFTER=$seedB
nvimx-lock --config "$seeds/config" --out s2 --update 2>s4.log
grep -qxF "nvimx-lock: lazy.nvim seed: $seedA (pinned in $here/s2/flake.lock)" s4.log
grep -qxF "nvimx-lock: lazy.nvim seed: $seedB (newly pinned in $here/s2/flake.lock); re-extracting spec" s4.log
only_plugin s2 seed-b.nvim
# Starts with these two; the changed plugin set may add a freezing lock after them.
head -n 2 argv >argv.head
printf '%s\n' 'flake lock path:.' 'flake update --flake path:. lazy-nvim seed-a-nvim' | diff -u - argv.head

# 5. A flake.lock that pins no lazy.nvim falls back to nvimx's own input.
reset
mkdir s5
cp "$fx"/nvimx-lock/flake.lock s5/
export NVIMX_STUB_SEED=
nvimx-lock --config "$seeds/config" --out s5 2>s5.log
grep -qxF "nvimx-lock: lazy.nvim seed: ${lazyInput} (nvimx's own; no lock pins lazy.nvim yet)" s5.log
only_plugin s5 seed-input.nvim

# 6. A failing lookup is fatal. Falling back silently would reintroduce the skew.
reset
cp -r s2 s6
chmod -R u+w s6
rc=0
NVIMX_STUB_FAIL=9 nvimx-lock --config "$seeds/config" --out s6 2>s6.log || rc=$?
[ "$rc" -eq 9 ]
[ "$(tail -n 1 s6.log)" = "$(fail_line 9)" ]
cmp s6/plugins.json s2/plugins.json
no_leftover
touch "$out"
