# shellcheck shell=bash disable=SC2154
# Body of checks.rplugin-manifest, sourced by the runCommand in ../rplugin-manifest.nix.
# The *Manifest / *Plugin / *Wrapped variables come from that derivation's env.
export HOME=$TMPDIR

# --- the manifest's content ---
# The plugin's resolved store path, not <farm>/<name>: that is what a user's own
# :UpdateRemotePlugins records too.
py="$v2Plugin/rplugin/python3/nvimx_rplugin_test.py"
grep -qF "RegisterPlugin('python3', '$py'" "$v2Manifest"
for spec in NvimxRpluginTest NvimxRpluginCmd NvimxRpluginPing; do
  grep -q "$spec" "$v2Manifest"
done
# A plugin that fails to register is left out and named, and the build still went green.
if grep -v '^"' "$v2Manifest" | grep -q nvimx_rplugin_broken; then
  echo "a plugin that cannot load was registered" >&2
  exit 1
fi
grep -q '^" not registered: .*nvimx_rplugin_broken.py' "$v2Manifest"
# Hosts that are not on never see their plugins.
if grep -q 'rplugin/node\|rplugin/ruby' "$v2Manifest"; then
  echo "a python3-only manifest names a node or ruby plugin" >&2
  exit 1
fi
# devPlugins are left to :UpdateRemotePlugins.
if grep -q RegisterPlugin "$devManifest"; then
  echo "a dev plugin was registered by the build" >&2
  exit 1
fi
# Both directions, because a failing plugin does not fail the build: only this turns red when
# node's PATH (runtimeDeps) stops reaching generation.
grep -q "RegisterPlugin('node', '.*/rplugin/node/nvimx_rplugin_node.js'" "$multiManifest"
grep -q NvimxRpluginNode "$multiManifest"
grep -q "RegisterPlugin('ruby', '.*/rplugin/ruby/nvimx_rplugin_ruby.rb'" "$multiManifest"
grep -q NvimxRpluginRuby "$multiManifest"
if grep '^" not registered' "$multiManifest" | grep -q 'rplugin/node\|rplugin/ruby'; then
  echo "a node or ruby plugin did not register" >&2
  exit 1
fi

# null and false: nothing of this is in the wrapper (test -f first, so grep -q cannot pass on a
# missing file).
for w in "$untouchedWrapped" "$offWrapped"; do
  test -f "$w/bin/nvim"
  if grep -q rplugin "$w/bin/nvim"; then
    echo "$w mentions rplugin with no provider turned on" >&2
    exit 1
  fi
done
rc=$(grep -o '/nix/store/[^ ]*nvimx-providers.lua' "$offWrapped/bin/nvim" | head -n1)
test -f "$rc"
if grep -q rplugin "$rc"; then
  echo "the providers rc mentions rplugin with every host false" >&2
  exit 1
fi

# --- the controls for the upstream runs ---
grep -q "$upstreamRuntime" "$upstreamNeovim/bin/nvim"
# B needs the old plugin to still exist: a manifest naming it is not enough for the collision.
test -d "$v1Plugin/rplugin"

# A dev plugin as a user's manifest records it, working tree outside the store.
mkdir -p dev/rplugin/python3
cat >dev/rplugin/python3/nvimx_rplugin_dev.py <<'PY'
import pynvim


@pynvim.plugin
class NvimxRpluginDev(object):
    def __init__(self, nvim):
        self.nvim = nvim

    @pynvim.function("NvimxRpluginDev", sync=True)
    def dev(self, args):
        return "dev"
PY

fresh_home() {
  HOME=$(mktemp -d)
  export HOME
  mkdir -p "$HOME/.local/share/nvim"
}
run() { # <wrapper> <nvim args...>
  local w=$1
  shift
  timeout 300 "$w/bin/nvim" "$@"
}

for w in "$v2Wrapped" "$v2uWrapped"; do
  # A: fresh
  fresh_home
  run "$w" -u "$initLua" -l "$driver" run v2

  # B: after a plugin update, with the previous version's manifest and a dev plugin in it
  fresh_home
  cp "$v1Manifest" "$HOME/.local/share/nvim/rplugin.vim"
  chmod u+w "$HOME/.local/share/nvim/rplugin.vim"
  cat >>"$HOME/.local/share/nvim/rplugin.vim" <<VIM
call remote#host#RegisterPlugin('python3', '$PWD/dev/rplugin/python3/nvimx_rplugin_dev.py', [
      \ {'sync': v:true, 'name': 'NvimxRpluginDev', 'type': 'function', 'opts': {}},
     \ ])
VIM
  run "$w" -u "$initLua" -l "$driver" run v2 NvimxRpluginDev

  # C: the user's manifest names the same paths
  fresh_home
  cp "$v2Manifest" "$HOME/.local/share/nvim/rplugin.vim"
  chmod u+w "$HOME/.local/share/nvim/rplugin.vim"
  run "$w" -u "$initLua" -l "$driver" run v2

  # E: --clean
  fresh_home
  run "$w" --clean -l "$driver" absent

  # F: rplugin disabled with g:loaded_remote_plugins
  fresh_home
  run "$w" --cmd 'let g:loaded_remote_plugins = 1' -u "$initLua" -l "$driver" absent
done

# G: ruby and node at run time
fresh_home
run "$multiWrapped" -u "$initLua" -l "$driver" hosts

touch "$out"
