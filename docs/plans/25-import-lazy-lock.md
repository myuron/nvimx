# #25 対応計画: `--import-lazy-lock` による lazy-lock.json からの移行 import

対象 issue: [#25 feat(lock): add --import-lazy-lock](https://github.com/myuron/nvimx/issues/25)

Depends on #18(PR #41 でマージ済み)。前提となる #43 / #42 / #31 / #36 / #23 / #24 は**すべて main にマージ済み**
(`7d43721` 時点)。本計画の `file:line` は**現在の main(`7d43721`)基準で全件再検証済み**である。

旧版(`08e51ef` = #24 マージ前)からの主な訂正:

- §3.1 の「home-manager ラッパは触らない」→ **現物で確認済み・変更不要**(`nix/home-manager/default.nix:25-32`)
- §5.2 の行番号はすべて #24 後の実コードに差し替え。`lock-app.nix` のパーサは `while [ $# -gt 0 ]`(`:32-60`)、
  `--update` は**多語消費の while ループ**(`:46-50`)であって 1 語先読みではない。import は 1 語先読みで書く
- 旧 §6.2 の「lock-app の bash パーサは checks にできない」→ **一部は可能**。#24 が
  `checks.resolve-update` step 10(`flake.nix:2011-2020`)で `nvimxLib.lockApp` を nativeBuildInputs に入れて
  `nix` を一度も呼ばない引数エラー経路を assert する前例を作った。本件も**併用拒否・既定パス・不存在エラーの
  3 件を offline check に載せる**(§6.2 step 12-15)。手動検証は残すが必須ではなくなる
- §3.4 の `tag` あり seed について、**git type では `?ref=refs/tags/<t>&rev=<sha>` の両方が付く**ことを
  `genflake.lua:45-57` の実読で確定。リスクとして §7 に追加(旧版は github type しか見ていなかった)
- 報告 summary に「lazy-lock に無い config 側プラグイン数」を 1 項足し、
  **`pinned + skipped + ignored == lazy-lock.json のエントリ総数`という不変条件**を check で assert する(§3.6 / §6.2)

### 計画レビュー(opus)による訂正(反映済み)

本計画は執筆後に別の opus サブエージェントが**実コードに突き合わせて**レビューしており、以下を反映済みである。
`resolve.lua` / `lock-app.nix` の行番号はレビューで全件照合され、誤りは 1 件も無かった。

1. **[MAJOR] §6.2 step 10 の期待件数は `8`**(スニペットが `9` になっていた)。`out1.json` の `plugins` に
   載る非 local 9 件のうち `only-here.nvim` は `import_db` に無く、`local.nvim` は `resolve.lua:515-516` で
   マージループに到達しないため、prev ブロックされるのは 8 件。
2. **[MAJOR] §6.2 step 16 の生成 lazy-lock に `lazy.nvim` エントリが必要**。分類 8 は `import_db` に
   `lazy.nvim` キーがあるときしか出ないため、`tokyonight.nvim` のみのファイルでは assert が通らない。
3. **[MINOR] §6.2 step 2 の grep 2 本が空虚だった**。進捗行は `resolve.lua:686` で **stdout** に出るので
   stderr を grep しても常に真。stdout を別取りする形に修正。`--lazy` という文字列はどこにも印字されない。
4. **[MINOR] §3.2 のトップレベル配列の扱いが自己矛盾していた**。`vim.json.decode("[1,2]")` は
   **数値キーの table** を返すので `type(decoded) ~= "table"` では捕まらない。配列はエントリ単位ループに落ち、
   分類 9 の `key is not a plugin name` になる —— この分岐が死にコードでない唯一の根拠。ハードエラー側の
   文言を「table でない」に修正。
5. **[MINOR] §6.1 のカバレッジ穴 3 件**を追加: 空オブジェクト、トップレベル配列、
   「壊れたエントリ名が config 側にも居る」場合の分類 5 抑止(意図的な設計判断として明文化)。
6. **[MINOR] 分類 10 の文言**を `resolve.lua:816` の慣習(`the config-wide version constraint` /
   `version constraint` の使い分け)に合わせ、`<name>` がリテラルのプレースホルダであることを明記。
7. **[NIT]** `versioned` の宣言は `:332`(`:331` は `pending`)、申し送りコメントは `:202-207`、
   URL mapping 表の本体は `:236-244`。分類器に明示的な `else` bucket を置いて不変条件が黙って崩れないようにする。

## 1. 背景 / 現状(現在の main で再検証)

### 1.1 CLI と lock の流れ(`nix/lib/lock-app.nix`)

- `:3` に `# TODO (Phase 6): --import-lazy-lock` が**単独で残っている**(#24 が `--update` を落とした)。本件で TODO 行ごと消える。
- `usage()` は `:22-25`。現在の文字列は
  `usage: nvimx-lock --config <configDir> --out <lockDir> [--update [name...]]`。
- 引数パーサは `:32-60` の `while [ $# -gt 0 ]`。`--config`(`:34-37`)/ `--out`(`:38-41`)は `shift 2`、
  `--update`(`:42-55`)は **`while [ $# -gt 0 ] && [ "''${1#--}" = "$1" ]` で名前を何語でも消費**し、
  1 語も取れなければ `update_all=1`。`*)` は `usage`(`:56-58`)。**同名フラグは後勝ち**。
- `:61-69`: bare `--update` と named `--update` の併用拒否(`echo` + `usage`)。**本件の併用拒否はこの直後に置く**。
- `:70` 必須チェック → `:71-80` `--update` の「既存 lock が無ければ exit 2」ガード
  (**`mkdir -p "$out"` より前に置くことで、失敗時に空ディレクトリすら作らない**という明示的な設計)→
  `:81` `config=$(realpath "$config")` → `:82-83` `mkdir -p "$out"` / `out=$(realpath "$out")`。
- `:87` `seed="${lazyNvimSeed}"`。`:89` `sandbox=$(mktemp -d)`。
- `:99-106` resolve.log 後出し機構(#22)の `cleanup` trap。
- `resolve_args` の構築は `:129-147`。`--prev`(`:130-132`)/ `--lock`(`:133-135`)を条件付きで、
  `--update` 系(`:136-147`)を `update_mode` のときに積む。
- **1 回目の resolve は `:155-158`**、`--lazy "$seed"` を常に渡し `resolve_args` を展開する。
- **2 回目(収束パス)は `:209-211` で `--prev` / `--lock` / `--lazy` を直書き**しており `resolve_args` を使わない。
  直前の `:203-207` に「ここに `--update` 系を渡してはならない。#25 の `--import-lazy-lock` も
  `resolve_args` を共有形に組み替えるなら同じ除外が要る」という申し送りコメントがある。
- `:236-241` `--update` 時のみ `update-summary.lua` を呼ぶ。

### 1.2 resolve.lua 側(#18 + #23 + #24 の実装)

- ヘッダの Usage コメント `:3-6`、`usage()` `:21-28`。
- フラグループ `:30-93`。`:43` が**値付き既知フラグの一括判定**
  (`a == "--prev" or a == "--lock" or a == "--lazy" or a == "--update-plan"`)で、`:49-57` に代入の if-chain。
  `--update` は `:59-72` の 1 語先読み分岐。`:73` が未知 `--` フラグのエラー。`:81-84` が位置引数の検証。
  `:85-92` に「bare + named `--update` の併用は resolve.lua 側でも拒否(手叩き用の防御)」。
- `read_json` は `:98-117`。JSON 不正時のメッセージ(`:108-114`)は
  `"... Fix the file, or delete it and run nvimx-lock again -- deleting it loses the pinned revs."` で、
  **prev 専用の文言**。`checks.resolve-merge`(`flake.nix:1601-1603`)が `run nvimx-lock again` と
  `is not valid JSON` を grep しているので**この 2 語を壊してはならない**。
- `is_null` `:122-124` / `norm` `:126-131` / `is_true` `:133-135` / `is_frozen_rev` `:139-141`(40 桁 hex)/
  `is_tag_ref` `:145-147`。
- prev のロードは `:149-166`(`schemaVersion ~= 1` は fatal)。flake.lock の pin DB は `:168-192`。
- `local force = {}` は `:198`。`to_input_name` は `:200-203`(`name:gsub("[^%w_-]", "-")`)。
- **`identity_fields = { "branch", "tag", "commit", "version" }` は `:223`。`resolvedRef` は含まれない**
  (`source_fields` は `:224`、`same_identity` は `:226-242`)。**seed 永続性の唯一の根拠。**
- `warn` `:262-266`(stderr + `plugins.json` の `warnings`)/ `note` `:268-270`(**stderr のみ**、`"[nvimx] " .. line`)。
- `pending` の宣言は `:331`、`versioned` は `:332`。
- **進捗行(`resolving version constraints for N plugin(s)`)は `:686` で stdout に書かれる**
  (#22 のため意図的に stderr ではない)。§6.2 step 2 の grep はこれを踏まえること。
- #24 の名前検証は `:470-512`。`:474-477` に `input_name_lookup`(`to_input_name(rn) -> rn`)を作る前例があり、
  §3.3 の did-you-mean はこれと同型。
- **メインループは `:514`** `for name, p in pairs(raw.plugins or {})`。`dev`/`dir` は `:515-516` で `local_plugins` 行き
  (**以降のマージ処理には到達しない**)。`entry` 構築は `:537-548`。
- **マージ本体 `:550-572`**。核心は `:552`:
  ```lua
  local prev = (prev_plugins and not force[name]) and prev_plugins[name] or nil
  ```
  → **`prev` はエントリ不在でも `force[name]` が立っていても nil になる**。§3.5 の判定を生の
  `prev_plugins[name]` で行う根拠(**旧計画の疑似コードのバグ**)。
- unpin 時の凍結破棄は `:568-570`(`is_frozen_rev(carried) and is_true(prev.pin) and not is_true(entry.pin)`)。
- **pin 凍結ブロックは `:574-581`**。条件(`:579`)は
  `is_true(entry.pin) and unchanged and is_null(entry.resolvedRef) and is_null(entry.commit)`。
  **`unchanged` を含むので prev が無いエントリでは絶対に発火しない** → seed と排他。
- **#23 の解決ゲートは `:583-603`**。条件(`:595`)は
  ```lua
  if p.version and is_null(entry.resolvedRef) and is_null(entry.commit) and is_null(entry.tag) then
  ```
  → **`entry.resolvedRef` が非 null ならゲートは発火しない。§3.4.1 の全根拠。**
- `versioned` への push は `:604-609`(`p.version` がある全プラグイン)。`plugins[name] = entry` は `:611`。
- semver 解決の実処理は `:615-784`。git が PATH に無い場合は `pcall(vim.system, ...)` が偽を返し
  `:719` の `could not run git ls-remote (is git on PATH?)` で **fail_plugin(致命)**。
  `from_defaults` でも spawn 失敗は fallback にならず致命である点に注意(§6.2 の証明に使う)。
- `defaults.version` fallback の集約 note は `:786-803`(分類 10 はこの流儀を踏襲する)。
- pin+version 警告は `:805-819`。**ここで `versioned` が name 昇順に sort される**(`:809-811`)。
- `plugin_warnings` の emit は `:821-832`。`report_resolve_errors()` の呼び出しは `:838`(コメント `:834-837`)。
- unbuildable の note は `:840-849`。`result` は `:851-861`、**出力書き込みは `:863-865` の 1 回だけ**。
- `--update-plan` の書き出しは `:867-888`。

### 1.3 genflake の URL 優先順(`lua/nvimx/genflake.lua`)

- github type(`:28-40`): `commit` > `resolvedRef` > `tag`(`/refs/tags/<t>`)> `branch`。
- git type(`:41-68`): `commit` → `rev`、なければ `resolvedRef` が 40-hex なら `rev`、そうでなければ `ref`(`:45-54`)。
  そのうえで **`ref` が未設定なら `tag` → `branch` の順で `ref` を埋める(`:57`)**。
  → **`tag` を持つ git type のプラグインに 40-hex を seed すると `?ref=refs/tags/<t>&rev=<sha>` の両方が付く**。§7。
- パラメータ順は `ref` → `rev`(`:58-64`)。

### 1.4 lazy-lock.json の実フォーマット

(pin された seed `lua/lazy/manage/lock.lua` の実読。旧計画から変更なし)

- 書式: `{ "<name>": { "branch": "<branch>", "commit": "<40 hex>" }, ... }`。キーは `table.sort` 済み、
  値は `branch` / `commit` の 2 キー(`M.update`)。ただし `M.load` は `vim.json.decode` 素通しなので、
  **他キー・欠落キーを含むファイルが世に存在しうる**。parse は「`commit` 必須、`branch` 任意、未知キーは無視」。
- lock に載るのは **installed な非ローカルプラグイン ∪ disabled ∪ cond 無効化**。config から消したものは lazy が消す。
- **`lazy.nvim` 自身のエントリは通常必ず入る**(`Plugin.load()` が `{ "folke/lazy.nvim" }` を足す)。
  一方 nvimx の extract は `Plugin.Spec.new(spec, { pkg = false })` を呼ぶ(`lua/nvimx/extract.lua:147`)ので
  raw-spec に `lazy.nvim` は入らない。実際 `tests/fixtures/golden/basic-config.raw-spec.json` の `plugins` は
  `tokyonight.nvim` 1 件のみ。→ **import では `lazy.nvim` が必ず未マッチになる**(§4.3)。
- 名前の同一性: lock のキーも raw-spec のキーも lazy の `M.get_name`(末尾 `.git` と `/` を落として最後のパス要素)が
  唯一の導出元。**完全一致照合が正当である根拠。**
- extract は `disabled = vim.tbl_keys(s.disabled or {})` を raw-spec のトップレベルに出す
  (`lua/nvimx/extract.lua:162`)。**resolve.lua は現在 `raw.disabled` を一切読んでいない**(新規に読む)。

### 1.5 ドキュメントの予告(既に `--import-lazy-lock` を宣伝している箇所)

- `docs/architecture.md:82` シーケンス図 `nvimx-lock [--update] [--import-lazy-lock]`
- `docs/architecture.md:141-142` `[3] Resolution` の CLI 行(`--prev` / `--lock` / `--lazy` のみ)
- `docs/architecture.md:262` Update semantics の `--import-lazy-lock` 行
- `docs/architecture.md:440` First run の `--import-lazy-lock ~/.config/nvim/lazy-lock.json`
- `docs/architecture.md:478` fixtures 一覧 / `:487` checks 一覧 / `:519` Phase 6 の一覧
- `README.md` の Usage は `:72-112`(`--update` の段落が `:104-112`)、`## Options` が `:114`。移行の記述は無い。
- `templates/default/README.md:22-29`「Adding and updating plugins」。
- `nix/home-manager/default.nix:21-32` `lockCommand`: `projectDir` 設定時は
  `exec nvimx-lock --config ... --out ... "$@"` と**デフォルトを無条件に前置して `"$@"` を後置**する。
  → **`nvimx-lock --import-lazy-lock` はそのまま通る。本件での変更は不要(確認済み)。**
  末尾に置かれるため `--import-lazy-lock` を最後に書いても 1 語先読みが正しく「値なし」を判定する。

## 2. ゴール

1. **正確な pin**: fixture の `lazy-lock.json` を import した `plugins.json` で、照合成功した各プラグインの
   `resolvedRef` が lazy-lock の `commit` と完全一致する(golden diff + `lazy-lock.json` 自身から jq で読み出した
   値との 1 件ずつの突き合わせ)。genflake を通した `flake.nix` の input URL に該当 SHA が現れる。
   **完全オフライン**(ネットワークも `git` バイナリも使わずに)検証する。
2. **報告の完全性**: (a) 照合できない lazy-lock エントリ、(b) config にあって lazy-lock に無いプラグイン、
   (c) seed をスキップした理由、(d) seed により検証されなくなった `version` 制約が、区別されて決定的な順序で
   stderr に出る。**`pinned + skipped + ignored == lazy-lock.json のエントリ総数`** が成り立ち、
   黙って捨てられるエントリは 1 つも無い。
3. **lock を汚さない**: import の報告は `plugins.json` の `warnings` に入らない。import 後にフラグ無しで
   再 lock した出力が byte-identical。
4. **優先順位**: force(#24) > 実 prev > import シード > 通常解決。同一入力の再 import は no-op。
5. **CLI**: `nvimx-lock --config <dir> --out <dir> --import-lazy-lock [path]` が受理され、path 省略時は
   `<configDir>/lazy-lock.json`。ファイルが無い / 壊れている場合は明確なエラーで exit 非ゼロ。
   `--update` との併用は usage エラー。
6. **ドキュメント**: `README.md` に移行フロー(コマンド列 + ユーザーが確認すべき差分)が載る。

## 3. 設計

### 3.1 CLI インタフェース

**lock-app(bash)**: `--import-lazy-lock [path]`。引数省略可なので **1 語先読み**で判定する
(`--update` の多語 while ループとは別形。パスは高々 1 個なので):

```bash
--import-lazy-lock)
  import_mode=1
  shift
  if [ $# -gt 0 ] && [ "''${1#--}" = "$1" ]; then
    import_path="$1"
    shift
  fi
  ;;
```

- 既定値 `<configDir>/lazy-lock.json` は `config=$(realpath "$config")`(`:81`)の**後**、
  `mkdir -p "$out"`(`:82`)の**前**で確定させる。`--update` ガードと同じ理由:
  **このガードで落ちる実行は空の out ディレクトリすら作ってはならない**。
- **ファイル不存在は即エラー(exit 2)**: 明示的に import を求めた実行が黙って通常 lock に落ちると
  「全プラグインが今日の HEAD へ動く」という本機能が防ぎたい事故そのものが起きる。
- `--` 始まりのパス名は指定できない。現実に存在しないので許容する。
- `--update` との併用は **usage エラーで拒否**(§4.2)。
- **home-manager ラッパは触らない**(§1.5 で確認済み)。

**resolve.lua**: フラグループに `--import-lazy-lock <path>` を**値付き既知フラグ**として追加(path 必須。
既定値解決は lock-app の責務)。`--prev` / `--lock` / `--lazy` と同じく、値が `--` で始まっていても
そのまま値として食う(既存 3 フラグと同じ挙動なので特別扱いしない)。

**収束パス(2 回目の resolve、`lock-app.nix:209-211`)には渡さない。**

- 根拠: 1 回目の resolve は raw-spec の全プラグインを `plugins.json` に書く。2 回目は
  `--prev "$out/plugins.json"` を受けるので**全エントリで prev が存在**し、import シードは §3.5 の優先順位に
  よって 1 件も適用されない。渡しても渡さなくても出力は同じ。
- 渡さない方を採る理由: `:209-211` の直書き呼び出しを**一切触らずに済む**。`:202-207` の申し送りコメント(#25 に触れているのは `:205-207`)が
  「`resolve_args` を共有形に組み替えるなら除外が要る」と警告しているとおり、その誘惑を持ち込まない。
  代わりに同コメントを「#25 は組み替えず、フラグを渡さない」に更新する(§5.2)。

### 3.2 lazy-lock.json の parse

`read_json`(`resolve.lua:98-117`)を再利用する。ただし JSON 不正時のアドバイス文は prev 専用なので、
**第 3 引数 `advice` を追加**して分岐する(既定値は現在の文字列そのままにし、既存メッセージのバイト列を変えない。
`checks.resolve-merge:1601-1603` の grep を壊さないため):

```lua
local JSON_ADVICE_LOCK = "Fix the file, or delete it and run nvimx-lock again -- deleting it loses the pinned revs."
local JSON_ADVICE_IMPORT = "Fix the file, or regenerate it with :Lazy restore in lazy.nvim -- nvimx will not guess the commits."

local function read_json(path, what, advice)
  ...
  fail(("%s is not valid JSON (%s): %s. "):format(what, path, decoded) .. (advice or JSON_ADVICE_LOCK))
end
```

検証は 2 段:

- **ファイル単位(ハードエラー)**: 開けない(`cannot open the lazy-lock.json: <path>`)/ JSON として壊れている /
  **decode 結果が table でない**(`the lazy-lock.json (%s) is not a JSON object`)。移行データの黙殺は許されない。
  **注意(レビュー指摘)**: `vim.json.decode("[1,2]")` は**数値キーの table を返す**ので、
  `type(decoded) ~= "table"` は**トップレベル配列を捕まえない**。配列はそのままエントリ単位ループに落ち、
  「キーが文字列でない」= 分類 9 として報告される。**これが分類 9 の `key is not a plugin name` が
  死にコードでない唯一の根拠である。** したがってハードエラー側は「table でない」だけを見る(数値・文字列・
  boolean の JSON が来た場合)。メッセージ文言も「JSON object でない」ではなく decode 結果に即したものにする。
- **エントリ単位(報告のみ、非致命 = 分類 9)**: キーが文字列でない / 値がオブジェクトでない(`vim.NIL` を含む)/
  `commit` が文字列でない / `commit` が 40 桁 hex でない。部分的に壊れたファイルでも残りの移行価値がある。
  形式検査には `is_frozen_rev`(`:139-141`)をそのまま使う。
  **判定順は「値が table か」→「`commit` が文字列か」→「40-hex か」**。`vim.NIL` は
  `type == "userdata"` なので最初の判定で捕まり、`.commit` のインデックスに到達しない
  (`vim.json.decode("{}")` は `vim.empty_dict()` = table を返すので空オブジェクトは正常系)。
- `branch` は任意(値が文字列でなければ「無し」として扱う)。未知キーは無視。
- 空オブジェクトは正常。`import: lazy-lock.json has no entries; nothing to seed` を 1 行 note して通す。

### 3.3 名前照合

- **主経路: キーの完全一致**。§1.4 のとおり lock のキーと raw-spec のキーは lazy の `get_name` という単一の
  導出元を共有する。曖昧照合(大文字小文字の同一視、`.nvim` の付け外し等)は誤マッチの温床なので**導入しない**。
- **近似ヒント**: 完全一致しなかった lazy-lock エントリについて、`to_input_name`(`:200-203`)で正規化した名前が
  config 側のどれかの正規化名と一致すれば、報告に `did you mean "<config 側の名前>"?` を添える。
  **報告のみで自動マッチはしない。** 実装は #24 の `input_name_lookup`(`:474-477`)と同型。
- **`disabled` の分類**: 未マッチのうち `raw.disabled`(`extract.lua:162`)にある名前は
  「config で無効化されているため対象外」として別分類(6)。lazy が意図的に残すエントリなので正常系である。
- **local(dev/dir)プラグイン**: raw.plugins には居るがマージループに到達しない(`resolve.lua:515-516`)ので、
  報告段で別分類(skip)にする。lazy は `is_local` を lock に書かないので通常は現れないが、
  不変条件(§3.6)を成立させるため必ず分類する。
- **`lazy.nvim` 自身**: §4.3、分類 8。

### 3.4 seed の書き込み先: `resolvedRef`(`commit` ではない)

**採用: `resolvedRef` に lazy-lock の `commit`(40 桁 SHA)を書く。**

- `commit` フィールドは `identity_fields`(`:223`)の構成要素である。ここに書くと次回 lock で raw-spec 側の
  `commit = null` と食い違って `same_identity` が false になり、`resolvedRef` が null に戻って **pin が全損する**。
- `resolvedRef` は恒等性に含まれないので、seed 後も spec 恒等性は raw-spec と一致し続け、**以後の通常 lock で
  マージ契約 1(`:554-572`)により無条件に生き延びる**。
- **`branch` フィールドへの書き込みもしない**(同じ理由)。

**spec のフィールド別の seed 可否**(照合に成功したエントリについて):

| spec の状態 | 挙動 | 理由 |
|---|---|---|
| 素 / `branch` 未指定 | seed する | 移行の本命ケース |
| `version` あり(明示 / `defaults` 由来を問わず) | **seed する** | §3.4.1 |
| `tag` あり | **seed する** | genflake は `resolvedRef` > `tag`。github type は `github:o/r/<sha>`。git type は `?ref=refs/tags/<t>&rev=<sha>` になる(§7 のリスク) |
| `commit` あり | **seed しない**(分類 2) | genflake で `commit` が最優先(`:45`)なので seed は無意味。値が食い違う場合はその旨も報告(spec が勝つ) |
| `branch` 明示 ∧ lazy-lock の `branch` と不一致 | **seed しない**(分類 3) | lock 記録後に spec の branch を変えた明確な証拠。「spec の編集は過去の決定に勝つ」。git type では `?ref=<spec branch>&rev=<別ブランチの rev>` になり fetch が失敗しうるという実害もある。**`branch` 未指定のときは比較しない**(default branch 名はオフラインでは知り得ない) |
| `pin = true` | seed する | prev が無い以上 `unchanged = false` なので pin 凍結ブロック(`:579`)は発火しない。seed がそのまま凍結値になる |
| `dev` / `dir`(local) | seed しない(分類 skip) | マージループに到達しない。ロックする対象が無い |

**但し書き**: seed した 40-hex は `is_frozen_rev` が真になるため、**pin 由来の凍結と区別が付かない**。
`pin = true` のまま import したプラグインから後で `pin` を外すと、unpin 処理(`:568-570`)が `resolvedRef` を
破棄し、通常追跡(+ `version` があれば #23 の解決)に戻る。意味論としては妥当なので**受容する**が §7 に残す。

#### 3.4.1 `version` 有りエントリへの seed と #23 ゲートの関係

#23 のゲート(`:595`)は `p.version and is_null(entry.resolvedRef) and is_null(entry.commit) and is_null(entry.tag)`。
**seed をこのゲートより前で行えば `entry.resolvedRef` が非 null になり、ゲートは発火しない。**

**帰結 1(利点)**: `defaults = { version = "*" }` を書いている lazy ユーザーの移行では、**初回 lock で
ls-remote が 1 本も飛ばない**。#23 のフォールバック集約行も出ない。lazy が既に semver で選んだ commit を
そのまま引き継ぐので、bit-identical 移行が成立する。

**帰結 2(欠点)**: seed された `version` 付きプラグインは、以後 spec を触らない限り**制約が一度も検証されない
まま commit に固定され続ける**。#23 の重大度分岐はこのプラグインを一切見ない。`pin = true` の場合だけは既存の
`pinned; version constraint ... is not validated (pin wins)` 警告(`:812-819`)が出るが、pin していなければ
**何も言われない**。→ **分類 10 の集約 note を新設**(§3.6)。

**帰結 3**: check 側では**意図的に `--lazy` を渡さず、`pkgs.git` も入れない**ことで抑止を証明する(§6.2)。
`lock-app.nix:155-158` は常に `--lazy` を渡すので実装上の分岐は不要。

### 3.5 マージへの組み込みと優先順位

優先順位(高い順): **force 集合(#24) > 実 prev > import シード > 通常解決**。

配置は **pin 凍結ブロック(`:574-581`)の直後、#23 のゲート(`:583-603`)の直前**。ゲートより前であることが
§3.4.1 の全根拠であり、pin 凍結ブロックとの前後は結果に影響しない(seed が効くのは prev が無いときだけで、
pin 凍結は `unchanged`= prev がある場合にしか発火しないので排他)。

```lua
if import_db and not (prev_plugins and prev_plugins[name] ~= nil) then
  local imp = import_db[name]
  if imp then
    local ok, why = seedable(entry, imp)
    if ok then
      entry.resolvedRef = imp.commit
      import_seeded[name] = true
      import_pinned[#import_pinned + 1] = { name = name, commit = imp.commit }
    else
      import_skipped[#import_skipped + 1] = { name = name, reason = why }
    end
  end
elseif import_db and import_db[name] then
  import_prev_blocked = import_prev_blocked + 1
end
```

**判定は `prev` ではなく生の `prev_plugins[name]` で行う(重要)。**
`:552` は `local prev = (prev_plugins and not force[name]) and prev_plugins[name] or nil` であり、
**`force[name]` が立ったエントリでも `prev` は nil になる**。`prev == nil` で判定すると
`--update foo --import-lazy-lock …` で foo が lazy-lock の古い commit に**巻き戻る** —— `--update` の意味が
反転する。CLI では併用を拒否する(§4.2)が、`resolve.lua` を手で叩く場合も含めて意味論が定義されている
必要がある。

- 「実 prev > import シード」の判定は **prev にエントリが存在するか**で行い、`prev.resolvedRef` が null でも
  ブロックする。null は「解決不要(追跡)」という nvimx の確定済みの決定であり、古い commit で上書きすれば
  追跡中のプラグインを黙って巻き戻すことになる。
- prev にあるが恒等性が破れているエントリ(`unchanged = false`)も seed しない。spec の編集はあらゆる過去の
  決定に勝つ、という #18 の原則をそのまま適用する。
- **2 回目以降の実行**: 初回 import 後は全プラグインが prev に載るため、同じフラグ付きで再実行しても seed は
  全て prev ブロックされ、出力は byte-identical。分類 4 の集約行で報告する。

`seedable` は `same_identity`(`:226-242`)の隣に置く小関数:

```lua
local function short_sha(s)
  return s:sub(1, 12)
end

-- Whether a lazy-lock.json entry may seed this plugin's resolvedRef (§3.4).
-- Returns true, or false plus the reason to report.
local function seedable(entry, imp)
  if not is_null(entry.commit) then
    local extra = ""
    if entry.commit ~= imp.commit then
      extra = (" (lazy-lock.json has %s)"):format(short_sha(imp.commit))
    end
    return false, ("the spec already fixes commit %s%s"):format(short_sha(entry.commit), extra)
  end
  local b = norm(entry.branch)
  if b and imp.branch and b ~= imp.branch then
    return false, ('the spec is on branch %q but lazy-lock.json recorded %q'):format(b, imp.branch)
  end
  return true
end
```

### 3.6 報告の分類と出力形式

**全て `note()`(`:268-270`。stderr のみ)で出し、`warnings` 配列(`plugins.json` に永続化)には入れない。**

- 理由 1: import は一度きりの操作であり、その回の事情を commit される `plugins.json` に焼き込むと、
  次の通常 lock で warnings が丸ごと消える無意味な diff が生まれる。`warnings` は「現在の spec について
  毎回導出される事実」(#18 契約 3)のためのもの。
- 理由 2: note にしておくことで **import 実行の出力とフラグ無し再 lock の出力が byte-identical** になる。
  ゴール 3 はこの性質そのものであり、`warn()` を使うと成立しない。
- stderr は lock-app の resolve.log 後出し機構(#22)に乗るので、`nix flake lock` の出力に流されず最後に必ず見える。

**決定性**: `raw.plugins` も `import_db` も `pairs()` で走査するため、**収集してからソートして出力する**
(`plugin_warnings` と同じ流儀)。分類順 → 分類内はプラグイン名昇順。

**メッセージ文字列(確定。`note()` が `[nvimx] ` を前置する)**

| # | 文字列 |
|---|---|
| 1 | `import: pinned <name> to <sha の先頭 12 桁>` |
| 2 | `import: skipped <name>: the spec already fixes commit <sha12>` / 食い違う場合は末尾に ` (lazy-lock.json has <sha12>)` |
| 3 | `import: skipped <name>: the spec is on branch "<b>" but lazy-lock.json recorded "<b'>"` |
| 3L | `import: skipped <name>: it is a local plugin (dev/dir), so there is nothing to pin` |
| 4 | `import: skipped <N> entries already decided by the existing lock`(N==1 のときは `entry`)— **集約 1 行** |
| 5 | `import: <name> is not in lazy-lock.json; it will resolve normally` |
| 6 | `import: ignored <name> (disabled in the config)` |
| 7 | `import: ignored <name> (not in the config)` / ヒントがあれば `import: ignored <name> (not in the config; did you mean "<x>"?)` |
| 8 | `import: lazy.nvim itself is not imported (nvimx pins lazy.nvim through its own flake input)` |
| 9 | `import: invalid entry <name> in lazy-lock.json: <理由>` |
| 10 | `import: <PREFIX> "<c>" is not validated for <N> plugin(s) pinned from lazy-lock.json (run nvimx-lock --update <name> to resolve it again): a.nvim, b.nvim` |
| S | `import: <N> pinned, <M> skipped, <K> ignored, <L> not in lazy-lock.json` |
| 空 | `import: lazy-lock.json has no entries; nothing to seed` |

分類 9 の `<理由>`(4 種):
- `value is not an object`
- `no commit`
- `commit "<v>" is not a 40-hex sha`
- `key is not a plugin name`(トップレベルが配列だった場合など、キーが文字列でない)

分類 10 は `versioned`(`:332` 宣言、`:604-609` で埋まり、`:809-811` で name 昇順に sort 済み)を再利用し、
`import_seeded[name]` が真かつ `is_true(entry.pin)` が偽のものだけを制約文字列ごとに集約する
(pin のものは既存の "pin wins" 警告が担当するので**除外**。二重に言わない)。
制約文字列は昇順、名前も昇順。

**`<PREFIX>` は既存の慣習に合わせる(レビュー指摘)**: `resolve.lua:816` が
`the config-wide version constraint %q` と `version constraint %q` を `from_defaults` で使い分けている。
分類 10 も同じ分岐にし、`defaults.version` 由来なら `the config-wide version constraint`、
明示なら `version constraint` を使う。集約キーは「制約文字列 + from_defaults」の対にする
(同じ `"*"` でも由来が違えば別行)。
**`<name>` は文字どおりのプレースホルダ**であり、具体名には置換しない(「`--update <name>` を実行せよ」
という案内文の一部。実際の名前は同じ行の末尾に列挙されている)。

**カウントの定義(不変条件)**

- `pinned` = 分類 1 の件数
- `skipped` = 分類 2 + 3 + 3L の件数 + 分類 4 の件数(`import_prev_blocked`)
- `ignored` = 分類 6 + 7 + 8 + 9 の件数
- `not in lazy-lock.json` = 分類 5 の件数(**lazy-lock 側ではなく config 側の数なので合計には入らない**)

→ **`pinned + skipped + ignored == lazy-lock.json のトップレベルキー総数`** が常に成り立つ。
§6.2 でこれを jq で assert する(「黙って捨てられるエントリが 1 つも無い」の機械的証明)。

**分類器には明示的な `else` を置く(レビュー指摘)**: §5.1 step 8 の分類ループが
「raw.plugins に居る ∧ dev/dir でない ∧ seed も skip もされなかった」名前を取りこぼすと、不変条件が
黙って崩れる。理論上は lazy の `Spec` が `plugins` と `disabled` を排他に保つので起きないが、
**取りこぼしを分類 7 相当の bucket に落として必ず数える**こと。数が合わないことを検知できる形にする。

**分類 5 と分類 9 の関係(明示的な設計判断)**: lazy-lock の壊れたエントリ(分類 9)の名前が
config 側にも存在する場合、そのプラグインは分類 9 で報告済みなので**分類 5 の
「lazy-lock.json に無い」行は出さない**(`not bad_names[rn]` フィルタ)。同じプラグインについて
「壊れている」と「無い」を二重に言わないための判断であり、意図的である。

## 4. 既存機能との関係

### 4.1 #23(semver)との相互作用

- ゲート条件(`:595`)と seed 位置(`:582`)の関係が §3.4.1 のとおり成立する。**#23 側の変更は不要**。
- `defaults.version` ユーザーの移行では初回 lock が完全にオフラインで済む。代償は「制約が検証されないまま
  固定される」ことで、分類 10 の集約 note で可視化する。
- `pin = true` + `version` + import では既存の `pinned; version constraint ... is not validated (pin wins)`
  警告(`:812-819`)が出る。**これは `warn_plugin` なので `plugins.json` の `warnings` に入る**。
  したがってメインの fixture には pin+version の組み合わせを入れない(`warnings == []` を主張したいため)。
  §6.2 step 9 で jq 派生 fixture として別に検証する。

### 4.2 #24(`--update`)との相互作用 — 併用は拒否

**`--import-lazy-lock` と `--update` の同時指定は lock-app が usage エラーで拒否する。**

1. **どう転んでも意味のある動作にならない。** `lock-app.nix:71-80` のガードにより、`--update` は
   `$out/plugins.json` と `$out/flake.lock` の両方が無ければ exit 2。逆に `plugins.json` が存在すれば
   import は全件 prev ブロックされる(§3.5)。つまり併用は「exit 2」か「`--import-lazy-lock` が完全な no-op」の
   二択にしかならない。黙って no-op にするのは誤操作に弱い。
2. **意図が矛盾している。** 「古い lock に合わせて固定する」と「今の HEAD へ動かす」を 1 回のコマンドに
   混ぜる理由がない。2 回に分ければ両方の意図が明示される。
3. `lock-app.nix:203-207` が本件に対して除外の申し送りを置いている。

実装は `lock-app.nix:61-69` の bare/named 拒否の**直後**に 1 分岐。`[ -n "$config" ]` チェック(`:70`)より
前に置くことで、`checks` から `nix` を一切呼ばずに到達できる(§6.2 step 12)。

**resolve.lua 側は拒否しない。** 併用されても意味論が定義されているように §3.5 の判定を生の
`prev_plugins[name]` で書く(force > import を保証する)。これは防御であり、CLI の拒否と二重に持つ。

import で seed された `resolvedRef` は、`--update`(全体)または `--update <name>` が force 集合に入れた
時点で破棄され、通常追跡(+ #23 の解決)に戻る。**本件側の追加実装は不要**。

### 4.3 #49(spec に `folke/lazy.nvim` を書くと synthetic な `lazy-nvim` と衝突)との関係

**#25 は #49 に依存しない。**

- §1.4 のとおり **lazy-lock.json には `lazy.nvim` のエントリがほぼ必ず入るが、nvimx の raw-spec には入らない**。
  したがって通常のユーザーでは `lazy.nvim` は**単なる未マッチエントリ**として現れ、#49 の衝突経路には触れない。
- ただし分類 7(`not in the config`)に落とすと全ユーザーが毎回見る雑音になり、しかも誤解を招く。
  → **専用の分類 8**。分類 8 は `raw.plugins["lazy.nvim"]` が**存在しない**ときにのみ出す。
- ユーザーが spec に `folke/lazy.nvim` を書いていた場合(= #49 の条件)は `raw.plugins["lazy.nvim"]` が
  存在するので、import は**他のプラグインと同じ規則で普通に照合・seed する**(分類 8 は出さない)。
  その実行はこのあと `nix flake lock` の段階で #49 の重複 input により落ちるが、それは
  **import の有無に関わらず落ちる既存の破綻**であり、本件は悪化させない。
- **`lazyNvim` synthetic エントリへの seed はしない**(スコープ外)。synthetic エントリは
  `{ inputName, synthetic, source }` の 3 キー(`resolve.lua:853-857`)で `resolvedRef` の置き場所が無く、
  genflake も `input_url({ source = db.lazyNvim.source })`(`genflake.lua:72`)で source しか渡さない。
  `lock-app.nix:85-86` の既存 TODO(「既存 lock が lazy.nvim を pin していればそれを seed に使う」)と同じ土俵。
  **別 issue(#32 系)に委ねる。**
- **#49 への申し送り**: #49 が「ユーザーの `lazy.nvim` を synthetic input と共有する」形で解決した場合、
  分類 8 の出し分け条件(`raw.plugins["lazy.nvim"]` の有無)と共有 input への seed 可否を読み直すこと。
  #49 の issue 本文にこの申し送りを追記する。

## 5. 実装手順

### 5.1 `lua/nvimx/resolve.lua`

現在の行番号を併記する。**必ず下から順(行番号の大きい順)に当てるか、シンボルで位置決めすること。**

1. **ヘッダの Usage コメント(`:3-6`)**: `[--update [<name>]]... [--update-plan <path>]` の行に
   `[--import-lazy-lock <lazy-lock.json>]` を追記。併せて `--lazy` の説明段落(`:12-14`)の後に 2〜3 行、
   「`--import-lazy-lock` は lazy.nvim の lock を読んで、prev に決定が無いプラグインの `resolvedRef` にだけ
   その commit を種として書く。`commit` / `branch` には書かない(spec 恒等性を壊すため)」を追加。

2. **`usage()`(`:21-28`)**: 文字列末尾に `[--import-lazy-lock <path>]` を追記。

3. **フラグループ**:
   - `:33` の `local raw_path, out_path, prev_path, lock_path, lazy_path, update_plan_path` に `, import_path` を追加。
   - `:43` の条件に `or a == "--import-lazy-lock"` を追加。
   - `:49-57` の if-chain に `elseif a == "--import-lazy-lock" then import_path = value` を
     `--lazy` の分岐の後・`else`(= `--update-plan`)の前に挿入。

4. **`read_json` の advice 引数化(`:98-117`)**: §3.2 のとおり。`JSON_ADVICE_LOCK` / `JSON_ADVICE_IMPORT` を
   `read_json` の直前に定数として置く。**既存メッセージのバイト列は変えない。**

5. **import ファイルのロード(prev ロード `:149-166` の直後、`locked_rev` の `do` ブロック `:168` の直前)**:
   §3.2 のパースを実装。`import_db`(name → `{ commit, branch }`)と `import_bad`(`{ name, reason }` の配列)を作る。
   `is_frozen_rev`(`:139-141`)より後なので使える。ここではまだ何も出力しない。
   併せて収集用の状態も宣言する:
   ```lua
   local import_seeded = {}
   local import_pinned = {}
   local import_skipped = {}
   local import_prev_blocked = 0
   ```

6. **`short_sha` / `seedable`(`same_identity` の直後 `:243` 付近)**: §3.5 のコードをそのまま。

7. **メインループへの seed 分岐(pin 凍結ブロック `:574-581` の直後、#23 ゲートのコメント `:583` の直前)**:
   §3.5 のコードをそのまま。コメントで (a) 生の `prev_plugins[name]` を使う理由、
   (b) `resolvedRef` に書く理由、(c) #23 ゲートより前に置く理由の 3 点を明記する。

8. **報告ブロック(`plugin_warnings` の emit ループ `:821-832` の直後、`report_resolve_errors()` のコメント
   `:834` の直前)**: `if import_db then ... end` で囲み、以下を順に出す。
   `versioned` はこの時点で `:809-811` により name 昇順に sort 済みなので、分類 10 はそのまま走査してよい。

   ```lua
   -- --import-lazy-lock's report (#25). Everything here is note() -- stderr only, never the
   -- warnings array: an import is a one-shot migration, and baking this run's circumstances into
   -- the committed plugins.json would only produce a diff that the next plain lock deletes again.
   -- Collected above rather than emitted inline, because both raw.plugins and import_db are walked
   -- with pairs(): sorted here so two identical runs print identical stderr.
   ```

   実装スケッチ:
   ```lua
   if import_db then
     local raw_plugins = raw.plugins or {}
     local disabled_set = {}
     for _, dn in ipairs(raw.disabled or {}) do
       disabled_set[dn] = true
     end
     local bad_names = {}
     for _, b in ipairs(import_bad) do
       bad_names[b.name] = true
     end
     -- lazy-lock side: everything import_db holds that the merge loop above never saw
     local ignored_disabled, ignored_missing, local_skipped = {}, {}, {}
     local lazy_self = false
     local lock_names = {}
     for n in pairs(import_db) do
       lock_names[#lock_names + 1] = n
     end
     table.sort(lock_names)
     local input_name_lookup = {}
     for rn in pairs(raw_plugins) do
       input_name_lookup[to_input_name(rn)] = rn
     end
     for _, n in ipairs(lock_names) do
       local p = raw_plugins[n]
       if p == nil then
         if n == "lazy.nvim" then
           lazy_self = true
         elseif disabled_set[n] then
           ignored_disabled[#ignored_disabled + 1] = n
         else
           ignored_missing[#ignored_missing + 1] = { name = n, hint = input_name_lookup[to_input_name(n)] }
         end
       elseif p.dev or p.dir then
         local_skipped[#local_skipped + 1] = n
       end
     end
     -- config side
     local not_in_lock = {}
     for rn, p in pairs(raw_plugins) do
       if not (p.dev or p.dir) and import_db[rn] == nil and not bad_names[rn] then
         not_in_lock[#not_in_lock + 1] = rn
       end
     end
     table.sort(not_in_lock)
     ... -- 各配列を name 昇順に sort して分類 1 → 10 → summary の順に note()
   end
   ```

   - 分類 1: `import_pinned` を name 昇順に sort して 1 行ずつ。
   - 分類 2/3: `import_skipped` を name 昇順に sort して `import: skipped <name>: <reason>`。
   - 分類 3L: `local_skipped` を sort。
   - 分類 4: `import_prev_blocked > 0` のとき 1 行。
   - 分類 5: `not_in_lock`。
   - 分類 6: `ignored_disabled`。
   - 分類 7: `ignored_missing`(ヒント付き)。
   - 分類 8: `lazy_self` のとき 1 行。
   - 分類 9: `import_bad` を name 昇順に sort。
   - 分類 10: `versioned` を走査 → `by_constraint[c] = { names }` → 制約昇順で 1 行ずつ。
   - summary: `import: %d pinned, %d skipped, %d ignored, %d not in lazy-lock.json`。
   - `import_db` が空 かつ `#import_bad == 0` のときは、分類ループの前に
     `import: lazy-lock.json has no entries; nothing to seed` を出して残りをスキップしてよい
     (ただし**分類 5 と summary は出す**。config 側の全プラグインが「lazy-lock に無い」ため)。

9. **新規ファイルは作らない。** import は resolve.lua の I/O と密結合しており、`version.lua` のような
   純関数層にならない。stylua(`stylua.toml`: 2-space / double quotes / 120 桁)/ luacheck clean であること。

### 5.2 `nix/lib/lock-app.nix`

1. **`:3`** — `# TODO (Phase 6): --import-lazy-lock` の行を**削除**。
2. **`usage()`(`:22-25`)** — 文字列を
   `usage: nvimx-lock --config <configDir> --out <lockDir> [--update [name...] | --import-lazy-lock [path]]` に。
3. **変数初期化(`:27-31`)** — `import_mode=0` / `import_path=""` を追加。
4. **パーサ(`:32-60`)** — `--update` ケース(`:42-55`)の後に §3.1 のケースを追加。
5. **併用拒否(`:69` の `fi` の直後、`:70` の必須チェックの前)**:
   ```bash
   # --import-lazy-lock and --update are opposite intents ("hold still at lazy's commits" vs.
   # "move to today's HEAD"), and combining them can only ever produce one of two useless
   # outcomes: the --update guard below rejects the run outright when there is no existing lock,
   # or there is one and every seed is blocked by it, making --import-lazy-lock a silent no-op.
   # Rejecting here -- before --config/--out are even validated -- keeps this provable in
   # checks.resolve-import-lazy-lock without ever invoking nix.
   if [ "$import_mode" -eq 1 ] && [ "$update_mode" -eq 1 ]; then
     echo "nvimx-lock: --import-lazy-lock cannot be combined with --update; run them as two separate locks" >&2
     usage
   fi
   ```
6. **既定パス確定と存在チェック(`:81` の `config=$(realpath "$config")` の直後、`:82` の `mkdir -p "$out"` の前)**:
   ```bash
   # --import-lazy-lock [path] (#25): the default lives next to the config, so it can only be
   # resolved once $config is absolute. Checked before `mkdir -p "$out"` for the same reason the
   # --update guard above is: a run that fails this must not leave an empty lock directory behind.
   # A missing file is fatal rather than a silent fallback to a plain lock -- that fallback would
   # move every plugin to today's HEAD, which is the exact accident this flag exists to prevent.
   if [ "$import_mode" -eq 1 ]; then
     [ -n "$import_path" ] || import_path="$config/lazy-lock.json"
     if [ ! -f "$import_path" ]; then
       echo "nvimx-lock: no lazy-lock.json at $import_path" >&2
       exit 2
     fi
     import_path=$(realpath "$import_path")
   fi
   ```
7. **`resolve_args`(`:129-147`)** — `--update` のブロック(`:136-147`)の後に:
   ```bash
   if [ "$import_mode" -eq 1 ]; then
     resolve_args+=(--import-lazy-lock "$import_path")
   fi
   ```
8. **収束パス(`:203-211`)** — **呼び出し自体は変更なし**。`:202-207` の申し送りコメント(#25 に触れているのは `:205-207`)の最後の 2 文
   (`#25's --import-lazy-lock will need this same exclusion ...`)を、実装済みの事実に差し替える:
   ```
   # --import-lazy-lock (#25) is deliberately not passed here either, for a different reason: this
   # pass gets --prev pointing at the plugins.json the first resolve just wrote, so every plugin
   # already has a previous decision and every seed would be blocked anyway. Passing it would be a
   # no-op, so this call stays exactly as it is rather than being restructured to share resolve_args.
   ```
9. `writeShellApplication` は `set -euo pipefail` + shellcheck を掛けるので、変数はすべて quote すること。

### 5.3 ドキュメント

#### 5.3.1 `README.md` — `## Usage` の末尾(`:112` の直後、`## Options`(`:114`)の直前)に新設

以下をそのまま挿入する:

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
         different `branch`); the spec wins
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
    - The import does not check version constraints. If your spec uses `version` (or
      `defaults = { version = "*" }`), the imported commit is taken as-is and the run reports
      `import: version constraint ... is not validated for N plugin(s) pinned from lazy-lock.json`.
      That is deliberate: the whole migration then needs no network at all, because lazy already
      resolved those constraints for you. `nvimx-lock --update <name>` resolves one for real whenever
      you want it checked again.
    - `lazy.nvim` itself is not imported: nvimx pins it through its own flake input, so the entry
      `lazy-lock.json` has for it is reported and skipped.
    - For a plugin on a non-GitHub git URL whose spec names no `branch`, the imported commit becomes
      `git+<url>?rev=<sha>` with no ref. Most servers serve that fine, but one that refuses to serve an
      unadvertised object will fail at `nix flake lock`, naming the input. Adding `branch = "..."` to
      that plugin's spec fixes it.

#### 5.3.2 `templates/default/README.md`

`## Adding and updating plugins` のリスト(`:24-29`)の末尾に 1 項追加:

    - Coming from plain lazy.nvim: put your `lazy-lock.json` next to `init.lua`, `git add` it, and run
      the first lock with `--import-lazy-lock` — every plugin is then pinned to the commit lazy already
      had, so nothing moves during the migration. See "Migrating from lazy.nvim" in the nvimx README

#### 5.3.3 `docs/architecture.md`

- `:82` — `U->>L: nvimx-lock [--update | --import-lazy-lock]`(併用不可を図でも表す)
- `:141-142` — `[3] Resolution` の CLI 行に `[--import-lazy-lock <lazy-lock.json>]` を追記
- `:236-244` の URL mapping 表(見出しは `:234`)の直後(`:248` の pin+version caveat の隣)に 1 段落:
  「import された `resolvedRef` は pin 由来の 40-hex 凍結と同じ形をしており、`is_frozen_rev` から見て区別が
  付かない。したがって `pin = true` のまま import したプラグインの `pin` を外すと、その凍結も一緒に落ちる」
  および「spec が `tag` を持つ git type のプラグインに import すると URL は
  `?ref=refs/tags/<t>&rev=<sha>` になる」
- `:262` — 実装済みの意味論に差し替え:
  `- `nvimx-lock --import-lazy-lock [path]` (#25): seeds each plugin's `resolvedRef` from the `commit` an existing lazy-lock.json records (defaulting to `<configDir>/lazy-lock.json`), so a migration from plain lazy.nvim pins exactly the plugin set the user is already running. Only plugins the previous lock has no decision about at all are seeded -- an existing `plugins.json` entry always wins, so a second import is a no-op. The seed goes into `resolvedRef`, never into `commit`/`branch`: those are part of the spec identity, so a seed written there would be discarded by the very next lock. A seeded `resolvedRef` also closes the semver gate, which is what makes a `defaults.version` migration need no network at all -- the constraint is not validated on that run, and the report says so. Cannot be combined with `--update`. Returns to normal tracking at `--update` time`
- `:439-441`(First run)— `--import-lazy-lock` はパス省略可であることを補足
- `:478` fixtures 一覧に `import-lazy-lock` を追加
- `:487` checks 一覧に `resolve-import-lazy-lock` を追加
- `:519` Phase 6 の一覧を `--import-lazy-lock (#25)` に
- `## Edge cases and explicit limitations` の表(`:494-508`)に 1 行:
  `| lazy-lock.json entry with no matching plugin | reported (with a "did you mean" hint when the name only differs by input-name normalization) and skipped, never silently dropped |`

### 5.4 テスト一式

- `tests/fixtures/import-lazy-lock/` を追加(§6.1)。
- `flake.nix` の `checks` に `resolve-import-lazy-lock` を追加。挿入位置は
  **`update-summary` の終端 `:2193`(`'';`)の直後、`checks` を閉じる `:2194` の `}` の直前**。

## 6. テスト

### 6.1 フィクスチャ `tests/fixtures/import-lazy-lock/`

```
tests/fixtures/import-lazy-lock/
  raw-spec.json            # 手書き
  lazy-lock.json           # 実フォーマット準拠(キーソート済み)
  lazy-lock-broken.json    # JSON として壊れたファイル(ハードエラー用)
  lazy-lock-empty.json     # `{}`(「seed するものが無い」note の検証用)
  lazy-lock-array.json     # `[]`(トップレベル配列 → 分類 9 `key is not a plugin name` の検証用)
  prev.json                # prev 優先の検証用 plugins.json
  golden/
    imported.plugins.json  # raw-spec + lazy-lock を import した期待出力
```

raw-spec を手書きにするのは #18 §6.1 / #23 §6.2 と同じ理由(場合分けを extract の揺れから切り離す)。
**全プラグインの url を到達不能な固定パス(`file:///nvimx-nonexistent/<name>` / 実在しない github owner)にする**。
`ver.nvim` / `defver.nvim` は「ls-remote が飛べば必ず fatal」になるので、**exit 0 であること自体が
#23 ゲート抑止の証明**になる。

#### `raw-spec.json`

```json
{
  "_comment": [
    "Hand-written raw-spec.json (the shape extract.lua dumps), used by",
    "checks.resolve-import-lazy-lock. Hand-written rather than extracted so the seed cases below",
    "are exactly the ones the test means to cover.",
    "Every url is deliberately unreachable: nothing here is ever fetched, and ver.nvim /",
    "defver.nvim exist to prove that a seeded resolvedRef closes #23's semver gate -- if the gate",
    "ever fired, ls-remote would fail on these urls (or on git being absent from the check's PATH)",
    "and the whole resolve would exit non-zero. exit 0 *is* the assertion.",
    "No plugin here combines pin with version on purpose: that pair produces a real warn_plugin",
    "entry in plugins.json, and this fixture's golden asserts warnings == []. That case is covered",
    "by a jq-derived variant inside the check instead."
  ],
  "disabled": ["disabled-me.nvim"],
  "notifs": [],
  "plugins": {
    "plain.nvim": {
      "name": "plain.nvim",
      "short": "o/plain.nvim",
      "url": "https://github.com/o/plain.nvim.git"
    },
    "git.nvim": {
      "name": "git.nvim",
      "url": "file:///nvimx-nonexistent/git.nvim",
      "branch": "main"
    },
    "ver.nvim": {
      "name": "ver.nvim",
      "url": "file:///nvimx-nonexistent/ver.nvim",
      "version": "^1.2"
    },
    "defver.nvim": {
      "name": "defver.nvim",
      "url": "file:///nvimx-nonexistent/defver.nvim",
      "version": "*",
      "versionFromDefaults": true
    },
    "tag.nvim": {
      "name": "tag.nvim",
      "url": "file:///nvimx-nonexistent/tag.nvim",
      "tag": "v1.0.0"
    },
    "pinned.nvim": {
      "name": "pinned.nvim",
      "url": "file:///nvimx-nonexistent/pinned.nvim",
      "pin": true
    },
    "commit.nvim": {
      "name": "commit.nvim",
      "url": "file:///nvimx-nonexistent/commit.nvim",
      "commit": "dddddddddddddddddddddddddddddddddddddddd"
    },
    "branchy.nvim": {
      "name": "branchy.nvim",
      "url": "file:///nvimx-nonexistent/branchy.nvim",
      "branch": "master"
    },
    "only-here.nvim": {
      "name": "only-here.nvim",
      "short": "o/only-here.nvim",
      "url": "https://github.com/o/only-here.nvim.git"
    },
    "local.nvim": {
      "name": "local.nvim",
      "dev": true,
      "dir": "/some/local/path"
    }
  }
}
```

#### `lazy-lock.json`

キーは lazy と同じく昇順。`plain.nvim` だけ `branch` キーを持たない(「`branch` は任意」の実証)。

```json
{
  "badsha.nvim": { "branch": "main", "commit": "not-a-sha" },
  "branchy.nvim": { "branch": "main", "commit": "6666666666666666666666666666666666666666" },
  "commit.nvim": { "branch": "main", "commit": "5555555555555555555555555555555555555555" },
  "defver.nvim": { "branch": "main", "commit": "3333333333333333333333333333333333333333" },
  "disabled-me.nvim": { "branch": "main", "commit": "8888888888888888888888888888888888888888" },
  "ghost.nvim": { "branch": "main", "commit": "9999999999999999999999999999999999999999" },
  "git-nvim": { "branch": "main", "commit": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" },
  "git.nvim": { "branch": "main", "commit": "4444444444444444444444444444444444444444" },
  "lazy.nvim": { "branch": "main", "commit": "0000000000000000000000000000000000000000" },
  "local.nvim": { "branch": "main", "commit": "cccccccccccccccccccccccccccccccccccccccc" },
  "nullentry.nvim": null,
  "pinned.nvim": { "branch": "main", "commit": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" },
  "plain.nvim": { "commit": "7777777777777777777777777777777777777777" },
  "tag.nvim": { "branch": "main", "commit": "2222222222222222222222222222222222222222" },
  "ver.nvim": { "branch": "main", "commit": "1111111111111111111111111111111111111111" }
}
```

**エントリ総数 15**。期待される内訳:

| エントリ | 分類 | 備考 |
|---|---|---|
| `plain.nvim` | 1 | github type、`branch` キー無し |
| `git.nvim` | 1 | git type、spec branch と一致 |
| `ver.nvim` | 1 | 明示 `version` + 分類 10 |
| `defver.nvim` | 1 | `versionFromDefaults` + 分類 10 |
| `tag.nvim` | 1 | `resolvedRef` > `tag` |
| `pinned.nvim` | 1 | `pin = true` でも seed される |
| `commit.nvim` | 2 | 値が食い違うので `(lazy-lock.json has 555555555555)` が付く |
| `branchy.nvim` | 3 | spec `master` vs lock `main` |
| `local.nvim` | 3L | dev/dir |
| `disabled-me.nvim` | 6 | raw-spec の `disabled` にある |
| `ghost.nvim` | 7 | ヒント無し |
| `git-nvim` | 7 | `did you mean "git.nvim"?` |
| `lazy.nvim` | 8 | |
| `badsha.nvim` | 9 | `commit "not-a-sha" is not a 40-hex sha` |
| `nullentry.nvim` | 9 | `value is not an object` |

config 側で lazy-lock に無いもの = `only-here.nvim`(分類 5)1 件。

**summary の期待値**: `import: 6 pinned, 3 skipped, 6 ignored, 1 not in lazy-lock.json`
(6 + 3 + 6 = 15 = エントリ総数、§3.6 の不変条件)。

**stderr の期待行数**: 6(分類1) + 1(2) + 1(3) + 1(3L) + 1(5) + 1(6) + 2(7) + 1(8) + 2(9) + 2(10) + 1(summary)
= **19 行**、すべて `[nvimx] import: ` 始まり。それ以外の行は 1 行も出てはならない。

#### `prev.json`

`schemaVersion: 1` の plugins.json。`plain.nvim`(`resolvedRef` を lazy-lock と違う値に)と
`tag.nvim`(`resolvedRef: null`)の 2 件だけを持つ。`source` と恒等性フィールドは `raw-spec.json` から
`parse_source` が導く値と**完全一致**させること(一致しないと `same_identity` が偽になり、
このフィクスチャが検証したい「prev が seed をブロックする」経路に入らない)。

```json
{
  "_comment": [
    "A plugins.json holding decisions for two of raw-spec.json's plugins, used to prove that an",
    "existing lock always wins over the imported file. tag.nvim's resolvedRef is deliberately null:",
    "null is a decision too (\"track this ref, nothing to pin\"), so the import must not overwrite it",
    "either. `source` must match what parse_source derives from raw-spec.json exactly, or",
    "same_identity would fail and this fixture would test nothing."
  ],
  "lazyNvim": {
    "inputName": "lazy-nvim",
    "source": { "owner": "folke", "repo": "lazy.nvim", "type": "github" },
    "synthetic": true
  },
  "localPlugins": {},
  "plugins": {
    "plain.nvim": {
      "branch": null, "build": { "kind": "none" }, "commit": null, "dependencies": [],
      "inputName": "plain-nvim", "pin": null,
      "resolvedRef": "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee",
      "source": { "owner": "o", "repo": "plain.nvim", "type": "github" },
      "tag": null, "version": null
    },
    "tag.nvim": {
      "branch": null, "build": { "kind": "none" }, "commit": null, "dependencies": [],
      "inputName": "tag-nvim", "pin": null, "resolvedRef": null,
      "source": { "type": "git", "url": "file:///nvimx-nonexistent/tag.nvim" },
      "tag": "v1.0.0", "version": null
    }
  },
  "schemaVersion": 1,
  "warnings": []
}
```

#### `lazy-lock-broken.json`

```
{
  "plain.nvim": { "branch": "main", "commit":
```

(閉じ括弧なし。`vim.json.decode` が失敗する。)

#### `golden/imported.plugins.json`

step 1 の出力そのもの。実装後に `nvim -l resolve.lua ... > golden` で生成し、**以下を目視レビューしてから
コミットする**:

- `plain.nvim.resolvedRef == "7777777777777777777777777777777777777777"`
- `git.nvim.resolvedRef == "4444444444444444444444444444444444444444"`
- `ver.nvim.resolvedRef == "1111111111111111111111111111111111111111"`、`version == "^1.2"`
- `defver.nvim.resolvedRef == "3333333333333333333333333333333333333333"`、`version == "*"`
- `tag.nvim.resolvedRef == "2222222222222222222222222222222222222222"`、`tag == "v1.0.0"`
- `pinned.nvim.resolvedRef == "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"`、`pin == true`
- `commit.nvim.resolvedRef == null`、`commit == "dddd…"`
- `branchy.nvim.resolvedRef == null`、`only-here.nvim.resolvedRef == null`
- `localPlugins == { "local.nvim": { "dir": "/some/local/path" } }`
- **`warnings == []`**

### 6.2 `checks.resolve-import-lazy-lock`(新設)

`flake.nix:2193` の直後に挿入。`resolve-update`(`:1885-2042`)と同型だが、
**`pkgs.git` を意図的に入れない**(`nvimxLib.lockApp` は自前で `pkgs.git` を `runtimeInputs` に持つが、
それはラッパの PATH であって check の PATH には漏れない)。`--lazy` も渡さない。完全オフライン。

```nix
# Offline coverage of `--import-lazy-lock` (#25). Deliberately without pkgs.git: resolve.lua's
# semver path fails outright when git is not on PATH, so "the resolve exits 0" is itself the
# proof that a seeded resolvedRef closed #23's gate and no ls-remote was ever attempted. Every
# fixture url is unreachable on top of that, for the same reason. --lazy is never passed either,
# which is the other half of the same statement: a migrating config needs neither.
resolve-import-lazy-lock =
  pkgs.runCommand "resolve-import-lazy-lock"
    {
      nativeBuildInputs = [
        pkgs.neovim-unwrapped
        pkgs.jq
        nvimxLib.lockApp
      ];
    }
    ''
      export HOME=$TMPDIR
      lua=${./lua/nvimx}
      fx=${./tests/fixtures/import-lazy-lock}
      ...
    '';
```

**assert 一覧(順に実装する)**

1. **golden + 正確な pin**
   ```
   nvim -l $lua/resolve.lua $fx/raw-spec.json out1.json --import-lazy-lock $fx/lazy-lock.json \
     > out1.out 2> out1.log
   diff -u $fx/golden/imported.plugins.json out1.json
   ```
   **stdout も別ファイルに取る**(step 2 で使う)。
   さらに **golden の書き間違いに対する独立検証**として、`lazy-lock.json` 自身から jq で読み出した commit と
   `out1.json` の `resolvedRef` を 1 件ずつ突き合わせる:
   ```
   for n in plain.nvim git.nvim ver.nvim defver.nvim tag.nvim pinned.nvim; do
     want=$(jq -r --arg n "$n" '.[$n].commit' $fx/lazy-lock.json)
     got=$(jq -r --arg n "$n" '.plugins[$n].resolvedRef' out1.json)
     [ "$want" = "$got" ]
   done
   ```

2. **#23 ゲート抑止**: 主たる証明は**手順 1 が exit 0 であること**(`set -e` により自動)。
   `--lazy` を渡していないので、ゲートが 1 件でも発火していれば `resolve.lua:633` の
   `a version constraint needs --lazy <lazy.nvim path>` で fatal になる。仮に `--lazy` があったとしても
   git 不在と到達不能 url で必ず落ちる。**exit 0 が主張そのもの**である。

   補助の assert:
   ```
   ! grep -q 'resolving version constraints' out1.out   # 進捗行は stdout(resolve.lua:686)
   ! grep -q 'ls-remote' out1.log
   ```
   **レビュー指摘**: 旧案の「`out1.log` から `resolving version constraints` を grep する」は
   進捗行が **stdout** に出るため常に真になる空虚な assert だった。`--lazy` という文字列も
   どこにも印字されないので同様。上記のとおり stdout 側で見る。

3. **`warnings == []`**: `jq -e '.warnings == []' out1.json`。報告が lock に混入していないことの直接検証。

4. **seed 除外**: `commit.nvim` / `branchy.nvim` / `only-here.nvim` の `resolvedRef` が null。
   `commit.nvim.commit == "dddd…"` のまま。

5. **flake.nix への到達**: `nvim -l $lua/genflake.lua out1.json flake1.nix` して grep(**完全一致文字列**):
   - `url = "github:o/plain.nvim/7777777777777777777777777777777777777777";`
   - `url = "git+file:///nvimx-nonexistent/git.nvim?ref=main&rev=4444444444444444444444444444444444444444";`
   - `url = "git+file:///nvimx-nonexistent/tag.nvim?ref=refs/tags/v1.0.0&rev=2222222222222222222222222222222222222222";`
     (§7 の「tag + seed で ref と rev の両方が付く」の固定)
   - `url = "git+file:///nvimx-nonexistent/commit.nvim?rev=dddddddddddddddddddddddddddddddddddddddd";`
     (spec の `commit` が勝ち、seed が入り込んでいない)

6. **報告の網羅**: `out1.log` を grep で分類 1〜10 + summary を 1 つずつ確認。特に:
   - `grep -q '^\[nvimx\] import: pinned plain.nvim to 777777777777$'`
   - `grep -q 'import: skipped commit.nvim: the spec already fixes commit dddddddddddd (lazy-lock.json has 555555555555)$'`
   - `grep -q 'import: skipped branchy.nvim: the spec is on branch "master" but lazy-lock.json recorded "main"$'`
   - `grep -q 'import: skipped local.nvim: it is a local plugin'`
   - `grep -q 'import: only-here.nvim is not in lazy-lock.json; it will resolve normally$'`
   - `grep -q 'import: ignored disabled-me.nvim (disabled in the config)$'`
   - `grep -q 'import: ignored ghost.nvim (not in the config)$'`
   - `grep -q 'import: ignored git-nvim (not in the config; did you mean "git.nvim"?)$'`
   - `grep -q 'import: lazy.nvim itself is not imported'`
   - `grep -q 'import: invalid entry badsha.nvim in lazy-lock.json: commit "not-a-sha" is not a 40-hex sha$'`
   - `grep -q 'import: invalid entry nullentry.nvim in lazy-lock.json: value is not an object$'`
   - `grep -q 'import: version constraint "\^1.2" is not validated for 1 plugin(s) pinned from lazy-lock.json'`
   - `grep -q 'import: version constraint "\*" is not validated for 1 plugin(s) pinned from lazy-lock.json'`
   - `grep -q 'import: 6 pinned, 3 skipped, 6 ignored, 1 not in lazy-lock.json$'`
   - **行数**: `[ "$(grep -c '^\[nvimx\] import: ' out1.log)" -eq 19 ]` かつ `[ "$(wc -l < out1.log)" -eq 19 ]`
     (想定外の報告が 1 行も無いことの証明。`checks.resolve-build-warnings` の `n=$(grep -c …)` と同じ手法)
   - **不変条件**: `pinned + skipped + ignored` を summary 行から抜き出し、
     `jq 'keys | length' $fx/lazy-lock.json`(= 15)と一致すること。

7. **決定性**: 同じコマンドをもう一度走らせて `diff -u out1.log out1b.log` が空。

8. **prev 優先**:
   ```
   nvim -l $lua/resolve.lua $fx/raw-spec.json out2.json --prev $fx/prev.json --import-lazy-lock $fx/lazy-lock.json 2> out2.log
   jq -e '.plugins["plain.nvim"].resolvedRef == "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"' out2.json
   jq -e '.plugins["tag.nvim"].resolvedRef == null' out2.json
   grep -q 'import: skipped 2 entries already decided by the existing lock$' out2.log
   ```
   **`resolvedRef: null` の prev エントリ(`tag.nvim`)も seed されない**ことが要点(§3.5)。

9. **pin + version(分類 10 の除外)**:
   ```
   jq '.plugins["pinned.nvim"].version = "^2.0"' $fx/raw-spec.json > raw-spec-pinver.json
   nvim -l $lua/resolve.lua raw-spec-pinver.json out3.json --import-lazy-lock $fx/lazy-lock.json 2> out3.log
   jq -e '.plugins["pinned.nvim"].resolvedRef == "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"' out3.json
   grep -q 'pinned; version constraint "\^2.0" is not validated (pin wins)' out3.log
   # 分類 10 は pinned.nvim を挙げない(二重に言わない)
   ! grep -q 'is not validated for .* pinned from lazy-lock.json.*pinned\.nvim' out3.log
   ```

10. **冪等 / 再 import**:
    ```
    nvim -l $lua/resolve.lua $fx/raw-spec.json out4.json --prev out1.json --import-lazy-lock $fx/lazy-lock.json 2> out4.log
    cmp out1.json out4.json
    [ "$(grep -c 'import: pinned ' out4.log)" -eq 0 ]
    grep -q 'import: skipped 8 entries already decided by the existing lock$' out4.log
    ```
    (out1 には非 local の 9 プラグイン全部が載るので、lazy-lock 側で config に居る 9 件
    = plain/git/ver/defver/tag/pinned/commit/branchy/local のうち local を除く 8 件が prev ブロック。
    **実装後に実測値で確定させること** —— `local.nvim` は `localPlugins` にしか居らず prev.plugins に無いので
    分類 3L のまま。したがって期待値は **8**。実装時に必ず実行して数を確認する。)

11. **seed の永続(ゴール 3 の本体)**:
    ```
    nvim -l $lua/resolve.lua $fx/raw-spec.json out5.json --prev out1.json 2> out5.log
    cmp out1.json out5.json
    [ ! -s out5.log ]
    ```
    **import フラグ無し**で prev だけ渡した出力が byte-identical。`identity_fields` に `resolvedRef` が
    無いことによるマージ契約 1 の実証であり、stderr が空であること(import の報告が lock に残らない)も含む。

12. **ハードエラー(壊れたファイル)**:
    ```
    rc=0
    nvim -l $lua/resolve.lua $fx/raw-spec.json bad1.json --import-lazy-lock $fx/lazy-lock-broken.json 2> bad1.log || rc=$?
    [ "$rc" -ne 0 ]
    grep -q 'is not valid JSON' bad1.log
    grep -q ':Lazy restore' bad1.log
    [ ! -f bad1.json ]
    ```
    **出力ファイルが書かれていない**ことが要点(`resolve.lua:863` は最後に 1 回しか書かない)。

13. **ハードエラー(存在しないパス)**:
    ```
    rc=0
    nvim -l $lua/resolve.lua $fx/raw-spec.json bad2.json --import-lazy-lock $TMPDIR/no-such.json 2> bad2.log || rc=$?
    [ "$rc" -ne 0 ]
    grep -q 'cannot open the lazy-lock.json' bad2.log
    [ ! -f bad2.json ]
    ```

13b. **空ファイルとトップレベル配列**(レビュー指摘のカバレッジ穴):
    ```
    # {} -- 正常系。「seed するものが無い」note が出て exit 0
    nvim -l $lua/resolve.lua $fx/raw-spec.json out6.json \
      --import-lazy-lock $fx/lazy-lock-empty.json 2> out6.log
    grep -q 'import: lazy-lock.json has no entries; nothing to seed$' out6.log
    jq -e '[.plugins[] | .resolvedRef] | all(. == null)' out6.json
    # config 側の全プラグインが分類 5 で報告され、summary も出る
    [ "$(grep -c 'is not in lazy-lock.json; it will resolve normally$' out6.log)" -eq 9 ]
    grep -q 'import: 0 pinned, 0 skipped, 0 ignored, 9 not in lazy-lock.json$' out6.log

    # [] -- decode 結果は数値キーの table なので、ハードエラーではなく分類 9 に落ちる
    nvim -l $lua/resolve.lua $fx/raw-spec.json out7.json \
      --import-lazy-lock $fx/lazy-lock-array.json 2> out7.log
    grep -q 'key is not a plugin name' out7.log
    ```
    (`lazy-lock-array.json` は `["a", "b"]` のように 2 要素にして、分類 9 が 2 行出ることを見る。
    **実装時に実測して件数を確定させること。**)

14. **lock-app: `--update` 併用拒否**(`nix` を一度も呼ばない。`resolve-update` step 10 と同じ手法):
    ```
    rc=0
    nvimx-lock --config /nonexistent-config --out /nonexistent-out \
      --update --import-lazy-lock 2> cli1.log || rc=$?
    [ "$rc" -eq 2 ]
    grep -q -- '--import-lazy-lock cannot be combined with --update' cli1.log
    grep -q 'usage: nvimx-lock' cli1.log
    grep -q -- '--import-lazy-lock \[path\]' cli1.log   # usage 文字列に載っていること
    ```

15. **lock-app: 既定パスと不存在エラー**(ここも `nix` に到達しない):
    ```
    mkdir -p $TMPDIR/cfg
    rc=0
    nvimx-lock --config $TMPDIR/cfg --out $TMPDIR/outdir --import-lazy-lock 2> cli2.log || rc=$?
    [ "$rc" -eq 2 ]
    grep -q "no lazy-lock.json at $TMPDIR/cfg/lazy-lock.json" cli2.log
    # このガードで落ちた実行は out ディレクトリを作らない
    [ ! -e $TMPDIR/outdir ]

    rc=0
    nvimx-lock --config $TMPDIR/cfg --out $TMPDIR/outdir2 --import-lazy-lock /no/such/lazy-lock.json 2> cli3.log || rc=$?
    [ "$rc" -eq 2 ]
    grep -q 'no lazy-lock.json at /no/such/lazy-lock.json' cli3.log
    [ ! -e $TMPDIR/outdir2 ]
    ```
    step 15 の 1 本目が**既定パス `<configDir>/lazy-lock.json` の証明**、2 本目が明示パスの証明。

16. **extract 通し(名前照合の実地検証)**: `tests/fixtures/basic-config` を実 extractor に通し、
    その raw-spec に対して check 内で lazy-lock を生成して resolve → `resolvedRef` がその commit。
    **extract が導出する名前と lazy-lock のキーが同一系である(§1.4)ことを通しで担保する。**
    `extractor-snapshot` / `resolve-merge:1609-1620` と同じ XDG sandbox シェル片を流用する
    (`ln -s ${lazy-nvim} $sb/data/nvim/lazy/lazy.nvim` + `NVIMX_LAZY_SEED`)。
    basic-config の `tokyonight.nvim` には `version` が無いので `--lazy` も git も不要。

    **生成する lazy-lock には `lazy.nvim` のエントリも入れること(レビュー指摘)**:
    ```json
    {
      "lazy.nvim":       { "branch": "main", "commit": "0000000000000000000000000000000000000000" },
      "tokyonight.nvim": { "branch": "main", "commit": "1234123412341234123412341234123412341234" }
    }
    ```
    分類 8 は `import_db` に `lazy.nvim` キーがあるときにしか出ない(§5.1 step 8 の
    `for _, n in ipairs(lock_names) ... if n == "lazy.nvim"`)ので、`tokyonight.nvim` だけの
    lazy-lock では `import: lazy.nvim itself is not imported` を assert できない。
    2 キーにすることで**実 lazy-lock により近く**なり(実際の lazy は必ず自分自身を書く)、
    かつ「実 extract の出力に `lazy.nvim` が居ない」ことの assert が成立する。

### 6.3 CI / darwin

- `.github/workflows/check.yml` は `nix flake check` と `nix fmt -- --ci` を回すだけなので、`checks` に 1 つ
  足せば両系統の CI に自動的に乗り、**ワークフローの編集は不要**。
- ローカル(linux)の `nix flake check` は darwin を `omitted these incompatible systems` でスキップするので、
  `nix eval .#checks.aarch64-darwin.resolve-import-lazy-lock.drvPath` で評価だけ通す(CLAUDE.md の規約)。
  新 check は `neovim-unwrapped` / `jq` / `nvimxLib.lockApp` のみで darwin 固有の落とし穴には触れない。
- `nix fmt -- --ci` で `resolve.lua` の追記が stylua 済み・luacheck clean であることを確認(#31)。
- `writeShellApplication` の shellcheck は `nix flake check` ではなく `nvimxLib.lockApp` のビルド時に走る。
  step 14-15 が lockApp を nativeBuildInputs に持つので、check が shellcheck も兼ねる。

### 6.4 手動検証(オンライン、PR 前に 1 回。結果を PR 本文に貼る)

1. 実在の `lazy-lock.json`(作者の dotfiles)で `nvimx-lock --config … --out … --import-lazy-lock` を実行し、
   `flake.lock` の各 `locked.rev` が lazy-lock の `commit` と一致すること。
2. 直後の `nvimx-lock`(フラグ無し)が `git diff` で no diff(ゴール 3 のオンライン版)。
3. `defaults = { version = "*" }` を書いた config で import した場合に **ls-remote が 1 本も飛ばず、
   通常 lock より明確に速いこと**(所要時間を測る)。分類 10 の集約行が出ること。
4. 非 GitHub の git URL を含む config で `nix flake lock` が通ること(§7 の第 1・2 項の実地確認)。
5. `projectDir` 経由の home-manager ラッパで `nvimx-lock --import-lazy-lock` が通ること(§1.5 の実地確認)。

## 7. リスク / 未決事項

- **spec が `tag` を持つ git type への seed で `ref` と `rev` が両方付く**(新規、`genflake.lua:45-57` の実読で判明):
  URL は `git+<url>?ref=refs/tags/<t>&rev=<sha>` になる。nix の git fetcher は ref を fetch したうえで rev の
  存在を確認するため、**lazy-lock の commit がそのタグの指す commit でない場合に `nix flake lock` が失敗する**。
  通常は lazy がそのタグを checkout した結果が lock に入っているので一致するはずである。失敗時のエラーは
  input 名を含むので対処は自明(spec の `tag` を直すか `--update <name>`)。github type は `resolvedRef` が
  `tag` より優先されて `github:o/r/<sha>` 単独になるので影響しない。§6.2 step 5 でこの URL 形を固定する。
- **git type(非 GitHub)で `branch` を書いていない場合の rev fetch**: seed した SHA は
  `git+<url>?rev=<sha>`(ref なし)で fetch される。**実リモート(https)で advertise されていない SHA を
  サーバが拒否する可能性が残る**(オフラインでは検証できない)。lazy-lock は `branch` を持っているが、
  それを `branch` フィールドに書くと spec 恒等性が破れて seed が次回 lock で失われるので書けない(§3.4)。
  失敗時は `nix flake lock` の段階で input 名付きの明確なエラーになり、spec に `branch` を明示すれば直る。
  README の移行節に 1 行書く。
- **`version` 制約が検証されないまま固定される**(§3.4.1 帰結 2): 分類 10 の集約 note で可視化するが、
  「lazy-lock の commit が本当に制約を満たすか」はオフラインでは判定できない(ls-remote + タグの peel が要る)。
  検証を足すと import のオフライン性という最大の利点が失われるため、**足さない**。将来
  `--import-lazy-lock --verify` のようなオプトインを足すかは未決。
- **pin + import した commit は unpin で失われる**(§3.4 の但し書き): seed した 40-hex は `is_frozen_rev` が
  真になり、pin 由来の凍結(`resolve.lua:568-570`)と区別が付かないため、`pin` を外した次の lock で破棄される。
  意味論としては妥当だが「import したのに pin を外したら動いた」という驚きはありうる。区別を付けるには
  `resolvedRef` の出自を記録する第 4 の値かフィールド追加が必要で、#23 が「pin がタグ ref を焼き直すか」で
  同じ形の未決を抱えている(`docs/architecture.md:248`)。**両方まとめて別途判断する。**
- **lazy.nvim 自身の pin は import されない**(§4.3): `lock-app.nix:85-86` の既存 TODO と同じ土俵。
  移行直後の runtime lazy.nvim は `lazy-nvim` input の HEAD になり、ユーザーが lazy 側で固定していた
  バージョンとは一致しない。別 issue(#32 系)に委ねることを README の移行節に 1 行書く。
- **近似ヒントの誤検出**: 分類 7 のヒントは「正規化名が config 側の正規化名と一致する」だけで出す。
  lazy-lock に `git.nvim` と `git-nvim` の両方があるような病的なケースでは、既にマッチ済みの名前を
  「did you mean」で指してしまう。助言のみで自動マッチはしないので実害は無い。修正しない。
- **upstream から消えた commit**(force-push・リポジトリ移転): `nix flake lock` が fetch に失敗して止まる。
  オフラインでは検出不能。エラーは該当 input 名を含むので対処は自明であり、許容する。
- **lazy のバージョン差による名前導出の揺れ**: `get_name` は「末尾 `.git` と `/` を落として最後のパス要素」
  という極めて単純な規則(§1.4)なので実害の可能性は低いが、変わった場合は完全一致が失敗する。
  §3.3 の近似ヒントで手がかりを出すのみで、自動修復はしない。
- **lazy-lock.json に無い installed プラグイン**: lazy は installed なプラグインしか lock に書かないので、
  移行直前に spec へ追加したばかりのプラグインは lock に無く通常解決になる(分類 5 で報告)。仕様とする。
- **#49 との順序**: 本件は #49 に依存しないが、#49 が「ユーザーの `lazy.nvim` を synthetic input と共有する」
  形で解決した場合、分類 8 の出し分け条件と共有 input への seed 可否を読み直す必要がある(§4.3)。
  この申し送りを #49 の issue にも書く。
- **§6.2 step 10 の期待件数**: 分類 4 の件数(8 を想定)は実装後に必ず実測して確定させること。
  ここだけは机上の数え上げに頼っている。

## 8. 検証手順(実装完了時に必ず全部通す)

```bash
nix flake check
nix fmt -- --ci
nix eval .#checks.aarch64-darwin.resolve-import-lazy-lock.drvPath
nix build .#checks.x86_64-linux.resolve-import-lazy-lock -L   # 個別に速く回すとき
```

さらに §6.4 の手動検証を 1 回行い、結果を PR 本文に貼る。

CLAUDE.md の規約:

- **main への直接 push は禁止**。ブランチ `feat/import-lazy-lock` を切って PR 経由でマージする。
- コミットメッセージは **conventional commits**(本件は `feat(lock): ...`)。
- コミットメッセージ / PR は**英語**で書く。
- PR 作成後は `fable` モデルのサブエージェントで `/review` を回し、指摘に対応する。
- CI のステップ追加が必要になった場合、編集するのは reusable workflow の `.github/workflows/check.yml`
  のみ(`ci-linux.yml` / `ci-darwin.yml` は触らない)。本件は `checks` に 1 つ足すだけなので**編集不要**。
