# extraLuaPackages through the module's option type (functionTo (listOf package)), which
# the lib-level check bypasses, and all the way to an activation package -- so the rock
# env is part of a real home-manager build, not just of a wrapper built in isolation.
# Uses the same basic-config lock hm-module already builds, so it adds no fetch of its own.
{
  pkgs,
  mkHmCheck,
  ...
}:
mkHmCheck {
  configDir = ../fixtures/basic-config;
  lockDir = ../fixtures/basic-config/nvimx-lock;
  extraPackages = [ pkgs.hello ];
  extraLuaPackages = ps: [ ps.inspect ];
}
