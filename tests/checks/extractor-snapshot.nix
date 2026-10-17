# Snapshot comparison of the extraction result for a fixture config.
# Everything is self-contained in the store (fixture + seed + neovim), so no network is needed.
{
  pkgs,
  lazy-nvim,
  ...
}:
pkgs.runCommand "extractor-snapshot"
  {
    nativeBuildInputs = [
      pkgs.neovim-unwrapped
      pkgs.jq
    ];
  }
  ''
    export HOME=$TMPDIR
    sb=$TMPDIR/sandbox
    mkdir -p $sb/config $sb/data/nvim/lazy $sb/state $sb/cache
    ln -s ${../fixtures/basic-config} $sb/config/nvim
    ln -s ${lazy-nvim} $sb/data/nvim/lazy/lazy.nvim
    env \
      XDG_CONFIG_HOME=$sb/config \
      XDG_DATA_HOME=$sb/data \
      XDG_STATE_HOME=$sb/state \
      XDG_CACHE_HOME=$sb/cache \
      NVIMX_LAZY_SEED=${lazy-nvim} \
      NVIMX_OUT=$sb/raw-spec.json \
      nvim --headless --cmd "luafile ${../../lua/nvimx/extract.lua}"
    # lazyNvim.source contains a store path that changes when the seed is updated, so exclude it
    jq -S 'del(.lazyNvim)' $sb/raw-spec.json > got.json
    diff -u ${../fixtures/golden/basic-config.raw-spec.json} got.json
    touch $out
  ''
