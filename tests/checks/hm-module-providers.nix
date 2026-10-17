# The provider options (#73) through the module's option types to a real activation package
# with a real farm. Asserts nothing; the pass-through is checks.providers' moduleWrapped.
# Reuses hm-module's lock and checks.providers' hosts, so it adds no fetch.
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
