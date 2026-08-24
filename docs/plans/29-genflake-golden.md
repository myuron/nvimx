# #29 対応計画: spec マトリクスを golden 化する(`resolve-golden` / `genflake-golden`)

対象 issue: [#29 test: add genflake-golden check with richer fixtures](https://github.com/myuron/nvimx/issues/29)

作業ツリー: `/home/myuron/.cache/nvimx-worktrees/issue-29`(ブランチ `agent/issue-29`、`origin/main` = `0eadbcc`)。
本計画の `file:line` と実測出力はすべてこのツリー(= #28 マージ後の main)で確認している。

---

## 1. 背景 / 現状

### 1.1 issue 本文の前提のうち、**もう成立していないもの**

issue #29 は #28 より前に書かれており、本文の事実記述の大半が古い。実装前に棚卸しした結果:

| issue 本文の記述 | 現状 | 根拠 |
|---|---|---|
| 「check は 5 つしかない」 | **29 個ある** | 下記の実測 |
| 「`genflake.lua` と `resolve.lua` は **zero test coverage**」 | **誤り**。`resolve.lua` は 7 つの check が、`genflake.lua` は 4 つの check が実際に駆動している | §1.2 |
| 「`docs/architecture.md:348` が `checks.genflake-golden` を挙げている」 | 行が動いた。現在は **`docs/architecture.md:503`** の `- planned, not yet implemented: \`genflake-golden\` (#29), \`e2e-offline\` (#30)` | `grep -n genflake-golden docs/architecture.md` |
| 「golden fixture は `tests/fixtures/golden/basic-config.raw-spec.json` の 1 つだけ」 | **誤り**。golden ディレクトリ 5 つ / ファイル 9 本ある: `tests/fixtures/golden/basic-config.raw-spec.json` / `merge/golden/base.plugins.json` / `update/golden/{summary-all,summary-named,summary-none}.txt` + `update/golden/update-pinned.plugins.json` / `import-lazy-lock/golden/imported.plugins.json` / **`source-urls/golden/{ok.plugins.json,ok.flake.nix}`(#28 が追加)** | `find tests -path '*golden*'` |
| 「`genflake.lua` の `input_url` と `resolve.lua` の build classifier のあらゆる分岐が未カバー」 | **build classifier は全分岐カバー済み**(`checks.resolve-build-warnings`)。`input_url` にも未カバーの分岐は残っているが「あらゆる」ではない | §1.2 |
| `json.lua` は zero coverage | **専用 check は無い**が、既存 golden 9 本のうち **JSON は 5 本、うち `json.lua` の出力は 4 本**なので、キーソート・`[]` / `{}` の区別・エスケープは事実上固定されている。残る 1 本 `golden/basic-config.raw-spec.json` だけは `json.lua` を通らず、`extract.lua:167` の `vim.json.encode` の出力を `flake.nix:1294` の `jq -S 'del(.lazyNvim)'` で整形したものである | §7 で follow-up 扱い |

```console
$ nix eval .#checks.x86_64-linux --apply 'x: builtins.attrNames x'
[ "build-network-detect" "build-registry" "build-shell" "dev-plugins" "extra-lua-packages"
  "extractor-defaults-version" "extractor-no-setup" "extractor-snapshot" "hm-module"
  "hm-module-degrade" "hm-module-dev" "hm-module-lua-packages" "hm-module-plugins"
  "hm-module-treesitter" "plugin-drv-phases" "plugins-escape-hatch" "plugins-nixpkgs-fallback"
  "plugins-overrides" "resolve-build-warnings" "resolve-import-lazy-lock" "resolve-merge"
  "resolve-semver" "resolve-sources" "resolve-update" "semver-select" "source-parse"
  "treesitter-grammars" "update-summary" "wrapper-aliases" ]
```

**したがって本計画は issue の文言ではなく意図に従う**。issue の literal な要求(「2 つの golden check を足す」「fixture をマトリクスに拡張する」)は採るが、
その動機として書かれた「zero coverage だから」は採らない。実際に残っている穴(§1.2)を埋めることを目的にする。

### 1.2 いま本当にカバーされていないもの

#### `lua/nvimx/genflake.lua` の `input_url`(`:33-76`。関数宣言が `:33`、本体が `:34-75`)の分岐 × 現行カバレッジ

`input_url` は 2 つの type × 優先順ラダーで 11 分岐ある(github 側 5 + git 側 6)。`genflake.lua` を実際に走らせている check は 4 つだけ
(`grep -n 'nvim -l .*genflake.lua' flake.nix` → 実行行は `:1709` `:1710` `:1921` `:2478` `:2798` の 5 行。
素の `grep -n genflake flake.nix` は 9 行返るが、`:179` `:2475` `:2750` `:2754` はコメント行である)で、
いずれも **golden ではなく `grep -q` / `grep -qF`** である。

| # | 分岐(`genflake.lua`) | 出力例 | 現行カバレッジ |
|---|---|---|---|
| G1 | github + `commit`(`:37-38`) | `github:o/r/<sha>` | **なし**。`update/raw-spec-commit.json` の `vim-fugitive` は `commit` を持つが、`checks.resolve-update` は genflake を走らせない |
| G2 | github + `resolvedRef`(`:39-40`) | `github:o/r/<sha>` | `resolve-merge`(`flake.nix:1722`)、`resolve-import-lazy-lock`(`:2479-2480`) |
| G3 | github + `tag`(`:41-42`) | `github:o/r/refs/tags/t` | `resolve-sources` の `ghtag.nvim`(golden) |
| G4 | github + `branch`(`:43-44`) | `github:o/r/<branch>` | **なし**。`merge` の `tokyonight.nvim` は `branch = "main"` を持つが `pin` 凍結で `resolvedRef` が勝ち、G2 に落ちる |
| G5 | github plain(`:46`) | `github:o/r` | ほぼ全 fixture |
| T1 | git + `commit` → `rev=`(`:52-53`) | `?rev=<sha>` | `resolve-sources` の `scpcommit.nvim`、`resolve-import-lazy-lock`(`:2487-2489`) |
| T2 | git + `resolvedRef` が 40hex → `rev=`(`:56-57`。`:55` は説明コメント) | `?ref=…&rev=<sha>` | `resolve-import-lazy-lock`(`:2481-2486`) |
| T3 | git + `resolvedRef` が symbolic → `ref=`(`:58-59`) | `?ref=refs/tags/…` | `resolve-semver`(`flake.nix:1922` の `grep -q 'ref=refs/tags/v1.2.5'`) |
| T4 | git + `tag` → `ref=refs/tags/t`(`:64`) | `?ref=refs/tags/t` | **なし**(単独では)。`import-lazy-lock` の `tag.nvim` は seed 済み rev と組み合わさった T2+T4 の形しか見ていない |
| T5 | git + `branch` → `ref=<branch>`(`:64`) | `?ref=<branch>` | **単独の形を見ているのは `resolve-sources` の `scpbranch.nvim` だけ**。`resolve-merge`(`:1723`)は `?ref=trunk&rev=bbbb…` = **T2+T5 の合成形**であり、T5 単独ではない |
| T6 | git plain(`rev` も `ref` も無く、`:72` の `if #params > 0 then` に入らない。`:72-75`) | クエリ無し | `resolve-sources` の golden(`ok.flake.nix:9` の `file.nvim`、`:13` の `ghe.nvim` ほか多数) |

**G1 / G4 / T4 が空白**であり、より重要なのは **優先順そのものを固定している check が 1 つも無い**ことである。
優先順は type ごとに形が違う: github 側は `commit` > `resolvedRef` > `tag` > `branch` の 1 本の 4 段ラダー(`:37-45`)、
git 側は **独立した 2 スロット**で、`rev` が `commit` > 40hex の `resolvedRef`(`:52-57`)、
`ref` が symbolic な `resolvedRef` > `tag` > `branch`(`:58-59` と `:64`)である。
現行はどの check も「1 プラグインにつき 1 フィールドしか置かない」ため、`commit` と `tag` を両方持つプラグインで
`tag` が勝つように書き換えても、**全 29 check がグリーンのまま通る**。git 側も同様で、実測すると
`tests/fixtures/**/*.json` 全体で `commit` と `resolvedRef` を同時に持つプラグインは **0 件**であり、
`:52-53` と `:54-60` を本体ごと入れ替えても既存 golden は 1 バイトも動かない。issue の "Done when" にある
「`input_url` の分岐を変えたら golden が落ちる」は、この状態では成立しない。

#### `lua/nvimx/resolve.lua`

| 領域 | カバレッジ |
|---|---|
| merge / spec 恒等性 / `pin` 凍結 | `checks.resolve-merge` + `merge/golden/base.plugins.json`(golden あり) |
| semver 解決(分類 A-D、fallback、pin+version) | `checks.resolve-semver`(golden 無し、`jq -e` と `grep`) |
| `defaults.version` の fallback | `checks.extractor-defaults-version`(`flake.nix:1366`)が extract の出力を `resolve.lua`(`flake.nix:1442`)まで通して駆動する。`resolve.lua` を走らせる 7 つ目の check がこれで、`resolve-*` という名前を持たないので見落としやすい |
| `--update` | `checks.resolve-update` + `update/golden/*`(golden あり) |
| `--import-lazy-lock` | `checks.resolve-import-lazy-lock` + `import-lazy-lock/golden/imported.plugins.json`(golden あり) |
| build 分類(`classify_build` / `classify_step` / `build_warning` / `has_rockspec`) | `checks.resolve-build-warnings` が **全 kind を網羅**(`none` / `shell` / `excmd` / `function` / `rockspec` / `luafile` / `steps`、および `false`)。`flake.nix:1477-1637` |
| ソース URL 分類 | `checks.source-parse`(unit)+ `checks.resolve-sources`(golden 2 本)(#28) |
| `sorted_deps` | `merge/golden/base.plugins.json:54-57` が `["nui.nvim","plenary.nvim"]`(spec の記述順は `["plenary.nvim","nui.nvim"]`)で固定済み |
| `localPlugins`(`dev` / `dir`) | `checks.resolve-import-lazy-lock` が既に golden で固定している。`import-lazy-lock/raw-spec.json:63-67` の `local.nvim`(`"dev": true` + 絶対パスの `dir`)を resolve に通し(`flake.nix:2438-2440`)、`flake.nix:2441` の `diff -u` が `import-lazy-lock/golden/imported.plugins.json:11-15` の `"localPlugins": { "local.nvim": { "dir": "/some/local/path" } }` を byte 単位で固定する。`local.nvim` は golden の `:12` にしか現れない(= `plugins` 側に無い)。なお `checks.dev-plugins` の方は**手書きの** `dev-plugins/nvimx-lock/plugins.json` を Nix 側から読むだけで、`resolve.lua` を駆動しない |

つまり `resolve.lua` 側で本当に空いているのは、**上記すべてが 1 本の `plugins.json` に同居したときの姿**である。
これは「1 ファイル丸ごと byte 一致」という形でしか固定できず、それがまさに golden の仕事である。

### 1.3 `tests/fixtures/basic-config` の消費者(拡張の可否を決める材料)

```console
$ grep -c 'tests/fixtures/basic-config' flake.nix
26
```

26 行の内訳(1 出力が複数行で参照することがある): `:97/99` `:217/218` `:226/227` `:234/235` `:259/260` `:269/270` `:279` `:302`
`:355/356` `:747` `:1188` `:1283` `:2699` `:2890/2895/2922/2923/2937/2947`。

参照している出力(重複除去):
`packages.demo`(`:93`)、`checks.hm-module`(`:216`)、`hm-module-degrade`(`:225`)、`hm-module-plugins`(`:233`)、
`hm-module-dev`(`:258`)、`hm-module-lua-packages`(`:268`)、`wrapper-aliases`(`:275`)、`extra-lua-packages`(`:294`)、
`plugins-overrides`(`:740`)、`treesitter-grammars`(`:1125`)、`extractor-snapshot`(`:1271`)、
`resolve-import-lazy-lock`(`:2420`)、`dev-plugins`(`:2865`)。

**12 check + `packages.demo`**。しかも `basic-config/nvimx-lock/flake.lock` は実在の tokyonight.nvim を pin しており、
`hm-module` 系はそれを実際に fetch してビルドする。

---

## 2. ゴール

issue の "Done when" を検証可能な形に落とす。

1. **`checks.resolve-golden` を新設**する。raw-spec → `resolve.lua` → `plugins.json` を、コミット済み golden と `diff -u` で byte 一致させる。
   fixture は plain github / `branch` / `tag` / `commit` / `version` / `dev` / shell `build` / excmd `build` / `dependencies` /
   非 GitHub git URL のマトリクス(§3.3)。
2. **`checks.genflake-golden` を新設**する(`docs/architecture.md:503` が名指ししている check の実体化)。
   `plugins.json` → `genflake.lua` → `flake.nix` を、コミット済み golden と `diff -u` で byte 一致させる。
   入力は 2 本で、**うち 1 本は `input_url` の優先順ラダーを網羅する手書き `plugins.json`**(§3.6)。
   これにより §1.2 の「優先順を書き換えても全 check がグリーン」が解消される。
3. **両 check は完全に hermetic かつ offline**。`resolve-golden` が使う `version` の remote は check 自身が作るローカル git repo であり
   (`mkTagRepoSh`、`flake.nix:182-193`)、`genflake-golden` は git もネットワークも `jq` すら要らない純テキスト変換である。
4. **生成 flake の全 input URL が nix の flake ref として妥当で、`github` / `git` 以外の type に降格していない**ことを
   **評価時に**(IFD 無しで)assert する。#28 の `checks.resolve-sources`(`flake.nix:2756-2787`)と同じ手法を踏襲する。
5. **`nix flake check` が Linux でグリーン、両 check が `aarch64-darwin` でも評価できる**。
6. **`genflake.lua` の `input_url` の分岐を 1 つ書き換えると `genflake-golden` が落ちる**ことを、実際の摂動と `diff -u` 出力で示す(§6.2)。
7. **`docs/architecture.md:503` の `genflake-golden` が "planned" から実在 check へ昇格**し、
   `:502` の check 一覧・`:493` の fixtures 一覧も追随する。

---

## 3. 設計

### 3.1 fixture は **新設**する — `tests/fixtures/spec-matrix/`

**採用: 新しい fixture ディレクトリ `tests/fixtures/spec-matrix/` を作り、`basic-config` には一切触らない。**

`basic-config` を拡張する案の却下理由:

1. **消費者が 12 check + `packages.demo`(§1.3)**。プラグインを 1 つ足すだけで
   `tests/fixtures/basic-config/nvimx-lock/{plugins.json,flake.nix,flake.lock}` を再生成する必要があり、
   `flake.lock` に新しいノードが増える = **`hm-module` / `hm-module-dev` / `hm-module-lua-packages` /
   `wrapper-aliases` / `plugins-overrides` / `treesitter-grammars` / `extra-lua-packages` が新たな実 fetch を要求する**。
   `basic-config` の lock は「1 プラグインだけを fetch する最小の lock」であることに価値がある。
2. **`basic-config/init.lua` は実在プラグインしか書けない**。マトリクスに要る
   `commit = "1111…"` / `tag = "v1.0.0"` / 非 GitHub URL / `dev = true` は、実在プラグインに対して書くと
   fetch が壊れるか、`hm-module` のビルドが落ちる。
3. **`extractor-snapshot`(`flake.nix:1271`)の golden が `basic-config` に固定されている**。
   拡張すると `tests/fixtures/golden/basic-config.raw-spec.json` も同時に書き換わり、
   「extract の出力」と「resolve の出力」という別々の関心事の golden が 1 つの fixture 変更で連動する。
4. **`dev` を `basic-config` に足すと `checks.dev-plugins` の前提が崩れる**。
   `flake.nix:2885-2886` のコメントが明言している:
   *"The default has to be a genuine no-op: basic-config's localPlugins is empty and …"*。

新 fixture は **`merge/` / `source-urls/` / `import-lazy-lock/` と同じく手書きの raw-spec** にする。
理由も同じで(`merge/raw-spec-base.json:3-4`、`source-urls/raw-spec-ok.json:2-5`)、
「lazy が spec をどう正規化するかとは独立に、テストが意図した形ちょうどを並べたい」から。
`commit = "1111…"` や `tag = "v1.0.0"` を実在しないプラグインに対して書けるのは手書き raw-spec だけである。

```
tests/fixtures/spec-matrix/
  raw-spec.json            # 手書き。spec フィールドのマトリクス(§3.3)
  priority.plugins.json    # 手書きの「入力」(golden ではない)。genflake の input_url 優先順ラダー(§3.6 / §3.9)
  golden/
    matrix.plugins.json    # resolve-golden の golden(生成物、手書き禁止)
    matrix.flake.nix       # genflake-golden の golden その 1(同上)
    priority.flake.nix     # genflake-golden の golden その 2(同上)
```

### 3.2 check は **2 つに割る** — 段を分けることが目的

issue は `resolve-golden` と `genflake-golden` の 2 つを要求している。`resolve-sources`(#28)は
raw-spec → resolve → genflake を **1 derivation** に入れたので、ここで揃えるべきか改めて検討した。

**採用: 2 derivation に分ける。** 理由:

1. **`docs/architecture.md:503` が `genflake-golden` という名前を約束している**。1 本にまとめると、
   その行を消すときに「約束した名前の check は結局作らなかった」ことになる。
2. **段が分かれていると落ちた場所が名前で分かる**。`resolve-golden` が赤 = `resolve.lua`、
   `genflake-golden` が赤 = `genflake.lua`。1 本だと `diff -u` の対象ファイル名を読むまで分からない。
3. **`genflake-golden` を resolve から独立させられる**のが決定的である。`genflake-golden` の入力は
   **コミット済みの `plugins.json`** であり、resolve の実行結果ではない。したがって
   **resolve が現状では出力できない `plugins.json` の形**(`commit` と `tag` を同時に持つ、
   `resolvedRef` が 40hex と symbolic の両方…= §1.2 の優先順ラダー)を入力にできる。
   1 本にまとめると入力が resolve の出力に縛られ、**ラダーを固定できない = issue の "Done when" が満たせない**。
4. **依存関係の重さが違う**。`resolve-golden` は `pkgs.git` + ローカル repo 作成 + `jq` が要る。
   `genflake-golden` は `pkgs.neovim-unwrapped` だけで走る純テキスト変換であり、それを混ぜる理由が無い。

**連鎖の健全性(「resolve の出力が genflake の入力である」)は失われない。**
`resolve-golden` は「resolve の出力 == `golden/matrix.plugins.json`」を証明し、
`genflake-golden` は「`golden/matrix.plugins.json` → `golden/matrix.flake.nix`」を証明する。
2 つを合わせれば「resolve の出力 → `golden/matrix.flake.nix`」が推移的に言える。
**同じ golden ファイルが両者の接点になっている**ことが、この推移を成立させている唯一の仕掛けなので、
両 check のコメントに相互参照を書く(§5.2)。

**却下: `resolve-sources` を拡張して 1 本にまとめる。** #28 の計画 §4.6 が
「マトリクスの軸(URL 形式 / spec フィールド)が違うので 1 つの golden に混ぜると fixture が読めなくなり、
落ちたときにどちらの回帰か分からなくなる」と明示的に線を引いている(`docs/plans/28-validate-plugin-sources.md:750-751`)。
これに従う。§4.1 に境界を再掲する。

### 3.3 `resolve-golden` のマトリクス — `tests/fixtures/spec-matrix/raw-spec.json`

issue が挙げる軸をすべて 1 プラグイン 1 軸で並べる。**すべて実測済み**(§8-1 の生成コマンドをスクラッチで実行して確認した)。

| plugin | raw-spec に書くフィールド | golden `plugins.json` の要点 | golden `flake.nix` の input URL | 何を固定するか |
|---|---|---|---|---|
| `plain.nvim` | `url = https://github.com/o/plain.nvim.git` | `source = {github, o, plain.nvim}`、他すべて null | `github:o/plain.nvim` | G5 |
| `branchy.nvim` | + `branch = "trunk"` | `branch = "trunk"` | `github:o/branchy.nvim/trunk` | **G4(現行未カバー)** |
| `tagged.nvim` | + `tag = "v1.0.0"` | `tag = "v1.0.0"` | `github:o/tagged.nvim/refs/tags/v1.0.0` | G3 |
| `committed.nvim` | + `commit = "1111…"`(40hex) | `commit = "1111…"` | `github:o/committed.nvim/1111…` | **G1(現行未カバー)** |
| `versioned.nvim` | `url = file:///nvimx-fixture/versioned.nvim`、`version = "^1.2"` | `version = "^1.2"`、`resolvedRef = "refs/tags/v1.2.5"` | `git+file:///nvimx-fixture/versioned.nvim?ref=refs/tags/v1.2.5` | semver 解決の結果が lock と flake に落ちること(T3)。§3.4 |
| `gittag.nvim` | `url = https://git.example.com/o/gittag.nvim.git`、`tag = "v2.0.0"` | `source = {git, url}` | `git+https://git.example.com/o/gittag.nvim.git?ref=refs/tags/v2.0.0` | **T4(現行未カバー)** + issue が要求する非 GitHub git URL |
| `shellbuild.nvim` | + `build = "make"` | `build = { kind = "shell", cmd = "make" }`、**警告なし** | `github:o/shellbuild.nvim` | shell build が静かなこと |
| `excmdbuild.nvim` | + `build = ":TSUpdate"` | `build = { kind = "excmd", cmd = ":TSUpdate" }` + `warnings` に 1 件 | `github:o/excmdbuild.nvim` | excmd build と、警告が lock に載ること。§3.8 |
| `deps.nvim` | + `dependencies = ["z.nvim","a.nvim"]` | `dependencies = ["a.nvim","z.nvim"]`(**ソート**) | `github:o/deps.nvim` | `sorted_deps` |
| `devel.nvim` | `dev = true`、`dir = "/nvimx-fixture/dev-root/devel.nvim"`(`url` なし) | `plugins` に**現れない**。`localPlugins["devel.nvim"] = { dir = … }` | **input が生成されない** | `localPlugins` の出力。**`checks.resolve-import-lazy-lock` の golden(`imported.plugins.json:11-15`)が同じ形を既に固定している**ので、ここは「マトリクスの 1 軸として同居させる」ことが目的であり、単独では新規カバレッジではない。issue が `dev` を軸に挙げているので残す。§3.5 |

生成された `golden/matrix.flake.nix`(実測、全文):

```nix
# This file is generated by nvimx. Do not edit by hand.
{
  inputs = {
    lazy-nvim = {
      url = "github:folke/lazy.nvim";
      flake = false;
    };
    branchy-nvim = {
      url = "github:o/branchy.nvim/trunk";
      flake = false;
    };
    committed-nvim = {
      url = "github:o/committed.nvim/1111111111111111111111111111111111111111";
      flake = false;
    };
    deps-nvim = {
      url = "github:o/deps.nvim";
      flake = false;
    };
    excmdbuild-nvim = {
      url = "github:o/excmdbuild.nvim";
      flake = false;
    };
    gittag-nvim = {
      url = "git+https://git.example.com/o/gittag.nvim.git?ref=refs/tags/v2.0.0";
      flake = false;
    };
    plain-nvim = {
      url = "github:o/plain.nvim";
      flake = false;
    };
    shellbuild-nvim = {
      url = "github:o/shellbuild.nvim";
      flake = false;
    };
    tagged-nvim = {
      url = "github:o/tagged.nvim/refs/tags/v1.0.0";
      flake = false;
    };
    versioned-nvim = {
      url = "git+file:///nvimx-fixture/versioned.nvim?ref=refs/tags/v1.2.5";
      flake = false;
    };
  };
  outputs = _: { };
}
```

`devel.nvim` の input が**無い**ことがこのファイルの主張の 1 つである(`grep -q` ではなく golden の不在で固定される)。

**意図的に入れないもの**:

- `pin = true` — `checks.resolve-merge` が `merge/golden/base.plugins.json` で完全にカバー済み(§4.3)。
  入れると `--lock` が必要になり、fixture に `flake.lock` を足すことになる。issue のマトリクスにも無い。
- `steps` 形式の `build` / `rockspec` / `luafile` / `false` — `checks.resolve-build-warnings` が
  `build-steps-config` で全網羅済み(`flake.nix:1554-1637`)。issue が挙げるのは「shell build」「excmd build」の 2 つだけ。
- `--prev` / `--import-lazy-lock` / `--update` — それぞれ専用 check がある。golden は「1 回の素の resolve」に限定する。

### 3.4 `version` をどう hermetic に扱うか

semver 解決は `resolve.lua:926` で `git ls-remote --tags --refs <url>` を実際に叩く。
既存の `checks.resolve-semver` / `checks.extractor-defaults-version` は、`flake.nix:182-193` の
`mkTagRepoSh` でローカル repo を作り、`file://$sb/<name>` を `jq` で raw-spec に注入することでオフライン化している。
**同じ手を使う。**

問題は **`$sb` がビルドディレクトリ依存**で、そのまま golden に焼くと Linux(`/build/...`)と
darwin(`/private/tmp/nix-build-....drv-0/...`)で値が違ってしまうことである。

**採用: raw-spec には固定のプレースホルダ URL を書き、check の中で (1) 実パスを注入 → (2) resolve → (3) プレースホルダへ戻す。**

```bash
# (1) 実パスを注入
jq --arg u "file://$sb/versioned" '.plugins["versioned.nvim"].url = $u' $fx/raw-spec.json > injected.json
# (2) 解決(ここだけ git ls-remote が走る。相手は $sb のローカル repo なのでネットワークは不要)
nvim -l $lua/resolve.lua injected.json out.json --lazy $lazy 2> resolve.log
# (3) サンドボックスのパスを、fixture が書いたのと同じプレースホルダへ戻す
sed "s#file://$sb/versioned#file:///nvimx-fixture/versioned.nvim#g" out.json > got.json
# サンドボックスのパスがどこにも残っていないこと(残っていたら golden が機械依存になる)
if grep -q "$TMPDIR" got.json; then
  echo "the sandbox path leaked into the golden-comparable output" >&2
  exit 1
fi
diff -u $fx/golden/matrix.plugins.json got.json
```

`sed` はこの 1 箇所しか書き換えないが、**`grep -q "$TMPDIR"` の方が本体**である:
将来 resolve が別のフィールドにも URL を書くようになったら、`sed` の穴を静かに通すのではなくここで落ちる。

`file:///nvimx-fixture/...` は「絶対に存在しないが形は正しい」という既存の慣習
(`tests/fixtures/semver/`、`update/`、`import-lazy-lock/` の `file:///nvimx-nonexistent/...`)に揃える。
`/nvimx-nonexistent` を再利用しないのは、**注入対象の 1 件を名前で見分けたいから**である。
「到達不能な固定 URL」という性質そのものは `/nvimx-nonexistent` と全く同じであり、しかも一時的でもない:
このプレースホルダは `golden/matrix.plugins.json` の `source.url` と `golden/matrix.flake.nix` の
`git+file:///nvimx-fixture/versioned.nvim?ref=refs/tags/v1.2.5` に**恒久的に焼かれる**。
違うのは「check が実パスへ差し替える対象かどうか」の 1 点だけなので、そこを名前で区別する。

`^1.2` に対するタグ集合は `mkrepo $sb/versioned v1.0.0 v1.2.0 v1.2.5 v2.0.0` とし、
勝つのは `v1.2.5`(実測確認済み)。`v2.0.0` を置くのは「範囲外の新しいタグが勝ってしまう」回帰を捕まえるためである。

**github type + `version` は扱わない。** `resolve.lua:812` は github type のとき `p.url`(= `https://github.com/...`)を
そのまま ls-remote に渡すので、ローカル repo に差し替える手段が無い。github type のゲート挙動
(`version` を持たない github プラグインが ls-remote に送られないこと)は
`checks.resolve-semver` の `gh.nvim` に対する 3 本の `jq -e`(`flake.nix:1913-1915`)が既にカバーしている
(その意図は `:1900-1901` のコメントが *"gh.nvim has no `version` at all (a github type plugin), proving the gate does not
send it to ls-remote regardless of type"* と明記している)。

### 3.5 `dev` / ローカルプラグインをマシン依存にせず扱う — #56 との共存

open issue **#56(`fix(lock): stop recording a machine-specific dir in localPlugins`)** が、
まさにこの `localPlugins[<name>].dir` を対象にしている。#56 の本文の表:

| spec | 記録される `dir` | マシン依存? |
|---|---|---|
| `dev = true` のみ | `<HOME>/projects/bare.nvim`(lazy が `dev.path` から導出) | **yes** |
| `dev = true` + `dir = "/abs/both"` | `/abs/both`、そのまま | **no** |
| `dev = true` + `dir = "~/mine/x"` | `<HOME>/mine/x`(`Util.norm` が展開) | **yes** |

**採用: 3 番目の行 = `dev = true` + **絶対パスの** `dir` を書く。**
`raw-spec.json` は手書きなので lazy の `dev.path` 導出も `Util.norm` も一切走らず、
`extract.lua` が dump するはずの値をそのまま書ける。よって golden に `$HOME` は入らない。

**#56 と衝突しないための追加の手当て**: golden の `localPlugins` の値そのものに寄りかからず、
**この check の主張を「値」ではなく「構造」に置く**。`resolve-golden` に次の 2 本の `jq -e` を明示的に置く:

```bash
# a dev plugin has no lock entry and no flake input at all -- that is the whole contract of
# localPlugins, and it is the half that survives #56 whichever option that issue picks.
jq -e '.plugins["devel.nvim"] == null' got.json > /dev/null
jq -e '.localPlugins | has("devel.nvim")' got.json > /dev/null
```

`golden/matrix.plugins.json` は当然 `"localPlugins": { "devel.nvim": { "dir": "/nvimx-fixture/dev-root/devel.nvim" } }` を持つが、
**#56 が option 1(`{ }` を書く)を採ったら、この golden の 1 行を再生成するだけで済む**(§3.9 の再生成コマンド)。
上の 2 本の `jq -e` はどちらの選択肢でもそのまま通る。この事実を fixture の `_comment` と §7 に書く。

**なお、この 2 本が主張する内容そのものは新規ではない**: `import-lazy-lock/golden/imported.plugins.json` が
`local.nvim`(同じく `dev = true` + 絶対パスの `dir`)について「`localPlugins` に居て `plugins` に居ない」を
既に byte 単位で固定している(§1.2)。ここで改めて `jq -e` を置くのは、**同じ主張を #56 に耐える形で書き直すため**であり、
新しい穴を埋めるためではない。裏を返せば **#56 は `matrix.plugins.json` と `imported.plugins.json` の 2 本の golden を
同時に更新する必要がある**(§4.5)。

### 3.6 `genflake-golden` の 2 本目の入力 — `priority.plugins.json`

§1.2 で示したとおり、**`input_url` の優先順ラダーを固定した check は現状 1 つも無い**。
これを固定するには「1 プラグインが `commit` と `resolvedRef` と `tag` と `branch` を同時に持つ」`plugins.json` が要るが、
`resolve.lua` はそういう出力を作らない(`commit` があれば semver ゲートが閉じ、`resolvedRef` は解決されない、など)。
したがって **手書きの `plugins.json` を入力にする**。これは `genflake-golden` を resolve から独立させた最大の見返りである(§3.2-3)。

`tests/fixtures/spec-matrix/priority.plugins.json`(手書き、11 プラグイン):

| plugin | source type | `commit` | `resolvedRef` | `tag` | `branch` | 期待 input URL | 勝つ分岐 |
|---|---|---|---|---|---|---|---|
| `gh-commit.nvim` | github | `1111…` | `2222…` | `v9.9.9` | `b` | `github:o/gh-commit.nvim/1111…` | G1 |
| `gh-resolved.nvim` | github | — | `2222…` | `v9.9.9` | `b` | `github:o/gh-resolved.nvim/2222…` | G2 |
| `gh-tag.nvim` | github | — | — | `v9.9.9` | `b` | `github:o/gh-tag.nvim/refs/tags/v9.9.9` | G3 |
| `gh-branch.nvim` | github | — | — | — | `b` | `github:o/gh-branch.nvim/b` | G4 |
| `gh-plain.nvim` | github | — | — | — | — | `github:o/gh-plain.nvim` | G5 |
| `git-commit.nvim` | git | `3333…` | **`5555…`(40hex)** | — | `b` | `…?ref=b&rev=3333…` | T1(`resolvedRef` に**勝つ**)+ T5 |
| `git-frozen.nvim` | git | — | `4444…`(40hex) | `v9.9.9` | — | `…?ref=refs/tags/v9.9.9&rev=4444…` | T2 + T4 |
| `git-symbolic.nvim` | git | — | `refs/tags/v1.2.3` | **`v9.9.9`** | `b` | `…?ref=refs/tags/v1.2.3` | T3(`tag` にも `branch` にも**勝つ**) |
| `git-tag.nvim` | git | — | — | `v9.9.9` | `b` | `…?ref=refs/tags/v9.9.9` | T4(`branch` に勝つ) |
| `git-branch.nvim` | git | — | — | — | `b` | `…?ref=b` | T5 |
| `git-plain.nvim` | git | — | — | — | — | クエリ無し | T6(git plain) |

**表の「期待 input URL」に現れないフィールドは、1 つ残らず「負けるために」置いた敗者フィールドである。**
太字にした 2 つ(`git-commit.nvim` の `resolvedRef` と `git-symbolic.nvim` の `tag`)は git 側の 2 スロットを
固定するために意識して足したものだが、**性質は github 側の敗者フィールドとまったく同じ**である。
`gh-commit.nvim` の `resolvedRef` / `tag` / `branch`、`gh-resolved.nvim` の `tag` / `branch`、`gh-tag.nvim` の `branch`、
`git-symbolic.nvim` と `git-tag.nvim` の `branch` — これらを**全部まとめて `null` にしても
`golden/priority.flake.nix` は byte 単位で同一のまま**である(実測)。
つまり「消しても `nix flake check` が緑のまま」は太字の 2 つに固有の性質ではなく、**敗者フィールド全体の性質**である。
これら全体で 1 本の全順序を強制しており、個々には他のプラグインと冗長なものもあるが、どれが冗長かはラダーを
触るたびに変わるので、勝者でないという理由で 1 つでも消してはならない。列挙して覚えるのではなく「**勝者として表に書かれていないフィールドは
すべて意図的に置いてある**」というルールで扱う(`_comment` と `flake.nix` のコメントもその形で書く。§5.1 / §5.2)。

git 側の分岐(`genflake.lua:52-61` と `:64`)は github 側のような 1 本の 4 段ラダーではなく、
**独立した 2 つのスロット**である:

- `rev` スロット = `commit`(`:52-53`)> 40hex の `resolvedRef`(`:56-57`)の 2 択。
- `ref` スロット = symbolic な `resolvedRef`(`:58-59`)> `tag` > `branch`(`:64` の `or` 連鎖)。

敗者フィールドを置かないと、この 2 スロットの優先順は**どちらも固定されない**。実測で確認した:
`tests/fixtures/**/*.json` 全体で `commit` と `resolvedRef` を同時に持つプラグインは **0 件**であり、
`git-commit.nvim` に `resolvedRef` を足さない限り `:52-53` と `:54-60` の分岐を本体ごと入れ替えても golden は 1 バイトも動かない。
足したうえで入れ替えると `rev=3333…` が `rev=5555…` になって落ちる(§6.2 の摂動 (c) で実測)。
`git-symbolic.nvim` の `tag` も同じで、足さなければ `:64` の `or` 連鎖で `tag` を `ref` より前に上げても落ちないが、
足せば `?ref=refs/tags/v1.2.3` が `?ref=refs/tags/v9.9.9` になって落ちる(摂動 (e))。
github 側も同型である: `gh-commit.nvim` の `resolvedRef` を消したうえで `:37-38` と `:39-40`
(`commit` > `resolvedRef` の段)を本体ごと入れ替えると **diff はゼロ**、残したまま入れ替えると
`github:o/gh-commit.nvim/1111…` が `/2222…` になって落ちる(実測)。
**どの敗者フィールドも期待 input URL を変えない**ので、`golden/priority.flake.nix` は敗者フィールドを足す前と
byte 単位で同一である(実測確認済み。下に全文を再掲する)。

`source.url` はすべて `https://git.example.com/o/<name>.git`。
エントリの形は `resolve.lua:693-704` の `entry` テーブルリテラルと同じキー集合にする(`inputName` / `source` /
`branch` / `tag` / `commit` / `version` / `pin` / `dependencies` / `resolvedRef` / `build`)。
代表として、敗者フィールドを持つ `git-commit.nvim`:

```json
    "git-commit.nvim": {
      "branch": "b",
      "build": { "kind": "none" },
      "commit": "3333333333333333333333333333333333333333",
      "dependencies": [],
      "inputName": "git-commit-nvim",
      "pin": null,
      "resolvedRef": "5555555555555555555555555555555555555555",
      "source": {
        "type": "git",
        "url": "https://git.example.com/o/git-commit.nvim.git"
      },
      "tag": null,
      "version": null
    },
```

**トップレベルの `lazyNvim` は必須である。** `genflake.lua:79` が
`inputs[#inputs + 1] = { name = db.lazyNvim.inputName, url = input_url({ source = db.lazyNvim.source }) }` を
**無条件に**実行するので、省くとその場で落ちる。しかも golden `priority.flake.nix` の最初の input は
`lazy-nvim = { url = "github:folke/lazy.nvim"; ... }` なので、値まで決まっている。
`resolve.lua:1297-1301` のリテラルをそのまま写す(既存 fixture では `source-urls/golden/ok.plugins.json:2-10` が同じ形):

```json
{
  "lazyNvim": {
    "inputName": "lazy-nvim",
    "source": {
      "owner": "folke",
      "repo": "lazy.nvim",
      "type": "github"
    },
    "synthetic": true
  },
  "plugins": { … }
}
```

`genflake.lua` は `localPlugins` も `warnings` も `schemaVersion` も読まないので、それらは書かない。

(このファイルは **golden ではなく入力**であり、`diff -u` の相手がいない。したがって手書きでよく、
再生成手順も持たない。既存 fixture に合わせてキー昇順・2 スペース字下げで書くが、それは可読性のためであって
byte 一致の要件ではない。位置付けの詳細は §3.9。)

生成された `golden/priority.flake.nix`(実測、全文):

```nix
# This file is generated by nvimx. Do not edit by hand.
{
  inputs = {
    lazy-nvim = {
      url = "github:folke/lazy.nvim";
      flake = false;
    };
    gh-branch-nvim = {
      url = "github:o/gh-branch.nvim/b";
      flake = false;
    };
    gh-commit-nvim = {
      url = "github:o/gh-commit.nvim/1111111111111111111111111111111111111111";
      flake = false;
    };
    gh-plain-nvim = {
      url = "github:o/gh-plain.nvim";
      flake = false;
    };
    gh-resolved-nvim = {
      url = "github:o/gh-resolved.nvim/2222222222222222222222222222222222222222";
      flake = false;
    };
    gh-tag-nvim = {
      url = "github:o/gh-tag.nvim/refs/tags/v9.9.9";
      flake = false;
    };
    git-branch-nvim = {
      url = "git+https://git.example.com/o/git-branch.nvim.git?ref=b";
      flake = false;
    };
    git-commit-nvim = {
      url = "git+https://git.example.com/o/git-commit.nvim.git?ref=b&rev=3333333333333333333333333333333333333333";
      flake = false;
    };
    git-frozen-nvim = {
      url = "git+https://git.example.com/o/git-frozen.nvim.git?ref=refs/tags/v9.9.9&rev=4444444444444444444444444444444444444444";
      flake = false;
    };
    git-plain-nvim = {
      url = "git+https://git.example.com/o/git-plain.nvim.git";
      flake = false;
    };
    git-symbolic-nvim = {
      url = "git+https://git.example.com/o/git-symbolic.nvim.git?ref=refs/tags/v1.2.3";
      flake = false;
    };
    git-tag-nvim = {
      url = "git+https://git.example.com/o/git-tag.nvim.git?ref=refs/tags/v9.9.9";
      flake = false;
    };
  };
  outputs = _: { };
}
```

この 12 input(lazy-nvim を含む)が **`docs/architecture.md:237-245` の「lazy spec → flake input URL mapping」表の実行可能な写し**である。
表と golden が対になっていることを、表の直後に 1 行書き足す(§5.3)。

**入力名のソート**も同時に固定される: `genflake.lua:80-81`(`local names = vim.tbl_keys(db.plugins or {})` と `table.sort(names)`)が効いていることは、
`gh-branch` < `gh-commit` < … < `git-tag` の並びが golden に焼かれることで担保される
(raw の Lua テーブルは `pairs()` 順なので、ソートを外せば golden が落ちる)。

### 3.7 評価時の `parseFlakeRef` assert(#28 の踏襲)

`checks.resolve-sources`(`flake.nix:2756-2787`)がやっているのと同じことを `genflake-golden` でも行う。
golden の `flake.nix` は**ソースファイル**なので `import` は素の `readFile` であり **IFD にはならない**。

```console
$ nix eval --impure --raw --expr "builtins.toJSON (builtins.mapAttrs (_: i: (builtins.parseFlakeRef i.url).type) (import ./tests/fixtures/spec-matrix/golden/matrix.flake.nix).inputs)"
{"branchy-nvim":"github","committed-nvim":"github","deps-nvim":"github","excmdbuild-nvim":"github","gittag-nvim":"git","lazy-nvim":"github","plain-nvim":"github","shellbuild-nvim":"github","tagged-nvim":"github","versioned-nvim":"git"}

$ nix eval --impure --raw --expr "builtins.toJSON (builtins.mapAttrs (_: i: (builtins.parseFlakeRef i.url).type) (import ./tests/fixtures/spec-matrix/golden/priority.flake.nix).inputs)"
{"gh-branch-nvim":"github","gh-commit-nvim":"github","gh-plain-nvim":"github","gh-resolved-nvim":"github","gh-tag-nvim":"github","git-branch-nvim":"git","git-commit-nvim":"git","git-frozen-nvim":"git","git-plain-nvim":"git","git-symbolic-nvim":"git","git-tag-nvim":"git","lazy-nvim":"github"}
```

全部 `github` / `git`。この判定を `genflake-golden` の derivation の env に渡して**インスタンス化時に強制**するので、
`nix eval .#checks.aarch64-darwin.genflake-golden.drvPath` だけで darwin 側の URL 妥当性まで確認できる(#28 と同じ)。

`resolve-golden` 側には parseFlakeRef の assert を**置かない**: `resolve-golden` の成果物は `plugins.json` で、
そこには flake ref が 1 つも無い。URL が flake ref になるのは genflake を通ったあとである。

### 3.8 excmd build の警告文言が golden に載ることについて

`excmdbuild.nvim` を入れると `golden/matrix.plugins.json` の `warnings` に

```
plugin "excmdbuild.nvim": build is a neovim command (":TSUpdate") and cannot be run at build time
```

が丸ごと入る。同じ文言は `checks.resolve-build-warnings`(`flake.nix:1519`)が
`grep -q '^\[nvimx\] warning: plugin "nvim-treesitter": build is a neovim command (":TSUpdate")'` で **stderr 側**に固定している。
#28 の計画は「同じ文言を 2 箇所で固定しない」を明確な方針にしている(`docs/plans/28-validate-plugin-sources.md:1145-1149`)ので、
ここを素通ししてはいけない。

**判断: golden に載せたまま許容する。** 理由:

1. #28 が避けたのは **19 件の拒否文言 × 2 層の手書き固定**である。ここは **1 件**で、
   しかも **片側(golden)は機械生成**なので、文言を変えたときの作業は「`grep -q` を手で直す」+「golden を再生成コマンドで作り直す」であり、
   手書きの二重管理にはならない。
2. `warnings` を golden から `jq` で削ると、**`json.lua` の配列エンコードと `resolve.lua` の
   `table.sort(plugin_warnings, …)` がまさに現れる場所に穴が空く**。plugins.json 全体を byte 単位で固定するのが golden の存在理由なので、
   ここを削るのは目的に反する。
3. **2 つの check の関心が違う**。`resolve-build-warnings` は「どの build 形が警告するか」の**分類マトリクス**を stderr で見ている。
   `resolve-golden` は「警告が **lock ファイルの中身として** どう記録されるか」を見ている。
   後者は `resolve-build-warnings` も `jq -e '.warnings[0] | startswith(…)'` という**前方一致**でしか見ておらず(`flake.nix:1536-1538`)、
   全文を `plugins.json` 側で固定している check は 1 つも無い。

`flake.nix` の `resolve-golden` のコメントに、`resolve-build-warnings` が同じ文言の stderr 側を持っていることを明記する
(本リポジトリのコメントは他 check を名指しする流儀。`CLAUDE.md` の Gotchas)。

**stderr の assert**: 警告が 1 件出るので `resolve-sources` のような「stderr が空」は使えない。件数で見る:

```bash
n=$(grep -c '^\[nvimx\] warning: ' resolve.log || true)
if [ "$n" -ne 1 ]; then
  echo "expected exactly 1 warning, got $n" >&2
  exit 1
fi
```

**`|| true` が本質的である。** nixpkgs の `setup.sh` は `set -e` を敷いており、`grep -c` は 0 件マッチで exit 1 を返す。
`n=$(...)` という**単独の代入文**はそれ自体が 1 つのコマンドとして `set -e` の対象になるので、警告が 0 件のときは
この行でビルドが死に、直後の `expected exactly 1 warning, got 0` は**一度も表示されない**。
つまり最も起こりやすい回帰(excmd の警告が静かに消える)がちょうど診断の出ないケースになり、
2 件以上のときにしかメッセージが読めないという逆立ちした挙動になる。実測でも
`nix build` した `runCommand "probe" {} "touch f; n=$(grep -c foo f); echo got $n; touch $out"` は
`builder failed with exit code 1` で終わり、`got 0` を印字しない。

既存の `flake.nix:2855` が `[ "$(grep -c 'unsupported source URL "[^"]' withurl.log)" -eq "$with_url" ]` と
`|| true` 無しで書けているのは、**そこで `set -e` が見る終了ステータスがコマンド置換のものではなく `[` のもの**だからである
(この行は POSIX の用語では複合コマンドではなく単純コマンドであり、コマンド置換はその引数を作っているだけである)。
罠なのは**単独の代入文**の方で、そこでは代入文の終了ステータスがコマンド置換の終了ステータスそのものになる。
診断メッセージを付けたくて代入に分けた瞬間に踏む。

escape hatch の `note()` 6 行(`resolve.lua:1287-1292`)は `warning:` を持たないので数に入らない。

### 3.9 golden の再生成手順と `nix fmt` 冪等性

**golden は手書きしない。必ず実物から生成する**(#28 の計画 §6.4 と同じ規律)。
`tests/fixtures/spec-matrix/raw-spec.json` の **`_comment` キー**(`merge/raw-spec-base.json:2-12` /
`source-urls/raw-spec-ok.json:2-15` と同じ慣習。`_comment` という**ファイル**は本リポジトリに存在しない)には、
手順そのものではなく **§3.9 への参照**を 1 行書く(実際の文面は §5.1)。手順の本体はこの計画にだけ置き、
二重管理にしない。

```bash
# 1. 一時的な semver remote を作る(check がやるのと同じこと)
sb=$(mktemp -d); git init -q -b main $sb/versioned
git -C $sb/versioned -c user.name=nvimx -c user.email=nvimx@example.com commit -q --allow-empty -m init
for t in v1.0.0 v1.2.0 v1.2.5 v2.0.0; do
  git -C $sb/versioned -c user.name=nvimx -c user.email=nvimx@example.com tag -a "$t" -m "$t"
done
seed=$(nix eval --impure --raw --expr '(builtins.getFlake (toString ./.)).inputs.lazy-nvim.outPath')

lua=lua/nvimx; fx=tests/fixtures/spec-matrix
# 2. resolve → プレースホルダへ戻す → golden
jq --arg u "file://$sb/versioned" '.plugins["versioned.nvim"].url = $u' $fx/raw-spec.json > /tmp/injected.json
nvim -l $lua/resolve.lua /tmp/injected.json /tmp/out.json --lazy "$seed"
sed "s#file://$sb/versioned#file:///nvimx-fixture/versioned.nvim#g" /tmp/out.json > $fx/golden/matrix.plugins.json
# 3. genflake × 2
nvim -l $lua/genflake.lua $fx/golden/matrix.plugins.json $fx/golden/matrix.flake.nix
nvim -l $lua/genflake.lua $fx/priority.plugins.json      $fx/golden/priority.flake.nix
rm -rf $sb
```

**`priority.plugins.json` はこの再生成手順の対象ではない。これは golden ではなく入力である。**
`checks.genflake-golden` が `diff -u` するのは `golden/{matrix.flake.nix,priority.flake.nix}` の 2 本、
`checks.resolve-golden` が `diff -u` するのは `golden/matrix.plugins.json` の 1 本で(§5.2)、
`priority.plugins.json` は `genflake.lua` が JSON として読むだけで**どの check とも突き合わされない**。
したがって上の「golden は手書きしない」という規律は**この 1 本には掛からない**。掛けようがない、とも言える:
§3.6 のとおり `resolve.lua` はこの形を出力できないので、実物から生成する経路が原理的に存在しない。
byte 一致を要求する相手がいない以上、`json.lua` に通して整形させる要件も置かない
(そのためだけの使い捨てスクリプトをコミットしても、それ自体を検証する check が無く二重管理になるだけである)。
手で書き、`resolve.lua:693-704` の `entry` と同じキー集合を持たせ(§3.6)、
読みやすさのために既存 fixture と同じキー昇順・2 スペース字下げに揃える — それで足りる。
この位置付け(golden ではなく入力)は fixture の `_comment` に明記する(§5.1)。

**`nix fmt` との関係**: `golden/*.flake.nix` は `*.nix` なので treefmt の nixfmt がそのまま拾う
(除外設定は無い。`flake.nix:124-141`)。**genflake の出力は nixfmt 冪等であることを実測で確認済み**:

```console
$ cp golden/matrix.flake.nix /tmp/m.nix && nixfmt /tmp/m.nix && diff -u golden/matrix.flake.nix /tmp/m.nix
$ cp golden/priority.flake.nix /tmp/p.nix && nixfmt /tmp/p.nix && diff -u golden/priority.flake.nix /tmp/p.nix
```

どちらも差分ゼロ。よって golden をそのままコミットしてよく、`nix fmt -- --ci` と `diff -u` が喧嘩しない。
(この不変条件が将来壊れる可能性は #28 の計画 §7 が既にリスクとして挙げており、本件も同じ扱いにする。§7)

`priority.plugins.json` は `*.json` なので、treefmt には対応するフォーマッタが無く整形されない。

---

## 4. 既存機能との関係

### 4.1 #28(`checks.resolve-sources` / `checks.source-parse`)との関係

**#28 は 2026-08-24 に PR #60 でマージ済み**(`git log --oneline`: `0eadbcc` Merge pull request #60、`03a718e` feat(lock): validate non-GitHub plugin sources)。
`docs/plans/28-validate-plugin-sources.md:733-751`(§4.6)が #29 との境界を明示的に引いており、**本計画はそれをそのまま守る**:

> `resolve-sources` の fixture は **URL 形式のマトリクスに限定する**。`version` は 1 つも置かない […]、
> `dev` / `dir` も置かない […]、build 分類も dependencies も置かない。
> したがって #29 が扱う build 分類 / dependencies / `dev` / `version` のマトリクスは
> `resolve-sources` では **1 つも代替されない**。

| 軸 | `resolve-sources`(#28) | `resolve-golden` / `genflake-golden`(#29) |
|---|---|---|
| **URL 形式**(github / http / 大文字ホスト / 末尾 `/` / scp / ssh / port / `git://` / `file://` / GHE / 入れ子 group / 1 セグメント) | **20 件のマトリクス。ここが本体** | **触らない**。git type の代表として `gittag.nvim` を 1 件だけ置く |
| **拒否側の URL** | 19 件(`raw-spec-bad.json`)+ `checks.source-parse` の unit | **1 件も置かない**(本件は成功パスの golden のみ) |
| `version` | 1 件も置かない(オフライン維持のため) | **`versioned.nvim` で扱う**(ローカル repo で hermetic に。§3.4) |
| `dev` / `dir` | 1 件も置かない | **`devel.nvim` で扱う**(§3.5) |
| `build` 分類 | 1 件も置かない(全部 `{ kind: "none" }`) | **shell / excmd を扱う** |
| `dependencies` | 1 件も置かない(全部 `[]`) | **`deps.nvim` で扱う(ソートの固定)** |
| `commit` / `branch` / `tag` on **github** type | `ghtag.nvim`(tag のみ) | **G1 / G4 を埋める**。優先順ラダーは `priority.plugins.json` で網羅 |
| `input_url` の優先順(`commit` > `resolvedRef` > `tag` > `branch`) | 1 プラグイン 1 フィールドなので固定していない | **`genflake-golden` の主目的**(§1.2 / §3.6) |

**重複するのは `gittag.nvim` の 1 件だけ**で、これは非 GitHub git URL を issue が明示的に要求しているためと、
`?ref=refs/tags/…` が単独で現れる形(T4)が `resolve-sources` に無いためである。
`resolve-sources` は `ghtag.nvim`(github + tag)を持つが git type + tag は持たない。

**手法も #28 から借りる**: golden 2 本立て(`plugins.json` + `flake.nix`)、
評価時の `builtins.parseFlakeRef` + type チェック(§3.7)、手書き raw-spec、`_comment` に意図を書く慣習。
`checks.resolve-sources` のコメント(`flake.nix:2753-2754`)は現に

> URL shapes only: build classification, dependencies, dev and version are the matrix #29's genflake-golden is for, not this check's.

と書いているので、**本件の新 check のコメントから逆向きに `resolve-sources` を名指しして対にする**(§5.2)。

### 4.2 `checks.resolve-build-warnings`

build 分類の**分類マトリクス**は完全にここが持っている(`flake.nix:1477-1637`、fixture は
`unbuildable-config` / `build-plugins` / `build-steps-config`)。**本件はそこに一切足さない**。
本件が持つのは「shell / excmd が `plugins.json` の中でどう見えるか」という golden の一部分だけである。
文言の二重固定に関する判断は §3.8。

### 4.3 `checks.resolve-merge` / `resolve-semver` / `resolve-update` / `resolve-import-lazy-lock`

(`file:line` はすべて **attribute 行**を指す。`flake.nix` は check ごとに説明コメントを前置するので、
`pkgs.runCommand "<name>"` の行や直前のコメント行と 1 行ずれやすい。§1.3 の `:2420`、§4.2 の `:1477` と同じ数え方に揃えてある。)

| check | 本件との関係 |
|---|---|
| `resolve-merge`(`flake.nix:1644`) | `--prev` / `--lock` / `pin` 凍結 / spec 恒等性 / 削除。**本件は `--prev` も `--lock` も使わない**ので重ならない。`merge/golden/base.plugins.json` が `dependencies` のソートを既に固定している点だけ重複するが、あちらは merge の文脈、こちらは素の resolve の文脈 |
| `resolve-semver`(`flake.nix:1875`) | semver の**分類 A-D・fallback・pin+version・再解決・`--prev` での持ち越し**。本件は成功パス 1 本だけを golden に載せる。`mkTagRepoSh` を共有する(3 つ目の利用者から 4 つ目になる) |
| `resolve-update`(`flake.nix:2105`) | `--update` 専用。無関係。ただし**これも `mkTagRepoSh` の利用者である**(`flake.nix:2116`)。既存の利用者は `extractor-defaults-version`(`:1376`)/ `resolve-semver`(`:1885`)/ この 3 つで、`resolve-golden` は 4 つ目になる |
| `resolve-import-lazy-lock`(`flake.nix:2420`) | seed 経路。`flake.nix:2479-2489` の 4 本の `grep -qF` が genflake の G2 / T1 / T2 / T2+T4 を押さえている。本件の `priority.plugins.json` はそれを golden 化して**残りの 6 分岐まで広げる**ものであり、あちらの grep は seed の文脈で意味があるので**消さない**。**加えて `localPlugins` の出力が重複する**: `flake.nix:2441` の `diff -u` が `imported.plugins.json:11-15` で `local.nvim`(`dev` + 絶対パス `dir`)の `localPlugins` エントリを既に byte 単位で固定しており、本件の `devel.nvim` はそれと同じ形である(§1.2 / §3.5)。本件で新しいのは「その 1 軸が他 9 軸と同じ `plugins.json` に同居した姿」の方 |

### 4.4 `checks.extractor-snapshot` と `tests/fixtures/golden/`

`extractor-snapshot`(`flake.nix:1271-1296`)は **extract 段**の golden で、
`tests/fixtures/golden/basic-config.raw-spec.json` を使う。本件は extract を 1 度も呼ばない
(raw-spec は手書き)ので、このディレクトリにも `basic-config` にも触らない。

なお golden の置き場所が `tests/fixtures/golden/`(extract 用)と `tests/fixtures/<name>/golden/`(それ以外)に
分かれているのは既存の慣習で、本件は後者に従う(`merge/golden/`、`update/golden/`、`import-lazy-lock/golden/`、`source-urls/golden/` と同じ)。

### 4.5 #56(`localPlugins` の機械依存 `dir`)との関係

§3.5 のとおり。**本件は #56 の修正方向を塞がない**:

- 本件は `resolve.lua:671` の `local_plugins[name] = { dir = p.dir }` に**触らない**。
- fixture は `dev = true` + **絶対パスの** `dir` なので、そもそも `$HOME` を含まない(#56 の表の「マシン依存? no」の行)。
- #56 が option 1(`{ }` を書く)を採ると `golden/matrix.plugins.json` の `localPlugins` が 1 行変わる。
  **golden の再生成コマンド 1 本で済む**(§3.9)。#56 の実装者がそれを見落とさないよう、
  fixture の `_comment` に「#56 が入ったら golden を再生成すること」と書く。
- **`import-lazy-lock/golden/imported.plugins.json` も全く同じ立場にある**(§1.2 / §4.3)。
  そちらの `:11-15` は `local.nvim` について `"dir": "/some/local/path"` を既に byte 単位で固定しており、
  #56 が `localPlugins` の中身を変えれば**そちらも同時に更新が要る**。
  つまり本件は #56 の作業量を **1 本から 2 本に増やすだけ**で、新しい種類の障害物は持ち込まない
  (そもそも #56 は既に 1 本の golden を更新せざるを得ない状態にある)。
- 本件が置く 2 本の `jq -e`(§3.5)は `dir` の値を読まないので、#56 のどの選択肢でも通る。

### 4.6 `docs/architecture.md`

| 行 | 作業 |
|---|---|
| 表の最終行 `:245` の直後(`:247` の段落の前) | URL マッピング表は `:237-245` で終わり、`:246` は空行、`:247` から `**Source URL validation** (#28):` の段落が始まる。**その空行と段落の間**に、表の実行可能な写しが `tests/fixtures/spec-matrix/golden/priority.flake.nix`(`checks.genflake-golden`)であることを 1 行書き足す(段落の中に入れない)。表と golden が対であることを明示しないと、表を直したときに golden を直し忘れる |
| `:493` | fixtures 一覧に `spec-matrix` を追加(`source-urls` の隣) |
| `:502` | checks 一覧に `resolve-golden` と `genflake-golden` を追加。`resolve-sources` の隣に並べる |
| `:503` | `- planned, not yet implemented: \`genflake-golden\` (#29), \`e2e-offline\` (#30)` から **`genflake-golden` (#29) を削除**し、`- planned, not yet implemented: \`e2e-offline\` (#30)` にする。**issue #29 の主目的の 1 つ**(§2-7) |
| `:531`(Phase 2 の "golden tests") | **触らない**。Phase 2 の説明であって、check の一覧ではない |
| `:514` の edge-case 表 | **触らない**。#28 の記述であり、本件は URL 分類を変えない |

`README.md` は**触らない**。README には fixture の一覧も check の一覧も無く、
本件はユーザから見える挙動を 1 バイトも変えない。

---

## 5. 実装手順

### 5.1 fixture(新規 `tests/fixtures/spec-matrix/`)

#### `raw-spec.json`(手書き)

`_comment` には (a) 手書きである理由(`merge/raw-spec-base.json:3-4` と同じ)、
(b) `versioned.nvim` の `url` が check によって実パスへ差し替えられるプレースホルダであること(§3.4)、
(c) `devel.nvim` の `dir` を絶対パスで書いてある理由と #56(§3.5)、
(d) URL 形式のマトリクスは `source-urls`(#28)の担当でここには置かないこと(§4.1)、
(e) golden の再生成コマンド(§3.9)、を書く。

```json
{
  "_comment": [
    "Hand-written raw-spec.json (the shape extract.lua dumps), used by checks.resolve-golden.",
    "Hand-written rather than extracted so this fixture holds exactly the spec-field matrix #29",
    "means to cover -- a `commit`, a `tag` and a non-GitHub URL can only name plugins that do not",
    "exist, which no extracted config could produce (the same reason",
    "tests/fixtures/merge/raw-spec-base.json gives).",
    "URL *shapes* are checks.resolve-sources' matrix (#28), not this one's: there is exactly one",
    "non-GitHub URL here (gittag.nvim), and it exists for genflake's git-type `?ref=refs/tags/`",
    "branch, which source-urls does not cover.",
    "versioned.nvim's url is a placeholder: checks.resolve-golden rewrites it to a local git repo",
    "it creates itself (git ls-remote has to reach something), then rewrites the resolved output",
    "back to this same string so the golden stays machine-independent.",
    "devel.nvim writes an absolute `dir` on purpose: lazy would otherwise derive one from dev.path",
    "and Util.norm would expand ~ against the extracting machine's $HOME. If #56 changes what",
    "resolve.lua records in localPlugins, regenerate golden/matrix.plugins.json -- the check's own",
    "two jq assertions about devel.nvim are written not to depend on the recorded value.",
    "Regenerating the goldens: see docs/plans/29-genflake-golden.md §3.9."
  ],
  "disabled": [],
  "notifs": [],
  "plugins": {
    "plain.nvim": {
      "name": "plain.nvim",
      "short": "o/plain.nvim",
      "url": "https://github.com/o/plain.nvim.git"
    },
    "branchy.nvim": {
      "name": "branchy.nvim",
      "url": "https://github.com/o/branchy.nvim.git",
      "branch": "trunk"
    },
    "tagged.nvim": {
      "name": "tagged.nvim",
      "url": "https://github.com/o/tagged.nvim.git",
      "tag": "v1.0.0"
    },
    "committed.nvim": {
      "name": "committed.nvim",
      "url": "https://github.com/o/committed.nvim.git",
      "commit": "1111111111111111111111111111111111111111"
    },
    "versioned.nvim": {
      "name": "versioned.nvim",
      "url": "file:///nvimx-fixture/versioned.nvim",
      "version": "^1.2"
    },
    "gittag.nvim": {
      "name": "gittag.nvim",
      "url": "https://git.example.com/o/gittag.nvim.git",
      "tag": "v2.0.0"
    },
    "shellbuild.nvim": {
      "name": "shellbuild.nvim",
      "url": "https://github.com/o/shellbuild.nvim.git",
      "build": "make"
    },
    "excmdbuild.nvim": {
      "name": "excmdbuild.nvim",
      "url": "https://github.com/o/excmdbuild.nvim.git",
      "build": ":TSUpdate"
    },
    "deps.nvim": {
      "name": "deps.nvim",
      "url": "https://github.com/o/deps.nvim.git",
      "dependencies": ["z.nvim", "a.nvim"]
    },
    "devel.nvim": {
      "name": "devel.nvim",
      "dev": true,
      "dir": "/nvimx-fixture/dev-root/devel.nvim"
    }
  }
}
```

#### `priority.plugins.json`(手書き)

§3.6 の表のとおり 11 プラグイン + **トップレベルの `lazyNvim`**。
`lazyNvim` は `genflake.lua:79` が `db.lazyNvim.inputName` と `db.lazyNvim.source` を無条件に読むため必須で、
値は `resolve.lua:1297-1301` のリテラルをそのまま写す:

```json
{
  "lazyNvim": {
    "inputName": "lazy-nvim",
    "source": {
      "owner": "folke",
      "repo": "lazy.nvim",
      "type": "github"
    },
    "synthetic": true
  },
  "plugins": { … }
}
```

(`source-urls/golden/ok.plugins.json:2-10` が同じ形。省くと `genflake.lua` が
`attempt to index a nil value` でその場で落ち、golden `priority.flake.nix` の先頭 input
`lazy-nvim = { url = "github:folke/lazy.nvim"; ... }` も作られない。
このファイルには再生成経路が無く手書きが唯一の正なので、ここだけは具体的に書いておく。)
`localPlugins` / `warnings` / `schemaVersion` は `genflake.lua` が読まないので書かない。

**`golden/` の外に置く**のは、これが golden ではなく**入力**だからである(§3.9)。
`_comment` に
「これは resolve.lua が現状では出力できない形(1 プラグインが `commit`/`resolvedRef`/`tag`/`branch` を同時に持つ)を
わざと作った `plugins.json` であり、`genflake.lua:33-76` の優先順ラダーを固定するためだけに存在する。
どの check とも `diff` されない**入力**なので手書きが正であり、再生成手順は無い(golden 3 本の再生成手順は §3.9)。
**§3.6 の表で「期待 input URL」の勝者になっていないフィールドは、1 つ残らず負けるために置いてある。**
`git-commit.nvim` の `resolvedRef` と `git-symbolic.nvim` の `tag` だけでなく、
`gh-commit.nvim` の `resolvedRef` / `tag` / `branch`、`gh-resolved.nvim` の `tag` / `branch`、
`gh-tag.nvim` の `branch`、`git-symbolic.nvim` と `git-tag.nvim` の `branch` も同じである。
敗者フィールドは**全体で 1 本の全順序を強制している**。個々には他のプラグインと冗長なものもあるが、
どれが冗長かはラダーを触るたびに変わるので、勝者でないという理由で 1 つでも消してはならない。
`plugins.json` のスキーマが増えたときはここも手で追随すること(genflake は一部のキーしか読まないので、
欠けていても静かに通ってしまう)」を書く。

#### `golden/{matrix.plugins.json, matrix.flake.nix, priority.flake.nix}`

§3.9 のコマンドで生成する。**手書き禁止**。

### 5.2 `flake.nix` — 2 つの check を追加

**挿入位置**: `checks.resolve-sources` は `flake.nix:2857` の `'';` で終わり、`:2858` から
`dev-plugins` の説明コメントが始まる。したがって **`:2858` の直前**に 2 つ続けて挿入する。
`resolve-*` 系がファイル後半に固まっている並びを保てるうえ、#28 の直後に #29 が来る時系列とも一致する。

```nix
          # The spec-field matrix, end to end but split in two: raw-spec -> resolve here, and
          # plugins.json -> genflake in checks.genflake-golden below. The two meet on one file --
          # tests/fixtures/spec-matrix/golden/matrix.plugins.json is this check's output and that
          # one's input -- so "resolve's output turns into that flake" still holds transitively,
          # while a red check names which stage broke (#29).
          # Fully offline: every url here is unreachable except versioned.nvim's, which is
          # rewritten to a local git repo this check creates itself (the same mkTagRepoSh
          # checks.resolve-semver uses) and rewritten back afterwards, so the golden never records
          # a build-directory path. URL *shapes* are checks.resolve-sources' matrix (#28), not
          # this one's -- there is exactly one non-GitHub url here.
          resolve-golden =
            pkgs.runCommand "resolve-golden"
              {
                nativeBuildInputs = [
                  pkgs.neovim-unwrapped
                  pkgs.jq
                  pkgs.git
                ];
              }
              (
                mkTagRepoSh
                + ''
                  export HOME=$TMPDIR
                  lua=${./lua/nvimx}
                  fx=${./tests/fixtures/spec-matrix}
                  lazy=${lazy-nvim}
                  sb=$TMPDIR/sandbox

                  # v2.0.0 is deliberately outside "^1.2": without it, a classifier that simply
                  # took the newest tag would pass.
                  mkrepo $sb/versioned v1.0.0 v1.2.0 v1.2.5 v2.0.0

                  jq --arg u "file://$sb/versioned" '.plugins["versioned.nvim"].url = $u' \
                    $fx/raw-spec.json > injected.json
                  nvim -l $lua/resolve.lua injected.json out.json --lazy $lazy 2> resolve.log
                  cat resolve.log >&2

                  # Put the sandbox path back to the placeholder the fixture wrote, so the golden
                  # is the same on x86_64-linux (/build/...) and aarch64-darwin (/private/tmp/...).
                  sed "s#file://$sb/versioned#file:///nvimx-fixture/versioned.nvim#g" out.json > got.json
                  # ...and prove nothing else leaked. The sed above only knows about the one field
                  # resolve writes a url into today; this catches the day that stops being true.
                  if grep -q "$TMPDIR" got.json; then
                    echo "the sandbox path leaked into the golden-comparable output" >&2
                    exit 1
                  fi
                  diff -u $fx/golden/matrix.plugins.json got.json

                  # Exactly one warning: excmdbuild.nvim. shellbuild.nvim is the quiet path, and
                  # without it a resolve that warned about every build would pass the golden too
                  # (the golden would just have been generated with both warnings in it).
                  # The same wording is pinned on the *stderr* side by
                  # checks.resolve-build-warnings, which owns the build-shape matrix; this check
                  # owns how a warning is recorded in the lock file itself.
                  # `|| true` is load-bearing: grep -c exits 1 on zero matches, and a bare
                  # assignment takes the substitution's own exit status, so setup.sh's `set -e`
                  # kills the build right here. checks.resolve-sources' `[ "$(grep -c 'unsupported
                  # source URL …')" -eq "$with_url" ]` needs no `|| true`, because there the status
                  # `set -e` sees is `[`'s, not the substitution's.
                  # Without it the message below never prints in the one case it is there for --
                  # the excmd warning going missing.
                  n=$(grep -c '^\[nvimx\] warning: ' resolve.log || true)
                  if [ "$n" -ne 1 ]; then
                    echo "expected exactly 1 warning, got $n" >&2
                    exit 1
                  fi
                  grep -q 'plugin "excmdbuild.nvim"' resolve.log

                  # A dev plugin has no lock entry and no flake input at all -- that is the whole
                  # contract of localPlugins, and it is the half that survives #56 whichever way
                  # that issue goes (the recorded `dir` may stop being recorded; these two do not
                  # read it). The golden pins the value; these two pin the structure.
                  jq -e '.plugins["devel.nvim"] == null' got.json > /dev/null
                  jq -e '.localPlugins | has("devel.nvim")' got.json > /dev/null
                  touch $out
                ''
              );
          # plugins.json -> flake.nix, on two inputs (#29). The first is checks.resolve-golden's
          # own golden output, which is what makes the two checks compose into the end-to-end
          # statement neither makes alone. The second is a hand-written plugins.json holding
          # shapes resolve.lua cannot currently emit -- one plugin carrying `commit`,
          # `resolvedRef`, `tag` and `branch` at once -- because that is the only way to pin
          # input_url's precedence: one ladder on the github side (commit > resolvedRef > tag >
          # branch), and two independent slots on the git side (rev: commit > 40-hex
          # resolvedRef; ref: symbolic resolvedRef > tag > branch). Before this check, swapping
          # two rungs left all 29 checks green -- no fixture in the tree carried `commit` and
          # `resolvedRef` on the same plugin, so nothing could tell the two apart.
          # Every field in that fixture that is not the winning one exists only to lose -- the
          # github side (gh-commit.nvim's resolvedRef/tag/branch, gh-resolved.nvim's tag/branch,
          # gh-tag.nvim's branch) just as much as the git side (git-commit.nvim's resolvedRef,
          # git-symbolic.nvim's tag, git-symbolic/git-tag's branch). None of them changes a
          # single byte of the golden, but together they enforce one total order across the
          # ladder. Individually some are redundant with another plugin's field, but which
          # fields are redundant shifts whenever the ladder changes, so never delete one
          # just because it is not the winner -- that is exactly the regression they catch.
          # No git, no jq, no network: this stage is a pure text transform.
          genflake-golden =
            let
              # Same evaluation-time guard checks.resolve-sources uses (#28): a golden is a source
              # file, so importing it is a plain readFile and never IFD, and the derivation below
              # is what proves the generated flake still equals it. parseFlakeRef succeeding is
              # too weak on its own -- it accepts `github:o/r/tree/main` and bare `just-a-name` --
              # so the *type* is asserted as well: anything that is not github/git has silently
              # degraded to an `indirect` or `path:` node that only dies later, in sources.nix.
              goldenFlakes = {
                matrix = import ./tests/fixtures/spec-matrix/golden/matrix.flake.nix;
                priority = import ./tests/fixtures/spec-matrix/golden/priority.flake.nix;
              };
              refTypes = builtins.mapAttrs (
                _: f: builtins.mapAttrs (_: i: (builtins.parseFlakeRef i.url).type) f.inputs
              ) goldenFlakes;
              badTypes = builtins.mapAttrs (
                _: ts: pkgs.lib.filterAttrs (_: t: t != "github" && t != "git") ts
              ) refTypes;
              checkedRefTypes =
                if builtins.all (v: v == { }) (builtins.attrValues badTypes) then
                  refTypes
                else
                  throw "generated flake inputs are not github/git refs: ${builtins.toJSON badTypes}";
            in
            pkgs.runCommand "genflake-golden"
              {
                nativeBuildInputs = [ pkgs.neovim-unwrapped ];
                # Forced while the derivation is instantiated, so
                # `nix eval .#checks.aarch64-darwin.genflake-golden.drvPath` is enough to catch a
                # degraded URL on a system this machine cannot build for.
                refTypes = builtins.toJSON checkedRefTypes;
              }
              ''
                export HOME=$TMPDIR
                lua=${./lua/nvimx}
                fx=${./tests/fixtures/spec-matrix}

                nvim -l $lua/genflake.lua $fx/golden/matrix.plugins.json matrix.nix
                diff -u $fx/golden/matrix.flake.nix matrix.nix

                nvim -l $lua/genflake.lua $fx/priority.plugins.json priority.nix
                diff -u $fx/golden/priority.flake.nix priority.nix
                touch $out
              '';
```

コメント密度は `CLAUDE.md` の Gotchas(*"Its comments record why, often naming other checks and issue numbers. Match that density when adding one."*)に従い、
`resolve-sources` / `resolve-build-warnings` / `resolve-semver` / #28 / #29 / #56 を名指ししている。

### 5.3 ドキュメント

§4.6 の表のとおり。作業は `docs/architecture.md` の 4 箇所
(URL マッピング表の最終行 `:245` の直後 — `:246` の空行と `:247` の段落の間 — に 1 行、`:493`、`:502`、`:503`)。

### 5.4 触らないもの

- `lua/nvimx/*.lua` — **1 バイトも変えない**。本件はテストの追加であり、挙動は変えない。
- `tests/fixtures/basic-config/` と `tests/fixtures/golden/` — §3.1 / §4.4。
- `flake.nix:182-193` の `mkTagRepoSh` — **既存のまま再利用**する(4 つ目の利用者になる)。
  ただし `flake.nix:176` のコメントは「shared by checks.resolve-semver and checks.extractor-defaults-version」と
  書いており、**現状すでに `checks.resolve-update`(`flake.nix:2116`)が漏れている**。
  `resolve-golden` だけを足すと誤ったままの行を再コミットすることになるので、
  **`resolve-update` と `resolve-golden` の両方**を書き足して 4 利用者すべてを列挙した形にする。
- `.github/workflows/*` — check の追加は `nix flake check` の中身が増えるだけ。`CLAUDE.md` のとおりステップ追加は不要。
- `stylua.toml` / `.luacheckrc` — 編集しないので `nix fmt -- --clear-cache` は不要。
- `README.md` / `templates/` / `nix/**` — 無関係。
- `.claude/skills/` — 触らないので `nix run .#skills-install` は不要。

---

## 6. テスト

### 6.1 何を、どの層で守るか

| 層 | 手段 | 守るもの |
|---|---|---|
| 統合(resolve) | `checks.resolve-golden` の `golden/matrix.plugins.json` | spec フィールド 10 軸が 1 本の `plugins.json` に落ちた姿の byte 一致。`sorted_deps`、build 分類、`warnings` 配列、`localPlugins`、semver 解決の結果 |
| 構造(resolve) | 同 check の `jq -e` 2 本 + 警告数 | `dev` プラグインが `plugins` に無いこと(#56 に耐える表現)、警告がちょうど 1 件であること |
| 機械非依存 | 同 check の `grep -q "$TMPDIR"` ガード | golden にビルドディレクトリのパスが混ざらないこと |
| 統合(genflake) | `checks.genflake-golden` の `golden/matrix.flake.nix` | resolve の出力から生成される最終成果物 |
| 単体(genflake) | 同 check の `golden/priority.flake.nix` | `input_url` の**11 分岐すべて**と、**その優先順の全段**: github 側の 4 段ラダー(`commit` > `resolvedRef` > `tag` > `branch`)、git 側の `rev` スロット(`commit` > 40hex `resolvedRef`)と `ref` スロット(symbolic `resolvedRef` > `tag` > `branch`)、`ref`→`rev` のクエリ順、および入力名のソート。**固定できないのは「`commit` が勝った状態で symbolic な `resolvedRef` が `ref` 側に漏れないこと」の 1 点だけ**(§6.2) |
| 評価時 | 両 golden の全 input に `builtins.parseFlakeRef` + type が `github`/`git` | `path:` / `indirect` への降格が起きていないこと(#28 と同じ手法) |
| 回帰 | 既存 29 check | 本件は lua を 1 バイトも変えないので、全部無変更で通るはず(§6.3) |

### 6.2 issue の "Done when" — 摂動が golden を落とすことの実証

> Changing an `input_url` branch in `genflake.lua` makes the golden check fail.

`genflake.lua:41-42` の github + `tag` 分岐を潰す:

```diff
     elseif not is_null(p.tag) then
-      return base .. "/refs/tags/" .. p.tag
+      return base .. "/" .. p.tag
```

`checks.genflake-golden` の 2 本目の `diff -u` が落ちる(実測):

```console
--- golden/priority.flake.nix
+++ priority.nix
@@ -22,7 +22,7 @@
       flake = false;
     };
     gh-tag-nvim = {
-      url = "github:o/gh-tag.nvim/refs/tags/v9.9.9";
+      url = "github:o/gh-tag.nvim/v9.9.9";
       flake = false;
     };
     git-branch-nvim = {
```

(1 本目 `golden/matrix.flake.nix` も `tagged-nvim` の行で同じように落ちる。)

**ただし摂動 (a) は既存 check でも捕まる。** `github:o/r/refs/tags/…` の形を固定しているのは
`checks.resolve-sources`(attr は `flake.nix:2755`)の golden で、
`source-urls/golden/ok.flake.nix:17` の `url = "github:o/ghtag.nvim/refs/tags/v1.0.0";` が
摂動 (a) で `github:o/ghtag.nvim/v1.0.0` に変わり、`flake.nix:2799` の `diff -u` が**今日でも赤くなる**(実測)。
つまり (a) は issue の "Done when" を満たす最短の実例ではあるが、**本件の追加価値そのものではない**
(`resolve-golden` / `genflake-golden` は同じ摂動を 2 本目の golden でも捕まえる、という重ね掛けにはなる)。

**追加価値は優先順の摂動 (b)-(e) の方にある。** そちらは現行のどの check も落とせない:
`tests/fixtures/**/*.json` 全体で `commit` と `resolvedRef` を同時に持つプラグインが **0 件**なので、
ラダーの段を入れ替えても既存 golden も既存 `grep` も 1 バイトも動かない。
たとえば (b)(github 分岐で `commit` と `tag` の段を本体ごと入れ替える)は、
`priority.plugins.json` を入れて初めて `gh-commit.nvim` と `gh-resolved.nvim` の **2 行**で落ちる。

**git 側は「同じ入れ替え」では落ちない。** `genflake.lua:52-61` は `commit` と `resolvedRef` の 2 択でしかなく、
`tag` / `branch` は `:64` の `ref` 側にしか効かないので、git 側で `commit` と `tag` の順を入れ替えても
そもそも入れ替える対象が同じ if 文の中に無い。git 側で意味のある摂動は別に用意する必要がある。

実装時に実際に確かめる摂動は 5 つ(§8-6)。**すべて実測済み**(`priority.plugins.json` を作って
`nvim -l genflake.lua` を摂動版と素の版で走らせ、`diff -u` を取った):

| # | 摂動 | 落ちる golden | 落ちる行 |
|---|---|---|---|
| (a) | `genflake.lua:42` の `"/refs/tags/"` を `"/"` に(github + `tag`) | `matrix.flake.nix`、`priority.flake.nix` | `tagged-nvim` / `gh-tag-nvim` |
| (b) | github 分岐(`:37-44`)で `p.commit` と `p.tag` の段を**本体ごと**入れ替える | `priority.flake.nix` のみ | **2 行**。`gh-commit-nvim` と `gh-resolved-nvim` |
| (c) | git 分岐の `:52-53` と `:54-60` を**本体ごと**入れ替える(`p.commit` と `p.resolvedRef` の判定順) | `priority.flake.nix` のみ | 1 行。`git-commit-nvim`(`rev=3333…` → `rev=5555…`) |
| (d) | `:66-71` の `params` の組み立て順を `ref`→`rev` から `rev`→`ref` に入れ替える | `priority.flake.nix`、`matrix.flake.nix` は無変化 | **2 行**。`git-commit-nvim` と `git-frozen-nvim` |
| (e) | `:64` の `or` 連鎖で `p.tag` を `ref`(= symbolic な `resolvedRef`)より前に上げる | `priority.flake.nix` のみ | 1 行。`git-symbolic-nvim` |

摂動 (b) は 1 hunk ではなく **2 hunk** になる。`tag` を先頭に上げると `commit` だけでなく `resolvedRef` にも勝つためで、
ラダーが **2 段ぶん**固定されていることがここで見える(実測、`diff -u golden/priority.flake.nix priority2.nix`):

```diff
@@ -10,7 +10,7 @@
       flake = false;
     };
     gh-commit-nvim = {
-      url = "github:o/gh-commit.nvim/1111111111111111111111111111111111111111";
+      url = "github:o/gh-commit.nvim/refs/tags/v9.9.9";
       flake = false;
     };
     gh-plain-nvim = {
@@ -18,7 +18,7 @@
       flake = false;
     };
     gh-resolved-nvim = {
-      url = "github:o/gh-resolved.nvim/2222222222222222222222222222222222222222";
+      url = "github:o/gh-resolved.nvim/refs/tags/v9.9.9";
       flake = false;
     };
     gh-tag-nvim = {
```

摂動 (c) は **`:52-53` の分岐と `:54-60` の分岐を本体ごと**入れ替える。
条件行 `:52` と `:54` だけを入れ替えると `rev = p.commit`(`:53`)が `resolvedRef` 側の分岐の本体として残ってしまい、
`git-frozen.nvim` で `rev` が `vim.NIL` のまま `genflake.lua:70` に届いて
`attempt to concatenate local 'rev' (a userdata value)` で**落ちる**(実測)。それでは `diff` が 1 行も出ないので、
摂動の実験としては意味が無い。本体ごと入れ替えて初めて下の 1 hunk になる。

摂動 (c) が落ちるのは **`git-commit.nvim` に敗者フィールド `resolvedRef = "5555…"` を置いたから**である(§3.6)。
置かなければこの入れ替えは golden を 1 バイトも動かさない — 実測で、`tests/fixtures/**/*.json` 全体を通して
`commit` と `resolvedRef` を同時に持つプラグインは **0 件**だからである。実測の `diff -u`:

```diff
@@ -30,7 +30,7 @@
       flake = false;
     };
     git-commit-nvim = {
-      url = "git+https://git.example.com/o/git-commit.nvim.git?ref=b&rev=3333333333333333333333333333333333333333";
+      url = "git+https://git.example.com/o/git-commit.nvim.git?ref=b&rev=5555555555555555555555555555555555555555";
       flake = false;
     };
     git-frozen-nvim = {
```

摂動 (d) は **`ref` と `rev` が併存する 2 プラグイン**を同時に落とす。1 つの hunk に 2 行入る(実測):

```diff
@@ -30,11 +30,11 @@
       flake = false;
     };
     git-commit-nvim = {
-      url = "git+https://git.example.com/o/git-commit.nvim.git?ref=b&rev=3333333333333333333333333333333333333333";
+      url = "git+https://git.example.com/o/git-commit.nvim.git?rev=3333333333333333333333333333333333333333&ref=b";
       flake = false;
     };
     git-frozen-nvim = {
-      url = "git+https://git.example.com/o/git-frozen.nvim.git?ref=refs/tags/v9.9.9&rev=4444444444444444444444444444444444444444";
+      url = "git+https://git.example.com/o/git-frozen.nvim.git?rev=4444444444444444444444444444444444444444&ref=refs/tags/v9.9.9";
       flake = false;
     };
     git-plain-nvim = {
```

摂動 (e) が落ちるのは **`git-symbolic.nvim` に敗者フィールド `tag = "v9.9.9"` を置いたから**である(§3.6)。実測:

```diff
@@ -42,7 +42,7 @@
       flake = false;
     };
     git-symbolic-nvim = {
-      url = "git+https://git.example.com/o/git-symbolic.nvim.git?ref=refs/tags/v1.2.3";
+      url = "git+https://git.example.com/o/git-symbolic.nvim.git?ref=refs/tags/v9.9.9";
       flake = false;
     };
     git-tag-nvim = {
```

**それでも残る未固定の 1 点**: 「`commit` が勝った状態で symbolic な `resolvedRef` が `ref` 側に漏れないこと」。
`git-commit.nvim` の敗者 `resolvedRef` は 40hex なので `:58-59`(symbolic → `ref`)を通らず、
`:58-59` を `if` の外に出すような書き換えは検出できない。12 本目のプラグイン(`commit` + symbolic `resolvedRef`)を
足せば埋まるが、隣接する書き換え(`:54` の `elseif` を独立した `if` にする)については
**(c) と同じ敗者フィールド — `git-commit.nvim` の `resolvedRef` — がそれも同時に捕まえる**。
実測すると `git-commit-nvim` の `rev=3333…` が `rev=5555…` になって落ち、
その敗者フィールドを消すと diff はゼロになる(検出しているのは摂動 (c) ではなく敗者フィールドの側である)。
したがって 12 本目の追加価値は薄く、本計画では**意図的に埋めない**。§7 に残す。

### 6.3 既存 check への影響

**期待差分ゼロ**。本件は `lua/` を 1 バイトも変えず、既存 fixture にも触らないため。
`flake.nix` への変更は新規 attribute 2 つの追加と、`mkTagRepoSh` の説明コメント(`flake.nix:176` 付近、利用者名を 4 つに揃える)だけである。
`mkTagRepoSh` の**中身**を変えないことが `checks.resolve-semver` / `checks.extractor-defaults-version` /
`checks.resolve-update`(既存 3 利用者すべて)への非干渉を保証する。

---

## 7. リスク / 未決事項

- **`golden/*.flake.nix` は `nix fmt` の対象である**。いまは genflake の出力が nixfmt 冪等なので問題無い(§3.9 で実測)が、
  将来 genflake の整形が nixfmt と食い違うと `nix fmt` が golden を書き換えて `diff` が落ちる。
  これは #28 の計画 §7 が既に受け入れているリスクであり、本件も同じ扱い(**乖離を可視化する機能**とみなす)。
  ユーザの lockDir 側は `nix/lib/lock-app.nix:236` が生成直後に `nixfmt` をかけるので、そちらが正となる。
- **`priority.plugins.json` は手書きなので、`plugins.json` のスキーマ変更に自動追随しない**。
  `genflake.lua` は `lazyNvim` / `plugins[].inputName` / `source` / `commit` / `resolvedRef` / `tag` / `branch` しか読まないので、
  新しいキーが増えても**静かに通ってしまう**。fixture の `_comment` に明記し、
  スキーマを触る issue(将来の `schemaVersion` bump など)では手で追随すること。
  自動化する案(resolve の出力から機械生成する)は、そもそも resolve が作れない形なので採れない。
  これが「golden は必ず実物から生成する」(§3.9)の唯一の例外を許した理由でもある: このファイルは golden ではなく
  **入力**で、どの check とも `diff` されない。
- **敗者フィールドは「消しても golden が落ちない」**(§3.6 / §6.2)。しかもこれは
  `git-commit.nvim` の `resolvedRef` と `git-symbolic.nvim` の `tag` に限った話ではなく、
  **`priority.plugins.json` で勝者になっていないフィールド全部**(github 側の `gh-commit.nvim` の
  `resolvedRef` / `tag` / `branch` などを含む)に当てはまる。これら全体で 1 本の全順序を強制しており、
  個々には他のプラグインと冗長なものもあるが、どれが冗長かはラダーを触るたびに変わるので、
  誰かが「使われていない」と判断してどれか 1 つを消してよいとは言えない。
  `_comment` と `flake.nix` のコメントの両方に、**個別の 2 つではなく「勝者以外はすべて意図的」というルールの形で**
  明記して防ぐ(§5.1 / §5.2)。2 つだけを名指しすると、名指しされなかった github 側が「未使用」に見えてしまう。
- **git 側で 1 段だけ固定できないままの分岐がある**(§6.2 末尾): 「`commit` が勝った状態で symbolic な
  `resolvedRef` が `ref` 側に漏れないこと」。`git-commit.nvim` の敗者 `resolvedRef` を 40hex にしたので、
  `genflake.lua:58-59` を通る経路と `commit` の勝ちが同時に起きるケースが fixture に無い。
  12 本目のプラグインで埋まるが、隣接する書き換え(`:54` の `elseif` → 独立した `if`)は
  (c) と同じ敗者フィールドが捕まえるため、本件では埋めない。
- **#56 が入ると `golden/matrix.plugins.json` の `localPlugins` が 1 行変わる**(§3.5 / §4.5)。
  再生成コマンド 1 本で済むうえ、check 側の 2 本の `jq -e` はどちらの選択肢でも通る。
  ただし **#56 の実装者がこの golden の存在に気付く必要がある**ので、fixture の `_comment` にその旨を書く。
  順序はどちらが先でもよい。
- **excmd build の警告文言が 2 箇所に現れる**(§3.8)。片方は機械生成の golden、もう片方は
  `checks.resolve-build-warnings` の手書き `grep -q`。1 件なので許容したが、**判断であってゼロコストではない**。
  文言を変えるときは `nix flake check` が両方を落とす(片方だけ直すと必ず赤になる)ので、静かな不整合にはならない。
- **`json.lua` の専用 unit test は作らない**。本件で golden が 3 本増えるので、キーソート / `[]` vs `{}` /
  文字列エスケープは実質さらに固定される。`tests/json-encode-test.lua` + `checks.json-encode` を足すのは
  issue #29 の "Done when" に無く、スコープを膨らませる。**follow-up 候補として別 issue に切る**のが筋。
  ただし `json.lua` の「エンコードできない型で `error()` する」経路(`:33`)だけは golden では踏めないので、
  その issue を切るなら根拠はそこになる。
- **github type + `version` はオフラインで検証できない**(§3.4)。`resolve.lua:812` が github type では
  `p.url` をそのまま ls-remote に渡すため、ローカル repo に差し替えられない。
  `source.lua` に「github type の ls-remote 用 URL を組み直す」責務を足せば可能になるが、それは #28 の
  follow-up 領域であり本件では扱わない。
- **`resolve-golden` は `pkgs.git` を要求する**。darwin のサンドボックスで `git init` / `git tag -a` が動くことは
  `checks.resolve-semver` / `checks.extractor-defaults-version` が既に CI で証明しているので、新しいリスクではない。
  ただし §8-4 の `nix eval .#checks.aarch64-darwin.resolve-golden.drvPath` は必ず通すこと。
- **`sed` による正規化が「正しい golden を作る」方向にも効いてしまう**。誤った URL が出ても `sed` が
  プレースホルダに置き換えれば golden と一致しうる。ただし置換対象は `file://$sb/versioned` 完全一致なので、
  resolve が別の URL を書けば置換されず `diff` で落ちる。`grep -q "$TMPDIR"` がその補強である。
- **新 check 2 本ぶん `nix flake check` が遅くなる**。`resolve-golden` は git repo 作成 + nvim 1 回、
  `genflake-golden` は nvim 2 回で、どちらも数秒。fetch はゼロ。

---

## 8. 検証手順(実装完了時に必ず全部通す)

```bash
# 0. 作業ツリーのルートで
cd /home/myuron/.cache/nvimx-worktrees/issue-29

# 1. CI と同一の 2 本(CLAUDE.md の Commands より)。これが通ることが必須条件
nix flake check
nix fmt -- --ci

# 2. 新規 check 単体(失敗時の切り分け用)
nix build .#checks.x86_64-linux.resolve-golden
nix build .#checks.x86_64-linux.genflake-golden

# 3. 影響を受けうる既存 check 単体(mkTagRepoSh の共有先と、golden を持つもの)
nix build .#checks.x86_64-linux.resolve-semver
nix build .#checks.x86_64-linux.extractor-defaults-version
nix build .#checks.x86_64-linux.resolve-update
nix build .#checks.x86_64-linux.resolve-sources
nix build .#checks.x86_64-linux.resolve-merge
nix build .#checks.x86_64-linux.resolve-build-warnings

# 4. darwin 評価(linux の nix flake check は darwin を omit するため必須。CLAUDE.md)。
#    genflake-golden は parseFlakeRef と type チェックを instantiation 時に強制するので、
#    ここで golden の URL 妥当性まで darwin 側でも確認される。
nix eval .#checks.aarch64-darwin.resolve-golden.drvPath
nix eval .#checks.aarch64-darwin.genflake-golden.drvPath
nix eval .#checks.aarch64-darwin.resolve-semver.drvPath

# 5. golden 3 本(matrix.plugins.json / matrix.flake.nix / priority.flake.nix)が本当に生成物であること。
#    §3.9 の手順でそのまま作り直して差分ゼロ(実行後 git status が clean であることまで確認する)。
#    raw-spec.json と priority.plugins.json は手書きの *入力* で、再生成の対象ではない(§3.9)。
#    ... §3.9 のコマンドをそのまま実行 ...
git status --porcelain -- tests/fixtures   # spec-matrix の新規追加分だけであること

# 6. issue の "Done when": input_url の分岐を摂動すると golden が落ちること(§6.2)。
#    5 通り試し、1 つごとに必ず元に戻す。(c) と (e) は敗者フィールドが効いていることの確認でもある
#    (a) genflake.lua:42 の "/refs/tags/" を "/" に(github + tag)
#    (b) github 分岐(:37-44)の p.commit と p.tag の段を *本体ごと* 入れ替え((c) と同じ理由)
#    (c) git 分岐の :52-53 と :54-60 を *本体ごと* 入れ替え(p.commit と p.resolvedRef の判定順)。
#        条件行 :52 / :54 だけを入れ替えると :70 で rev が vim.NIL のまま concat されて落ち、
#        diff が 1 行も出ない(§6.2)
#    (d) :66-71 の params の組み立て順を ref->rev から rev->ref に入れ替え
#    (e) :64 の or 連鎖で p.tag を ref(symbolic な resolvedRef)より前に上げる
nix build .#checks.x86_64-linux.genflake-golden   # 落ちることを確認
git checkout -- lua/nvimx/genflake.lua
nix build .#checks.x86_64-linux.genflake-golden   # 戻したら通ることを確認

# 6b. 敗者フィールドが本当に「消すと固定が消える」ことの確認(§3.6 / §7)。
#     priority.plugins.json から git-commit.nvim の resolvedRef を消すと (c) が検出できなくなり、
#     git-symbolic.nvim の tag を消すと (e) が検出できなくなる。
#     github 側も同型で、gh-commit.nvim の resolvedRef を消すと (b) の一部((:37-38)/(:39-40) の
#     本体ごとの入れ替え)が検出できなくなる。いずれも確認したら必ず戻す。
#     ついでに、そもそも fixture 全体で commit と resolvedRef が同居するのがこのファイルだけであること。
#     2>/dev/null は tests/fixtures/merge/prev-broken.json と
#     tests/fixtures/import-lazy-lock/lazy-lock-broken.json のためである。この 2 本は
#     「壊れた JSON を食わせたら resolve が落ちること」を確かめるために *わざと* 不正な JSON にしてあり、
#     jq が "parse error: Unfinished JSON term at EOF" を 2 回出す。これは失敗ではない。
for f in $(find tests -name '*.json'); do
  jq -r --arg f "$f" '[.. | objects
      | select(has("commit") and has("resolvedRef") and .commit != null and .resolvedRef != null)]
    | length as $n | if $n > 0 then "\($f): \($n)" else empty end' "$f" 2>/dev/null
done
# -> spec-matrix/priority.plugins.json: 2 の 1 行だけ(#29 以前は 0 行だった)。
#    2 なのは git-commit.nvim(commit 3333… + 敗者 resolvedRef 5555…)だけでなく
#    gh-commit.nvim(commit 1111… + 敗者 resolvedRef 2222…)も同居させているからで、
#    §3.6 の表の 1 行目と 6 行目に対応する(実測値。1 ではない)。

# 7. 生成 golden の全 input URL が flake ref として妥当で、github/git 以外へ降格していないこと
#    (check が評価時にやるのと同じ判定を手元でも)
for f in matrix priority; do
  nix eval --impure --raw --expr \
    "builtins.toJSON (builtins.mapAttrs (_: i: (builtins.parseFlakeRef i.url).type)
       (import $PWD/tests/fixtures/spec-matrix/golden/$f.flake.nix).inputs)"
  echo
done
# -> 値はすべて "github" か "git"

# 8. スモークテスト(CLAUDE.md の Commands。本件は lua を変えないので影響は無いはずだが、
#    fixture 追加が demo の評価を壊していないことの確認)
nix build .#demo && ./result/bin/nvim   # :Lazy が全プラグインを local 表示、git 操作ゼロ

# 9. ドキュメント(§4.6)。書いたことが実物と合っているか突き合わせる
grep -n 'spec-matrix' docs/architecture.md            # fixtures 一覧(:493)
grep -n 'resolve-golden\|genflake-golden' docs/architecture.md
                                                      # checks 一覧(:502)に 2 つ、
                                                      # planned 行(:503)から genflake-golden が消えていること
grep -n 'planned, not yet implemented' docs/architecture.md   # e2e-offline (#30) だけが残ること
grep -n 'priority.flake.nix' docs/architecture.md     # URL マッピング表の最終行 :245 の直後
                                                      # (:246 の空行と :247 の段落の間)に 1 行
```

**`nix fmt -- --clear-cache` は不要**。本件は `stylua.toml` も `.luacheckrc` も編集しない
(キャッシュ無効化が必要になるのはその 2 ファイルを触ったときだけ)。

**`nix run .#skills-install` は不要**(`.claude/skills/` に触らない)。

### 手動確認(check にできない部分)

- 特に無い。本件が触るのはテストと fixture と docs だけで、ユーザから見える挙動は 1 バイトも変わらない。
  実 remote を要する経路(実際の `nix flake lock`)は #28 の計画 §8 の手動確認と #30(`e2e-offline`)の領分である。
