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

Updating is `nvimx-lock --update` (moves every plugin that is not `pin = true`) or
`nvimx-lock --update <name>...` (moves only the named plugins, pinned or not) → commit → switch.
Either form prints a summary of what moved, what was skipped because it is pinned, and what was
added or removed. `--update` with no names is the most expensive form: it re-resolves every
plugin's version constraint, so it is worth reserving for when you actually mean "update
everything" rather than running it out of habit. `--update <name>...` moves the named inputs with
`nix flake update <inputName>...` — the input name derived from the plugin's, not the name you
type — whose positional-argument form needs Nix ≥ 2.19; older Nix would need
`nix flake lock --update-input <name>` by hand instead.

## Migrating from lazy.nvim

If you already run lazy.nvim, you have a `lazy-lock.json` recording the exact commit of every
installed plugin. `nvimx-lock --import-lazy-lock` seeds those commits into the first lock, so the
migration does not move a single plugin: you get the plugin set you are running today, under nix,
and you decide when to move forward.

1. Copy your existing config into the repo — `init.lua`, the `lua/` tree, **and `lazy-lock.json`** —
   and `git add` all of it. Nix only sees git-tracked files.

2. Lock with the import. `lazy-lock.json` sits inside your config directory, so the path can be
   omitted:

   ```bash
   nix run github:myuron/nvimx#lock -- --config ./nvim --out ./nvim/nvimx-lock --import-lazy-lock
   ```

   Pass a path explicitly if it lives somewhere else:
   `--import-lazy-lock ~/.config/nvim/lazy-lock.json`. A missing file is an error, not a silent
   fallback — a fallback would move every plugin to today's HEAD, which is what this flag exists
   to prevent.

3. Read the import report before committing. It is printed at the very end of the run and accounts
   for every entry in `lazy-lock.json`:

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
  `lazy-lock.json` has for it is reported and skipped.
- For a plugin on a non-GitHub git URL whose spec names no `branch`, the imported commit becomes
  `git+<url>?rev=<sha>` with no ref. Most servers serve that fine, but one that refuses to serve an
  unadvertised object will fail at `nix flake lock`, naming the input. Adding `branch = "..."` to
  that plugin's spec fixes it.

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
| `plugins.overrides` | `attrsOf (functionTo package)` | `{ }` | Per-plugin derivation overrides, keyed by the plugin name lazy derived. See [Escape hatches](#escape-hatches). |
| `plugins.nixpkgsFallback` | `listOf str` | `[ ]` | Plugin names to take from `pkgs.vimPlugins` as-is instead of building from the lock. Opt-in per plugin. See [Escape hatches](#escape-hatches). |
| `treesitter.grammars` | `nullOr (either (enum [ "all" ]) (listOf str))` | `null` | Tree-sitter grammars to merge into the locked `nvim-treesitter`, so no `:TSInstall` ever runs. See [Tree-sitter grammars](#tree-sitter-grammars). |
| `lock.installCommand` | `bool` | `true` | Add the `nvimx-lock` command to `home.packages`. |
| `lock.projectDir` | `nullOr str` | `null` | The working tree of your dotfiles repository. When set, running `nvimx-lock` with no arguments targets `configDirRelative` / `lockDirRelative`. |
| `lock.configDirRelative` | `str` | `"nvim"` | Path to `configDir`, relative to `projectDir`. |
| `lock.lockDirRelative` | `str` | `"nvim/nvimx-lock"` | Path to `lockDir`, relative to `projectDir`. |
| `env` | `attrs` | _(derived)_ | The result of `makeEnv` (`farm` / `bootstrap` / `wrapped` / `pluginDrvs` / `unknownPluginNames` / `treesitterWithoutPlugin` / `hasLock`). Built automatically from the options above; a direct escape hatch for advanced users. |

`lockDir` is the only option without a default, so it must always be set. `configDir` is also required whenever `manageConfig` is `true` (the default), which is enforced by an assertion in the module.

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
luarocks build (`build = "rockspec"`), or a `*.lua` file has nothing nvimx can execute directly
(and neither do the non-shell elements of a list build), so that part is skipped and the plugin is
installed with helptags only, plus whatever shell steps did run — and `nvimx-lock` says so, listing
every such plugin at the end of its output, along with which of its steps could not run,
and pointing at the hatches above (at `treesitter.grammars` for `nvim-treesitter`). The same list is
recorded in `plugins.json` under `warnings`. Locking still succeeds; this is a warning, not an
error. It is emitted by the Lua resolver, which runs before any Nix evaluation and therefore cannot
see your config — so a plugin you have already handled with an override keeps being listed. A build
of `false`, or a list with nothing unrunnable in it, says nothing at all.

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

## Acknowledgments

nvimx is inspired by [emacs-twist/twist.nix](https://github.com/emacs-twist/twist.nix), which builds an
entire Emacs configuration as a pure Nix package. Its core model — read the configuration you already
write, fetch each package from its upstream repository, and pin every one of them in `flake.lock` — is
what nvimx applies to Neovim and lazy.nvim. Where the two differ (nvimx resolves the spec at lock time
with a headless Neovim instead of at evaluation time, so no `--impure` is needed) is listed in
[docs/architecture.md](docs/architecture.md#appendix-main-divergences-from-twistnix).
