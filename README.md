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
   `nvimx-lock` reads your working tree, so it locks an untracked Lua file just the same — but a
   flake only sees git-tracked files, so home-manager would then deploy your config without it.
   `nvimx-lock` warns about config files git does not track yet and prints the `git add` to run.

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

   Do not skip the `git add`. A flake only sees git-tracked files, so an untracked lock
   directory is invisible to home-manager and the build degrades exactly as if you had never
   locked. `nvimx-lock` prints a note when the lock it just wrote is not tracked yet. Locking
   itself does not need the directory to be tracked.

The order is not actually rigid. Switching without a lock does not fail: the build *degrades* to a
lazy.nvim-only Neovim and warns you, while still installing the `nvimx-lock` command. Running
`nvimx-lock` → commit → switching again gets you to the full state either way.

Adding a plugin later is the same loop: write the spec → `git add` → `nvimx-lock` → commit → switch.
Existing pins stay untouched; only the new plugin is fetched.

Updating is `nvimx-lock --update` (moves every plugin that is not `pin = true`) or
`nvimx-lock --update <name>...` (moves only the named plugins, pinned or not) → commit → switch.
Either form prints a summary of what moved, what was skipped because it is pinned, and what was
added or removed. `--update` with no names is the most expensive form: it re-resolves every
plugin's version constraint, so it is worth reserving for when you actually mean "update
everything" rather than running it out of habit. `--update <name>...` moves the named inputs with
`nix flake update --flake path:. <inputName>...` — the input name derived from the plugin's, not
the name you type — whose positional-argument form needs Nix ≥ 2.19; older Nix would need
`nix flake lock --update-input <name>` by hand instead — and inside a git repository that bare form
fails while the lock directory is untracked, so track it first or pass `path:.` as the flake
reference.

### Machine-readable summary

`nvimx-lock ... --summary-json <path>` also writes a JSON report of what the run moved, for bots
that build a PR body. It works with a plain lock (`mode: "lock"`, which prints no summary text),
`--update`, `--update <name>...` and `--import-lazy-lock`. The file is deleted as soon as the
command line has been parsed, so after any run that got that far it exists only if the run
succeeded; rejected arguments (exit 2 for a usage error) leave it untouched, so scripts should
check the exit status as well. Its parent directory must exist. Keep it outside the lock
directory, or it shows up there as an untracked file.

The top-level keys are `schemaVersion` (currently `1`; it is bumped on any incompatible change),
`mode` (`update-all`, `update-named` or `lock`), `requested`, `updated`, `added`, `removed`,
`skippedPinned`, `unchanged` and `unexplained` (the plugins in the "moved without being named"
warning). Keys come out sorted alphabetically and arrays sorted by plugin name. As in the stderr
summary, `update-named` mode lists only the requested plugins plus whatever moved, so `unchanged`
is not a full inventory there. In `lock` mode nothing is skipped, so a pinned plugin is
`unchanged`. To see whether anything changed, test `(.updated + .added + .removed) | length > 0`.

`updated`, `added` and `removed` share one entry shape: `name`, `inputName`, `source` (as in
`plugins.json`), `from` and `to` (full revs, `null` where not applicable), `fromRef` and `toRef`
(the resolved refs), `reason` (`tag-changed`, `version-resolved`, `unpinned`, `spec-changed` or
`null`) and `compareUrl`. `compareUrl` is set for `updated` entries from a GitHub source only, with
the full revs (`https://github.com/<owner>/<repo>/compare/<from>...<to>`), and is `null`
otherwise. For example, a PR body table:

```sh
jq -r '"| Plugin | Old | New |\n|---|---|---|", (.updated[] | "| \(.name) | \(.from[0:7] // "-") | \(if .compareUrl then "[\(.to[0:7])](\(.compareUrl))" else .to[0:7] end) |")' summary.json
```

## Migrating from lazy.nvim

If you already run lazy.nvim, you have a `lazy-lock.json` recording the exact commit of every
installed plugin. `nvimx-lock --import-lazy-lock` seeds those commits into the first lock, so the
migration does not move a single plugin: you get the plugin set you are running today, under nix,
and you decide when to move forward.

1. Copy your existing config into the repo — `init.lua`, the `lua/` tree, **and `lazy-lock.json`** —
   and `git add` all of it. `nvimx-lock` and the import read your working tree either way, but a
   flake only sees git-tracked files, so anything you leave untracked would be missing from the
   config home-manager deploys.

2. Lock with the import. `lazy-lock.json` sits inside your config directory, so the path can be
   omitted:

   ```bash
   nix run github:myuron/nvimx#lock -- --config ./nvim --out ./nvim/nvimx-lock --import-lazy-lock
   ```

   Pass a path explicitly if it lives somewhere else:
   `--import-lazy-lock ~/.config/nvim/lazy-lock.json`. A missing file is an error, not a silent
   fallback — a fallback would move every plugin to today's HEAD, which is what this flag exists
   to prevent.

