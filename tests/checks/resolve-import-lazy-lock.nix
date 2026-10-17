# Offline coverage of `--import-lazy-lock` (#25). Deliberately without pkgs.git:
# resolve.lua's semver path fails outright when git is not on PATH, so "the resolve
# exits 0" is itself the proof that a seeded resolvedRef closed #23's gate and no
# ls-remote was ever attempted. Every fixture url is unreachable on top of that, for the
# same reason. --lazy is never passed either, which is the other half of the same
# statement: a migrating config needs neither.
{
  pkgs,
  nvimxLib,
  lazy-nvim,
  ...
}:
pkgs.runCommand "resolve-import-lazy-lock"
  {
    nativeBuildInputs = [
      pkgs.neovim-unwrapped
      pkgs.jq
      nvimxLib.lockApp
    ];
  }
  ''
    export HOME=$TMPDIR
    lua=${../../lua/nvimx}
    fx=${../fixtures/import-lazy-lock}

    # 1. golden + exact pin. stdout is also captured (used by step 2 below): the
    # progress line resolve.lua prints when it actually resolves a version constraint
    # goes to stdout, not stderr, on purpose (#22) -- see the io.stdout:write next to
    # resolve.lua's "resolving version constraints" message.
    nvim -l $lua/resolve.lua $fx/raw-spec.json out1.json \
      --import-lazy-lock $fx/lazy-lock.json \
      > out1.out 2> out1.log
    diff -u $fx/golden/imported.plugins.json out1.json
    # Independent of the golden file: read lazy-lock.json's own commits with jq and
    # compare them one by one against what actually landed in resolvedRef, so a wrong
    # golden could not paper over a wrong implementation.
    for n in plain.nvim git.nvim ver.nvim defver.nvim tag.nvim pinned.nvim; do
      want=$(jq -r --arg n "$n" '.[$n].commit' $fx/lazy-lock.json)
      got=$(jq -r --arg n "$n" '.plugins[$n].resolvedRef' out1.json)
      [ "$want" = "$got" ]
    done

    # 2. #23's gate never fired: primarily proven by step 1 exiting 0 at all (no git on
    # PATH and every url unreachable means any ls-remote attempt is fatal). These greps
    # are a belt-and-suspenders check on top of that, on the right stream this time.
    if grep -q 'resolving version constraints' out1.out; then
      echo "a seeded resolvedRef must close #23's gate before it ever queues ls-remote" >&2
      exit 1
    fi
    if grep -q 'ls-remote' out1.log; then
      echo "no ls-remote should ever run in this offline check" >&2
      exit 1
    fi

    # 3. The import's own report never leaks into plugins.json's warnings array.
    jq -e '.warnings == []' out1.json > /dev/null

    # 4. Seed exclusion: a spec that already fixes `commit`, a branch mismatch, and a
    # local (dev/dir) plugin all keep resolvedRef null, and commit.nvim's own spec
    # `commit` is untouched.
    jq -e '.plugins["commit.nvim"].resolvedRef == null' out1.json > /dev/null
    jq -e '.plugins["branchy.nvim"].resolvedRef == null' out1.json > /dev/null
    jq -e '.plugins["only-here.nvim"].resolvedRef == null' out1.json > /dev/null
    jq -e '.plugins["commit.nvim"].commit
           == "dddddddddddddddddddddddddddddddddddddddd"' out1.json > /dev/null

    # 5. The seeded refs reach genflake's generated input URLs, in exactly the forms
    # §7 of the plan predicts (github wins outright; git type combines ref and rev when
    # the spec also names a tag; a spec `commit` beats any seed).
    nvim -l $lua/genflake.lua out1.json flake1.nix
    grep -qF \
      'url = "github:o/plain.nvim/7777777777777777777777777777777777777777";' flake1.nix
    grep -qF \
      'url = "git+file:///nvimx-nonexistent/git.nvim?ref=main&rev=4444444444444444444444444444444444444444";' \
      flake1.nix
    grep -qF \
      'url = "git+file:///nvimx-nonexistent/tag.nvim?ref=refs/tags/v1.0.0&rev=2222222222222222222222222222222222222222";' \
      flake1.nix
    grep -qF \
      'url = "git+file:///nvimx-nonexistent/commit.nvim?rev=dddddddddddddddddddddddddddddddddddddddd";' \
      flake1.nix

    # 6. Every reporting classification, and nothing unaccounted for.
    grep -q '^\[nvimx\] import: pinned plain.nvim to 777777777777$' out1.log
    grep -q 'import: skipped commit.nvim: the spec already fixes commit dddddddddddd (lazy-lock.json has 555555555555)$' \
      out1.log
    grep -q 'import: skipped branchy.nvim: the spec is on branch "master" but lazy-lock.json recorded "main"$' \
      out1.log
    grep -q 'import: skipped local.nvim: it is a local plugin' out1.log
    grep -q 'import: only-here.nvim is not in lazy-lock.json; it will resolve normally$' out1.log
    grep -q 'import: ignored disabled-me.nvim (disabled in the config)$' out1.log
    grep -q 'import: ignored ghost.nvim (not in the config)$' out1.log
    grep -q 'import: ignored git-nvim (not in the config; did you mean "git.nvim"?)$' out1.log
    grep -q 'import: lazy.nvim itself is not imported' out1.log
    grep -q 'import: invalid entry badsha.nvim in lazy-lock.json: commit "not-a-sha" is not a 40-hex sha$' \
      out1.log
    grep -q 'import: invalid entry nullentry.nvim in lazy-lock.json: value is not an object$' out1.log
    grep -q 'import: version constraint "\^1.2" is not validated for 1 plugin(s) pinned from lazy-lock.json' \
      out1.log
    # defver.nvim's constraint comes from `defaults.version` (versionFromDefaults =
    # true), so its message uses the "the config-wide ..." phrasing resolve.lua's
    # pin+version warning already established -- not the plain "version
    # constraint" ver.nvim gets above (an explicit `version`). The plan's own sketch of
    # this grep omitted "the config-wide " and so never actually matched; fixed here to
    # check the real, correct message instead of weakening it to fit the typo.
    grep -q 'import: the config-wide version constraint "\*" is not validated for 1 plugin(s) pinned from lazy-lock.json' \
      out1.log
    grep -q 'import: 6 pinned, 3 skipped, 6 ignored, 1 not in lazy-lock.json$' out1.log
    # No surprise output: exactly 19 lines, every one of them an "import: " note.
    [ "$(grep -c '^\[nvimx\] import: ' out1.log)" -eq 19 ]
    [ "$(wc -l < out1.log)" -eq 19 ]
    # The invariant (§3.6 of the plan): pinned + skipped + ignored accounts for every
    # entry lazy-lock.json has, with nothing silently dropped.
    summary=$(grep 'import: .* pinned,' out1.log)
    pinned=$(echo "$summary" | grep -o '[0-9]* pinned' | grep -o '[0-9]*')
    skipped=$(echo "$summary" | grep -o '[0-9]* skipped' | grep -o '[0-9]*')
    ignored=$(echo "$summary" | grep -o '[0-9]* ignored' | grep -o '[0-9]*')
    total=$(jq 'keys | length' $fx/lazy-lock.json)
    [ "$((pinned + skipped + ignored))" -eq "$total" ]

    # 7. Determinism: raw.plugins and import_db are both walked with pairs(), so this
    # is the proof the sort-then-emit design actually removes that non-determinism.
    nvim -l $lua/resolve.lua $fx/raw-spec.json out1b.json \
      --import-lazy-lock $fx/lazy-lock.json 2> out1b.log
    diff -u out1.log out1b.log

    # 8. An existing lock always wins over the imported file -- including a `null`
    # resolvedRef, which is itself a decision ("track this ref, nothing to pin").
    nvim -l $lua/resolve.lua $fx/raw-spec.json out2.json \
      --prev $fx/prev.json --import-lazy-lock $fx/lazy-lock.json 2> out2.log
    jq -e '.plugins["plain.nvim"].resolvedRef
           == "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"' out2.json > /dev/null
    jq -e '.plugins["tag.nvim"].resolvedRef == null' out2.json > /dev/null
    grep -q 'import: skipped 2 entries already decided by the existing lock$' out2.log

    # 9. `pin = true` plus `version`: the existing "pin wins" warning covers it, so
    # classification 10 must not also mention it (saying it twice would be redundant).
    jq '.plugins["pinned.nvim"].version = "^2.0"' $fx/raw-spec.json > raw-spec-pinver.json
    nvim -l $lua/resolve.lua raw-spec-pinver.json out3.json \
      --import-lazy-lock $fx/lazy-lock.json 2> out3.log
    jq -e '.plugins["pinned.nvim"].resolvedRef
           == "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"' out3.json > /dev/null
    grep -q 'pinned; version constraint "\^2.0" is not validated (pin wins)' out3.log
    if grep -q 'is not validated for .* pinned from lazy-lock.json.*pinned\.nvim' out3.log; then
      echo "pin+version must not be reported twice (once by the pin warning, once by classification 10)" >&2
      exit 1
    fi

    # 10. Idempotent re-import: every seed from run 1 is already decided, so a second
    # pass with the same lazy-lock.json changes nothing and pins nothing new.
    # local.nvim never reaches plugins.json at all (it lives only in localPlugins), so
    # only 8 of the 9 non-local matched plugins are prev-blocked here, not 9.
    nvim -l $lua/resolve.lua $fx/raw-spec.json out4.json \
      --prev out1.json --import-lazy-lock $fx/lazy-lock.json 2> out4.log
    cmp out1.json out4.json
    [ "$(grep -c 'import: pinned ' out4.log)" -eq 0 ]
    grep -q 'import: skipped 8 entries already decided by the existing lock$' out4.log

    # 11. The seed's persistence (goal 3's whole point): with no --import-lazy-lock at
    # all, a plain --prev pass reproduces out1.json byte-for-byte and prints nothing --
    # resolvedRef is not part of identity_fields, so a plain lock right after an import
    # never re-litigates it, and the import's own report never lands in plugins.json.
    nvim -l $lua/resolve.lua $fx/raw-spec.json out5.json --prev out1.json 2> out5.log
    cmp out1.json out5.json
    [ ! -s out5.log ]

    # 12. A lazy-lock.json nvimx cannot parse must stop the run, with no partial output
    # written (resolve.lua only ever writes its output once, at the very end).
    rc=0
    nvim -l $lua/resolve.lua $fx/raw-spec.json bad1.json \
      --import-lazy-lock $fx/lazy-lock-broken.json 2> bad1.log || rc=$?
    [ "$rc" -ne 0 ]
    grep -q 'is not valid JSON' bad1.log
    grep -q ':Lazy restore' bad1.log
    [ ! -f bad1.json ]

    # 13. A missing lazy-lock.json is a hard, explicit error -- never a silent fallback
    # to a plain lock, which is exactly the accident this flag exists to prevent.
    rc=0
    nvim -l $lua/resolve.lua $fx/raw-spec.json bad2.json \
      --import-lazy-lock $TMPDIR/no-such.json 2> bad2.log || rc=$?
    [ "$rc" -ne 0 ]
    grep -q 'cannot open the lazy-lock.json' bad2.log
    [ ! -f bad2.json ]

    # 13b. Coverage-gap fixtures the plan's review added: an empty object, and a
    # top-level array. Both use a raw-spec with ver.nvim / defver.nvim's `version`
    # stripped (a jq-derived variant, not $fx/raw-spec.json directly): neither of these
    # two lazy-lock fixtures seeds anything at all, so nothing would ever close #23's
    # gate for those two plugins, and this check deliberately has neither git nor
    # --lazy available to resolve them. That is a real gap the plan's own snippet
    # missed (it reused $fx/raw-spec.json as-is here) -- with it, this step would fail
    # needing --lazy on every run, seeded or not, which is a much less useful check
    # than "importing an empty/malformed lock behaves correctly".
    jq 'del(.plugins["ver.nvim"].version,
            .plugins["defver.nvim"].version,
            .plugins["defver.nvim"].versionFromDefaults)' \
      $fx/raw-spec.json > raw-spec-no-version.json

    # {} -- valid and empty: a "nothing to seed" note, and every config plugin still
    # reported as resolving normally (classification 5) plus a summary, even though
    # there was nothing to loop over.
    nvim -l $lua/resolve.lua raw-spec-no-version.json out6.json \
      --import-lazy-lock $fx/lazy-lock-empty.json 2> out6.log
    grep -q 'import: lazy-lock.json has no entries; nothing to seed$' out6.log
    jq -e '[.plugins[] | .resolvedRef] | all(. == null)' out6.json > /dev/null
    [ "$(grep -c 'is not in lazy-lock.json; it will resolve normally$' out6.log)" -eq 9 ]
    grep -q 'import: 0 pinned, 0 skipped, 0 ignored, 9 not in lazy-lock.json$' out6.log

    # [] -- vim.json.decode returns a table with integer keys for a JSON array, so this
    # is not the hard-error path (a JSON scalar is); every "key" is a number instead of
    # a plugin name, reported as classification 9.
    nvim -l $lua/resolve.lua raw-spec-no-version.json out7.json \
      --import-lazy-lock $fx/lazy-lock-array.json 2> out7.log
    [ "$(grep -c 'key is not a plugin name' out7.log)" -eq 2 ]

    # 13c. A JSON scalar at the top level (a bare number, string, boolean, or null) is
    # the hard-error counterpart to the array case just above: vim.json.decode returns
    # a plain Lua value whose type is not "table" at all, so it is caught up front
    # rather than falling through to the entry loop and being reported per-entry like
    # the array's classification-9 lines.
    rc=0
    nvim -l $lua/resolve.lua raw-spec-no-version.json bad3.json \
      --import-lazy-lock $fx/lazy-lock-scalar.json 2> bad3.log || rc=$?
    [ "$rc" -ne 0 ]
    grep -q 'is not a table' bad3.log
    [ ! -f bad3.json ]

    # A top-level `null` is a scalar too (vim.json.decode returns vim.NIL, Lua type
    # "userdata"), but saying so verbatim would mean nothing to a reader -- checked here
    # that the message says "null", the actual JSON word they wrote, instead.
    rc=0
    nvim -l $lua/resolve.lua raw-spec-no-version.json bad4.json \
      --import-lazy-lock $fx/lazy-lock-null.json 2> bad4.log || rc=$?
    [ "$rc" -ne 0 ]
    grep -q 'is not a table (it decoded to null)' bad4.log
    if grep -q 'userdata' bad4.log; then
      echo "a top-level null must be reported as null, not as the Lua type it happens to decode to" >&2
      exit 1
    fi
    [ ! -f bad4.json ]

    # 13d. Classification 9's "no commit" reason has no coverage yet: an entry whose
    # value is an object but has no `commit` key at all (as opposed to badsha.nvim in
    # the main fixture, whose `commit` fails the 40-hex check instead). Built inline
    # rather than folded into $fx/lazy-lock.json itself, so that fixture's
    # exactly-19-lines assertion (check 6, above) is not perturbed.
    cat > lazy-lock-nocommit.json <<'JSON'
    {
      "nocommit.nvim": { "branch": "main" }
    }
    JSON
    nvim -l $lua/resolve.lua raw-spec-no-version.json out8.json \
      --import-lazy-lock lazy-lock-nocommit.json 2> out8.log
    grep -q 'import: invalid entry nocommit.nvim in lazy-lock.json: no commit$' out8.log
    grep -q 'import: 0 pinned, 0 skipped, 1 ignored, 9 not in lazy-lock.json$' out8.log

    # 14. lock-app's own parser rejects --update + --import-lazy-lock outright, before
    # --config/--out are even realpath'd -- provable without ever calling `nix`.
    rc=0
    nvimx-lock --config /nonexistent-config --out /nonexistent-out \
      --update --import-lazy-lock 2> cli1.log || rc=$?
    [ "$rc" -eq 2 ]
    grep -q -- '--import-lazy-lock cannot be combined with --update' cli1.log
    grep -q 'usage: nvimx-lock' cli1.log
    grep -q -- '--import-lazy-lock \[path\]' cli1.log

    # 15. The default path (<configDir>/lazy-lock.json) and an explicit missing path,
    # both fatal before `mkdir -p "$out"` ever runs -- neither leaves an out directory.
    mkdir -p cfg
    rc=0
    nvimx-lock --config cfg --out outdir --import-lazy-lock 2> cli2.log || rc=$?
    [ "$rc" -eq 2 ]
    grep -q "no lazy-lock.json at $(realpath cfg)/lazy-lock.json" cli2.log
    [ ! -e outdir ]

    rc=0
    nvimx-lock --config cfg --out outdir2 --import-lazy-lock /no/such/lazy-lock.json \
      2> cli3.log || rc=$?
    [ "$rc" -eq 2 ]
    grep -q 'no lazy-lock.json at /no/such/lazy-lock.json' cli3.log
    [ ! -e outdir2 ]

    # 16. Name matching, proven through the real extractor rather than a hand-written
    # raw-spec: extract's derived name and lazy-lock.json's own keys have to agree for
    # any of the above to mean anything about a real config. Includes lazy.nvim's own
    # entry, which every real lazy-lock.json has (the extractor's raw-spec never does),
    # so classification 8 gets one genuine end-to-end exercise too.
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
    cat > basic-lazy-lock.json <<'JSON'
    {
      "lazy.nvim":       { "branch": "main", "commit": "0000000000000000000000000000000000000000" },
      "tokyonight.nvim": { "branch": "main", "commit": "1234123412341234123412341234123412341234" }
    }
    JSON
    nvim -l $lua/resolve.lua $sb/raw-spec.json basic-out.json \
      --import-lazy-lock basic-lazy-lock.json 2> basic-import.log
    jq -e '.plugins["tokyonight.nvim"].resolvedRef
           == "1234123412341234123412341234123412341234"' basic-out.json > /dev/null
    grep -q 'import: lazy.nvim itself is not imported' basic-import.log

    # 17. Regression guard for lock-app.nix's log-truncation hazard. The real
    # nvimx-lock runs resolve.lua twice -- pass 1 with --import-lazy-lock, then an
    # unconditional convergence pass (deliberately without --import-lazy-lock; see that
    # pass's own comment in lock-app.nix) -- and both redirect stderr with `2>` to the
    # same resolve.log path. `2>` truncates on open, so without lifting pass 1's
    # `[nvimx] import: ...` report out first, pass 2 silently erases it before
    # nvimx-lock ever gets a chance to print it -- exactly the bug this fix closes.
    # The full two-pass pipeline can't run inside this check (it ends in `nix flake
    # lock`, and a nested nix call from within a nix build is recursive nix), so this
    # reproduces just the hazard: run pass 1, lift its import lines out with the same
    # grep lock-app.nix uses, then run a convergence-shaped pass 2 (--prev, no
    # --import-lazy-lock) redirected to the *same* log file, and prove (a) the shared
    # log really did lose every import line, and (b) the lifted-out copy did not. This
    # exists so lock-app.nix's flush_logs/import.log fix can never be "simplified" back
    # into a single shared log file without this check catching it. checks.lock-app (#71)
    # does run the whole pipeline against a stub `nix`, but it does not assert on the
    # import lines' truncation, which is why this reproduction stays.
    nvim -l $lua/resolve.lua $fx/raw-spec.json seq-out1.json \
      --import-lazy-lock $fx/lazy-lock.json 2> seq.log
    grep '^\[nvimx\] import: ' seq.log > seq-import.log || true
    nvim -l $lua/resolve.lua $fx/raw-spec.json seq-out2.json \
      --prev seq-out1.json 2> seq.log
    if grep -q 'import: ' seq.log; then
      echo "pass 2 was expected to truncate away pass 1's import lines when both redirect to the same path -- that is the exact hazard lock-app.nix's import.log lift-out has to work around" >&2
      exit 1
    fi
    [ "$(wc -l < seq-import.log)" -eq 19 ]

    # 18. #49: classification 8 ("lazy.nvim itself is not imported") only fires when the
    # spec has *no* lazy.nvim entry of its own -- true for every fixture above, but not
    # in general any more. raw-spec-lazy-self.json's spec lists lazy.nvim (with no
    # `commit` and no non-"main" `branch`, so seedable() does not block the seed) and
    # nothing else that needs a version constraint, so it seeds normally, exactly like
    # plain.nvim, and is counted in "N pinned" rather than reported as classification 8.
    nvim -l $lua/resolve.lua $fx/raw-spec-lazy-self.json outls.json \
      --import-lazy-lock $fx/lazy-lock.json 2> outls.log
    jq -e '.lazyNvim.resolvedRef
           == "0000000000000000000000000000000000000000"' outls.json > /dev/null
    jq -e '.plugins["lazy.nvim"] == null' outls.json > /dev/null
    if grep -q 'lazy.nvim itself is not imported' outls.log; then
      echo "a spec lazy.nvim entry must be seeded like any other matched plugin, not reported as classification 8" >&2
      exit 1
    fi
    grep -q '^\[nvimx\] import: 2 pinned, ' outls.log

    # 19. #47: a dir-only plugin that *is* in lazy-lock.json. Before #47 it was filed as remote and got
    # pinned from the lock; now it takes classification 3L like any other local plugin, because lazy
    # does not record a rev for a local plugin either (lua/lazy/manage/lock.lua:25).
    #
    # All four assertions matter and none of them is "the resolve exits 0": import seeds resolvedRef
    # *before* #23's gate and a non-null resolvedRef closes it, so every way of breaking this still
    # exits 0. Narrowing the main loop's dev/dir test pins local.nvim from the lock and reports its
    # materialized defaults.version as unvalidated, which the `is not validated` line catches;
    # narrowing only this loop's own test leaves it unpinned but unaccounted for, which the skipped
    # line and the pinned/skipped counts catch. (The fixture's url exists so either regression gets
    # that far instead of dying on "has no url"; it is not a gate guard.)
    nvim -l $lua/resolve.lua $fx/raw-spec-dir-only.json dir-only.json \
      --import-lazy-lock $fx/lazy-lock.json 2> dir-only.log
    grep -q 'import: skipped local.nvim: it is a local plugin (dev/dir), so there is nothing to pin' \
      dir-only.log
    grep -q 'import: 1 pinned, 1 skipped,' dir-only.log
    ! grep -q 'is not validated' dir-only.log
    jq -e '.plugins["local.nvim"] == null' dir-only.json > /dev/null
    # Keys only, never the recorded dir: #56 did stop recording it, and this line did not move.
    # Step 1's golden pins the value for the `dev = true` route -- its local.nvim writes both dev
    # and dir. This dir-only route (#47) has no golden of its own, so what pins its value is
    # checks.extractor-local-dir's `select(. != { })` assertion, not the diff above.
    jq -e '.localPlugins | has("local.nvim")' dir-only.json > /dev/null

    touch $out
  ''
