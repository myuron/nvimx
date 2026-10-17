# devPlugins / devPath / devPatterns set through the module, all the way to a build: this is the only
# check that actually builds the wrapper and the generated bootstrap.lua with a
# non-empty devDirs against a real lock. checks.dev-plugins' moduleDevDirs also goes
# through the module, but only reads back .config.programs.nvimx.env.devDirs and never
# builds anything. Uses the same basic-config lock hm-module already builds, so it adds
# no fetch of its own.
{
  mkHmCheck,
  ...
}:
mkHmCheck {
  configDir = ../fixtures/basic-config;
  lockDir = ../fixtures/basic-config/nvimx-lock;
  devPlugins = [ "tokyonight.nvim" ];
  devPath = "~/projects";
  devPatterns = [ "folke" ];
}