3. Read the import report before committing. It is printed at the end of the run, after
   `nix flake lock`'s output, and accounts for every entry in `lazy-lock.json`:

   - `import: pinned <name> to <sha>` — locked to exactly the commit lazy recorded
   - `import: <name> is not in lazy-lock.json; it will resolve normally` — the only plugins that
     move. lazy only writes plugins it has actually installed, so this is usually a plugin you
     added to the spec but never started nvim with
   - `import: skipped ...` — an entry your spec overrides (it already fixes a `commit`, or names a
     different `branch`); the spec wins. Also covers a local (`dev`/`dir`) plugin, which has nothing
     to pin, and the aggregate `import: skipped N entries already decided by the existing lock` on a
     re-import, once `plugins.json` already has its own decision for those entries
   - `import: ignored ...` — an entry with no plugin in the config to attach to

4. Cross-check, then commit:

   ```bash
   jq -r '.plugins | to_entries[] | "\(.key) \(.value.resolvedRef)"' nvim/nvimx-lock/plugins.json
   git add nvim/nvimx-lock && git commit -m "migrate nvim plugins to nvimx"
   ```

   Each `resolvedRef` should be the commit `lazy-lock.json` has under the same name, and each
   `locked.rev` in `nvim/nvimx-lock/flake.lock` should be that same commit again.

   Until the lock directory is tracked, home-manager cannot see it and builds the degraded
   Neovim; `nvimx-lock` reminds you if it is not.

5. From here on, run plain `nvimx-lock`. `--import-lazy-lock` is a one-shot migration: once
   `plugins.json` exists, every decision in it wins over the imported file, so a second import is a
   no-op that only prints `import: skipped N entries already decided by the existing lock`. When
   you want to start moving forward, that is `nvimx-lock --update [name...]`.

A few things worth knowing:

- `--import-lazy-lock` cannot be combined with `--update`. One says "hold still at lazy's
  commits", the other says "move to today's HEAD"; run them as two separate locks.
- The import does not check version constraints. If your spec uses an explicit `version`, the
  imported commit is taken as-is and the run reports `import: version constraint ... is not
  validated for N plugin(s) pinned from lazy-lock.json`; a constraint that instead comes from
  `defaults = { version = "*" }` gets the wording `import: the config-wide version constraint ...
  is not validated for N plugin(s) pinned from lazy-lock.json`. That is deliberate: the whole
  migration then needs no network at all, because lazy already resolved those constraints for you.
  `nvimx-lock --update <name>` resolves one for real whenever you want it checked again.
