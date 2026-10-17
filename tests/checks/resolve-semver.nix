# Offline, end-to-end coverage of semver resolution (#23): git ls-remote against local
# repos this check creates itself, so no network is needed and no fixture ever names a
# real, reachable remote. Destructive steps (removing a repo to prove a carried ref
# needs no further network access) are kept last, since several earlier steps still need
# those repos alive.
{
  pkgs,
  lazy-nvim,
  mkTagRepoSh,
  ...
}:
pkgs.runCommand "resolve-semver"
  {
    nativeBuildInputs = [
      pkgs.neovim-unwrapped
      pkgs.jq
      pkgs.git
    ];
  }
  (
    mkTagRepoSh
    + ''
      export HOME=$TMPDIR
      lua=${../../lua/nvimx}
      fx=${../fixtures/semver}
      lazy=${lazy-nvim}
      sb=$TMPDIR/sandbox

      # 1. Three remotes: tagged (a real tag set to resolve against), untagged (a real
      # remote with zero tags -- classification B), and a small one just for the E2E
      # step's telescope.nvim dependency.
      mkrepo $sb/tagged v1.0.0 v1.2.0 v1.2.5 v2.0.0 v2.1.0-beta stable
      mkrepo $sb/untagged
      mkrepo $sb/telescope 0.1.5 0.1.8

      # 2. Explicit constraint, success path. gh.nvim has no `version` at all (a github
      # type plugin), proving the gate does not send it to ls-remote regardless of type.
      jq --arg u "file://$sb/tagged" \
        '.plugins["tagged.nvim"].url = $u | .plugins["pinned.nvim"].url = $u' \
        $fx/raw-spec-explicit.json > explicit.json
      nvim -l $lua/resolve.lua explicit.json out-explicit.json --lazy $lazy 2> explicit.log
      if [ -s explicit.log ]; then
        echo "an explicit constraint that resolves cleanly must not warn, got:" >&2
        cat explicit.log >&2
        exit 1
      fi
      jq -e '.plugins["tagged.nvim"].resolvedRef == "refs/tags/v1.2.5"' out-explicit.json > /dev/null
      jq -e '.warnings == []' out-explicit.json > /dev/null
      jq -e '.plugins["gh.nvim"].source.type == "github"' out-explicit.json > /dev/null
      jq -e '.plugins["gh.nvim"].version == null' out-explicit.json > /dev/null
      jq -e '.plugins["gh.nvim"].resolvedRef == null' out-explicit.json > /dev/null
      # 13(a). pinned.nvim resolves exactly the same way on its first lock, and the
      # "pin wins" warning does not fire -- the constraint really was validated.
      jq -e '.plugins["pinned.nvim"].resolvedRef == "refs/tags/v1.2.5"' out-explicit.json > /dev/null

      # 3. The resolved tag reaches the generated flake's input URL.
      nvim -l $lua/genflake.lua out-explicit.json flake-explicit.nix
      grep -q 'ref=refs/tags/v1.2.5' flake-explicit.nix

      # 4. Editing the constraint re-resolves against the same remote (spec identity
      # includes `version`; tests/fixtures/merge's coverage of this fact is metadata-only,
      # this is the semver-constrained case). $sb/tagged must stay alive for this.
      jq --arg u "file://$sb/tagged" \
        '.plugins["tagged.nvim"].url = $u | .plugins["pinned.nvim"].url = $u
         | .plugins["tagged.nvim"].version = "~1.0"' \
        $fx/raw-spec-explicit.json > step4.json
      nvim -l $lua/resolve.lua step4.json out-step4.json --prev out-explicit.json --lazy $lazy \
        2> /dev/null
      jq -e '.plugins["tagged.nvim"].resolvedRef == "refs/tags/v1.0.0"' out-step4.json > /dev/null

      # 5. --prev carries an already-resolved tag ref forward with no ls-remote at all --
      # proven by rewriting it to a value ls-remote could never have produced right now
      # ("^1.2" no longer resolves to v1.0.0) and checking that value survives untouched.
      jq '.plugins["tagged.nvim"].resolvedRef = "refs/tags/v1.0.0"' out-explicit.json > prev-step5.json
      nvim -l $lua/resolve.lua explicit.json out-step5.json --prev prev-step5.json --lazy $lazy \
        2> /dev/null
      jq -e '.plugins["tagged.nvim"].resolvedRef == "refs/tags/v1.0.0"' out-step5.json > /dev/null

      # 6. Classification A: an explicit constraint no tag on a real (if local) remote
      # satisfies is fatal, with the plugin name, constraint, url and candidate tags.
      jq --arg u "file://$sb/tagged" \
        '.plugins["tagged.nvim"].url = $u | .plugins["pinned.nvim"].url = $u
         | .plugins["tagged.nvim"].version = "^9"' \
        $fx/raw-spec-explicit.json > step6.json
      rc=0
      nvim -l $lua/resolve.lua step6.json out-step6.json --lazy $lazy 2> step6.log || rc=$?
      if [ "$rc" -eq 0 ]; then
        echo "an unsatisfiable explicit constraint must fail the lock" >&2
        exit 1
      fi
      [ ! -e out-step6.json ]
      grep -q 'plugin "tagged.nvim"' step6.log
      grep -q 'no tag matches version constraint "\^9"' step6.log
      grep -q 'newest' step6.log

      # 7. Classification B: an explicit constraint on a remote with no tags at all.
      jq --arg u "file://$sb/untagged" '.plugins["untagged.nvim"].url = $u' \
        $fx/raw-spec-explicit-untagged.json > step7.json
      rc=0
      nvim -l $lua/resolve.lua step7.json out-step7.json --lazy $lazy 2> step7.log || rc=$?
      if [ "$rc" -eq 0 ]; then
        echo "an explicit constraint on a tagless remote must fail the lock" >&2
        exit 1
      fi
      grep -q 'the remote has no tags' step7.log

      # 8. Classification C: git ls-remote itself fails (bad url), fatal regardless of
      # where the constraint came from.
      jq '.plugins["untagged.nvim"].url = "file:///nvimx-nonexistent/step8"' \
        $fx/raw-spec-explicit-untagged.json > step8.json
      rc=0
      nvim -l $lua/resolve.lua step8.json out-step8.json --lazy $lazy 2> step8.log || rc=$?
      if [ "$rc" -eq 0 ]; then
        echo "a git ls-remote failure must fail the lock" >&2
        exit 1
      fi
      grep -q 'git ls-remote failed' step8.log

      # 9. Classification D: a constraint lazy.manage.semver cannot parse must be caught
      # before ls-remote -- the url is unreachable, so if D were detected after the fetch
      # this would report classification C's message instead.
      rc=0
      nvim -l $lua/resolve.lua $fx/raw-spec-badrange.json out-step9.json --lazy $lazy \
        2> step9.log || rc=$?
      if [ "$rc" -eq 0 ]; then
        echo "an unparseable constraint must fail the lock" >&2
        exit 1
      fi
      grep -q 'not valid lazy.nvim semver syntax' step9.log
      if grep -q 'git ls-remote failed' step9.log; then
        echo "classification D must be decided before any network access" >&2
        exit 1
      fi

      # 10. A defaults.version-derived constraint falls back to HEAD instead of failing
      # the lock, on the very same remotes step 6/7 just proved are fatal for an explicit
      # constraint -- the contrast is the point (§3.4 of the plan).
      jq --arg t "file://$sb/tagged" --arg u "file://$sb/untagged" \
        '.plugins["tagged.nvim"].url = $t | .plugins["untagged.nvim"].url = $u' \
        $fx/raw-spec-defaults.json > step10.json
      nvim -l $lua/resolve.lua step10.json out-step10.json --lazy $lazy 2> step10.log
      jq -e '.plugins["untagged.nvim"].resolvedRef == null' out-step10.json > /dev/null
      jq -e '.plugins["tagged.nvim"].resolvedRef == "refs/tags/v2.0.0"' out-step10.json > /dev/null
      jq -e '.warnings == []' out-step10.json > /dev/null
      grep -q 'follow the default branch' step10.log

      # 11. The fallback survives a second pass byte-identically, with the same
      # aggregated report -- this is what makes overwriting nvimx-lock's first-pass log
      # with the second one safe for a defaults.version fallback, the same way it already
      # is for a pin (checks.resolve-merge's out9a/out9b).
      nvim -l $lua/resolve.lua step10.json out-step11.json --prev out-step10.json --lazy $lazy \
        2> step11.log
      cmp out-step10.json out-step11.json
      diff -u step10.log step11.log

      # 12. The gate: none of `tag` / `commit` / `version = false` may reach ls-remote,
      # against urls that do not exist -- if the gate regressed, this would fail with
      # classification C instead of quietly doing the right thing. No --lazy: nothing is
      # pending, so it must not be required (see step 15).
      nvim -l $lua/resolve.lua $fx/raw-spec-gate.json out-step12.json 2> step12.log
      jq -e '.plugins["tag-and-version.nvim"].resolvedRef == null' out-step12.json > /dev/null
      jq -e '.plugins["commit-and-version.nvim"].resolvedRef == null' out-step12.json > /dev/null
      jq -e '.plugins["version-false.nvim"].resolvedRef == null' out-step12.json > /dev/null
      if [ -s step12.log ]; then
        echo "the gate must not touch a nonexistent remote nor warn, got:" >&2
        cat step12.log >&2
        exit 1
      fi

      # 13(b). A prev freeze (pin = true, resolved on an earlier lock) wins over semver
      # resolution before any ls-remote happens: the url is a nonexistent path, so if the
      # freeze did not win first, this would fail with classification C.
      nvim -l $lua/resolve.lua $fx/raw-spec-pinned-frozen.json out-step13b.json \
        --prev $fx/prev-pinned-unresolved.json --lock $fx/flake.lock --lazy $lazy \
        2> step13b.log
      jq -e '.plugins["pinned.nvim"].resolvedRef
             == "cccccccccccccccccccccccccccccccccccccccc"' out-step13b.json > /dev/null
      grep -q 'pinned; version constraint "\^1.2" is not validated (pin wins)' step13b.log
      if grep -q 'git ls-remote failed' step13b.log; then
        echo "a prev freeze must win before any ls-remote is attempted" >&2
        exit 1
      fi

      # 14. E2E: a real extractor run, through to a real (local) resolution.
      sb2=$TMPDIR/sandbox2
      mkdir -p $sb2/config $sb2/data/nvim/lazy $sb2/state $sb2/cache
      ln -s ${../fixtures/merge-config} $sb2/config/nvim
      ln -s $lazy $sb2/data/nvim/lazy/lazy.nvim
      env \
        XDG_CONFIG_HOME=$sb2/config \
        XDG_DATA_HOME=$sb2/data \
        XDG_STATE_HOME=$sb2/state \
        XDG_CACHE_HOME=$sb2/cache \
        NVIMX_LAZY_SEED=$lazy \
        NVIMX_OUT=$sb2/raw-spec.json \
        nvim --headless --cmd "luafile $lua/extract.lua"
      jq -e '.plugins["telescope.nvim"].version == "^0.1"' $sb2/raw-spec.json > /dev/null
      jq --arg u "file://$sb/telescope" '.plugins["telescope.nvim"].url = $u' \
        $sb2/raw-spec.json > $sb2/raw-spec-patched.json
      nvim -l $lua/resolve.lua $sb2/raw-spec-patched.json out-step14.json --lazy $lazy \
        2> step14.log
      jq -e '.plugins["telescope.nvim"].resolvedRef == "refs/tags/0.1.8"' out-step14.json > /dev/null

      # 15. --lazy is required exactly when something is pending, not unconditionally.
      rc=0
      nvim -l $lua/resolve.lua explicit.json out-step15.json 2> step15.log || rc=$?
      if [ "$rc" -eq 0 ]; then
        echo "resolving a pending version constraint without --lazy must fail" >&2
        exit 1
      fi
      grep -q -- '--lazy' step15.log
      # ...and the converse: nothing pending needs no --lazy at all (step 12 already
      # relies on this; repeated here so both halves of the contract sit together).
      nvim -l $lua/resolve.lua $fx/raw-spec-gate.json out-step15b.json 2> step15b.log

      # 16. Destructive (kept last): a fully carried tag ref needs no further network
      # access at all, even once the remote it originally came from is gone -- this is
      # what makes the second nvimx-lock pass, and every unrelated re-lock afterwards,
      # network-free (#18's identity contract). Not repeated for the defaults-fallback
      # case (out-step10.json): its resolvedRef stays null on purpose, so it is
      # re-queried on every run, and would legitimately fail once the remote is gone.
      rm -rf $sb/tagged $sb/untagged
      nvim -l $lua/resolve.lua explicit.json out-step16.json --prev out-explicit.json \
        --lazy $lazy 2> step16.log
      cmp out-explicit.json out-step16.json
      if [ -s step16.log ]; then
        echo "a fully carried resolve must not touch the network nor warn, got:" >&2
        cat step16.log >&2
        exit 1
      fi

      touch $out
    ''
  )
