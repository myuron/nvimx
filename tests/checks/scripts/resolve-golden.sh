# shellcheck shell=bash disable=SC2154
# Body of checks.resolve-golden, sourced by the runCommand in ../resolve-golden.nix.
# $lua $fx $lazy come from that derivation's env.
export HOME=$TMPDIR
sb=$TMPDIR/sandbox

# v2.0.0 is deliberately outside "^1.2": without it, a classifier that simply
# took the newest tag would pass.
mkrepo "$sb"/versioned v1.0.0 v1.2.0 v1.2.5 v2.0.0

jq --arg u "file://$sb/versioned" '.plugins["versioned.nvim"].url = $u' \
  "$fx"/raw-spec.json >injected.json
nvim -l "$lua"/resolve.lua injected.json out.json --lazy "$lazy" 2>resolve.log
cat resolve.log >&2

# Put the sandbox path back to the placeholder the fixture wrote, so the golden
# is the same on x86_64-linux (/build/...) and aarch64-darwin (/private/tmp/...).
sed "s#file://$sb/versioned#file:///nvimx-fixture/versioned.nvim#g" out.json >got.json
# ...and prove nothing else leaked. The sed above only knows about the one field
# resolve writes a url into today; this catches the day that stops being true.
if grep -q "$TMPDIR" got.json; then
  echo "the sandbox path leaked into the golden-comparable output" >&2
  exit 1
fi
diff -u "$fx"/golden/matrix.plugins.json got.json

# Exactly one warning: excmdbuild.nvim. shellbuild.nvim is the quiet path, and
# without it a resolve that warned about every build would pass the golden too
# (the golden would just have been generated with both warnings in it). So the
# count is asserted here, not left to the golden: regenerating it cannot silence
# this. This check owns how a warning is recorded in the lock file itself; the
# stderr side is checks.resolve-build-warnings', which owns the build-shape matrix.
jq -e '.warnings | length == 1' got.json >/dev/null
jq -e '.warnings[0] | startswith("plugin \"excmdbuild.nvim\"")' got.json >/dev/null

# A dev plugin has no lock entry and no flake input at all -- that is the whole
# contract of localPlugins. resolve.lua stopped recording the dir it resolved
# (#56), so what the golden now pins here is an empty object. These two lines
# never read that value either way, so #56 left them alone; they pin the
# structure, and the golden's byte-for-byte diff pins the value.
jq -e '.plugins["devel.nvim"] == null' got.json >/dev/null
jq -e '.localPlugins | has("devel.nvim")' got.json >/dev/null
touch "$out"
