# treesitter.grammars through the module's option type
# (nullOr (either (enum [ "all" ]) (listOf str))), which the lib-level check bypasses
{
  mkHmCheck,
  ...
}:
mkHmCheck {
  configDir = ../fixtures/treesitter-config;
  lockDir = ../fixtures/treesitter-config/nvimx-lock;
  treesitter.grammars = [ "lua" ];
}
