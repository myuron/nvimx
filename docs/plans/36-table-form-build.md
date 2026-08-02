# #36 対応計画: table 形式の `build` が黙って捨てられる問題

対象 issue: [#36 fix(resolve): a table-form build is silently dropped](https://github.com/myuron/nvimx/issues/36)

作業順序上の位置: #43(`optional` 削除, main にマージ済み `18a28b3`) → #42(`defaults.version` の実体化, ブランチ `fix/extract-defaults-version` でレビュー中) → #31(treefmt に stylua / luacheck) → **#36(本件)** → #23 → #24 → #25。

**行番号の基準**: 本文の `file:line` はすべて**現 main (`18a28b3`) 基準**。ただし着手時点では #42 と #31 が入っているため、以下は既にずれる。**位置合わせはシンボルを主キーに行うこと**。

| ファイル | #42 / #31 による移動 |
|---|---|
| `lua/nvimx/extract.lua` | #42 が `effective_version` を足し `dump_plugin` を 2 引数化するため **+28 行**。`dump_plugin` は `:40` → `:68`、build 記録ブロックは `:41-44` → `:69-72` |
| `flake.nix` | #42 が `checks.extractor-defaults-version` を `resolve-build-warnings` の直前に足すため、`:898` 以降が **+66 行**(`resolve-build-warnings` `:898` → `:964`、`resolve-merge` `:981` → `:1047`)。`:207` / `:221` / `:260` の check は不動 |
| `docs/architecture.md` | #42 が **+8 行**。`:190` → `:194`、`:209` → `:213`、`:273`/`:277` → `:278`/`:282`、`:448` → `:453` |
| `lua/nvimx/resolve.lua`, `nix/lib/*`, `tests/fixtures/*` | #42 は無変更。#31 は stylua 整形で lua の行が動く可能性がある(現状の lua は 2 スペース / ダブルクォートなので実差分は小さい見込み) |

本計画の計測・実測はすべて main + #42 の作業ツリー(= 着手時の想定状態)、lazy.nvim seed rev `306a0552`(store path `/nix/store/d9jq3s81p4i9q6g8gaa6f2pn51p8za9l-source`)で行った。

---

## 1. 背景 / 現状

### 1.1 nvimx 側: 2 段構えで情報が失われている

**第 1 段 — `extract.lua` が構造を潰す。** `lua/nvimx/extract.lua:41-44`(#42 後 `:69-72`)、`dump_plugin` の先頭:

```lua
  local build = nil
  if p.build ~= nil then
    build = type(p.build) == "string" and p.build or ("<" .. type(p.build) .. ">")
  end
```

非文字列の `build` はすべて `"<" .. type .. ">"` というプレースホルダ 1 個に落ちる。table は `"<table>"`、`build = false` は `"<boolean>"`。**要素の内容はこの時点で完全に消える**。

**第 2 段 — `resolve.lua` が `none` に落とす。** `lua/nvimx/resolve.lua:266-275`:

```lua
    local build = { kind = "none" }
    if type(p.build) == "string" then
      if p.build:sub(1, 1) == "<" then
        build = { kind = "function" }
      elseif p.build:sub(1, 1) == ":" then
        build = { kind = "excmd", cmd = p.build }
      else
        build = { kind = "shell", cmd = p.build }
      end
    end
```

issue 本文は「table は全分岐をすり抜けて `{ kind = "none" }` になる」と書いているが、**現状はそうではない**。extract が先に `"<table>"` にしているので `type(p.build) == "string"` は真になり、先頭が `<` なので `{ kind = "function" }` に落ちる。つまり:

- `plugins.json` には `"build": { "kind": "function" }` が記録される(`none` ではない)。
- `resolve.lua:281-291` の警告経路は通る。`build_phrasing`(`:251-254`)に `["<table>"] = "a list of build steps"` があるため、**警告自体は既に出ている**(#22 で入った)。`checks.resolve-build-warnings`(`flake.nix:898`、`:940` 付近)がその文言を固定している。

**したがって「完全な silent drop」ではなく「警告は出るが情報が失われ、実行可能な step が 1 つも実行されない」が現状の正確な姿である。** 実測(`unbuildable-config` fixture 相当):

```
[nvimx] warning: plugin "LuaSnip": build is a list of build steps ("<table>") and cannot be run at build time
```

`{ "make install_jsregexp" }` は**全要素がシェルコマンド**で、サンドボックスで問題なく実行できるのに、helptags のみでインストールされる。`{ "make", ":TSUpdate" }` も `make` が実行されない。これが本件で直す実害である。issue の「silently dropped」は「実行可能な step が黙って捨てられる」と読むのが正しい。

### 1.2 隣接する誤分類(実測で判明)

同じ分類器に、table 以外にも取りこぼしがある。scratchpad で `{ build = false }` / `{ build = "rockspec" }` / `{ build = "build.lua" }` / 混在 table を実際に extract → resolve に通した結果:

| spec の `build` | raw-spec | plugins.json | 実際に起きること |
|---|---|---|---|
| `{ "make", ":TSUpdate" }` | `"<table>"` | `{ kind: "function" }` | 警告のみ。`make` は実行されない(本件の主題) |
| `{ }`(空 table) | `"<table>"` | `{ kind: "function" }` | 実行するものが無いのに警告が出る(偽陽性) |
| `false` | `"<boolean>"` | `{ kind: "function" }` | **偽陽性の警告**: `build is not a shell command ("<boolean>")`。lazy では `false` は「build を行うな」の明示(`task/plugin.lua:56-59`)で、警告する理由がない |
| `"rockspec"` | `"rockspec"` | `{ kind: "shell", cmd: "rockspec" }` | **サンドボックスで `rockspec` をシェル実行 → command not found でビルド失敗**。`build-network.nix` の検出リストにも無い |
| `"build.lua"` | `"build.lua"` | `{ kind: "shell", cmd: "build.lua" }` | 同様にシェル実行して失敗。lazy は nvim 内で `loadfile` する(`task/plugin.lua:73-79`) |

`rockspec` / `*.lua` は**本件の修正によって悪化する**: 分類器を table の要素にも適用すると、`{ "make", "rockspec" }` のような table が「shell step 2 本」と解釈され、これまで(table ごと捨てられて helptags のみ)なら少なくともインストールされていたプラグインが**ハードなビルド失敗**になる。§3.4 で扱う。

### 1.3 lazy.nvim 側の実装(pin された seed を実読)

`lua/lazy/manage/task/plugin.lua:51-85`(`M.build.run`)が唯一の実行経路:

```lua
    local builders = self.plugin.build
    if builders == false then                      -- :57  false は「build しない」
      return
    end
    builders = builders or get_build_file(self.plugin)   -- :61
    if builders then
      builders = type(builders) == "table" and builders or { builders }  -- :64 スカラーは 1 要素リストに正規化
      for _, build in ipairs(builders) do           -- :66 順に実行
        if type(build) == "function" then           -- :67 関数
          build(self.plugin)
        elseif build == "rockspec" then             -- :69 luarocks
          Rocks.build(self)
        elseif build:sub(1, 1) == ":" then          -- :71 ex コマンド
          B.cmd(self, build)
        elseif build:match("%.lua$") then           -- :73 プラグイン dir 相対の lua ファイルを loadfile
          ...
        else
          B.shell(self, build)                      -- :81 シェル
        end
      end
    end
```

読み取れる契約:

1. **型**: `lua/lazy/types.lua:34` — `build? false|string|async fun(self)|(string|async fun(self))[]`。要素は**文字列か関数のみ**。
2. **スカラーは 1 要素リストと等価**(`:64`)。つまり `build = "make"` と `build = { "make" }` は lazy にとって同一。**nvimx の内部表現もこれに合わせられる**(§3.1)。
3. **要素の特殊値は 4 種**: `rockspec`(`:69`)、`:ExCmd`(`:71`)、`*.lua`(`:73`)、それ以外はシェル(`:81`)。関数は型で判定。
4. **シェル step は step ごとに新しいシェル**: `B.shell`(`:32-40`)が `task:spawn(shell, { args = { "-c", build }, cwd = task.plugin.dir })`。**step 間で cwd も変数も引き継がれない**。§3.5 の設計根拠。
5. `build` 未指定でも `build.lua` / `build/init.lua` があれば実行する(`get_build_file`, `:9-15`)。nvimx はこれを模倣していない(既存の非対応であり本件の範囲外。§7)。
6. `false` は step ループの前に return(`:57`)。`{}`(空リスト)はループが 0 回回るだけ(`{}` は truthy なので `get_build_file` へのフォールバックも起きない)。

### 1.4 Nix 側の消費者

| 消費者 | `build` の読み方 | table 化の影響 |
|---|---|---|
| `nix/lib/make-env.nix:47` | `build = p.build or { kind = "none"; }` でそのまま透過 | なし(キー単位で読んでいない) |
| `nix/lib/resolve-plugin.nix:44-46, 61-69` | 既定値 `{ kind = "none"; }`、`args` に透過するだけ | なし |
| `nix/lib/plugin-drv.nix:28-32, 44-71` | `build.kind or "none"` / `build.cmd or ""`、`isShell` で stdenv・cmake・`dontBuild`・`buildPhase` を決める | **ここが実装の本体**(§3.5) |
| `nix/lib/build-network.nix:139-144` | `detect cmd`(純粋な文字列関数) | step ごとに呼ぶ必要がある(§3.5) |
| `nix/build-registry/*.nix` | 渡された `build` を**読まない**(自前で `{ kind, cmd }` を組んで `mkPluginDrv` を呼ぶ) | なし。ただし `default.nix:21` の「`build` は `{ kind, cmd }`」というコメントは更新が必要 |
| `lua/nvimx/genflake.lua:26-69` | `build` を読まない | なし。**生成 `flake.nix` は不変 → `flake.lock` も不変 → 再 fetch なし** |
| `lua/nvimx/resolve.lua`(prev として) | `schemaVersion` / `plugins` / `resolvedRef` / `pin` / `identity_fields` / `source_fields` のみ | なし。`build` は spec 恒等性に**含まれない**(`resolve.lua:179-181`) |

### 1.5 既存の実装バグ(実測): `cd` が installPhase に漏れる

`plugin-drv.nix:67-71` は `buildPhase` に `${cmd}` を素で埋め込む。phase は同一シェルで走るので、build の `cd` が `installPhase` の `cp -r . $out` に漏れる。実測:

```
nix build --expr 'mkPluginDrv { name = "cwd-leak"; src = ./tests/fixtures/local-plugin;
                                build = { kind = "shell"; cmd = "cd lua && touch marker"; }; }'
→ $out の中身は local-plugin.lua と marker だけ(lua/ の中身)。doc/ も Makefile も消え、helptags も生成されない。
```

`checks.build-network-detect`(`flake.nix:260`、`:273` 付近)には `cd deps && make` という**まさにこの形の case が期待値 `null`(= 許可)として存在する**。つまり現実に起こりうる形が壊れている。本件は step ごとの分離を入れる以上、この修正を同時に行うのが自然である(§3.5)。

---

## 2. ゴール

issue 本文に "Done when" は無いので、"What to do" の 4 項目を検証可能な形に落とす。

1. **table の展開**: spec の `build = { "make", ":TSUpdate" }` が `plugins.json` に**要素ごとの分類付きで**記録される。要素が 1 つも失われない(要素数が一致する)。
2. **順序どおりの実行**: table のシェル step が**宣言順に**、それぞれ**プラグインルートを cwd として**実行される。`excmd` / `function` 要素はスカラー build と同様にスキップされる。混在 table では「実行できる step は実行され、できない step だけスキップされる」。
3. **lock 時警告**: 実行できない要素について、**どの step か(index)・どういう形か・残りの step は実行されるのか**が lock 時の警告で分かる。#22 の流儀どおり **warning に留まり lock は成功する**(exit 0)。`nvim-treesitter` には table 形式でも `treesitter.grammars` への誘導が出る。
4. **静かな経路**: 全要素がシェルの table(`{ "make install_jsregexp" }`)は**警告を 1 件も出さず**、実際にビルドされる(現状は警告のみで未ビルド)。
5. **`schemaVersion` は 1 のまま**、かつ:
   - 旧形式(`build` が `{ kind: "function" }` の既存 lock)を `--prev` に渡して pin が 1 つも失われない。
   - 新形式を**旧 nvimx** が読んでも評価が壊れない(helptags のみに degrade する = 本件前と同じ挙動)。
   - `build` は spec 恒等性に入らないままなので(`resolve.lua:181`)、`resolvedRef` は 1 件も再解決されない。生成 `flake.nix` / `flake.lock` は不変(再 fetch を強制しない)。
6. **冪等性**: 変更後の resolve が自分の出力を `--prev` にして byte-identical(`checks.resolve-merge` の既存契約)。
7. **既存 check の通過**: `nix flake check`(linux)グリーン、`nix fmt -- --ci` 通過、`nix eval .#checks.aarch64-darwin.<name>.drvPath` が通る(§6.4)。
8. **回帰ガード**: 「table を `{ kind = "function" }` に戻す」「step の cwd が次の step / installPhase に漏れる」の双方で落ちる assert が checks に存在する。

---

## 3. 設計

### 3.1 スキーマの最終形

**採用: 追加的 (additive) な `{ kind = "steps", steps = [ { kind, cmd } ] }`。スカラー build の表現は現状のまま変えない。**

```jsonc
// スカラー: 完全に現状維持
"build": { "kind": "none" }
"build": { "kind": "shell", "cmd": "make" }
"build": { "kind": "excmd", "cmd": ":TSUpdate" }
"build": { "kind": "function" }                  // cmd は載せない(現状の意図的な仕様)
// table: 新形式。要素は上のスカラーと同じ { kind, cmd } の形
"build": {
  "kind": "steps",
  "steps": [
    { "kind": "shell", "cmd": "make" },
    { "kind": "excmd", "cmd": ":TSUpdate" }
  ]
}
```

`kind` の値域(トップレベル): `none` | `shell` | `excmd` | `function` | `rockspec` | `luafile` | `steps`。
`steps[]` の要素の `kind`: `shell` | `excmd` | `function` | `rockspec` | `luafile`(`none` と `steps` は入らない = **ネストしない**)。

**却下案と理由**

| 案 | 却下理由 |
|---|---|
| 全 build を `{ kind, steps }` に統一(スカラーも 1 要素リストにする) | 表現としては最も綺麗(lazy 自身が `:64` でそう正規化している)が、**既存の全 `plugins.json` エントリが書き換わる**。committed lock に無意味な差分が出る、`tests/fixtures/*/nvimx-lock/plugins.json` と golden の全面更新が必要、そして**旧 nvimx が新 lock を読むと `kind == "shell"` が消えて既存のシェルビルドが走らなくなる**(ロールバック時の実害)。additive でなくなるので `schemaVersion` bump の議論を呼び込む(§3.3)。得られるものは表現の統一だけで、実行側の統一は §3.5 の内部正規化で無料で得られる |
| `build.cmd` をリスト化(`{ kind = "shell", cmd = [ "make", ... ] }`) | `cmd` の型が `string \| array` の可変になり、全読み手(`plugin-drv.nix`、registry のコメント、docs)に型分岐が増える。さらに **`{ "make", ":TSUpdate" }` のような混在 table を表現できない**(トップレベル `kind` を 1 つ選べない)。issue が挙げた 2 案のうちこちらは表現力が足りない |
| `kind = "shell"` のまま `steps` を併記 | 「`kind == "shell"` なら `cmd` を実行」という既存の読み手の前提を破る(旧 nvimx が `cmd` = 空文字で 1 回ビルドする)。事故の温床 |

**空 table の扱い**: `build = {}` は `{ kind = "none" }` に畳む(`{ kind = "steps", steps = [] }` にはしない)。実行するものが無い状態を 2 通りで表現する意味がなく、`steps = []` は `plugin-drv.nix` の `anyShell` 判定・警告判定の双方で `none` と完全に同義になるため。

**1 要素 table の扱い**: 畳まない。`{ "make" }` は `{ kind = "steps", steps = [ { kind = "shell", cmd = "make" } ] }` とする。スカラーへ畳むと「spec に書いた形と lock の形が要素数で変わる」規則を 1 つ増やすことになり、本件が消そうとしている「形が失われる」性質を別の形で持ち込む。畳まないことによる損失は無い(§3.5 が内部で正規化するので実行側は同一コード)。

### 3.2 どこで table を展開するか

**採用: `extract.lua` が構造を保った dump を出し、`resolve.lua` が分類する。**

`extract.lua` の `build` 出力型を `string | string[] | false | null` に拡張する:

```lua
  -- 要素は文字列か関数のみ(lazy/types.lua:34)。文字列以外は "<type>" プレースホルダに落とす
  local function dump_build_step(v)
    return type(v) == "string" and v or ("<" .. type(v) .. ">")
  end
  local build = nil
  if p.build == false then
    build = false                       -- lazy の「build しない」(task/plugin.lua:57)。§3.4
  elseif type(p.build) == "table" then
    local steps = {}
    for _, s in ipairs(p.build) do
      steps[#steps + 1] = dump_build_step(s)
    end
    build = steps
  elseif p.build ~= nil then
    build = dump_build_step(p.build)
  end
```

**却下案**

- **extract は `"<table>"` のまま、resolve で展開**: 不可能。resolve が読むのは JSON で、要素は既に失われている。
- **extract が分類まで済ませて `{ kind, steps }` を raw-spec に書く**: 却下。raw-spec は「lazy が正規化した値の忠実な dump」、`plugins.json` は「nvimx の分類と方針」という現在の役割分担(`extract.lua` に `build_phrasing` 相当が無い、`resolve.lua` が `kind` を決める)を崩す。`rockspec` / `*.lua` の判定は nvimx のビルド方針(何がサンドボックスで実行できるか)に属し、抽出器の責務ではない。

raw-spec の型が可変になる点は、消費者が `resolve.lua` だけ(raw-spec は `lock-app.nix:48` の `mktemp -d` に書かれ `:53-59` の trap で消える)なので実害がない。リポジトリに残る唯一の raw-spec は `tests/fixtures/golden/basic-config.raw-spec.json` で、`basic-config` は `build` を持たないため **golden は無変更**(§6.3 で確認)。

### 3.3 `schemaVersion` は 1 のまま(#43 の結論との整合)

`docs/plans/43-drop-optional-field.md` §3.2 は「bump は `resolve.lua:119-127` のハードエラー経路で既存 lock を読めなくし、案内どおり削除すれば pin が全損する」と結論づけている。この緊張は**スキーマを additive にすることで解消する**(bump しない)。issue 本文の「shape が変わるなら bump」は満たさないが、以下の分析により **shape は変わらない**(値域が増えるだけ)と判断する。

**方向 A: 新 nvimx が旧 `plugins.json` を読む。**
`resolve.lua` は prev の `build` を読まない(1.4)。`plugin-drv.nix` は旧 lock の `shell` / `excmd` / `function` / `none` をこれまでどおり処理する。table build を `{ kind: "function" }` と記録した旧 lock は、**再 lock するまで従来どおり helptags のみ**(= 本件前と同じ)。壊れない。

**方向 B: 旧 nvimx が新 `plugins.json` を読む(ロールバック)。**
`plugin-drv.nix:28` の `isShell` は `kind == "shell"` の等値比較なので、`steps` / `rockspec` / `luafile` はすべて「shell ではない」= helptags のみに degrade する。**throw もエラーも起きない**。しかも `rockspec` については、旧 nvimx が自分で resolve した場合(`kind = "shell", cmd = "rockspec"` → サンドボックスで実行して失敗、1.2)より**新 lock を読んだ方が壊れない**。

**方向 C: 既存エントリの byte 差分。** スカラー build のエントリは 1 バイトも変わらない。差分が出るのは (a) table / `false` / `rockspec` / `*.lua` の build を持つプラグインの `build` フィールド、(b) `warnings` 配列(毎回導出、lock state ではない)のみ。`genflake.lua` は `build` を読まないので生成 `flake.nix` は不変 → `flake.lock` も不変 → **再 fetch は起きない**。該当プラグインの derivation は変わる(= 再ビルドされる)が、それが本件の目的である。

**結論**: `schemaVersion` は 1 のまま。理由は「追加だから安全」ではなく、**上の 3 方向すべてで「pin の喪失」も「評価の失敗」も起きないことを個別に確認したから**である。#43 が残した債務(将来 non-additive な変更が必要になったら `resolve.lua` に v1 受理の互換読みを書く)は本件では返済しない — 本件で返済する必要が無いことが上の分析の帰結である。

**#18 の spec 恒等性との関係**: `identity_fields = { "branch", "tag", "commit", "version" }`(`resolve.lua:181`)に `build` は含まれない。本件でも**追加しない**。`build` の形が変わっても ref の決定には一切影響しないため、pin も `resolvedRef` も動かない(ゴール 5)。`resolve.lua:179-180` のコメント(「pin / dependencies / build は恒等性に含めない」)はそのまま有効。

### 3.4 新しい kind: `rockspec` / `luafile`、および `build = false`

**採用: `rockspec` と `luafile` を kind として明示し、`build = false` は `{ kind = "none" }`(警告なし)にする。**

これは機能追加ではなく**本件による悪化の回避**である(1.2)。分類器を table の要素にも適用する以上、`{ "make", "rockspec" }` のような table は「shell step 2 本」と解釈され、`rockspec` がサンドボックスでシェル実行されて**ビルドが失敗する**。現状は table ごと捨てられていたので少なくともプラグインはインストールされていた。つまり「table を実行できるようにする」変更は、この 2 つを同時に分類しないと**既存ユーザを退行させる**。

- `rockspec`: `kind = "rockspec"`。`cmd` は載せない(実行すべきコマンドではない)。lock 時警告あり。`docs/architecture.md:448-455` が「luarocks は明示的に非対応(`rocks.enabled = false` を強制)」と宣言しているので、方針として一貫する。**警告文で `extraLuaPackages` に言及しないこと**: そのオプションは `nix/home-manager/default.nix` に**まだ存在しない**(`extraPackages` のみ)。3 つの hatch 案内(`resolve.lua:371-378`)に任せる。
- `luafile`: `kind = "luafile"`、`cmd` に元の相対パスを保持。lazy は nvim 内でプラグインをロードした状態で `loadfile` する(`task/plugin.lua:73-79`)ので、サンドボックスで忠実に再現する手段がない。実行不可として警告する。
- `build = false`: `{ kind = "none" }`、**警告なし**。現状は `"<boolean>"` 経由で偽陽性の警告が出る(1.2 で実測)。`false` はユーザが「build するな」と明示した状態で、警告する対象ではない。

**却下案「本件では table だけ扱い、`rockspec` / `*.lua` / `false` は別 issue にする」**: `rockspec` は上記のとおり退行を生むので分離できない。`*.lua` は同じ 1 関数(`classify_step`)の 1 分岐で、lazy の判定順(`:69` → `:71` → `:73` → `:81`)を写すだけなので、分離するコストの方が高い。`false` は extract 側 2 行。3 つ合わせて 10 行程度で、いずれも「lazy の実行規則を写す」という同じ設計原理に属する。

**プレースホルダ由来の要素**: `"<function>"` 等は `kind = "function"` に落とす(先頭 `<` 判定、現状維持)。lazy の型上、要素として現実に来るのは関数だけである(`types.lua:34`)。

### 3.5 `plugin-drv.nix` での実行

**内部では 1 つの形に正規化する。** スキーマは 2 形(§3.1)だが、実行器は 1 本にする:

```nix
  steps =
    if (build.kind or "none") == "steps" then build.steps or [ ]
    else if (build.kind or "none") == "none" then [ ]
    else [ build ];                       # スカラーは 1 要素リスト = lazy の task/plugin.lua:64 と同じ正規化
  shellSteps = builtins.filter (s: (s.kind or "none") == "shell") steps;
  anyShell = shellSteps != [ ];
```

- `anyShell` が `isShell` を置き換える。`stdenv` / `stdenvNoCC` の選択(`:44`)、`cmake` / `pkg-config` の投入(`:51-54`)、`dontBuild`(`:66`)はこれで決める。**シェル step が 1 本も無い table は `stdenvNoCC` のまま**(pure-lua プラグインの closure を汚さないという既存の判断を維持)。
- `buildPhase` は `shellSteps` を**宣言順に、各 step をサブシェルで**実行する:

```nix
    buildPhase = lib.optionalString anyShell ''
      runHook preBuild
      ${lib.concatMapStringsSep "\n" (s: "(\n${s.cmd}\n)") shellSteps}
      runHook postBuild
    '';
```

**サブシェルで包む理由(スカラー build も含めて包む)**:

1. lazy は step ごとに新しいシェルを spawn し、cwd を常にプラグイン dir に固定する(1.3 の 4)。素で連結すると step 1 の `cd` が step 2 に漏れ、lazy と挙動が変わる。
2. 1.5 の既存バグ(`cd` が `installPhase` に漏れて `$out` が壊れる)が同時に直る。**スカラー build も包む**のはこのため。挙動が変わるのは「`cd` して installPhase に漏らすことを前提にした build」だけで、それは 1.5 の実測どおり `$out` が壊れる = 元から壊れているケースである。

**ネットワーク検出**(`build-network.nix`)は **step ごとに** `detect` を掛け、最初に当たった step で evaluation 時に throw する。`buildNetwork.message` は `{ name, cmd, tool }` に**任意の `step ? null`** を足し、非 null のときだけ「(build step N)」相当の一文を添える。既存の呼び出し(`flake.nix` の `build-network-detect`、`:335-339`)は引数を増やさないので不変。

実測(scratchpad にプロトタイプ `plugin-drv-proto.nix` を書いて実行):

```
build = { kind = "steps"; steps = [ {shell "cd lua && touch inner"} {excmd ":TSUpdate"} {shell "make"} ]; }
→ $out に build/artifact.txt(step 3 が root で走った)、lua/inner、doc/tags、Makefile、scripts/run が揃う
   = cwd が漏れず、excmd はスキップされ、helptags も生成される
build = { kind = "steps"; steps = [ {shell "make"} {shell "cargo build"} ]; }
→ tryEval が success = false(step 2 で throw)
```

**サンドボックスとネットワークの関係**: 変わらない。step が増えても「サンドボックスに network は無い」という前提は同じで、`build-network.nix` のヒューリスティクス(fail open、ヘッダに明記)もそのまま適用される。`rockspec` はそもそも luarocks 経由のダウンロードが必要なので実行対象にしない(§3.4)ことで、`build-network.nix` に `rockspec` を足す必要も無くなる。

### 3.6 警告の設計

`resolve.lua` の既存の仕組みを再利用する: `warn_plugin`(`:243-245`)、プラグイン名 → メッセージのソート(`:359-367`)、`unbuildable` フラグと hatch 案内(`:371-378`)。

**プラグイン 1 件につき build 警告は 1 本**にする。step ごとに `warn_plugin` を呼ぶと、同一プラグイン内の順序が `:359-364` の「name → msg」ソートで**メッセージのアルファベット順に並び替わり、step の index 順が壊れる**(このソートは pairs() 由来の churn を防ぐためのもので、外せない)。1 本に集約すれば index 順が保たれ、既存 check の「1 プラグイン 1 警告」という数え方も維持できる。

- スカラー(`excmd` / `function`)の文言は**バイト単位で現状維持**する。`checks.resolve-build-warnings`(`flake.nix:898`、`:940` 付近)の 2 本の grep がそのまま通ることを回帰ガードとして使う。
- `steps` 用の文言(新規)。プロトタイプの実出力:

```
plugin "nvim-treesitter": build is a list of 2 steps and 1 of them cannot be run at build time:
  step 2 is a neovim command (":TSUpdate"); the remaining shell step still runs.
  nvimx merges parsers from nixpkgs instead -- set programs.nvimx.treesitter.grammars
plugin "h.nvim": build is a list of 4 steps and 2 of them cannot be run at build time:
  step 2 is a Lua function; step 3 is a neovim command (":Foo"); the remaining 2 shell steps still run
```

(実出力は 1 行。プロトタイプでは "the remaining 1 shell step(s)" になったので、単数・複数の出し分けを入れる。)

- **「残りは実行される」を必ず言う**。ユーザにとって「helptags のみ」と「一部は実行された」は全く別の状態で、`resolve.lua:371-378` の hatch 案内(「これらは helptags のみでインストールされます」)だけでは誤解を生む。案内文の方も「一部の step が実行されない」を含む言い方に直す。
- **`unbuildable = true` は部分実行でも立てる**。build が宣言どおりに完了していないので、hatch 案内は出すべきである。
- **全 step がシェルの table は完全に無言**(ゴール 4)。
- **`nvim-treesitter` 特別扱い**(`resolve.lua:287-289`)は `name == "nvim-treesitter"` のみを条件にしているので、**steps 経路でもそのまま動く**(プロトタイプで実出力を確認済み)。ただし条件を「警告を出すとき」に紐付けたまま維持すること: 実行できない step が 1 つも無ければ(= 全シェル)誘導は出ない、が正しい。
- `build_phrasing`(`:251-254`)はプレースホルダ文字列をキーにしているが、`"<table>"` は raw-spec に現れなくなる。**キーを step の `kind` に変える**(`shell` / `excmd` / `luafile` / `rockspec` / `function`)。スカラーの文言互換のため、`function` の行だけは `p.build` のプレースホルダを引用する現在の組み立てを残す。

---

## 4. 既存の契約との関係

| 契約 | 影響 |
|---|---|
| **#18 spec 恒等性**(`resolve.lua:181`, `docs/architecture.md:209`) | `build` は `identity_fields` に入っておらず、本件でも入れない。table build の記録形が変わっても `resolvedRef` は 1 件も再解決されない。`:179-180` のコメントは無変更で有効 |
| **#18 merge 契約**(`docs/architecture.md:209`) | 「`pin` / `dependencies` / `build` は毎回 spec から更新されるが決定を無効化しない」がそのまま成立。`build` の形が増えるだけ |
| **#18 冪等性** | `build` は raw-spec の純関数なので 2 回目も同一。`checks.resolve-merge` の `cmp out1.json out2.json` はそのまま通る |
| **#22 警告**(`resolve.lua:243-245`, `:371-378`, `lock-app.nix:49-59, 89-102, 116-140`) | 同じ経路に乗せる。lock は成功し続ける(exit 0)。`lock-app.nix` の 2 パスは同じ raw-spec を読むので**両パスの警告が一致する**性質も保たれる(build は flake.lock に依存しない) |
| **`build-registry`** | registry entry は渡された `build` を読まず自前で組む(1.4)ので無変更。`telescope-fzf-native.nvim` / `fzf` は table build でも今と同じく registry が勝つ。`default.nix:21` のコメント(`{ kind, cmd }`)は更新 |
| **`plugins.overrides` / `nixpkgsFallback`** | `resolve-plugin.nix:61-69` の `args.build` に新形が流れる。override 側が `build` を読むことは想定されていない(`defaultDrv` を使うのが定石)が、**読む override が書けるようにドキュメントの形を更新する**。`generic` の遅延性(`:57-60` のコメント)も維持 — network step の throw を hatch で回避できる性質は steps でも同じ |
| **`build-network.nix` の fail-open 方針** | 維持。step 単位に適用範囲が広がるだけ。`sh -c "npm install"` 等の盲点も同じ |
| **`treesitter.grammars`** | `make-env.nix:58-65` の merge は resolution の**上**に乗るので無変更。`nvim-treesitter` の build が `steps` になっても grammars merge は効く |

---

## 5. 実装手順

作業単位はファイル単位。行番号は現 main(`18a28b3`)基準だが、着手時は #42 / #31 で動くので**シンボルで位置合わせすること**(冒頭の表)。

### 5.1 `lua/nvimx/extract.lua`

1. `dump_plugin` 冒頭の build 記録ブロック(`:41-44`、#42 後 `:69-72`)を §3.2 のコードに置き換える。`dump_build_step` はローカル関数として `dump_plugin` の**外**に出す(`effective_version` と同じ流儀。単体で呼べる純関数にしておく)。
2. ヘッダコメント(`:1-14`)に「`build` は string / string の配列 / `false` / 未設定のいずれかで dump する。分類は resolve.lua の仕事」を 1-2 行で追記。lazy 側の根拠として `lua/lazy/manage/task/plugin.lua:57`(false)と `:64`(スカラー = 1 要素リスト)を引く。
3. `dump_plugin` の他フィールドは無変更。#42 の `effective_version` / 第 2 引数とは**同じテーブルリテラルの別行**なので衝突しない。

### 5.2 `lua/nvimx/resolve.lua`

1. **`classify_step(v)` を新設**(`build_phrasing` の直前、`:251` 付近)。lazy の判定順(1.3 の 3)を写す純関数: 先頭 `<` → `function` / `"rockspec"` → `rockspec` / 先頭 `:` → `excmd` / `%.lua$` → `luafile` / それ以外 → `shell`。非文字列は `function`。
2. **`classify_build(b)` を新設**。`false` / `nil` → `{ kind = "none" }`、文字列 → `classify_step`、テーブル → 要素を `classify_step` して `steps`(空なら `none`)。`steps` は `json.array(...)` で包む(`json.lua:7-9` のマーカー。要素 0 のときに `{}` にならないよう、また意図を明示するため)。
3. **`build_phrasing`(`:251-254`)を kind キーに書き換え**、`luafile` / `rockspec` / `shell` を追加。コメントも「extract は任意の非文字列を `<type>` にする」という前提の説明から、「kind ごとの人間向け表現」に直す。
4. **分類ブロック(`:266-275`)を `local build = classify_build(p.build)` に置き換え**。
5. **警告ブロック(`:281-291`)を書き換え**:
   - 実行できない step の一覧を求めるヘルパ(`unrunnable_steps(build)`)と、メッセージ組み立て(`build_warning`)を追加。
   - スカラー `excmd` / `function` の文言は**現状のまま**(§3.6)。
   - `steps` は index 付き列挙 + 「残り N 本のシェル step は実行される」。
   - `unbuildable = true` は「実行できない step が 1 本以上」で立てる。
   - `nvim-treesitter` 分岐(`:287-289`)は現状のまま流用(steps でも動く)。
6. **hatch 案内(`:371-378`)の 1 行目を修正**: 「helptags only」だけでなく「一部の step が実行されない場合がある」を含む言い方にする。
7. stylua(#31、`column_width = 120`)に収まる改行にする。`("..."):format(...)` の連鎖が長くなるので、メッセージ組み立ては小さな関数に割ること。

### 5.3 `nix/lib/plugin-drv.nix`

1. ヘッダのコメント表(`:5-8`)を新しい `kind` 一覧に更新。`steps` / `rockspec` / `luafile` を追加し、「shell step のみ実行、他はスキップ」「step ごとに新しいサブシェル、cwd はプラグインルート(lazy `task/plugin.lua:32-40` と同じ)」を明記。
2. `let` ブロック(`:27-32`)を §3.5 の `steps` / `shellSteps` / `anyShell` に置き換え。`isShell` / `cmd` は消える。
3. ネットワーク検出を step 単位に(`:32`, `:34-41`)。当たった step の `cmd` と(あれば)index を `buildNetwork.message` に渡す。
4. `:44`, `:51`, `:66`, `:67-71` の `isShell` を `anyShell` に。`buildPhase` は `lib.concatMapStringsSep "\n" (s: "(\n${s.cmd}\n)") shellSteps`。**1 行の `( … )` にしてはいけない**: cmd に末尾 `#` コメントが含まれると閉じ括弧がコメントに飲まれて構文エラーになる(実測)。現行実装は cmd を単独行に展開しているので、複数行のサブシェルにしないと微小な退行になる。
5. `installPhase`(`:73-83`)は無変更。

### 5.4 `nix/lib/build-network.nix`

`message` に任意引数 `step ? null` を足し、非 null のとき「build step N」であることを本文に出す。`detect` は無変更(純粋な文字列関数のまま)。既存の呼び出し互換を壊さないこと(`flake.nix:335-339`)。

### 5.5 `nix/build-registry/default.nix`

`:21` の `#   build        the build recorded in plugins.json ({ kind, cmd })` を新しい形に更新(`{ kind, cmd }` または `{ kind = "steps", steps }`、registry entry は通常これを読まず自前で組む、という現状の運用も 1 行で残す)。

### 5.6 `docs/architecture.md`

1. `:190`(スキーマ例の `build` 行、#42 後 `:194`): `kind` の値域を更新し、`steps` の例を 1 つ載せる。
2. `:209` の merge 契約(#42 後 `:213`): `build` が恒等性に入らないことは現状どおり。文言変更は不要だが、`build` が「spec から毎回更新される」対象であることは維持されているか確認する。
3. `:273-286`(Plugin derivations の項目 4、#42 後 `:278-291`): 「`function` は非文字列 build のすべて。lazy のリスト形式もそこに落ちる」という**現在の記述は本件で嘘になる**ので書き換える。新しい記述に必要なのは (a) `steps` は shell step を順に実行しシェル step 以外はスキップ、(b) 各 step は独立したサブシェルで cwd はプラグインルート、(c) 部分実行のときも lock 時に警告する、(d) `rockspec` / `luafile` は実行しない。
4. `:448`(edge case 表、#42 後 `:453`): `build is a Lua function / excmd` の行を、table / `rockspec` / `*.lua` / `false` を含む形に拡張(1 行追加でもよい)。
5. `:455`(luarocks 非対応の行)との整合を確認(`rockspec` kind はこの方針の実装であると読めるようにする)。なおこの行は存在しない hm オプション `extraLuaPackages` を hatch として案内している(実在するのは `extraPackages` のみ、`nix/home-manager/default.nix:85`)。既存の doc 齟齬で本件のスコープ外だが、#27 がまさにそのオプションを追加する issue なので放置してよい。
6. `:431`(fixtures ディレクトリの列挙行)に新 fixture `build-steps-config` を追記。#42 がこの一覧を実態に合わせたので、片方だけ足さないこと。

### 5.7 `README.md`

計画レビューで抜けが判明した箇所。

1. `:195-198` — 「A spec whose `build` is an ex command, a Lua callback, **or a list of steps** has nothing nvimx can execute directly, so the plugin is installed with helptags only」。本件後は嘘になるので書き換える。list of steps は shell step を実行し、実行できない要素だけをスキップする。
2. `:189` — 「run `build.kind == "shell"` if the spec declared one」。`steps` も実行対象であることを反映する。
3. `:160-176` — override に渡る引数と `mkPluginDrv` の例が `build = { kind, cmd }` の形。`steps` 形も併記する(§7-7 の互換性の話と対応させる)。

### 5.8 `nix/build-registry/nvim-treesitter.nix`(新規)

§7-2 の決着に対応。宣言された build を無視して copy + helptags に落とす entry。既存 entry(`fzf.nix` / `telescope-fzf-native.nvim.nix`)を手本にし、`default.nix` の登録も行う。「parser は `programs.nvimx.treesitter.grammars` が担うので、上流の `make` はサンドボックスで成立しないうえに不要」という理由をコメントで残すこと。

### 5.9 fixtures / checks

§6 参照。

---

## 6. テスト

### 6.1 fixtures

| fixture | 変更 | 目的 |
|---|---|---|
| `tests/fixtures/unbuildable-config/init.lua` | `L3MON4D3/LuaSnip`(`build = { "make install_jsregexp" }`)を**この fixture から外す**。`nvim-treesitter`(`:TSUpdate`)と `markdown-preview.nvim`(関数)は現状維持 | この fixture の役目は「**まったく**実行できない build の形」。全シェルの table は実行できるようになるので、ここに残すと fixture の説明(ヘッダコメント `:1-5`)と矛盾する。ヘッダも合わせて直す |
| `tests/fixtures/build-steps-config/`(**新規**) | `init.lua` のみ(never built、`nvimx-lock/` 無し。`unbuildable-config` と同じ構成)。内容: ① `nvim-treesitter/nvim-treesitter` `build = { "make", ":TSUpdate" }`(issue の例。混在 = 部分実行 + treesitter 誘導)② `L3MON4D3/LuaSnip` `build = { "make install_jsregexp" }`(全シェル = 静かな経路)③ 全要素が実行不可の table(`{ function() ... end, ":Foo" }`)④ `build = false` ⑤ `build = "rockspec"` ⑥ `build = "install.lua"` | table 形式と §3.4 の各 kind を lock 時経路で網羅。①②が同じ fixture に同居できるのは別プラグインだから |
| `tests/fixtures/build-plugins/nvimx-lock/plugins.json` | 無変更を第一候補とする | `build-shell` / `plugins-nixpkgs-fallback` / `hm-module` の入力。この lock の `telescope-fzf-native.nvim` は registry entry が勝つので `build` の形を変えても実行経路は変わらず、テストの価値が薄い。makeEnv が `steps` を透過することの確認は 6.2 の `plugin-drv-phases` で足りる |

`build-steps-config` の ③〜⑥ は実在しないプラグインを使わない方がよいが、この fixture は extract しかされない(fetch されない)ので、**実在するプラグイン名に妥当でない build を付ける**より、**「そのプラグインが実際に取りうる形」に寄せる**こと。少なくとも ④(`build = false`、上流 spec の build を打ち消す実在パターン)と ⑤⑥ は lazy のドキュメント上の正規の形なので、コメントで「どの lazy の分岐(`task/plugin.lua:69` / `:73`)を突いているか」を書き残す。

### 6.2 `checks`(`flake.nix`)

**`plugin-drv-phases`(`:221-257`)— 実行側の主戦場。ローカル fixture のみで完全にオフライン。**
`mkLocal` に steps の case を足す:

1. `steps` 2 本の shell が**順に**走る(step 1 が作ったファイルを step 2 が読む / 追記する形で順序を assert)。
2. 混在 `[ shell "cd lua && touch inner", excmd ":TSUpdate", shell "make" ]` → `build/artifact.txt` と `lua/inner` の**両方**が存在し、`doc/tags` も生成される。**これが 1.5 の cwd リークと step 間リークの回帰ガードになる**(実測済み: プロトタイプで再現確認)。
3. 全要素が実行不可の `steps` → `test ! -e $out/build`、helptags のみ。
4. スカラー `{ kind = "shell"; cmd = "cd lua && touch marker"; }` → `$out/Makefile` と `$out/doc/tags` が残る(1.5 の既存バグの回帰ガード。**現状の実装では落ちる**)。
5. 既存の `shell` / `excmd` / `none` の 3 case と `dontFixup` 系 assert(`:246-255`)は無変更で維持。

**`resolve-build-warnings`(`:898-975`)— lock 側の主戦場。**

- 既存部: `unbuildable-config` から LuaSnip が消えるので、`grep 'build is a list of build steps ("<table>")'`(`:940` 付近)と `.plugins["LuaSnip"].build == { kind: "function" }`、`warnings | length == 3` → 2 に、`n -ne 3` → 2 に修正。**さらに `flake.nix:1026-1028` の `.warnings[0] | startswith("plugin \"LuaSnip\"")` / `[1]` / `[2]` の 3 本を再インデックスすること**(LuaSnip が抜けると添字が全部ずれる。check が落ちるので取り逃しはしないが、修正列挙に入れておく)。`nvim-treesitter`(excmd)と `markdown-preview.nvim`(function)の 2 本の grep は**バイト単位で不変**であることを確認する(§3.6 の互換方針の検証)。
- 追加部: `build-steps-config` を extract → resolve して、
  - `rc == 0`(warning に留まる)。
  - `.plugins["nvim-treesitter"].build.kind == "steps"`、`.build.steps | length == 2`、`.build.steps[0] == {kind:"shell",cmd:"make"}`、`.build.steps[1] == {kind:"excmd",cmd:":TSUpdate"}` — **要素が 1 つも失われないことと順序の assert**。
  - 警告文に `step 2`、`":TSUpdate"`、「残りは実行される」旨、`programs.nvimx.treesitter.grammars` が含まれる。
  - LuaSnip: `.build.kind == "steps"`、`.build.steps[0].kind == "shell"`、**この プラグインについての警告が 0 件**。
  - `build = false` → `.build == { kind: "none" }` かつ警告 0 件(1.2 の偽陽性の回帰ガード)。
  - `rockspec` → `.build == { kind: "rockspec" }`、`*.lua` → `{ kind: "luafile", cmd: "install.lua" }`、それぞれ警告 1 件。**`kind == "shell"` になっていないこと**を明示的に assert(1.2 の退行ガード)。
  - `warnings` 配列が plugins.json にもプラグイン名順で入っていること(既存の流儀)。
  - 既存の「静かな経路」(`build-plugins` fixture、`:1030-1039`)は無変更で維持。

**`build-network-detect`(`:260-377`)**

- `mkPluginDrv` が `steps` の中の network step で throw することと、オフラインな `steps` では throw しないことを `evaluates` と同じ `tryEval` パターンで追加。
- `buildNetwork.message` の既存呼び出し(`:335-339`)が引数追加後も通ること(= `step` は任意)を、そのまま通ることで確認。
- `detect` 自体の case 表(`:264-333`)は無変更。

**`resolve-merge`(`:981-1245`)**: 変更不要の見込み。`tests/fixtures/merge/*.json` は手書き raw-spec で `build` を持たない(= `{ kind: "none" }`)ため、`golden/base.plugins.json` にも差分は出ない。**着手時に `jq '.plugins[].build' tests/fixtures/merge/golden/base.plugins.json` で確認すること**。差分が出るなら golden を再生成する。

**`extractor-snapshot`(`:833-859`)**: `tests/fixtures/golden/basic-config.raw-spec.json` は `build` キーを持たない(`basic-config` が build を宣言していない)ため**差分なし**。golden の再生成は不要。これをゴールとして明示的に確認する。

### 6.3 手元確認(実装中)

```sh
# 1) 抽出 → 解決の往復(オフライン)
#    sandbox の作り方は flake.nix:898 の check と同じ(XDG_* と NVIMX_LAZY_SEED)
nvim -l lua/nvimx/resolve.lua <raw-spec> plugins.json    # 警告文と build の形を目視
# 2) 冪等性
nvim -l lua/nvimx/resolve.lua <raw-spec> a.json && nvim -l lua/nvimx/resolve.lua <raw-spec> b.json --prev a.json && cmp a.json b.json
# 3) 旧 lock 互換(§3.3 方向 A): build が {kind:"function"} の plugins.json を --prev に渡し resolvedRef が保たれること
# 4) step 実行(§3.5 の実測手順)
nix build --impure --expr '... mkPluginDrv { build = { kind = "steps"; steps = [...]; }; }'
```

### 6.4 CI / darwin

- **CI ファイルは編集しない**。`.github/workflows/check.yml` は `nix flake check` と `nix fmt -- --ci` を実行するだけで(`:18-22`)、check は自動的に拾われる。仮に手を入れる必要が生じたら、`CLAUDE.md` の規約どおり `check.yml`(reusable workflow)**のみ**を編集し、`ci-linux.yml` / `ci-darwin.yml` は触らない。
- **darwin 評価確認**(ローカル linux の `nix flake check` は darwin を omit する):

```sh
nix eval .#checks.aarch64-darwin.plugin-drv-phases.drvPath
nix eval .#checks.aarch64-darwin.resolve-build-warnings.drvPath
nix eval .#checks.aarch64-darwin.build-network-detect.drvPath
```

`( cmd )` のサブシェルは bash 依存の構文ではないので darwin 差はない。`stdenv` の選択が `anyShell` で変わる点も既存と同じ構造。

- `nix fmt -- --ci`(#31 適用後は lua も対象になる)。

---

## 7. リスク / 未決事項

1. **評価時 throw の新規発生(最大のリスク)**。table の中に network コマンドがある build(`{ "cargo build", ":Foo" }` 等)は、これまで table ごと捨てられて評価が通っていたが、本件後は `plugin-drv.nix` が**評価時に throw** する。緩和: (a) throw は **再 lock 後にしか起きない**(既存 lock は `{kind:"function"}` を持つので、アップグレードしただけでは何も変わらない)、(b) メッセージが 3 つの hatch を名指しする(`build-network.nix:146-169`)、(c) `resolve-plugin.nix:57-60` の遅延性により `overrides` / `nixpkgsFallback` で確実に回避できる。判断: **受け入れる**。「黙って落とす」より「大声で止まる」は #17 / #22 が既に選んだ方針であり、スカラー build と同じ扱いにするのが一貫している。resolve は Nix 側の検出器を呼べないので lock 時に予告することはできない(検出ロジックを Lua に複製するのは却下)。
2. **これまで実行されなかった step が実行され、失敗するようになる** — **決着済み。`nix/build-registry/nvim-treesitter.nix` を本件と同一 PR で追加する。**

   計画レビューで実際に確認した結果、`nvim-treesitter` の `make` は**サンドボックスで確実に失敗する**。default branch は現在 `main` で、その Makefile は `.DEFAULT_GOAL := all` / `all: lua query docs tests` であり、**全ターゲットが curl / git clone で依存(nvim nightly, emmylua, ts_query_ls, highlight-assertions, plentest)を取得してから走る**。しかも宣言されたコマンド文字列は素の `make` なので `build-network.nix:12-15` の検出器は素通しする(同ファイルが自ら文書化している盲点)。legacy の `master` は先頭ターゲットが `build: echo "Do nothing"` で無害だが、`main` 追従の config では本件によって「helptags のみで成功」→「不透明なビルド失敗」に変わる。

   `{ "make", ":TSUpdate" }` は issue #36 が挙げる主対象例そのものなので、これを壊したまま出すことはできない。registry entry で宣言された build を無視して copy + helptags に落とし、parser は `treesitter.grammars` の merge に任せる — これは「build 宣言がサンドボックスで成立しないプラグインを nvimx が救う」という `nix/build-registry/` の本来の用途である。

   残るリスクは「他のプラグインの table build にも同種のものがある」こと。緩和は lock 時警告がどの step が走るかを明示すること、および 3 つの hatch が案内されることで足りる。
3. **サブシェル化によるスカラー build の挙動変更**。1.5 のとおり「`cd` して installPhase に漏らす」build は現状 `$out` が壊れるので、実質的に修復である。ただし「壊れた `$out` に依存して動いていた」ケースは理論上ありうる。§6.2 の case 4 で新しい正しい挙動を固定する。
4. **`rockspec` / `luafile` / `false` の同時対応(スコープ)**。§3.4 のとおり `rockspec` は退行回避のために不可分。`luafile` と `false` は数行だが、レビューで「別 issue にせよ」と判断されうる。その場合の最小分割: `rockspec` は本件に残し、`luafile` は `shell` のまま(= 現状維持)にして別 issue へ。`false` も別 issue へ。**分割しても本件のゴール 1〜4 は達成できる**。
5. **`build.lua` / `build/init.lua` の自動検出**(lazy `task/plugin.lua:9-15, 61`)は既存の非対応であり、本件では**扱わない**。table 形式とは独立した「build 未宣言でも build がある」問題なので、必要なら別 issue。
6. **警告文の長さ**。steps の警告は 1 本が長くなる(step が多い場合)。`plugins.json` の `warnings` 配列にも同じ文字列が入るので、committed lock の diff が読みづらくなりうる。step 数の上限で切る(「... and 3 more」)案もあるが、情報を落とすと本件の趣旨に反するため**切らない**方針とする。
7. **`overrides` が `build` を読む場合の互換**。ドキュメント上 `build` は override に渡る引数の 1 つで(`docs/architecture.md:256`)、`{ kind, cmd }` を読んでいる利用者がいれば `steps` で `cmd` が nil になる。破壊的だが、`build` を読む override は定石ではなく(`defaultDrv` を使う)、リポジトリ内には 1 件も存在しない。docs 側で新しい形を明記して周知する。
8. **`schemaVersion` を上げない判断の再確認**。§3.3 の 3 方向分析は本計画時点の消費者一覧(1.4)に基づく。着手時に `grep -rn '\.build' lua nix flake.nix` で消費者が増えていないか再確認すること。
