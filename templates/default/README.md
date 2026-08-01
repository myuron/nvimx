# nvimx template

A dotfiles template with nvimx integrated.

## Usage

1. Change `myuser` / `home.homeDirectory` / `lock.projectDir` in `flake.nix` to match your environment
2. Write your lazy.nvim-style lua config in `nvim/` (see the `init.lua` in this template)
3. Lock your plugins:

   ```sh
   nix run github:myuron/nvimx#lock -- --config ./nvim --out ./nvim/nvimx-lock
   git add nvim/nvimx-lock
   ```

4. Deploy with `home-manager switch --flake .`

If you switch before locking, you still get a degraded build (lazy.nvim only) and nvim starts,
and since the `nvimx-lock` command lands on your PATH you can reach the complete state with
lock → commit → switch again.

## Adding and updating plugins

- Add: write the spec in lua → `git add` → `nvimx-lock` → commit → switch
- Update everything: `nvimx-lock --update` → commit → switch. Plugins with `pin = true` are
  skipped (say so in the output) -- name them explicitly to move them anyway
- Update one plugin: `nvimx-lock --update tokyonight.nvim` (any number of names) → commit → switch.
  Every other plugin's lock entry is left untouched
- Either form prints a summary of what moved (and what was skipped) before exiting
- Coming from plain lazy.nvim: put your `lazy-lock.json` next to `init.lua`, `git add` it, and run
  the first lock with `--import-lazy-lock` — every plugin is then pinned to the commit lazy already
  had, so nothing moves during the migration. See "Migrating from lazy.nvim" in the nvimx README
