# shellcheck shell=bash disable=SC2154
# Body of checks.e2e-offline, sourced by the runCommand in ../e2e-offline.nix.
# $fx $lazy $lua $farm $wrapped $gitShim $ownLock $probe $runLockLoop come from that derivation's env.
export HOME=$TMPDIR
# nix refuses a store root with a symlink anywhere in its parents, and darwin's /tmp is one,
# so every path step 3 hands to nix (store, remotes, configs) lives under the resolved TMPDIR.
base=$(realpath "$TMPDIR")

# 1. Fixture integrity (extract -> resolve -> genflake). Steps 2 and 3 are only meaningful if
# the committed lock is what the pipeline makes of this init.lua today. The per-stage goldens
# (extractor-snapshot, resolve-golden, genflake-golden) use other fixtures and launch nothing.
# No --lock / --prev: that is a first pass, so the pin stays unfrozen and nothing goes online.
sb=$base/sandbox
mkdir -p "$sb"/config "$sb"/data/nvim/lazy "$sb"/state "$sb"/cache gen
ln -s "$fx" "$sb"/config/nvim
ln -s "$lazy" "$sb"/data/nvim/lazy/lazy.nvim
# timeout + closed stdin: a config that never reaches setup would otherwise hang the build (#3).
env \
  XDG_CONFIG_HOME="$sb"/config \
  XDG_DATA_HOME="$sb"/data \
  XDG_STATE_HOME="$sb"/state \
  XDG_CACHE_HOME="$sb"/cache \
  NVIMX_LAZY_SEED="$lazy" \
  NVIMX_OUT="$sb"/raw-spec.json \
  timeout 120 nvim --headless --cmd "luafile $lua/extract.lua" </dev/null
nvim -l "$lua"/resolve.lua "$sb"/raw-spec.json gen/plugins.json --lazy "$lazy"
nvim -l "$lua"/genflake.lua gen/plugins.json gen/flake.nix
nixfmt gen/flake.nix
cmp gen/plugins.json "$fx"/nvimx-lock/plugins.json
cmp gen/flake.nix "$fx"/nvimx-lock/flake.nix

# 2. The env is already built (a derivation input). Launch the wrapped nvim with the user's
# init.lua laid out as the hm module / packages.demo do, with a git shim as the only git on a
# minimal PATH: every plugin must come from the store without a single git call.
x=$base/run
mkdir -p "$x"/config "$x"/data/nvim/lazy "$x"/state "$x"/cache
ln -s "$fx" "$x"/config/nvim
ln -s "$farm"/lazy.nvim "$x"/data/nvim/lazy/lazy.nvim
git_log=$base/git.log
: >"$git_log"
coreutils_bin=$(dirname "$(command -v timeout)")
# Closed stdin and a timeout, as for the extractor above: the guard against a hung headless nvim.
# `|| rc=$?` so that the failure message below is reached under errexit.
rc=0
env \
  PATH="$gitShim/bin:$coreutils_bin" \
  GIT_LOG="$git_log" \
  FARM="$farm" \
  PROBE_OK="$base"/probe-ok \
  XDG_CONFIG_HOME="$x"/config \
  XDG_DATA_HOME="$x"/data \
  XDG_STATE_HOME="$x"/state \
  XDG_CACHE_HOME="$x"/cache \
  timeout 120 "$wrapped"/bin/nvim --headless -c "luafile $probe" </dev/null || rc=$?
if [ "$rc" -ne 0 ] || [ ! -f "$base"/probe-ok ]; then
  echo "the wrapped nvim did not start cleanly (exit $rc)" >&2
  exit 1
fi
if [ -s "$git_log" ]; then
  echo "git was called at runtime:" >&2
  cat "$git_log" >&2
  exit 1
fi

# 3. A real `nix flake lock` through nvimx-lock, on file:// remotes and a private store (the build
# sandbox has no daemon). lock-app only proves this against a stub nix.
if [ -n "$runLockLoop" ]; then
  cp -r "$fx" "$base"/src
  chmod -R u+w "$base"/src
  for d in "$base"/src/plugins/*; do
    r=$base/remotes/nvimx-e2e/$(basename "$d")
    mkdir -p "$r"
    cp -r "$d"/. "$r"/
    git -C "$r" init -q -b main
    git -C "$r" add -A
    git -C "$r" -c user.name=nvimx -c user.email=nvimx@example.com commit -q -m init
  done
  mkdir -p "$base"/cfg "$base"/out
  # url_format is the one string that tells the two halves apart (see the fixture's init.lua).
  sed "s#https://github.com/%s.git#file://$base/remotes/%s#" "$fx"/init.lua >"$base"/cfg/init.lua
  grep -q "file://$base/remotes" "$base"/cfg/init.lua
  # Seeded with nvimx's own lazy-nvim node: nix keeps a locked node whose `original` still
  # matches and never fetches it, so the synthetic github input stays network-free.
  jq '{nodes: {"lazy-nvim": .nodes["lazy-nvim"], root: {inputs: {"lazy-nvim": "lazy-nvim"}}}, root: "root", version: 7}' \
    "$ownLock" >"$base"/out/flake.lock
  export NIX_CONFIG="experimental-features = nix-command flakes
store = $base/store
flake-registry ="
  lock() { nvimx-lock --config "$base"/cfg --out "$base"/out 2>"$base"/lock.log; }

  # 3a. The first run freezes the pin: resolvedRef, flake.lock and flake.nix agree on one rev.
  lock
  grep -q '^nvimx-lock: freezing pinned plugins$' "$base"/lock.log
  rev=$(git -C "$base"/remotes/nvimx-e2e/alpha.nvim rev-parse HEAD)
  [ "$(jq -r '.plugins["alpha.nvim"].resolvedRef' "$base"/out/plugins.json)" = "$rev" ]
  [ "$(jq -r '.nodes["alpha-nvim"].locked.rev' "$base"/out/flake.lock)" = "$rev" ]
  grep -q "?rev=$rev" "$base"/out/flake.nix

  # 3b. Same plugin graph as the committed lock; only where the sources live differs.
  proj='{plugins: (.plugins | map_values(del(.source, .resolvedRef))), lazyNvim: (.lazyNvim | del(.source)), localPlugins}'
  [ "$(jq -S "$proj" "$base"/out/plugins.json)" = "$(jq -S "$proj" "$fx"/nvimx-lock/plugins.json)" ]

  # 3c. A second run converges: byte-identical output, and nothing left to freeze.
  cp -r "$base"/out "$base"/out1
  lock
  diff -r "$base"/out1 "$base"/out
  if grep -q 'freezing' "$base"/lock.log; then
    echo "the second run froze something again" >&2
    exit 1
  fi

  # 3d. Dropping a spec drops its node (and its dependency's) from flake.lock, via real nix.
  sed -i '/nvimx-e2e\/beta.nvim/d' "$base"/cfg/init.lua
  lock
  for n in beta-nvim gamma-nvim; do
    jq -e --arg n "$n" '(.nodes | has($n) | not) and (.nodes.root.inputs | has($n) | not)' "$base"/out/flake.lock >/dev/null
    jq -e --arg n "$n" '[.plugins[].inputName] | index($n) | not' "$base"/out/plugins.json >/dev/null
    if grep -q "$n" "$base"/out/flake.nix; then
      echo "$n is still in flake.nix" >&2
      exit 1
    fi
  done
  [ "$(jq -S '.nodes["alpha-nvim"]' "$base"/out/flake.lock)" = "$(jq -S '.nodes["alpha-nvim"]' "$base"/out1/flake.lock)" ]
fi
touch "$out"
