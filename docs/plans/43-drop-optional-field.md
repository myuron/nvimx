# #43 対応計画: 常に null な `optional` フィールドを plugins.json から削除する

対象 issue: [#43 refactor(resolve): drop the always-null optional field from plugins.json](https://github.com/myuron/nvimx/issues/43)

直前の #18 (PR #41, `d85558e`) で `plugins.json` のプラグインエントリに `pin` / `optional` / `dependencies` の 3 フィールドが追加された。本件はそのうち `optional` が構造上常に `null` であることを確認して取り除く、純粋な後片付けである。設計上の前提は `docs/plans/18-resolve-merge-plugins-json.md` の §3(スキーマ、spec 恒等性、`resolvedRef` の意味論)を引き継ぐ。

作業順序: 本件が最初で、現在の main (`d85558e`) の上に直接乗る。以降 #42(`defaults.version` の取り落とし)→ #31(stylua / luacheck の treefmt 追加)→ #36, #23, #24, #25 の順。#42 も `extract.lua` の `dump_plugin` と同じ fixtures を触るため、本件を先に入れて #42 が削除後のスキーマを前提にする(逆順だと golden の再生成が二重になる)。

## 1. 背景 / 現状

### 1.1 nvimx 側の現状

- `lua/nvimx/extract.lua:56` — `optional = p.optional,` で lazy の正規化済みプラグインから `optional` を raw-spec に dump している。
- `lua/nvimx/resolve.lua:301` — `optional = p.optional or vim.NIL,` でエントリに載せている。`p.optional` が真値でない限り `vim.NIL`(= JSON の `null`)になる。
- `lua/nvimx/resolve.lua:179-180` — spec 恒等性のコメントで「`pin` / `optional` / `dependencies` / `build` は ref の決定に影響しないので恒等性に**含めない**」と明記されている。恒等性は `identity_fields = { "branch", "tag", "commit", "version" }`(`resolve.lua:181`)+ `source_fields`(`:182`)のみ。**`optional` は spec 恒等性に入っていない**。これが後述する互換性判断の土台になる。
- `docs/architecture.md:188` — スキーマ例に `"optional": null, // lazy's optional (recorded only; does not affect the build)`。
- `docs/architecture.md:210` — merge contract の「再解決を起こさないメタデータ」の列挙に `optional` が含まれる。

### 1.2 消費者の棚卸し(`optional` を読むコードは 1 つも無い)

| 読み手 | 実際に読むキー | `optional` |
|---|---|---|
| `lua/nvimx/resolve.lua`(prev として) | `schemaVersion`(:119)、`plugins`(:128)、`resolvedRef`(:312)、`pin`(:319)、`identity_fields` + `source_fields`(:181-182) | 読まない |
| `lua/nvimx/genflake.lua:26-69` | `source` / `commit` / `resolvedRef` / `tag` / `branch` / `inputName` | 読まない |
| `nix/lib/make-env.nix:41-50` | `lazyNvim.inputName`(:36)、`plugins` の各 `inputName` / `build` | 読まない |
| `nix/lib/resolve-plugin.nix` | `name` / `src` / `build` のみ(make-env から渡される) | 読まない |
| `nix/lib/sources.nix` | `flake.lock` のみ | 読まない |

さらに raw-spec.json 自体がユーザに届かない: `nix/lib/lock-app.nix:48` の `mktemp -d` 内に書かれ(`:74` の `NVIMX_OUT`)、`:53-59` の `trap cleanup EXIT` で削除される。リポジトリに残る唯一の raw-spec は `tests/fixtures/golden/basic-config.raw-spec.json`(`extractor-snapshot` の golden)である。

### 1.3 lazy.nvim 側の根拠(pinned seed で実読)

seed は `flake.lock` の `lazy-nvim` = rev `306a05526ada86a7b30af95c5cc81ffba93fef97`。ストアパスは
`nix eval --impure --raw --expr '(builtins.getFlake (toString ./.)).inputs.lazy-nvim.outPath'` → `/nix/store/d9jq3s81p4i9q6g8gaa6f2pn51p8za9l-source`。以下は同パスの実ファイルからの引用。

1. `lua/lazy/core/plugin.lua:32` — `self.optional = opts and opts.optional`。`extract.lua:78` は `Plugin.Spec.new(spec, { pkg = false })` なので `Spec.optional` は常に `nil`。
2. `lua/lazy/core/meta.lua:355` — `while self:fix_disabled() + self:fix_optional() > 0 do`。resolve は不動点まで回る。
3. `lua/lazy/core/meta.lua:289-292` — `fix_optional()` の早期 return は `if self.spec.optional then return 0 end`。1 より発火しないので、`fix_optional` は必ず本体まで進む。
4. `lua/lazy/core/meta.lua:295-297` — `if plugin.optional then ... self:del(plugin.name) end`。**全 fragment が optional なプラグインは削除される**。
5. `lua/lazy/core/meta.lua:183` / `:197` — `_rebuild` は `plugin.optional = true` から始め、`plugin.optional = plugin.optional and (rawget(fragment.spec, "optional") == true)` で畳み込む。非 optional な fragment が 1 つでもあれば `false` になる。
6. `lua/lazy/core/meta.lua:246-248` — `if not plugin.optional and not super.optional then plugin.optional = nil end`。

ここで issue 本文より一段強い結論が出る。5 で `false` になったプラグインでも、別 fragment が `optional = true` を持っていれば `super`(fragment spec の `__index` チェーン)経由で `super.optional` が真になり、6 の nil 化が**走らない**。つまり `p.optional` の値域は:

| 状況 | `p.optional` | `s.plugins` に残るか |
|---|---|---|
| 全 fragment が optional | `true` | 残らない(4 で削除) |
| optional / 非 optional が混在 | `false`(6 が走らない) | 残る |
| optional 指定なし | `nil`(6 で nil 化) | 残る |

**`s.plugins` に到達する `p.optional` は `nil` か `false` のみ**であり、`resolve.lua:301` の `p.optional or vim.NIL` はどちらの場合も `vim.NIL` になる。よって `plugins.json` の `optional` は**構造上常に `null`**。

### 1.4 実測(seed 306a055、ローカルでオフライン実行)

`{ "nvim-lua/plenary.nvim", optional = true }`(optional-only)、`{ "folke/tokyonight.nvim", optional = true }` + `{ "folke/tokyonight.nvim" }`(混在 fragment)、`{ "nvim-telescope/telescope.nvim", dependencies = { { "nui.nvim", optional = true } } }`(optional な依存)を含む config を `extract.lua` → `resolve.lua` に通した結果:

- optional-only の `plenary.nvim` と optional な依存 `nui.nvim` は raw-spec / plugins.json の**双方から消える**。親の `dependencies` からも落ちて `[]` になる。
- 混在 fragment の `tokyonight.nvim` は raw-spec に `"optional": false` として現れる(1.3 の 5/6 の帰結)。
- plugins.json 側は 3 プラグインすべて `"optional": null`。

### 1.5 その結果、現在の fixture は到達不能な状態を golden 化している

`tests/fixtures/merge/*.json` は手書き raw-spec なので `optional: true` を書けてしまう。

- `tests/fixtures/merge/raw-spec-base.json:23` / `raw-spec-added.json:22` / `raw-spec-branch-changed.json:35` に `"optional": true`
- その帰結として `tests/fixtures/merge/golden/base.plugins.json:61` が `"optional": true` を固定
- `flake.nix:1062` の `jq -e '.plugins["custom.nvim"].optional == true' out5.json` がその架空値に依存

実 extract 経路では絶対に生じない値をテストが固定している状態で、削除の副産物としてこれも解消される。

一方 `tests/fixtures/golden/basic-config.raw-spec.json` には `optional` キーが**存在しない**。`vim.json.encode` は値が `nil` のキーを落とすためで、`basic-config` の `tokyonight.nvim` は `optional` 未指定だからである。→ `extract.lua` から `optional` を落としてもこの golden に差分は出ない(§5 で実測確認済み)。

そして `plugins.json` 側で `null` が明示的に出るのは、`resolve.lua` が `vim.NIL` を書いており `lua/nvimx/json.lua` がそれを `null` として出力するためである。

## 2. ゴール

issue の "Done when"(`optional` がどの plugins.json / fixture にも現れない、`nix flake check` が通る)を検証可能な形にすると:

1. **削除の完了**: `grep -n 'optional' lua/nvimx/*.lua` が空(`lib.optional` のような同名の Nix 関数は lua には無いので完全に空になる)。`grep -rn '"optional"' tests/ docs/architecture.md README.md` が空。
2. **既存 check の通過**: `nix flake check`(linux)がグリーン。`nix fmt -- --ci` が通る。
3. **darwin 評価**: `nix eval .#checks.aarch64-darwin.resolve-merge.drvPath` と `... .extractor-snapshot.drvPath` が通る(CLAUDE.md の規約。ローカル linux の `nix flake check` は darwin を omit するため必須)。
4. **回帰ガード**: `optional` をエントリに戻すと落ちる assert が `checks.resolve-merge` に存在する。
5. **互換性**(§3.2 で検証):
   - 旧形式(`optional` 入り)の plugins.json を `--prev` に渡しても、凍結済み `resolvedRef` が 1 つも失われない。
   - 新形式(`optional` 無し)を旧 `resolve.lua` が `--prev` として読んでも同じ。
   - 生成される `flake.nix` / `flake.lock` が不変(= ユーザに再 fetch / 再ビルドを強制しない)。
6. **冪等性の維持**: 削除後の resolve が 1 回で不動点に達する(`--prev` に自分の出力を渡して byte-identical)。
7. **意味論の明文化**: `optional` フィールドの削除で失われる情報の代わりに「optional-only プラグインは lazy 自身が落とすので nvimx は lock しない」が docs と test の双方に残る。

## 3. 設計

### 3.1 何を消し、何を残すか

| 対象 | 判断 |
|---|---|
| `resolve.lua:301` のエントリ構築 | **削除**(本件の主目的) |
| `resolve.lua:179-180` のコメント | `optional` を列挙から外す |
| `extract.lua:56` の `dump_plugin` | **削除**(下記) |
| `extract.lua:78` の `Spec.new(spec, { pkg = false })` | **無変更**(§3.4) |
| `pin` / `dependencies` | 残す。実値を取り、`pin` は凍結の判断に使われる(`resolve.lua:319`, `:330`) |
| `genflake.lua` / `nix/lib/*` | 無変更(1.2 の通り誰も読んでいない) |

**`extract.lua:56` を削除する判断と理由**

- 採用理由:
  1. raw-spec.json はユーザに届かない中間物である(`lock-app.nix:48` の sandbox に書かれ `:53-59` の trap で消える)。「診断情報としての価値」を主張できる読み手が実質存在しない。唯一リポジトリに残るのは `extractor-snapshot` の golden で、そこには元々このキーが無い(1.5)。
  2. 値域が `{ nil, false }` に限られる(1.3)。`false` は「optional / 非 optional の fragment が混在した」という情報ではあるが、それが分かってもユーザにも nvimx にも取れるアクションがない — lazy はそのプラグインを install するし nvimx も lock する。挙動に一切の差がない。
  3. 残すと「なぜ raw-spec には出るのに plugins.json では常に null なのか」という、まさに今回 issue になった混乱を再生産する。フィールドの寿命を 1 段階だけ延ばす価値はない。
  4. golden への影響がゼロ(1.5、§5 で実測確認)。削除コストが実質ゼロである。
- 却下案「extract には残す」: 上記 2 により診断価値が薄い。将来 optional-only プラグインも lock する方針に変えるなら、`Spec.new` への `{ optional = true }` 追加(§3.4)と**同時に**、意味を伴った形で復活させるべきである。いま `nil` / `false` しか入らないフィールドを温存する理由にはならない。

### 3.2 `schemaVersion` は 1 のまま(issue の提案を検証した上で追認)

issue 本文は「`schemaVersion` は 1 のまま」を提案しているが、「追加は additive だがフィールドの削除は additive でない」ため、そのまま鵜呑みにはできない。危険なのは**キーの存在を前提に読む読み手**がいる場合なので、双方向で確認した。

**方向 A: 旧 nvimx が新ファイルを読む**

- prev 読み: 旧 `resolve.lua` が prev から読むのは `schemaVersion` / `plugins` / 各エントリの `resolvedRef` / `pin` / `identity_fields` / `source_fields` だけ(1.2)。`prev.optional` を読む行は存在しない。`same_identity`(`resolve.lua:184-200`)も `optional` を比較しないので、キーが無いことが恒等性を破って再解決を引き起こすことはない。
- lockDir 読み: `make-env.nix` / `genflake.lua` も読まない。
- 実測: 削除後の plugins.json を旧(main の)`resolve.lua` に `--prev` として渡し、`tokyonight.nvim` = `aaaa...`、`custom.nvim` = `bbbb...` の凍結 rev が両方保持されることを確認。

**方向 B: 新 nvimx が旧ファイルを prev として読む**

- 実測: `tests/fixtures/merge/golden/base.plugins.json`(`optional` 入り)を `--prev` に、`raw-spec-base.json` + `merge/flake.lock` を入力として削除後の `resolve.lua` を実行 → 凍結 rev は両方保持され、出力は「旧 golden から `optional` 行を削ったもの」と byte-identical。さらにその出力を `--prev` に渡した 2 回目は byte-identical(不動点)。

**bump は有害である**

`resolve.lua:119-127` は `prev.schemaVersion ~= 1` をハードエラーにし、「upgrade nvimx, or delete the file and run nvimx-lock again -- deleting it loses the pinned revs」と案内する。2 に上げると、既存ユーザの committed plugins.json が新 nvimx から読めなくなる。案内どおり削除すれば**pin が全損**する。回避するには v1 も受理する互換読みコードを足すことになるが、それはキー 1 個の削除のために払うコストではない。

**結論**: `schemaVersion` は 1 のまま。理由は「削除だから安全」ではなく「`optional` を読む読み手が全消費者のうち 1 つも存在せず(1.2)、かつ spec 恒等性に含まれていない(`resolve.lua:181`)ため、キーの消失が観測できるコードパスが無い」から。代わりにユーザ側で起きることを許容する: アップグレード後の初回 lock で committed plugins.json から `"optional": null` 行が消える差分が出る。`genflake` の入力に `optional` は含まれないので生成 `flake.nix` は不変、したがって `flake.lock` も不変で、再 fetch も再ビルドも起きない。

### 3.3 `checks.resolve-merge` の assert をどうするか

**(a) `flake.nix:1062`(`.plugins["custom.nvim"].optional == true`)— 削除だけでは不十分**

この assert は `flake.nix:1053-1055` のコメントが述べる主張「ref に影響しないメタデータの編集は凍結を解かない」を、pinned な `custom.nvim` について検証する唯一の手段である。単純に削除すると `raw-spec-branch-changed.json` の `custom.nvim` は `raw-spec-base.json` と完全一致になり、`:1060-1061` の「凍結 rev が残る」assert は自明に通るだけのゼロ情報 assert に劣化する。

- 採用: メタデータ編集を `dependencies` で表現し直す。`raw-spec-branch-changed.json` の `custom.nvim` から `"optional": true` を消し、代わりに `"dependencies": ["plenary.nvim"]` を入れる。assert は `jq -e '.plugins["custom.nvim"].dependencies == ["plenary.nvim"]' out5.json`。`dependencies` は spec 恒等性の外にあり(`resolve.lua:181`)実値を取る唯一残ったフィールドなので、テストの意図をそのまま移せる。
- 却下: `build` を使う。`build` も恒等性外だが、`build.kind` が `excmd` / `function` だと warning が発生して `warnings` 配列と stderr が変わり、他の assert(`:1130` 付近の「解決済み制約は warn しない」など)に副作用が及ぶ。`dependencies` の方が副作用ゼロ。
- 却下: テストケースごと削除する。「メタデータ編集で pin が解けない」は #18 の契約の一部(`docs/architecture.md:210`)であり、カバレッジを落としてはならない。

**(b) 「`optional` キーが存在しないこと」を assert するか**

- 採用: する。実 extract 経路に **2 本**置く。`resolve.lua` 側と `extract.lua` 側は別々に守る必要がある(下記)。
  - 手書き raw-spec 経路は `flake.nix:1007` の `diff -u $fx/golden/base.plugins.json out1.json` が byte 単位のガードになっており、golden に `optional` が無ければ再導入は即座に落ちる。ここに追加の `has("optional")` は要らない。
  - ガードが無いのは `flake.nix:1142-1163` の実 extract → resolve 経路(golden を持たない)。そこで `flake.nix:1162` の `.plugins["plenary.nvim"].optional == null` を `jq -e 'all(.plugins[]; has("optional") | not)' extracted.json` に**差し替える**。
  - **plugins.json 側の assert だけでは `extract.lua` の復活を検知できない。** `resolve.lua` のエントリ構築はフィールドの明示列挙なので、`dump_plugin` にだけ `optional = p.optional` が戻っても raw-spec に増えたキーは `plugins.json` に伝播せず、上の assert は通ってしまう(実測: 旧 extract × 新 resolve のハイブリッドで raw-spec は `"optional": false` を持つのに `all(...; has("optional") | not)` はパスした)。`extractor-snapshot` の golden も検知しない(`basic-config` の plugin は `optional` 未指定 → `nil` → キーが落ちるため golden と一致したまま)。したがって **raw-spec 側にも 1 本置く**: extract 直後(`flake.nix:1155` 付近)に `jq -e 'all(.plugins[]; has("optional") | not)' "$sb/raw-spec.json" > /dev/null`。
  - **この raw-spec 側 assert は §3.3(c) / §4.4 に依存する。** `optional == false` が実値として encode されるのは混在 fragment のプラグインだけであり、`merge-config` に plenary を足さない限り全プラグインが `nil` になってキーが落ち、raw-spec 側 assert も素通りする。§4.4 は「推奨」ではなく **この assert を有効にするための必須の前提**として扱う。
- 却下: 全 `out*.json` に `has("optional")` を撒く。golden diff と重複するノイズになる。

**(c) 追加(必須): 「optional-only プラグインは lock されない」を test で固定する**

(b) の raw-spec 側ガードを有効にする前提でもあるため、推奨ではなく必須。

`optional` フィールドを消すと、「optional-only プラグインをどう扱うか」という判断が明示的にはどこにも残らなくなる。これを test に固定するのが §3.4 で代替案を却下する根拠の担保になる。`tests/fixtures/merge-config/init.lua` に 2 エントリ足す:

- `{ "folke/which-key.nvim", optional = true }` — optional-only。plugins.json に**現れてはならない**。
- `{ "nvim-lua/plenary.nvim", optional = true }` — telescope の非 optional な `dependencies` と混在する fragment。lazy 内部で `plugin.optional == false` になる経路(1.3)を実際に踏み、それでも lock されることを示す。

実測: この 2 行を足した spec で plugins.json のキーは `plenary.nvim` / `telescope.nvim` / `tokyonight.nvim` のまま、`which-key.nvim` は不在。既存 assert(`flake.nix:1157-1163`)は `telescope.nvim.dependencies == ["plenary.nvim"]`、`tokyonight.nvim.pin == true`、`telescope.nvim.version == "^0.1"`、`plenary.nvim.pin == null`、`plenary.nvim.dependencies == []` すべて成立を確認済み。

### 3.4 却下する代替案: `Spec.new(spec, { optional = true })`

issue 本文の代替案。`extract.lua:78` を `Plugin.Spec.new(spec, { pkg = false, optional = true })` にすると `meta.lua:290` の早期 return が効いて `fix_optional` が何も削除しなくなり、optional-only プラグインも `optional = true` を持って `s.plugins` に残る。フィールドは真に意味を持つようになる。

**採らない理由**:

1. **lock 対象の定義を壊す**。nvimx が lock するのは「lazy が実際に install するもの」であり、`docs/architecture.md:199` の superset 方針も「`enabled` が関数の場合や `cond` — つまり**機械依存の分岐**の上位集合を lock する」に限定されている。`optional` は機械依存ではなく「他の誰かが同じプラグインを非 optional で要求したときだけ有効になる」という spec 内部の条件である。ここを超集合化すると、lock が「lazy が絶対に install しないプラグイン」を含むことになり、farm には置かれるが runtime で一切読まれない死んだ derivation を生む。
2. **コストが無条件に増える**。`optional = true` は LazyVim 系の extras が多用するイディオムで、対象を全部 lock すると input 数・fetch 量・ビルド時間が跳ねる。得られるものは使われないプラグインである。
3. **こちらこそ破壊的変更**。`plugins.json` の意味(何が入っているか)が変わるので、`schemaVersion` の議論と移行の設計が必要になる。§3.2 で bump を避けられるのは、本件が純粋な削除で意味を変えないからである。
4. **drive-by で決めるべき判断ではない**。仮に需要が出たら、`programs.nvimx.lock.includeOptional` のような opt-in として別 issue で設計するのが筋。フィールドを温存することはその設計を一切助けない。

本計画では入口を塞がない: `extract.lua:78` の `Spec.new` 呼び出しは無変更のまま残すので、将来 opt-in を入れる際は `{ optional = true }` の追加と dump フィールドの復活を同時に行えばよい。

### 3.5 `docs/architecture.md` の更新箇所

| 行 | 作業 |
|---|---|
| `:188` | `"optional": null, // lazy's optional ...` の行を**削除** |
| `:199` | superset 方針の箇条書きに 1 文追加。「全 fragment が `optional = true` なプラグインは lazy 自身(`Meta:fix_optional`)が spec から落とすので、nvimx も lock しない」。これが `:188` の削除で失われる情報の**正しい**置き換えである(フィールドではなく挙動として記述する) |
| `:210` | merge contract の列挙 `pin`, `optional`, `dependencies` and `build` → `pin`, `dependencies` and `build` |

`docs/plans/18-resolve-merge-plugins-json.md`(`:44`, `:51`, `:85`, `:121`, `:150`, `:155`, `:170`, `:180`, `:216`, `:271-272`)、`docs/plans/24-lock-update.md:31`、`docs/plans/25-import-lazy-lock.md:202` にも `optional` を含むスキーマ記述が残るが、計画書は決定当時の記録なので**更新しない**(§6 参照)。スキーマの唯一の出典は `docs/architecture.md` である。

## 4. 実装手順

### 4.1 `lua/nvimx/resolve.lua`

- `:179-180` — コメントを `-- pin / dependencies / build are deliberately excluded: they are metadata that never` に修正(`optional /` を削る)。
- `:301` — `      optional = p.optional or vim.NIL,` の 1 行を削除。

### 4.2 `lua/nvimx/extract.lua`

- `:56` — `    optional = p.optional,` の 1 行を削除(§3.1)。

この 2 ファイルが変更の本体で、他の lua ファイルは無変更。

### 4.3 fixture の再生成

すべてオフラインで完結する。まず seed を取る(リポジトリルートで):

```bash
seed=$(nix eval --impure --raw --expr '(builtins.getFlake (toString ./.)).inputs.lazy-nvim.outPath')
```

**(a) `tests/fixtures/{basic-config,build-plugins,registry-plugins,treesitter-config}/nvimx-lock/plugins.json`(4 ファイル)**

```bash
for fx in basic-config build-plugins registry-plugins treesitter-config; do
  sb=$(mktemp -d)
  mkdir -p "$sb"/config "$sb"/data/nvim/lazy "$sb"/state "$sb"/cache
  ln -sfn "$PWD/tests/fixtures/$fx" "$sb/config/nvim"
  ln -sfn "$seed" "$sb/data/nvim/lazy/lazy.nvim"
  env HOME="$sb" \
      XDG_CONFIG_HOME="$sb/config" XDG_DATA_HOME="$sb/data" \
      XDG_STATE_HOME="$sb/state" XDG_CACHE_HOME="$sb/cache" \
      NVIMX_LAZY_SEED="$seed" NVIMX_OUT="$sb/raw-spec.json" \
      nvim --headless --cmd "luafile lua/nvimx/extract.lua"
  nvim -l lua/nvimx/resolve.lua "$sb/raw-spec.json" "tests/fixtures/$fx/nvimx-lock/plugins.json"
  rm -rf "$sb"
done
```

- `--prev` / `--lock` は**渡さない**。この 4 つは `pin` も `resolvedRef` も持たず `warnings` も空(例: `tests/fixtures/basic-config/nvimx-lock/plugins.json:21-23`)なので、from-scratch 生成がそのまま定常状態である。
- 検証済み: このコマンド列を**変更前の main で**走らせると 4 ファイルすべてを byte-identical に再生産する。したがって変更後の差分は `optional` 起因のみであることが保証される。
- 検証済み: 変更後の出力は各ファイルから `"optional": null,` の 1 行だけを削ったものと byte-identical(キーはソート出力で `optional` の直後に `pin` が来るため、行削除で JSON のカンマが壊れることもない)。レビュー時は `git diff` が 4 ファイル × 1 行削除だけであることを確認すればよい。
- `nvimx-lock/flake.nix` と `nvimx-lock/flake.lock` は**無変更**(`genflake.lua` は `optional` を読まない)。

**(b) 手書き raw-spec から `optional` を落とす**

| ファイル | 作業 |
|---|---|
| `tests/fixtures/merge/raw-spec-base.json:23` | `"optional": true,` の行を削除(`telescope.nvim`) |
| `tests/fixtures/merge/raw-spec-added.json:22` | 同上 |
| `tests/fixtures/merge/raw-spec-branch-changed.json:35` | `custom.nvim` の `"optional": true` を削除し、代わりに `"dependencies": ["plenary.nvim"]` を追加(§3.3(a))。`:2-7` の `_comment` の「the metadata-only fields of the equally pinned custom.nvim (optional) and of telescope.nvim (dependencies)」を、編集対象が両方 `dependencies` であると読める文に修正 |
| `tests/fixtures/merge/prev-v1.json:3` | `_comment` の「without the pin / optional / dependencies fields」→「without the pin / dependencies fields」。**JSON 本体は無変更**(このファイルは元々 `optional` キーを持たない。旧形式 prev を表すのが役目) |

**(c) `tests/fixtures/merge/golden/base.plugins.json` の再生成**

(b) の変更を確実に反映するため、手編集ではなく再生成する。`flake.nix:997-1007` の手順と同一の 2 パス:

```bash
fx=tests/fixtures/merge
tmp=$(mktemp -d)
nvim -l lua/nvimx/resolve.lua "$fx/raw-spec-base.json" "$tmp/pass1.json" --lock "$fx/flake.lock"
nvim -l lua/nvimx/resolve.lua "$fx/raw-spec-base.json" "$fx/golden/base.plugins.json" \
  --prev "$tmp/pass1.json" --lock "$fx/flake.lock"
rm -rf "$tmp"
```

- 検証済み: この 2 パスを変更前の main で走らせると現 golden を byte-identical に再生産する。
- 期待差分は 4 行の削除のみ: `:21` / `:39` / `:80` の `"optional": null,` と `:61` の `"optional": true,`。

### 4.4 `tests/fixtures/merge-config/init.lua`(§3.3(c)) — **必須**

§3.3(b) の raw-spec 側回帰ガードは、`optional == false` を実値として持つプラグインが 1 つ以上ないと素通りする。この追加はその前提であり、省略できない。


`require("lazy").setup({ ... })` の spec に 2 エントリ追加(`:12-22` のリスト末尾):

```lua
  -- optional-only: lazy's Meta:fix_optional drops it, so nvimx must not lock it either
  {
    "folke/which-key.nvim",
    optional = true,
  },
  -- an optional fragment alongside telescope's non-optional dependency on the same plugin:
  -- lazy keeps the plugin (plugin.optional ends up false, never true), so it must be locked
  {
    "nvim-lua/plenary.nvim",
    optional = true,
  },
```

冒頭コメント(`:1-4`)の「`pin`, `dependencies` and `version`」は据え置きだが、optional の扱いも見ているという 1 文を足す。

### 4.5 `flake.nix`(`checks.resolve-merge`、`:981-1165`)

| 行 | 作業 |
|---|---|
| `:1054-1055` | コメントの `(optional / dependencies)` → `(dependencies)`。編集対象が `custom.nvim` の `dependencies` であると読める文言にする |
| `:1062` | 削除し、`jq -e '.plugins["custom.nvim"].dependencies == ["plenary.nvim"]' out5.json > /dev/null` に置き換え(§3.3(a)) |
| `:1004` | コメント「the new schema fields plus both frozen revs」の「new」は #18 由来の表現。`pin` / `dependencies` の 2 つになった旨に軽く修正 |
| `:1142-1143` | コメント「the three fields」→ フィールド数を書かない表現(`pin` / `dependencies` / `version`)に修正 |
| `:1160` | コメント「...and stay absent when the spec does not set them」に、`optional` はキー自体が存在しないという 1 行を追加 |
| `:1155` 付近(extract 直後、resolve を呼ぶ前) | **raw-spec 側の回帰ガードを新規追加**: `jq -e 'all(.plugins[]; has("optional") | not)' "$sb/raw-spec.json" > /dev/null`。`extract.lua` 単独の復活を検知できる唯一の assert(§3.3(b))。有効化には §4.4 の plenary 追加が必須 |
| `:1162` | `jq -e '.plugins["plenary.nvim"].optional == null' extracted.json` を削除し、回帰ガード `jq -e 'all(.plugins[]; has("optional") | not)' extracted.json > /dev/null` に置き換え(§3.3(b))。こちらは `resolve.lua` 側の復活を検知する |
| `:1163` の直後 | §4.4 に対応する assert 2 本を追加:<br>`jq -e '.plugins \| has("which-key.nvim") \| not' extracted.json > /dev/null`(optional-only は lock されない)<br>`jq -e '.plugins \| has("plenary.nvim")' extracted.json > /dev/null`(混在 fragment は lock される) |

他の checks(`:833` `extractor-snapshot`、`:898` `resolve-build-warnings`)は無変更。

### 4.6 `docs/architecture.md`

§3.5 の 3 箇所(`:188` 削除、`:199` に 1 文追加、`:210` の列挙修正)。

### 4.7 触らないもの

- `.github/workflows/*` — `nix flake check` の中身が変わるだけなので編集不要。仮に CI ステップの追加が必要になった場合も、CLAUDE.md の規約により編集は `.github/workflows/check.yml` のみ(`ci-linux.yml` / `ci-darwin.yml` は触らない)。
- `CLAUDE.md`
- `docs/plans/` の既存ファイル(§3.5、§6)
- `nix/` 配下すべて、`lua/nvimx/genflake.lua`、`lua/nvimx/json.lua`
- `tests/fixtures/golden/basic-config.raw-spec.json` — `optional` キーが元々無いので更新不要(§5)
- `tests/fixtures/*/nvimx-lock/flake.nix` / `flake.lock`

## 5. テスト

### 5.1 既存 `checks` への影響

| check(`flake.nix`) | 影響 |
|---|---|
| `resolve-merge`(`:981`) | 直接編集(§4.5)。golden diff(`:1007`)が手書き raw-spec 経路の byte 単位ガード、`:1162` の差し替えが `resolve.lua` 側、`:1155` 付近の新規 assert が `extract.lua` 側の回帰ガード |
| `extractor-snapshot`(`:833`) | `extract.lua` を変えるが、golden `tests/fixtures/golden/basic-config.raw-spec.json` に `optional` キーが存在しないため**差分ゼロ**。実測: 削除後の `extract.lua` で `basic-config` を extract → `jq -S 'del(.lazyNvim)'` の結果が現 golden と一致。**golden の更新は不要** |
| `resolve-build-warnings`(`:898`) | `resolve.lua` を叩くが assert は build warning のみ。無変更で通る |
| fixture の plugins.json を lockDir として読む check 群: `hm-module`(`:155`)、`hm-module-degrade`(`:164`)、`hm-module-plugins`(`:172`)、`hm-module-treesitter`(`:186`)、`build-shell`(`:211` / `:461`)、`build-registry`(`:525`)、`plugins-overrides` / `plugins-nixpkgs-fallback` / `plugins-escape-hatch`(`:387` 他)、`treesitter-grammars`(`:695` / `:750`) | `make-env.nix` / `resolve-plugin.nix` が `optional` を読まない(1.2)ため挙動不変。フル `nix flake check` で確認 |
| `extractor-no-setup`、`plugin-drv-phases`、`build-network-detect`、`wrapper-aliases` | 無関係 |

### 5.2 追加 / 変更する assert

| assert | 何を守るか |
|---|---|
| `.plugins["custom.nvim"].dependencies == ["plenary.nvim"]`(`:1062` の置き換え) | pinned プラグインに対する「ref に影響しないメタデータ編集は凍結を解かない」。削除した `optional` assert のカバレッジ移送 |
| `all(.plugins[]; has("optional") \| not)` on `extracted.json`(`:1162` の置き換え) | `resolve.lua` のエントリ構築への再導入を検知する。`extract.lua` 単独の復活は**検知しない**(明示列挙なので raw-spec のキーは伝播しない) |
| `all(.plugins[]; has("optional") \| not)` on `raw-spec.json`(`:1155` 付近、新規) | `extract.lua` の `dump_plugin` への再導入を検知する。§4.4 の混在 fragment が無いと素通りする点に注意 |
| `.plugins \| has("which-key.nvim") \| not` | optional-only プラグインは lock しない(= §3.4 の代替案を採らないという判断の固定) |
| `.plugins \| has("plenary.nvim")` | 混在 fragment(lazy 内部で `optional == false`)のプラグインは lock する |
| `diff -u $fx/golden/base.plugins.json out1.json`(`:1007`、既存) | 再生成した golden がそのまま byte 単位の回帰ガードになる |

### 5.3 検証コマンド

```bash
# 1. 削除の完了
grep -n 'optional' lua/nvimx/*.lua                                  # 空であること
grep -rn '"optional"' tests/ docs/architecture.md README.md          # 空であること

# 2. フルチェック(linux)
nix flake check
nix fmt -- --ci

# 3. darwin 評価(CLAUDE.md の規約。ローカル linux の flake check は darwin を omit する)
nix eval .#checks.aarch64-darwin.resolve-merge.drvPath
nix eval .#checks.aarch64-darwin.extractor-snapshot.drvPath

# 4. 互換性(§3.2)。旧ファイルを prev にしても pin が生き残ることの手元確認
tmp=$(mktemp -d); fx=tests/fixtures/merge
git show HEAD:tests/fixtures/merge/golden/base.plugins.json > "$tmp/old-prev.json"
nvim -l lua/nvimx/resolve.lua "$fx/raw-spec-base.json" "$tmp/new.json" \
  --prev "$tmp/old-prev.json" --lock "$fx/flake.lock"
jq -e '.plugins["tokyonight.nvim"].resolvedRef == "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"' "$tmp/new.json"
jq -e '.plugins["custom.nvim"].resolvedRef == "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"' "$tmp/new.json"
# 不動点であること
nvim -l lua/nvimx/resolve.lua "$fx/raw-spec-base.json" "$tmp/new2.json" \
  --prev "$tmp/new.json" --lock "$fx/flake.lock"
cmp "$tmp/new.json" "$tmp/new2.json"
```

`nix fmt` について: `flake.nix:118-126` の treefmt はいま `nixfmt` のみを有効にしている。JSON / Lua はフォーマッタの対象外なので、fixture の手編集がフォーマットで揺れることはない。stylua / luacheck は #31 で入るが本件はその**前**に入るので追加対応は不要。

### 5.4 手動確認(ネットワークが必要なため `checks` にできない部分)

- 実 lockDir を持つ環境で `nix run .#lock -- --config <configDir> --out <lockDir>` を 2 回実行:
  1 回目で `plugins.json` から `optional` 行が消えるだけの差分が出て、`flake.nix` / `flake.lock` は**無変更**であること。2 回目で `plugins.json` も無変更であること(冪等性 = ゴール 6 の end-to-end 版)。
- 差分に rev の移動が 1 件も含まれないこと(`git diff -- <lockDir>/flake.lock` が空)。

## 6. リスク / 未決事項

- **ユーザの committed `plugins.json` に差分が出る**。プラグイン 1 個につき 1 行の削除。`genflake` の入力に `optional` は含まれないので `flake.nix` / `flake.lock` は不変で、再 fetch も再ビルドも起きない。PR 本文にこの性質(「lock の内容は動かない、行が消えるだけ」)を明記する。
- **旧 nvimx へのロールバック**。新形式を旧 `resolve.lua` が prev として読んでも pin は保持される(§3.2 方向 A、実測済み)。旧 nvimx で lock し直せば `optional` 行が復活するだけで、rev は動かない。
- **`p.optional == false` 経路が lazy 側の実装詳細に依存する**。`meta.lua:246-248` の nil 化条件が変わり、将来 `optional = true` が `s.plugins` に到達するようになった場合、本件は「フィールドが無いので静かに取り落とす」形になる。ただしその変化は lazy 自身の install 対象の変化を伴うため、§4.4 で入れる「optional-only は lock されない / 混在 fragment は lock される」の 2 本の assert が seed 更新時に検知する。これが §3.3(c) の追加を必須とする主たる理由である。
- **`docs/plans/` に古いスキーマ記述が残る**(`18-resolve-merge-plugins-json.md` の `:44` / `:51` / `:85` / `:121` / `:150` / `:155` / `:170` / `:180` / `:216` / `:271-272`、`24-lock-update.md:31`、`25-import-lazy-lock.md:202`)。計画書は決定当時の記録なので更新しない方針。混乱が実際に起きるようなら「スキーマの唯一の出典は `docs/architecture.md`」を `docs/plans/` の入口に書くのが筋で、本件の範囲外。
- **#42 との衝突**。#42(`defaults.version` が extract で失われる)は `extract.lua` の `dump_plugin` と本件と同じ fixture 群(`tests/fixtures/*/nvimx-lock/plugins.json`、`merge/*`、golden)を触る見込み。本件を先に main へ入れ、#42 は削除後のスキーマと §4.3 の再生成手順を前提にする。
- **未決: optional-only プラグインを lock する opt-in を将来入れるか**(§3.4)。入れるなら `programs.nvimx.lock.includeOptional` 相当として別 issue で設計する。本計画は入口を塞がない(`extract.lua:78` の `Spec.new(spec, { pkg = false })` は無変更で残す)。
- **`raw-spec-branch-changed.json` のメタデータ編集ケースが `dependencies` 1 本に依存するようになる**。将来 `dependencies` も spec 恒等性に入れる判断をした場合(現状その予定はない。`resolve.lua:179-180` が明示的に除外している)、このテストケースは別のメタデータフィールドに移す必要がある。
