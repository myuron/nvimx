# The module's pass-through to env.check (#79). mkHmCheck asserts nothing about it, and makeEnv's
# new formals have defaults, so a dropped configDir or check.ignoreErrors would go unnoticed.
# This builds only if both reach makeEnv: without configDir env.check throws, without
# ignoreErrors the notify-error fixture fails at runtime. Same module setup as
# checks.extra-wrapper-args' moduleWrapped.
{
  pkgs,
  self,
  home-manager,
  ...
}:
(home-manager.lib.homeManagerConfiguration {
  inherit pkgs;
  modules = [
    self.homeModules.nvimx
    {
      # Same values as mkHmCheck. Only .config is read.
      home.username = "nvimx-test";
      home.homeDirectory = "/home/nvimx-test";
      home.stateVersion = "25.05";
      programs.nvimx = {
        enable = true;
        configDir = ../fixtures/startup-check/notify-error;
        lockDir = ../fixtures/basic-config/nvimx-lock;
        check.ignoreErrors = [ "failed to download server" ];
      };
    }
  ];
}).config.programs.nvimx.env.check
