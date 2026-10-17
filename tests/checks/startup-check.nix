# env.check (#79). Building a check only shows that it passes, so this is the one place that
# proves it also fails: the broken fixtures run env.check.runner directly and must exit non-zero
# with the expected message (scripts/startup-check.sh). The passing fixtures are plain build
# dependencies. The cases pin what is and is not a failure: Lua errors, an error in a lazy-loaded
# plugin's config (only the load-all step finds it, cf. checks.hm-module's plain startup), ERROR
# notifications even through a replaced / chained vim.notify, a spec plugin missing from the
# lock, a config that never calls lazy.setup, and a config that quits during startup (exit 0
# without the sentinel); but not stderr noise, silent!, dev plugins with no working tree, WARN.
# The 120 s timeout is not exercised: a deliberate hang is too slow for CI.
{ pkgs, nvimxLib, ... }:
let
  mkEnv =
    args:
    nvimxLib.makeEnv (
      {
        package = pkgs.neovim-unwrapped;
        lockDir = ../fixtures/basic-config/nvimx-lock;
      }
      // args
    );
  fixture = name: ../fixtures/startup-check + "/${name}";
  env = mkEnv { };
  runner =
    name:
    (nvimxLib.mkCheck {
      inherit env;
      configDir = fixture name;
    }).runner;
in
pkgs.runCommand "startup-check" {
  goodCheck = (mkEnv { configDir = ../fixtures/basic-config; }).check;
  # tokyonight is a dev plugin whose tree is absent: skipped, and lazy's startup
  # "not installed" error for it filtered
  toleratedCheck =
    (mkEnv {
      configDir = fixture "tolerated";
      devPlugins = [ "tokyonight.nvim" ];
      devPath = "/nvimx-check/no-such-dir";
    }).check;
  allowedCheck =
    (mkEnv {
      configDir = fixture "notify-error";
      check.ignoreErrors = [ "failed to download server" ];
    }).check;
  chainWarnCheck = (mkEnv { configDir = fixture "chain-warn"; }).check;
  initErrorRunner = runner "init-error";
  lazyConfigErrorRunner = runner "lazy-config-error";
  notifyErrorRunner = runner "notify-error";
  chainErrorRunner = runner "chain-error";
  earlyQuitRunner = runner "early-quit";
  staleLockRunner = runner "stale-lock";
  noLazyRunner = runner "no-lazy";
} "source ${./scripts/startup-check.sh}"
