# extraWrapperArgs (#72) through the module's listOf str type to a real activation package,
# with a context-carrying string (a store path, the shape the issue asks for). Asserts
# nothing; the pass-through is checks.extra-wrapper-args' moduleWrapped. Reuses hm-module's lock.
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
