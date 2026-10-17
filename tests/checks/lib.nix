# Helpers shared by several checks. Imported by ./default.nix and passed to every check
# file alongside pkgs / nvimxLib.
{
  pkgs,
  self,
  home-manager,
  ...
}:
{
  # An upstream blink.cmp tree for checks.build-registry / checks.plugins-escape-hatch,
  # pinned here rather than taken from pkgs.vimPlugins.blink-cmp.src. The entry reads the
  # plugin's Cargo.lock *at evaluation time*, so handing it a derivation would make both
  # checks import-from-derivation: `nix flake check` would then need IFD enabled, and the
  # `tryEval` in plugins-escape-hatch could no longer report its own failure (an IFD build
  # error is not catchable). A fetchTree is already a store path at eval, so neither
  # applies. Real srcs reach the entry the same way -- nix/lib/sources.nix fetchTree's the
  # flake inputs -- so this is also the shape users actually get.
  # rev = v1.10.2; the narHash is the one nixpkgs records for the same tree.
  blinkSrc = builtins.fetchTree {
    type = "github";
    owner = "Saghen";
    repo = "blink.cmp";
    rev = "78336bc89ee5365633bcf754d93df01678b5c08f";
    narHash = "sha256-C1FpyGw0f35NdHvDUGPXxmKdOgw3SpIteK1gAjVy6Ns=";
  };
  # A git repo usable as a `version` constraint's remote with no network at all (#23),
  # shared by checks.resolve-semver, checks.extractor-defaults-version,
  # checks.resolve-update, checks.resolve-golden (#29) and checks.resolve-lazy-self (#49).
  # `git+file://`
  # (not a bare path) is what nix's flake ref parser accepts for a local remote, so any
  # caller building a flake input URL from one of these repos has to add that prefix
  # itself -- genflake.lua already does, since it prepends "git+" to every git-type source.
  # Tags are annotated (`tag -a`) so the same repo exercises both the `--refs` filtering
  # and nix's own peeling of an annotated tag to its commit (see the plan's §1.3).
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
