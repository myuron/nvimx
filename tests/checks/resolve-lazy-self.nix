# The lazyNvim slot itself (#49). A spec is allowed to list lazy.nvim -- lazy's own docs
# tell people to -- and it used to make genflake write `inputs.lazy-nvim` twice, so the
# generated flake died at `nix flake lock` with a duplicate-attribute error naming
# neither the plugin nor the spec line. lazy.nvim cannot become an ordinary plugin
# instead: make-env.nix's farm (nix/lib/make-env.nix:122-133) always puts one `lazy.nvim`
# entry in front of pluginDrvs, and linkFarm is last-wins, so a second entry would
# silently replace nvimx's own foundation -- exactly what make-env.nix:47-48 and
# docs/architecture.md's plugin-derivation section say never happens. So the spec entry
# decides the *existing* input instead, and this check owns that slot. The spec-field
# matrix on ordinary plugins is checks.resolve-golden's (#29), the input_url precedence
# ladder is checks.genflake-golden's, and URL shapes are checks.resolve-sources' (#28);
# none of the three ever sees lazyNvim carrying a ref.
{
  pkgs,
  lazy-nvim,
  mkTagRepoSh,
  ...
}:
let
  # Importing the golden flake IS the regression test for the original bug: a
  # duplicate attribute is a *parse* error in Nix, so a golden that reintroduced the
  # second `lazy-nvim` would fail here, at evaluation, before any builder runs -- and
  # `nix eval .#checks.aarch64-darwin.resolve-lazy-self.drvPath` catches it on a
  # system this machine cannot build for. The diff in the builder is what proves
  # genflake still produces exactly this file. The parseFlakeRef type assert is the
  # same one checks.resolve-sources and checks.genflake-golden use (#28/#29): a github
  # or git ref, never a degraded `path:` / `indirect` node that only dies later in
  # nix/lib/sources.nix.
  goldenFlake = import ../fixtures/lazy-self/golden/tag.flake.nix;
  refTypes = builtins.mapAttrs (_: i: (builtins.parseFlakeRef i.url).type) goldenFlake.inputs;
  badTypes = pkgs.lib.filterAttrs (_: t: t != "github" && t != "git") refTypes;
  checkedRefTypes =
    if badTypes == { } then
      refTypes
    else
      throw "generated flake inputs are not github/git refs: ${builtins.toJSON badTypes}";
