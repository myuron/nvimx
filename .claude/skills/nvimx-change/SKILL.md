---
name: nvimx-change
description: Drive a non-trivial nvimx change through the required six-step subagent pipeline — plan, review the plan, implement, review the implementation, open a PR, review the PR. Use when starting any feature, bug fix, or refactor in this repository.
---

# nvimx change pipeline

Every non-trivial change goes through these six steps. Each step is delegated to a subagent via the `Agent` tool with the model named below. Do not skip a step and do not run one yourself — the point of the pipeline is that a fresh context reviews each artifact.

Trivial changes (typo fixes, a comment reword, bumping a single pinned hash) do not need this. If you are unsure, run the pipeline.

## 1. Plan — `model: "opus"`

The subagent writes a plan to `docs/plans/<issue-number>-<slug>.md` (e.g. `docs/plans/25-import-lazy-lock.md`). These files are tracked in git.

**Plans are written in Japanese.** This is deliberate and asymmetric with the rest of the repo: commit messages, PR descriptions, `CLAUDE.md`, and `docs/architecture.md` are all English, but every plan under `docs/plans/` is Japanese. Keep it that way.

Follow the section structure the existing ten plans have established:

```markdown
# #NN 対応計画: <title>

対象 issue: <link>

## 1. 背景 / 現状
## 2. ゴール
## 3. 設計
## 4. 既存機能との関係        ← or「#18 / #23 との関係」when it builds on other issues
## 5. 実装手順
## 6. テスト
## 7. リスク / 未決事項
## 8. 検証手順(実装完了時に必ず全部通す)
```

Existing plans quote real code and real command output rather than describing them abstractly — match that. Section 8 should list the exact commands from `CLAUDE.md`'s Commands section that apply to this change.

## 2. Review the plan — `model: "opus"`

Hand the plan to a fresh opus subagent for review. Address every finding, then hand the updated plan to another fresh subagent. Repeat until a review comes back with **zero findings**. Never reuse the subagent that wrote the plan.

## 3. Implement — `model: "sonnet"`

Follow the approved plan. Two things that bite here:

- **`git add` every new file before running any nix command.** Nix only sees files tracked by git, so an untracked new file is invisible to the flake and the build will fail in a confusing way.
- Comments in `flake.nix` and `nix/lib/` record *why*, often naming other checks and issue numbers. Match that density; a new check with no rationale comment is incomplete.

## 4. Review the implementation — `model: "opus"`

Fresh opus subagent, address every finding, re-review with another fresh subagent, repeat until zero findings.

Before declaring the step done, these must pass:

- `nix fmt -- --ci`
- `nix build .#checks.x86_64-linux.<name>` for each check touched or added (fast loop)
- `nix flake check` (full)
- `nix eval .#checks.aarch64-darwin.<name>.drvPath` — **only skippable if nothing darwin-related was touched.** A Linux `nix flake check` silently omits darwin, so this is the only local signal.

If `stylua.toml` or `.luacheckrc` changed, run `nix fmt -- --clear-cache` first — treefmt caches on file + command and would not otherwise notice.

## 5. Open a PR

Branch as `<type>/<slug>`. Conventional Commits, English, lowercase, imperative, no trailing period, scope = subsystem (`lock`, `resolve`, `hm`, `dev`, `extract`, `build-registry`, `plugin-drv`, `treesitter`, `wrapper`, `ci`). Write the PR body in English. Never push to main.

## 6. Review the PR — `model: "fable"`

Run `/review` on the PR in a fable subagent. Address every finding, re-review with a fresh fable subagent, repeat until zero findings.
