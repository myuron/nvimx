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
      # TODO: change the username and home directory to your own
      homeConfigurations."myuser" = home-manager.lib.homeManagerConfiguration {
        # On macOS (Apple Silicon), change this to "aarch64-darwin".
        # Intel Mac ("x86_64-darwin") is not supported by nvimx because
        # nixpkgs 26.11 dropped support for it.
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

              # What a bare `nvimx-lock` targets (the dotfiles working tree)
              lock.projectDir = "~/dotfiles";

              # Example of swapping out neovim itself (substitute your system name on macOS):
              # package = inputs.neovim-nightly-overlay.packages.x86_64-linux.default;

              # extraPackages = [ pkgs.ripgrep ];

              # vimAlias = true;  # if you also want to launch it with `vim`
            };
          }
        ];
      };
    };
}
