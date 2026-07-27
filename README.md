# nvimx

<p align="center">
  <img src="assets/nvimx.png" alt="nvimx logo" width="240">
</p>

<p align="center">
  <a href="https://nixos.org"><img src="https://img.shields.io/badge/built%20with-Nix-5277C3?logo=nixos&logoColor=white" alt="Built with Nix"></a>
  <a href="https://neovim.io"><img src="https://img.shields.io/badge/for-Neovim-57A143?logo=neovim&logoColor=white" alt="For Neovim"></a>
  <a href="https://github.com/myuron/nvimx/actions/workflows/ci-linux.yml"><img src="https://github.com/myuron/nvimx/actions/workflows/ci-linux.yml/badge.svg?branch=main" alt="x86_64-linux"></a>
  <a href="https://github.com/myuron/nvimx/actions/workflows/ci-darwin.yml"><img src="https://github.com/myuron/nvimx/actions/workflows/ci-darwin.yml/badge.svg?branch=main" alt="aarch64-darwin"></a>
  <a href="LICENSE"><img src="https://img.shields.io/github/license/myuron/nvimx?color=blue" alt="License: MIT"></a>
</p>

## What is nvimx?

nvimx manages your Neovim plugins with Nix, driven by the same lazy.nvim-style Lua config you already write.

## Why nvimx?

- lazy.nvim is a great plugin manager, but the fact that it updates its lock file on startup causes compatibility issues with Nix.
- Nixvim is also an excellent home-manager module, but since it primarily uses plugins available in nixpkgs, if the plugin you want isn't available, you'll need to manage the hash yourself.
- nvimx parses Lua and fetches plugins from GitHub rather than from nixpkgs. The hashes of the retrieved plugins are managed in `flake.lock`. This means you can manage a large number of plugins with Nix without sacrificing the flexibility of Lua.

## Installation

nvimx is a home-manager module. You integrate it into your dotfiles to use it.

```nix
{
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
      self,
      nixpkgs,
      home-manager,
      nvimx,
    }:
    {
      homeConfigurations."myuser" = home-manager.lib.homeManagerConfiguration {
        pkgs = import nixpkgs { system = "x86_64-linux"; };
        modules = [
          nvimx.homeModules.nvimx
          {
            programs.nvimx = {
              enable = true;
              configDir = ./nvim;
              lockDir = ./nvim/nvimx-lock;

              lock = {
                installCommand = true;
                projectDir = "~/dotfiles";
                configDirRelative = "nvim";
                lockDirRelative = "nvim/nvimx-lock";
              };
            };
          }
        ];
      };
    };
}
```

## Usage

1. Write your Lua config using the same definition method as lazy.nvim, then `git add` it.
   Nix only sees git-tracked files, so an untracked Lua file is silently skipped during extraction.

2. Lock the plugins.

   ```bash
   nvimx-lock
   ```

   `nvimx-lock` lands on your PATH via home-manager, so before your very first switch, run it
   straight from the flake instead:

   ```bash
   nix run github:myuron/nvimx#lock -- --config ./nvim --out ./nvim/nvimx-lock
   ```

3. Commit the generated lock directory and switch home-manager.

   ```bash
   git add nvim/nvimx-lock
   home-manager switch --flake .
   ```

The order is not actually rigid. Switching without a lock does not fail: the build *degrades* to a
lazy.nvim-only Neovim and warns you, while still installing the `nvimx-lock` command. Running
`nvimx-lock` → commit → switching again gets you to the full state either way.

Adding a plugin later is the same loop: write the spec → `git add` → `nvimx-lock` → commit → switch.
Existing pins stay untouched; only the new plugin is fetched.

## Options

All options live under `programs.nvimx`.

| option | type | default | description |
| --- | --- | --- | --- |
| `enable` | `bool` | `false` | Whether to enable nvimx (nix x neovim manager). |
| `package` | `package` | `pkgs.neovim-unwrapped` | The Neovim itself (an `-unwrapped` style derivation). You can also point this at neovim-nightly-overlay. |
| `configDir` | `nullOr path` | `null` | The Lua config directory containing `init.lua`. When `manageConfig = true` it is deployed from the Nix store via `xdg.configFile`. |
| `lockDir` | `path` | _(required)_ | Where `nvimx-lock` writes `plugins.json` / `flake.nix` / `flake.lock`. If they are absent, the build degrades. |
| `manageConfig` | `bool` | `true` | `true`: deploy `configDir` from the Nix store via `xdg.configFile` (reproducibility first, the default). `false`: `~/.config/nvim` is managed by you (fast iteration). |
| `vimAlias` | `bool` | `false` | Add a symlink so that the `vim` command launches the wrapped Neovim. |
| `viAlias` | `bool` | `false` | Add a symlink so that the `vi` command launches the wrapped Neovim. |
| `extraPackages` | `listOf package` | `[ ]` | Packages prepended to the wrapper's `PATH` (ripgrep, language servers, etc.). |
| `lock.installCommand` | `bool` | `true` | Add the `nvimx-lock` command to `home.packages`. |
| `lock.projectDir` | `nullOr str` | `null` | The working tree of your dotfiles repository. When set, running `nvimx-lock` with no arguments targets `configDirRelative` / `lockDirRelative`. |
| `lock.configDirRelative` | `str` | `"nvim"` | Path to `configDir`, relative to `projectDir`. |
| `lock.lockDirRelative` | `str` | `"nvim/nvimx-lock"` | Path to `lockDir`, relative to `projectDir`. |
| `env` | `attrs` | _(derived)_ | The result of `makeEnv` (`farm` / `bootstrap` / `wrapped` / `hasLock`). Built automatically from the options above; a direct escape hatch for advanced users. |

`lockDir` is the only option without a default, so it must always be set. `configDir` is also required whenever `manageConfig` is `true` (the default), which is enforced by an assertion in the module.

## How it works

Network access happens only while locking. `nvimx-lock` runs a headless Neovim that really evaluates
your lazy spec, then persists the plugin list to `plugins.json` and the pins to `flake.lock`.

Builds merely read those files, so evaluation is fully pure — no network, no `--impure`. From them
nvimx builds one derivation per plugin, collects them into a linkFarm, and wraps Neovim with a
generated `bootstrap.lua` so lazy.nvim loads everything from the Nix store instead of running its
own git/install pipeline. The same lock always yields the same result, no matter how often you
switch.

See [docs/architecture.md](docs/architecture.md) for the full design.

## Example

Author's dotfiles: [myuron/dotfiles](https://github.com/myuron/dotfiles/tree/main/home-manager/nvimx)
