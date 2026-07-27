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
- Update: `nvimx-lock --update` (planned for Phase 6) → switch
