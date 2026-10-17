# extraWrapperArgs (#72) through the module's option type (listOf str) with a
# context-carrying string, and all the way to an activation package against a real lock --
# checks.extra-wrapper-args' moduleWrapped goes through the same type but stops at the
# wrapper. The last element is the shape the issue asks for, a store path interpolated
# into a string. Like every mkHmCheck it asserts nothing about the result: that the
# module actually hands the option on is checked by checks.extra-wrapper-args'
# moduleWrapped, for the reason spelled out there. Uses the same basic-config lock
# hm-module already builds, so it adds no fetch of its own.
{
  pkgs,
  mkHmCheck,
  ...
}:
mkHmCheck {
  configDir = ../fixtures/basic-config;
  lockDir = ../fixtures/basic-config/nvimx-lock;
  extraPackages = [ pkgs.hello ];
  extraWrapperArgs = [
    "--set"
    "NVIMX_TEST_ASSET"
    "${pkgs.hello}/share"
  ];
}
