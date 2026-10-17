# Pure unit test of lua/nvimx/source.lua (#28): the whole accept/reject matrix of plugin
# source URLs, with no fixture, no jq, no git and no network. This is the *only* place a
# rejection's exact wording is pinned -- the integration side (checks.resolve-sources)
# deliberately checks the shape of the failure output, not its text, so a reworded message
# never has to be edited in two files. Same split checks.semver-select has with
# checks.resolve-semver.
{
  pkgs,
  ...
}:
pkgs.runCommand "source-parse"
  {
    nativeBuildInputs = [ pkgs.neovim-unwrapped ];
  }
  ''
    nvim -l ${../source-parse-test.lua} ${../../lua/nvimx/source.lua}
    touch $out
  ''
