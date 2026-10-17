# With a lock: the whole set (farm / wrapper / dataFile deployment) must build
{
  mkHmCheck,
  ...
}:
mkHmCheck {
  configDir = ../fixtures/basic-config;
  lockDir = ../fixtures/basic-config/nvimx-lock;
  vimAlias = true;
  viAlias = true;
  lock.projectDir = "~/dotfiles";
}
