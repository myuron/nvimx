# shellcheck shell=bash disable=SC2154
# Body of checks.extractor-dev-opts, sourced by the runCommand in ../extractor-dev-opts.nix.
# $devOptsConfig $devOptsFallbackConfig $devOptsDefaultsConfig $lazy $extractLua $lua come from
# that derivation's env.
export HOME=$TMPDIR
sb=$TMPDIR/sandbox
mkdir -p "$sb"/config "$sb"/data/nvim/lazy "$sb"/state "$sb"/cache
# Makes each fixture's lazypath fs_stat succeed, so its bootstrap snippet never reaches `git clone`.
ln -s "$lazy" "$sb"/data/nvim/lazy/lazy.nvim

# extract <fixture dir> <out json>
extract() {
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

# (1) patterns + path, no fallback: both clauses, one line, and the lock-time effect it describes.
extract "$devOptsConfig" "$sb"/raw.json
jq -e '[.notifs[] | select(.msg | startswith("lazy.nvim'"'"'s dev settings"))] | length == 1' \
  "$sb"/raw.json >/dev/null
for tok in 'dev.patterns' 'programs.nvimx.devPatterns' 'dev.path' 'programs.nvimx.devPath'; do
  jq -e --arg t "$tok" '.notifs[] | select(.msg | startswith("lazy.nvim'"'"'s dev settings")) | .msg | contains($t)' \
    "$sb"/raw.json >/dev/null
done
jq -e '.notifs[] | select(.msg | startswith("lazy.nvim'"'"'s dev settings")) | .msg | contains("dev.fallback is ignored") | not' \
  "$sb"/raw.json >/dev/null
jq -e '.notifs[] | select(.msg | startswith("lazy.nvim'"'"'s dev settings")) | .msg | contains("\n") | not' \
  "$sb"/raw.json >/dev/null

nvim -l "$lua"/resolve.lua "$sb"/raw.json plugins.json --lazy "$lazy" 2>stderr.log
[ "$(grep -c "^\[nvimx\] warning: lazy.nvim's dev settings.*dev\.patterns.*dev\.path" stderr.log)" -eq 1 ]
jq -e '.warnings | any(test("dev\\.patterns"))' plugins.json >/dev/null
# Matched plugins leave the lock; this is what the patterns clause tells the user.
jq -e '.localPlugins | has("tokyonight.nvim")' plugins.json >/dev/null
jq -e '.plugins == {}' plugins.json >/dev/null

# (2) patterns + fallback: only matched plugins whose checkout exists leave the lock, and with no
#     checkout under the sandbox $HOME this one reverts to a remote.
extract "$devOptsFallbackConfig" "$sb"/raw-fallback.json
jq -e '[.notifs[] | select(.msg | startswith("lazy.nvim'"'"'s dev settings"))] | length == 1' \
  "$sb"/raw-fallback.json >/dev/null
for tok in 'dev.patterns' 'dev.fallback' 'only those whose checkout exists'; do
  jq -e --arg t "$tok" '.notifs[] | select(.msg | startswith("lazy.nvim'"'"'s dev settings")) | .msg | contains($t)' \
    "$sb"/raw-fallback.json >/dev/null
done
jq -e '.notifs[] | select(.msg | startswith("lazy.nvim'"'"'s dev settings")) | .msg | (contains("dev.path is ignored") or contains("\n")) | not' \
  "$sb"/raw-fallback.json >/dev/null
jq -e '.plugins["tokyonight.nvim"] | (.dev == null and .dir == null)' "$sb"/raw-fallback.json >/dev/null

# (3) lazy's defaults written out explicitly do not count.
extract "$devOptsDefaultsConfig" "$sb"/raw-defaults.json
jq -e '[.notifs[] | select(.msg | startswith("lazy.nvim'"'"'s dev settings"))] | length == 0' \
  "$sb"/raw-defaults.json >/dev/null

touch "$out"
