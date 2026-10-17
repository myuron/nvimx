# Without a lock: evaluation must still succeed via the degraded build
# (verifies the chicken-and-egg problem is solved)
{
  mkHmCheck,
  ...
}:
mkHmCheck {
  configDir = ../fixtures/basic-config;
  lockDir = ../fixtures/basic-config/no-such-lock;
}
