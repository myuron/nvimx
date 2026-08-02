# #42 対応計画: `defaults.version` を extract 時にプラグインへ実体化する

対象 issue: [#42 fix(extract): defaults.version is lost, so a config-wide version constraint silently tracks HEAD](https://github.com/myuron/nvimx/issues/42)

Blocks #23。着手順は **#43 → #42(本件) → #31 → #36 → #23 …** で、本件は #43(`plugins.json` から常に null の `optional` を削除)がマージされた直後に着手する。

本計画は `plugins.json` の**スキーマを変更しない**ため、#43 との衝突面は `lua/nvimx/extract.lua` の `dump_plugin` テーブルリテラル 1 箇所だけである。#43 の計画は `docs/plans/43-drop-optional-field.md` にあり、実装は PR #44 (`ded6c6b`) として完了している。実際の差分を突き合わせて確認した結果、**衝突は起きない**:

- #43 が `extract.lua` から消すのは `optional = p.optional` の 1 行だけで、`version = p.version` は同じ位置に残る
- #43 が追加する raw-spec 側の回帰ガード(`all(.plugins[]; has("optional") | not)`)、`merge-config` fixture への optional プラグイン 2 件追加、`docs/architecture.md` の 3 箇所の変更は、いずれも `version` の扱いと直交する

以下、lazy.nvim 側の行番号は **pin された seed**(`flake.lock` の `lazy-nvim`、rev `306a055`、store path `/nix/store/d9jq3s81p4i9q6g8gaa6f2pn51p8za9l-source`)の実ソースを読んで確認したものである。

**nvimx 側の行番号は #43 未適用の main 基準なので、着手時点(= #43 マージ後)には既にずれている。** #43 は `flake.nix` を +28/-8 行、`resolve.lua` を -2 行、`docs/architecture.md` を -1 行動かす。したがって §5.2 / §5.4 / §5.5 の位置指定は行番号ではなく**シンボルを主キーとして読むこと**: check 名(`extractor-snapshot` / `resolve-merge`)、`identity_fields`、スキーマコメントの文言、`dump_plugin` / `version = p.version`。

## 1. 背景 / 現状

### 1.1 lazy.nvim 側の事実

- `defaults` は **opts** のキーであり、既定値は `lazy` / `version` / `cond` の 3 つだけ(lazy: `lua/lazy/core/config.lua:9-20`)。`version` の既定は `nil`(同 `:15`)で、`M.defaults` のテーブルに **キーとして存在しない**(Lua で `version = nil` を書いてもキーは生えない)。
- `Config.setup` は `M.options = vim.tbl_deep_extend("force", M.defaults, opts or {})`(lazy: `lua/lazy/core/config.lua:278`)で 1 回だけ合成する。したがってユーザーが `defaults = { version = "*" }` を渡した場合のみ `Config.options.defaults.version` が生える。実測(seed に対して `Config.setup` を直接叩いて確認):

  | 渡した opts | `Config.options.defaults.version` | `Config.options.defaults` のキー |
  |---|---|---|
  | `{}` | `nil` | `lazy` |
  | `{ defaults = { version = "*" } }` | `"*"` (string) | `version`, `lazy` |
  | `{ defaults = { version = false } }` | `false` (boolean) | `version`, `lazy` |

- **`defaults.version` はプラグインオブジェクトに書かれない。** 適用されるのは git 操作時の `M.get_target` の中だけ(lazy: `lua/lazy/manage/git.lua:141`):

  ```lua
  -- lua/lazy/manage/git.lua:118-153 (抜粋)
  function M.get_target(plugin)
    if plugin._.is_local then ... return { branch = branch, commit = ... } end   -- :119-123
    local branch = assert(M.get_branch(plugin))                                   -- :125
    if plugin.commit then return { branch = branch, commit = plugin.commit } end   -- :127-132
    if plugin.tag then return { branch = branch, tag = plugin.tag, ... } end       -- :133-139
    local version = (plugin.version == nil and plugin.branch == nil) and Config.options.defaults.version or plugin.version  -- :141
    if version then                                                               -- :142
      local last = Semver.last(M.get_versions(plugin.dir, version))
      if last then return { branch = branch, version = last, tag = last.tag, ... } end
    end
    return { branch = branch, commit = M.get_commit(plugin.dir, branch, true) }    -- :153 ← HEAD
  end
  ```

  重要な点が 3 つある:
  1. `:141` の条件は `version` と `branch` しか見ないが、**`commit` / `tag` は `:127` / `:133` の早期 return で既に処理済み**である。つまり「`defaults.version` が実際に効く条件」は `:141` 単独ではなく `commit == nil ∧ tag == nil ∧ version == nil ∧ branch == nil` である(§3.2)。
  2. `:119-123` により **dev(local)プラグインは `get_target` の先頭で抜ける**ので `defaults.version` の対象外。
  3. `:142-152` は「制約を満たすタグが 1 つも無ければ黙って `:153` の HEAD に落ちる」。lazy 自身のテンプレートコメント `-- version = "*", -- try installing the latest stable version for plugins that support semver`(lazy: `lua/lazy/core/config.lua:16`。"try" と "for plugins that support semver")もこの挙動を前提にした文言である。→ #23 に対する重大な帰結があるので §4.2 で扱う。

### 1.2 nvimx 側の欠落

- `lua/nvimx/extract.lua:54` は `version = p.version` を dump するだけで、`Config.options.defaults.version`(`extract.lua:75` の `Config.setup` 後に読める)を一切参照しない。
- 実測: seed の store path を rtp に置き、`defaults = { version = "*" }` の spec を現行 `extract.lua` に通した結果(raw-spec の各エントリの**存在するキー**を列挙):

  | spec | 現行 raw-spec の `version` | lazy が実際にやること |
  |---|---|---|
  | `{ "folke/tokyonight.nvim" }` | キー無し(= nil) | `*` で最新安定タグを試す |
  | `{ "nvim-lua/plenary.nvim" }`(telescope の依存として展開) | キー無し | `*` で最新安定タグを試す |
  | `{ "nvim-telescope/telescope.nvim", version = "^0.1" }` | `"^0.1"` | `^0.1` |
  | `{ "folke/trouble.nvim", branch = "dev" }` | キー無し(`branch = "dev"` あり) | branch HEAD |
  | `{ "folke/which-key.nvim", tag = "v3.0.0" }` | キー無し(`tag` あり) | tag |
  | `{ "folke/flash.nvim", commit = "…" }` | キー無し(`commit` あり) | commit |
  | `{ "folke/noice.nvim", version = false }` | `false`(**キーは存在する**) | HEAD(タグを使わない) |

  つまり 1 行目・2 行目が本件の被害者で、raw-spec も `plugins.json` も `version: null` になる。
- `lua/nvimx/resolve.lua:299` は `version = p.version or vim.NIL` なので、`false` は `null` に落ちる(意味的には正しい。§3.3)。`resolve.lua:339-351` の warning も `p.version` が nil のため出ない ⇒ **ユーザーには何の兆候も出ないまま全プラグインが HEAD 追従**になる。`docs/architecture.md:220` の表(`version = "^1.2"` → `refs/tags/vX.Y.Z`)が config 全体指定では成立していない。
- このギャップは `docs/plans/23-resolve-semver.md:187` で既にリスクとして記録されている(「別 issue に切り出す」)。本件がその issue である。

## 2. ゴール

issue の "Done when" を検証可能な形に落とす:

1. **実体化**: `defaults = { version = "*" }` だけを書いた config を extract → resolve すると、対象条件(§3.2)を満たす全プラグインの `plugins.json` の `version` が `"*"` になる。**依存として展開されたプラグイン**(spec に直接書かれていないもの)も含む。
2. **自前指定の不変**: 自前の `version` / `branch` / `tag` / `commit` を持つプラグインは `version` フィールドが 1 バイトも変わらない(自前 `version` はそのまま、`branch`/`tag`/`commit` 持ちは `null` のまま)。
3. **三値の区別**: `defaults.version` が `nil` の場合と `false` の場合はともに「制約なし」(`plugins.json` は `null`)、`"*"` 等の文字列の場合のみ制約が入る。プラグイン個別の `version = false` は config 全体の `defaults.version` を**上書きして無効化**する(`plugins.json` は `null`)。
4. **`defaults` の全キー監査が済んでいる**: 同種の取りこぼしが他に無いことを根拠付きで結論できる(§3.4 の表)。
5. **check で担保**: 1〜3 が `nix flake check` の 1 チェックで検証される。既存 golden(`tests/fixtures/golden/basic-config.raw-spec.json`)は**無変更**であること(= 既存挙動への回帰が無いことの裏返し)。
6. **スキーマ不変**: `plugins.json` の `schemaVersion` は 1 のまま、フィールド追加なし。既存ユーザーの committed な `plugins.json` は再生成なしで読める(`defaults.version` を使っていた人は §4.1 の通り 1 回だけ ref が再決定される)。

## 3. 設計

### 3.1 適用時点: なぜ resolve.lua ではなく extract 時か

**採用**: `extract.lua` の `capture()` 内、`Config.setup(...)`(`extract.lua:75`)の直後に `Config.options.defaults.version` を読み、`dump_plugin` が各プラグインの `version` を決める時にそれを適用する。raw-spec.json の時点で既に「プラグインごとに 1 つの具体的な制約」になっている。

理由(重い順):

1. **lazy の意味論を lazy が動いている場所に閉じ込める。** `defaults.version` の適用規則は `commit` / `tag` の早期 return を含む `get_target` 全体の構造(§1.1)であり、これを resolve.lua に持たせると nvimx 側で lazy の優先順を再実装することになる。`extract.lua` は「lazy 自身にやらせる」層(`docs/architecture.md` 設計原則 2)で、`Config` モジュールが load 済みの唯一の場所である。resolve.lua は素の `nvim -l` で走り `json.lua` しか `dofile` しない(`resolve.lua:59`)ので、`Config.options` を読む手段がそもそも無い(raw-spec に `defaults` を echo して渡す設計にすれば読めるが、それは 1 に反する)。
2. **マージ契約(#18)がそのまま効く。** `resolve.lua:181` の `identity_fields = { "branch", "tag", "commit", "version" }` は**プラグイン単位**の恒等性である。制約が per-plugin の `version` として入るなら、`defaults.version` の追加・変更・削除は「対象プラグインの `version` が変わった」として自動的に検出され、`resolvedRef` が `null` に戻って再解決される(`resolve.lua:309-323`)。もし config 全体の `defaults` ブロックとして持たせると、「グローバル値が変わったら全プラグインの恒等性を無効化する」という横断ルールを `same_identity()` の外に足す必要があり、#18 のマージ契約(`docs/architecture.md:210`)を壊す。
3. **`plugins.json` は commit されてレビューされる成果物である。** 読み手が「グローバル設定を頭の中で適用し直す」必要がある lock は lock として弱い。issue 本文の "keeps recording one concrete constraint per plugin" もこの立場。
4. **テスト可能性**: resolve.lua が「raw-spec.json → plugins.json の純粋関数」であるという性質は `checks.resolve-merge` が手書き raw-spec で全契約を検証できている根拠(`flake.nix:981-1165`)。resolve に暗黙のグローバル状態を持ち込むと、手書き raw-spec の意味が「lazy の opts 次第」に変わる。
5. **`--update`(#24)/警告の粒度がプラグイン名である。** `resolve.lua:243-245` の `warn_plugin` も #24 の `--update <name>` もプラグイン単位。制約もプラグイン単位で持つのが素直。

### 3.2 適用規則: lazy の「実効規則」を再現する

```
effective_version(p, dv) =
  p.version ~= nil                                   → p.version   -- 自前指定(false を含む)が最優先
  dv == nil                                          → nil         -- config 全体指定なし
  p.branch ~= nil or p.tag ~= nil or p.commit ~= nil → nil         -- lazy では default に到達しない
  otherwise                                          → dv
```

- **`p.version ~= nil` は falsy 判定ではなく nil 判定にすること。** `version = false` を書いたプラグインは lazy でも `:141` の条件を外れて `version = false` になり `:142` を通らない(= HEAD)。falsy 判定(`if not p.version`)にすると `false` が `"*"` に化けて、ユーザーの明示的なオプトアウトを踏み潰す。実測で raw-spec は `"version": false` を**キーごと保持**しているので、この区別は extract の時点で機能する。
- **`tag` / `commit` も除外する(issue 本文の一文からの意図的な逸脱)。** issue は "use it only when the plugin sets neither `version` nor `branch`" と書いており、これは `git.lua:141` の逐語訳である。しかし §1.1 の通り `:141` に到達する時点で `commit`(`:127`)と `tag`(`:133`)は既に return 済みなので、**逐語訳は lazy の実効挙動より広い**。
  - 選択肢 A(逐語): `version == nil and branch == nil` のみ。`tag = "v3.0.0"` のプラグインに `version = "*"` が入る。
  - 選択肢 B(実効、**採用**): `tag` / `commit` も除外。
  - B を採る理由: ref の決定結果は A でも B でも同じになる(genflake の優先順は `commit` > `resolvedRef` > `tag` > `branch`、#23 の解決ゲートも `commit`/`tag` があれば解決しない、`docs/plans/23-resolve-semver.md:56-63`)。差が出るのは **`plugins.json` に載る文字列と warning** だけである。A では (i) 効きようのない制約が commit された lock に残り、(ii) `resolve.lua:339-351` が `version constraint "*" is not resolved yet` をユーザーが書いてもいない制約について警告し、(iii) `pin` 併用時は `pinned; version constraint "*" is not validated` まで出る。lock は「lazy が実際にやること」を記録するものなので B が正しい。
  - 逸脱である旨は `extract.lua` のコメントに `git.lua:127-141` の構造ごと書き残す(将来 seed が更新されて `:141` の条件式だけを読んだ人が A に戻さないように)。
- **dev / local プラグインは自然に対象外。** `git.lua:119-123` で `get_target` の先頭から抜けるため lazy でも `defaults.version` は効かない。nvimx 側では、たとえ raw-spec に `version` が載っても `resolve.lua:257-259` が `p.dev or p.dir` を `local_plugins`(= `{ dir = ... }` のみ)に振り分けるので `plugins.json` には出ない。**追加のガードは書かない**(`p.dev` を `effective_version` に持ち込むと `extract.lua` 側に resolve の振り分け規則が漏れる)。この結論は §6 の check で assert しない(既存の `local-plugin` fixture に `defaults` を足す価値が低い)が、コメントで根拠を残す。
- **実装位置**: `dump_plugin(p)` に第 2 引数 `default_version` を足し、規則は `effective_version(p, default_version)` として `dump_plugin` の上に切り出す(純粋関数)。`capture()` 側は upvalue ではなく引数で渡す(`dump_plugin` が `capture` の外にある現構造を維持し、テスト時に単体で呼べる形を保つ)。

### 3.3 `nil` / `false` / 文字列 の三値

`Config.options.defaults.version` の読み出しは 1 箇所で正規化する:

```lua
-- git.lua:141 は `(cond) and Config.options.defaults.version or plugin.version` なので、
-- defaults.version == false は「config 全体指定なし」と完全に同義(false or nil → nil)。
-- lazy のテンプレートが version = false を勧めている(config.lua:13-15)ので実際に来る値である。
local default_version = Config.options.defaults.version or nil
```

真理値表(`git.lua:141` を実際に評価して確認済み):

| `p.version` | `p.branch` | `defaults.version` | lazy が使う version | タグを使うか |
|---|---|---|---|---|
| nil | nil | `"*"` | `"*"` | する |
| nil | nil | `false` | `nil` | しない(HEAD) |
| nil | nil | nil | `nil` | しない(HEAD) |
| `false` | nil | `"*"` | `false` | しない(HEAD) |
| nil | `"dev"` | `"*"` | `nil` | しない(branch HEAD) |
| `"^1"` | nil | `"*"` | `"^1"` | する(`^1`) |

- `defaults.version = ""` は Lua で truthy なのでそのまま入る。lazy の `Semver.range("")` は `*` 相当(`docs/plans/23-resolve-semver.md:17`)なので特別扱いしない。
- `plugins.json` 側では `false` を記録しない(`resolve.lua:299` の `p.version or vim.NIL` が既に `null` にする)。`false` と「未指定」を lock で区別する消費者は存在しない(lazy でも両者は同じ HEAD)。**`resolve.lua` は無変更**。

### 3.4 `Config.options.defaults` 全キーの監査

`defaults` の全キーは `lazy/core/config.lua:9-20` の 3 つで確定(`Config.setup` は `M.defaults` と opts を deep extend するだけなので、ユーザーが未知のキーを足しても lazy 自身が読む場所は無い)。seed 全体を `options.defaults` で grep した結果、参照箇所は下表の 3 箇所のみ。

| キー | 既定値 | lazy が適用する場所 | プラグインオブジェクトに書かれるか | lock に影響するか | nvimx の状態 |
|---|---|---|---|---|---|
| `lazy` | `false` | `lua/lazy/core/plugin.lua:234-243`(`M.update_state()`、`plugin.lazy` を埋める) | 書かれる(が **runtime の遅延ロード判定専用**) | **しない** | 問題なし。`extract.lua` は `Spec.new` しか呼ばず `update_state()` を通らないので、そもそも適用すらされない。`dump_plugin` は `lazy` を dump していないので取りこぼしにもならない |
| `version` | `nil` | `lua/lazy/manage/git.lua:141`(**git 操作時**) | **書かれない** | **する**(ref を決める) | **本件のバグ** |
| `cond` | `nil` | `lua/lazy/core/meta.lua:265-285`(`M:fix_cond()`。`Spec.new` → `Spec:parse` → `meta:resolve()` → `:352` から呼ばれる) | プラグインに `plugin._.cond = false` / `plugin.enabled = false` として反映され、`disabled` 集合に効く | する(が正しく効いている) | 問題なし。`extract.lua:59` の `hasCond` は `p.cond` の有無を見るだけだが、`defaults.cond` が効いた結果は `enabled = false` 経由で `s.disabled` に出るため取りこぼしはない(`docs/architecture.md:198`「関数 / `cond` を持つものは**含める**」= superset 方針とも整合) |

**結論: `defaults` に同種の取りこぼしは残らない。** 判定基準は「lazy がそのキーを *git 操作時* に読むか、*Spec 正規化時* に読むか」で、後者(`cond`)は `Spec.new` の中で既にプラグインへ焼き込まれ、前者(`version`)だけが `extract.lua` の視界から漏れる。`lazy` は git 操作にも Spec 正規化にも関係しない runtime 専用値である。

**隣接するグローバル opts の確認(参考)** — `defaults` 以外にも「グローバル opts がプラグインの lock 対象フィールドを決める」経路があるが、いずれも Spec 正規化時にプラグインへ焼き込まれるため既に取りこぼしはない:

- `Config.options.git.url_format`(既定 `https://github.com/%s.git`): `lua/lazy/core/fragments.lua:116` が `fragment.url` を埋める ⇒ `p.url` に反映済み(`extract.lua:48` が dump)。GitHub 以外を既定にしているユーザーでも `parse_source`(`resolve.lua:167-174`)が git type として拾う。
- `Config.options.dev.{patterns,path,fallback}`: `lua/lazy/core/meta.lua:214-236` が `plugin.dev` / `plugin.dir` を埋める ⇒ `extract.lua:49-50` が dump 済み。
- `Config.options.root`: `meta.lua:236` で `plugin.dir` の既定になるが、`dump_plugin` は `p.dev` が真のときだけ `dir` を出す(`extract.lua:49`)ので `root` は lock に漏れない(意図通り。nvimx では farm がその役割)。

### 3.5 `safe_opts` との合成

`extract.lua:75` は `Config.setup(vim.tbl_deep_extend("force", {}, opts, safe_opts))`。`safe_opts`(`extract.lua:30-37`)のキーは `install` / `checker` / `change_detection` / `pkg` / `rocks` / `readme` の 6 つで **`defaults` を含まない**ため、`opts.defaults` は素通しされる。`vim.tbl_deep_extend` は同名キーがある場合のみ再帰するので、`defaults` サブツリー全体がユーザーの値のまま `Config.setup` に渡り、そこで `M.defaults` と再度 deep extend される(`lazy/core/config.lua:278`)。実測(§1.1 の表)もこの合成後の値を読んで取っている。

したがって `safe_opts` への追加変更は不要。ただし将来 `safe_opts` に `defaults` を足すと本件の入力を殺すことになるので、`safe_opts` のコメントに「`defaults` はユーザーの意図を保持しなければならない」旨を 1 行足す。

### 3.6 「これは `defaults` 由来である」という情報を残すか

**判断: `plugins.json` には残さない。raw-spec.json にも今回は残さない。** ただし #23 が必要とするなら raw-spec 側にだけ足す(§4.2 の申し送り)。

- `plugins.json` に残さない理由:
  - issue 本文の "keeps recording one concrete constraint per plugin instead of teaching resolve.lua about a spec-wide default" が明示的にこの方向。
  - 消費者が居ない純粋な provenance フィールドは、commit されレビューされるファイルの純ノイズである。#43 が `optional` を消しているのと同じ理由で足すべきでない。
  - スキーマ追加は全ユーザーの `plugins.json` に churn を生む(#43 の再生成と併せて 2 回になる)。
  - `resolve.lua` のマージ契約(`identity_fields`、`resolve.lua:181-200`)は provenance を無視しなければならない(provenance は `version` と `defaults` から一意に決まる従属値なので、恒等性に入れると意味が二重になる)。「入れてはいけないフィールド」を増やすのは負債。
- `--update`(#24)への影響: なし。`--update` の粒度はプラグイン名で(`docs/plans/24-lock-update.md` §3.2)、prev を無いものとして扱うだけなので provenance を必要としない。
- 警告メッセージへの影響: 唯一の実害は `resolve.lua:340-346` の `plugin "foo": pinned; version constraint "*" is not validated (pin wins)` が、`defaults.version` + `pin = true` の組み合わせで「ユーザーが書いていない制約について」出ることである。これは**受容する**: (a) 記述内容は真である(グローバル制約はその pin されたプラグインには検証されない)、(b) `pin` は per-plugin の明示指定なので件数は有界、(c) 「`defaults.version` を書いたのに pin したプラグインだけ効いていない」という事実は実際に知る価値がある。§7 にリスクとして残す。
- raw-spec.json にも今回は足さない理由: raw-spec は sandbox の中間ファイル(commit されない)なので追加コストは低いが、**現時点で消費者が居ない**。#23 が §4.2 の分岐で「provenance が必要」に倒れた場合、`dump_plugin` に `versionFromDefaults = true or nil` を 1 行足すだけで済む(`plugins.json` のスキーマには触れずに済む)。この設計余地を §4.2 に明記して #23 に渡す。

## 4. #23 との関係

### 4.1 #23 に対して本件が保証すること

- **#23 の解決対象集合が正しくなる。** #23 は `plugins.json`(正確には raw-spec 経由の `entry.version`)を読んで解決するので(`docs/plans/23-resolve-semver.md` §3.2 の解決ゲート)、本件なしでは `defaults.version` 指定の config に対して #23 は 1 件も解決しない。本件により、ゲート条件 `entry.version and is_null(resolvedRef) and is_null(commit) and is_null(tag)` がそのまま正しい集合を選ぶ。
- **#23 のゲートの `commit` / `tag` 条件は冗長になるが残してよい。** §3.2 の規則 B により、extract 経路では `commit`/`tag` 持ちに `version` が入らない。ただし `checks.resolve-merge` のような手書き raw-spec では両方書けるので、#23 側の防御は残す価値がある(#23 計画の変更は不要)。
- **`defaults.version` の編集が正しく再解決を引き起こす。** `identity_fields` に `version` が入っている(`resolve.lua:181`)ため:
  - 既存 config に `defaults = { version = "*" }` を足す → 対象プラグインの `version` が `null → "*"` → 恒等性変化 → `resolvedRef` が `null` → #23 が解決。
  - 逆に外す → `"*" → null` → `resolvedRef` を破棄 → HEAD に戻る。
  - `"*" → "^1"` の変更も同様。
  横断的な無効化ロジックは不要で、`docs/architecture.md:210` のマージ契約の文言も変えずに済む。
- **#23 に本件を待つ理由**: 逆順(#23 が先)だと、`defaults.version` を使っているユーザーは #23 がマージされても何も解決されず、本件のマージ時に初めて全プラグインが一斉に再解決される。順序どおり #42 → #23 なら、本件のマージ時点では「`version` が入って warning が出るだけ」で ref は動かず、#23 で初めて実際に解決される。

### 4.2 #23 計画への申し送り(**必須**): 「マッチするタグが無い」の扱い

`docs/plans/23-resolve-semver.md` §2 ゴール 2 / §3.3 は「制約を満たすタグが無い → **ハードエラー**で lock を止める」と決めている。**本件がマージされた後、この規則をそのまま実装すると `defaults = { version = "*" }` の config は lock 不可能になる。** 根拠:

- `defaults.version = "*"` は「semver をサポートしているプラグインについては最新安定版を*試す*」設定である(lazy: `lua/lazy/core/config.lua:16` のコメント原文)。
- lazy 自身は制約を満たすタグが無ければ黙って branch HEAD に落ちる(`git.lua:142-153`)。タグを 1 つも打っていない neovim プラグインは普通に存在するので、この fallback は例外処理ではなく通常動作である。
- 本件により、その全プラグインに `version = "*"` が付く。#23 が「マッチなし = 致命的」を貫くと、**lazy では動く config が nvimx では lock できない**。今日のサイレント HEAD よりも悪い退行である。

したがって #23 の実装前に、次のいずれかを決める必要がある。本計画としての推奨は **選択肢 2**。

1. **全制約でハードエラーを維持**(現 #23 計画のまま): 不可。上記の理由で `defaults.version` が使えなくなる。
2. **provenance で severity を分ける(推奨)**: `defaults` 由来の制約はマッチなし時に **warning + HEAD fallback**(= lazy 完全互換)、ユーザーがプラグインに明示的に書いた制約はマッチなし時に**ハードエラー**(タイプミスをその場で検出できる)。実装コストは、本件が `dump_plugin` に `versionFromDefaults = <true or nil>` を 1 行足し、#23 の resolve が severity 分岐にそれを使うだけ。**`plugins.json` のスキーマには足さない**(§3.6)。raw-spec は lock ごとに作り直されるので lock state にならず、`lock-app.nix:95-97` と `:121-123` の 2 パスは同じ raw-spec を読むため両パスの判定も一致する。
3. **全制約で warning + HEAD fallback**(lazy 完全互換に統一): 最も単純で、原則「lazy の意味論に一致させる」(`docs/architecture.md` 設計原則 3)に忠実。ただし `version = "^99"` のようなタイプミスも warning だけになり、#23 issue の「HEAD に黙って落ちない」という要求を「黙ってはいない」の水準まで弱める。`resolve.lua:220-224` の warning は `plugins.json` にも記録されるので追跡は可能。

いずれの場合も、**`git ls-remote` 自体の失敗 / 制約のパース不能はハードエラーのまま**でよい(前者は環境の問題、後者は文法エラーで、どちらも lazy の fallback とは性質が違う)。

本件の PR では #23 計画の書き換えまでは行わず(#23 未着手のため)、この節を根拠として #23 着手時に `docs/plans/23-resolve-semver.md` §2/§3.3/§7 を改訂する。もし選択肢 2 を先に決められるなら、本件で `versionFromDefaults` を raw-spec に足しておくのが最も安い(§5.1 の任意項目)。

## 5. 実装手順

### 5.1 `lua/nvimx/extract.lua` — 本体

行番号は現行 main 基準。#43 が先に入ると `dump_plugin` から `optional = p.optional`(現 `:56`)が消えるだけで、以下が触る `version = p.version`(現 `:54`)の位置と内容は変わらない。位置合わせはシンボルで行うこと。

1. **`safe_opts`(`:29-37`)のコメント補強**: 「`defaults` はここに足してはならない(ユーザーの `defaults.version` が lock 対象。§3.5)」を 1 行。
2. **`effective_version` を新設**(`safe_opts` の直後、`dump_plugin` の直前、現 `:38-39` あたり):

   ```lua
   -- lazy applies `defaults.version` only when it checks out (lua/lazy/manage/git.lua:141), so it is
   -- never written into the plugin object -- and by the time :141 runs, `commit` (:127) and `tag`
   -- (:133) have already returned. Reproduce that *effective* rule, not the literal condition on
   -- :141: recording a constraint that can never decide a ref would only mislead the lock and make
   -- resolve.lua warn about a constraint the user never wrote.
   -- `p.version == false` is lazy's per-plugin "do not use tags" and must beat the config-wide
   -- default, so this tests for nil, not for falsy.
   -- dev plugins are excluded by lazy too (git.lua:119-123); resolve.lua already routes them to
   -- localPlugins, so no guard is needed here.
   ---@param p table the plugin object normalized by lazy
   ---@param default_version string|nil Config.options.defaults.version, false normalized to nil
   local function effective_version(p, default_version)
     if p.version ~= nil then
       return p.version
     end
     if default_version == nil or p.branch ~= nil or p.tag ~= nil or p.commit ~= nil then
       return nil
     end
     return default_version
   end
   ```

3. **`dump_plugin` を 2 引数化**(現 `:39-61`): `local function dump_plugin(p, default_version)`、`version = p.version` → `version = effective_version(p, default_version)`。他フィールドは無変更。nil を返す経路は従来どおり **JSON でキーが生えない**(実測確認済み)ので、`defaults` を使わない config の raw-spec は 1 バイトも変わらない。
   - (任意 / §4.2 選択肢 2 を先に決める場合のみ)`versionFromDefaults = (p.version == nil and effective_version(p, default_version) ~= nil) or nil` を追加。`plugins.json` には出さない。
4. **`capture()` 内で読む**(現 `:74-76`、`Config.setup(...)` の直後):

   ```lua
   -- false means "do not use tags", which git.lua:141 folds into the same nil as "unset"
   local default_version = Config.options.defaults.version or nil
   ```

   `Config.setup` の**後**で読むこと(それ以前は `Config.options` が存在しない)。`Spec.new`(`:78`)の前後どちらでもよいが、由来が分かる `Config.setup` の直下に置く。
5. **dump ループ**(現 `:81-83`): `plugins[name] = dump_plugin(p, default_version)`。
6. **ファイル冒頭コメント**(`:7-10`)に 1 行: 「lazy が git 操作時にしか適用しない opts 由来の既定値(`defaults.version`)は、ここでプラグインごとに実体化する」。

### 5.2 `lua/nvimx/resolve.lua` — 変更なし(確認のみ)

- `:299` `version = p.version or vim.NIL` — `false` → `null` は §3.3 の意図どおり。
- `:181` `identity_fields` に `version` が含まれる — §4.1 の再解決が自動で効く。
- `:339-351` の warning ゲート — 変更不要(`defaults` 由来でも同じ扱い。§3.6)。

### 5.3 `tests/fixtures/` — fixture 2 つ追加

§6.1。

### 5.4 `flake.nix` — check 1 つ追加

`extractor-no-setup`(`:861-892`)の直後、`resolve-build-warnings`(`:898`)の前に `extractor-defaults-version` を追加。§6.2。

### 5.5 `docs/architecture.md`

- `:186` のスキーマコメント `"version": "^0.1", // the original semver constraint (kept for reference)` → 「**実効**の semver 制約。プラグイン自身の `version`、または `defaults.version` が適用された結果」に更新。
- `:129-137` の抽出ステップ [2] に 1 行: lazy が checkout 時にしか見ない `defaults.version` は抽出時にプラグインごとへ実体化する(自前の `version` / `branch` / `tag` / `commit` があるものは対象外)。
- `:210` のマージ契約か `:220-233`「Update semantics」に 1 文: `defaults.version` の編集は対象プラグイン全部の `version` を編集したことになり、その `resolvedRef` が再決定される。
- `:198` 付近の superset 方針・`:206` の semver 段落は変更不要(後者は #23 が触る)。

### 5.6 README

`programs.nvimx` のオプション説明に `defaults` の話は無いため変更不要(確認のみ)。

## 6. テスト

### 6.1 fixture

既存 fixture の規約(実ユーザー config の見た目、bootstrap snippet 込み、`tests/fixtures/<name>/init.lua`)に従う。lock 対象ではない(`nvimx-lock/` を同梱しない)ので、`merge-config` / `unbuildable-config` と同じ「extract → resolve だけ通す」種類。

**`tests/fixtures/defaults-version-config/init.lua`**(主ケース。`defaults = { version = "*" }` + 除外条件の全網羅):

```lua
-- A lazy.nvim-style config that sets a config-wide `defaults.version` instead of writing
-- `version` on each plugin. lazy applies this only when it checks out
-- (lua/lazy/manage/git.lua:141), so it never reaches the plugin object -- nvimx has to
-- materialize it at extraction time or the whole config silently tracks HEAD (#42).
-- Never built, only extracted and resolved, so it ships no nvimx-lock/ directory.
<bootstrap snippet, same as the other fixtures>

require("lazy").setup({
  -- eligible: the config-wide default is the only thing that decides its ref
  { "folke/tokyonight.nvim" },
  -- its own constraint wins, and its dependency is expanded by lazy and *is* eligible
  { "nvim-telescope/telescope.nvim", version = "^0.1", dependencies = { "nvim-lua/plenary.nvim" } },
  -- branch / tag / commit all decide the ref themselves; lazy never consults the default
  { "folke/trouble.nvim", branch = "dev" },
  { "folke/which-key.nvim", tag = "v3.0.0" },
  { "folke/flash.nvim", commit = "cbf1cb041a0e806c9f70e5b0b13d68f4dc26cfe8" },
  -- lazy's per-plugin opt-out ("do not use tags"), which must beat the config-wide default
  { "folke/noice.nvim", version = false },
}, {
  defaults = { version = "*" },
})
```

**`tests/fixtures/defaults-version-false-config/init.lua`**(`defaults.version = false` が「未指定」と同義であることの担保。2 プラグインだけ):

```lua
-- lazy's own config template recommends `defaults.version = false` ("a lot the plugin that
-- support versioning, have outdated releases"), and git.lua:141 folds that into the same nil as
-- leaving it unset. nvimx must not record `false` as a constraint (#42).
<bootstrap snippet>
require("lazy").setup({
  { "folke/tokyonight.nvim" },
  { "nvim-telescope/telescope.nvim", version = "^0.1" },
}, {
  defaults = { version = false },
})
```

### 6.2 `checks.extractor-defaults-version`(新設)

`extractor-snapshot`(`flake.nix:833-857`)と同じ骨格(`pkgs.runCommand`、`nativeBuildInputs = [ pkgs.neovim-unwrapped pkgs.jq ]`、store 内で自己完結 = **ネットワーク不要**)。`resolve-build-warnings`(`:911-925`)の `extract()` シェル関数をそのまま流用して 2 fixture を回す。golden ファイルは作らず jq assert で書く(検証したいのは 7 プラグイン中の数フィールドだけで、golden にすると `url` 等の無関係な差分で壊れやすい)。

手順:

1. `extract ${./tests/fixtures/defaults-version-config} $sb/defaults.json`
2. **raw-spec への assert**(extract 単体の契約。#23 の影響を受けない):
   - `.plugins["tokyonight.nvim"].version == "*"` — ゴール 1
   - `.plugins["plenary.nvim"].version == "*"` — ゴール 1(依存展開されたプラグインにも届く)
   - `.plugins["telescope.nvim"].version == "^0.1"` — ゴール 2
   - `trouble.nvim` / `which-key.nvim` / `flash.nvim` の各エントリで `has("version") | not`、かつ `branch == "dev"` / `tag == "v3.0.0"` / `commit` が保たれていること — ゴール 2 + §3.2 の選択肢 B
   - `.plugins["noice.nvim"].version == false` — ゴール 3(`false` が `"*"` に化けていないこと。**falsy 判定で実装した場合ここだけが落ちる**ので、この 1 行が §3.2 の nil 判定を守る)
3. **`plugins.json` への assert**(issue の "Done when" 第 1 項が言うのは lock 側なので、resolve まで通す):
   - `nvim -l ${./lua/nvimx}/resolve.lua $sb/defaults.json plugins.json 2> resolve.log`(ディレクトリごと渡すのは `json.lua` を `dofile` するため。`resolve-build-warnings:928` と同じ)
   - `.plugins["tokyonight.nvim"].version == "*"` / `.plugins["plenary.nvim"].version == "*"`
   - `.plugins["telescope.nvim"].version == "^0.1"`
   - `.plugins["noice.nvim"].version == null`(`false` は lock では `null`。§3.3)
   - `trouble.nvim` / `which-key.nvim` / `flash.nvim` は `.version == null`
   - **warning の文言は grep しない。** `resolve.lua:347-350` の `is not resolved yet (TODO: semver)` は #23 が削除する暫定メッセージなので、ここで縛ると #23 がこの check を書き換えることになる。代わりに「制約を持つエントリ数」を数える: `[.plugins[] | select(.version != null)] | length == 3`(tokyonight `"*"` / plenary `"*"` / telescope `"^0.1"` の 3 件。実測で確認済み)。
4. `extract ${./tests/fixtures/defaults-version-false-config} $sb/false.json` → raw-spec で `.plugins | map(has("version")) | any | not`(= どのエントリにも `version` キーが生えていない)…ではなく telescope は自前 `version` を持つので、`.plugins["tokyonight.nvim"] | has("version") | not` と `.plugins["telescope.nvim"].version == "^0.1"` を assert する。ゴール 3。
5. `touch $out`

### 6.3 既存 check への影響

- **`extractor-snapshot`(`flake.nix:833-857`)/ `tests/fixtures/golden/basic-config.raw-spec.json`: 差分なし。** `basic-config/init.lua` の opts は `install = { colorscheme = ... }` だけで `defaults` を持たないため `Config.options.defaults.version` は nil、`effective_version` は nil を返し、`dump_plugin` の戻り値テーブルに `version` キーが生えない — 現状(golden が `name` / `short` / `url` の 3 キーのみ)と完全一致。**golden の再生成は不要**であり、そのことをゴール 5 として明示的に確認する。
- `extractor-no-setup`: `extract.lua` の setup 捕捉経路は無変更。差分なし。
- `resolve-build-warnings`(`:898-975`)/ `resolve-merge`(`:981-1165`): 対象 fixture(`unbuildable-config` / `build-plugins` / `merge-config`)と手書き raw-spec(`tests/fixtures/merge/*.json`)はいずれも `defaults` を持たないので差分なし。`resolve-merge` の extract 部分(`:1141-1163`)の assert(`telescope.nvim.version == "^0.1"` 等)もそのまま通る。
- `tests/fixtures/{basic-config,build-plugins,registry-plugins,treesitter-config}/nvimx-lock/plugins.json`: **再生成不要**(いずれも `defaults` 未使用)。#43 が `optional` 除去のために再生成するので、本件はそれに乗るだけ(逆に本件が独自に再生成を要求しないことを PR で明言する)。
- `docs/architecture.md:436` の checks 列挙リストに `extractor-defaults-version` を追記(現状 `extractor-snapshot` 等が並んでいる箇所)。
- **同じファイルの `:427` 付近の `tests/fixtures/` 一覧にも新 fixture 2 つを追記する。** checks 一覧だけ更新して fixture 一覧を放置するのは非一貫。なおこの一覧は main 時点で既に古く `empty-config` / `merge` / `merge-config` が欠落している。ついでに直してよい(#34 の scope と重なるが、追記のついでなら安い)。

### 6.4 CI と darwin 評価

- `.github/workflows/check.yml` は `nix flake check` を丸ごと実行するので、`checks` に 1 つ足すだけで linux / darwin 両系統の CI に乗る。**ワークフローの編集は不要**。仮にステップ追加が必要になっても、CLAUDE.md の規約により編集するのは reusable workflow の `check.yml` のみで、`ci-linux.yml` / `ci-darwin.yml` には触れない(badge を per-workflow にするための構造)。
- ローカルの `nix flake check`(linux)は darwin を `omitted these incompatible systems` でスキップするため、CLAUDE.md の規約どおり `nix eval .#checks.aarch64-darwin.extractor-defaults-version.drvPath` で darwin 側の評価だけ通す。新 check は `neovim-unwrapped` + `jq` のみで、`extractor-snapshot` と同じ構成なので darwin 固有の落とし穴(`timeout` が PATH に無い等、`:867-869` のコメント参照)には触れない — `coreutils` は使わない。
- 手動確認: `defaults = { version = "*" }` を書いた実 config に `nix run .#lock` を通し、`plugins.json` の各エントリに `"*"` が入ること・`nix flake lock` が通ること(#23 前なので ref は HEAD のまま)を 1 度見る。

## 7. リスク / 未決事項

- **#23 の「マッチなし = 致命的」との衝突(最重要)**: §4.2。本件単体では無害だが、#23 が現計画のまま実装されると `defaults = { version = "*" }` の config が lock 不可能になる。#23 着手時に `docs/plans/23-resolve-semver.md` を改訂すること。本計画としては選択肢 2(provenance で severity を分ける)を推奨し、必要な足場(`dump_plugin` に 1 行)を §5.1-3 の任意項目として用意しておく。
- **本件マージ直後の warning 増加**: #23 前は `resolve.lua:347-350` の `version constraint "*" is not resolved yet (TODO: semver)` が対象プラグイン全件に出る。`defaults.version` を使っている config では数十件になりうる。#23 で消える暫定 warning なので許容するが、#42 の PR 本文にはこの挙動変化を明記する。1 行に集約する等の対処は #23 と重複するので本件ではやらない。
- **`pin` + `defaults.version` の warning**: §3.6 の通り `pinned; version constraint "*" is not validated (pin wins)` がユーザーの書いていない制約について出る。内容は真であり件数も有界なので受容。`docs/architecture.md:231` の記述(pin が version に勝つ)と整合しているので文書追記は不要。
- **`resolvedRef` の一斉再決定**: `defaults.version` を既に使っているユーザーが本件を含む nvimx に上げると、対象プラグインの `version` が `null → "*"` に変わり恒等性が崩れるため、`resolvedRef` が一斉に `null` に戻る。#23 前なので実際の ref は HEAD のままで**ビルド結果は変わらない**が、`pin = true` のプラグインは「spec が変わった」扱いで凍結が 1 度解け、`lock-app.nix:120-135` の収束パスで現 rev に再凍結される(`resolve.lua:330-332`)。rev 自体は動かないので実害はないと判断するが、`plugins.json` の diff は大きく出る。PR 本文と CHANGELOG 相当の記述に残す。
- **seed 更新への追従**: 本件は `git.lua:141` の条件式ではなく `get_target`(`:118-153`)の**構造**を再現している(§3.2)。lazy が早期 return の順序を変えたり `defaults` にキーを足したりすると、§3.4 の監査結果が古くなる。検知手段は `extractor-defaults-version` の assert(適用規則が変われば落ちる)だが、**「`defaults` に新キーが増えた」ことは検知できない**。seed 更新の PR では `lua/lazy/core/config.lua` の `defaults` ブロックを目視し、§3.4 の表を更新する運用にする(`extractor-snapshot` が seed 更新で壊れるのと同じ性質)。
- **seed とユーザーの lazy.nvim の skew**: `lock-app.nix:44-46` の TODO(「既存 lock が lazy.nvim を pin していればそれを seed に使う」)が入ると、抽出に使われる lazy が nvimx の pin より新しくなりうる。そのバージョンで `defaults.version` の適用規則が変わっていた場合、nvimx は古い規則を適用したままになる。現状は常に nvimx の seed なので今日の問題ではない。
- **`defaults` は import された spec からは変更できない**: `defaults` は opts のキーであり、`import` / `.lazy.lua`(`Config.options.local_spec`)が持ち込めるのは spec だけなので、`setup` に渡された 1 つの `defaults` が全体に効く。`Config.setup` は extract で 1 回しか呼ばれない(`extract.lua:74-75`)ので競合もない。追加の考慮は不要。
- **`defaults.version` を dev プラグインに書いた場合**: §3.2 の通り lazy でも nvimx でも無視される。check では assert しない(fixture コストに見合わない)。将来 `local-plugin` fixture を触る機会があれば 1 行足す。
- **未決**: §4.2 の選択肢を本件の PR で決めて `versionFromDefaults` を先に入れるか、#23 まで持ち越すか。本計画は「持ち越し(足場だけ用意)」を既定とするが、レビューで #23 の方針が固まるなら本件で入れるほうが往復が減る。
