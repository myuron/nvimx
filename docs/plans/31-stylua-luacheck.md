# #31 build: add stylua and luacheck to treefmt — 実装計画

対象 issue: [#31](https://github.com/myuron/nvimx/issues/31) `build: add stylua and luacheck to treefmt`

作業順序上の位置: #43（`plugins.json` の `optional` 削除）→ #42（`defaults.version` 取りこぼし修正）→ **#31（本件）** → #36 / #23 / #24 / #25 …。
以降の lua 実装が「整形済み・lint 済み」の土台の上で進むよう、あえて lua の機能追加より前に置いている。

計測値はすべて `d85558e` (main) の作業コピーを scratchpad に複製したうえで実測したもの。stylua 2.5.2 / luacheck 1.2.0 / treefmt 2.5.0（いずれも現在の `flake.lock` の **root** nixpkgs `d407951447dc` 由来。`7525d999cd85` は推移的入力 `nixpkgs_2` で `pkgsFor` は使わない）。

**この計測は `d85558e` 基準なので、着手時点（#43 と #42 のマージ後）にはずれる。** #43 は `resolve.lua` を 2 行短くし（luacheck のベースラインは 67 → 66 件、内容は全件 `vim` 関連のままで結論は不変）、`tests/fixtures/merge-config/init.lua` という lua を 1 本追加した。#42 はさらに fixture を 2 つ（= lua 2 本）追加する。**ファイル数や警告件数の絶対値は着手時に数え直すこと。** 設計上の結論（stylua の設定値、luacheck が設定のみで 0 件になること、差分規模が 1 ファイルに収まること）は post-#43 の実ツリーで再現確認済みで変わらない。

---

## 1. 背景 / 現状

### 1.1 formatter の構成

`flake.nix:118-126` が formatter の全体。

```nix
      formatter = forAllSystems (
        system:
        treefmt-nix.lib.mkWrapper (pkgsFor system) {
          projectRootFile = "flake.nix";
          programs = {
            nixfmt.enable = true;
          };
        }
      );
```

- 入力は `flake.nix:4` の `treefmt-nix.url = "github:numtide/treefmt-nix"`。
- `flake.lock` の `treefmt-nix` ノード: `rev = df3c0640565d04a0261253cdd89fce78ec50168a` / `lastModified = 1784369104`。この rev の `programs/` ディレクトリを実際に列挙したところ **`stylua.nix` は存在するが `luacheck.nix` は存在しない**（`selene.nix` も無い）。lua 系のモジュールは stylua だけ。
- `forAllSystems`（`flake.nix:31`）は `x86_64-linux` / `aarch64-darwin` の 2 system。`formatter` は system 依存なので既に `forAllSystems` で包まれている（`CLAUDE.md` の「Structure notes」の規約どおり）。
- `pkgsFor`（`flake.nix:32`）は `import nixpkgs { inherit system; }`。

実測した生成物（`nix build .#formatter.x86_64-linux` → `bin/treefmt` が指す `treefmt.toml`）:

```toml
excludes = ["*.lock", "*.patch", "package-lock.json", "go.mod", "go.sum", ".gitattributes", ".gitignore", ".gitmodules", ".hgignore", ".svnignore", "LICENSE"]

[formatter.nixfmt]
command = "/nix/store/…-nixfmt-1.4.0/bin/nixfmt"
excludes = []
includes = ["*.nix"]
options = []
```

`excludes` は `enableDefaultExcludes` の既定値そのまま。`nixfmt` のバージョンは 1.4.0（`programs.nixfmt` の `package` は `pkgs.nixfmt`）。
なお `nix/lib/lock-app.nix:14` は生成 flake の整形に `pkgs.nixfmt-rfc-style` を使っている。現 nixpkgs では実体は同じだが、本件では触らない。

`nix fmt` の現状実測:

```
traversed 86 files
emitted 21 files for processing
formatted 21 files (0 changed) in 175ms
```

対象は `*.nix` の 21 ファイルのみ。`nix fmt -- --ci` も同じ結果で exit 0。**lua 13 ファイルは 1 つも処理されていない。**

### 1.2 checks の構成

`flake.nix:128` から `flake.nix:1167` までが `checks`。`nix eval --json .#checks.x86_64-linux --apply builtins.attrNames` の実測:

```
build-network-detect, build-registry, build-shell, extractor-no-setup, extractor-snapshot,
hm-module, hm-module-degrade, hm-module-plugins, hm-module-treesitter, plugin-drv-phases,
plugins-escape-hatch, plugins-nixpkgs-fallback, plugins-overrides, resolve-build-warnings,
resolve-merge, treesitter-grammars, wrapper-aliases
```

17 個。**整形/lint 系の check は 1 つも無い**（`treefmt-nix` の `build.check` も未使用。`mkWrapper` は `config` を返さないので現状の書き方では `build.check` に手が届かない）。

### 1.3 CI

`.github/workflows/check.yml` が唯一の実作業ワークフロー（`ci-linux.yml` / `ci-darwin.yml` が `workflow_call` で呼ぶ）。

- `.github/workflows/check.yml:18-19`: `nix flake check`
- `.github/workflows/check.yml:21-22`: `nix fmt -- --ci`

`CLAUDE.md` の規約により、check ステップを増やす場合も編集するのは `check.yml` のみ。**本件では新しいステップは要らない**（1.4 / 6 節参照）。

`treefmt --help` で確認したとおり `--ci` は `--no-cache` + `--fail-on-change` の合成。したがって既存の `nix fmt -- --ci` ステップだけで「未整形」も「lint 失敗」も落ちる。

### 1.4 lua ファイルの現状

| ファイル | 行数相当 | 最長行 | 備考 |
| --- | --- | --- | --- |
| `lua/nvimx/extract.lua` | 129 | 98 (L119) | |
| `lua/nvimx/resolve.lua` | 396 | 117 (L283) | 最長 |
| `lua/nvimx/genflake.lua` | 99 | 110 (L57) | |
| `lua/nvimx/json.lua` | 70 | 105 (L58) | |
| `lua/nvimx/bootstrap.lua.in` | 43 | 84 (L24) | **`.lua` ではない**テンプレート |
| `templates/default/nvim/init.lua` | 21 | 77 | |
| `tests/fixtures/*/init.lua` ×7 + `local-plugin/lua/local-plugin.lua` | 各 ~10-25 | 101 | fixture |

スタイルは全ファイル共通で 2 スペースインデント / ダブルクォート優先 / 最長 117 桁。tab インデントは 1 つも無い。

`lua/nvimx/bootstrap.lua.in` のプレースホルダは `bootstrap.lua.in:4` の `local farm = "@farm@"` **1 箇所だけ**で、しかも文字列リテラルの内側。置換は `nix/lib/bootstrap.nix:5` の `builtins.replaceStrings [ "@farm@" ] [ "${farm}" ]`。

### 1.5 luacheck の現状（設定なしでの実測）

`luacheck --no-config` を lua 13 ファイルに対して実行:

```
Total: 67 warnings / 0 errors in 13 files
```

内訳（すべて `vim` に関するもの。それ以外の指摘はゼロ）:

| ファイル | 件数 | 種別 |
| --- | --- | --- |
| `lua/nvimx/extract.lua` | 9 | accessing undefined variable `vim` |
| `lua/nvimx/resolve.lua` | 11 | 同上 |
| `lua/nvimx/json.lua` | 4 | 同上 |
| `lua/nvimx/genflake.lua` | 3 | 同上 |
| `templates/default/nvim/init.lua` | 7 | 6 件 accessing + 1 件 mutating non-standard global (`:11` の `vim.g.mapleader = " "`) |
| `tests/fixtures/basic-config/init.lua` | 7 | 6 件 accessing + 1 件 mutating (`:10`) |
| `tests/fixtures/unbuildable-config/init.lua` | 6 | accessing |
| `tests/fixtures/build-plugins/init.lua` | 5 | accessing |
| `tests/fixtures/merge-config/init.lua` | 5 | accessing |
| `tests/fixtures/registry-plugins/init.lua` | 5 | accessing |
| `tests/fixtures/treesitter-config/init.lua` | 5 | accessing |
| `tests/fixtures/empty-config/init.lua` | 0 | OK |
| `tests/fixtures/local-plugin/lua/local-plugin.lua` | 0 | OK |

重要な実測 2 点:

- **`arg` は警告されない。** `std = "min"`（全 std の共通部分）でも `arg[1]` / `#arg` は通る。luacheck は standalone interpreter の `arg` を標準グローバルとして持っているため、`nvim -l` 由来の `arg`（`resolve.lua:31,59` / `genflake.lua:9`）は globals 宣言が不要。
- **未使用変数・shadowing・`_G` 汚染などの指摘は 1 件も無い。** つまり `vim` を globals に入れるだけで既存コードは lint clean になる（1.6 参照）。

### 1.6 luacheck の設定候補ごとの実測

| `.luacheckrc` | 結果 |
| --- | --- |
| `std = "luajit"` + `globals = { "vim" }` | **0 warnings / 0 errors in 13 files** |
| `std = "lua51"` + `globals = { "vim" }` | 0 / 0 |
| `std = "min"` + `globals = { "vim" }` | 0 / 0 |
| `std = "luajit"` + `read_globals = { "vim" }` | 2 warnings（`setting read-only field g.mapleader of global vim`: `templates/default/nvim/init.lua:11`, `tests/fixtures/basic-config/init.lua:10`） |

`bootstrap.lua.in` も単体で `luacheck` に通した結果 **OK**（0 warnings）。

### 1.7 treefmt のフォーマッタ実行モデル（実測）

プローブスクリプトを formatter として登録して確認した挙動:

- **cwd はツリールート**、引数は**ツリールート相対パス**、対象ファイルは**1 バッチでまとめて渡される**。
  → 結果として、リポジトリルートに置いた `stylua.toml` / `.luacheckrc` は「上位ディレクトリ探索」で確実に発見される。`nix fmt` をサブディレクトリや `/` から実行しても発見できることを実測で確認済み。
- **同一ファイルにマッチする複数 formatter は priority 昇順で逐次適用される**（並列ではない）。プローブ A（ファイルにマーカー追記）→ プローブ B（マーカー検出）で検証:
  - A:1 / B:2 → B は A の出力を見た
  - B:1 / A:2 → B は A の出力を見なかった（＝順序が効いている）
  - priority 省略（両方 0）→ 名前順にフォールバック（`aaa` → `bbb`）
  → priority を省略すると **`luacheck` < `stylua`** の名前順で luacheck が先に走る。明示指定が必要。
- **formatter が非ゼロ終了したファイルはキャッシュされない。** lint エラーを残したまま `nix fmt` を 3 回連続実行し、3 回すべて同じエラーが報告され exit 1 になることを実測。
- 失敗時のメッセージ:
  - lint 失敗 → `Error: failed to finalise formatting: formatting failures detected`
  - 未整形 → `Error: unexpected changes detected, --fail-on-change is enabled`
  いずれも exit 1。

### 1.8 パッケージの可用性（darwin 含む）

| | attr | version | `meta.platforms` に `aarch64-darwin` |
| --- | --- | --- | --- |
| stylua | `pkgs.stylua` | 2.5.2 | ✅ |
| luacheck | `pkgs.luaPackages.luacheck` | 1.2.0-1 (lua5.2) | ✅ |

- `pkgs.luacheck` というトップレベル attr は**存在しない**（`nix eval nixpkgs#luacheck.version` は "Did you mean logcheck?" で失敗）。`luaPackages.luacheck` / `lua51Packages.luacheck` のどちらかを使う。
- `lib.getExe pkgs.luaPackages.luacheck` は `…/bin/luacheck` を返す（`meta.mainProgram = "luacheck"` が設定済み）。treefmt-nix の `settings.formatter.<name>.command` は `exeType` なので derivation をそのまま渡せる。
- `aarch64-darwin` での評価も実測済み: `stylua-2.5.2` / `lua5.2-luacheck-1.2.0-1` がどちらも評価できる。
- x86_64-darwin は `CLAUDE.md` どおりスコープ外。

---

## 2. ゴール

issue の "Done when" を検証可能な形に落としたもの。

| # | ゴール | 検証コマンド / 期待値 |
| --- | --- | --- |
| G1 | `nix fmt` が lua も整形する | `nix fmt` の `emitted` 件数が「nix ファイル数 + `find . -name '*.lua' \| wc -l`」に一致し、`bootstrap.lua.in` を含まない。**絶対数で判定しないこと**（#42 が fixture を 2 つ増やす） |
| G2 | クリーンチェックアウトで `nix fmt -- --ci` が通る | exit 0、`formatted 34 files (0 changed)` |
| G3 | 未整形の lua で CI が落ちる | 適当な lua に `local  x  =  1` を入れて `nix fmt -- --ci` → exit 1 / `unexpected changes detected` |
| G4 | lint に引っかかる lua で CI が落ちる | 適当な lua に未定義グローバル呼び出しを入れて `nix fmt -- --ci` → exit 1 / `failed to finalise formatting` |
| G5 | 既存 lua に lint 警告が 0 件 | `luacheck` が**全 lua ファイル**で `0 warnings / 0 errors`（ファイル数は着手時点で数え直す） |
| G6 | 既存の nixfmt 設定が壊れていない | `treefmt.toml` の `[formatter.nixfmt]` が変わらない / `*.nix` 21 ファイルに差分が出ない |
| G7 | `bootstrap.lua.in` の扱いが明文化されている | 設計と `docs/architecture.md` に記述（3.5 節） |
| G8 | darwin でも評価できる | `nix eval --raw .#formatter.aarch64-darwin.drvPath` が drv を返す |
| G9 | `nix flake check` が引き続き通る | 既存 17 checks に影響なし（lua の整形が挙動を変えていないことの確認も兼ねる） |

---

## 3. 設計

### 3.1 stylua: treefmt-nix の `programs.stylua` をそのまま使う

`treefmt-nix` の当該 rev には `programs/stylua.nix` があり、`mkFormatterModule { name = "stylua"; includes = [ "*.lua" ]; }` で登録されている。つまり `programs.stylua.enable = true;` だけで `[formatter.stylua]`（`includes = ["*.lua"]`）が生える。追加実装は不要。

### 3.2 stylua の設定値 — 既存コードに合わせる

採用する `stylua.toml`:

```toml
column_width = 120
line_endings = "Unix"
indent_type = "Spaces"
indent_width = 2
quote_style = "AutoPreferDouble"
call_parentheses = "Always"
collapse_simple_statement = "Never"
```

根拠（すべて実測ベース）:

| 項目 | 値 | 根拠 |
| --- | --- | --- |
| `indent_type` / `indent_width` | `Spaces` / `2` | 既存 lua は例外なく 2 スペース。stylua の既定は `Tabs` / `4` なので**必ず指定が必要**。指定しないと全ファイルが tab 化する（3.3 の実測 496/492 行） |
| `column_width` | `120` | 下表の実測で churn 最小。既存最長行 117 桁がそのまま残る |
| `quote_style` | `AutoPreferDouble` | 既定値。既存はダブルクォート優先で、エスケープが増える箇所（`resolve.lua:374-375,378` の `'…"<name>"…'`）だけシングルのまま残る。この挙動が既存の意図と一致する |
| `line_endings` | `Unix` | 既定値。明示しておく（Windows チェックアウト対策） |
| `call_parentheses` | `Always` | 既定値。既存コードは `require("lazy")` のように常に括弧付き |
| `collapse_simple_statement` | `Never` | 既定値。既存に 1 行 `if` は無い。`Always` にすると `resolve.lua` の多数の `if … then return … end` が潰れて差分が爆発する |
| `sort_requires.enabled` | **設定しない（= 既定 false）** | `extract.lua:74-78` は `require("lazy.core.config")` → `Config.setup(...)` → `require("lazy.core.plugin")` の順序が意味を持つ。今は間に文があるので連続ブロックにならず対象外だが、将来 require が並んだときに勝手に並べ替えられると壊れうるので明示的に無効のまま |

`column_width` の実測比較（`stylua --config-path` を lua 13 ファイルに適用して `git diff --shortstat`）:

| `column_width` | 差分 |
| --- | --- |
| 100 | 3 files changed, 29 insertions(+), 9 deletions(-) |
| 110 | 1 file changed, 7 insertions(+), 3 deletions(-) |
| **120** | **1 file changed, 2 insertions(+), 5 deletions(-)** |
| 130 | 1 file changed, 6 insertions(+), 15 deletions(-) |

### 3.3 設定ファイルの置き場所: `stylua.toml` をコミットする（Nix 側には書かない）

`treefmt-nix` の `programs/stylua.nix` は `programs.stylua.settings` が非空のとき **store 上に `stylua.toml` を生成して `--config-path <store path>` を渡す**。つまり選択肢は排他:

| 案 | 内容 | 評価 |
| --- | --- | --- |
| **A（採用）** | `stylua.toml` をリポジトリルートにコミットし、`programs.stylua.settings` は**設定しない** | `--config-path` が付かないので stylua は通常の探索（対象ファイルのディレクトリから上方向）でルートの `stylua.toml` を見つける。**実測で動作確認済み**（`nix fmt` 後もインデントが 2 スペースのまま）。エディタ／LSP から直接 stylua を叩く経路（nvimx は neovim プロジェクトであり、コントリビュータは neovim で lua を編集する）と CI が同じ設定を共有できる。issue #31 の `Files` 節も `stylua.toml (new)` を挙げている |
| B | `programs.stylua.settings` に Nix で書く | 設定が `flake.nix` に一元化される。**設定を変えると `--config-path` の store path が変わるので treefmt のキャッシュが自動で無効化される**（A にはこの性質が無い — R5 参照）。だがエディタ側は設定を持てず、CI と手元の整形結果がずれる。さらにルートに `stylua.toml` を置いても `--config-path` に負けて**黙って無視される**という罠を生む |

→ **A を採用**。キャッシュ無効化を失う点は R5 のコストとして受け入れる（CI は `--no-cache` なので取り逃しは起きない）。`flake.nix` 側には「`settings` を設定しないのは意図的」というコメントを残す（そうしないと将来「Nix に書いたほうが綺麗」と B に寄せられ、`stylua.toml` がサイレントに死ぬ）。

**エディタ統合の注意**: stylua の上方向探索は既定で無効で、`--search-parent-directories` が必要。実測では `lua/nvimx/` に cd して `stylua --check extract.lua` は exit 1（既定の Tabs/4 と判定）、`-s` 付きなら exit 0。treefmt 経由は cwd がツリールートなので問題ない。エディタ統合（conform.nvim 等）はこのフラグを渡すこと。この注意は 6.5 の確認手順と PR 本文にも残す。

同じ理由で `.luacheckrc` もリポジトリルートにコミットする（3.4）。

### 3.4 luacheck: treefmt の汎用 formatter エントリとして載せる

luacheck は formatter ではなく linter だが、**treefmt に載せる**。

`treefmt-nix` の当該 rev に `programs.luacheck` は**無い**ので、`mkFormatterModule` 経由は使えない。ただし `module-options.nix` の `settings.formatter` は `attrsOf (submodule { freeformType = toml; options = { command; options; includes; excludes; }; })` なので、**任意のコマンドを formatter として登録できる**。

```nix
settings.formatter.luacheck = {
  command = pkgs.luaPackages.luacheck;
  includes = [ "*.lua" ];
  priority = 2;
};
```

`command` の型は `exeType`（derivation を渡すと `lib.getExe`）なので derivation をそのまま書ける。`priority` は `freeformType` 経由で通る。

#### 案の比較

| 案 | 内容 | 長所 | 短所 |
| --- | --- | --- | --- |
| **A（採用）** | `settings.formatter.luacheck` として treefmt に載せる | 入口が `nix fmt` ひとつ。CI は既存の `nix fmt -- --ci` ステップのままで G3/G4 を両方満たす。stylua → luacheck の逐次実行が priority で保証される（1.7）。treefmt-nix 自身が `shellcheck` / `statix` / `mypy` / `yamllint` / `golangci-lint` / `clang-tidy` / `ruff-check` / `actionlint` など**多数の純 linter を同じ方式で提供している**ので、方式としては上流の既定路線 | 「formatter」という名前空間の意味的な濫用。treefmt のキャッシュにより、成功済み・未変更のファイルは再 lint されない（ただし**失敗したファイルはキャッシュされない**ことを実測済み。CI は `--ci` = `--no-cache` なので影響なし） |
| B | 独立した `checks.<system>.luacheck` derivation | `nix flake check` の一部になる。「linter は check」という素直な分類 | ソースツリー全体を derivation に入れる必要があり、`self` 依存で lua 以外の変更でも再ビルドされる。`nix fmt` では検出できないので手元での即時フィードバックが弱い。`checks` を 1 個増やす分だけ `flake.nix` が太る。CI ステップは増えない（`nix flake check` に乗る）が、**整形と lint の入口が 2 つに割れる** |
| C | 両方（treefmt + checks） | 冗長 | 同じ失敗が 2 回報告される。得るものがない |

→ **A を採用**。決定理由は「issue の Done when（`nix fmt` が lua を扱い、CI が lint 失敗で落ちる）を最小の変更で満たす」「上流 treefmt-nix が linter を同じ方式で扱っている前例が多数ある」「stylua との実行順序を treefmt が保証してくれる」の 3 点。
キャッシュの懸念は 1.7 の実測（失敗ファイルは非キャッシュ）で実害が無いと確認できたので、A の欠点は「名前空間の意味論」だけに縮む。

#### priority の必要性

`stylua.priority = 1` / `luacheck.priority = 2` を**明示する**。1.7 の実測どおり priority 省略時は名前順で `luacheck` → `stylua` になり、luacheck が**整形前**のファイルを読む。lint 結果自体は空白に依存しないので実害は小さいが、

- 3.6 の `max_line_length` を将来もし有効化した場合に「stylua が直す前の長い行」で落ちる
- 「書き換える側が先、読む側が後」が自明でない

ため、意図を設定に書く。

### 3.5 `.luacheckrc` の内容と `bootstrap.lua.in` / includes・excludes

採用する `.luacheckrc`:

```lua
-- nvimx の lua はすべて neovim (LuaJIT) の中で走る。
std = "luajit"
-- vim は read_globals ではなく globals: 設定 lua は vim.g.mapleader などを書き換える。
globals = { "vim" }
-- 行幅は stylua が持つ。ここで二重に上限を持つと、stylua が折れない行で詰む。
max_line_length = false
```

| 項目 | 決定 | 根拠 |
| --- | --- | --- |
| `std` | `"luajit"` | neovim の lua は LuaJIT（Lua 5.1 + 一部 5.2）。`luajit` std は `jit` / `bit` / `ffi` も含むので将来 `vim.loop` 以外の低レベル API を使っても足りる。`lua51` / `min` でも今は 0 件だが、意味的に `luajit` が正しい |
| `vim` | `globals`（not `read_globals`） | 1.6 の実測どおり `read_globals` にすると `vim.g.mapleader = " "` が `setting read-only field` で 2 件落ちる（`templates/default/nvim/init.lua:11` / `tests/fixtures/basic-config/init.lua:10`）。これは正当なコードなので `globals` にする |
| `arg` | **宣言しない** | 1.5 の実測どおり luacheck は `arg` を標準グローバルとして認識する（`std = "min"` でも通る）。冗長な宣言は入れない。ただし理由をコメントに残すか、`.luacheckrc` のコメントで「`arg` は `nvim -l` 由来だが luacheck の std に含まれるため宣言不要」と明記する |
| `max_line_length` | `false` | 3.6 参照 |
| `exclude_files` | **設定しない** | fixture も template も `globals = { "vim" }` だけで 0 件になる（1.6）。除外は不要で、除外しないほうが「ユーザーが書く形の lua」も検査対象に入って価値が高い |

#### `bootstrap.lua.in` の扱い

**lint / 整形の対象から外す。** 明示的な `excludes` は不要 — `*.lua` グロブが `bootstrap.lua.in` にマッチしないので、treefmt の既定で自動的に対象外になる（現状の `nix fmt` で `emitted 21 files`、変更後 `emitted 34 files` = 21 nix + lua 13 で、`bootstrap.lua.in` はどちらにも含まれない。`on-unmatched` の既定でも警告は出ないことを実測済み）。

外す理由と、外すことで失うもの:

- `bootstrap.lua.in` は `@farm@` プレースホルダを含むテンプレートであり、**厳密には置換後の形でしか lua として検査できない**。
- 現状は唯一のプレースホルダ（`bootstrap.lua.in:4`）が文字列リテラルの内側にあるため、偶然そのまま lua としてパースできる。実測でも stylua は差分ゼロ、luacheck は 0 warnings。
- しかしこれは偶然に依存している。プレースホルダを文字列外（例 `local n = @count@`）に置いた瞬間、stylua は `error: could not format file … expected identifier after '@'` で **exit 2** になり `nix fmt` 全体が壊れる（実測確認済み）。
- したがって「`*.lua.in` を includes に足す」案は採らない。テンプレートは検査対象外とし、**その事実を `docs/architecture.md` に明記する**（G7）。
- 失うもの: `bootstrap.lua.in` の整形とスタイル逸脱の検出。43 行と小さく、変更頻度も低いので許容する。将来これが問題になったら「`.in` を `substituteAll` ではなく `bootstrap.lua` + 引数注入に変える」（プレースホルダを廃して普通の `.lua` にする）が本筋の解であり、その時に別 issue で扱う。

### 3.6 `max_line_length = false` の根拠（実測）

luacheck の既定は `max_line_length = 120`。stylua の `column_width` も 120 に揃えるので一見整合するが、**stylua の `column_width` は「目安」であり強制ではない**（treefmt-nix の option description にも "this is not a hard requirement: lines may fall under or over the limit" とある）。実測:

```
$ cat long.lua
local msg = "xxx…(145 chars)…xxx"   # 154 桁
$ stylua --config-path stylua.toml long.lua   # 折り返して 2 行に
$ stylua --config-path stylua.toml --check long.lua
(exit 0)                                       # 整形後は idempotent
$ luacheck long.lua                            # max_line_length = 120 (default)
long.lua:2:121: line is too long (144 > 120)
```

つまり **stylua が「これで完成」と言う形が luacheck の既定を満たさないケースが存在し、`nix fmt` をどれだけ回しても clean にならないデッドロック**になる。行幅の権威は stylua 一本にし、luacheck 側は無効化する。

（現状の最長行は整形後 117 桁なので、既定 120 のままでも今は通る。将来の詰みを避けるための設定であり、`.luacheckrc` にその理由をコメントで残す。）

### 3.7 変更後の `formatter` の形

```nix
      formatter = forAllSystems (
        system:
        let
          pkgs = pkgsFor system;
        in
        treefmt-nix.lib.mkWrapper pkgs {
          projectRootFile = "flake.nix";
          programs = {
            nixfmt.enable = true;
            # stylua はリポジトリルートの stylua.toml を読む。programs.stylua.settings を
            # 設定しないのは意図的: 設定すると store 上に stylua.toml が生成されて
            # --config-path で渡され、リポジトリの stylua.toml が黙って無視される
            # -- エディタと CI で整形結果がずれる。
            stylua.enable = true;
            # stylua は書き換える側、luacheck は読むだけ。treefmt は同一ファイルに
            # マッチする formatter を priority 昇順で逐次適用するので、順序をここで固定する
            # (省略すると名前順で luacheck が先に走る)。
            stylua.priority = 1;
          };
          # luacheck は formatter ではなく linter なので treefmt-nix に programs.luacheck が無い。
          # treefmt が formatter に求めるのは「パスを受け取り、失敗したら非ゼロで終わる」だけで、
          # luacheck はファイルを書き換えないのでそのまま載る (上流も shellcheck / statix /
          # yamllint などを同じ方式で提供している)。設定は .luacheckrc から読む。
          settings.formatter.luacheck = {
            command = pkgs.luaPackages.luacheck;
            includes = [ "*.lua" ];
            priority = 2;
          };
        }
      );
```

`(pkgsFor system)` を 2 回参照するので `let pkgs = pkgsFor system; in` を挟む（`checks` / `packages` / `apps` が同じ形なのでリポジトリの流儀と一致）。

実測した生成 `treefmt.toml`:

```toml
excludes = ["*.lock", "*.patch", …, "LICENSE"]     # 既存と同一

[formatter.luacheck]
command = "/nix/store/…-lua5.2-luacheck-1.2.0-1/bin/luacheck"
excludes = []
includes = ["*.lua"]
options = []
priority = 2

[formatter.nixfmt]
command = "/nix/store/…-nixfmt-1.4.0/bin/nixfmt"   # 既存と同一 (G6)
excludes = []
includes = ["*.nix"]
options = []

[formatter.stylua]
command = "/nix/store/…-stylua-2.5.2/bin/stylua"
excludes = []
includes = ["*.lua"]
options = []                                       # ← --config-path なし = stylua.toml を探索
priority = 1
```

---

## 4. 一括整形の扱い

### 4.1 実測: 差分規模

`stylua.toml`（3.2 の値）を適用したときの `git diff --stat`:

```
 lua/nvimx/resolve.lua | 7 ++-----
 1 file changed, 2 insertions(+), 5 deletions(-)
```

**1 ファイル 2 行追加 5 行削除だけ。** 「既存 lua 全ファイルが一括で整形される」という前提だったが、既存コードは既に stylua と実質同じスタイルで書かれており、設定を既存に合わせれば churn はほぼゼロになる。

対比として、`stylua.toml` を置かず stylua の既定（Tabs / 4）で走らせた場合:

```
 12 files changed, 496 insertions(+), 492 deletions(-)
```

→ **`stylua.toml` のコミットは load-bearing**。無いと 1000 行規模の tab 化が起きる。この対比自体が「設定ファイルをリポジトリに置く」判断（3.3）の裏付けでもある。

### 4.2 実際の差分（全量）

```diff
--- a/lua/nvimx/resolve.lua
+++ b/lua/nvimx/resolve.lua
@@ -340,10 +340,7 @@ for name, p in pairs(raw.plugins or {}) do
        if is_true(entry.pin) and not is_tag_ref(norm(entry.resolvedRef)) then
          -- pin beats the constraint: the rev is whatever the lock happens to hold, and nothing
          -- ever checks it against the range. Frozen silently, this is a trap.
-        warn_plugin(
-          name,
-          ("pinned; version constraint %q is not validated (pin wins)"):format(tostring(p.version))
-        )
+        warn_plugin(name, ("pinned; version constraint %q is not validated (pin wins)"):format(tostring(p.version)))
        elseif is_null(entry.resolvedRef) then
@@ -370,7 +367,7 @@ end
 if unbuildable then
-  note('these plugins are installed with helptags only. To give them a real build:')
+  note("these plugins are installed with helptags only. To give them a real build:")
   note('  - programs.nvimx.plugins.overrides."<name>" = { pkgs, src, ... }: <your derivation>;')
```

- 1 つ目（`resolve.lua:343-346`）: 手で改行していた `warn_plugin(...)` が 1 行（117 桁）に戻る。直下の `:349` が既に同じ形の 1 行呼び出しなので、**整形後のほうが周囲と揃う**。意味の変化なし。
- 2 つ目（`resolve.lua:373`）: シングルクォート → ダブルクォート。この文字列に `"` は含まれないため。直後の `:374-375,378` は `"` を含むのでシングルのまま残る（`AutoPreferDouble` の意図どおり）。

### 4.3 レビュー可能性の担保

差分が 7 行なので**整形コミットと機能コミットを分ける必要は無い**。ただし PR を読む側が「どこまでが自動整形か」を即断できるように、以下を守る:

1. **コミットを 2 本に分ける**（差分の大小に関わらず、性質で分ける）
   - `build: add stylua and luacheck to treefmt` — `flake.nix` / `stylua.toml` / `.luacheckrc` / `docs/architecture.md`。lua には一切触らない。
   - `style: reformat lua with stylua` — `nix fmt` の出力だけ。**手作業の変更を 1 行も混ぜない**（`git diff` の内容が `stylua` の出力と bit 単位で一致すること）。
   - 順序はこの通り（設定 → 適用）。1 本目の時点では `nix fmt -- --ci` は落ちる（未整形が検出される）が、PR 単位では 2 本目で clean になる。CI は PR の HEAD に対して走るので問題ない。
2. **2 本目のコミットメッセージに再現手順を書く**: `nix fmt` を走らせただけであること、`stylua.toml` の設定値、差分が 2 insertions / 5 deletions であること。
3. lint 側の修正コミットは**発生しない**（4.4）。もし将来 lint 修正が必要になったら `fix(lua): …` として 3 本目に分ける。
4. `nix flake check` を整形後に回して、既存 17 checks（特に `extractor-snapshot` / `resolve-merge` / `resolve-build-warnings`）が通ることを確認する。lua は snapshot 比較の**生成側**なので、整形が挙動を変えていないことの実質的な証明になる（`tests/fixtures/golden/` に `.lua` は無いので golden 自体は整形の影響を受けない）。

### 4.4 luacheck の既存警告一覧と処理方針

1.5 の実測 67 件の内訳と処理:

| 警告 | 件数 | 処理 |
| --- | --- | --- |
| `accessing undefined variable vim` | 65 | **設定で解決**（`.luacheckrc` の `globals = { "vim" }`）。コード修正ゼロ |
| `mutating non-standard global variable vim`（`templates/default/nvim/init.lua:11`, `tests/fixtures/basic-config/init.lua:10`） | 2 | **同じく設定で解決**。`read_globals` ではなく `globals` にすることで消える。`vim.g.mapleader = " "` は正当なコードなので `-- luacheck: ignore` は入れない |

**コード修正が必要な箇所はゼロ。** `.luacheckrc` を置いた時点で `0 warnings / 0 errors in 13 files`（実測）。inline の `-- luacheck:` ディレクティブも `exclude_files` も一切不要。

### 4.5 #43 / #42 との干渉

本件の前に #43（`optional` 削除）と #42（`defaults.version`）が入るため、`resolve.lua` / `extract.lua` の行番号はずれる。#43 相当の変更（`extract.lua` の `optional = p.optional,` と `resolve.lua` の `optional = p.optional or vim.NIL,` を削除）を scratchpad で先に適用してから再計測した結果:

```
stylua:   1 file changed, 2 insertions(+), 5 deletions(-)   # 変わらず
luacheck: 0 warnings / 0 errors in 13 files                 # 変わらず
```

→ 差分の内容・規模は #43 / #42 の後でも同じ。ただし **実装時には必ず `nix fmt` を実際に走らせて `git diff` を確認する**（本計画の行番号は `d85558e` 基準であり、#43 / #42 の分だけ数行ずれる）。#42 が `extract.lua` に長い行を追加していた場合はそこにも整形が入りうるので、`git diff --stat` を見て 4.3 の 2 本目コミットの説明を実測値に合わせる。

---

## 5. 実装手順

### 5.1 `stylua.toml`（新規、リポジトリルート）

3.2 の 7 行をそのまま。各値に「既定値と同じだが明示する」旨のコメントは付けない（TOML が短いほうが読みやすい）。代わりに冒頭に 1 行:

```toml
# Matches the style lua/nvimx/*.lua is already written in (2-space, double quotes, <=120 cols).
# Read by both `nix fmt` (treefmt -> stylua) and editors/LSP running stylua directly.
```

### 5.2 `.luacheckrc`（新規、リポジトリルート）

3.5 の内容。コメントで以下を必ず書く:

- `vim` が `read_globals` ではなく `globals` である理由（`vim.g.mapleader` への代入）
- `arg`（`nvim -l` 由来）は luacheck の std に含まれるので宣言不要であること
- `max_line_length = false` の理由（行幅の権威は stylua）
- `lua/nvimx/bootstrap.lua.in` は `*.lua` にマッチしないため検査対象外であること

### 5.3 `flake.nix:118-126` の `formatter` ブロックを差し替え

3.7 のコードに置換。触るのはこの 9 行だけ。

- `flake.nix:2-13` の `inputs` は変更なし（`treefmt-nix` 済み、`stylua` / `luacheck` は nixpkgs から取る）。
- `flake.nix:128` 以降の `checks` は変更なし（3.4 の案 A を採るので `checks.<system>.luacheck` は作らない）。
- `forAllSystems` の外に出さない（`CLAUDE.md` の Structure notes）。
- `let pkgs = pkgsFor system; in` を挟むのを忘れないこと（`pkgs` を 2 回参照するため）。

### 5.4 `nix fmt` を走らせて整形コミットを作る

```
nix fmt
git diff --stat        # 期待: lua/nvimx/resolve.lua のみ、2 insertions / 5 deletions
```

`flake.nix` 自身も nixfmt の対象なので、5.3 の編集が nixfmt 的に整形済みであることもここで確認できる（`nix fmt` 実行後 `flake.nix` に差分が出ないこと）。

### 5.5 `docs/architecture.md` の更新

- `docs/architecture.md:425`（Repository layout の `bootstrap.lua.in # runtime bootstrap template`）に「`.lua` ではないので stylua / luacheck の対象外」という注記を足す。
- Repository layout のルート部分（`docs/architecture.md:403` の `flake.nix` の隣）に `stylua.toml` / `.luacheckrc` を追記する。
- `docs/architecture.md:474`（`- CI: nix flake check (offline checks) + confirming nix fmt has been applied`）を、`nix fmt` が nix と lua の両方を扱い、lua の lint も同じステップで走ることが分かる文に更新する。

なお `docs/architecture.md` は英語（`CLAUDE.md` の Version control 節は commit / PR を英語と定めており、既存ドキュメントも英語）。**本計画書だけが日本語**。

### 5.6 `.github/workflows/check.yml`

**変更なし。** 既存の `nix fmt -- --ci`（`:21-22`）が `--no-cache --fail-on-change` 相当なので、未整形も lint 失敗もこのステップで落ちる（1.7 / 6 節で実測）。
`CLAUDE.md` の規約「CI check ステップを追加するときは `check.yml` のみを編集する」に該当する作業は発生しない。この「変更不要である」ことを PR 本文に明記して、レビュアが `ci-linux.yml` / `ci-darwin.yml` を探さずに済むようにする。

### 5.7 コミット / PR

`CLAUDE.md` の Version control に従う。

1. ブランチを切る（main への直 push 禁止）: `build/stylua-luacheck`
2. コミット 2 本（4.3 の分割）。conventional commits / 英語。
3. PR を英語で作成。
4. **PR を開いたら `fable` モデルのサブエージェントで `/review` を回し、結果を読んで対応する**（`CLAUDE.md`）。

---

## 6. テスト

### 6.1 `nix fmt` — 正常系（G1 / G2 / G6）

```
$ nix fmt
traversed 88 files
emitted 34 files for processing        # 21 nix + 13 lua (bootstrap.lua.in は含まれない)
formatted 34 files (1 changed)         # 初回のみ resolve.lua が変わる

$ nix fmt -- --ci
traversed 88 files
emitted 34 files for processing
formatted 34 files (0 changed)         # exit 0
```

いずれも scratchpad の実リポジトリ複製に 3.7 の `flake.nix` / 5.1 / 5.2 を適用して**実測済み**。

確認項目:
- `emitted` が 21 → 34 に増えていること（lua が処理対象に入った証拠）
- 整形後の lua に tab が 1 つも無いこと（`grep -lP '^\t' $(find . -name '*.lua')` が空）
- `*.nix` 21 ファイルに差分が出ないこと（G6）

### 6.2 `nix fmt -- --ci` — 失敗系（G3 / G4）

**未整形**（`lua/nvimx/json.lua` の `local M = {}` を `local M    =    {}` に）:
```
ERRO file has changed path=lua/nvimx/json.lua …
Error: unexpected changes detected, --fail-on-change is enabled
exit=1
```

**lint 失敗**（`bogus_undefined_global()` を追加）:
```
lua/nvimx/json.lua:5:1: accessing undefined variable bogus_undefined_global
Total: 1 warning / 0 errors in 13 files
Error: failed to finalise formatting: formatting failures detected
exit=1
```

どちらも実測済み。なお `--ci` は失敗前にワーキングツリーを整形してしまう（treefmt の仕様）。これは nix についても現状すでにそうなので変化なし。

キャッシュの確認（1.7）: lint エラーを残したまま `nix fmt` を 3 回連続実行し、3 回すべて exit 1 かつ同じ警告が出ることを確認する。

### 6.3 `nix flake check`（G9）

```
nix flake check
```

`checks` は変更しないので新しい check は増えないが、**4.3-4 のとおり整形後に必ず 1 回通す**。`extractor-snapshot`（`lua/nvimx/extract.lua` を実行して `tests/fixtures/golden/basic-config.raw-spec.json` と比較）、`resolve-merge` / `resolve-build-warnings`（`resolve.lua` を直接叩く）が、整形が lua の挙動を変えていないことの実証になる。

`CLAUDE.md` のとおり、Linux での `nix flake check` は他 system を `omitted these incompatible systems` でスキップするので darwin の評価エラーは捕まえられない。→ 6.4。

### 6.4 darwin の評価確認（G8）

`formatter` は `checks` ではないので `CLAUDE.md` の `nix eval .#checks.aarch64-darwin.<name>.drvPath` の形をそのまま使えない。formatter 版で確認する:

```
$ nix eval --raw .#formatter.aarch64-darwin.drvPath
/nix/store/…-treefmt.drv          # 実測: 評価できた
```

併せてパッケージ側も確認済み:

```
$ nix eval --impure --expr 'let p = import <nixpkgs> { system = "aarch64-darwin"; }; in
    { stylua = p.stylua.name; luacheck = p.luaPackages.luacheck.name; }' --json
{"luacheck":"lua5.2-luacheck-1.2.0-1","stylua":"stylua-2.5.2"}
```

`meta.platforms` にも両方 `aarch64-darwin` を含む（1.8）。したがって `.github/workflows/ci-darwin.yml`（`macos-latest`）でも `nix fmt -- --ci` は動く。

既存 `checks` 側の darwin 評価は本件では変更しないので追加確認は不要だが、`flake.nix` を触るので念のため `nix eval .#checks.aarch64-darwin.hm-module.drvPath` を 1 本流して回帰が無いことを見る。

### 6.5 エディタ経路の確認（3.3 の A 案の要件）

リポジトリルートで `stylua --check lua/nvimx/resolve.lua` と `luacheck lua/nvimx/resolve.lua` を **`--config-path` / `--config` なしで**直接実行し、どちらも 0 件で終わること（= ルートの設定ファイルが探索で見つかること）を確認する。これが崩れていると CI と手元の結果がずれる。

---

## 7. リスク / 未決事項

| # | リスク | 影響 | 緩和 |
| --- | --- | --- | --- |
| R1 | `programs.stylua.settings` を将来誰かが設定し、`--config-path` がルートの `stylua.toml` を上書きする | エディタと CI の整形結果が黙ってずれる | `flake.nix` に「意図的に設定していない」コメントを残す（3.7）。6.5 の確認手順を PR に書く |
| R2 | nixpkgs 更新で stylua のメジャーバージョンが上がり、既定の整形結果が変わる | `nix fmt -- --ci` が突然落ちる、あるいは大きな再整形差分 | `nix flake update` の PR で `nix fmt -- --ci` が落ちるので必ず気付く。`stylua.toml` に明示している項目が増えるほど影響は小さい。stylua 側の互換方針として `stylua.toml` の未知キーはエラーになるので、キーを増やすときは慎重に |
| R3 | luacheck が treefmt の「formatter」名前空間に居ることの違和感 | 将来 `programs.luacheck` が treefmt-nix に入ったとき二重定義になりうる | 上流に `programs/luacheck.nix` が入ったら `settings.formatter.luacheck` を `programs.luacheck.enable` に移行する。それだけの局所的な変更。`flake.nix` のコメントに「上流に programs.luacheck が無いため手書きしている」と理由を残す |
| R4 | `bootstrap.lua.in` が検査対象外なので、そこだけスタイル/lint が劣化する | 43 行の小ファイルなので実害は小さい。ただしプレースホルダを増やしたときに気付きにくい | `docs/architecture.md` に明記（5.5）。現在の内容は stylua / luacheck ともにクリーンであることを実測済みなので、逸脱したら人間のレビューで見える。将来的にはプレースホルダを廃して普通の `.lua` にするのが本筋（別 issue） |
| R5 | treefmt のキャッシュは「対象ファイル + command(options 込み)」で決まり、リポジトリ上の `stylua.toml` / `.luacheckrc` の編集を見ない | **どちらの設定ファイルを変えても** 手元の `nix fmt` は `0 changed` のまま何もしない（実測: 整形済みツリーで `indent_width = 4` にしても無反応、`--clear-cache` で初めて全 lua が再インデントされた）。案 B（`--config-path <store path>`）なら設定変更が options の変化としてキャッシュを自動無効化するので、これは案 A のコストである | CI は `--ci` = `--no-cache` なので、設定を変えて整形し忘れた PR は必ず落ちる。手元で疑ったら `nix fmt -- --clear-cache`。失敗ファイルは非キャッシュであることは実測済み（1.7） |
| R6 | #42 / #43 で `extract.lua` / `resolve.lua` が変わり、本計画の行番号・差分規模がずれる | 4.3 の 2 本目コミットの説明が実測と合わなくなる | #43 相当を適用した状態で再計測し、規模が変わらないことを確認済み（4.5）。実装時に `git diff --stat` で実測値を取り直す |
| R7 | `luaPackages.luacheck` は lua5.2 ビルド。neovim は LuaJIT(5.1) | luacheck が動く lua のバージョンは解析対象の `std` とは無関係（`std` は設定で決まる）ので実害なし | `.luacheckrc` の `std = "luajit"` で解析対象の方言を明示している。`lua51Packages.luacheck` に替える必要は無い（同 1.2.0-1） |
| R8 | `max_line_length = false` により極端に長い行が入り込む | 可読性の劣化 | stylua の `column_width = 120` が通常の行は折る。折れないのは長い文字列リテラルだけで、それは人間のレビュー対象 |

### 未決事項

1. **`checks.<system>.formatting` を追加するか。** `treefmt-nix.lib.mkWrapper` を `evalModule` に変えれば `config.build.check self` が使えて `nix flake check` にも整形チェックが載る。ただし CI では `nix fmt -- --ci` と完全に重複し、`self` 依存の derivation が 1 個増える。**本件では追加しない**方針（issue の Done when は `nix fmt -- --ci` で満たされる）。追加したくなったら別 issue。
2. **fixture / template の lua を検査対象に含め続けるか。** 現状 0 件で通るので含める（3.5）。将来「lazy.nvim の変わった書き方」を再現する fixture を追加したときに lint と衝突する可能性がある。その時点で `exclude_files = { "tests/fixtures/" }` に切るか、fixture 側に `-- luacheck: ignore` を入れるかを決める。**先回りして除外はしない**（fixture は「ユーザーが書く形の lua」であり、そこが lint を通ることには価値がある）。
3. **`.editorconfig` を置くか。** stylua は `.editorconfig` も読む（`--no-editorconfig` で無効化できる）。現状リポジトリに `.editorconfig` は無く、`stylua.toml` が唯一の権威なので競合しない。将来 `.editorconfig` を入れるなら、`indent_size` などが `stylua.toml` と矛盾しないようにする必要がある。本件では作らない。
