# shellcheck shell=bash disable=SC2154
# Body of checks.extractor-local-dir, sourced by the runCommand in ../extractor-local-dir.nix.
# $localDirConfig $lazy $extractLua $lua come from that derivation's env.
export HOME=$TMPDIR
sb=$TMPDIR/sandbox
mkdir -p "$sb"/config "$sb"/data/nvim/lazy "$sb"/state "$sb"/cache
ln -s "$localDirConfig" "$sb"/config/nvim
# Makes the fixture's lazypath fs_stat succeed, so its bootstrap snippet never
# reaches the `git clone` branch. Same handling as extractor-defaults-version.
ln -s "$lazy" "$sb"/data/nvim/lazy/lazy.nvim
env \
  XDG_CONFIG_HOME="$sb"/config \
  XDG_DATA_HOME="$sb"/data \
  XDG_STATE_HOME="$sb"/state \
  XDG_CACHE_HOME="$sb"/cache \
  NVIMX_LAZY_SEED="$lazy" \
  NVIMX_OUT="$sb"/raw-spec.json \
  nvim --headless --cmd "luafile $extractLua"

# (1) extract.lua's own contract. The dir shapes are recorded exactly as lazy normalized them:
#     absolute verbatim, "~" expanded against $HOME by Util.norm, relative left relative.
#     Absolutizing the relative one here would put nvimx somewhere lazy is not.
jq -e '.plugins["dirabs.nvim"].dir == "/nvimx-fixture/dirabs"' "$sb"/raw-spec.json >/dev/null
jq -e --arg h "$HOME" '.plugins["dirtilde.nvim"].dir == ($h + "/nvimx-fixture/dirtilde")' \
  "$sb"/raw-spec.json >/dev/null
jq -e '.plugins["dirrel.nvim"].dir == "nvimx-fixture/dirrel"' "$sb"/raw-spec.json >/dev/null
# The shorthand-less form: lazy names it after the path and leaves url unset. Locking this used
# to be impossible ("has no url"), not merely wasteful.
jq -e '.plugins["dirnoname"].dir == "/nvimx-fixture/dirnoname"' "$sb"/raw-spec.json >/dev/null
jq -e '.plugins["dirnoname"] | has("url") | not' "$sb"/raw-spec.json >/dev/null
# A sibling of lazy's root. Recorded only because the predicate's prefix ends in "/": drop that
# slash and "<root>" prefix-matches "<root>-sibling/..." and this plugin silently goes remote.
jq -e '.plugins["sibling.nvim"] | has("dir")' "$sb"/raw-spec.json >/dev/null
# dev with no dir of its own still works, and its dir comes from lazy's dev.path
jq -e '.plugins["bare.nvim"].dev == true' "$sb"/raw-spec.json >/dev/null
jq -e --arg h "$HOME" '.plugins["bare.nvim"].dir == ($h + "/projects/bare.nvim")' \
  "$sb"/raw-spec.json >/dev/null
# The other half of the predicate, and the one a `dir = p.dir` regression breaks: an ordinary
# remote plugin has a dir too (<root>/<name>), and it must not be recorded.
jq -e '.plugins["tokyonight.nvim"] | has("dir") | not' "$sb"/raw-spec.json >/dev/null
jq -e '[.plugins[] | select(has("dir"))] | length == 6' "$sb"/raw-spec.json >/dev/null
# Step 2 relies on a routing regression killing the resolve, and #23's gate firing with no --lazy
# is one of the two routes it can take (dirnoname's missing url is the other, and the one that
# actually surfaces today). That route only exists while the constraints do, so pin them here --
# otherwise a later change that stops materializing defaults.version onto local plugins retires
# half of step 2's coverage with nothing going red.
jq -e '.plugins["dirabs.nvim"].version == "*"' "$sb"/raw-spec.json >/dev/null
jq -e '.plugins["dirabs.nvim"].versionFromDefaults == true' "$sb"/raw-spec.json >/dev/null
jq -e '[.plugins[] | select(.version == "*")] | length == 6' "$sb"/raw-spec.json >/dev/null
jq -e '[.plugins[] | select(.versionFromDefaults == true)] | length == 6' "$sb"/raw-spec.json >/dev/null

# (2) resolve, offline and with no --lazy. Exit 0 is the assertion that no local plugin was filed
#     as remote: either route out of the header comment -- dirnoname's missing url, or #23's gate
#     with no --lazy to satisfy it -- would end this non-zero.
nvim -l "$lua"/resolve.lua "$sb"/raw-spec.json plugins.json 2>resolve.log
[ ! -s resolve.log ]
jq -e '(.localPlugins | keys) ==
       ["bare.nvim","dirabs.nvim","dirnoname","dirrel.nvim","dirtilde.nvim","sibling.nvim"]' \
  plugins.json >/dev/null
jq -e '(.plugins | keys) == ["tokyonight.nvim"]' plugins.json >/dev/null
jq -e '.warnings == []' plugins.json >/dev/null
# The keys above are the whole of what nix/lib reads: make-env.nix only ever asks this map for
# its names (builtins.attrNames for devDirs, `? name` for unknownDevPluginNames), never for a
# value (#26). So #56 stopped writing anything else down -- for three of these six the dir lazy
# resolved came off the machine that ran the lock (bare.nvim's from dev.path, dirtilde's from a
# `~`, sibling's from stdpath), and this file gets committed. This is the only fixture whose
# resolve fills localPlugins with six entries at once -- a bare `dev`, three dir spellings
# (absolute, "~", relative), a shorthand-less dir, and a sibling of lazy's root -- so it is the
# one place "no matter which of those made a plugin local, the entry carries no value" can be
# said. It is deliberately not a list of every way in: a spec that writes `dev = true` *and* a
# dir (that shape is in checks.resolve-golden's fixture, whose golden pins its exact bytes),
# lazy's `virtual = true`, a dev.path aimed back under lazy's own root, and anything
# dev.patterns routes here off a plugin's url alone are all outside this fixture -- which is why
# the assertion is written over whatever localPlugins ended up holding rather than over a set of
# names. A plugins.json committed before #56 still carries the dirs it wrote then, and make-env
# still ignores those -- checks.dev-plugins' fixture is what holds *that* down.
jq -e '[.localPlugins[] | select(. != { })] | length == 0' plugins.json >/dev/null

# (3) The lock's own statement of the fix: no flake input for a plugin that lives on disk.
nvim -l "$lua"/genflake.lua plugins.json flake.nix
grep -q 'tokyonight-nvim = {' flake.nix
! grep -qE 'dirabs|dirtilde|dirrel|dirnoname|sibling|bare' flake.nix
[ "$(grep -c 'flake = false;' flake.nix)" -eq 2 ]

# (4) --update by name is fatal for a local plugin, and plugins.json is never written. This is
#     resolve.lua's existing rule; #47 only widens which plugins it applies to.
rc=0
nvim -l "$lua"/resolve.lua "$sb"/raw-spec.json update.json --update dirabs.nvim \
  2>update.log || rc=$?
[ "$rc" -ne 0 ]
[ ! -e update.json ]
grep -q 'is a local plugin (dev/dir); nothing to lock or update' update.log
grep -q 'dirabs.nvim' update.log

# (5) A bare --update leaves them out of the plan entirely: there is nothing to move.
nvim -l "$lua"/resolve.lua "$sb"/raw-spec.json all.json --update --update-plan plan.txt
[ "$(wc -l <plan.txt)" -eq 2 ]
grep -qx 'lazy-nvim' plan.txt
grep -qx 'tokyonight-nvim' plan.txt

touch "$out"
