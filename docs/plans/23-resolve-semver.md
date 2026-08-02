# #23 対応計画: git ls-remote による semver 制約の解決

対象 issue: [#23 feat(resolve): resolve semver constraints via git ls-remote](https://github.com/myuron/nvimx/issues/23)

Depends on #18(マージ済み)/ #42。着手順は **#43 → #42 → #31 → #36 → #23** で、本件は最後に入る。

**本計画は #42(PR #46)のマージを受けた改訂版である。** 旧版は #42 より前に書かれており、その中心方針(「制約にマッチするタグが 1 つも無ければハードエラー」)が `defaults.version` の実体化と正面衝突する。`docs/plans/42-extract-defaults-version.md` §4.2 がその衝突を指摘し 3 つの選択肢を示しており、本改訂はその選択肢 2(**制約の出自で重大度を分ける**)を採用して全体を組み直したものである。旧版から実質的に変わったのは §3.4(新設・改訂の中心)、§3.6、§5.1-5.2、§6 全体、§7。

### 行番号の扱い(重要)

本文の `file:line` は執筆時の作業ツリー(`ae9bf2c` = main `18a28b3` + #42)基準である。着手時点では:

- **#31**(stylua / luacheck による一括整形)が `lua/**/*.lua` と `tests/**/*.lua` を全部整形するため、lua の行番号は**全ファイルでずれる**。
- **#36**(table-form build)が `resolve.lua` のプラグインループ内(`classify_step` / `build_phrasing` / `warn_plugin` 周辺)を書き換えるため、本件が触るループの行位置もずれる。
- `flake.nix` も #31 / #36 が check を追加するためずれる。
- **`docs/architecture.md` も #36 のドキュメント追記でずれる。** 実測での対応(執筆時 → 現時点): semver 段落 `:227` → `:241`、URL マッピング表 `:217-225` → `:229-239`、fixtures 一覧 `:431` → `:462`、checks 一覧 `:440` → `:471`、pin 行 `:235` → `:238`、`resolvedRef` の 3 値表 `:205-211` → `:219-225`、マージ契約 `:233` → `:227`。**§5.6 のドキュメント作業は必ず現物を grep してから当てること**(見出し `### lazy spec → flake input URL mapping` / `### Update semantics`、太字 `**semver resolution**` / `**Merge contract.**` が主キー)。

したがって **位置指定はシンボルを主キーとして読むこと**: 関数名(`effective_version` / `dump_plugin` / `same_identity` / `warn_plugin` / `input_url`)、変数名(`identity_fields` / `plugin_warnings` / `safe_opts` / `runtimeInputs`)、check 名(`extractor-defaults-version` / `resolve-merge` / `resolve-build-warnings`)、コメントの文言。行番号は補助にすぎない。

lazy.nvim 側の行番号は pin された seed(`flake.lock` の `lazy-nvim`、rev `306a055`、store path `/nix/store/d9jq3s81p4i9q6g8gaa6f2pn51p8za9l-source`)の実ソースを読んで確認したものである。

## 1. 背景 / 現状

### 1.1 nvimx 側

- `lua/nvimx/resolve.lua:333-350`(`if p.version then` ブロック)が、マージ後もなお未解決の制約に対して `version constraint %q is not resolved yet (TODO: semver)` を warn するだけで素通りする。`resolvedRef` は初期値 `vim.NIL`(`:302`)のまま。ヘッダの TODO は `:11`。
- その結果 `version = "^1.2"` を書いたプラグインは `genflake.lua` のデフォルト分岐に落ち、**黙って default branch の HEAD を追う**。issue の主目的はこの穴を塞ぐこと。
- **#18 は #23 の足場を既に敷いている**(旧計画が「#18 に追加要求」としていた項目は消化済み):
  - `is_frozen_rev`(`resolve.lua:100-104`)/ `is_tag_ref`(`:106-110`)が既にあり、コメントも「`refs/tags/...` は #23 が書く」と明言している。
  - `resolve.lua:313-320` の unpin 処理は「pin 由来の 40-hex 凍結だけを落とし、semver 由来の `refs/tags/...` は残す」と既に書き分けてある。
  - `genflake.lua:41-68`(git type)は `resolvedRef` が 40-hex なら `?rev=`、そうでなければ `?ref=` にディスパッチ済み(`:46-54`)。github type(`:27-39`)も `commit` > `resolvedRef` > `tag` > `branch`。**#23 で genflake の変更は不要**(検証のみ)。
  - フラグループ(`resolve.lua:27-57`)は未知フラグをエラーにする `while` ループで、`--lazy` をそのまま足せる。
- `lua/nvimx/extract.lua` は #42 で `effective_version`(`:45-69`)を持ち、`defaults.version` を各プラグインに実体化する。ただし **`dump_plugin`(`:71-93`)には制約の出自情報が無い**(`version` の実効値だけを返す)。#42 §3.6 / §5.1-3 が「#23 が必要とするなら raw-spec にだけ 1 行足す」と設計余地を残しており、**その 1 行を足すのが本件の仕事**である。
- `nix/lib/lock-app.nix:10-15` の `runtimeInputs` は `coreutils` / `diffutils` / `neovim-unwrapped` / `nixfmt-rfc-style` のみで **git を含まない**(`nix flake lock` は Nix 内蔵 fetcher を使うため今まで不要だった)。resolve.lua の呼び出しは 2 箇所(`:95-97` と収束パスの `:121-123`)、seed は `:46` の `$seed`。
- lock は意図的に impure な工程(`lock-app.nix:1-2`)。`docs/architecture.md:74-93` のシーケンス図と `:119-120`(設計原則 3)、`:141-147`、`:227` に既に本機能の意図が書かれている。

### 1.2 lazy.nvim 側(実読)

- `lua/lazy/manage/semver.lua`(全 193 行)は **`require` を 1 つも持たない自己完結モジュール**。外部依存は `vim.split`(`:142,153`)と `vim.deepcopy`(`:161`)だけで、どちらも `nvim -l` で使える。`dofile` で直接ロードできる(実測確認済み)。
- `M.version(tag)`(`:78-97`)は `^v?(%d+)%.?(%d*)%.?(%d*)%-?([^+]*)+?(.*)$` の 1 パターン。`v` 接頭辞 / prerelease / build metadata を吸収し、`input` に**原文のタグ名**を残す。パース不能なら nil。
- `M.range(spec)`(`:132-191`)の実測結果:

  | spec | from | to |
  |---|---|---|
  | `*` / `""` | 0.0.0 | (なし) |
  | `^1.2` | 1.2.0 | 2.0.0 |
  | `~1.2` | 1.2.0 | 1.3.0 |
  | `>=1.2.3` | 1.2.3 | (なし) |
  | `>1.2.3` | 1.2.4 | (なし) |
  | `=1.2.3` / `1.2.3` / `v1.2.3` | 1.2.3 | 1.2.4 |
  | `1.2` | 1.2.0 | 1.3.0(修飾子なし 3 要素未満は `~` 扱い、`:154-156`) |
  | `1.x` | 1.0.0 | 2.0.0 |
  | `1.2 - 2.0` | 1.2.0 | 2.1.0 |
  | `<1.0` | **nil**(`<` は文法に無い) | |
  | `foo` | **nil** | |

- `Range:matches(v)`(`:118-129`)は `version.prerelease ~= self.from.prerelease` を即 false にする。つまり **prerelease タグは制約側が同じ prerelease を持たない限りマッチしない**(`^1.2` は `v2.1.0-beta` を選ばない。実測確認)。
- 選択は `M.last`(`:102-110`)= `>` による線形最大。**空配列には nil を返す**。同値(`__eq` は build metadata を無視)のタイでは**入力順で先のものが残る**。
- lazy 本体の選択ロジックは `get_versions`(`git.lua:51-64`)+ `get_target`(`:118-153`)。`get_target` の分岐順は `commit`(`:127`)> `tag`(`:133`)> `version`(`:141`)> HEAD(`:153`)で、**`tag` が指定されていれば `version` は見ない**。
- **`git.lua:142-152` は「制約を満たすタグが無ければ黙って `:153` の branch HEAD に落ちる」。** タグを 1 つも打っていないプラグインは普通に存在するので、これは例外処理ではなく通常動作である。lazy 自身のテンプレートコメント(`lua/lazy/core/config.lua:16`、"**try** installing the latest stable version **for plugins that support semver**")もこの前提の文言。→ §3.4 の根拠。
- なお `Semver.range(spec)` が nil のとき `get_versions` は `range:matches` で nil を index して**ランタイムエラー**になる。正確には `git.lua:58` が `if v and range:matches(v)` と書いており `v`(= `Semver.version(tag)`)が nil なら短絡するので、**semver としてパースできるタグが 1 件以上あるときに踏む**(`stable` / `nightly` しか無いリポジトリでは踏まない)。いずれにせよ文法エラーは lazy でも致命的である。

### 1.3 `git ls-remote` と nix fetcher(実測)

- `git ls-remote --tags --refs <url>` は peeled 表記(`refs/tags/x^{}`)を出力から除外し、`SHA\trefs/tags/NAME` を ref 名の昇順で返す。annotated tag では `--refs` 無しなら tag object の SHA と peeled commit の 2 行が出るが、`--refs` があれば tag object の 1 行だけになる(実測: git 2.55)。
- 失敗は exit 128 + stderr(存在しないパス / 名前解決失敗のいずれも実測)。タグが 0 件のリポジトリは **exit 0 + 空 stdout**。
- `vim.system({...}):wait()` は `nvim -l` で動く。**複数ハンドルを起動してから順に `:wait()` すると実際に並列実行される**(4 × `sleep 1` が 1.01s で完了。実測)。
- **`refs/tags/<tag>` は nix の両 type でそのまま通る**(旧計画 §7 の未決事項を実測で解消):
  - `builtins.parseFlakeRef "github:folke/tokyonight.nvim/refs/tags/v4.9.0"` → `{ ref = "refs/tags/v4.9.0"; }`。実 fetch で rev `19f39b5…`(= そのタグの SHA)に解決。
  - `git+file://<path>?ref=refs/tags/<annotated tag>` は **tag object ではなく peel された commit** を rev に記録する(実測: tag object `8e5e09c` / commit `2d757f7` のリポジトリで rev = `2d757f7`)。
  - ローカルパスをリモートに使う場合、**flake ref は `git+file://<abs path>` でなければならない**(`git+<bare path>` は `parseFlakeRef` がエラー)。`git ls-remote file://<path>` は通る。→ §6 の fixture URL は `file://` 付きにする。

### 1.4 既存 check の地雷(旧計画が見落としていた点)

#18 が `tests/fixtures/merge/` に `version = "^0.1"` を持つプラグイン(telescope.nvim、github URL)を入れたため、**#23 の解決ゲートが発火する箇所が既存 check の中に 3 つある**。nix サンドボックスにネットワークは無いので、いずれも `git ls-remote` の失敗 = ハードエラーになり、**assert に到達する前に check が落ちる**:

1. `flake.nix` の `resolve-merge`(`:1046-1249`)— `raw-spec-base.json` / `raw-spec-added.json` / `raw-spec-branch-changed.json` の telescope が `version = "^0.1"` + `resolvedRef = null`。`--prev` 無しの `pass1`(`:1067`)を含め十数回 resolve される。
2. 同 check の pin+version ブロック(`:1148-1167`)— jq で tokyonight に `version = "^1.0"` を注入し、`--prev` 無しで resolve する(`out9a`)。
3. 同 check の extractor 通しの末尾(`:1212-1247`)— `merge-config/init.lua:21` の telescope が `version = "^0.1"`。
4. `extractor-defaults-version`(`:894-963`)の `plugins.json` セクション(`:940-955`)— github type の `*` / `^0.1` 制約を resolve に通す。**flake.nix `:951-954` に「#23 で作り直す」旨のコメントが既に入っている。**

**#23 のスコープにはこの 4 箇所の作り直しが含まれる。** §6.4-6.5 で扱う。

## 2. ゴール

issue の "Done when" を検証可能な形にすると:

1. **解決の実体**: `version = "^1.2"` を持つ fixture プラグインが、リモートのタグ一覧から制約を満たす最大のタグに解決され、`plugins.json` の `resolvedRef` に `refs/tags/<タグ名>`(原文ママ)が入る。genflake を通すと該当 input の URL がそのタグを指す。
2. **明示制約の失敗は fatal**: **ユーザーがプラグインに明示的に書いた** `version` が満たせない(マッチなし / タグ 0 件)場合、HEAD へ黙って落ちず、プラグイン名・制約・URL・候補タグを含むエラーで resolve.lua が非ゼロ終了し、lock 全体が失敗する。
3. **`defaults.version` 由来の失敗は warning + HEAD**: `defaults.version` から実体化された制約が満たせない場合は lazy と同じく branch HEAD に落ち、**lock は成功する**。落ちた事実は stderr に集約報告される。`defaults = { version = "*" }` と 1 行書いた lazy 互換 config が lock 可能であること。
4. **環境エラーと文法エラーは出自を問わず fatal**: `git ls-remote` 自体の失敗、および `Semver.range` がパースできない制約。
5. **オフラインの単体テスト**: semver 選択と ls-remote 出力パースが、ネットワーク無しの `checks` で assert される。
6. **暫定 warning の削除**: `resolve.lua` の `is not resolved yet (TODO: semver)` を削除。version 制約は「解決される」「fallback して報告される」「エラー」の三択になり、"未解決" という状態は無くなる。
7. **解決結果の永続と決定性**: 解決済みタグは #18 の契約 1 により spec 不変な次回 lock でネットワークアクセスなしに引き継がれる(リモートを消しても `--prev` 付き再実行が byte-identical)。同じタグ集合に対する出力は byte-identical。

## 3. 設計

### 3.1 semver マッチング: lazy.manage.semver をそのまま dofile する(維持)

- **採用**: seed の `lua/lazy/manage/semver.lua` を `dofile` でロードし、`M.version` / `M.range` / `M.last` を**無改変**で使う。§1.2 の全文法がそのままカバーされ、prerelease の扱いも lazy と bit-exact に一致する。`docs/architecture.md:119-120`(設計原則 3)の実装。
- 却下案: nvimx 側に semver を再実装。lazy とのズレ(特に prerelease と修飾子なし 2 要素の `~` 化)が事故源になり、追従コストだけ増える。
- **ロード経路**: `resolve.lua` に `--lazy <lazy.nvim のパス>` を追加し、`dofile(lazy_dir .. "/lua/lazy/manage/semver.lua")` する。lock-app は `$seed`(`lock-app.nix:46`)を渡す。ロードは**解決対象が 1 件以上あるときだけ**行う(遅延)。
  - `--lazy` が無いのに解決が必要になったら**ハードエラー**(`resolve: a version constraint needs --lazy <lazy.nvim path>`)。呼び出し側のバグとして顕在化させる。テスト用に「`--lazy` が無ければ解決をスキップ」にする案は**却下**: ゴール 6 の「未解決という状態を無くす」を裏口から復活させ、check が nvimx-lock と違う挙動を検証することになる。
  - 却下案: raw-spec の `lazyNvim.source`(`extract.lua:125` が seed の store path を書いている)から暗黙に引く。skew が起きない利点はあるが、`tests/fixtures/merge/*.json` の手書き raw-spec は `lazyNvim` を持たないため「ある fixture では動きある fixture では動かない」暗黙依存になる。argv 経由の明示を採る(#18 のフラグループ設計と一貫)。
  - パス不正のとき(`semver.lua` が無い / dofile が失敗)は、その旨と与えられたパスを出して fatal。

### 3.2 ls-remote の呼び方: resolve.lua から vim.system を並列で

- **採用**: 解決対象ごとに `vim.system({ "git", "ls-remote", "--tags", "--refs", url }, { text = true, env = { GIT_TERMINAL_PROMPT = "0" }, timeout = 60000 })` を起動し、**最大 8 本の並列バッチ**で回して `:wait()` する。
  - 場所の理由: 「どのプラグインがタグ一覧を必要とするか」はマージ後の resolve.lua しか知らない(解決対象 = `version ~= nil` ∧ マージ後 `resolvedRef == null` ∧ `commit`/`tag` 未指定)。lock-app 側で事前取得すると raw-spec と prev の解釈を bash + jq に複製することになる。
  - **並列化は「将来の最適化」ではなく本件のスコープに入れる。** #42 以降 `defaults = { version = "*" }` の config では解決対象が**全プラグイン**になり、さらに lock-app は resolve を 2 回呼ぶ(`:95-97` と `:121-123`)。fallback したプラグインは `resolvedRef` が null のままなので 2 回目も再問い合わせされる。つまり逐次だと `2 × プラグイン数 × ls-remote` が lock の所要時間を支配する。実測どおり `vim.system` は `nvim -l` でも並列に走る(§1.3)ので、コード量はほぼ増えない。
  - 上限 8 の理由: 上限なしで 100 リモートを同時に開くと fd / プロセス数と相手側のレート制限が読めない。8 は「体感で十分速く、資源が読める」線。定数 1 箇所で調整可能にしておく。
  - `--refs` で peeled 表記を出力から除外する(git 2.8+。nixpkgs の git は常に満たす)。防御として parse 側でも `^{}` 終端の行はスキップする。SHA 列は使わない: `resolvedRef` にはタグ ref を書き、コミットへの固定は `nix flake lock` の仕事(annotated tag でも fetcher が peel する。§1.3 で実測)。
  - `GIT_TERMINAL_PROMPT=0` で認証プロンプトを殺し、失敗として顕在化させる。`timeout` はリモート 1 本あたり 60s。`signal ~= 0` / `code == 124` 相当も失敗として扱う。
  - 却下案: `io.popen`。シェルクォート・stderr 分離・timeout・並列の全部が手作りになる。
- **リモート URL は raw-spec の `p.url` をそのまま使う。** lazy が正規化した URL(`https://github.com/<owner>/<repo>.git` 等)であり、これが lazy 自身が fetch する URL でもある。`source` 構造体から再構築する案は却下: `parse_source`(`resolve.lua:166-174`)が `.git` を落としているので復元規則が二重定義になる。`p.url` が無い/文字列でないときは fatal。
- ローカルパス(`file://…`)も git の有効なリモートなので、テストは raw-spec の url にサンドボックス内 `git init` したリポジトリを書くだけでネットワークを切れる(§6)。
- 進捗は **stdout** に出す(stderr は `lock-app.nix:95-97` が `resolve.log` に握って最後まで表示しないため)。1 行のみ: `nvimx-lock: resolving version constraints for N plugin(s)`。N が数十になりうるので per-plugin の進捗行は出さない。

### 3.3 タグの正規化と選択

1. `range = Semver.range(constraint)`。nil ならエラー(§3.4 の分類 D)。**この判定だけは ls-remote の前に、全制約について一括で済ませる**(§5.3-2。ネットワークの成否で D と C が入れ替わらないようにするため)。
2. `parse_ls_remote(stdout)` で `refs/tags/` を剥がしたタグ名配列を得る。`^{}` 終端はスキップ。
3. **タグ名を `table.sort` で昇順に並べる。** git の出力順に依存しないことで、同値タグ(`1.2.3` と `v1.2.3`、build metadata 違い)のタイブレークが git のバージョンに関わらず固定される。
4. 各タグを `Semver.version` でパース。nil(`stable` / `nightly` 等)は黙ってスキップ。`range:matches(v)` で絞り、`Semver.last` で最大を選ぶ。
5. `resolvedRef = "refs/tags/" .. <元のタグ名>`。**正規化した番号ではなく原文のタグ名**を書く(ref として fetch するのはリモートの実名だから)。`Semver.version` が `input` に原文を保持しているのでこれを使う。

### 3.4 制約の出自による重大度の分岐(**本改訂の中心**)

#### 3.4.1 問題

旧計画は「マッチなし = 常に fatal」だった。#42 以降、`defaults = { version = "*" }` の 1 行は**タグを持たない全プラグイン**に `version = "*"` を付ける。この方針のままだと、タグを打っていないプラグインが 1 つあるだけで config 全体が lock 不能になり、**lazy では動く config が nvimx では lock できない** = 現状(黙って HEAD)より悪い退行になる(`docs/plans/42-extract-defaults-version.md` §4.2)。

#### 3.4.2 採用: 出自(provenance)で severity を分ける

失敗を 4 分類し、出自で重大度を変えるのは A / B の 2 つだけにする:

| 分類 | 明示的な `version`(ユーザーがそのプラグインに書いた) | `defaults.version` 由来 |
|---|---|---|
| A. 制約にマッチするタグが無い | **fatal** | warning(集約)+ HEAD fallback |
| B. リモートにタグが 1 つも無い | **fatal** | warning(集約)+ HEAD fallback |
| C. `git ls-remote` が失敗した | **fatal** | **fatal** |
| D. 制約が `Semver.range` でパースできない | **fatal** | **fatal** |

- A / B の非対称の根拠: 明示的な `version = "^1.2"` は「このプラグインはこの範囲のタグを持つ」という**ユーザーの主張**なので、外れたらタイプミスか誤解であり、その場で直せるようにするのが親切。`defaults.version` は「semver を持つプラグインについては最新安定版を*試す*」という**設定全体への期待**で、外れることが lazy の通常動作である(`git.lua:142-153`、§1.2)。
- C を出自を問わず fatal にする理由: 環境の問題(ネットワーク断、認証、URL の打ち間違い)であり、lazy の fallback とは性質が違う。ここで HEAD に落とすと「ネットワークが不調な日の lock が静かに全プラグインを HEAD に倒す」ことになり、lock の意味が失われる。
- D も fatal: 文法エラー。lazy でも `get_versions` が nil を index してエラーになる(§1.2)。`defaults.version` に書いた場合は 1 箇所の誤りが全プラグインに波及するので、なおさら止めるべき。
- fallback したプラグインの `resolvedRef` は **null のまま**にする。`plugins.json` に「fallback した」という状態を残さない(§3.4.4)。

#### 3.4.3 出自情報の持ち方: raw-spec にのみ、`versionFromDefaults`

- `lua/nvimx/extract.lua` の `dump_plugin` に **`versionFromDefaults = (version ~= nil and p.version == nil) or nil`** を 1 行足す。`or nil` なので false のときキーが生えず、`defaults.version` を使わない config の raw-spec は 1 バイトも変わらない(= `extractor-snapshot` の golden は無変更)。
- **`plugins.json` のスキーマには足さない。** 理由は #42 §3.6 のとおり:
  - 消費者が居ない provenance フィールドは、commit されレビューされるファイルの純ノイズ(#43 が `optional` を消したのと同じ理由)。
  - `version` と `defaults.version` から一意に決まる従属値なので、`identity_fields`(`resolve.lua:181`)に入れてはならない。「入れてはいけないフィールド」を増やすのは負債。
  - スキーマ追加は全ユーザーの `plugins.json` に churn を生む。
- raw-spec は lock ごとに作り直される中間ファイルなので lock state にならず、`lock-app.nix` の 2 パス(`:95-97` / `:121-123`)は**同じ raw-spec を読む**ため両パスの判定が一致する。
- 手書き raw-spec(`tests/fixtures/merge/*.json`、§6 の semver fixture)ではこのキーを明示的に書ける。これが check で両 severity を回せる根拠。

#### 3.4.4 却下した代替案

- **案 1: 全制約で fatal(旧計画のまま)** — 不可。§3.4.1。
- **案 2: 全制約で warning + HEAD(lazy 完全互換)** — 最も単純で「lazy の意味論に一致させる」原則には忠実だが、`version = "^99"` のタイプミスも warning だけになり、issue の「HEAD に黙って落ちない」要求を「黙ってはいない」水準まで弱める。明示指定は数が少なく、間違いを即座に指摘できる価値が高いので採らない。
- **案 3: 出自ではなくリモートのタグ集合の形で判定する**(「semver としてパースできるタグが 0 件 = そのプラグインは semver 非対応 → warning + HEAD」「semver タグはあるが範囲外 → fatal」)。provenance を一切増やさずに済む魅力があり、`defaults.version = "*"` については実際に正しく動く(`*` は semver タグが 1 つでもあれば必ずマッチする)。**却下理由**: (a) `defaults = { version = "^1" }` のように実範囲を書いた config では「semver タグはあるが範囲外」が普通に起きるため、`defaults` 経路が壊れる問題が残る。(b) severity が**リモートの現在の状態**で決まるので、同じ設定が日によって fatal / warning に変わる(上流がタグを消したら私のタイプミスが warning に格下げされる)。出自は「ユーザーが何を書いたか」で不変なので、エラーの再現性がある。
- **案 4: `programs.nvimx.lock.strictVersions` のようなオプションで切り替える** — 却下。lazy の意味論に従うべきところに設定面を増やす。必要になってから足せる。

#### 3.4.5 fallback の報告方法

- `resolve.lua` の `note()`(`:226-228`、**stderr のみ・`plugins.json` に記録しない**)で、名前ソート済みの 1 行に集約する:

  ```
  [nvimx] no tag matches the config-wide version constraint "*" for 12 plugins, so they follow
          their default branch instead (lazy.nvim does the same): a.nvim, b.nvim, ...
  ```

  - `warn()`(`:220-224`)を使わない理由: `warn` は `plugins.json` の `warnings` にも記録される。`defaults.version` 使用者では対象が数十件になり、commit される lock が「lazy でも普通に起きること」の列挙で埋まる。#42 §7 が「1 行に集約する等の対処は #23 で」と申し送っていた項目の回収でもある。
  - 制約文字列は `defaults.version` 由来なので config 全体で 1 つに定まる(`Config.options.defaults.version` は単一値)。念のため制約文字列ごとにグループ化して 1 行ずつ出す実装にしておく。
  - **この報告が「解決の副産物」であることが lock-app の 2 パス整合の条件になる。** fallback は `resolvedRef` に残らないので 2 パス目も同じ判定 → 同じ行が出る。`lock-app.nix:116-119` のコメント(「2 回の run は同じ問題を報告する」)が保たれる。
- fatal は `resolve_errors` に全件収集し、**名前 → メッセージでソートして全件 stderr に出してから exit 1** する(`plugin_warnings` と同じ流儀、`resolve.lua:356-367`)。`pairs()` 走査順に依存した「最初の 1 件で即死」はメッセージが非決定的になる。ユーザーは 1 回の lock で全問題を見られる。
- 出力形式は `fail`(`resolve.lua:13-16`)に揃え `[nvimx] resolve failed: plugin "<name>": …`。分類ごとの本文:
  - A: `no tag matches version constraint "^9" (<url>). 12 tags parsed; newest: 0.1.8, 0.1.7, 0.1.6, … . If this plugin does not use semver tags, drop `version` or set `version = false`.`(候補は semver 降順で最大 10 件)
  - B: `version constraint "^1.2" cannot be satisfied: the remote has no tags (<url>).`
  - C: `git ls-remote failed for <url> (exit 128): <stderr の先頭数行>`
  - D: `version constraint "<1.0" is not valid lazy.nvim semver syntax (supported: *, 1.2.3, =1.2.3, >1.2.3, >=1.2.3, ^1.2, ~1.2, 1.x, "1.2 - 2.0"). "<" is not supported.`
  - `error()` による Lua traceback は使わない(ユーザー向けメッセージとして汚い)。
- 非ゼロ終了時は出力ファイルを書かない(現行は最後に一括 write する構造(`resolve.lua:392-394`)なのでそのまま満たされる。#18 §3.4 もこの順序の維持を要求している)。lock-app 側は既存の fatal パス(`lock-app.nix:98-102`)で足りる。

#### 3.4.6 副産物: pin+version warning の文言

`resolve.lua:338-346` の `pinned; version constraint %q is not validated (pin wins)` は、#42 以降ユーザーが書いていない `defaults` 由来の制約についても出る(#42 §3.6 が「受容する」とした wart)。出自が分かるようになるので、**`defaults` 由来のときだけ `pinned; the config-wide version constraint %q is not validated (pin wins)` と言い換える**。3 行の追加で誤解が消える。明示指定時の文言は既存のまま(`resolve-merge` の grep も手書き raw-spec = 出自なしなので不変)。

### 3.5 解決ゲートの位置と pin との相互作用

```lua
-- 解決対象(マージと pin 凍結の後、warning ブロックの前)
-- 条件の主語は entry.version ではなく raw の p.version。理由は下記(vim.NIL は truthy)。
if p.version and is_null(entry.resolvedRef)
   and is_null(entry.commit) and is_null(entry.tag) then
  -- pending に積む → 後段のバッチで ls-remote → select
  --   → entry.resolvedRef = "refs/tags/<tag>" / fallback / error
end
```

- **`entry.version` で判定してはならない(実測で確認済み)。** `entry.version = p.version or vim.NIL`(`resolve.lua` の `entry` 構築、現時点 `:403`)であり、**`vim.NIL` は userdata なので Lua では truthy**。したがって version が未設定でも `version = false` でも `entry.version` は `vim.NIL` = truthy になり、`entry.version` をゲートに使うと **`resolvedRef` / `commit` / `tag` が null な全プラグインでゲートが発火**する。version を持たないプラグインまで ls-remote に送られ、制約が nil のまま `Semver.range(nil)` に落ちてエラーになる。
  - 実測: `type(vim.NIL)` → `userdata`、`vim.NIL and "T" or "f"` → `T`。`p.version = false` に対しても `p.version or vim.NIL` は `vim.NIL` = truthy。
  - 一方 raw の `p.version` なら、未設定(nil)も `version = false` も素直に falsy になり、どちらも正しくゲートから外れる。**現行コード(`resolve.lua` の warning ブロック冒頭、現時点 `:442` の `if p.version then`)と同じ判定であり、既存の意味論をそのまま引き継ぐ**のが安全側。
  - `entry` 側で判定したい場合は `not is_null(entry.version) and entry.version ~= false` と書く必要があるが、二重否定を持ち込む理由がないので採らない。ゲート内で使う制約文字列も `p.version` を渡す(`pending` の `constraint = p.version`)。
- `commit` / `tag` 併記時は解決しない(lazy の `get_target` の優先順に合わせて**黙って** version を無視。genflake の URL 優先順とも整合)。#42 §3.2 の実効規則により extract 経路では `commit`/`tag` 持ちに `version` は入らないが、手書き raw-spec では両方書けるのでこの防御は残す。この 2 条件は決定済みの `entry` を見るので `is_null(entry.…)` のままでよい(マージ後の値を見たいため)。
- `version = false`(lazy の「このプラグインだけ `defaults.version` を無効化する」書き方)は `p.version` が falsy なのでゲートを通らず、挙動変化なし。`entry.version` には従来どおり `vim.NIL` が入り `plugins.json` では `null` になる(#42 の `defaults-version-false-config` の契約どおり)。
- **pin 凍結ブロック(`:324-331`)より後**に置く。帰結:
  - pin=true ∧ spec 不変 ∧ flake.lock に rev あり(= #23 より前に lock 済み)→ 凍結が勝ち、`resolvedRef` は 40-hex。ゲートは発火せず、`is_tag_ref` が false なので既存の "pin wins" warning が出る。**これが #18 が定めた pin の意味論(`docs/architecture.md:235`、現 `:238`)であり維持する。**
  - pin=true ∧ 初回 lock(prev 無し / rev 無し)→ 凍結できないのでゲートが発火し、semver が解決する。以後 `refs/tags/…` が契約 1 で carry され、pin 凍結ブロックは `is_null(entry.resolvedRef)` の条件で skip される。結果として **URL がタグを指し、flake.lock がその commit を持つ**状態で安定する。制約が検証されているので "pin wins" warning は出ない(`is_tag_ref` が true)。これは HEAD の rev に凍結するより明らかに良い挙動なので、そのまま採る。
    - **ただしこれは pin の文書化された契約を弱める。** 現在の pin は「URL 自体が rev を名指すので `nix flake update` でも動かない」(`resolve.lua` の unpin コメント、現時点 `:429-431`。`docs/architecture.md` の pin 行、現時点 `:238`)と説明されているが、タグ ref に安定した input は **上流がタグを打ち替えれば `nix flake update` で動きうる**(タグ→commit の解決は fetcher が毎回やる)。40-hex の凍結と同一の保証ではない。
    - この差分は**文書化して受容する**(§5.6 に作業項目)。「次のパスで pin がタグ ref を 40-hex に焼き直す」設計も可能だが、(a) `is_tag_ref` の carry を pin だけ特別扱いする分岐が増える、(b) 焼き直した瞬間 `refs/tags/…` という決定の出自が lock から消えて `--update` の判断材料が失われる、ので本件では採らず §7 の未決事項に残す。
- **warning ブロック(`:333-350`)は解決の後に移す。** 現在ループ内で `pin` と `resolvedRef` から文言を決めているが、解決を待たずに判定すると「これから semver が解決するプラグイン」に "pin wins" を出してしまう。解決はバッチ化する(§3.2)ためループ内では完了しないので、warning の計算はループ後の**名前ソート順の 2 週目**に移す。副作用として warning の生成順が決定的になり、`plugin_warnings` のソート(`:356-367`)への依存が減る。

### 3.6 コード配置

ls-remote 出力のパースとタグ選択は純粋関数であり単体テストの対象にしたいので、resolve.lua に埋め込まず **`lua/nvimx/version.lua`(新規)** に切り出す。`json.lua` と同じく `dofile(arg[0]:gsub("resolve%.lua$", "version.lua"))` でロード(`resolve.lua:59` と同型)。提供物:

- `parse_ls_remote(stdout) -> string[]` — `SHA\trefs/tags/NAME` 行 → タグ名配列。`^{}` 終端はスキップ、`table.sort` 済み(§3.3)。
- `select_tag(Semver, tags, constraint) -> tag|nil, detail` — §3.3 の 1/4/5。失敗時 `detail = { kind = "no-range" | "no-tags" | "no-match", parsed = <数>, newest = { … } }` を返し、§3.4.5 のメッセージ材料にする。`Semver` は引数で受け、`dofile` はしない(テストから注入できる形)。

`vim.system` の起動・バッチ・結果集約は impure なので resolve.lua 側に置く(integration check で担保。§6.5)。`remote_url` は §3.2 の決定により不要。

**#31 適用後なので、新規 lua も stylua で整形済み・luacheck clean(`vim` は `.luacheckrc` の `globals` にある)であること。**

### 3.7 lazy.nvim 自身の `version` 扱い

`resolve.lua` の解決ループ自体には影響なし。`lazyNvim` エントリは synthetic(`resolve.lua:380-386`)で `version` を持たず、解決ループは `raw.plugins` しか走査しない。genflake も `input_url({ source = db.lazyNvim.source })`(`genflake.lua:72`)で source のみ渡すため HEAD 追従のまま。seed の pin は `lock-app.nix:44-45` の既存 TODO でスコープ外。

**ただし「ユーザーが spec に `folke/lazy.nvim` を書いた場合は通常プラグインとして普通に解決される」は誤りなので、そう書かないこと。** `to_input_name("lazy.nvim")` は `lazy-nvim` を返し、これは synthetic エントリの `inputName`(`resolve.lua:481-487`)と**完全に衝突する**。`genflake.lua` が `inputs.lazy-nvim` を 2 回書くため生成 flake が評価エラーになり、`nix flake lock` が失敗して lock 全体が落ちる。`seen_inputs` の衝突検出は synthetic エントリを見ない(synthetic は実プラグインのループの後に足される)ので捕まえられない。

- これは **#23 とは無関係に既に壊れている**経路であり、**issue #49 として起票済み**(`fix(resolve): a spec that lists lazy.nvim collides with the synthetic lazy-nvim input`。issue 本文が本節を名指しで訂正している)。修正は #49 のスコープ。
- したがって #23 では **`version` 付き `folke/lazy.nvim` の fixture / check を追加しない**(追加しても #49 が入るまで赤になる)。#49 が先に入って input が共有される形になった場合は、その共有 input に対して semver ゲートが発火するかを §3.5 の観点で読み直すこと(現設計では synthetic 側に `version` が無いので、統合の仕方によっては制約が黙って捨てられる)。この申し送りを #49 側にも書く。

## 4. #18 / #42 / #24 との関係

### 4.1 #18(マージ済み)から前提とするもの

- スキーマ最終形と `resolvedRef` の 3 値意味論(`docs/architecture.md:205-211`)。#23 が書くのは第 3 の値 `refs/tags/<tag>` のみ。**スキーマ変更なし、`schemaVersion` は 1 のまま。**
- マージ契約 1: spec 恒等性(`source` + `branch` + `tag` + `commit` + `version`)不変 ⇒ `resolvedRef` 無条件引き継ぎ。これにより解決済みタグは次回 lock でネットワークなしに生き延び、`version` を書き換えたときだけ再解決になる。
- CLI のフラグループ / 2 パス収束 / pin 凍結 / unpin 時の 40-hex のみ破棄。
- **旧計画が「#18 に追加要求」としていた 3 項目は消化済み**: genflake の git type `?ref=` ディスパッチ(実装済み、§1.1)、`--lazy` を足せるフラグループ(実装済み)、ゲートの `commit`/`tag` 条件(#23 側で足す。§3.5)。**#23 で `genflake.lua` の変更は不要**。

### 4.2 #42 から前提とするもの / 追加で要求するもの

- 前提: `effective_version` の実効規則(`extract.lua:61-69`。`commit` / `tag` / `version` / `branch` がすべて未設定のときだけ `defaults.version` を適用)。これで #23 の解決対象集合が決まる。
- 前提: `defaults.version` の編集は対象プラグインの `version` の編集として恒等性に効く(`docs/architecture.md:233`)ので、横断的な無効化ロジックは不要。
- **追加要求**: `dump_plugin` に `versionFromDefaults` を 1 行(§3.4.3)。#42 §5.1-3 が任意項目として設計済みで、#42 の PR には入っていない(`extract.lua` を実読して確認)。
- **追加要求**: `checks.extractor-defaults-version` の作り直し(§1.4-4、§6.4)。

### 4.3 #24(`--update`)への引き渡し

- `--update <name>` は「prev が無いものとして扱う」(#18 §4)ので `resolvedRef` が破棄され、本機能のゲートに自然に入る。#23 側で追加の考慮は不要。
- 注意点として #24 に申し送る: (a) `refs/tags/…` が URL に焼かれた input は `nix flake update` では動かないため、タグを進めるには `--update <name>` で `resolvedRef` を捨てて再解決する経路が唯一の手段になる(#24 §3.4 の分類「URL に rev が入ったままの input」と同じ扱いをタグ ref にも適用する)。(b) `defaults.version` で fallback したプラグインは `resolvedRef` が既に null なので `--update` の対象にしても差分は出ないが、再問い合わせは走る(#24 のサマリでは `unchanged` になる)。

### 4.4 #31 / #36 との関係

機能面の依存はない。#31 は新規 lua(`version.lua`、単体テストドライバ)を整形・lint 対象に含める前提を作る。#36 は `resolve.lua` のプラグインループを書き換えるので、本件のループ改造(§3.5 の warning 移動)と**同じ関数内で競合しうる**。着手時に `resolve.lua` を読み直してから手を入れること。

## 5. 実装手順

### 5.1 `lua/nvimx/extract.lua`

- `dump_plugin`: `version = effective_version(p, default_version)` を一度ローカルに取り、`versionFromDefaults = (version ~= nil and p.version == nil) or nil` を返却テーブルに追加。`effective_version` を 2 回呼ばない。
- `effective_version` の直上のコメント(`:45-58`)に 1 行: 出自を raw-spec にだけ残す理由と、`plugins.json` に出さないこと(§3.4.3)。
- ファイル冒頭コメント(`:12-14`)に 1 行: 出自フラグも一緒に記録する旨。

### 5.2 `lua/nvimx/version.lua` — 新規

§3.6 の 2 関数。ヘッダに「lazy の semver モジュールは引数で受ける(この層は pure)」旨。

### 5.3 `lua/nvimx/resolve.lua`

シンボル基準で:

- ヘッダ(`:1-11`): Usage コメントに `--lazy <path>` を追記。`:11` の TODO 行(`TODO: resolve version (semver) via git ls-remote`)を削除。
- **`usage()` 関数の文字列(現時点 `:18-23`)にも `--lazy <lazy.nvim path>` を足す。** ヘッダコメントと別物なので両方直すこと(片方だけだと `resolve.lua` を引数なしで叩いたユーザーに新フラグが見えない)。
- フラグループ(`:27-57`): `--lazy` を値付きフラグとして追加(`--prev` / `--lock` と同じ分岐)。
- `json` の dofile(`:59`)の隣: `local ver = dofile(arg[0]:gsub("resolve%.lua$", "version.lua"))`。
- `warn` / `note`(`:220-228`)の近く: `resolve_errors = {}` を `plugin_warnings` と並べて定義し、`fail_plugin(name, msg)` を追加。
- プラグインループ(`for name, p in pairs(raw.plugins or {})`):
  - `entry` 構築(`:293-304`)は不変(`versionFromDefaults` を `plugins.json` に入れないため)。
  - マージ(`:306-322`)/ pin 凍結(`:324-331`)は不変。
  - `if p.version then …` の warning ブロック(`:333-350`。現時点 `:442` 以降)を**ループから撤去**し、代わりに §3.5 のゲート条件を満たすものを `pending[#pending+1] = { name = name, entry = entry, url = p.url, constraint = p.version, from_defaults = p.versionFromDefaults }` として積む。**ゲートの主語は `entry.version` ではなく raw の `p.version`**(§3.5。`entry.version` は `vim.NIL` が truthy なため常に真になる)。`p.version` を持つ全件は `versioned` にも積む(warning 計算のため)。
- ループの直後:
  1. `pending` が空でなければ `--lazy` を検証して `Semver` を dofile(§3.1)。空なら何もしない。
  2. **分類 D(文法エラー)を先に全件確定させる。** `pending` を走査して各 `constraint` を `Semver.range` に通し、**nil を返したものは分類 D として `resolve_errors` に積み、`pending` から取り除く**(残った分だけがバッチ対象)。返った range オブジェクトは `pending` の要素に持たせて後段で再利用する(`select_tag` 内で 2 度パースしない。`version.lua` 側は range を受け取る形か、`kind = "no-range"` を返す既存形のどちらでもよいが、**呼び出し順として D の判定が ls-remote より前に来ることが要件**)。
     - **これは順序の要件であって最適化ではない。** D の判定を `select_tag` の中だけに置くと、ls-remote の後にしか走らない。url が到達不能な `raw-spec-badrange.json`(§6.2)では分類 C(ls-remote 失敗)が先に確定してしまい、§6.3-9 が期待する D の文言(`not valid lazy.nvim semver syntax`)が出ない。さらに一般には**ネットワークの状態次第で同じ設定が D にも C にもなる**ことになり、§3.4.4 で案 3 を却下した理由(「エラーの再現性がある」ことを severity 設計の根拠に置いた)と正面から矛盾する。
     - 副次的な利点として、文法が壊れている制約に対する無駄なリモートアクセスが消える。
  3. `pending` を name 昇順にソート。stdout に 1 行の進捗(§3.2。件数は D を除いた実際のバッチ対象数)。
  4. 8 本ずつ `vim.system` を起動 → `:wait()` → `parse_ls_remote` → `select_tag`。成功: `entry.resolvedRef = "refs/tags/" .. tag`。失敗: §3.4.2 の表に従って `resolve_errors`(A / B / C)か `fallbacks` へ。**D はこの段階では起きない**(2 で除去済み)。
  5. `fallbacks` を制約文字列でグループ化し、名前ソートして `note()` を 1 行ずつ(§3.4.5)。
  6. `versioned` を name 昇順に走査して pin+version の warning を `warn_plugin`(文言は §3.4.6)。
- `plugin_warnings` の emit(`:356-367`)の後: `resolve_errors` が 1 件でもあれば全件 stderr に出して `os.exit(1)`(出力ファイルは書かない)。

### 5.4 `nix/lib/lock-app.nix`

- `runtimeInputs`(`:10-15`)に `pkgs.git` を追加。**必要**である: `ls-remote` は `nix flake lock` の内蔵 fetcher ではなく**外部の git コマンドそのもの**なので、git が PATH に存在することを nvimx-lock 自身が保証しなければならない。
  - **根拠の書き方に注意**: 「`writeShellApplication` の PATH は hermetic だから」は**誤り**。`writeShellApplication` は `runtimeInputs` を PATH に**前置**するだけで、ユーザー環境の PATH はその後ろに残る。証拠として、現行の lock-app は `runtimeInputs` に nix を含まないまま `nix flake lock` を呼べている(`nix/lib/lock-app.nix`)。つまり `pkgs.git` の追加は「無いと必ず動かない」からではなく、**ユーザー環境に git があるかどうかに依存させないため**(バージョンも `--refs` を持つものに固定できる。§3.2)。追加自体は正当なので、直すのは理由の文言だけでよい。
- resolve 呼び出し 2 箇所(`:95-97` / `:121-123`)に `--lazy "$seed"` を追加。
- `:89-92` のコメントから「an unresolved version constraint」を削除し、「解決できない明示的な version 制約は fatal、`defaults.version` 由来の fallback は stderr の集約報告」に更新。
- `:116-119` のコメント(2 パスは同じ問題を報告する)に 1 文: fallback は `resolvedRef` に残らないため 2 パス目も同じ報告になる(§3.4.5)。

### 5.5 テスト一式(§6 で詳述)

- `tests/semver-select-test.lua`(新規、単体テストドライバ)。
- `tests/fixtures/semver/`(新規)。内訳は §6.2 に列挙: `raw-spec-explicit.json` / `raw-spec-explicit-untagged.json` / `raw-spec-defaults.json` / `raw-spec-gate.json` / `raw-spec-badrange.json` / `raw-spec-pinned-frozen.json` / `prev-pinned-unresolved.json` / `flake.lock`。URL は check が jq で差し替えるプレースホルダか、到達不能な固定パスのどちらか(§6.2 の鉄則)。
- `flake.nix`: `checks.semver-select` と `checks.resolve-semver` を新設、`extractor-defaults-version` の resolve 半分を作り直し、`resolve-merge` を修正、`let` に共有シェルヘルパ。
- `tests/fixtures/merge/raw-spec-{base,added,branch-changed}.json` と `golden/base.plugins.json` の修正(golden は `version` と `warnings` の 2 箇所。§6.5-1)。

### 5.6 ドキュメント

行番号は §「行番号の扱い」のとおり執筆時基準なのでずれている。括弧内に現時点の実測値を併記するが、**必ず見出し / 太字を grep して現物に当てること**。

- `docs/architecture.md:227`(現 `:241`)の `**semver resolution**` 段落を実装に合わせて書き換え: `--refs` を使い peeled は読まない(「preferring peeled `^{}`」という現記述は誤り)、`resolvedRef` はタグ ref で commit 固定は `nix flake lock` の仕事、明示制約の不成立は lock を止め `defaults.version` 由来は lazy と同じく HEAD に落ちる。
- `docs/architecture.md:217-225`(現 `:229-239`、見出し `### lazy spec → flake input URL mapping`)の URL マッピング表の `version` 行に、fallback 時は `null`(= HEAD 追従)になる旨を追記。
- **同じ表の `pin = true` 行(現 `:238`)に、pin+version の帰結を追記する**(§3.5)。現在は「the URL itself names the rev」= `nix flake update` でも動かない、と書かれているが、**version を併記した pin が初回 lock で解決された場合は URL がタグ ref になり、上流がタグを打ち替えれば追従しうる**。40-hex 凍結と同じ保証ではないことを 1 文で明記する。
- **`resolve.lua` の unpin コメント(現 `:429-431`。「the URL names the rev, so `nix flake update` cannot move it either」)にも同じ但し書きを 1 行足す。** コード側のコメントが `docs/architecture.md` と同じ主張をしているので、片方だけ直すと次に読む人が矛盾を踏む。
- `docs/architecture.md:229-239`(現 `:243` 以降、見出し `### Update semantics`)に 1 文: タグの付け替えは spec 不変なら追従しない(`--update <name>` が手段)。
- `docs/architecture.md:141-147` の `[3]` に `--lazy` と 4 分類の重大度を 1-2 行。
- `docs/architecture.md:431`(現 `:462`、fixtures 一覧)と `:440`(現 `:471`、checks 一覧)に追加分を反映。
- README: `programs.nvimx` のオプション面は変わらないので変更不要(確認のみ)。lock に git が必要になる旨は `nvimx-lock` が自前で持つので利用者への追加要求はない。

## 6. テスト

### 6.1 単体: `checks.semver-select`(新設)

`tests/semver-select-test.lua` を `nvim -l` で走らせるだけの `pkgs.runCommand`(`nativeBuildInputs = [ pkgs.neovim-unwrapped ]`。git も jq も不要、完全 pure)。`lua/nvimx/version.lua` と seed の `lazy/manage/semver.lua`(`${lazy-nvim}` を argv で渡す)を dofile し、固定入力で assert する。失敗時は非ゼロ終了するだけでよい(runCommand が落ちる)。

- `select_tag` 成功系: タグ集合 `{ stable, v1.0.0, v1.2.0, v1.2.5, v2.0.0, v2.1.0-beta }` に対し `*` → `v2.0.0` / `^1.2` → `v1.2.5` / `~1.2` → `v1.2.5` / `>=1.2.0` → `v2.0.0` / `=1.2.0` → `v1.2.0` / `1.2.0` → `v1.2.0`(いずれも実測値)。`v` 接頭辞なしタグの混在、`stable` / `nightly` が無視されること、prerelease が非 prerelease 制約に選ばれないこと、`2.1.0-beta` のように制約側が prerelease を持つときだけ選ばれること。
- `select_tag` 失敗系: `no-match`(`^9`)、`no-tags`(空配列)、`no-range`(`<1.0` / `foo`)がそれぞれ nil + 対応する `kind` を返すこと。`no-match` の `newest` が semver 降順で最大 10 件になること。
- タイブレークの安定性: `{ "1.2.3", "v1.2.3" }` を任意の順で与えても同じタグが返る(§3.3-3 の `table.sort` の意味)。
- `parse_ls_remote`: 通常行 / `^{}` 行のスキップ / 空出力 / 末尾改行なし / 出力順が逆でもソート済みで返ること。

### 6.2 fixture: `tests/fixtures/semver/`

ローカルリポジトリのパスは `$TMPDIR` 依存なので raw-spec に直書きできない。**URL をプレースホルダにした手書き raw-spec を commit し、check が jq で差し替える。**

**プレースホルダの鉄則(実装者向け)**: 1 つの raw-spec に**未置換のプレースホルダを 1 つでも残したまま resolve を走らせてはならない**。未置換の `@TAGGED@` はそのまま git のリモート URL として扱われ、分類 C(ls-remote 失敗)で fatal になる。したがって「成功を期待する手順で使う fixture」には**失敗させたいプラグインを同居させない**。旧版はこの点で `raw-spec-explicit.json` に成功系(`tagged.nvim`)と分類 B 用(`untagged.nvim`)を同居させており、置換してもしなくても成功系の手順が落ちる構成になっていた。**fixture をケース別に分ける**ことでこれを解消する:

- `raw-spec-explicit.json` — **成功系専用**。プレースホルダは `@TAGGED@` の 1 種類だけ。
  - `tagged.nvim`: `version = "^1.2"`、url プレースホルダ `@TAGGED@`
  - `pinned.nvim`: `version = "^1.2"` + `pin = true`、url `@TAGGED@`
  - github type 1 件(例 `gh.nvim`、url は `https://github.com/o/gh.nvim.git` のまま差し替えない): **`version` を持たせない。** `parse_source` が github type を出すことと、type が何であれ version 無しなら ls-remote が飛ばないことの検証専用。ここに `version` を書くとサンドボックスから GitHub に出ようとして分類 C で落ちる。
- `raw-spec-explicit-untagged.json` — **分類 B 専用**。`untagged.nvim` 1 件、`version = "^1.2"`(明示)、url プレースホルダ `@UNTAGGED@`。旧版で `raw-spec-explicit.json` に同居していたものをこちらに分離する。
- `raw-spec-defaults.json` — `tagged.nvim`(`@TAGGED@`)と `untagged.nvim`(`@UNTAGGED@`)の 2 件、全件 `version = "*"` + `versionFromDefaults: true`。fallback 経路用。**この fixture では 2 種のプレースホルダを両方置換する**(どちらも exit 0 が期待値なので同居してよい)。
- `raw-spec-gate.json` — `tag` 併記 / `commit` 併記 / `version = false` の 3 件。**url を存在しない固定パス(`file:///nvimx-nonexistent/gate`)にしておく**ことで「ls-remote が呼ばれない」ことを証明できる(呼ばれたら分類 C で fatal になる)。プレースホルダは持たない。
- `raw-spec-badrange.json` — `version = "<1.0"` の 1 件(分類 D)。url も存在しない固定パス(`file:///nvimx-nonexistent/badrange`)。プレースホルダは持たない。**分類 D が ls-remote より前に確定する**(§5.3-2)ので、到達不能な url でも D の文言で落ちるのが期待値。
- `raw-spec-pinned-frozen.json` — **手順 13(b) 専用**(旧版に欠けていた fixture)。`pinned.nvim` 1 件、`version = "^1.2"` + `pin = true`、url は**存在しない固定パス** `file:///nvimx-nonexistent/pinned`。プレースホルダは持たない。url が到達不能なので、pin 凍結が勝って ls-remote が呼ばれないことをこの fixture 自身が証明する(呼ばれたら分類 C で fatal)。
- `prev-pinned-unresolved.json` — 手順 13(b) の `--prev`(**旧版に欠けていた fixture**)。`schemaVersion: 1` の plugins.json で、`pinned.nvim` が `pin: true` / `version: "^1.2"` / `resolvedRef: null`(= #23 以前の nvimx が書いた lock の再現)。`source` は `raw-spec-pinned-frozen.json` の url から `parse_source` が導く値と**厳密に一致**させること(一致しないと spec 恒等性が崩れて `unchanged` が false になり、pin 凍結ブロックが skip されてテストの意味が消える)。
- `flake.lock` — 手順 13(b) の `--lock`(**旧版に欠けていた fixture**)。`tests/fixtures/merge/flake.lock` と同型の手書きスタブで、`nodes.pinned-nvim.locked.rev` に 40-hex のプレースホルダ rev(例 `cccc…`)を持ち、`root.inputs.pinned-nvim` から辿れること。`_comment` に「rev は fetch されない、resolve.lua が読む形だけが意味を持つ」旨を書く(merge の fixture と同じ流儀)。

### 6.3 統合: `checks.resolve-semver`(新設)

`resolve-merge` と同型の `pkgs.runCommand`。`nativeBuildInputs = [ pkgs.neovim-unwrapped pkgs.jq pkgs.git ]`(`diff` / `cmp` は stdenv 由来で足りる。`extractor-snapshot` / `resolve-merge` が既にそうしている)。**ネットワーク不使用** — サンドボックス内 `git init` したリポジトリをリモートとして使う。

`flake.nix` の checks の `let`(`mkHmCheck` と同じ場所)に共有シェル片を 1 つ置き、この check と `extractor-defaults-version` の両方から使う:

```
mkTagRepoSh = ''
  # mkrepo <dir> [tag...] -- a git repo usable as a remote with no network at all.
  # `git+file://` (not a bare path) is what nix's flake ref parser accepts, so callers
  # must build URLs with the file:// prefix.
  mkrepo() { local d="$1"; shift; mkdir -p "$d"; git init -q -b main "$d"
    git -C "$d" -c user.name=nvimx -c user.email=nvimx@example.com commit -q --allow-empty -m init
    for t in "$@"; do git -C "$d" -c user.name=nvimx -c user.email=nvimx@example.com tag -a "$t" -m "$t"; done; }
'';
```

annotated tag を使う(`tag -a`)ことで `--refs` 経路と nix の peel を同時に押さえる(§1.3)。`export HOME=$TMPDIR` は git のために必須。

**手順の順序に関する制約(重要)**: リポジトリを削除する破壊的な手順は**最後に置く**こと。旧版は手順 4 で `rm -rf $sb/tagged` していたが、その後の手順 5(制約変更による再解決)/ 10(defaults fallback)/ 11(2 パス整合)がいずれも同じ `$sb/tagged` に ls-remote を飛ばすため、書かれた順に実装すると分類 C の fatal で全部落ちる。以下では**破壊的な手順を末尾(手順 15)に移した**。`$sb/tagged` を `mkrepo` で作り直してから続行する形でも構わない —— `resolvedRef` に入るのは**タグ名**であって SHA ではないので、作り直しで commit SHA が変わっても出力の byte-identical 性は保たれる(その場合は「作り直す」ことをコメントに明記すること)。

各手順の先頭に、その手順で**どのプレースホルダをどう置換するか**を明記した(§6.2 の鉄則)。

1. `mkrepo $sb/tagged v1.0.0 v1.2.0 v1.2.5 v2.0.0 v2.1.0-beta stable` / `mkrepo $sb/untagged`(タグなし)/ `mkrepo $sb/telescope 0.1.5 0.1.8`(手順 14 用)。
2. **明示制約の成功** — 置換: `raw-spec-explicit.json` の `@TAGGED@` → `file://$sb/tagged`(この fixture のプレースホルダはこれだけ、残らない)。`nvim -l $lua/resolve.lua … **--lazy ${lazy-nvim}**` → `tagged.nvim` の `resolvedRef == "refs/tags/v1.2.5"` を assert。`warnings == []`、stderr に version 由来の行が無いこと(ゴール 6)。github type の `gh.nvim` は `version` を持たないので `resolvedRef == null` かつ ls-remote が飛ばないことも同時に確認できる。
3. **URL が実際に効くこと**: 2 の出力を genflake に通し、生成 flake.nix に `?ref=refs/tags/v1.2.5` が含まれることを grep。`nix flake lock` はビルド内で実行できない(recursive nix)ので、タグ ref が実 rev に解決されることは §6.7 の手動検証に回す(§1.3 で `nix flake metadata` により実測済み)。
4. **制約の変更が再解決を起こす** — 置換: `raw-spec-explicit.json` を `@TAGGED@` → `file://$sb/tagged` かつ `version` を `~1.0` に書き換えた版。2 の出力を `--prev` にして resolve → `refs/tags/v1.0.0` に変わる(恒等性に `version` が入っていることの実証。従来どこにも無かったカバレッジ)。**この手順は `$sb/tagged` が生きている必要がある。**
5. **`--prev` の carry**: 2 の出力の `resolvedRef` を jq で別のタグ ref に書き換えたものを `--prev` に渡し、spec が不変なら**その値がそのまま carry され**、警告も出ないこと(旧 `resolve-merge:1181-1194` から移設する観点)。ls-remote が走らないことは carry 後の値が `$sb/tagged` の実解決結果(`v1.2.5`)と違うことで示せる。
6. **明示制約の fatal(分類 A)** — 置換: `raw-spec-explicit.json` を `@TAGGED@` → `file://$sb/tagged` かつ `version` を `^9` に書き換えた版。非ゼロ終了、stderr にプラグイン名・制約・URL・候補タグの列挙。出力ファイルが生成されていないことも確認。
7. **明示制約の fatal(分類 B)** — 置換: `raw-spec-explicit-untagged.json` の `@UNTAGGED@` → `file://$sb/untagged`。非ゼロ終了 + `the remote has no tags` を grep。**成功系の fixture と分けてあるので、ここで未置換のプレースホルダは残らない。**
8. **分類 C**: 存在しないパスを url にして非ゼロ終了 + git の stderr が含まれることを grep。
9. **分類 D**: `raw-spec-badrange.json`(url は到達不能な固定パス、プレースホルダなし)で非ゼロ終了 + `not valid lazy.nvim semver syntax` を grep。**url が到達不能なのに C ではなく D の文言で落ちることが、§5.3-2 の「D を ls-remote より前に確定させる」順序の実証そのもの**である。念のため stderr に `git ls-remote failed` が**含まれない**ことも assert する。
10. **`defaults` 由来の fallback(ゴール 3)** — 置換: `raw-spec-defaults.json` の `@TAGGED@` → `file://$sb/tagged`、`@UNTAGGED@` → `file://$sb/untagged`(**2 種とも置換する**)。resolve → **exit 0**、`untagged.nvim` の `resolvedRef == null`、`tagged.nvim` は `refs/tags/v1.2.5`、`warnings == []`(= `plugins.json` を汚さない)、stderr に集約 1 行(`follow their default branch`)。**明示版(手順 7)と同じリモートで severity が変わることを対比で示す**のがこの check の要。
11. **fallback の 2 パス整合**: 10 の出力を `--prev` にして再実行 → `cmp` で byte-identical、かつ stderr の集約行が**同一**(`diff -u`)。`lock-app.nix` の 2 パス設計が保たれることの実証。**`$sb/tagged` / `$sb/untagged` が生きている必要がある。**
12. **ゲート(§3.5)**: `raw-spec-gate.json` を resolve → exit 0、3 件すべて `resolvedRef == null`、stderr に git のエラーが無いこと(= 存在しないパスに ls-remote が飛んでいない)。**`version = false` の 1 件が通ることが、ゲートを `entry.version` ではなく `p.version` で書いたことの回帰テスト**になる(`entry.version` で書くと `vim.NIL` が truthy なのでこの 3 件すべてがバッチに入り、分類 C か `Semver.range(nil)` のエラーで落ちる)。
13. **pin との関係**:
    - (a) 置換: `raw-spec-explicit.json` の `@TAGGED@` → `file://$sb/tagged`。`pinned.nvim` を `--prev` / `--lock` 無しで resolve → semver が解決し `refs/tags/v1.2.5`、"pin wins" warning が**出ない**。実質 2 の出力の別プラグインを見るだけなので手順 2 と統合してよい。
    - (b) **prev 凍結が semver に勝つ**: `raw-spec-pinned-frozen.json` + `--prev tests/fixtures/semver/prev-pinned-unresolved.json` + `--lock tests/fixtures/semver/flake.lock`(§6.2 の 3 fixture。**置換なし**)。spec 恒等性が不変 + `resolvedRef` が null なので pin 凍結が発火し、`resolvedRef` が flake.lock の 40-hex になること、`pinned; version constraint "^1.2" is not validated (pin wins)` が出ることを assert。**url が `file:///nvimx-nonexistent/pinned` なので、ls-remote が呼ばれていたら分類 C で必ず落ちる** —— exit 0 であること自体が「ls-remote は呼ばれない」の証明になる。加えて stderr に `git ls-remote failed` が含まれないことも assert する。
14. **E2E(extract → resolve)** — 置換: 実 extractor の出力に対し jq で telescope の url を `file://$sb/telescope` に差し替える(commit された fixture ではないのでプレースホルダではない)。`tests/fixtures/merge-config` を実 extractor に通し、raw-spec の telescope の `version == "^0.1"` を assert したうえで resolve(`--lazy ${lazy-nvim}` を渡す)→ `refs/tags/0.1.8`。実 spec から実解決まで 1 本で繋がることの証明。
15. **`--lazy` 欠落**: 解決対象があるのに `--lazy` を渡さないと非ゼロ終了 + `--lazy` を含むメッセージ。逆に解決対象が無い raw-spec(`raw-spec-gate.json`)なら `--lazy` 無しで通ること。
16. **prev 生存 + ネットワーク不要(破壊的。必ず最後)**: `rm -rf $sb/tagged $sb/untagged` してから 2 の出力を `--prev` に渡して再実行 → 成功し `cmp` で byte-identical。リポジトリが消えても通る = ls-remote が再実行されていない(#18 契約 1 の実証)。同じことを 10 の出力(defaults fallback)についても行い、**`resolvedRef` が null のまま carry される場合は再問い合わせが走るため、fallback 側は削除後には落ちる**ことに注意 —— したがって **fallback 側をこの手順に含めてはならない**(2 の出力=解決済みタグ ref のみが対象)。§7 の「fallback プラグインは毎 lock 再問い合わせされる」という設計の裏返しである。

### 6.4 `checks.extractor-defaults-version` の作り直し

現状(`flake.nix:894-963`)は前半が raw-spec assert、後半(`:940-955`)が `plugins.json` assert。**後半は §1.4-4 の理由で #23 のハードエラーに当たって落ちる**ので作り直す。方針は「§6.3 と同じ、ローカルリポジトリをリモートに使うオフライン方式」:

- 前半(raw-spec assert)は維持し、**出自フラグの assert を追加**する。ここが provenance の正しい検証場所:
  - `.plugins["tokyonight.nvim"].versionFromDefaults == true` / `.plugins["plenary.nvim"].versionFromDefaults == true`(依存展開されたものにも付く)
  - `.plugins["telescope.nvim"] | has("versionFromDefaults") | not`(自前 `version` は出自なし)
  - `trouble.nvim` / `which-key.nvim` / `flash.nvim` / `noice.nvim` も `has("versionFromDefaults") | not`
- 後半を差し替える。`let` の `mkTagRepoSh` を使って `$sb/tagged`(タグあり)と `$sb/untagged`(タグなし)を作り、extract した raw-spec の url を jq で差し替えてから resolve する。**この check の resolve 呼び出しにも `--lazy ${lazy-nvim}` を必ず渡すこと**(解決対象が存在するので、渡さないと §3.1 の設計どおり `resolve: a version constraint needs --lazy <lazy.nvim path>` で fatal になる。§6.3-15 が回帰テストしている挙動そのもの)。この check の `let` から `lazy-nvim` が参照できることを実装時に確認する(`extractor-defaults-version` は既に extract のために seed を参照しているので同じ束縛が使えるはず):
  - `tokyonight.nvim`(defaults 由来 `*`)→ `untagged` → **exit 0**、`resolvedRef == null`、`warnings == []`、stderr に集約行 → **#42 のゴール 1 が semver 実装後も「lock 可能」であることの回帰テスト**(この check の存在意義そのもの)
  - `plenary.nvim`(defaults 由来 `*`)→ `tagged` → `refs/tags/v2.0.0`
  - `telescope.nvim`(自前 `^0.1`)→ タグ `0.1.5` `0.1.8` のリポジトリ → `refs/tags/0.1.8`
  - `noice.nvim` / `trouble.nvim` / `which-key.nvim` / `flash.nvim` は `version == null` かつ `resolvedRef == null`(url を差し替えなくても ls-remote が飛ばないことの証明を兼ねる)
- 現在の `:949-955` のコメント(「warning の文言は grep しない / このセクションは #23 で作り直す」)は役目を終えるので削除し、代わりに「ローカルリポジトリをリモートに使うのはネットワークが無いから」を書く。`[.plugins[] | select(.version != null)] | length == 3` の assert は維持(制約が届く件数の回帰ガード)。
- `nativeBuildInputs` に `pkgs.git` を追加、`export HOME=$TMPDIR` は既にある。
- `defaults-version-false-config` の部分(`:957-960`)は extract のみなので不変。

代替案として「resolve 半分を丸ごと `resolve-semver` へ移し、この check は extract 専用にする」も検討したが**却下**: #42 のゴール 1 は `plugins.json` に対する要求であり、#42 の名を持つ check がそれを検証しなくなるのは追跡性が悪い。`mkrepo` を `let` で共有すれば重複は数行に収まる(`extract()` シェル関数が既に 2 つの check で重複しているのと同じ流儀)。

### 6.5 `checks.resolve-merge` の修正

§1.4 の 1-3。方針は「**version 制約を含む経路は `resolve-semver` に集約し、`resolve-merge` は pin / dependencies / 削除 / スキーマ互換に専念させる**」。

1. `tests/fixtures/merge/raw-spec-{base,added,branch-changed}.json` の `telescope.nvim.version` を `null` にする。この 3 ファイルの `_comment` に「version 制約を持つ経路は checks.resolve-semver が持つ(ここに置くとネットワークが必要になる)」旨を書く。
   - **`golden/base.plugins.json` の再生成は「1 フィールドのみ」では済まない。** 同ファイルの `.plugins["telescope.nvim"].version` を `null` にするのに加え、**末尾の `warnings` 配列(現時点 `:88-91`)から `"plugin \"telescope.nvim\": version constraint \"^0.1\" is not resolved yet (TODO: semver)"` の要素が消える**。この golden ではその 1 件が `warnings` の唯一の要素なので、結果として `"warnings": []` になる。golden は手で当てず、修正後の resolve.lua で**実際に再生成して差分を目視すること**(差分は `version` 1 箇所 + `warnings` 配列の計 2 箇所)。
   - なお `warnings` が空になること自体はゴール 6(`is not resolved yet` という状態を無くす)の副産物であり、期待どおりである。
2. `:1181-1194` のブロック(解決済み制約は warning を出さない)を書き換える: `grep -q 'version constraint "\^0.1" is not resolved yet' out1.log` は**削除**(ゴール 6 で消える文言)。`resolvedRef = "refs/tags/0.1.8"` を prev に注入して carry されることの assert は、`version` を持たないエントリに対する「タグ ref の carry」テストとして残す(型を問わず `resolvedRef` が引き継がれることの確認になる)。制約付きでの同等ケースは §6.3-5 に移設。
3. `:1148-1167`(現時点 `:1371-1390`)の pin+version ブロックを、**ls-remote が飛ばない形**に組み替える: jq で raw-spec に `version = "^1.0"` を注入するのに加え、**prev 側も `version = "^1.0"` かつ `resolvedRef = null` に加工して pass a / pass b の両方に渡す**(= #23 より前に書かれた lock を再現)。これで spec 不変 + `--lock` に rev があるので pin 凍結が勝ち、ゲートは発火せず、`pinned; version constraint "^1.0" is not validated (pin wins)` が両パスで出る。
   - **この組み替えは既存の「凍結が 2 パスの間に起きた」assert を壊すので、あわせて書き換えること。** 現在の `:1379-1382`(コメント `# the freeze really did happen between the two passes...`)は **out9a の `resolvedRef` が null、out9b が 40-hex** であることを assert している。これは pass a に `--prev` を渡していないから成立していた形であり、pass a にも「`resolvedRef = null` の prev」を与えると **pass a の時点で既に凍結が起きて 40-hex になる**ため `out9a.json … == null` が落ちる。
     - 対処: `jq -e '.plugins["tokyonight.nvim"].resolvedRef == null' out9a.json` を**削除**し、**out9a / out9b の両方が 40-hex であること**を assert する形に変える。コメントも「the freeze really did happen between the two passes」から「the freeze wins over the constraint on **both** passes, and no ls-remote is attempted」に書き換える。
     - 「凍結が実際に起きる」ことのカバレッジ自体は失われない: 同 check の `:1340-1356` 付近の pin ブロック(version 無し)と、`:1358-1369` の unpin ブロックが引き続き押さえている。version と組み合わせた初回凍結の観点は §6.3-13(b) が新 fixture で押さえる。
   - 既存の 2 パス一致 assert(`diff -u out9a.log out9b.log`)と `warnings` 配列の assert(`:1384-1387` のループ)は**そのまま維持できる**(文言が両パスで同一なのは変わらないため)。
4. `:1212-1247` の extractor 通し: `jq -e '.plugins["telescope.nvim"].version == "^0.1"' $sb/raw-spec.json`(extract の契約は raw-spec で assert)に変え、`extracted.json` を作る resolve には `jq 'del(.plugins["telescope.nvim"].version)'` した raw-spec を渡す。理由をコメントに 1 行(github type の制約解決はネットワークが必要で、実体は `resolve-semver` §6.3-14 が E2E で押さえている)。

### 6.6 その他の既存 check への影響

- `resolve-build-warnings`(`:964-1045`): 対象 fixture(`unbuildable-config` / `build-plugins`)に version 指定は無く、`--lazy` は省略可能なフラグなので呼び出し・assert とも**不変**。`quiet.log` が空であることの assert も version 由来の出力が無いので保たれる。
- `extractor-snapshot`(`:833-859`)/ `tests/fixtures/golden/basic-config.raw-spec.json`: `basic-config` は `defaults` を持たず、`versionFromDefaults` は `or nil` で false のときキーが生えないので **golden は無変更**。この「無変更であること」自体をゴールとして PR で明言する。
- `tests/fixtures/{basic-config,build-plugins,registry-plugins,treesitter-config}/nvimx-lock/plugins.json`: 全件 `version: null`(確認済み)なので**再生成不要**。
- `defaults-version-false-config`: extract のみ通す check なので不変。

### 6.7 CI と手動検証

- `.github/workflows/check.yml` は `nix flake check` を丸ごと実行するため、`checks` に 2 つ足すだけで両系統の CI に乗り、**ワークフローの編集は不要**。仮にステップ追加が必要になっても、CLAUDE.md の規約により編集するのは reusable workflow の `check.yml` のみ(`ci-linux.yml` / `ci-darwin.yml` には触れない。badge を per-workflow にするための構造)。
- ローカルの `nix flake check`(linux)は darwin を `omitted these incompatible systems` でスキップするので、CLAUDE.md の規約どおり `nix eval .#checks.aarch64-darwin.semver-select.drvPath` と `… .resolve-semver.drvPath` で darwin 側の評価だけ通す。新 check は `neovim-unwrapped` / `jq` / `git` のみで darwin 固有の落とし穴(`timeout` が PATH に無い等、`extractor-no-setup` の `:866-867` のコメント)には触れない。`pkgs.git` が darwin で引けることも同時に確認できる。
- `nix fmt --check` 相当(#31)で新規 lua が stylua 済み・luacheck clean であることを確認。
- 手動検証(ネットワーク必須、PR 本文に結果を貼る):
  1. `version` 付きの実 spec に `nix run .#lock` → `plugins.json` の `resolvedRef` が実在タグを指し、`flake.lock` の該当 node が `ref = "refs/tags/…"` で SHA に固定される。annotated tag のプラグインで peel されていることも見る。
  2. 再実行が no-op(`git diff` が空)。
  3. `version = "^999"` でエラー終了し、候補タグが列挙される。
  4. `defaults = { version = "*" }` だけを書いた実 config(タグ無しプラグインを含む)で lock が**成功**し、集約行が出る。所要時間を測って §3.2 の並列化が効いていることを確認する。

## 7. リスク / 未決事項

- **明示的な `version = "*"` は fatal になりうる**: `{ "foo", version = "*" }` と自分で書いたプラグインがタグを持たない場合、lazy は HEAD に落ちるが nvimx は分類 B の fatal になる。出自で分ける方針の意図的な帰結(明示指定は主張として扱う)。逃げ道は `version` を消す / `version = false` にする / `defaults.version` に移す。エラーメッセージにこの 3 つを書く。`docs/architecture.md` にも 1 行残す。
- **`defaults` 由来の fallback は lock に痕跡を残さない**: `plugins.json` は `version: "*"` + `resolvedRef: null` になるだけで、「タグが無くて落ちた」ことは stderr にしか出ない。lock だけをレビューする人には「まだ解決されていない」と見える。`warnings` に入れる案は churn の理由で却下したが(§3.4.5)、レビューで揺れうる未決点として残す。
- **fallback プラグインは毎 lock ×2 回 ls-remote される**: `resolvedRef` に null 以外を書かない設計の代償(§3.2)。並列化で緩和するが、根本的にはネガティブキャッシュを持たないという判断。将来問題化したら「fallback を記録する第 4 の `resolvedRef` 値」ではなく、lock-app 側で 2 パス目の semver を抑止する専用フラグを検討する(1 パス目の集約報告が失われない設計が必要)。
- **タグが後から生えるとリロックで ref が動く**: `defaults.version = "*"` で HEAD 追従していたプラグインが上流でタグを打つと、次の lock で `resolvedRef` が生えて URL が変わる。spec を触っていないのに ref が動くので「通常 lock は追加と削除のみ」(`docs/architecture.md:231`)の見え方と緊張する。lazy でも同じことが起きる(`defaults.version` は毎回評価される)ので意味論としては一致しているが、`docs/architecture.md` に 1 行残す。
- **pin と version の交差**: §3.5 のとおり、#23 より前に lock 済みの pin+version プラグインは「制約が検証されないまま現 rev に凍結」のままになる(既存の warning が出る)。動かす手段は spec 編集か #24 の `--update <name>`。`docs/architecture.md:235`(現 `:238`)の記述と整合している。
- **pin+version が初回 lock でタグ ref に安定することは、pin の契約を弱める**(§3.5)。`pin = true` は「URL 自体が rev を名指すので `nix flake update` でも動かない」と文書化されているが、version を併記して初回 lock された場合の URL は `refs/tags/<tag>` であり、**上流がタグを打ち替えれば追従しうる**。本件では §5.6 のとおり `docs/architecture.md` の pin 行と `resolve.lua` の凍結コメントに但し書きを足して受容する。
  - **未決(§7 に残す)**: 「次のパスで pin がタグ ref を 40-hex に焼き直す」設計を採るか。採れば pin の保証は一律になるが、(a) `is_tag_ref` の carry を pin だけ特別扱いする分岐が resolve.lua に増え、(b) 焼き直した瞬間「semver が決めた」という決定の出自が lock から消えて #24 の `--update` が何を再解決すべきか判断できなくなる。**#24 の設計が固まるまで保留**とし、それまでは文書化で対応する。
- **認証が要るリモート**: private リポジトリや ssh URL では `GIT_TERMINAL_PROMPT=0` により即失敗し、分類 C で lock 全体が止まる(ssh は agent が生きていれば通る)。エラーに URL が入るので原因は追えるが、`defaults.version` を使っていて private プラグインが 1 つあると lock 不能になる。credential helper 連携と「分類 C だけを警告に落とすオプション」は未決事項として持ち越し。
- **タグ数の多いリポジトリ**: `ls-remote --tags` は参照列挙のみでクローンしないため軽いが、数千タグのパースは Lua 側で線形。実例が出るまで最適化しない。
- **lazy の semver 文法への追従**: seed の更新で `lazy.manage.semver` の挙動が変わると選択結果が変わりうる。`semver-select` は lazy のモジュール実体を使うため、seed 更新時に挙動差はテストの失敗として顕在化する(`extractor-snapshot` と同じ性質)。壊れた場合はテスト期待値の見直しで追従する。`get_target` の分岐構造(§1.2)が変わった場合は #42 §3.2 の実効規則と本件のゲート(§3.5)の両方を見直す必要がある。
- **`git+file://` は check 専用の形**: 実ユーザーの spec に `file://` URL は普通現れない。`resolve-semver` が検証するのは「git type + `?ref=refs/tags/…`」という URL の**形**までで、`nix flake lock` を通した実解決は §6.7 の手動検証に依存する(recursive nix が使えないため、これは構造上の限界)。#30 の `e2e-offline`(path-type input による network-free E2E)が入れば埋められる。
- **`resolve-merge` の縮小**: §6.5 で version 制約を抜くと、`resolve-merge` は「spec 恒等性に `version` が入っている」ことを直接検証しなくなる。そのカバレッジは §6.3-4 に移すので総量は減らないが、2 つの check の役割分担を PR 本文で明示すること。
- **未決**: `mkrepo` を `let` の共有シェル片にするか各 check に直書きするか。共有を推奨するが、`flake.nix` の既存流儀(`extract()` は 2 箇所に重複)から外れるのでレビューで決める。