- `lazy.nvim` itself is not imported: nvimx pins it through its own flake input, so the entry
  `lazy-lock.json` has for it is reported and skipped. This only applies when your own config does
  not list lazy.nvim itself -- a fork included, not just `folke/lazy.nvim` (#49) -- if it does,
  that entry is imported like any other plugin's.
- For a plugin on a non-GitHub git URL whose spec names no `branch`, the imported commit becomes
  `git+<url>?rev=<sha>` with no ref. Most servers serve that fine, but one that refuses to serve an
  unadvertised object will fail at `nix flake lock`, naming the input. Adding `branch = "..."` to
  that plugin's spec fixes it.
- For a plugin on the scp-style URL shorthand (`git@host:owner/repo.git`), the imported commit is
  lost the first time it locks under #28's source URL validation: that URL is normalized to
  `ssh://git@host/owner/repo.git`, which changes the plugin's spec identity and drops whatever
  `resolvedRef` it carried, imported commit included. It is not re-derived on the next lock either,
  since re-deriving it is not what a plain lock does. Simply re-running the import does not bring it
  back: an existing entry in `plugins.json`, even with `resolvedRef` already null, blocks the reseed.
  To recover it, delete that plugin's entry from `plugins.json` first, then run `--import-lazy-lock`
  again.
- A git-type source URL that already carries `?ref=` / `?rev=` -- and does not also set `branch` /
  `tag` / `commit`, the only combination that ever locked -- now fails outright under #28's source
  URL validation, since a source URL may no longer carry a query string at all. Move it into the
  spec fields instead: `?ref=<x>` becomes `branch = "<x>"` or `tag = "<x>"`, `?rev=<sha>` becomes
  `commit = "<sha>"`.

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
| `defaultEditor` | `bool` | `false` | Set `EDITOR` to `nvim` in `home.sessionVariables`. `EDITOR` only — unlike home-manager's own `programs.neovim.defaultEditor`, `VISUAL` is left alone — and the value is the bare command name, resolved through the `PATH` that `home.packages` already provides. |
| `extraPackages` | `listOf package` | `[ ]` | Packages prepended to the wrapper's `PATH` (ripgrep, language servers, etc.). |
| `extraLuaPackages` | `functionTo (listOf package)` | `ps: [ ]` | Lua rocks to put on the wrapper's `LUA_PATH` / `LUA_CPATH`, as a function over the Lua package set of the Neovim you chose. luarocks itself stays disabled. See [Lua rocks](#lua-rocks). |
| `extraWrapperArgs` | `listOf str` | `[ ]` | Extra `makeWrapper` arguments for the wrapped Neovim, one per list element, appended after nvimx's own: environment variables set for Neovim rather than session-wide, `--suffix PATH`, extra flags. nvimx protects none of its own arguments from them. See [Wrapper arguments](#wrapper-arguments). |
| `withPython3` | `nullOr bool` | `null` | The Python 3 provider. `true`: build a host from nixpkgs (`pkgs.python3` with `pynvim`) and point `vim.g.python3_host_prog` at it. `false`: disable the provider. `null`: leave Neovim's own discovery alone, as before this option existed. See [Providers](#providers). |
| `extraPython3Packages` | `functionTo (listOf package)` | `ps: [ ]` | Python packages to add to the Python 3 provider's host, as a function over `pkgs.python3`'s package set. Only used when `withPython3 = true`, though the list is still evaluated otherwise, so a package that fails to evaluate is an error either way. See [Providers](#providers). |
| `withRuby` | `nullOr bool` | `null` | The Ruby provider, with the same three states. `true` uses the `neovim-ruby-host` nixpkgs builds and appends its Ruby to the wrapper's `PATH`; `GEM_HOME` is not set. See [Providers](#providers). |
| `withNodeJs` | `nullOr bool` | `null` | The Node.js provider, with the same three states. `true` uses `pkgs.neovim-node-client` and appends `pkgs.nodejs` to the wrapper's `PATH`. See [Providers](#providers). |
| `devPlugins` | `listOf str` | `[ ]` | Plugin names to load from a working tree under `devPath` instead of the Nix store. See [Local plugin development](#local-plugin-development). |
| `devPatterns` | `listOf str` | `[ ]` | Substrings of a plugin's source url; every matching plugin loads from `<devPath>/<name>`, like lazy.nvim's `dev.patterns`. See [Local plugin development](#local-plugin-development). |
| `devPath` | `str` | `"~/projects"` | Where dev working trees live. A locally developed plugin — named in `devPlugins`, matched by `devPatterns`, or marked `dev = true` by your own spec — resolves to `<devPath>/<name>`, unless that spec entry writes `dir` itself, which lazy uses directly instead. Replaces lazy.nvim's own `dev.path`. A `str`, not a `path`: a path would copy the tree into the store. |
| `plugins.overrides` | `attrsOf (functionTo package)` | `{ }` | Per-plugin derivation overrides, keyed by the plugin name lazy derived. See [Escape hatches](#escape-hatches). |
| `plugins.nixpkgsFallback` | `listOf str` | `[ ]` | Plugin names to take from `pkgs.vimPlugins` as-is instead of building from the lock. Opt-in per plugin. See [Escape hatches](#escape-hatches). |
| `treesitter.grammars` | `nullOr (either (enum [ "all" ]) (listOf str))` | `null` | Tree-sitter grammars to merge into the locked `nvim-treesitter`, so no `:TSInstall` ever runs. See [Tree-sitter grammars](#tree-sitter-grammars). |
| `lock.installCommand` | `bool` | `true` | Add the `nvimx-lock` command to `home.packages`. |
| `lock.projectDir` | `nullOr str` | `null` | The working tree of your dotfiles repository. When set, running `nvimx-lock` with no arguments targets `configDirRelative` / `lockDirRelative`. |
| `lock.configDirRelative` | `str` | `"nvim"` | Path to `configDir`, relative to `projectDir`. |
| `lock.lockDirRelative` | `str` | `"nvim/nvimx-lock"` | Path to `lockDir`, relative to `projectDir`. |
| `env` | `attrs` | _(derived)_ | The result of `makeEnv` (`farm` / `bootstrap` / `wrapped` / `pluginDrvs` / `unknownPluginNames` / `treesitterWithoutPlugin` / `devDirs` / `unknownDevPluginNames` / `unusedPython3Packages` / `hasLock`). Built automatically from the options above; a direct escape hatch for advanced users. Setting it replaces the `makeEnv` call, so `extraPackages`, `extraLuaPackages`, `extraWrapperArgs` and every other option above that only feeds `makeEnv` are silently ignored. |

`lockDir` is the only option without a default, so it must always be set. `configDir` is also required whenever `manageConfig` is `true` (the default), which is enforced by an assertion in the module. On NixOS, `defaultEditor` shares `EDITOR` with a default NixOS sets on its own; see [`defaultEditor` on NixOS](#defaulteditor-on-nixos).

### `defaultEditor` on NixOS

On NixOS, `defaultEditor` can look as if it does nothing. NixOS exports `EDITOR=nano` on every
system: `nixos/modules/programs/environment.nix` sets `environment.variables.EDITOR = lib.mkDefault
"nano"` unconditionally, whether or not `programs.nano.enable` is set. That value and the one
`defaultEditor` writes to `home.sessionVariables` live in different module systems and never merge,
so nvimx cannot override it; which one you see depends only on which shell startup file exports
last.

- In a shell home-manager manages (`programs.bash.enable`, `programs.zsh.enable` or
  `programs.fish.enable`), NixOS's own shell init runs first (`/etc/profile` for bash,
  `/etc/zshenv` for zsh, `nixos-env-preinit.fish` for fish) and home-manager's session variables
  are sourced after it, so `nvim` wins: for bash only in a login shell, for zsh and fish in every
  shell.
- When the session's first (login) shell is one home-manager does not manage, its session
  variables are never sourced (see home-manager's FAQ, "Why are the session variables not set?")
  and `nano` is the only value left. Shells started later inherit whatever that first shell
  exported, so a fish login giving `nvim` while a bash login gives `nano` on the same machine is
  this case.

Either let home-manager manage that shell (or source `hm-session-vars.sh` yourself, as the FAQ
shows), or drop the NixOS default in your NixOS configuration, not your home-manager one:

```nix
environment.variables.EDITOR = lib.mkForce null; # null entries are filtered out
```

With only that line, a shell home-manager does not manage ends up with no `EDITOR` at all rather
than `nvim`. Note also that NixOS puts this default in `environment.variables`, not
`environment.sessionVariables`, so it is not in `/etc/pam/environment`.

### Escape hatches

Most plugins are pure Lua and need nothing beyond the default treatment. When one does — a build
step that cannot run inside the Nix sandbox, a missing dependency, a patch you need — you have two
options, and neither requires forking nvimx.

```nix
programs.nvimx.plugins = {
  # Take the nixpkgs package as-is instead of building from the lock.
  # Opt-in per plugin: names are never matched automatically, because that would silently
  # detach the plugin from its flake.lock pin. The nixpkgs attribute is looked up under the
  # name verbatim (LazyVim), then with "." replaced by "-" (CopilotChat.nvim ->
  # CopilotChat-nvim), then lowercased on top of that (telescope.nvim -> telescope-nvim).
  nixpkgsFallback = [ "telescope-fzf-native.nvim" ];

  overrides = {
    # Patch the derivation nvimx would have built.
    "telescope-fzf-native.nvim" =
      { pkgs, defaultDrv, ... }:
      defaultDrv.overrideAttrs (o: {
        nativeBuildInputs = o.nativeBuildInputs ++ [ pkgs.fzf ];
      });

    # Or replace it outright, building whatever you like from the locked source tree.
    "some-rust.nvim" =
      { pkgs, src, ... }:
      pkgs.rustPlatform.buildRustPackage { inherit src; /* ... */ };
  };
};
```

An override function receives `{ pkgs, name, src, build, defaultDrv, mkPluginDrv }` and returns a
derivation. Always accept `...` too — more arguments may be added later. `src` is the locked source
tree, and `defaultDrv` is the derivation that would have been used without the override, so patching
and replacing are both one-liners. `build` is either the scalar `{ kind, cmd }` shown below or, for a
table-form spec build, `{ kind = "steps", steps = [ { kind, cmd } ... ] }`; most overrides ignore it
and pass their own `build` to `mkPluginDrv` instead. `mkPluginDrv` is nvimx's generic builder
(`{ name, src, build } -> drv`), which is the shortest way to say "the usual treatment, but with the
build command corrected":

```nix
programs.nvimx.plugins.overrides."some.nvim" =
  { name, src, mkPluginDrv, ... }:
  mkPluginDrv {
    inherit name src;
    build = {
      kind = "shell";
      cmd = "make PREFIX=$out";
    };
  };
```

One caveat on `defaultDrv`: for a plugin whose declared build needs the network, `defaultDrv` is
the very derivation nvimx refuses to evaluate, so touching it re-raises that error. Such a plugin
needs either the wholesale-replacement form above (ignore `defaultDrv`, build from `src`), or a
`nixpkgsFallback` entry — which makes `defaultDrv` the nixpkgs package, and patching works again.

Resolution order, highest first:

1. `plugins.overrides."<name>"`
2. `plugins.nixpkgsFallback`
3. `nix/build-registry/` — nvimx's shipped build recipes
4. The generic build: run `build.kind == "shell"` (or the shell steps of `build.kind == "steps"`)
   if the spec declared one, otherwise a plain copy

A user's explicit opt-in outranks a shipped default, hence 1 and 2 above 3. Both apply only to
plugins present in the lock; a name that matches nothing there is reported as a warning at
activation time rather than silently doing nothing.

Only shell commands can run inside the Nix build sandbox. A spec whose `build` is a list of steps
(`build = { "make", ":TSUpdate" }`) has each element classified individually and runs its shell
steps, in declared order, each in its own subshell — so a mix of runnable and unrunnable steps
still gets as much done as it can. Each step starts from the plugin root with nothing carried over
from the one before, the same way lazy runs them, so `{ "cd deps", "make" }` is not the same as
`cd deps && make`. A spec whose `build` is an ex command (`build = ":TSUpdate"`), a Lua callback, a
luarocks build (`build = "rockspec"` — see [Lua rocks](#lua-rocks) for how to supply what it was
going to install), or a `*.lua` file has nothing nvimx can execute directly (and neither do the
non-shell elements of a list build), so that part is skipped and the plugin is installed with
helptags only, plus whatever shell steps did run — and `nvimx-lock` says so, listing every such
plugin at the end of its output, along with which of its steps could not run, and pointing at the
hatches above (at `treesitter.grammars` for `nvim-treesitter`, at [`extraLuaPackages`](#lua-rocks)
for a `rockspec` build). The same list is recorded in `plugins.json` under `warnings`. Locking
still succeeds; this is a warning, not an error. It is emitted by the Lua resolver, which runs
before any Nix evaluation and therefore cannot see your config — so a plugin you have already
handled with an override keeps being listed. A build of `false`, or a list with nothing unrunnable
in it, says nothing at all.

### The build registry

Some plugins are known to need more than what their spec declares — a build command that is simply
missing, or one that downloads something the Nix sandbox can never reach. `nix/build-registry/`
holds nvimx's own recipes for those, so they build correctly with nothing configured on your side.
It currently covers:

| Plugin | What the recipe does |
| --- | --- |
| `telescope-fzf-native.nvim` | Always the Makefile, whatever the spec declared. |
| `fzf` | Takes `bin/fzf` from nixpkgs instead of the release binary `./install --bin` downloads. |
| `nvim-treesitter` | Always copy + helptags: its Makefile fetches over the network, and parsers come from [`treesitter.grammars`](#tree-sitter-grammars) instead. |
| `blink.cmp` | Builds the Rust fuzzy matching library from your locked source, so neither `cargo build --release` (which needs the network) nor the runtime binary download has to happen. |

Registry entries are ordinary override functions that nvimx happens to ship, and they build your
locked source rather than silently swapping in a nixpkgs package. The `fzf` entry borrows only the
*binary* from nixpkgs, because the release binary its build downloads cannot be produced offline
from the locked source either; the plugin files still come from your lock. Since both hatches above
outrank the registry, you can replace an entry (`plugins.overrides`), take nixpkgs' package instead
(`plugins.nixpkgsFallback`), or go back to the generic treatment with `mkPluginDrv` as shown above.

Contributions are welcome: add `nix/build-registry/<plugin name>.nix`, list it in that directory's
`default.nix` (its header documents the criteria an entry has to meet), and extend
`checks.build-registry`.

### Tree-sitter grammars

`nvim-treesitter` is the one plugin the generic build cannot finish on its own: its parsers are
compiled at runtime by `:TSInstall`, into exactly the kind of user-owned mutable state nvimx exists
to avoid. So nvimx merges prebuilt grammars into the plugin instead, and you name the languages you
want:

```nix
programs.nvimx.treesitter.grammars = [ "lua" "nix" "rust" ];
# or, at the cost of a much larger build:
# programs.nvimx.treesitter.grammars = "all";
```

Names are nvim-treesitter's own language names — the ones `:TSInstall` takes, underscores and all
(`c_sharp`, not `c-sharp`). A name nixpkgs has no grammar for fails evaluation rather than quietly
leaving you without a parser, and a grammar that needs another one (`angular` needs `html`) pulls it
in for you. The default, `null`, leaves `nvim-treesitter` untouched.

Neovim finds the merged parsers on the runtimepath, which is all `vim.treesitter` (and therefore
highlighting) needs. nvim-treesitter's own bookkeeping is a separate matter: `get_installed()` and
`:checkhealth nvim-treesitter` only look at the directory `:TSInstall` writes to, so they will keep
reporting nothing installed.

The grammars come from `pkgs.vimPlugins.nvim-treesitter.grammarPlugins`: nixpkgs already builds
them, keys them by nvim-treesitter's language names, and lays each one out as `parser/<lang>.so`,
which is exactly where Neovim looks on the runtimepath. (`pkgs.tree-sitter-grammars` is the same
set one layer down, but named and shaped differently, so it would only mean re-deriving what
nixpkgs already gets right.) Queries always come from *your* locked `nvim-treesitter`, never from
nixpkgs' copy.

**Known limitation**: the grammar revs follow nixpkgs while the plugin rev follows your lock, so the
two are close but not identical. In practice this is fine — grammars and queries move slowly — but a
badly timed mismatch can produce a query error for a node type the parser does not have. Pinning
grammars to the locked `nvim-treesitter` revision (a strict mode) is future work. For the same
reason the grammars are built against nixpkgs' Neovim: if you point `package` at a nightly Neovim
with a different tree-sitter ABI, a parser may refuse to load.

### Local plugin development

Sometimes you are not using a plugin, you are writing one. Name it, and nvimx points lazy.nvim at
your working tree instead of the Nix store:

```nix
programs.nvimx = {
  devPlugins = [ "my-plugin.nvim" ];
  devPath = "~/projects";        # the default
};
```

`my-plugin.nvim` is then loaded from `~/projects/my-plugin.nvim`, and every other plugin still
comes from the store exactly as before. The name is the one lazy derived — the key in
`nvimx-lock/plugins.json` — and a name that matches nothing there is reported as a warning during
`home-manager switch` rather than silently doing nothing.

To load every plugin from one author (or any url fragment) from your working trees, match on the
url instead of naming each plugin:

```nix
programs.nvimx.devPatterns = [ "ryoppippi" ];
```

This is lazy.nvim's own `dev.patterns`: a plain, case-sensitive substring match against the url
lazy derived (`https://github.com/<owner>/<repo>.git`), first match wins, so `"ryoppippi"` and
`"github.com/ryoppippi/"` both work. Matching plugins load from `<devPath>/<name>`, stay in the lock
and the farm (remove the pattern and the pinned build is back, no re-lock), and a spec entry with
`dev = false` opts out while one that writes `dir` keeps its `dir`. lazy.nvim itself is never moved.

Plugins your lazy spec already marks `dev = true` need no entry here, and neither does a plugin
whose spec sets `dir` without `dev` at all: `nvimx-lock` records both kinds and nvimx wires them up
on its own, under `devPath` just the same. A spec entry that writes `dir` itself is the exception —
lazy uses that path directly and never consults `devPath` for it, so changing `devPath` will not
move it. Short of that, `devPath` is the one place that decides where dev working trees live. If
you were setting lazy.nvim's own `dev.path`, set `devPath` instead, and `devPatterns` for
`dev.patterns` — nvimx overrides both along with the rest of `dev`. `nvimx-lock` prints a warning when your spec sets `dev.patterns`, `dev.path` or `dev.fallback`, since nvimx ignores them at runtime.

Three things are deliberate:

- **A missing working tree is not a fallback.** If `~/projects/my-plugin.nvim` does not exist
  (this goes for `devPatterns` matches too), lazy simply shows the plugin as not installed. Quietly loading the store copy instead would
  mean editing files that are not the ones being loaded.
- **A dev plugin is outside the reproducibility guarantee.** While a name is listed, `flake.lock`
  no longer describes what you actually run. That is the whole point while you are working on it
  — and it is why the plugin also *stays* in the lock and in the farm: remove the name from
  `devPlugins` and the pinned build is back, with no re-lock and no re-fetch. And the working tree
  is loaded raw: no helptags, no `build` step output, no merged tree-sitter grammars — everything
  nvimx does to the store copy applies only to the store copy.
- **`devPath` is per-machine, and it is yours.** Nothing about where your working trees live is
  read back out of `nvimx-lock/`, so a lock you commit never *decides* where another machine
  loads a dev plugin from. (Only the plugin's name goes into the lock; the directory lazy
  resolved on the machine that ran it is never recorded.) Point `devPath` wherever you keep your
  projects.

### Lua rocks

lazy.nvim can install luarocks dependencies for a plugin. nvimx switches that off — `rocks.enabled`
is forced to `false`, so nothing is ever fetched or built at runtime — and lets you take the rock
from Nix instead:

```nix
programs.nvimx.extraLuaPackages = ps: [ ps.inspect ];
```

The function receives the Lua package set of the Neovim *you* chose — `package`'s own
`passthru.lua.pkgs`, which is `luajitPackages` for a stock nixpkgs Neovim — so the rocks always
match the interpreter that will load them, C rocks included. It is the same shape as
home-manager's `programs.neovim.extraLuaPackages`, and it composes: two modules can each add
rocks and the lists are concatenated. A rock nixpkgs does not package is reachable too, since the
argument is only a package set: `_: [ myOwnRock ]` works just as well.

What it touches is `LUA_PATH` and `LUA_CPATH`, and nothing else. `extraPackages` stays the way to
put an *executable* on `PATH`, and no Lua interpreter from this option is added to it. The
interpreter's own default search path survives, and so does a `LUA_PATH` you already export — the
rocks are prefixed to it, not substituted for it. (If that exported `LUA_PATH` has no `;;` in it,
the defaults stay out, exactly as they would for any other Lua program you run.) They are
exported, so anything Neovim launches — a `:terminal` shell, a language server, a `:!` command —
inherits them, and a Lua program run from there will find these rocks first. Ask for no rocks and
the wrapper is exactly what it was before, environment variables included.

This does not resurrect `build = "rockspec"`: that build kind still cannot run, and `nvimx-lock`
still warns about it — pointing you here. `extraLuaPackages` is how you satisfy the dependency
such a build was going to install.

### Wrapper arguments

`extraPackages` and `extraLuaPackages` each look after one part of the wrapper's environment. For
anything else, `extraWrapperArgs` hands you the `makeWrapper` call itself, in the same shape as
home-manager's `programs.neovim.extraWrapperArgs`:

```nix
programs.nvimx.extraWrapperArgs = [
  # A variable set for Neovim only, not for your login shell; Lua reads it as vim.env.MY_ASSET_DIR.
  "--set" "MY_ASSET_DIR" "${pkgs.someAsset}/share"
  # Tools that should lose to whatever is already on PATH. extraPackages would make them win.
  "--suffix" "PATH" ":" "${lib.makeBinPath [ pkgs.nodejs ]}"
];
```

It is a flat list with one `makeWrapper` argument per element, and every element is shell-escaped
for you: one containing spaces, quotes, `;` or `$` still reaches `makeWrapper` as the one argument
you wrote.

The arguments are appended after nvimx's own, and `makeWrapper` applies them in the order given:

1. `--add-flags "--cmd 'luafile <bootstrap.lua>'"`
2. `--prefix PATH` for `extraPackages`
3. `--set-default` and `--prefix` on `LUA_PATH` / `LUA_CPATH` for `extraLuaPackages`
4. a second `--cmd` and a `--suffix PATH` for `withPython3` / `withRuby` / `withNodeJs`
5. your `extraWrapperArgs`

So yours act on what the first four built. A `--prefix PATH` lands in front of `extraPackages`, an
`--add-flags` follows nvimx's `--cmd`, and a `--set` replaces the variable outright. nvimx protects
none of its own arguments: `--set PATH` discards `extraPackages`, and with it the `PATH` entries
`withRuby` / `withNodeJs` added (the Node.js host no longer starts without its `node`);
`--set LUA_PATH` discards the
rocks' Lua modules, and the interpreter's default search path too unless the new value contains
`;;` (`LUA_CPATH` is a separate variable and stays). That is what makes this an escape hatch, and
it is also why whatever you put here is yours to keep working.

This is not the order home-manager uses. There `extraPackages` is applied (as `--suffix PATH`)
after your arguments, so a list ported from `programs.neovim.extraWrapperArgs` that touches `PATH`
can behave differently here.

Three things worth knowing before you reach for it:

- nvimx's own `--prefix PATH` is there only while `extraPackages` is non-empty, and no option turns
  it into a `--suffix`. To have a tool lose to the `PATH` you already have, leave it out of
  `extraPackages` and add it here with `--suffix`, as above.
- Adding to `LUA_PATH` / `LUA_CPATH` by hand has the catch it has in any Lua program: once the
  variable is set, the interpreter's defaults are included only where the value says `;;`. When
  `extraLuaPackages` is in use nvimx has already put that `;;` there — unless you already export
  the variable without one — and a `--prefix` here keeps it. Otherwise start with
  `"--set-default" "LUA_PATH" ";;"` yourself — or use `extraLuaPackages`, which does.
- Some arguments take shell text rather than a literal value — in nixpkgs' `makeWrapper`, these are
  `--add-flags`, `--append-flags`, `--run` and `--argv0`: the value is written into the wrapper
  script as-is and interpreted every time Neovim starts, so a `$HOME` in it is expanded then
  (`--argv0` is expanded inside double quotes, so without word splitting). `--add-flag` /
  `--append-flag` (singular) pass one literal argument instead; they need nixpkgs 25.05 or later
  (the one your home-manager configuration uses), otherwise the build fails with
  `makeWrapper doesn't understand the arg --add-flag`.

A variable set here is exported, so the processes Neovim starts — a `:!` command, a `:terminal`
shell, a language server — inherit it unless they are started with an environment of their own.

### Providers

Remote plugins written in Python, Ruby or JavaScript — and `:python3` / `:ruby` — need a *provider*:
a host process Neovim starts and talks to. Three options, named after home-manager's
`programs.neovim` ones, say where each host comes from:

```nix
programs.nvimx = {
  withPython3 = true;                                # rplugin/python3, :python3, py3eval()
  extraPython3Packages = ps: [ ps.jupyter-client ];  # importable from that host
  withRuby = false;                                  # never used here: switch it off
  # withNodeJs is not mentioned, so Neovim keeps searching for a host by itself
};
```

Each `with*` option has three states:

| value | what nvimx does | what Neovim does |
| --- | --- | --- |
| `true` | builds the host from nixpkgs and sets `vim.g.<name>_host_prog` | uses that host instead of searching for one |
| `false` | sets `vim.g.loaded_<name>_provider = 0` | the provider is off, and no search happens |
| `null` (the default) | nothing | searches for a host itself the first time one is needed (`:help provider`) |

`true` and `false` mean what they mean in `programs.neovim`. `null` is nvimx's own: it is what
nvimx did before these options existed, so nothing changes for a setup that relies on it — but it
depends on what that search finds on the machine. Write `true` or `false` to take it out of the
picture: with `true` the host comes from Nix on every machine (for Node.js the host does, its
interpreter not quite — see below).

**Coming from `programs.neovim`, write the value you were getting.** Its defaults are not nvimx's:
there `withPython3` and `withRuby` default to `true` before `home.stateVersion = "26.05"` and to
`false` from then on, and `withNodeJs` to `false`. In particular, an `extraPython3Packages` line
that worked without any `withPython3` line needs `withPython3 = true` here; nvimx warns at
activation time when it sees one without the other.

What `true` builds, and what it adds to the wrapper besides the `vim.g` setting:

- **Python 3** — `pkgs.python3` with `pynvim` and your `extraPython3Packages`. Nothing is added to
  `PATH`: the packages are importable by Python remote plugins and `:python3`, not by a `python`
  you start from `:terminal`.
- **Ruby** — the `neovim-ruby-host` nixpkgs builds for its own Neovim wrapper. Its Ruby is appended
  to the wrapper's `PATH`, which is what `:checkhealth` looks for. Unlike nixpkgs' wrapper, nvimx
  does not set `GEM_HOME`: the host runs without it, and it would be exported to every process
  Neovim starts. Add it through [`extraWrapperArgs`](#wrapper-arguments) if you need it.
- **Node.js** — `pkgs.neovim-node-client`, with `pkgs.nodejs` appended to the wrapper's `PATH`:
  Neovim starts the host as `node <host>`, so it has to be there. As with `programs.neovim`,
  appending it also makes `node` available to plugins that run it themselves. The host therefore
  runs under the first `node` on `PATH` — yours, if you have one; put `pkgs.nodejs` in
  `extraPackages` to pin it.

`PATH` entries are *appended*, so a `node` or `ruby` you already have — or one in `extraPackages` —
stays in front. The `vim.g` settings are applied with `--cmd`, before your `init.lua`, so a
`vim.g.python3_host_prog` you set there still wins. With `false` that does not bring the provider
back by itself: `init.lua` has to unset `vim.g.loaded_python3_provider` as well.

`:checkhealth vim.provider` compares each host with its upstream registry over the network, so it
can report a host pinned by Nix as out of date, or report errors when you are offline. Neither means
the provider is broken, and the `npm install -g` style advice it gives does not apply: the host's
version follows your nixpkgs.

Two things these options do not do:

- **No remote-plugin manifest is generated.** Run `:UpdateRemotePlugins` yourself, and again after
  every plugin update: the manifest records each plugin's path, which is a Nix store path that
  changes with the lock.
- **There is no `withPerl`.** Neovim's own discovery applies to Perl as it always has; put
  `vim.g.loaded_perl_provider = 0` in your `init.lua` to switch it off.

## How it works

Network access happens only while locking. `nvimx-lock` runs a headless Neovim that really evaluates
your lazy spec, then persists the plugin list to `plugins.json` and the pins to `flake.lock`.

Extraction runs against the lazy.nvim your `flake.lock` pins, which is the one your Neovim loads.
nvimx's own pinned lazy.nvim is used only on the very first lock, and the spec is extracted again
whenever locking or updating moves lazy.nvim, so `plugins.json` always matches `flake.lock`.

Builds merely read those files, so evaluation is fully pure — no network, no `--impure`. From them
nvimx builds one derivation per plugin, collects them into a linkFarm, and wraps Neovim with a
generated `bootstrap.lua` so lazy.nvim loads from the Nix store instead of running its own
git/install pipeline. The same lock always yields the same result, no matter how often you switch
— the one exception being any plugin you deliberately point at a working tree with
[`devPlugins` or `devPatterns`](#local-plugin-development).

## Example

Author's dotfiles: [myuron/dotfiles](https://github.com/myuron/dotfiles/tree/main/home-manager/nvimx)

## Acknowledgments

nvimx is inspired by [emacs-twist/twist.nix](https://github.com/emacs-twist/twist.nix), which builds an
entire Emacs configuration as a pure Nix package. Its core model — read the configuration you already
write, fetch each package from its upstream repository, and pin every one of them in `flake.lock` — is
what nvimx applies to Neovim and lazy.nvim. The main difference is that nvimx resolves the spec at lock time
with a headless Neovim instead of at evaluation time, so no `--impure` is needed.
