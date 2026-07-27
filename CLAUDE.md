# CLAUDE.md

## Purpose

- Build the ultimate nix x neovim manager that takes advantage of the flexibility of Lua as used in neovim while enjoying the reproducibility of nix

## Requirements

- Provide a home-manager module that can be embedded in the user's dotfiles.
- Parse lazy.nvim-style lua, fetch the required plugins, and pin them in flake.lock.
- Let the user freely choose neovim itself — either the nixpkgs neovim or neovim-overlay — and integrate it with nvimx.

## Structure notes

- `flake.nix` supports multiple systems, `x86_64-linux` and `aarch64-darwin` (`forAllSystems = nixpkgs.lib.genAttrs systems`). When adding system-dependent outputs (`lib` / `packages` / `formatter` / `checks` / `apps`), always wrap them in `forAllSystems (system: ...)`. `homeModules` / `templates` do not depend on pkgs, so do not split them per system.
- `x86_64-darwin` (Intel Mac) is out of scope. nixpkgs 26.11 has dropped support for it, so as long as we pin `nixpkgs-unstable` it `throw`s at evaluation time. Users who want to use it on an Intel Mac need to specify `nixpkgs-26.05-darwin` on their side (that branch also reaches EOL at the end of 2026).
- CI is split into one workflow per system. The actual work lives in a single reusable workflow, `.github/workflows/check.yml` (`workflow_call`, with `runs-on` as its input), which `ci-linux.yml` (`ubuntu-latest`) and `ci-darwin.yml` (`macos-latest`) call. This structure exists so the README can show a CI badge per system (GitHub badges are per workflow only and cannot distinguish matrix jobs). When adding check steps, edit only `check.yml`. macOS runner labels are retired on a fast cycle, so whenever you add or change one, always confirm that the label exists in the current [GitHub-hosted runners](https://docs.github.com/en/actions/reference/runners/github-hosted-runners) list. **Specifying a retired label does not make the job fail — it stays queued forever** (this happened before with `macos-13`).
- A local (Linux) `nix flake check` skips other systems with `omitted these incompatible systems`, so it cannot catch evaluation errors on the darwin side. Whenever you touch darwin-related code, verify evaluation alone with `nix eval .#checks.aarch64-darwin.<name>.drvPath`.

## Communication

- Communicate in Japanese.

## Version control

- Commit messages must follow conventional commits
- Pushing to main is forbidden. Always create a branch and merge via a PR
- Write commit messages and PRs in English
