# junegunn/fzf: the vim plugin that ships alongside the fzf command.
#
# Every form of its declared build (`./install --bin`, `./install --all`, or the
# `vim.fn["fzf#install"]()` function form) downloads a release binary from GitHub, which the
# sandbox can never do -- so the generic path throws before it ever runs. The binary nixpkgs
# already builds is the same program, so it is linked into the place the download would have
# populated: plugin/fzf.vim resolves `s:base_dir . "/bin/fzf"` before falling back to $PATH.
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
      mkdir -p $out/bin
      ln -sf ${pkgs.fzf}/bin/fzf $out/bin/fzf
    '';
  })
