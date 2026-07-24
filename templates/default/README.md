# nvimx template

nvimx を組み込んだ dotfiles の雛形。

## 使い方

1. `flake.nix` の `myuser` / `home.homeDirectory` / `lock.projectDir` を自分の環境に合わせて変更する
2. `nvim/` に lazy.nvim 形式の lua config を書く (雛形の `init.lua` 参照)
3. plugin を lock する:

   ```sh
   nix run github:myuron/nvimx#lock -- --config ./nvim --out ./nvim/nvimx-lock
   git add nvim/nvimx-lock
   ```

4. `home-manager switch --flake .` で配備

lock を忘れて switch しても degrade ビルド (lazy.nvim のみ) で nvim は起動し、
`nvimx-lock` コマンドが PATH に入るので、lock → commit → 再 switch で完全状態に到達できる。

## plugin の追加・更新

- 追加: lua に spec を書く → `git add` → `nvimx-lock` → commit → switch
- 更新: `nvimx-lock --update` (Phase 6 で対応予定) → switch
