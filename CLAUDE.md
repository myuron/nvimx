# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A nix × neovim manager. lazy.nvim-style lua is interpreted **at lock time** by a headless neovim, the resulting plugins are pinned in a `flake.lock`, and the whole thing is delivered as a home-manager module (`programs.nvimx`). Users pick neovim themselves — nixpkgs or neovim-overlay, either works.

Architecture, repository layout, and the full flake output list live in `docs/architecture.md`. Read it before any non-trivial change.

## Commands

- `nix flake check` and `nix fmt -- --ci` — these two are exactly what CI runs (`.github/workflows/check.yml`). Both must pass.
- `nix build .#checks.x86_64-linux.<name>` — a single check. There is no test runner: every check is a plain derivation written inline in `flake.nix`, comparing a fixture against `tests/fixtures/golden/`. The drivers in `tests/*.lua` run under `nvim -l` and fail via bare `assert()`.
- `nix eval .#checks.aarch64-darwin.<name>.drvPath` — a Linux `nix flake check` prints `omitted these incompatible systems` and silently skips darwin. Run this whenever you touch darwin-related code; it is the only way to catch a darwin evaluation error locally.
- `nix fmt -- --clear-cache` — required after editing `stylua.toml` or `.luacheckrc`. treefmt caches on file + command, so a config change invalidates nothing on its own. CI passes `--ci`, which implies `--no-cache`, so CI is unaffected.
- `nix build .#demo && ./result/bin/nvim` — smoke test. `:Lazy` must show every plugin as local, with no git operations.
- `nix run .#lock -- --config ./nvim --out ./nvim/nvimx-lock` — the lock pipeline. Also takes `--update [name...]` and `--import-lazy-lock [path]`.
- `nix run .#skills-install` — regenerates `.claude/skills/` from the `agent-skills` input. It rsyncs with `--delete`, so **never hand-edit anything under `.claude/skills/`** except `nvimx-change/`, which is excluded on purpose.

## Gotchas

- `flake.nix` is ~2900 lines and holds every check inline. Its comments record *why*, often naming other checks and issue numbers. Match that density when adding one.
- Builds are fully pure and offline — **locking is the only online step**. `nix/lib/build-network.nix` throws at *evaluation* time on any build command that needs the network. The three ways out are `nix/build-registry/`, `plugins.overrides`, and `plugins.nixpkgsFallback`.
- No IFD. Checks pin blink.cmp with a literal `builtins.fetchTree` instead of `pkgs.vimPlugins.blink-cmp.src`, so `nix flake check` never needs IFD enabled and `plugins-escape-hatch`'s `tryEval` can still catch its own failure.
- `lua/nvimx/bootstrap.lua.in` is deliberately not named `*.lua`. That is what excludes it from stylua and luacheck — no `exclude_files` entry exists.
- Multi-system: `systems = [ "x86_64-linux" "aarch64-darwin" ]` via `forAllSystems`. Wrap system-dependent outputs (`lib` / `packages` / `formatter` / `checks` / `apps`) in `forAllSystems`; `homeModules` and `templates` do not depend on pkgs, so do not split them per system.
- `x86_64-darwin` (Intel Mac) is out of scope — nixpkgs 26.11 dropped it, so pinning `nixpkgs-unstable` makes it `throw` at evaluation time. Intel Mac users must specify `nixpkgs-26.05-darwin` on their side (EOL end of 2026).
- CI is one workflow per system only so the README can show a badge for each (GitHub badges are per workflow and cannot distinguish matrix jobs). All the work lives in the reusable `.github/workflows/check.yml`; `ci-linux.yml` and `ci-darwin.yml` just call it. **When adding a check step, edit only `check.yml`.**
- macOS runner labels are retired quickly, and a retired label does not fail the job — it stays queued forever (this already happened with `macos-13`). Whenever you add or change one, confirm it against the current [GitHub-hosted runners](https://docs.github.com/en/actions/reference/runners/github-hosted-runners) list.

## Version control

- Conventional Commits: English, lowercase, imperative, no trailing period. Scope is the subsystem — `lock`, `resolve`, `hm`, `dev`, `extract`, `build-registry`, `plugin-drv`, `treesitter`, `wrapper`, `ci`.
- Branch as `<type>/<slug>` (e.g. `feat/dev-plugins`). Pushing to main is forbidden — always merge via a PR, as a merge commit rather than a squash.
- Write PRs in English.

## Workflow

Every non-trivial change must go through `/nvimx-change` (plan → review → implement → review → PR → review, each step delegated to a subagent). Do not skip it and do not run the steps yourself.
