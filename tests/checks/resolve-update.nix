# Offline coverage of `--update [name...]` (#24): resolve.lua's name validation,
# force-set construction, and update-plan output, driven the same way
# checks.resolve-merge drives the plain merge path. `nix flake lock` / `nix flake
# update` themselves cannot run inside a nix build (recursive nix), so the actual CLI
# wiring in lock-app.nix is only exercised here for its argument parser (step 10, which
# never calls `nix`); the calls themselves (argv, cwd) are pinned by checks.lock-app
# against a stub `nix`, and that the real nix moves the inputs is the plan's §6.4
# manual verification.
{
  pkgs,
  nvimxLib,
  lazy-nvim,
  mkTagRepoSh,
  ...
}:
pkgs.runCommand "resolve-update" {
  nativeBuildInputs = [
    pkgs.neovim-unwrapped
    pkgs.jq
    pkgs.git
    nvimxLib.lockApp
  ];
  lua = ../../lua/nvimx;
  fx = ../fixtures/update;
  mfx = ../fixtures/merge;
  lazy = lazy-nvim;
} (mkTagRepoSh + "source ${./scripts/resolve-update.sh}")
