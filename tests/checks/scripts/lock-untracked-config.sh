# shellcheck shell=bash disable=SC2154
# Body of checks.lock-untracked-config, sourced by the runCommand in ../lock-untracked-config.nix.
# $fx comes from that derivation's env.
export HOME=$TMPDIR
# Resolved the same way nvimx-lock resolves --config (darwin's /tmp is a symlink).
here=$(realpath .)
export NVIMX_STUB_LOCK=$fx/nvimx-lock/flake.lock
# `! grep -q` would be vacuous: a `!`-negated command never trips errexit.
absent() { # <pattern> <file>
  if grep -q -- "$1" "$2"; then
    echo "unexpected \"$1\" in $2" >&2
    exit 1
  fi
}
git_t() { git -c user.name=t -c user.email=t@t "$@"; }
# The lock must never touch the index: compared by content, since `status --porcelain`
# is polluted by the untracked lock dir the run itself creates.
lock() { # <log>
  git -C repo ls-files --stage >idx.before
  nvimx-lock --config repo/nvim --out repo/nvim/nvimx-lock 2>"$1"
  git -C repo ls-files --stage | diff -u idx.before -
}
cfg=$here/repo/nvim

# Setup: only init.lua and .gitignore are committed.
git init -q -b main repo
mkdir -p repo/nvim/lua/plugins
cat >repo/nvim/init.lua <<'LUA'
vim.opt.rtp:prepend(vim.fn.stdpath("data") .. "/lazy/lazy.nvim")
require("lazy").setup(require("plugins.extra"))
LUA
echo 'return { { "folke/tokyonight.nvim" } }' >repo/nvim/lua/plugins/extra.lua
echo notes >repo/nvim/notes.txt
echo 'nvim/ignored.lua' >repo/.gitignore
echo 'return {}' >repo/nvim/ignored.lua
git -C repo add nvim/init.lua .gitignore
git_t -C repo commit -q -m init

# 1. Untracked: still locked, and warned about (every file, not only Lua).
lock u.log
jq -e '.plugins["tokyonight.nvim"]' repo/nvim/nvimx-lock/plugins.json >/dev/null
grep -q '^nvimx-lock: warning: 2 file(s) under .* are not tracked by git\. nvimx-lock read them from your work tree.*manageConfig = true' u.log
grep -qxF 'nvimx-lock: warning:   lua/plugins/extra.lua' u.log
grep -qxF 'nvimx-lock: warning:   notes.txt' u.log
grep -qxF "nvimx-lock: warning:   git -C \"$cfg\" add -- lua/plugins/extra.lua notes.txt" u.log
# Anchored: the done line and #71's note legitimately contain "nvimx-lock/".
absent '^nvimx-lock: warning:   nvimx-lock/' u.log
absent 'ignored.lua' u.log
tail -n 1 u.log | grep -q "^nvimx-lock: note:"

# 2. Staged but not committed: a clean config prints nothing extra.
git -C repo add nvim/lua/plugins/extra.lua nvim/notes.txt nvim/nvimx-lock
lock s.log
absent '^nvimx-lock: warning:' s.log
absent 'not inside a git work tree' s.log
[ "$(tail -n 1 s.log)" = "nvimx-lock: done. commit $cfg/nvimx-lock/{plugins.json,flake.nix,flake.lock}" ]

# 3. Modified tracked file: nix reads the work tree for it, so no warning.
echo '-- touched' >>repo/nvim/init.lua
lock m.log
absent '^nvimx-lock: warning:' m.log

# 4a. A name with a space is shell-quoted in the add line.
mkdir "repo/nvim/lua/sp ace"
echo 'return {}' >"repo/nvim/lua/sp ace/x.lua"
lock q.log
grep -q '^nvimx-lock: warning: 1 file(s) under ' q.log
grep -qxF 'nvimx-lock: warning:   lua/sp ace/x.lua' q.log
grep -qxF "nvimx-lock: warning:   git -C \"$cfg\" add -- lua/sp\\ ace/x.lua" q.log

# 4b. 26 untracked files: 20 listed, the rest counted, and a catch-all add.
mkdir repo/nvim/many
for i in $(seq -w 1 25); do echo 'return {}' >"repo/nvim/many/f$i.lua"; done
lock c.log
grep -q '^nvimx-lock: warning: 26 file(s) under ' c.log
[ "$(grep -c '^nvimx-lock: warning:   [^.g]' c.log)" -eq 20 ]
grep -qxF "nvimx-lock: warning:   ... and 6 more (git -C \"$cfg\" status --untracked-files=all)" c.log
grep -qxF "nvimx-lock: warning:   git -C \"$cfg\" add -- ." c.log
rm -rf "repo/nvim/lua/sp ace" repo/nvim/many

# 5. Not a git work tree: one neutral line, still exit 0.
cp -r "$fx" plain
chmod -R u+w plain
nvimx-lock --config plain --out plain-out 2>plain.log
[ "$(grep -c 'is not inside a git work tree' plain.log)" -eq 1 ]
absent '^nvimx-lock: warning:' plain.log

# 6. A bare repository is not a work tree either.
git init -q --bare bare.git
cp -r "$fx"/. bare.git/cfg
chmod -R u+w bare.git/cfg
nvimx-lock --config bare.git/cfg --out bare-out 2>bare.log
[ "$(grep -c 'is not inside a git work tree' bare.log)" -eq 1 ]

touch "$out"
