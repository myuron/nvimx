# shellcheck shell=bash disable=SC2154
# Body of checks.extractor-defaults-version, sourced by the runCommand in ../extractor-defaults-version.nix.
# $lazy $extractLua $defaultsConfig $lua $defaultsFalseConfig come from that derivation's env.
export HOME=$TMPDIR
sb=$TMPDIR/sandbox
mkdir -p "$sb"/config "$sb"/data/nvim/lazy "$sb"/state "$sb"/cache
ln -s "$lazy" "$sb"/data/nvim/lazy/lazy.nvim

extract() { # <fixture> <raw-spec output>
  rm -f "$sb"/config/nvim
  ln -s "$1" "$sb"/config/nvim
  env \
    XDG_CONFIG_HOME="$sb"/config \
    XDG_DATA_HOME="$sb"/data \
    XDG_STATE_HOME="$sb"/state \
    XDG_CACHE_HOME="$sb"/cache \
    NVIMX_LAZY_SEED="$lazy" \
    NVIMX_OUT="$2" \
    nvim --headless --cmd "luafile $extractLua"
}

extract "$defaultsConfig" "$sb"/defaults.json

# raw-spec: extract.lua's own contract, unaffected by #23's resolution
jq -e '.plugins["tokyonight.nvim"].version == "*"' "$sb"/defaults.json >/dev/null
jq -e '.plugins["plenary.nvim"].version == "*"' "$sb"/defaults.json >/dev/null
jq -e '.plugins["telescope.nvim"].version == "^0.1"' "$sb"/defaults.json >/dev/null
jq -e '.plugins["trouble.nvim"] | has("version") | not' "$sb"/defaults.json >/dev/null
jq -e '.plugins["trouble.nvim"].branch == "dev"' "$sb"/defaults.json >/dev/null
jq -e '.plugins["which-key.nvim"] | has("version") | not' "$sb"/defaults.json >/dev/null
jq -e '.plugins["which-key.nvim"].tag == "v3.0.0"' "$sb"/defaults.json >/dev/null
jq -e '.plugins["flash.nvim"] | has("version") | not' "$sb"/defaults.json >/dev/null
jq -e '.plugins["flash.nvim"].commit == "cbf1cb041a0e806c9f70e5b0b13d68f4dc26cfe8"' "$sb"/defaults.json >/dev/null
# false must not be folded into truthy and turned into "*" (a falsy check would pass this)
jq -e '.plugins["noice.nvim"].version == false' "$sb"/defaults.json >/dev/null

# `versionFromDefaults` (#23): present, and true, exactly on the plugins whose
# version came from `defaults.version` -- not on ones with their own `version`
# (telescope.nvim), and not on ones the default never reaches at all.
jq -e '.plugins["tokyonight.nvim"].versionFromDefaults == true' "$sb"/defaults.json >/dev/null
jq -e '.plugins["plenary.nvim"].versionFromDefaults == true' "$sb"/defaults.json >/dev/null
jq -e '.plugins["telescope.nvim"] | has("versionFromDefaults") | not' "$sb"/defaults.json >/dev/null
jq -e '.plugins["trouble.nvim"] | has("versionFromDefaults") | not' "$sb"/defaults.json >/dev/null
jq -e '.plugins["which-key.nvim"] | has("versionFromDefaults") | not' "$sb"/defaults.json >/dev/null
jq -e '.plugins["flash.nvim"] | has("versionFromDefaults") | not' "$sb"/defaults.json >/dev/null
jq -e '.plugins["noice.nvim"] | has("versionFromDefaults") | not' "$sb"/defaults.json >/dev/null

# plugins.json: the issue's "Done when" is about the lock, so resolve it too.
# A real ls-remote needs a real remote, and the sandbox has no network at all, so
# the three plugins that reach ls-remote are pointed at local git repos instead
# (the same offline approach checks.resolve-semver uses for its own coverage).
# plugins whose version never reaches the gate at all (trouble/which-key/flash/
# noice, via branch/tag/commit/false respectively) are untouched: if the gate ever
# regressed to let one of them through, ls-remote against their real (github) urls
# would fail here with no network, and the check would fail loudly instead of
# silently doing the wrong thing.
mkrepo "$sb"/tagged v1.0.0 v2.0.0
mkrepo "$sb"/untagged
mkrepo "$sb"/telescope 0.1.5 0.1.8
jq \
  --arg tagged "file://$sb/tagged" \
  --arg untagged "file://$sb/untagged" \
  --arg telescope "file://$sb/telescope" \
  '.plugins["plenary.nvim"].url = $tagged
   | .plugins["tokyonight.nvim"].url = $untagged
   | .plugins["telescope.nvim"].url = $telescope' \
  "$sb"/defaults.json >"$sb"/defaults-online.json
nvim -l "$lua"/resolve.lua "$sb"/defaults-online.json plugins.json \
  --lazy "$lazy" 2>resolve.log
cat resolve.log >&2

jq -e '.plugins["tokyonight.nvim"].version == "*"' plugins.json >/dev/null
# no tags on tokyonight.nvim's remote: a defaults-derived constraint falls back to
# HEAD rather than failing the lock (#42's goal 1, the reason this check exists,
# verified again now that #23 could have broken it)
jq -e '.plugins["tokyonight.nvim"].resolvedRef == null' plugins.json >/dev/null
jq -e '.plugins["plenary.nvim"].version == "*"' plugins.json >/dev/null
jq -e '.plugins["plenary.nvim"].resolvedRef == "refs/tags/v2.0.0"' plugins.json >/dev/null
jq -e '.plugins["telescope.nvim"].version == "^0.1"' plugins.json >/dev/null
jq -e '.plugins["telescope.nvim"].resolvedRef == "refs/tags/0.1.8"' plugins.json >/dev/null
jq -e '.plugins["noice.nvim"].version == null' plugins.json >/dev/null
jq -e '.plugins["trouble.nvim"].version == null' plugins.json >/dev/null
jq -e '.plugins["which-key.nvim"].version == null' plugins.json >/dev/null
jq -e '.plugins["flash.nvim"].version == null' plugins.json >/dev/null
jq -e '[.plugins[] | select(.version != null)] | length == 3' plugins.json >/dev/null
# the fallback must not show up as a per-plugin warning in the lock (§3.4.5 of the
# #23 plan) -- only as the aggregated stderr line checked below
jq -e '.warnings == []' plugins.json >/dev/null
grep -q 'follow the default branch' resolve.log

# defaults.version = false must be indistinguishable from "unset" (#42 goal 3)
extract "$defaultsFalseConfig" "$sb"/false.json
jq -e '.plugins["tokyonight.nvim"] | has("version") | not' "$sb"/false.json >/dev/null
jq -e '.plugins["telescope.nvim"].version == "^0.1"' "$sb"/false.json >/dev/null

touch "$out"
