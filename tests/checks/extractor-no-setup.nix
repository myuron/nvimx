# A config that never calls lazy.setup must not hang; it must exit non-zero with a clear error (#3)
{
  pkgs,
  lazy-nvim,
  ...
}:
pkgs.runCommand "extractor-no-setup"
  {
    nativeBuildInputs = [
      pkgs.neovim-unwrapped
      # timeout is not on PATH inside the darwin sandbox, so pull it in explicitly
      pkgs.coreutils
    ];
  }
  ''
    export HOME=$TMPDIR
    sb=$TMPDIR/sandbox
    mkdir -p $sb/config $sb/data/nvim/lazy $sb/state $sb/cache
    ln -s ${../fixtures/empty-config} $sb/config/nvim
    ln -s ${lazy-nvim} $sb/data/nvim/lazy/lazy.nvim
    rc=0
    env \
      XDG_CONFIG_HOME=$sb/config \
      XDG_DATA_HOME=$sb/data \
      XDG_STATE_HOME=$sb/state \
      XDG_CACHE_HOME=$sb/cache \
      NVIMX_LAZY_SEED=${lazy-nvim} \
      NVIMX_OUT=$sb/raw-spec.json \
      timeout 60 nvim --headless --cmd "luafile ${../../lua/nvimx/extract.lua}" \
      2> stderr.log < /dev/null || rc=$?
    cat stderr.log >&2
    if [ "$rc" -eq 0 ] || [ "$rc" -eq 124 ]; then
      echo "expected fast non-zero exit, got rc=$rc" >&2
      exit 1
    fi
    grep -q 'did not call require("lazy").setup' stderr.log
    touch $out
  ''
