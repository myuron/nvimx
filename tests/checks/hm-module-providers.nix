# The provider options (#73) through the module's option types (nullOr bool, and
# functionTo (listOf package) for extraPython3Packages), all the way to an activation
# package against a real lock -- so the three hosts are part of a real home-manager
# build, next to a real farm. checks.providers' moduleWrapped goes through the same
# types but stops at the wrapper, in degraded mode. Like every mkHmCheck it asserts
# nothing about the result: that the module actually hands the four options on is
# checked by checks.providers' moduleWrapped, for the reason spelled out at
# checks.extra-lua-packages. Uses the same basic-config lock hm-module already builds,
# and the same three hosts checks.providers builds, so it adds no fetch of its own.
{
  mkHmCheck,
  ...
}:
mkHmCheck {
  configDir = ../fixtures/basic-config;
  lockDir = ../fixtures/basic-config/nvimx-lock;
  withPython3 = true;
  extraPython3Packages = ps: [ ps.six ];
  withRuby = true;
  withNodeJs = true;
}
