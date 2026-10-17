# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A Nix × Neovim plugin manager shipped as a home-manager module (`programs.nvimx`). Users write lazy.nvim-style Lua; at **lock time** a headless Neovim evaluates the spec (`lua/nvimx/extract.lua` → `resolve.lua` → `genflake.lua`) and pins plugins in `plugins.json` + `flake.lock`. Builds are then pure and offline, and a generated bootstrap makes lazy.nvim load everything from the Nix store. Files under `lua/nvimx/` are standalone scripts run via `nvim -l` / `nvim --headless`, not a `require` module tree.

## Commands

- `nix flake check` and `nix fmt -- --ci` — exactly what CI runs (`.github/workflows/check.yml`). Both must pass.
- `nix build .#checks.x86_64-linux.<name>` — run one check.
- `nix eval .#checks.<system>.<name>.drvPath` — a `nix flake check` silently skips other systems (aarch64-darwin, and aarch64-linux on an x86 host); run this for `aarch64-darwin` / `aarch64-linux` when touching system-dependent code. `nix flake check --no-build --all-systems` evaluates all of them.
- `nix fmt -- --clear-cache` — required after editing `stylua.toml` or `.luacheckrc` (treefmt caches on file + command).
- `nix build .#demo && ./result/bin/nvim` — smoke test; `:Lazy` should show every plugin as local with no git operations.
- `nix run .#lock -- --config ./nvim --out ./nvim/nvimx-lock` — lock pipeline; also `--update [name...]`, `--import-lazy-lock [path]`.
- `nix run .#skills-install` — regenerates `.claude/skills/` from the `agent-skills` input with rsync `--delete`. Never hand-edit `.claude/skills/`.

## Testing

No test framework. Every check is a derivation in its own `tests/checks/<name>.nix` (listed in `tests/checks/default.nix`; shared helpers in `tests/checks/lib.nix`), usually comparing output against `tests/fixtures/**/golden/`. `tests/*.lua` drivers run under `nvim -l` and fail via bare `assert()`. Check comments explain *why* (often citing issue numbers and other check names) — match that when adding a check.

## Gotchas

- Locking is the only online step. `nix/lib/build-network.nix` throws at evaluation time on builds needing network; escape hatches: `plugins.overrides` > `plugins.nixpkgsFallback` > `nix/build-registry/`.
- No IFD — e.g. checks pin blink.cmp with a literal `builtins.fetchTree`.
- Systems are `x86_64-linux`, `aarch64-linux` and `aarch64-darwin` only (`x86_64-darwin` is out of scope). Wrap system-dependent outputs in `forAllSystems`; `homeModules` and `templates` stay system-independent.
- CI has one workflow per system only for per-system README badges. Add steps to `check.yml` only, never to the per-system `ci-*.yml` files.
- `lua/nvimx/bootstrap.lua.in` is excluded from stylua/luacheck only by its extension — keep the name.
- Don't set `programs.stylua.settings` in treefmt; it would override `stylua.toml`.

## Version control

- Conventional Commits: English, lowercase, imperative, no trailing period, scoped by subsystem (`lock`, `resolve`, `hm`, `dev`, `extract`, `build-registry`, `plugin-drv`, `treesitter`, `wrapper`, `ci`).
- Branch as `<type>/<slug>`. Never push to main — merge via PR as a merge commit (not squash). Write PRs in English.
