# nvimx-lock: 抽出 → 解決 → flake 生成 → nix flake lock を一発実行するスクリプト。
# lock はオンライン操作 (build は完全 pure・オフライン)。
# TODO (Phase 6): --update [name...], --import-lazy-lock
{ pkgs, lazyNvimSeed }:
let
  luaDir = ../../lua/nvimx;
in
pkgs.writeShellApplication {
  name = "nvimx-lock";
  runtimeInputs = [
    pkgs.coreutils
    pkgs.neovim-unwrapped
    pkgs.nixfmt-rfc-style
  ];
  text = ''
    usage() {
      echo "usage: nvimx-lock --config <configDir> --out <lockDir>" >&2
      exit 2
    }

    config=""
    out=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --config)
          config="$2"
          shift 2
          ;;
        --out)
          out="$2"
          shift 2
          ;;
        *)
          usage
          ;;
      esac
    done
    [ -n "$config" ] && [ -n "$out" ] || usage
    config=$(realpath "$config")
    mkdir -p "$out"
    out=$(realpath "$out")

    # TODO: 既存 lock に lazy.nvim の pin があればそれをシードに使う (skew 対策)。
    # 現状は nvimx 自身の flake input を常にシードにする。
    seed="${lazyNvimSeed}"

    sandbox=$(mktemp -d)
    trap 'rm -rf "$sandbox"' EXIT
    mkdir -p "$sandbox/config" "$sandbox/data/nvim/lazy" "$sandbox/state" "$sandbox/cache"
    ln -sfT "$config" "$sandbox/config/nvim"
    ln -sfT "$seed" "$sandbox/data/nvim/lazy/lazy.nvim"

    echo "nvimx-lock: extracting spec from $config" >&2
    env \
      XDG_CONFIG_HOME="$sandbox/config" \
      XDG_DATA_HOME="$sandbox/data" \
      XDG_STATE_HOME="$sandbox/state" \
      XDG_CACHE_HOME="$sandbox/cache" \
      NVIMX_LAZY_SEED="$seed" \
      NVIMX_OUT="$sandbox/raw-spec.json" \
      nvim --headless --cmd "luafile ${luaDir}/extract.lua"

    echo "nvimx-lock: resolving plugins" >&2
    nvim -l "${luaDir}/resolve.lua" "$sandbox/raw-spec.json" "$out/plugins.json"

    echo "nvimx-lock: generating lock flake" >&2
    nvim -l "${luaDir}/genflake.lua" "$out/plugins.json" "$out/flake.nix"
    nixfmt "$out/flake.nix"

    echo "nvimx-lock: pinning with nix flake lock" >&2
    (cd "$out" && nix flake lock)

    echo "nvimx-lock: done. commit $out/{plugins.json,flake.nix,flake.lock}" >&2
  '';
}
