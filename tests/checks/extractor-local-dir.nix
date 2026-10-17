# #47: a spec plugin with an explicit `dir` and no `dev`. lazy treats that exactly like a
# `dev = true` one -- Meta:_rebuild short-circuits on any dir the spec wrote
# (lua/lazy/core/meta.lua:216-217), and get_target returns at its very first branch
# (lua/lazy/manage/git.lua:118-123), before commit / tag / defaults.version are consulted
# at all -- but extract.lua used to record `dir` only for dev plugins, so resolve.lua
# filed it as an ordinary remote: an inputName, a github source, a flake input and a farm
# entry, for a plugin the user keeps in a working tree. Since #42 materializes
# defaults.version per plugin, it also picked up a constraint that #23 then resolves for
# real -- measured, that means a git ls-remote against github.com for a plugin on the
# user's own disk, and a failed lock when no tag matches.
#
# This check starts from a real config rather than a hand-written raw-spec because the
# fact that makes the obvious fix wrong is lazy's, not nvimx's: lazy fills in plugin.dir
# for *every* plugin (meta.lua:238 falls back to <root>/<name>), so `dir = p.dir` would
# route the whole spec into localPlugins and leave `plugins` empty -- silently, exit 0.
# extract.lua tests the prefix meta.lua:238 itself builds, which is the same axis lazy
# judges _.is_local on (plugin.lua:244-252) -- close to it, not identical to it, since
# extraction runs against a sandbox root rather than the user's (see extract.lua's own
# comment on local_dir).
#
# Deliberately without pkgs.git and without --lazy, so that "the resolve exits 0" is
# itself the assertion -- the same trick checks.resolve-import-lazy-lock uses. Filing any
# of the fixture's local plugins as remote kills the resolve one of two ways: dirnoname
# has no url at all (source.parse rejects it), and the other five carry a materialized
# defaults.version that fires #23's gate with no --lazy to satisfy it. Today it is always
# the first, since report_resolve_errors() runs before the fail() for a missing --lazy.
# Step 1 asserts the version constraints exist so the second route stays a fact about
# this fixture rather than an assumption this comment quietly outlives.
# The dev/dir *consumer* side (devDirs, and lazy ignoring them at runtime) is
# checks.dev-plugins' (#26); the import report's classification matrix is
# checks.resolve-import-lazy-lock's (#25), which gets this issue's one case added to it.
{
  pkgs,
  lazy-nvim,
  ...
}:
pkgs.runCommand "extractor-local-dir" {
  nativeBuildInputs = [
    pkgs.neovim-unwrapped
    pkgs.jq
  ];
  localDirConfig = ../fixtures/local-dir-config;
  lazy = lazy-nvim;
  extractLua = ../../lua/nvimx/extract.lua;
  lua = ../../lua/nvimx;
} "source ${./scripts/extractor-local-dir.sh}"
