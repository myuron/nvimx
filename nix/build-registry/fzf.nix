# junegunn/fzf: the vim plugin that ships alongside the fzf command.
#
# Every form of its declared build (`./install --bin`, `./install --all`, or the
# `vim.fn["fzf#install"]()` function form) downloads a release binary from GitHub, which the
# sandbox can never do. Note that build-network.nix does *not* catch this one: it matches the
# first word of a command only, and `./install` hides its curl inside a script -- deliberately,
# since that detection fails open (see its header). So without this entry the generic path
# evaluates happily and then dies mid-build with a fetch error.
#
# The binary nixpkgs already builds is the same program, so it is linked into the place the
# download would have populated: plugin/fzf.vim resolves `s:base_dir . "/bin/fzf"` before
# falling back to $PATH. It is the one thing here that does not come from the locked src --
# building fzf itself needs its Go module deps, i.e. the network again.
{
  pkgs,
  name,
  src,
  mkPluginDrv,
  ...
}:
(mkPluginDrv {
  inherit name src;
  build = {
    kind = "none";
  };
}).overrideAttrs
  (o: {
    postInstall = (o.postInstall or "") + ''
      # "fzf" is a short enough name that another repo could claim it in someone's lock, and
      # this entry drops that plugin's own build on the floor. Fail loudly instead of shipping
      # a silently broken plugin plus a stray binary.
      if [ ! -f $out/plugin/fzf.vim ]; then
        echo "nvimx: the plugin locked as \"fzf\" is not junegunn/fzf (no plugin/fzf.vim)." >&2
        echo "nvimx: override it with programs.nvimx.plugins.overrides.\"fzf\"." >&2
        exit 1
      fi
      mkdir -p $out/bin
      ln -sf ${pkgs.fzf}/bin/fzf $out/bin/fzf
    '';
  })
