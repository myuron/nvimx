# Offline coverage of `--update [name...]` (#24): resolve.lua's name validation,
# force-set construction, and update-plan output, driven the same way
# checks.resolve-merge drives the plain merge path. `nix flake lock` / `nix flake
# update` themselves cannot run inside a nix build (recursive nix), so the actual CLI
# wiring in lock-app.nix is only exercised here for its argument parser (step 10, which
# never calls `nix`); the calls themselves (argv, cwd) are pinned by checks.lock-app
# against a stub `nix`, and that the real nix moves the inputs is the plan's §6.4
# manual verification.
{
  pkgs,
  nvimxLib,
  lazy-nvim,
  mkTagRepoSh,
  ...
}:
pkgs.runCommand "resolve-update"
  {
    nativeBuildInputs = [
      pkgs.neovim-unwrapped
      pkgs.jq
      pkgs.git
      nvimxLib.lockApp
    ];
  }
  (
    mkTagRepoSh
    + ''
      export HOME=$TMPDIR
      lua=${../../lua/nvimx}
      fx=${../fixtures/update}
      mfx=${../fixtures/merge}
      lazy=${lazy-nvim}

      # 1. Steady state, exactly checks.resolve-merge's own pass1 -> out1 (the golden
      # comparison for this is resolve-merge's job, not repeated here). This is only
      # the starting point every --update case below forces a plugin away from.
      nvim -l $lua/resolve.lua $mfx/raw-spec-base.json pass1.json --lock $mfx/flake.lock \
        --lazy $lazy 2> /dev/null
      nvim -l $lua/resolve.lua $mfx/raw-spec-base.json out1.json \
        --prev pass1.json --lock $mfx/flake.lock --lazy $lazy 2> /dev/null

      # 2. Naming a pinned plugin thaws just that plugin: the rest of plugins.json is
      # byte-for-byte the steady state, and the plan names only the one plugin.
      nvim -l $lua/resolve.lua $mfx/raw-spec-base.json out2.json \
        --prev out1.json --lock $mfx/flake.lock --lazy $lazy \
        --update tokyonight.nvim --update-plan plan2.txt 2> /dev/null
      diff -u $fx/golden/update-pinned.plugins.json out2.json
      for other in telescope.nvim plenary.nvim custom.nvim; do
        diff -u \
          <(jq -S --arg n "$other" '.plugins[$n]' out1.json) \
          <(jq -S --arg n "$other" '.plugins[$n]' out2.json)
      done
      [ "$(cat plan2.txt)" = "tokyonight-nvim" ]

      # 3. A bare --update thaws everything not pinned: both pinned plugins keep out1's
      # frozen rev, and the plan is exactly the pinned exclusion made explicit -- the
      # two unpinned plugins' inputNames plus the synthetic lazy-nvim seed, sorted.
      nvim -l $lua/resolve.lua $mfx/raw-spec-base.json out3.json \
        --prev out1.json --lock $mfx/flake.lock --lazy $lazy \
        --update --update-plan plan3.txt 2> /dev/null
      jq -e '.plugins["tokyonight.nvim"].resolvedRef
             == "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"' out3.json > /dev/null
      jq -e '.plugins["custom.nvim"].resolvedRef
             == "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"' out3.json > /dev/null
      printf 'lazy-nvim\nplenary-nvim\ntelescope-nvim\n' > plan3-expected.txt
      diff -u plan3-expected.txt plan3.txt

      # 4. --update lazy.nvim moves only the synthetic seed input: plugins.json is
      # untouched and the plan names only lazy-nvim. This fixture's spec (raw-spec-base
      # via merge/raw-spec-base.json) never lists lazy.nvim, so lazyNvim stays the
      # synthetic literal that only the update-plan entry can move -- when the spec
      # *does* list lazy.nvim, the lazyNvim entry itself is force-resolved too, so
      # plugins.json (well, the lazyNvim slot outside `plugins`) moves as well
      # (#49, checks.resolve-lazy-self).
      nvim -l $lua/resolve.lua $mfx/raw-spec-base.json out4.json \
        --prev out1.json --lock $mfx/flake.lock --lazy $lazy \
        --update lazy.nvim --update-plan plan4.txt 2> /dev/null
      cmp out1.json out4.json
      [ "$(cat plan4.txt)" = "lazy-nvim" ]

      # 5. Unknown names are collected and reported together, not one at a time (#23's
      # convention), and nothing is written -- resolve.lua's "no partial plugins.json on
      # failure" contract (#18 §3.4) extends to a failed --update. The third name is
      # spelled as an inputName rather than the display name, to prove the did-you-mean
      # hint fires without treating it as accepted.
      rc=0
      nvim -l $lua/resolve.lua $mfx/raw-spec-base.json out5.json \
        --prev out1.json --lock $mfx/flake.lock --lazy $lazy \
        --update no-such-plugin --update also-missing --update tokyonight-nvim \
        2> out5.log || rc=$?
      [ "$rc" -ne 0 ]
      grep -q 'plugin "no-such-plugin": unknown plugin' out5.log
      grep -q 'plugin "also-missing": unknown plugin' out5.log
      grep -q 'plugin "tokyonight-nvim": unknown plugin (did you mean "tokyonight.nvim"?)' out5.log
      [ ! -f out5.json ]

      # 6. A local (dev/dir) plugin and an unknown name in the same run are reported
      # together too, not just multiple unknown names.
      jq '.plugins["local.nvim"] = { "name": "local.nvim", "dev": true, "dir": "/some/path" }' \
        $mfx/raw-spec-base.json > raw-spec-with-local.json
      rc=0
      nvim -l $lua/resolve.lua raw-spec-with-local.json out6.json \
        --prev out1.json --lock $mfx/flake.lock --lazy $lazy \
        --update local.nvim --update no-such-plugin 2> out6.log || rc=$?
      [ "$rc" -ne 0 ]
      grep -q 'plugin "local.nvim": is a local plugin' out6.log
      grep -q 'plugin "no-such-plugin": unknown plugin' out6.log
      [ ! -f out6.json ]

      # 7. resolve.lua's own defense against mixing a bare --update with a named one
      # (for anyone driving it by hand -- the CLI itself never reaches this, since
      # lock-app rejects the same combination first; step 10 below is what proves the
      # CLI path actually does).
      rc=0
      nvim -l $lua/resolve.lua $mfx/raw-spec-base.json out7.json \
        --prev out1.json --lock $mfx/flake.lock --lazy $lazy \
        --update --update foo 2> out7.log || rc=$?
      [ "$rc" -eq 2 ]
      grep -q -- '--update takes either no names' out7.log

      # 8. A plugin whose spec fixes `commit` is a no-op when named explicitly (the URL
      # cannot move either way) but still lands in the update-plan -- harmlessly, since
      # `nix flake update` cannot move it either. This is the golden fixture for that
      # decision (§3.2 of the plan).
      nvim -l $lua/resolve.lua $fx/raw-spec-commit.json out8base.json \
        --lock $mfx/flake.lock --lazy $lazy 2> /dev/null
      nvim -l $lua/resolve.lua $fx/raw-spec-commit.json out8.json \
        --prev out8base.json --lock $mfx/flake.lock --lazy $lazy \
        --update vim-fugitive --update-plan plan8.txt 2> /dev/null
      jq -e '.plugins["vim-fugitive"].commit
             == "dddddddddddddddddddddddddddddddddddddddd"' out8.json > /dev/null
      [ "$(cat plan8.txt)" = "vim-fugitive" ]

      # 9. The convergence pass' own re-resolve (no --update, exactly what lock-app.nix
      # runs after `nix flake update`) is what actually refreezes a thawed pin once
      # flake.lock has caught up with the new rev, and running it once more from there
      # must be a fixed point -- the second nvimx-lock pass never needs a third.
      nvim -l $lua/resolve.lua $mfx/raw-spec-base.json out9a.json \
        --prev out2.json --lock $fx/flake.lock.after --lazy $lazy 2> /dev/null
      jq -e '.plugins["tokyonight.nvim"].resolvedRef
             == "5555555555555555555555555555555555555555"' out9a.json > /dev/null
      nvim -l $lua/resolve.lua $mfx/raw-spec-base.json out9b.json \
        --prev out9a.json --lock $fx/flake.lock.after --lazy $lazy 2> /dev/null
      cmp out9a.json out9b.json

      # 10. lock-app's own parser rejects the same bare+named mix (§3.1 of the plan):
      # this is the one place the rejection is provable without ever calling `nix`, and
      # the exact case the plan review found the previous draft could not actually
      # reach from the CLI. No real config/out is needed -- the rejection happens before
      # either is even realpath'd.
      rc=0
      nvimx-lock --config /nonexistent-config --out /nonexistent-out \
        --update --update foo 2> out10.log || rc=$?
      [ "$rc" -eq 2 ]
      grep -q 'usage: nvimx-lock' out10.log

      # 11. A version constraint on a named plugin resolves against a real (if local
      # and offline) remote exactly as a normal lock would: force only discards the
      # previous decision, it does not change how the constraint itself is honored.
      mkrepo $TMPDIR/tagged v1.0.0 v1.2.0 v1.2.5
      jq --arg u "file://$TMPDIR/tagged" \
        '.plugins["tagged.nvim"] = { "name": "tagged.nvim", "url": $u, "version": "^1.0" }' \
        $mfx/raw-spec-base.json > raw-spec-tagged.json
      jq --arg u "file://$TMPDIR/tagged" \
        '.plugins["tagged.nvim"] = { "inputName": "tagged-nvim", "resolvedRef": "refs/tags/v1.0.0",
                                      "branch": null, "tag": null, "commit": null, "version": "^1.0",
                                      "pin": null, "dependencies": [], "build": { "kind": "none" },
                                      "source": { "type": "git", "url": $u } }' \
        out1.json > prev-tagged.json
      nvim -l $lua/resolve.lua raw-spec-tagged.json out11.json \
        --prev prev-tagged.json --lazy $lazy \
        --update tagged.nvim 2> /dev/null
      jq -e '.plugins["tagged.nvim"].resolvedRef == "refs/tags/v1.2.5"' out11.json > /dev/null

      touch $out
    ''
  )
