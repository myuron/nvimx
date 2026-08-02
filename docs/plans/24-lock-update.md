# #24 対応計画: `nvimx-lock --update [name...]`

対象 issue: [#24 feat(lock): add --update [name...]](https://github.com/myuron/nvimx/issues/24)

Depends on #18(**PR #41 でマージ済み**)。前提としていた #43(PR #44)/ #42(PR #46)/ #31(PR #48)/
#36(PR #50)/ #23(PR #51)は**すべて main にマージ済み**であり、本件は今すぐ着手できる。
以降の着手順は **#24(本件) → #25 → #32 → …**(残る open issue は
#25 / #26 / #27 / #28 / #29 / #30 / #32 / #33 / #34 / #47 / #49)。

**本計画は #18 マージ後の実コードに突き合わせた改訂版である。** 旧版は #18 の計画書だけを見て書かれた
予測であり、以下を実コード・実測で検証して差し替えた: 旧 §3.2 の `--update-plan` の採用理由(誤り。
§3.3 で訂正)、旧 §3.4 の `nix flake lock` / `update` の使い分け(`nix flake update` 単体を全体更新に
使う案を撤回。§3.5)、旧 §4「#18 に追加で要求するもの」(2 項目とも既に満たされている。§4.1)、
旧 §7 の「lockDir の lazy.nvim pin は runtime に使われていない」(**誤り**。`make-env.nix:35`。§3.6)。

**さらに #23 マージ後の main(`7959314`)に対する計画レビューを反映した第 2 版である。** 主な訂正:
裸 `--update` と名前指定の混在エラーが CLI から到達不能だった問題(§3.1 / §5.1)、サマリ仕様の穴
(`removed` の欠落と名前指定モードの警告の偽陽性。§3.4 / §7)、`--update-plan` の内容の実測記述と
設計の食い違い(§4.1)、未知名エラーの一括報告(§3.2 / §5.2)、`update-summary.lua` 自身の失敗時
挙動(§5.1)、`refs/tags/` 以外での ref 二重表示(§3.4)、ドキュメント更新の抜け(§5.6)、
既に #49 として起票済みの lazy.nvim 衝突バグ(§7)、行番号基準と着手順の更新。

### 行番号の扱い(重要)

本文の `file:line` は **main `7959314`(#36 / #23 のマージ後)基準に更新済み**である。旧版は
`de7b6e2`(ブランチ `build/stylua-luacheck`)基準で、#36 / #23 が `resolve.lua` を書き換えた分だけ
ずれていた。以降の編集でも動くので、**位置指定は引き続きシンボルを主キーとして読むこと**。
main で現物を確認した主要シンボルの位置:

- `lua/nvimx/resolve.lua`(773 行): ヘッダ Usage コメント `:3-5` / `usage()` `:20-26` /
  フラグループ冒頭コメント `:28-29` と `do ... end` 本体 `:30-62` / `read_json(raw_path, ...)` `:88` /
  `is_frozen_rev` / `is_tag_ref` `:106-116` / `prev_plugins` `:119` / `local force = {}` `:163-165` /
  `to_input_name` `:167-170` / `identity_fields` / `source_fields` `:190-191`(除外理由のコメント `:185-189`)/
  `same_identity` `:193-209` / `warn` `:230` / `note` `:235` / `resolve_errors` と `fail_plugin` `:243-246` /
  `seen_inputs` `:267`(衝突検査 `:416-419`)/ `for name, p in pairs(raw.plugins or {})` `:411-510` /
  「Merge with the previous lock」`:447-450` / 「`pin = true`: freeze onto the rev」`:471-478` /
  #23 の semver ゲート `:492` / fatal の一括報告 `:735-746` / 末尾の `io.open(out_path, "w")` `:771`
- `nix/lib/lock-app.nix`(158 行): TODO `:3` / `runtimeInputs` `:10-20` / `usage()` `:22-25` /
  `while [ $# -gt 0 ]` `:29-43` / 必須チェック `:44` / seed の TODO `:49-51` / `sandbox` `:53` /
  `cleanup()` `:58-64` / extract `:69-80` / resolve 1 回目 `:82-109`(`resolve_args=()` `:87-93`)/
  genflake + nixfmt `:111-113` / `nix flake lock` `:115-116` と `:148` /
  「convergence pass」コメントブロック `:118-133` と 2 回目 resolve の直書き引数 `:134-137` /
  resolve.log 再表示 `:151-154` / done `:156`
- `nix/home-manager/default.nix`: `lockCommand` `:15-29`、`lock.projectDir` の option `:171-179`
- `flake.nix`(1828 行): `checks = forAllSystems` `:154` / 共有ヘルパ `mkTagRepoSh` `:166` /
  `resolve-build-warnings` `:1200` / `resolve-merge` `:1350` / `resolve-semver` `:1577`
- `docs/architecture.md`: シーケンス図の `nvimx-lock [--update] ...` `:82` / 「Update semantics」`:250-262` /
  「Updating」`:439` / 「Repository layout」`:442-473`(`lua/nvimx/` 一覧 `:465-470`、`tests/fixtures/` `:472`)/
  checks 一覧 `:481` / フェーズ一覧 `:513`

nix の挙動に関する記述はすべて **nix 2.34.8** で scratchpad の `git+file://` ローカルリポジトリを使って
実測したものである(§3.5、§7)。

## 1. 背景 / 現状

### 1.1 CLI と lock の流れ

- `nix/lib/lock-app.nix:3` に TODO「`--update [name...]`, `--import-lazy-lock`」が残っている。
- 引数パーサ(`lock-app.nix:29-43`、`while [ $# -gt 0 ]`)は `--config` / `--out` のみを解釈し、それ以外は
  `usage()`(`:22-25`)で exit 2。**同名フラグの後勝ち**(`--config A --config B` なら B)であり、
  これは §3.7 の設計根拠になる。
- 必須チェックは `:44`(`[ -n "$config" ] && [ -n "$out" ] || usage`)。`config` は `:45` で realpath 化。
- lock の流れ: extract(`:69-80`)→ resolve 1 回目(`:82-109`)→ genflake + nixfmt(`:111-113`)→
  `nix flake lock`(`:115-116`)→ **収束パス**(resolve 2 回目 + 差分があれば genflake + `nix flake lock`、
  `:118-149`)→ resolve.log 再表示(`:151-154`)→ done(`:156`)。
- resolve の warning は `$sandbox/resolve.log` に溜め、最後にまとめて表示する(#22)。失敗時は
  `cleanup` trap(`:58-64`)と各致命パス(`:105-109` / `:138-142`)が代打で表示する。
- `resolve_args`(`:87-93`)は `$out/plugins.json` / `$out/flake.lock` の存在に応じて `--prev` / `--lock` を
  組む。**収束パス(`:134-137`)はこの配列を再利用せず `--prev` / `--lock` を直書きしている**。
  これは本件にとって好都合である(§4.1)。
- `runtimeInputs`(`:10-20`)は `coreutils` / `diffutils` / `git`(#23 が追加、`:17`)/ `neovim-unwrapped` /
  `nixfmt-rfc-style`。生成スクリプトを実読したところ `writeShellApplication` は
  `export PATH="<runtimeInputs>:$PATH"` の**前置**で、bash 5.3 + `set -o errexit -o nounset -o pipefail`。
  `nix` 自体もユーザー PATH 由来である(現状の `nix flake lock` も同じ)。
  **`xargs` は coreutils ではなく findutils** なので、本件では使わず bash の `mapfile` を使う(§5.1)。

### 1.2 resolve.lua 側(#18 が敷いた受け口)

- `local force = {}`(`resolve.lua:163-165`)が既に存在し、コメントに「Always empty today; #24
  (`nvimx-lock --update [name...]`) fills it from the command line」と書かれている。
- フラグループ(`:30-62`)は「`--` 始まりの未知フラグはエラー、それ以外は位置引数」の `while` ループで、
  冒頭コメント(`:28-29`)が #24 / #25 の追加を想定している(**このコメント自体の書き換えが本件の宿題**。§5.6)。
- マージ本体(`:447-470`、要点は `:449-450`):
  `local prev = (prev_plugins and not force[name]) and prev_plugins[name] or nil` →
  `local unchanged = prev ~= nil and same_identity(prev, entry)` → `unchanged` のときだけ
  `entry.resolvedRef = carried`。
- pin 凍結(`:471-478`)は `is_true(entry.pin) and unchanged and is_null(entry.resolvedRef) and is_null(entry.commit)`
  で**ガードが `unchanged` を含む**。したがって `force[name]` が立つと `prev = nil` → `unchanged = false` →
  **凍結ブロックも自動的にスキップされる**。#24 が必要とする 2 条件(resolvedRef 破棄・凍結スキップ)は
  **force に名前を入れるだけで両方満たされる**(§4.1 で実測確認済み)。
- spec 恒等性 = `identity_fields = { "branch", "tag", "commit", "version" }` + `source_fields`
  (`:190-191`)。`pin` / `dependencies` / `build` は含まれない(`:185-189` のコメント)。
- `to_input_name`(`:167-170`)= `name:gsub("[^%w_-]", "-")`。エントリの `inputName` に格納されるので、
  **`plugins.json` を読めば表示名 → inputName の対応は再計算せずに引ける**(§3.3 の訂正の根拠)。
- `#43`(PR #44)で `optional` は削除済み。`#42`(PR #46)で `extract.lua` に `effective_version` が入り
  `dump_plugin` は 2 引数。`defaults.version` は各プラグインの `version` に実体化される。
- **fatal は 1 件ずつ死なずに集めてから一括報告する**のが #23 が確立した流儀である
  (`fail_plugin`(`:243-246`)が `resolve_errors` に溜め、`:735-746` が名前順にソートして全部出してから
  `os.exit(1)`)。本件の名前検証もこれに合わせる(§5.2)。
- **`defaults.version` フォールバック中のプラグイン(`resolvedRef` が null のまま)は毎回の lock で
  ls-remote に再照会される**。#23 のゲート(`:492`)の条件が `is_null(entry.resolvedRef)` であり、
  フォールバックは「解決できなかった」ことを記録しないためで、`lock-app.nix:123-133` のコメントが
  この性質を明示している。**通常 lock でも remote 側にタグが出現した瞬間に `resolvedRef` が
  `refs/tags/...` に変わり URL が動く**。これが §3.4 のサマリ設計と Done when 1 に効いてくる。

### 1.3 ドキュメントと約束

- `templates/default/README.md:25` が「Update: `nvimx-lock --update` (planned for Phase 6)」と
  実装されていない約束を出荷している。
- `README.md:101-102`「Adding a plugin later ...」に更新の記述が無い。
- `docs/architecture.md:250-262`「Update semantics」に意図が既にある。特に `:260`
  「`nvimx-lock --update [name...]`: re-resolves version constraints + `nix flake update [name...]`」、
  `:261` のバックドア、`:82` のシーケンス図、`:439`(Updating)。
- `docs/architecture.md:481` の checks 一覧に本件の新 check を足す必要がある。
- 「Repository layout」(`:442-473`)の `lua/nvimx/` 一覧(`:465-470`)と `tests/fixtures/` 行(`:472`)は
  本件が足すファイルの分だけ追記が要る(§5.6)。フェーズ一覧(`:513`)の
  「6. Version/update features: ... `--update [name]` ...」も実装済み表記の検討対象。

### 1.4 home-manager ラッパの穴(再確認)

`nix/home-manager/default.nix:20-29` の `lockCommand` は **`[ "$#" -eq 0 ]` のときだけ**
`--config` / `--out` のデフォルトを補い、そうでなければ `"$@"` をそのまま渡す。したがって
`projectDir` を設定したユーザーの `nvimx-lock --update tokyonight.nvim` は `--config` が無いため
`lock-app.nix:44` で usage → exit 2 になる。

**これは「既存バグ」ではなく潜在的な穴である**: 今日の lock-app が受けるフラグは `--config` / `--out`
だけで、その 2 つを欠いた呼び出しはどう転んでもエラーなので、観測可能な不具合が現時点では存在しない。
よって**別 issue には切り出さず本件のスコープに含める**(issue の "Done when" 1 が
`nvimx-lock --update tokyonight.nvim` の成功を要求しており、projectDir ユーザーで成立させるには必須)。
#25 の `--import-lazy-lock` も同じ穴を踏むので、ここで直しておけば #25 は何もしなくてよい。

## 2. ゴール

issue の "Done when" を検証可能な形に落とす:

1. **選択的更新**: `nvimx-lock --update tokyonight.nvim` の後、tokyonight.nvim 以外の全プラグインの
   `plugins.json` エントリと `flake.lock` node が実行前と byte-identical。tokyonight.nvim だけ
   locked rev が前進しうる。オフラインで固定できるのは resolve 層と update-plan の内容、
   `flake.lock` 層は手動検証(§6.4)。
   **この byte-identical は無条件ではなく「spec が不変 かつ 指定外プラグインでフォールバック解決が
   起きない」という条件付きである**: (a) spec からプラグインが消えていれば、手順 5 の素の
   `nix flake lock` が stale node を落とす(実測、§3.5)。(b) `defaults.version` フォールバック中の
   指定外プラグインの remote に適合タグが出現していれば、`resolvedRef` が `refs/tags/...` になって URL が
   変わり、同じく素の `nix flake lock` がその input を動かす(§1.2)。どちらも通常 lock でも起きる
   正当な挙動なので、サマリはこれらを警告ではなく `removed` / `updated` の行として報告する(§3.4)。
2. **全体更新**: `nvimx-lock --update`(無引数)で pin されていない全プラグインが再解決・再 fetch される。
   `pin = true` のプラグインは凍結 rev のまま動かず、その旨がサマリに出る。
3. **未知名エラー**: 存在しないプラグイン名を渡すと lock を一切書き換えずに非ゼロ終了し、どの名前が
   未知かをエラーが名指しする。**nix には任せられない**: `nix flake update <未知名>` は warning を出して
   **exit 0** で終わる(実測、§3.5)。検証は resolve.lua が持つ。
4. **サマリ**: 実行末尾に plugin / old rev / new rev の変更サマリが出る。無変更・pin スキップ・
   spec の `commit` 固定・新規追加・**削除**のそれぞれに定義された行が出る(§3.4)。名前指定モードで
   **説明のつかない形で指定外の input が動いていたらサマリがそれを暴露する**(Done when 1 の実行時
   セーフティネット。ただし上の (a)(b) は「説明のつく移動」なので警告ではなく通常行にする)。
5. **ドキュメント**: usage 文字列 / `README.md` / `templates/default/README.md` / `docs/architecture.md`
   が両形式を説明し、テンプレートの「planned for Phase 6」が消えている。
6. **オフライン検証**: 1-4 のうちネットワーク不要な部分(force 意味論、名前検証、update-plan の内容、
   サマリ生成)が `flake.nix` の `checks` で回り、darwin でも評価が通る。
7. **通常 lock への非影響**: `--update` なしの `nvimx-lock` は `checks.resolve-merge` /
   `resolve-semver` の既存 assert がすべて不変で通る。

## 3. 設計

### 3.1 CLI インタフェース(nvimx-lock)

```
usage: nvimx-lock --config <configDir> --out <lockDir> [--update [name...]]
```

文法: `--update` の後に続く「`--` で始まらない引数」をすべて更新対象名として取り込む。0 個なら全体更新。

- `nvimx-lock --config c --out o --update` → 全体更新。
- `nvimx-lock --update foo bar --config c --out o` → foo と bar のみ(`--config` で名前の取り込みが止まる)。
- 実装は bash の先読みループ(§5.1)。判定は `[ "''${1#--}" = "$1" ]` の**`--` 前置のみ**で行う。
  単一 `-` 始まりの語は名前として取り込まれるが、resolve.lua の検証が `unknown plugin "-x"` で
  ハード失敗するので黙って誤動作はしない。
- `--update` の重複指定は許す(`--update foo --update bar`。名前は積み上がる)。
- **裸 `--update` と名前指定の混在は lock-app 自身が usage エラー(exit 2)で弾く**。
  例: `nvimx-lock --update --update foo` / `nvimx-lock --update --config c --out o --update foo`。

  **これを resolve.lua 任せにしてはならない**(旧版の誤り): lock-app のパーサは複数の `--update` を
  単一の `update_names` 配列に畳み込むので、resolve.lua に渡す引数を**名前の総数だけから**再構成すると
  裸マーカーの情報が消え、`--update --update foo` は `--update foo` に化ける。resolve.lua 側の混在
  エラーは**一度も発火しないまま「foo だけの更新」として黙って実行される**(パーサ再現で実測確認)。
  したがって lock-app は「**名前を 1 つも取り込まなかった `--update`**」を `update_all=1` として
  別途記録し、`update_all=1` かつ `${#update_names[@]} -gt 0` を自分で usage エラーにする(§5.1)。
  resolve.lua 側の同じチェックは `nvim -l resolve.lua` を手で叩く場合の防御として維持する(§3.2)。
- `--update` 指定時に `$out/plugins.json` または `$out/flake.lock` が無ければ
  「no existing lock to update; run nvimx-lock first」でエラー(exit 2)。更新は既存 lock の前進であり、
  初回 lock と混ぜない。

**名前の名前空間**: **lazy 由来の表示名 = `plugins.json` の `plugins` のキー = ユーザーが spec に書く
short name**(例 `tokyonight.nvim`)で照合する。`inputName`(`tokyonight-nvim`)では照合しない。

- 採用理由: ユーザーが目にするのは spec と `nvimx-lock` の出力で、どちらも表示名。inputName は
  genflake / flake.lock の内部表現。
- 却下案: inputName も受理する。`tokyonight-nvim` と打った場合に「did you mean "tokyonight.nvim"?」と
  *案内*するのは親切だが、受理はしない。

**未知名の検証**は resolve.lua が行う(raw-spec が名前の正であり、検証を merge 実装と同じ場所に置く)。
エラーの型:

| 入力 | 挙動 |
|---|---|
| raw-spec のどこにも無い名前 | `unknown plugin "<name>"`(inputName 一致があれば did-you-mean を付す) |
| `dev` / `dir` 指定の local plugin | `"<name>" is a local plugin (dev/dir); nothing to lock or update` |
| `lazy.nvim` | **エラーにせず受理**し、synthetic な `lazy-nvim` input を更新対象にする(下記) |

`lazy.nvim` を受理する理由: 全体更新は `lazy-nvim` input を動かし、サマリに `lazy.nvim (seed)` として
出す(§3.4)。それを見たユーザーが `--update lazy.nvim` を試すのは自然であり、拒否する理由がない。
実装は「名前が `lazy.nvim` なら plan に `lazyNvim.inputName` を足す」だけ(force 集合には入れない。
synthetic エントリには `resolvedRef` が無い)。なお**ユーザーが spec に `"folke/lazy.nvim"` を書くと
inputName が synthetic の `lazy-nvim` と衝突し、生成 flake が評価できなくなる**既存バグがある
(実測確認。**issue #49 として起票済み**。§7)。本件の範囲外だが `--update lazy.nvim` の意味を
「synthetic な seed input」に固定しておけば、そのバグを直す際にも解釈が変わらない。

いずれのエラーもハード失敗(exit 1)で、lock-app の既存の致命パス(`lock-app.nix:105-109`)が
resolve.log ごと即時表示・非ゼロ終了する。**出力ファイルは一切書かれない**(resolve.lua は最後に
まとめて書く構造。`resolve.lua:771`)。検証はメインループより前に置く。

**エラーは名前ごとに即死せず、全名前ぶん集めてから一括で出す**。#23 が `resolve_errors` /
`fail_plugin`(`resolve.lua:243-246`、報告 `:735-746`)で確立した流儀であり、`--update foo bar baz` で
foo と baz が両方未知のときに 1 件ずつ直させるのは明確な後退である(§5.2 に実装上の注意)。

### 3.2 resolve.lua への渡し方

既存のフラグループに 2 つ追加する:

```
nvim -l resolve.lua <raw-spec.json> <out> [--prev <p>] [--lock <l>] [--lazy <d>]
    [--update [<name>]]... [--update-plan <path>]
```

- `--update` は先読み 1 語: 次の引数が存在し `--` で始まらなければ名前として消費、そうでなければ
  「全体更新」マーカー。繰り返し可。全体更新マーカーと名前指定の混在はエラー。
  **この混在エラーは CLI からは到達しない**(lock-app が先に弾く。§3.1)。
  `nvim -l resolve.lua` を直接叩く場合のための防御として置く。
- 意味論は #18 の `force` 集合そのもの:
  - 名前指定: `force = { 指定名 }`(**pin されていても含む。名前の明示 = 凍結解除**)。
  - 全体更新: `force = { 全プラグイン } - { pin = true }`。pinned は通常マージ(= 凍結 rev の引き継ぎ)を受ける。
  - `force[name]` が立つと `prev = nil` になり、`resolvedRef` 破棄と pin 凍結スキップが**既存コードの
    ガードだけで**成立する(§1.2、§4.1)。
  - **名前指定された「spec に `commit` 直書き」のプラグインも、そのまま force に入れ plan にも入れる**。
    force しても URL は commit 固定のままなので `nix flake lock` / `nix flake update` は動かせず、
    **無害な no-op** である(URL に rev が焼かれた input が `nix flake update` で動かないことは §3.5 で
    実測済み)。除外の分岐を足す方が仕様も実装も増えるので入れる。ユーザーへの説明はサマリの
    `unchanged (commit-pinned in spec)` 行が担当する(§3.4)。plan に入る/入らないは §6.3 の
    plan 内容 assert が golden で固定するので、**この決定は必ず一文として明記しておくこと**。
- `--update-plan <path>`(lock-app 専用の内部フラグ): 更新対象の `inputName` を 1 行 1 個・ソート済みで
  書き出す。lock-app はこれを `nix flake update` の引数にする(§3.5)。全体更新モードでは
  force 集合の inputName 全部 + `lazy-nvim` を書く(merge fixture なら
  `lazy-nvim` / `plenary-nvim` / `telescope-nvim` の 3 行。§4.1)。

### 3.3 `--update-plan` の採否(旧計画の理由付けを訂正)

旧計画は「表示名 → inputName の変換(`to_input_name`)を resolve.lua に一元化するため」を採用理由に
していた。**これは誤りである**: `plugins.json` の各エントリは `inputName` を持っており、lock-app が
それを読めば変換は再実装ではなく単なる参照になる。正しい採用理由は次の 3 点:

1. **lock-app に JSON リーダが無い**。`runtimeInputs` に `jq` は無く(#23 が足すのは `git`)、
   `plugins.json` を読むには jq を足すか `nvim -l` 用の小さなスクリプトを新設するかになる。
   後者は「resolve.lua にフラグを 1 つ足す」より確実に行数が多い。
2. **stdout は #23 が使う**。#23 §3.2 は進捗行を stdout に出す設計なので、resolve.lua が plan を
   stdout に流すことはできない。ファイル経由が唯一素直な口になる。
3. **plan は「検証を通過した force 集合」そのもの**である。名前検証(§3.1)と pin スキップ(§3.2)の
   結果を lock-app が再計算せずに受け取れるので、`checks` で plan の内容を assert すれば
   「何を動かすつもりだったか」を固定できる。`nix flake update <未知名>` が exit 0 で黙る(§3.5)
   ことを踏まえると、この固定点は安全装置として必要である。

却下案: `pkgs.jq` を `runtimeInputs` に足して `jq -r --args '.plugins[$ARGS.positional[]].inputName'` で
引く。動くが、名前が local plugin だった場合の null 混入・全体更新モードでの pin フィルタの再実装が
bash 側に増える。plan ファイル 1 個の方が総量が小さい。

### 3.4 pin との相互作用と変更サマリ

**pin**(#18 の推奨をそのまま採用。実装が既にそれを満たすことは §4.1 で確認済み):

- **全体更新は pinned をスキップ**する。凍結 rev は URL に焼かれているので後段の `nix flake update` でも
  物理的に動かない(実測、§3.5 の E8)。スキップした事実はサマリに `pinned (skipped)` として必ず出す。
- **名前で明示された pinned は更新する**。resolve が凍結を解いて `resolvedRef = null` に戻し、genflake が
  branch/tag URL を出し、`nix flake lock` と `nix flake update <input>` が新 rev を取り、収束パスの
  2 回目 resolve が新 rev を再凍結する。終了時には再び URL レベルで凍っている。
- spec に `commit` が直書きされたプラグインは名前指定されても動けない(URL が commit 固定)。
  エラーにせず、サマリで `unchanged (commit-pinned in spec)` と理由付きで報告する。

**サマリの計算場所**: 新規の小さな Lua スクリプト `lua/nvimx/update-summary.lua` を lock-app が最後に呼ぶ。

```
nvim -l update-summary.lua <plugins.json.before> <plugins.json.after> \
    <flake.lock.before> <flake.lock.after> [name...]
```

- **旧計画の判断は #18 実装後も正しい**(再検証済み): branch 追従プラグインの `resolvedRef` は
  更新の前後どちらも `null` なので、resolve.lua はマージ時に差分を一切観測できない。真の old/new rev は
  `flake.lock` の `locked.rev` にしかなく、それが確定するのは `nix flake update` の後である。
  よって #18 §4 が想定した「マージ時の prev.resolvedRef 比較で出す」は**不採用**のままとする。
  flake.lock の走査は `nix/lib/sources.nix:6-12` と同じ構造(`nodes[root].inputs[inputName]` →
  `locked.rev`)で、`resolve.lua:140-161` の `locked_rev` と同型の 20 行程度。
- **旧計画からの拡張**: `plugins.json` の before も渡す。#23 以降は `resolvedRef` が
  `refs/tags/<tag>` を取りうるので、rev だけを見せると「タグが v0.1.7 → v0.1.8 に動いた」という
  ユーザーにとって最も意味のある情報が落ちる。スナップショットは `cp` 2 本(§5.1)で足りる。
  **ref の併記規則**(旧版の「`resolvedRef` が異なるときは併記」は不正確なので限定する):
  - **before/after が両方 `refs/tags/...` で異なるとき**だけ `refs/tags/A -> refs/tags/B (rev -> rev)`
    の形で併記する。タグが動いたという情報がここにしかないため。
  - **両方が 40-hex のとき(pin の凍結解除 → 再凍結)は併記しない**。字義どおりに併記すると
    `aaaa... -> 1111... (aaaa... -> 1111...)` と同じ情報の二重表示になる。rev 行だけで足りる。
  - **片方が null のとき**も併記しない(`resolvedRef` の null は「まだ決まっていない」であって
    ref の移動ではない)。ただし null → `refs/tags/...`(#23 の解決が今回初めて成立した)は移動の
    *理由* として意味があるので、`(version constraint resolved: refs/tags/B)` と理由だけ添える。
  - 40-hex と tag ref の判別は `resolve.lua:106-116` の `is_frozen_rev` / `is_tag_ref` と同じ 2 関数を
    `update-summary.lua` にも置く(各 3 行の純関数。共有モジュール化はしない)。
- **`versionFromDefaults`(#23)はサマリでは使わない**。サマリの主題は「この実行で ref / rev がどう動いたか」
  であり、制約の出自は動いたかどうかに影響しない。出自の報告は #23 の集約行(`note()`)の担当であり、
  二重に言わない。なお `defaults.version` フォールバック中のプラグインは before/after ともに
  `resolvedRef = null` のままか、あるいは今回タグが出現して null → `refs/tags/...` に動くかのどちらかで、
  後者は上の「理由だけ添える」ケースになる(この経路が名前指定モードの警告と衝突する。下記)。
- 却下案: lock-app が bash + jq でやる。`jq` を `runtimeInputs` に足す必要があり、pin / commit の
  分類とテキスト整形が bash に散る。Lua なら `checks` で golden 比較の単体テストができる(§6.3)。

**出力形式**(stderr、resolve.log 再表示の後・`done` メッセージの前):

```
nvimx-lock: update summary
  updated:   tokyonight.nvim  1f2e3d4 -> 5a6b7c8
  updated:   telescope.nvim   refs/tags/0.1.7 -> refs/tags/0.1.8 (9c0d1e2 -> 3f4a5b6)
  unchanged: plenary.nvim
  unchanged: vim-fugitive (commit-pinned in spec)
  pinned:    nui.nvim (skipped; run `nvimx-lock --update nui.nvim` to move it)
  added:     new.nvim         -> 7e8f9a0
  removed:   old.nvim         (was 4d5e6f7)
  updated:   lazy.nvim (seed) 9c0d1e2 -> 3f4a5b6
  3 updated, 2 unchanged, 1 pinned, 1 added, 1 removed
```

- rev は 7 桁短縮。行の種別は `updated` / `unchanged` / `pinned` / `added` / **`removed`** の 5 つ。
- **`removed`**: before の flake.lock に node があり after に無いもの。素の `nix flake lock` は
  spec から消えたプラグインの stale node を落とす(実測、§3.5)ので、`--update` 実行中にもこれは
  起きうる。**名前指定モードでも起きる**(指定外のプラグインが spec から消えていた場合)。
  これは正当な動作なので、警告ではなくこの行で報告する。旧版は削除を全く定義していなかった。
- 全体更新モードでは全プラグイン + `lazy.nvim (seed)` を列挙し、末尾にカウント行を出す。
  カウント行は**件数が 0 の種別を省き**、`updated` / `unchanged` / `pinned` / `added` / `removed` の
  固定順で並べる(golden を決定的にするため)。
- 名前指定モードでは**指定したプラグイン + `added` / `removed` に該当するもの**を列挙する。
  added / removed を警告に混ぜないのは、どちらも「ユーザーが spec を編集した結果」であって
  Done when 1 の不変条件の破れではないからである。
- **警告行の対象は「rev が動いた既存 input のうち、動いた理由が説明できないもの」だけ**に限定する:
  `warning: N input(s) moved without being named: <names>`。
  以下は**警告に含めない**(いずれも通常 lock でも起きる正当な移動であり、旧版の字義では誤警報になる):
  - 指定外プラグインの `resolvedRef` が **null → `refs/tags/...`** に動いた場合。#23 の
    `defaults.version` フォールバックは毎回 ls-remote に再照会されるので(§1.2)、remote に適合タグが
    出現した瞬間に URL が変わり、§3.5 手順 5 の**素の `nix flake lock`** がその input を動かす。
    `updated: <name> <rev> -> <rev> (version constraint resolved: refs/tags/x)` として通常行に出す。
  - 指定外プラグインの **spec 恒等性が変わった**場合(before/after の `branch` / `tag` / `commit` /
    `version` / source が違う)。ユーザーが spec を編集して URL が変わったのだから動いて当然である。
    `updated: <name> <rev> -> <rev> (spec changed)` として通常行に出す。
  - `added` / `removed`。
  判定材料は before/after の `plugins.json` にすべて入っているので、この分類は完全オフラインで付く。
  残った「spec も `resolvedRef` も動いていないのに rev が動いた指定外 input」だけが警告になる。
  これが Done when 1 の実行時セーフティネットであり、黙らせてはいけない。§7 にも偽陽性経路として残す。
- 何も変わらなかった場合も無言にしない: `nvimx-lock: no plugins updated (all up to date)`。
- resolve.log(warning 群)と分離するのは、warning は「lock の恒常的な状態」でサマリは「この実行が
  何をしたか」であるため。表示順は warning → サマリ。

### 3.5 `nix flake lock` / `nix flake update` の使い分け(実測に基づく改訂)

nix 2.34.8 で `git+file://` のローカルリポジトリを input にして実測した結果:

| 実験 | 結果 |
|---|---|
| `nix flake update a`(a, b とも branch 追従、両方 HEAD が進んでいる) | **a の node だけ**が変わり、b は byte-identical |
| `nix flake update no-such-input` | `warning: 'no-such-input' does not match any input of this flake` を出して **exit 0**、flake.lock は無変更 |
| `nix flake update c`(c は flake.nix に追加済みで node が無い) | `Added input 'c'` で追加される |
| `nix flake update`(引数なし)。a は `?ref=main&rev=<sha>` で固定、b は branch 追従 | **a の node は byte-identical**、b だけ更新。stale node(消えた input)も除去される |
| URL を `?rev=<sha>` → `?ref=main` に変えて `nix flake lock` | a は branch HEAD まで**進む**(URL が変わった input は plain lock が再 lock する)。b は無変更 |
| URL を `?ref=main` → `?ref=main&rev=<sha>` に戻して `nix flake lock` | `locked.rev` は不変、`original` に `rev` が増えるだけ(再 fetch なし) |
| `nix flake update a`(a の URL に rev が焼かれている) | a は byte-identical(動かせない) |
| flake.nix から input b を消して **素の `nix flake lock`** | `• Removed input 'b'` と表示して **node ごと除去**される(再実測。§3.4 の `removed` 行の根拠) |

読み取れること:

- **`nix flake update <input>` の位置引数形式は使える**(nix 2.19 以降。それ以前は
  `nix flake lock --update-input <input>`)。フォールバックは実装しない(§7)。
- **未知名は nix が黙って無視する**ので、名前検証は nvimx 側の責務(§3.1)。
- **URL が変わった input は `nix flake lock` が動かし、URL が変わらない input は `nix flake update` が
  必要**。名前指定モードでは両方が要る(pinned の凍結解除は前者、branch 追従は後者)。

そこで **`--update` の有無にかかわらず単一の経路**にする(旧計画は全体更新で裸の `nix flake update` を
使う分岐を持っていたが撤回する):

1. 引数解析後、混在チェック(§3.1)と `--update` ガード(既存 lock の存在確認)。sandbox 作成の後に
   `cp "$out/flake.lock" "$sandbox/flake.lock.before"` と `cp "$out/plugins.json" "$sandbox/plugins.json.before"`。
2. extract(不変)。
3. resolve 1 回目に `--update` 系フラグ + `--update-plan "$sandbox/update-plan.txt"` を追加。
4. genflake + nixfmt(不変)。
5. `nix flake lock`(現行どおり、常に実行)。新規 input の追加、**spec から消えた input の stale node の
   除去**(実測)、URL が変わった input の再 lock をここが処理する。**指定外の input が動きうるのは
   この手順である**(削除、および `defaults.version` フォールバックの遅延解決による URL 変化。
   どちらもサマリでは警告ではなく `removed` / `updated` 行になる。§3.4)。
6. `--update` 時のみ: plan が非空なら `mapfile -t names < plan` して `nix flake update "''${names[@]}"`。
7. 収束パス(`lock-app.nix:118-149`、**`--update` を渡さない**。§4.1)。
8. resolve.log 再表示(不変)→ サマリ(§3.4)→ done。

裸の `nix flake update` を全体更新に使わない理由:

- **経路が 1 本になる**。全体更新と名前指定の差は plan ファイルの中身だけになり、テストの固定点も
  plan 1 か所で済む。
- **pinned を URL の偶然に頼らず明示的に除外できる**。裸の update で pinned が動かないのは
  「URL に rev が入っているから」であり、正しいが間接的である。plan から外せば意図が一次的に表現される。
- **`lazy-nvim` の扱いが暗黙でなくなる**。裸の update は `lazy-nvim` input も動かす。これは
  「全部更新する」として妥当だが、**`make-env.nix:35` は lock がある限り runtime の lazy.nvim を
  この input から取る**ので、副作用ではなく明示的な決定として扱うべきである(§3.6)。
- コストは引数が長くなることだけ(1 回の呼び出しで複数名を受ける。実測済み)。

### 3.6 lazy.nvim(seed input)の扱い

- **旧計画の「lockDir の lazy.nvim pin はまだ runtime に使われていないため無害」は誤り**。
  `nix/lib/make-env.nix:35` は `src = if hasLock then getSource pluginsDb.lazyNvim.inputName else lazyNvimSeed`
  であり、lock がある限り runtime の lazy.nvim は `lazy-nvim` input から来る。
  `lock-app.nix:49-51` の TODO(= issue #32)は**抽出時の seed**(常に nvimx 自身の flake input)に
  ついてのもので、runtime とは別の話である。
- したがって全体更新で `lazy-nvim` を動かすのは**ユーザーに見える変更**である。plan に明示的に含め、
  サマリに `lazy.nvim (seed)` として出す(§3.4)。名前指定モードでは `--update lazy.nvim` と
  書いたときだけ動く。
- 副作用として「抽出 seed(nvimx の flake input)と runtime lazy.nvim(lock)の skew」が起きやすくなる。
  これは `lock-app.nix:49-51` の既存 TODO(#32)そのものであり、本件で悪化はしないが顕在化しやすくなる(§7)。

### 3.7 home-manager ラッパの修正(旧計画より単純な方法)

旧計画は `case " $* " in *" --config "*)` で分岐する案だったが、**デフォルトを無条件に前置する**方が
単純かつ堅牢である:

```bash
project=${lib.escapeShellArg cfg.lock.projectDir}
project=''${project/#\~/$HOME}
exec ${nvimxLib.lockApp}/bin/nvimx-lock \
  --config "$project/"${lib.escapeShellArg cfg.lock.configDirRelative} \
  --out "$project/"${lib.escapeShellArg cfg.lock.lockDirRelative} \
  "$@"
```

根拠: lock-app のパーサ(`lock-app.nix:29-43`)は同名フラグの**後勝ち**なので、ユーザーが `--config` /
`--out` を明示すれば前置したデフォルトを上書きする。`--update` の名前取り込みループは `--` 前置で
止まるため、前置されたフラグが名前として吸われることもない(前置は `"$@"` より前にある)。
`$# -eq 0` の分岐そのものが消えて行数も減る。#25 の `--import-lazy-lock` も自動的に通る。

### 3.8 通常 lock(`--update` なし)への影響

なし。force 集合が空なら resolve は #18 の挙動そのままで、lock-app も §3.5 の手順 1 の `cp` と
手順 6(`nix flake update`)、手順 8 のサマリをスキップするだけ。
update-summary は `--update` 時のみ呼ぶ(通常 lock での「新規追加分の表示」まで欲張らない。やるなら別 issue)。

## 4. #18 / #23 / #36 / #25 との関係

### 4.1 #18(マージ済み)— 追加要求は無い

**旧計画が「#18 に追加で要求するもの」として挙げた 2 項目は、実装で既に満たされている**:

1. 「force 集合が名前集合を取り、resolvedRef 破棄と pin 凍結スキップの 2 条件を満たすこと」→
   `resolve.lua:449` の `prev = (prev_plugins and not force[name]) and ...` と、`:476` の凍結ガードが
   `unchanged` を含むことで**両方満たされている**。
2. 「収束パスの 2 回目 resolve が引数を組み立て直す構造であること」→ `lock-app.nix:134-137` は
   `resolve_args` を再利用せず `--prev` / `--lock` を直書きしているので、**何もしなくても `--update` は
   2 回目に渡らない**。

**実測による確認**(scratchpad にリポジトリを複製し、resolve.lua に §3.2 相当の約 20 行を足して
`tests/fixtures/merge/` を食わせた):

- steady state(pass1 → pass2)は `golden/base.plugins.json` と一致。
- `--update tokyonight.nvim`(pinned)→ tokyonight の `resolvedRef` が null に戻り、
  **他 3 エントリは jq 比較で完全一致**。plan には `tokyonight-nvim` の 1 行だけ。
- 裸 `--update` → pinned 2 件(`tokyonight.nvim` / `custom.nvim`)の凍結 rev は不変、
  plan には unpinned の 2 件(`plenary-nvim` / `telescope-nvim`)。
  **注意: このプロトタイプは `lazy-nvim` を plan に足す前の実装である。**§3.2 / §6.3 手順 3 の設計
  どおりなら全体更新モードの plan は `lazy-nvim` / `plenary-nvim` / `telescope-nvim` の **3 行**になる
  (再実測で確認済み)。golden と assert は 3 行を前提にすること。
- `--update` 無しで 2 回目 resolve(`--prev` = 上の出力、`--lock` = fixture)→ tokyonight が
  flake.lock の rev で再凍結され、**出力が steady state と byte-identical**(不動点)。

つまり §3.5 手順 6-7 の意味論は #18 の実装の上でそのまま成立する。前提とするのは
スキーマ最終形・`resolvedRef` の 3 値意味論・マージ不変条件 1・pin 凍結・2 パス収束である。

### 4.2 #23(semver、PR #51 でマージ済み)

- **`--update` は #23 の解決経路を「force で `resolvedRef` を捨てる」ことだけで呼ぶ**。#23 のゲートは
  「`entry.version` があり、マージと pin 凍結の後で `resolvedRef` が null、かつ `commit` / `tag` 未指定」
  (#23 §3.5)なので、force が `refs/tags/...` を破棄した瞬間に対象集合に入る。**本件側に追加の配線は無い**。
  #23 §4.3 も同じ結論を申し送っている。
- resolve.lua の呼び出しには `--lazy "$seed"` が既に付いている(#23 §5.4)ので、`--update` を足しても
  引数の組み立て以外に変更はない。
- **コスト**: 全体更新 + `defaults = { version = "*" }` では、force が全 unpinned の `resolvedRef` を
  捨てるので `ls-remote` が全プラグインに飛ぶ。さらに lock-app は resolve を 2 回呼ぶので最大 2 倍。
  #23 の 8 並列バッチが前提になる。#23 側の変更は不要だが、`--update` が最も重い経路であることを
  README / architecture.md に 1 行書く。
- **`--update` は通常 lock より失敗しやすい**: 明示 `version` で既に解決済みのタグが carry されていた
  プラグインを force すると再解決になり、上流がタグを消していれば #23 の分類 A/B で **fatal** になる
  (通常 lock なら carry されて成功していた)。仕様として受容し、§7 に残す。
- 進捗行の stdout / plan ファイルの棲み分けは §3.3 のとおり。
- `versionFromDefaults` はサマリでは使わない(§3.4 で理由を述べた)。

### 4.3 #36(table 形式 build、PR #50 でマージ済み)

- **`build` は spec 恒等性に入らない**(`resolve.lua:190` の `identity_fields` に無い。#36 §3.3 / §4 も
  「入れない」と明記)。したがって `build` が `{ kind = "steps", ... }` になっても force の判定・
  `resolvedRef`・flake.lock には一切影響しない。**確認済み・本件への影響なし**。
- 唯一の接点は `resolve.lua` のプラグインループの**編集位置の近さ**である。#36 は `classify_step` /
  `classify_build` / `build_phrasing` / 警告ブロックを、本件はループ先頭付近の force 参照(`:449`)と
  ループ前の名前検証を触る。同じ関数内だが別ブロックなので競合は小さい。着手時に `resolve.lua` を
  読み直すこと。
- #36 が足す fixture(`build-steps-config`)と check は本件と無関係。

### 4.4 #25(`--import-lazy-lock`、本件の後)

- #25 §4 は「`--update` と `--import-lazy-lock` の同時指定は lock-app が usage エラーで拒否する。
  #24 実装時にこの拒否を引き継ぐこと」と申し送っている。**本件時点では `--import-lazy-lock` が存在しない
  ので拒否は実装できない**。本件がやることは 2 つ:
  1. usage 文字列を `[--update [name...]]` の形にしておき、#25 が `[--update [name...] | --import-lazy-lock [path]]`
     へ拡張できる形にする。
  2. パーサの `--update` ケースに「#25 の `--import-lazy-lock` とは併用不可(#25 で拒否を入れる)」の
     コメントを残す。
- **#25 への申し送り(重要)**: #25 は収束パス(2 回目 resolve)にも自分のフラグを渡す必要がある
  (#25 §3.1)ため、`lock-app.nix:134-137` を `resolve_args` 共有形に組み替える誘惑がある。
  その際 **`--update` 系フラグだけは 2 回目に渡してはならない**(渡すと毎回凍結解除されて不動点に
  達しない)。本件はこの制約をコメントで明示しておく。
- import で seed された `resolvedRef` は force が破棄する(`architecture.md:262`「Returns to normal
  tracking at `--update` time」の実装)。本件側の追加実装は不要。

## 5. 実装手順

### 5.1 `nix/lib/lock-app.nix`

- `:3` — TODO から `--update [name...]` を落とす(`--import-lazy-lock` は残す)。
- `usage()`(`:22-25`)— `usage: nvimx-lock --config <configDir> --out <lockDir> [--update [name...]]`。
- パーサ(`:29-43`)— `update_mode` / `update_all` / `update_names` の **3 変数**を追加:
  ```bash
  --update)
    update_mode=1
    shift
    got=0
    while [ $# -gt 0 ] && [ "''${1#--}" = "$1" ]; do
      update_names+=("$1"); got=1; shift
    done
    # A --update that took no names at all is the "update everything" marker. It has to be
    # recorded separately: several --update occurrences collapse into one names array, so the
    # marker cannot be recovered from the array's length afterwards.
    [ "$got" -eq 1 ] || update_all=1
    ;;
  ```
  `update_mode=0` / `update_all=0` / `update_names=()` を `config=""` / `out=""` と並べて先に宣言する。
  空配列の**展開**は既存と同じ `''${a[@]+"''${a[@]}"}` ガードを使う(`set -u`)。
  要素数 `''${#update_names[@]}` は宣言済みの配列なら空でも安全(bash 5.3)。
- パーサ直後 — **裸 `--update` と名前指定の混在を lock-app 自身が弾く**(§3.1。これを入れないと
  `--update --update foo` が `--update foo` に化けて resolve.lua の混在エラーに到達しない):
  ```bash
  if [ "$update_all" -eq 1 ] && [ "''${#update_names[@]}" -gt 0 ]; then
    echo "nvimx-lock: --update takes either no names (update everything) or names, not both" >&2
    usage
  fi
  ```
- `:44-45` の後 — `--update` ガード(既存 lock、すなわち `$out/plugins.json` と `$out/flake.lock` の
  存在確認。無ければ「no existing lock to update; run nvimx-lock first」で exit 2)。
- sandbox 作成(`:53`)の後 — `cp "$out/flake.lock" "$sandbox/flake.lock.before"` と
  `cp "$out/plugins.json" "$sandbox/plugins.json.before"`(update_mode のときだけ)。
- `resolve_args`(`:87-93`)— update_mode なら、`update_all=1` のときは裸の `--update` を 1 個、
  そうでなければ**名前ごとに** `--update <name>` を積み、加えて
  `--update-plan "$sandbox/update-plan.txt"` を追加する。**`''${#update_names[@]}` の値からモードを
  復元してはならない**(上の混在チェックと同じ理由。`update_all` を直接見ること)。
- `nix flake lock`(`:115-116`)の**直後** — update_mode かつ plan が非空なら:
  ```bash
  mapfile -t update_inputs < "$sandbox/update-plan.txt"
  if [ "''${#update_inputs[@]}" -gt 0 ]; then
    echo "nvimx-lock: updating ''${#update_inputs[@]} input(s) with nix flake update" >&2
    (cd "$out" && nix flake update "''${update_inputs[@]}")
  fi
  ```
  `xargs` を使わないのは findutils が `runtimeInputs` に無いため(§1.1)。
- 収束パス(`:118-149`)— **変更なし**。`--update` を渡さないことをコメントで明示し、#25 への
  申し送り(§4.4)を 1 行添える。
- resolve.log 再表示(`:151-154`)の後 — update_mode のとき
  `nvim -l "${luaDir}/update-summary.lua" "$sandbox/plugins.json.before" "$out/plugins.json" "$sandbox/flake.lock.before" "$out/flake.lock" ''${update_names[@]+"''${update_names[@]}"}`
  を実行してから done メッセージ(`:156`)へ。
- **`update-summary.lua` 自身が失敗したときの挙動(明示的な決定)**: `|| true` や
  `|| echo "warning: summary failed"` で降格せず、**`set -o errexit` のまま非ゼロで死なせる**。
  - この時点で lock ファイルは**全部書けており**、実質的には成功した lock である。それでも
    nvimx-lock 全体は非ゼロ終了し、done メッセージも出ない。ユーザーには失敗に見える。
  - それでも受容する理由: サマリは純テキスト処理で、落ちるとすれば nvimx 側のバグである。
    降格するとそのバグが人にも CI にも見えなくなる。**バグは大声で表面化させる**方がよい。
    実害も小さい(ファイルは書けている。`nvimx-lock` の再実行は冪等で、2 回目は
    「no plugins updated」になるだけ)。
  - 予防線は `checks.update-summary`(§6.3)であり、そこが唯一の砦になる。この受容は §7 に 1 行残す。
  - `--update` 以外の経路(通常 lock)はサマリを呼ばないので、この risk は `--update` 限定である。

### 5.2 `lua/nvimx/resolve.lua`

シンボル基準で:

- ヘッダ Usage コメント(`:3-5`)— `--update` / `--update-plan` を追記。
- フラグループ冒頭コメント(`:28-29`)— 「#24 (--update [name...]) and #25 (--import-lazy-lock)
  add themselves here」は #24 実装後は半分だけ実現済みになる。「#24 はここに `--update` /
  `--update-plan` を足した。#25 (--import-lazy-lock) も同じ形で足せる」に書き換える(§5.6)。
- フラグループ(`:30-62`)— `--update`(先読み 1 語、繰り返し可)と `--update-plan <path>` を追加。
  裸 `--update` と名前付きの混在はエラー(**CLI からは lock-app が先に弾くので到達しない防御**。
  §3.1 / §3.2。コメントでそう明記する)。`usage()`(`:20-26`)の文言も更新。
- raw ロード(`:88`)の直後 — 名前検証(§3.1)。`raw.plugins[name]` の存在と `dev` / `dir` で分類し、
  `lazy.nvim` は plan 専用の特別扱い。did-you-mean は `to_input_name` を全キーに掛けて突き合わせる。
  **メインループより前**に置く(出力ファイルを書かないため)。
- **名前検証は 1 件目で死なず、全名前ぶん集めてから一括報告する**(#23 の流儀。§3.2)。実装上の注意:
  既存の `fail_plugin`(`:243-246`)は使えるが、その報告ブロック(`:735-746`)は**メインループの後**に
  あるので、そこに任せると「未知名で死ぬはずの run が semver 解決(ls-remote)まで走ってしまう」。
  したがって `:735-746` のソート + 出力 + `os.exit(1)` を `report_resolve_errors()` として小さく
  切り出し、**名前検証の直後**と既存位置の 2 か所から呼ぶのが最小の変更である。
  `fail_plugin` の第 1 引数(プラグイン名)がソートキーなので、未知名もそのまま渡せる。
  出力書式(`[nvimx] resolve failed: plugin "<name>": ...`)は既存と揃う。
- `local force = {}`(`:163-165`)— 名前指定なら指定集合(**`commit` 直書きのプラグインも除外しない**。
  §3.2)、全体更新なら `{ name | raw.plugins[name].pin が真でない、かつ local plugin でない }` を詰める。
  コメントを「#24 が埋める」から実装済みの説明に書き換える。
- ファイル末尾(`plugins.json` の write(`:771`)の後)— `--update-plan` 指定時に inputName をソートして
  書き出す。全体更新モードでは `lazyNvim.inputName` も含める。名前指定モードで `lazy.nvim` が
  指定されていたら含める。
- stylua(`column_width = 120`、2 スペース、ダブルクォート)/ luacheck clean(`std = "luajit"` +
  `globals = { "vim" }`)であること。

### 5.3 `lua/nvimx/update-summary.lua`(新規)

- §3.4 の CLI。`read_json` / flake.lock 走査(`sources.nix:6-12` と同じ構造)/ 7 桁短縮 / 行フォーマット
  のみの純テキスト処理。ネットワーク・外部プロセス依存なし(`vim.json.decode` のみ)。
- 名前指定モード: argv の名前 + `added` / `removed` に該当するものを報告し、残る「説明のつかない
  rev 移動」があれば警告行(§3.4 の限定規則をそのまま実装する)。
  全体更新モード: `plugins` 全キー + `lazy.nvim (seed)` を報告しカウント行を出す。
- 分類は before/after 両方の `plugins.json` と flake.lock から:
  - after の `plugins` にあり before の flake.lock に node が無い → `added`
  - **before の flake.lock に node があり after に無い → `removed`**(§3.4。素の `nix flake lock` が
    stale node を落とすので、名前指定モードでも起きる)
  - `pin` が真 かつ 名前指定されていない → `pinned (skipped)`
  - `commit` が非 null → `unchanged (commit-pinned in spec)`
  - rev が動いた → `updated`。指定外のものについては移動の理由を before/after の `plugins.json` から
    判定して `(version constraint resolved: refs/tags/x)` / `(spec changed)` を添え、**理由が付いた
    ものは警告に数えない**(§3.4)。理由判定に使う spec 恒等性の比較対象は `resolve.lua:190-191` の
    `identity_fields` + `source_fields` と同じフィールド集合にする。
  - どれにも当たらず rev も動いていない → `unchanged`
- ref の併記は §3.4 の限定規則(両方 `refs/tags/` のときだけ併記、40-hex 同士は併記しない)。
  `is_frozen_rev` / `is_tag_ref` 相当の 2 関数をこのファイルにも置く。
- カウント行は件数 0 の種別を省き、固定順(`updated` / `unchanged` / `pinned` / `added` / `removed`)。
- **このスクリプトが非ゼロ終了すると lock 全体が非ゼロで死ぬ**(§5.1 の決定)。したがって
  「入力 JSON にキーが無い」程度で `error()` しないこと。欠損は `nil` として扱い、行を落とすのではなく
  `unchanged` に倒す。落ちてよいのは本当に壊れた JSON を渡されたときだけ。
- stylua / luacheck clean。

### 5.4 `nix/home-manager/default.nix`

- `lockCommand`(`:15-29`)— §3.7 の無条件前置に置き換える。`$# -eq 0` の分岐を削除し、コメントを
  「デフォルトを前置する。lock-app のパーサは後勝ちなので明示指定が勝つ」に更新。
  `lock.projectDir` の option description(`:171-179`)の「running `nvimx-lock` without arguments targets ...」も
  「引数の有無にかかわらずデフォルトになる」に合わせて直す。

### 5.5 `lua/nvimx/genflake.lua` / `lua/nvimx/json.lua`

変更なし(URL 生成は `commit` > `resolvedRef` > `tag` > `branch` のままで足りる。確認のみ)。

### 5.6 ドキュメント

- `templates/default/README.md:25` — 「planned for Phase 6」を削除し、
  `nvimx-lock --update`(全部)/ `--update <name>...`(個別)の両形式 + pinned はスキップされる旨を書く。
- `README.md:101-102` の直後 — 更新の段落を追加(両形式、pinned のスキップと名前明示での更新、
  サマリが出ること、`--update` が最も重い経路であること)。
- `docs/architecture.md` — `:260` の `--update` 行を実装済みの記述に(pin 相互作用: スキップ +
  名前明示で凍結解除→再凍結、`lazy.nvim` seed も対象、サマリは flake.lock の before/after 比較)。
  `:250-262` の「Update semantics」全体の整合、`:439`(Updating)の確認、`:481` の checks 一覧に
  `resolve-update` / `update-summary` を追加。`:82` のシーケンス図は #25 が
  `[--update | --import-lazy-lock]` に直すので本件では触らない。
- `docs/architecture.md` の「Repository layout」(`:442-473`)— **旧版で抜けていた 2 か所**:
  - `lua/nvimx/` 一覧(`:465-470`)に `update-summary.lua # --update 実行の before/after 差分サマリ` の行
  - `tests/fixtures/` 行(`:472`)の列挙に `update/` を追加
- `docs/architecture.md:513` のフェーズ一覧「6. Version/update features: `resolve.lua` (semver),
  `--update [name]`, pin-preserving merge, `--import-lazy-lock`」— semver(#23)と本件が入ることで
  残るのは `--import-lazy-lock`(#25)だけになるので、実装済みの表記に寄せるか判断する(軽微。
  #34「architecture.md を実態に合わせる」に送ってもよい)。
- `lua/nvimx/resolve.lua:28-29` のフラグループ冒頭コメント — §5.2 のとおり書き換える
  (「#24 / #25 がここに自分を足す」という予告のうち #24 の分が実現するため)。
- `nix/lib/lock-app.nix` のヘッダコメント(`:3`)と usage は 5.1 に含む。

## 6. テスト

### 6.1 オフラインで検証できる範囲の切り方

3 層に分解し、上 2 層をオフラインで閉じる:

1. **resolve の force 意味論**(凍結解除・pinned スキップ・他エントリ不変・名前検証・plan の内容)—
   resolve.lua を固定入力で叩くだけで完全オフライン。
2. **サマリ生成** — update-summary.lua は手書きの before/after を食わせる純テキスト処理。
3. **lock-app の配線**(`nix flake lock` → `nix flake update` → 収束パス)— `nix flake *` は
   nix ビルド内で実行できない(recursive nix)ため checks にできない。§6.4 の手動検証に回す。
   #30 の `checks.e2e-offline`(`architecture.md:482`)が入れば埋められる。
   例外は **lock-app の引数パーサ**で、usage エラーは `nix` を一度も呼ばずに exit 2 するため、
   `nvimxLib.lockApp` を `nativeBuildInputs` に入れれば checks から叩ける(§6.3 手順 10)。

### 6.2 フィクスチャ

`tests/fixtures/merge/` を再利用し、update 固有分だけ足す。

**前提の確認(#23 マージ後に検証済み)**: `tests/fixtures/merge/raw-spec-{base,added,branch-changed}.json`
から `telescope.nvim.version` は**既に落ちている**(#23 §6.5。version 制約付きの経路は `resolve-semver` に
集約された)。merge fixture の raw-spec には `version` キーが 1 つも無いので、これを使う限り `--lazy` は
不要で `ls-remote` も飛ばない。

merge fixture の構成は pinned + branch(`tokyonight.nvim`、github type)/ pinned + branch(`custom.nvim`、
git type)/ 素(`telescope.nvim`、`plenary.nvim`)で、update の場合分け(pinned スキップ・pinned 明示・
素の force)をそのまま賄える。`flake.lock` は tokyonight = `aaaa...` / custom = `bbbb...` / telescope = `cccc...`、
plenary は node なし。

```
tests/fixtures/update/
  raw-spec-commit.json           # merge/raw-spec-base.json + `commit` 直書きのプラグイン 1 件
                                 # (名前指定した commit 固定プラグインが plan に入ることの固定用。§3.2)
  flake.lock.after               # merge/flake.lock の 1 input だけ rev を変えた手書き lock
  plugins.json.before            # サマリ用の before(merge/golden/base.plugins.json 相当 + タグ/削除の例)
  plugins.json.after             # サマリ用の after(added / removed / タグ移動 / フォールバック解決を含む)
  flake.lock.summary-{before,after}.json
                                 # サマリ用。after 側は 1 node 追加・1 node 削除・数件の rev 移動
  golden/
    update-pinned.plugins.json   # --update <pinned名> 後の期待出力
    summary-named.txt            # 名前指定モードのサマリ期待出力(removed 行と警告行を含む)
    summary-all.txt              # 全体更新モードのサマリ期待出力(pinned skip 行とカウント行を含む)
    summary-none.txt             # 何も動いていない場合(`no plugins updated`)
```

`_comment` に「ネットワークを要する経路は持たない / rev はプレースホルダ」を書く(既存 fixture の流儀)。

### 6.3 `checks` への繋ぎ方

`flake.nix` の `checks`(`:154` の `forAllSystems`)に 2 つ追加する。`resolve-merge`(`:1350` から)/
`resolve-semver`(`:1577` から)と同型の `pkgs.runCommand`(`nativeBuildInputs = [ neovim-unwrapped jq ]`、
`export HOME=$TMPDIR`、`lua=${./lua/nvimx}` でディレクトリごと渡す)。挿入位置は `resolve-semver` の直後。

**`checks.resolve-update`**(完全オフライン、git 不要):

1. **steady state 準備**: `resolve.lua raw-spec-base pass1.json --lock merge/flake.lock` →
   `resolve.lua raw-spec-base out1.json --prev pass1.json --lock merge/flake.lock`
   (golden 一致の assert は `resolve-merge` の担当なので省略)。
2. **名前指定 = 凍結解除 + 他は不変**: `--update tokyonight.nvim --update-plan plan.txt` →
   `diff -u update/golden/update-pinned.plugins.json out2.json`。jq で tokyonight の
   `resolvedRef == null`、**他 3 エントリが out1 と完全一致**(`diff <(jq -S ...) <(jq -S ...)`、
   `resolve-merge:1396-1397` と同じ流儀)。`plan.txt` が `tokyonight-nvim` の 1 行のみであることも assert。
3. **全体更新 = pinned スキップ**: 裸 `--update` → pinned 2 件の `resolvedRef` が out1 の凍結 rev のまま、
   plan が **`lazy-nvim` / `plenary-nvim` / `telescope-nvim` の 3 行ちょうど**(ソート済み)であることを
   assert(pinned の `tokyonight-nvim` / `custom-nvim` が plan に**入っていない**ことの assert が本体)。
4. **`--update lazy.nvim`**: plan が `lazy-nvim` の 1 行のみで、`plugins.json` が out1 と byte-identical。
5. **未知名は全件まとめて報告される**: `--update no-such-plugin also-missing` が非ゼロ終了し、
   stderr に **2 件とも**名指しされること(1 件目で死んでいないこと。§3.2 / §5.2)。
   **出力ファイルが書かれていない**(`[ ! -f out.json ]`)。inputName を打った場合に did-you-mean が
   出ることも grep。
6. **local plugin 名**: 専用メッセージで非ゼロ終了(`tests/fixtures/local-plugin` 由来の extract 結果か
   手書き raw-spec)。未知名と混ぜて渡し、**両方の種類のエラーが 1 回で出る**ことも見る。
7. **裸と名前の混在(resolve.lua 側の防御)**: `--update --update foo` 相当がエラー。
   CLI から到達するのは lock-app 側の拒否(手順 10)であり、こちらは手叩き用の防御である。
8. **名前指定した commit 固定プラグイン**: `update/raw-spec-commit.json` で `--update <commit 固定名>` →
   エントリの `commit` は不変(URL が動かないので実害なし)で、**その inputName が plan に入る**ことを
   assert する(§3.2 の決定を golden で固定する。plan は `nix flake update` の引数になるが、
   rev 焼き込み URL は動かせないので no-op である)。
9. **収束パス相当の不動点**: 手順 2 の out2 を `--prev out2.json --lock update/flake.lock.after` で
   (`--update` なしで)再 resolve → pinned エントリが `flake.lock.after` の新 rev で再凍結される。
   さらにもう 1 回同じ引数で回して byte-identical(3 回目が不要であることの固定点)。
10. **lock-app のパーサ拒否**(`nix` を呼ばないので checks に載る): `nativeBuildInputs` に
    `nvimxLib.lockApp` を入れ、`nvimx-lock --config c --out o --update --update foo` が
    **exit 2 で usage を出す**ことを assert する。§3.1 の混在エラーが CLI から到達可能であることの
    唯一の自動検証であり、旧版が落とし穴にはまった箇所そのものなので入れる価値が高い。
    ビルド依存が重くなる等で難しければ §6.4 の手動検証に落とす。
11. **version 制約との合流**: `mkTagRepoSh` は既に `flake.nix:166` の共有 `let` にあるので(#23 §7 の
    未決事項は「共有する」で決着済み)、そのまま使える。タグ付きローカルリポジトリを立て、
    `resolvedRef = "refs/tags/v1.0.0"` を持つ prev を `--update <name>` で force →
    `refs/tags/v1.2.5` に再解決されることを assert。この手順だけ `pkgs.git` が要る。

**`checks.update-summary`**(新設、完全オフライン、`neovim-unwrapped` のみ):

- `update-summary.lua` に fixture の before/after を食わせ、stderr を
  `diff -u update/golden/summary-named.txt` / `summary-all.txt` / `summary-none.txt` と比較。
- `updated` / `unchanged` / `unchanged (commit-pinned in spec)` / `pinned (skipped)` / `added` /
  **`removed`** の 6 パターンの行、`refs/tags/...` 併記、カウント行、`lazy.nvim (seed)` 行を固定する。
- **ref 併記の限定規則**(§3.4)を固定する: タグ同士の移動では併記される、**40-hex 同士(pin の
  再凍結)では併記されず rev 行だけになる**、null → `refs/tags/` では理由だけが添えられる。
- **警告行の対象が限定されていること**を固定する:
  - 指定外プラグインの rev が `resolvedRef` null → `refs/tags/...` に伴って動いた場合、警告ではなく
    `updated ... (version constraint resolved: ...)` になる(§3.4 の偽陽性経路)。
  - 指定外プラグインの spec 恒等性が変わって動いた場合も警告ではなく `updated ... (spec changed)`。
  - 指定外プラグインが消えた場合は警告ではなく `removed` 行。
  - 上記のいずれでもない指定外の rev 移動**だけ**が `warning: N input(s) moved without being named:` を
    出すこと。
- 何も動いていない場合の `no plugins updated` を assert。

### 6.4 手動検証(ネットワーク必須、PR 本文に結果を貼る)

- 実 config で `nvimx-lock --update <1 プラグイン>` → 前後の `plugins.json` / `flake.lock` を `git diff` し、
  該当 input の node 以外に差分が無いこと(Done when 1)。サマリの内容が diff と一致すること。
  **spec を一切編集していない状態で実行すること**(削除やフォールバック解決が混ざると byte-identical は
  成立しない。§2-1 の条件)。もし指定外の node が動いたら、サマリがそれを `removed` /
  `updated (...)` / 警告のどれで説明したかを PR 本文に書く。
- `nvimx-lock --update --update foo` が exit 2 で usage を出すこと(§3.1 の混在拒否。
  §6.3 手順 10 を入れなかった場合は**ここが唯一の検証**になる)。
- `nvimx-lock --update` → pinned の node が不変で、サマリの `pinned` 行が出ること。
  `lazy-nvim` が動いてサマリに出ること。所要時間(#23 の ls-remote が全プラグインに飛ぶ)を測る。
- pinned プラグインの名前指定 → 実行後に `plugins.json` の `resolvedRef` が**新しい 40 桁 rev** で
  再凍結され、生成 `flake.nix` の URL にその rev が入っていること(凍結解除 → 再凍結の一巡)。
- `projectDir` を設定した home-manager 環境で `nvimx-lock --update <name>` が動くこと(§3.7)。
- `nvimx-lock --update no-such-plugin` が lock を書き換えずに落ちること(`git status` が clean)。

### 6.5 CI / darwin

- `.github/workflows/check.yml` は `nix flake check` と `nix fmt -- --ci` を回すだけ(`:16-22`)なので、
  `checks` に 2 つ足せば両系統の CI に自動的に乗る。**ワークフローの編集は不要**。仮にステップ追加が
  必要になっても、`CLAUDE.md` の規約どおり編集するのは reusable workflow の `check.yml` のみで、
  `ci-linux.yml` / `ci-darwin.yml` は触らない(badge を per-workflow にするための構造)。
- ローカル(linux)の `nix flake check` は darwin を `omitted these incompatible systems` でスキップするので、
  `nix eval .#checks.aarch64-darwin.resolve-update.drvPath` と
  `nix eval .#checks.aarch64-darwin.update-summary.drvPath` で評価だけ通す(`CLAUDE.md` の規約)。
  新 check は `neovim-unwrapped` / `jq` のみで darwin 固有の落とし穴には触れない。
- `nix fmt -- --ci` で新規 lua(`update-summary.lua`)が stylua 済み・luacheck clean であることを確認(#31)。

## 7. リスク / 未決事項

- **`nix flake update <input>` のサポート下限**: 位置引数形式は nix 2.19 以降(それ以前は
  `nix flake lock --update-input <input>`)。手元の 2.34.8 で動作確認済み。フォールバックは
  **実装しない**(テスト不能なパスが増える)。README に最低 nix バージョンを 1 行明記する。
  現状リポジトリのどこにも下限が書かれていないので、本件がその最初の記述になる。
- **`nix flake update <未知名>` が exit 0 で黙る**(実測)。したがって plan ファイルに誤った inputName が
  入っても nix は何も言わない。§6.3 手順 2-4 / 8 の plan 内容 assert がこの唯一の防波堤である
  (名前指定した commit 固定プラグインが plan に入るという §3.2 の決定も、この assert で固定される)。
- **`--update` は通常 lock より失敗しやすい**(#23 との相互作用): 明示 `version` の解決済みタグを
  force で捨てて再解決した結果、上流がタグを消していれば #23 の分類 A/B で fatal になる。
  仕様として受容する(名前を明示した = 動かす意図)。エラーメッセージは #23 のものがそのまま使える。
- **全体更新が `lazy-nvim` を動かす**: `make-env.nix:35` により runtime の lazy.nvim が進む。
  抽出 seed(`lock-app.nix:49-51` の TODO により常に nvimx 自身の flake input)との skew が
  顕在化しやすくなる。skew 自体は既存の TODO の問題であり本件で悪化はしないが、`--update` を
  常用すると踏みやすくなる。**この TODO は issue #32(`fix(lock): use the locked lazy.nvim as the
  extraction seed`)として起票済み**で、本件の次の次に着手する予定である。
- **spec に `"folke/lazy.nvim"` を書くと生成 flake が壊れる(既存バグ、実測確認済み)**:
  `to_input_name("lazy.nvim") == "lazy-nvim"` が synthetic な `lazyNvim.inputName` と衝突し、
  genflake が `lazy-nvim` を 2 回出力して flake の評価が失敗する。`seen_inputs`(`resolve.lua:267`、
  衝突検査は `:416-419`)は synthetic エントリを見ていない。**本件の範囲外。
  issue #49(`fix(resolve): a spec that lists lazy.nvim collides with the synthetic lazy-nvim input`、
  OPEN)として起票済み**なので、本件で新たに起票することは無い(#25 の計画書 §4.4 も #49 を参照している)。
  なお #23 §3.7 の「ユーザーが spec に lazy.nvim を書いた場合は通常プラグインとして普通に解決される」
  という記述はこの点で誤っている(#49 の本文にも記載済み)。
- **`--update` 中の途中失敗**: `nix flake update` が失敗すると flake.lock が中途半端に進む可能性がある。
  lockDir は git 管理前提(README が commit を指示)なので `git diff` / `checkout` で戻せるが、
  lock-app 自身はロールバックしない。既存の通常 lock も同じ性質で本件で悪化はしない。
  途中で落ちた場合はサマリまで到達しない(最小方針)。
- **サマリ自体が落ちると「成功した lock が失敗に見える」**: `update-summary.lua` は lock ファイルを
  全部書き終えた後に走るので、そこで非ゼロ終了すると `set -o errexit` により nvimx-lock 全体が
  非ゼロで死ぬ。ユーザーには失敗に見えるが、実際には lock は完成している。**これは受容する**
  (§5.1 の決定。降格するとサマリのバグが誰にも見えなくなる)。再実行は冪等なので実害は小さい。
- **サマリの網羅性と偽陽性経路**: 凍結解除直後の `nix flake lock` が動かした rev も before/after 比較で
  `updated` に含まれる(実測: URL が rev → branch に変わった input は plain lock で HEAD まで進む)。
  これは意図どおり(ユーザーから見れば更新)。
  **名前指定モードで指定外の input が動く経路は「URL が変わらない限り起きない」わけではない**:
  1. spec からプラグインが消えていれば素の `nix flake lock` が stale node を落とす(実測)。
  2. `defaults.version` フォールバック中のプラグイン(`resolvedRef` が null)は毎回 ls-remote に
     再照会されるので(§1.2、`resolve.lua:492` / `lock-app.nix:123-133`)、remote に適合タグが出現した
     瞬間に `resolvedRef` が `refs/tags/...` になり URL が変わって素の `nix flake lock` が動かす。
     **これは通常 lock でも起きる正当な挙動である。**
  3. ユーザーが指定外プラグインの spec を編集していれば当然動く。
  1-3 を素朴に警告すると誤警報になるので、§3.4 は 1 を `removed` 行、2 と 3 を理由付きの `updated` 行に
  分類し、**残りだけ**を警告にする。この分類が緩すぎ/厳しすぎた場合の調整は運用しながら決める。
- **`--import-lazy-lock` との併用拒否は #25 が実装する**。本件は usage の形とコメントだけを用意する(§4.4)。
- **プラグイン名の shell 引用**: lock-app → resolve.lua → plan ファイル → `nix flake update` の受け渡しは
  すべて bash 配列 / ファイル経由にして word splitting を避ける(`"''${update_names[@]}"`、`mapfile`)。
- **did-you-mean の範囲**: inputName 一致のみ提案し、編集距離によるあいまい提案はやらない
  (誤提案のリスクが実装コストを上回る)。不足が出たら別 issue。
- **`resolve.lua` の肥大**: 本件で名前検証 + force 構築 + plan 出力が加わり、#23 の semver 解決も同じ
  ファイルに入る。分割(`update.lua` への切り出し等)はレビューで判断する。純関数部分が少ない
  (raw-spec 全体を見る検証と argv 解釈)ので、本計画では切り出さない方針とする。