in
pkgs.runCommand "resolve-lazy-self"
  {
    nativeBuildInputs = [
      pkgs.neovim-unwrapped
      pkgs.jq
      pkgs.git
    ];
    # Forced while the derivation is instantiated, so
    # `nix eval .#checks.aarch64-darwin.resolve-lazy-self.drvPath` is enough to catch
    # an unparseable or degraded URL on a system this machine cannot build for.
    refTypes = builtins.toJSON checkedRefTypes;
  }
  (
    mkTagRepoSh
    + ''
      export HOME=$TMPDIR
      lua=${../../lua/nvimx}
      fx=${../fixtures/lazy-self}
      lazy=${lazy-nvim}
      sb=$TMPDIR/sandbox

      # 1. tag: a spec lazy.nvim with `tag` + `build` + `dependencies`. The golden pair
      # is the direct regression test for #49's original bug (duplicate `lazy-nvim`
      # attribute); `grep -c 'lazy-nvim = {'` is the explicit statement of "exactly one"
      # for a reader who only sees this check fail without the golden diff in front of
      # them.
      nvim -l $lua/resolve.lua $fx/raw-spec-tag.json tag.json --lazy $lazy 2> tag.log
      diff -u $fx/golden/tag.plugins.json tag.json
      nvim -l $lua/genflake.lua tag.json tag.flake.nix
      diff -u $fx/golden/tag.flake.nix tag.flake.nix
      [ "$(grep -c 'lazy-nvim = {' tag.flake.nix)" -eq 1 ]

      # `build` on lazy.nvim is dropped, never recorded, and warned about with lazy.nvim's
      # own wording (never the 3-escape-hatch build_warning ordinary plugins get -- none
      # of overrides/nixpkgsFallback/build-registry applies to lazy.nvim itself).
      n=$(grep -c '^\[nvimx\] warning: ' tag.log || true)
      if [ "$n" -ne 1 ]; then
        echo "expected exactly 1 warning, got $n" >&2
        exit 1
      fi
      grep -q 'plugin "lazy.nvim": `build` is ignored' tag.log

      # stderr's *total* line count, not just the warning count above: the `unbuildable`
      # escape-hatch note() block is `[nvimx] `-prefixed but never `warning: `-prefixed,
      # so it would not move the count above at all -- only the total line count catches
      # `unbuildable` staying wrongly set for lazy.nvim (the plan's §3.4 (ii)).
      [ "$(wc -l < tag.log)" -eq 1 ]
      if grep -q 'programs.nvimx.plugins.overrides' tag.log; then
        echo "lazy.nvim must never get the unbuildable escape-hatch note: none of its 3 hatches apply to it" >&2
        exit 1
      fi

      jq -e '.plugins["lazy.nvim"] == null' tag.json > /dev/null
      jq -e '.lazyNvim.synthetic == false' tag.json > /dev/null

      # 2. pin: the same 3-pass shape checks.resolve-merge uses for an ordinary pinned
      # plugin -- pass1 has nothing in flake.lock yet to freeze onto, pass2 freezes onto
      # $fx/flake.lock's rev, pass3 is a fixed point (0-op reruns must never re-decide a
      # frozen ref).
      nvim -l $lua/resolve.lua $fx/raw-spec-pin.json pin1.json 2> pin1.log
      jq -e '.lazyNvim.resolvedRef == null' pin1.json > /dev/null
      nvim -l $lua/resolve.lua $fx/raw-spec-pin.json pin2.json \
        --prev pin1.json --lock $fx/flake.lock 2> pin2.log
      jq -e '.lazyNvim.resolvedRef
             == "ffffffffffffffffffffffffffffffffffffffff"' pin2.json > /dev/null
      nvim -l $lua/resolve.lua $fx/raw-spec-pin.json pin3.json \
        --prev pin2.json --lock $fx/flake.lock 2> pin3.log
      cmp pin2.json pin3.json
      nvim -l $lua/genflake.lua pin2.json pin2.flake.nix
      grep -qF \
        'url = "github:folke/lazy.nvim/ffffffffffffffffffffffffffffffffffffffff";' \
        pin2.flake.nix

      # raw-spec-pin.json's lazy.nvim carries `build = false` -- lazy's own "do not
      # build" -- which must never warn (the plan's §3.4 (i)): an implementation that
      # warns on `p.build ~= nil` instead of `classify_build(p.build).kind ~= "none"`
      # would pass every other case in this file, since none of them gives lazy.nvim a
      # literal `false`.
      [ ! -s pin1.log ]
      [ ! -s pin2.log ]
      [ ! -s pin3.log ]

      # 3a/3b/3c. version: the semver gate fires for lazyNvim -- the discharge of
      # docs/plans/23-resolve-semver.md:235's follow-up ("does the gate fire once the
      # inputs are unified"). github type cannot be redirected to a local repo
      # (resolve.lua's github branch of the semver ls-remote uses the literal spec url),
      # so this is git type, a local repo this check builds itself.
      #
      # 4 tags to start, not 5: Semver.last(matched) in lua/nvimx/version.lua picks the
      # newest match, so starting with v11.14.9 already present would resolve straight
      # to it and 3b/3c's "does a later release actually force a re-resolve" would be
      # untestable. v12.0.0 is outside "^11.14" on purpose too, the same reason
      # checks.resolve-golden's matrix keeps a v2.0.0 outside its "^1.2": a classifier
      # that just took the newest tag, full stop, would still pass without it.
      mkrepo $sb/lazy v11.0.0 v11.14.0 v11.14.1 v12.0.0
      jq --arg u "file://$sb/lazy" '.plugins["lazy.nvim"].url = $u' \
        $fx/raw-spec-version.json > vin.json
      nvim -l $lua/resolve.lua vin.json v1.json --lazy $lazy 2> v1.log
      cat v1.log >&2
      jq -e '.lazyNvim.resolvedRef == "refs/tags/v11.14.1"' v1.json > /dev/null
      jq -e '.lazyNvim.source.type == "git"' v1.json > /dev/null
      nvim -l $lua/genflake.lua v1.json v1.flake.nix
      grep -qF 'ref=refs/tags/v11.14.1' v1.flake.nix

      # 3b. A later upstream release, between two locks -- a plain `git tag`, not
      # mkrepo: mkrepo always starts with a fresh `git init` and has no way to add a tag
      # to a repo it already created.
      git -C $sb/lazy -c user.name=nvimx -c user.email=nvimx@example.com \
        tag -a v11.14.9 -m v11.14.9

      # 3c. --prev is the actual subject of this step: with no previous decision to
      # force away from, a re-resolve would happen (or not) regardless of whether the
      # `force[LAZY_NAME] = true` line even exists, and perturbation (d) -- deleting
      # that line -- could never be caught by this file.
      nvim -l $lua/resolve.lua vin.json v2.json --prev v1.json --lazy $lazy \
        --update lazy.nvim --update-plan planv.txt 2> v2.log
      cat v2.log >&2
      jq -e '.lazyNvim.resolvedRef == "refs/tags/v11.14.9"' v2.json > /dev/null
      [ "$(cat planv.txt)" = "lazy-nvim" ]

      # 4. collide: two independent input-name collisions, neither one the real
      # lazy.nvim -- "lazy-nvim" (a plugin whose own name normalizes to the reserved
      # input name) and "foo.nvim"/"foo-nvim" (two ordinary names that normalize to the
      # same input name as each other). Both are reported through
      # fail_plugin/report_resolve_errors -- the `[nvimx] resolve failed: plugin ...`
      # path #28 established -- never the bare Lua error() this replaced (which named
      # neither the plugin nor a stable message across runs; see the plan's §1.6).
      rc=0
      nvim -l $lua/resolve.lua $fx/raw-spec-collide.json collide.json --lazy $lazy \
        > collide.out 2> collide.log || rc=$?
      if [ "$rc" -eq 0 ]; then
        echo "resolve.lua accepted two colliding input names" >&2
        exit 1
      fi
      if [ -e collide.json ]; then
        echo "resolve.lua wrote plugins.json for a failed (colliding) run" >&2
        exit 1
      fi
      # Counting exactly 2 lines matters as much as the wording: a regression that
      # turned only the reserved-name branch back into a bare error() (perturbation (n))
      # would still print the *other* line and could hide behind a looser `grep -q`.
      grep '^\[nvimx\] resolve failed: plugin ' collide.log > collide-failed.log
      [ "$(wc -l < collide-failed.log)" -eq 2 ]
      LC_ALL=C sort -c collide-failed.log
      grep -q 'reserved for lazy.nvim itself' collide.log
      grep -q 'derived from more than one plugin' collide.log

      # The reserved-name collision side of the semver-gate suppression (the plan's
      # §3.9-4, perturbation (o) -- the plugin-vs-plugin side is not decidable enough to
      # assert, see the plan's §7): raw-spec-collide.json's "lazy-nvim" entry carries a
      # `version` and an unreachable url specifically so that, if it were still queued
      # for ls-remote after resolve.lua already knew the run was doomed, this progress
      # line would appear (or the whole run would hang on the 60s ls-remote timeout
      # instead of failing immediately).
      if grep -q 'resolving version constraints' collide.out; then
        echo "a plugin that lost the reserved-name collision must never be queued for the semver gate" >&2
        exit 1
      fi

      # 5a. pin x update_all asymmetry (the plan's §3.6): a bare --update must respect
      # a spec lazy.nvim's own `pin = true` the same way it already respects `pin` for
      # an ordinary plugin, but naming it explicitly still overrides the pin -- the same
      # "naming beats pin" rule an ordinary plugin gets.
      nvim -l $lua/resolve.lua $fx/raw-spec-pin.json updall.json \
        --update --update-plan planall.txt 2> /dev/null
      if grep -q '^lazy-nvim$' planall.txt; then
        echo "a bare --update must not move a pin = true spec lazy.nvim's seed input" >&2
        exit 1
      fi
      nvim -l $lua/resolve.lua $fx/raw-spec-pin.json updnamed.json \
        --update lazy.nvim --update-plan plannamed.txt 2> /dev/null
      [ "$(cat plannamed.txt)" = "lazy-nvim" ]

      # 5b. dev/dir exclusion from lazy_is_spec (the plan's §3.6, perturbation (i)): a
      # *local* lazy.nvim that also happens to be `pin = true` must not trip the pin x
      # update_all exclusion above -- doing so would silently drop the synthetic seed
      # input from every dev-lazy.nvim user's bare --update, breaking #24's "a no-names
      # update always includes the seed input" contract. This is the only fixture that
      # can catch that: nothing else here gives lazy.nvim `dev`/`dir` *and* `pin` at
      # once. Also pins down the routing order itself: dev/dir wins over is_lazy, so
      # lazyNvim stays the synthetic default and lazy.nvim shows up in localPlugins.
      nvim -l $lua/resolve.lua $fx/raw-spec-devpin.json devpin.json \
        --update --update-plan plandev.txt 2> /dev/null
      grep -q '^lazy-nvim$' plandev.txt
      jq -e '.lazyNvim.synthetic == true' devpin.json > /dev/null
      jq -e '.localPlugins | has("lazy.nvim")' devpin.json > /dev/null

      # 5c. A spec lazy.nvim with a `dir` and no `dev` (#47). extract.lua used to drop that dir, so this
      # entry decided the lazy-nvim input like any other spec lazy.nvim -- tag, pin and all. Now it is
      # a local plugin, exactly as `dev = true` + dir already was (step 5b), so lazyNvim falls back to
      # the synthetic literal, the input URL loses the tag, and a bare --update moves the seed input
      # again because there is no longer a spec pin to respect (#49's own rule, now applied
      # symmetrically). The lazyNvim slot is this check's, so the new classification is pinned here
      # rather than in checks.extractor-local-dir.
      #
      # What this case can and cannot catch: the raw-spec is hand-written, so extract.lua never runs
      # and nothing here would notice #47's actual one-line fix being reverted
      # (checks.extractor-local-dir owns that). What it does hold down is the two resolve.lua
      # conditions the new classification rests on -- the main loop's dev/dir branch, which three of
      # the four jq lines and both genflake greps follow (`.plugins["lazy.nvim"] == null` stays true
      # either way: a spec lazy.nvim lands in the lazyNvim slot, never in `plugins`), and
      # lazy_is_spec's own `.dir` term, which only the update-plan lines follow.
      nvim -l $lua/resolve.lua $fx/raw-spec-dir-only.json dir-only.json --lazy $lazy \
        --update --update-plan plan-dir-only.txt 2> /dev/null
      jq -e '.lazyNvim.synthetic == true' dir-only.json > /dev/null
      jq -e '.lazyNvim | has("tag") | not' dir-only.json > /dev/null
      jq -e '.localPlugins | has("lazy.nvim")' dir-only.json > /dev/null
      jq -e '.plugins["lazy.nvim"] == null' dir-only.json > /dev/null
      nvim -l $lua/genflake.lua dir-only.json dir-only.flake.nix
      grep -q 'url = "github:folke/lazy.nvim";' dir-only.flake.nix
      ! grep -q 'refs/tags/v11.0.0' dir-only.flake.nix
      # The seed input is back in the plan: a dev/dir lazy.nvim has no pin worth respecting.
      grep -qx 'lazy-nvim' plan-dir-only.txt
      grep -qx 'tokyonight-nvim' plan-dir-only.txt

      touch $out
    ''
  )
