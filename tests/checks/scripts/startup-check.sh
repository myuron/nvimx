# shellcheck shell=bash disable=SC2154
# Body of checks.startup-check, sourced by the runCommand in ../startup-check.nix.
# The *Runner variables come from that derivation's env; each must fail with its message.
export HOME=$TMPDIR

# expect_fail <name> <runner> <message>: the runner exits non-zero and says why on stderr.
expect_fail() {
  if "$2" 2>"$1.log"; then
    echo "$1: the check must fail" >&2
    exit 1
  fi
  if ! grep -qF -- "$3" "$1.log"; then
    echo "$1: expected '$3' in:" >&2
    cat "$1.log" >&2
    exit 1
  fi
}

expect_fail init-error "$initErrorRunner" 'nvimx-check: init boom'
expect_fail lazy-config-error "$lazyConfigErrorRunner" 'nvimx-check: config boom'
expect_fail notify-error "$notifyErrorRunner" 'vim.notify: copilot: failed to download server'
expect_fail chain-error "$chainErrorRunner" 'vim.notify: nvimx-check: chained error'
# once: the chain must not double-count, and must not hang into the timeout
test "$(grep -cF 'nvimx-check: chained error' chain-error.log)" = 1 || {
  echo "chain-error: reported more than once:" >&2
  cat chain-error.log >&2
  exit 1
}
if grep -qF 'timed out' chain-error.log; then
  echo "chain-error: the notify chain hung" >&2
  exit 1
fi
expect_fail early-quit "$earlyQuitRunner" 'exited before the check finished'
expect_fail stale-lock "$staleLockRunner" 'plenary.nvim'
grep -qF 'nvimx-lock' stale-lock.log
expect_fail no-lazy "$noLazyRunner" 'setup() was never called'

touch "$out"
