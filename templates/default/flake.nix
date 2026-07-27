{
  description = "dotfiles with nvimx-managed neovim";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixpkgs-unstable";
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nvimx.url = "github:myuron/nvimx";
  };

  outputs =
    {
      nixpkgs,
      home-manager,
      nvimx,
      ...
    }:
    {
      # TODO: ユーザー名・ホームディレクトリを自分のものに変更する
      homeConfigurations."myuser" = home-manager.lib.homeManagerConfiguration {
        # macOS (Apple Silicon) の場合は "aarch64-darwin" に変更する。
        # Intel Mac ("x86_64-darwin") は nixpkgs 26.11 でサポート打ち切りのため
        # nvimx の対応対象外。
        pkgs = import nixpkgs { system = "x86_64-linux"; };
        modules = [
          nvimx.homeModules.nvimx
          {
            home.username = "myuser";
            home.homeDirectory = "/home/myuser";
            home.stateVersion = "25.05";

            programs.nvimx = {
              enable = true;
              configDir = ./nvim;
              lockDir = ./nvim/nvimx-lock;

              # 引数なし `nvimx-lock` の対象 (dotfiles 作業ツリー)
              lock.projectDir = "~/dotfiles";

              # neovim 本体の差し替え例 (macOS では system 名を読み替える):
              # package = inputs.neovim-nightly-overlay.packages.x86_64-linux.default;

              # extraPackages = [ pkgs.ripgrep ];

              # vimAlias = true;  # `vim` でも起動したい場合
            };
          }
        ];
      };
    };
}
