# Helpers shared by several checks. Imported by ./default.nix and passed to every check
# file alongside pkgs / nvimxLib.
{
  pkgs,
  self,
  home-manager,
  ...
}:
{
  # blink.cmp for checks.build-registry / checks.plugins-escape-hatch. A fetchTree, not
  # pkgs.vimPlugins.blink-cmp.src: the entry reads Cargo.lock at evaluation time, so a
  # derivation would mean IFD (and an uncatchable error in plugins-escape-hatch's tryEval).
  # Real srcs arrive the same way, via nix/lib/sources.nix. rev = v1.10.2, nixpkgs' narHash.
  blinkSrc = builtins.fetchTree {
    type = "github";
    owner = "Saghen";
    repo = "blink.cmp";
    rev = "78336bc89ee5365633bcf754d93df01678b5c08f";
    narHash = "sha256-C1FpyGw0f35NdHvDUGPXxmKdOgw3SpIteK1gAjVy6Ns=";
  };
  # `mkrepo <dir> [tag...]`: an offline git remote for `version` constraints (#23), used by the
  # resolve-* / extractor-defaults-version checks. Flake URLs built from it need a `git+file://`
  # prefix (genflake.lua adds "git+"). Annotated tags, so nix's tag peeling is exercised too.
  mkTagRepoSh = builtins.readFile ./scripts/mkrepo.sh;
  # Actually evaluate and build the hm module against a fixture config
  mkHmCheck =
    nvimxConfig:
    (home-manager.lib.homeManagerConfiguration {
      inherit pkgs;
      modules = [
        self.homeModules.nvimx
        {
          home.username = "nvimx-test";
          home.homeDirectory = "/home/nvimx-test";
          home.stateVersion = "25.05";
          programs.nvimx = {
            enable = true;
          }
          // nvimxConfig;
        }
      ];
    }).activationPackage;
}
