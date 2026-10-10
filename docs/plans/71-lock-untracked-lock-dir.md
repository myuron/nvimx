# #71 対応計画: git リポジトリ内での初回 lock が untracked な `flake.nix` で失敗する

対象 issue: https://github.com/myuron/nvimx/issues/71

ブランチ `fix/lock-untracked-lock-dir`、コミットは `fix(lock): ...`、PR 本文に `Closes #71`。
出発点はユーザー承認済みの方針(§2 の 5 点)であり、
**この 5 点は変更しない**。方針の前提になっていた行番号と主張は main `74aa086` の実コードと実測で裏取りし、
食い違った点は本文で正したうえで §7 R1 に一覧した。

### 行番号の扱い

本文の `file:line` は **main `74aa086`(#67 マージ後)基準**。`flake.nix` は 3873 行、
`nix/lib/lock-app.nix` は 312 行。編集で動くので、**位置指定はシンボルを主キーとして読むこと**。

- `nix/lib/lock-app.nix`: `runtimeInputs` `:9-22`(`pkgs.git` は `:16`)/ `usage()` `:24-27` /
  exit 2 で抜ける最後のガード `:113-120` / `mkdir -p "$out"` `:121` / `flush_logs` `:148-159` /
  `cleanup()` `:160-163` / `trap cleanup EXIT` `:164` / extract `:173-180` /
  resolve 1 回目 `:214-223` / `nix flake lock` 1 回目 `:238-239` / `nix flake update` `:247-253` /
  収束パス `:279-293`(`nix flake lock` 2 回目は `:292`)/ `flush_logs` 呼び出し `:295` / done `:310`
- `flake.nix`: `checks = forAllSystems` `:154` / `resolve-update` `:2389`(ヘッダコメント `:2383-2388`、
  step 10 `:2520-2529`)/ `resolve-import-lazy-lock` `:2766-3135`(step 14 `:3012-3020`、
  step 16 `:3038-3065`、step 17 `:3067-3091`)/ `resolve-sources`(直前のコメントが `:3136`、属性そのものは `:3142`)
- `nix/lib/make-env.nix`: `hasLock` `:31-32` / `nix/lib/sources.nix`: 全 21 行
- `docs/architecture.md`(572 行): シーケンス図 `:90` / データフロー `[5]` `:156-157` /
  Update semantics の `--update` `:287`、Back door `:288` / First run `:466-470` / checks 一覧 `:517` /
  Edge cases 表 `:524-539`(該当行 `:528`)/ How to verify `:555`
- `README.md`(472 行): Usage 1 `:74-75` / Usage 3 `:90-95` / Migrating 4 `:149-157`
- `templates/default/README.md`(32 行): 手順 3 `:9-14`

nix の挙動に関する記述はすべて **nix 2.34.8 / bash 5.3.15 / x86_64-linux** での実測である(§6.2)。

## 1. 背景 / 現状

### 1.1 何が起きているか(実機で再現済み)

`lock-app.nix` は `nix` を 3 箇所で呼ぶ。どれも flake 参照を渡していない:

```bash
# :238-239
echo "nvimx-lock: pinning with nix flake lock" >&2
(cd "$out" && nix flake lock)
# :251
(cd "$out" && nix flake update "''${update_inputs[@]}")
# :292(収束パス。plugins.json が変わったときだけ)
(cd "$out" && nix flake lock)
```

参照なしの `nix flake lock` は cwd から flake を探し、cwd が git work tree 内なら `git+file` flake として
解決する。`git+file` は tracked なファイルしか見ないので、いま生成したばかりの `flake.nix` が見えない。
README どおりの構成(`lockDir = ./nvim/nvimx-lock`)では初回に必ず踏む。

使い捨て git リポジトリ(`nvim/init.lua` だけ `git add` 済み、spec は tokyonight +
`nvim-treesitter` の `build = ":TSUpdate"`)で main の lock app を実行した結果(`$S` はスクラッチパッド):

```console
$ nix run /home/myuron/ghq/github.com/myuron/nvimx#lock -- --config ./nvim --out ./nvim/nvimx-lock
nvimx-lock: extracting spec from $S/e2/dot/nvim
nvimx-lock: resolving plugins
nvimx-lock: generating lock flake
nvimx-lock: pinning with nix flake lock
warning: Git tree '$S/e2/dot' is dirty
error: Path 'nvim/nvimx-lock/flake.nix' in the repository "$S/e2/dot" is not tracked by Git.

       To make it visible to Nix, run:

       git -C "$S/e2/dot" add "nvim/nvimx-lock/flake.nix"
[nvimx] warning: plugin "nvim-treesitter": build is a neovim command (":TSUpdate") and cannot be run at build time. nvimx merges parsers from nixpkgs instead -- set programs.nvimx.treesitter.grammars
[nvimx] these plugins are installed with helptags only, or with some build steps skipped. To give them a real build:
[nvimx]   - programs.nvimx.plugins.overrides."<name>" = { pkgs, src, ... }: <your derivation>;
[nvimx]   - programs.nvimx.plugins.nixpkgsFallback = [ "<name>" ];
[nvimx]   - a recipe under nix/build-registry/, if this plugin is common enough that nvimx
[nvimx]     should ship one
[nvimx] See docs/architecture.md ("Plugin derivations").
$ echo $?; ls nvim/nvimx-lock
1
flake.nix
plugins.json
```

issue の報告と一致する。ここから読み取れることが 2 つある(どちらも方針の前提どおり):

1. **終了コードは握りつぶされていない(rc=1)。** `writeShellApplication` が `errexit` を付けるので、
   `:239` の失敗でスクリプトは即終了する。issue の「処理が続行して import レポートと build warning を出す」
   ように見えるのは、EXIT trap の `cleanup()`(`:160-163`)が呼ぶ `flush_logs`(`:148-159`)の出力である。
   これは #22 の意図的な設計(後段が落ちても resolve の warning を捨てない)で、
   結果として **nix の error が warning の上に埋もれ、最終行が成功時と見分けのつかない warning になる**。
2. `plugins.json` と `flake.nix` は書かれ、`flake.lock` だけが無い。この状態で `home-manager switch` すると
   `make-env.nix:31-32` の `hasLock` が false になり、lazy.nvim だけの縮退ビルドになる:

   ```nix
   hasLock =
     builtins.pathExists (lockDir + "/plugins.json") && builtins.pathExists (lockDir + "/flake.lock");
   ```

`--update` 経路も同じである(lockDir を `git rm --cached` した状態で実測。`:239` で同じ error になり
`:251` には届かない。`nix flake update <input>` を単体で untracked な lockDir に対して叩いても同じ error)。

### 1.2 lock が通っても残る落とし穴

`hasLock` が見るのは `lockDir` という **Nix の path** であり、ユーザーの flake が git flake なら
untracked なファイルはストアにコピーされない。つまり lock が成功しても、`git add nvim/nvimx-lock` を
忘れたまま switch すれば §1.1 の 2 と同じ縮退になる。今日の lock app の最終行は

```bash
# :310
echo "nvimx-lock: done. commit $out/{plugins.json,flake.nix,flake.lock}" >&2
```

で、「commit しろ」とは言うが、しないと何が起きるかは言わない。README(`:90-95`)も
`git add nvim/nvimx-lock` を手順として載せているだけである。

### 1.3 `flake.lock` は flake 自身の参照形式を記録しない

`path:` に変えても成果物が変わらないことの根拠。生成される `flake.lock` の root ノードは `inputs` しか持たず
(§6.2 (a) の実測: `{"inputs":{"lazy-nvim":"lazy-nvim","plenary-nvim":"plenary-nvim"}}`)、
生成 flake の input はすべて `flake = false` の外部 URL(`genflake.lua`)。消費側の
`nix/lib/sources.nix` は `nodes.*.locked` を JSON として読むだけで、lock flake を flake として評価しない:

```nix
lock = builtins.fromJSON (builtins.readFile (lockDir + "/flake.lock"));
rootInputs = lock.nodes.${lock.root}.inputs;
```

### 1.4 既存 check は `nix` を呼ぶ行を 1 行も通っていない

`nix` の呼び出しは「recursive nix になるので check にできない」とされ、lock app 本体は
引数パーサ(`nix` に届く前に exit 2 で抜ける経路)しか check されていない:

```nix
# flake.nix:2385-2388(resolve-update のヘッダ)
# ... `nix flake lock` / `nix flake
# update` themselves cannot run inside a nix build (recursive nix), so the actual CLI
# wiring in lock-app.nix is only exercised here for its argument parser (step 10, which
# never calls `nix`); the rest is covered by the plan's §6.4 manual verification.
```

`resolve-import-lazy-lock` step 17(`:3067-3091`)も同じ理由で、パイプラインの該当部分だけを
`nvim -l resolve.lua` の直叩きで再現している。したがって `:239` / `:251` / `:292` の argv、
`cleanup()` の出力順、`:310` 以降は、今日どの check も守っていない。

一方 `nix` は `runtimeInputs`(`:9-22`)に無く、`writeShellApplication` は
`export PATH="<runtimeInputs>:$PATH"` の前置なので、**`nix` は呼び出し側の PATH から解決される**。
ビルドサンドボックスの PATH には本物の `nix` が無いので、`nix` という名前のスタブを置けば
lock app 全体をオフラインで最後まで走らせられる(§6.2 (d) で実証)。

### 1.5 ドキュメントに実装の無い約束が 1 つ、事実と逆の説明が 1 つある

`docs/architecture.md:528`(Edge cases 表):

```
| lua files not tracked by git | they are not part of the flake source, so they are missed during extraction → the lock app detects working-tree differences and warns |
```

- **後半「the lock app detects working-tree differences and warns」は実装に存在しない。**
  `grep -rn 'working-tree\|untracked\|not tracked\|diff --quiet\|status --porcelain' nix lua` は
  `devPlugins` の working tree に関する記述しか返さない。lock app が `git` を呼ぶのは
  `resolve.lua` の `git ls-remote` だけである。
- **前半「missed during extraction」も事実と逆である。** lock app は `--config` を `realpath` して
  サンドボックスに symlink するだけ(`:107`、`:166` `ln -sfT "$config" "$sandbox/config/nvim"`)で、
  flake source を経由しない。つまり **untracked な lua も抽出され、lock される**
  (§6.2 (d) step 7 が `?? nvim/` のまま抽出に成功している)。実害が出るのはビルド側で、
  `configDir` が Nix path なので `manageConfig = true` のとき deploy される設定から untracked な
  ファイルが抜ける。
- 同じ誤りが `README.md:74-75` にもある:
  「Nix only sees git-tracked files, so an untracked Lua file is silently skipped during extraction.」

## 2. ゴール

承認済みの方針 5 点を、検証可能な形に落とす。

1. **`path:` 参照で lock する。** `lock-app.nix` の `nix` 呼び出し 3 箇所すべてを
   `(cd "$out" && nix flake lock "path:.")` ×2 /
   `(cd "$out" && nix flake update --flake "path:." "''${update_inputs[@]}")` にする(`''$` は `lock-app.nix` の nix 文字列内でのエスケープ。§3.1 と同じ表記)。
   git work tree 内の untracked な lockDir に対する初回 lock と `--update` が終了コード 0 で通り、
   生成される `flake.lock` が従来方式(`git add` 後に参照なしで lock)と byte-identical であること。
   `git add --intent-to-add` 案は採らない(ユーザーの index を書き換えるため)。
2. **失敗を埋もれさせない。** `cleanup()` が終了コードを保存し、`flush_logs` の後、非ゼロなら
   失敗を示す 1 行を **stderr の最終行**として出す。#22 の「warning を握りつぶさない」挙動、
   および終了コードそのものは変えない。
3. **`git add` 忘れを案内する。** lock 成功後、`$out` が git work tree 内にあり生成 3 ファイルの
   いずれかが untracked なら、`git add` するまで home-manager から見えず縮退する旨を出す。
   **index には一切触れない**(`git status --porcelain` が実行前後で同一)。
4. **check を追加する。** `checks.<system>.lock-app`。スタブ `nix` を PATH に置いて lock app を
   end-to-end で走らせ、3 箇所の argv と cwd、失敗時の終了コードと最終行、案内の有無を固定する。
5. **ドキュメントを実態に合わせる。** `README.md` / `docs/architecture.md` /
   `templates/default/README.md`。

やらないこと: untracked な lua の検出(§1.5。§7 R6)、lock 失敗時に書きかけの
`plugins.json` / `flake.nix` を巻き戻すこと(§7 R7)、`nix` を `runtimeInputs` に入れること。

## 3. 設計

### 3.1 `path:.` で lock する

| 行 | 現在 | 変更後 |
|---|---|---|
| `:239` | `(cd "$out" && nix flake lock)` | `(cd "$out" && nix flake lock "path:.")` |
| `:251` | `(cd "$out" && nix flake update "''${update_inputs[@]}")` | `(cd "$out" && nix flake update --flake "path:." "''${update_inputs[@]}")` |
| `:292` | `(cd "$out" && nix flake lock)` | `(cd "$out" && nix flake lock "path:.")` |

- **`cd "$out"` は維持し、参照は相対の `path:.` にする。** `path:$out` と絶対パスを埋め込むと、
  パス中の `#` や `?` が flake 参照の fragment / query として解釈される。実測(§6.2 (b)):
  ディレクトリ名 `a b#c?d%20e` の下で `path:.` は通り、`path:$PWD` は
  `error: getting status of ".../lock/path:/.../a b": No such file or directory` で落ちた。
- `nix flake update --flake <ref> <input...>` は、既存コードが前提にしている位置引数形式と同じ
  Nix ≥ 2.19 の構文なので、要求バージョンは変わらない(`README.md` の Nix ≥ 2.19 の注記は変わらない)。
- 副次効果として、tracked だが未コミットの lockDir で毎回出ていた
  `warning: Git tree '...' is dirty` が出なくなる(§1.1 の出力と §6.2 (c) の出力の差)。
- もう 1 つの副次効果: 参照なしの `nix flake lock` は、`flake.nix` が tracked なら書いた `flake.lock` を
  自分で `git add --intent-to-add` していた。`path:.` ではそれが起きず、`flake.lock` は untracked のまま残る
  (実測と影響は §7 R12)。案内が 3 ファイルを個別に見るのはこのためでもある。
- `:239` の直上に、なぜ `path:` なのかを残す(§5.1)。

### 3.2 失敗行(`cleanup()`)

```bash
cleanup() {
  # Has to be the very first statement: any command run before it replaces $?.
  exit_code=$?
  flush_logs
  rm -rf "$sandbox"
  if [ "$exit_code" -ne 0 ]; then
    echo "nvimx-lock: failed (exit $exit_code) -- look for the error above; it may sit above the import report and warnings" >&2
  fi
}
```

**正確な文言**(`N` は終了コード):

```
nvimx-lock: failed (exit N) -- look for the error above; it may sit above the import report and warnings
```

文言は**すべての失敗経路で真**でなければならない。最初の案
(`-- the error is above, before any import report or warnings`)は `nix` が落ちたときにしか正しくなかった:

| 失敗する場所 | error の位置 | レポート / warning |
|---|---|---|
| extract(`:173-180`) | この行の直上 | どちらも無い |
| resolve(`:214-223` / `:279-286`) | `resolve.log` の中。warning を出してから落ちると **warning の後**に来る | warning と混ざる |
| `nix`(`:239` / `:251` / `:292`) | import レポートと warning の**上** | error の後に `flush_logs` が出す |
| `update-summary.lua`(`:303-308`) | この行の直上(`flush_logs` は `:295` で済んでいる) | error の前 |

4 つに共通して言えるのは「error はこの行より上にある」だけなので、前半でそれだけを断定し
(`look for the error above`)、後半は「レポートや warning のさらに上かもしれない」という
可能性として書く(`it may sit above the import report and warnings`)。#71 の症状(`nix` 失敗)では
後半がそのまま探す場所を指し、他の経路でも嘘にならない。

`$?` まわりの落とし穴。すべて bash 5.3.15 + `set -euo pipefail` で実測した(§6.2 (e)):

- **`exit_code=$?` は関数の 1 文目でなければならない。** 先に `flush_logs` を呼ぶと `$?` は
  その戻り値(0)に置き換わる(T6: `f; ec=$?` → `ec=0`)。
- **`[ "$exit_code" -ne 0 ] && echo ...` と書いてはいけない。`if ... fi` にする。**
  `&&` 形は成功時にテストが偽で `cleanup()` が 1 を返す。trap の中でも `errexit` は生きているので、
  その非ゼロで trap が打ち切られ、**成功した lock の終了コードが 1 に化ける**(T3: rc=1。
  `errexit` が無ければ rc=0 のまま)。`if` 形は条件が偽でも 0 を返す(T2: rc=0)。
- **trap 内で `exit` を呼ばない。** EXIT trap が `exit` しなければ元の終了コードがそのまま
  プロセスの終了コードになる(T1: `exit 3` → 失敗行を出したうえで rc=3)。
- **trap の中でも `set -e` は生きている。** trap 内のコマンドが失敗すると、そこで trap が打ち切られ、
  終了コードはそのコマンドのものに化ける(T5: 元が 3 でも rc=1)。`flush_logs` は末尾が
  `if [ -s ... ]; then cat ...; fi` なので、`cat` が失敗しない限り 0 を返す。`cat` / `echo` が
  失敗するのは stderr が閉じているときだけで、これは今日も同じ(§7 R5)。
  順序を `flush_logs` → `rm -rf` → 失敗行にしているのは、失敗行の `echo` が最後なら、
  万一それが落ちてもサンドボックスの削除は済んでいるからである。
- 変数名は `exit_code` にする。スクリプト本体が `rc` をグローバルで使っている(`:214` / `:279`)ので、
  `rc` を使い回すと読み手が混乱する(`local` にしてもよいが、`local rc=$?` と紛らわしい形は避ける)。
- **引数エラー(exit 2)には出ない。** `usage()` と 4 つのガード(`:82-85` / `:92-95` / `:101-106` /
  `:113-120`)はすべて `trap cleanup EXIT`(`:164`)より前で抜ける。`resolve-update` step 10 と
  `resolve-import-lazy-lock` step 14 / 15 が見ている stderr は変わらない。
- resolve 失敗時の既存の `flush_logs; exit "$rc"`(`:220-223` / `:283-286`)はそのまま。
  `flush_logs` は `resolve_log_shown` で 1 回しか出さないので、trap 側は失敗行だけを足す。

### 3.3 `git add` の案内

`:310` の `done` 行の直後に置く:

```bash
echo "nvimx-lock: done. commit $out/{plugins.json,flake.nix,flake.lock}" >&2
if [ "$(git -C "$out" rev-parse --is-inside-work-tree 2> /dev/null)" = "true" ] \
  && ! git -C "$out" ls-files --error-unmatch -- plugins.json flake.nix flake.lock > /dev/null 2>&1; then
  echo "nvimx-lock: note: this lock is not fully tracked by git. A flake only sees git-tracked files, so until you run" >&2
  echo "nvimx-lock: note:   git -C \"$out\" add plugins.json flake.nix flake.lock" >&2
  echo "nvimx-lock: note: home-manager switch cannot see it and builds the degraded (lazy.nvim-only) neovim instead" >&2
fi
```

**正確な文言**(`<out>` は `realpath` 済みの lockDir):

```
nvimx-lock: note: this lock is not fully tracked by git. A flake only sees git-tracked files, so until you run
nvimx-lock: note:   git -C "<out>" add plugins.json flake.nix flake.lock
nvimx-lock: note: home-manager switch cannot see it and builds the degraded (lazy.nvim-only) neovim instead
```

- **判定は 2 段。** 1 段目 `git -C "$out" rev-parse --is-inside-work-tree` は**出力が `true` で
  あることを見る。終了コードでは判定できない**: bare リポジトリの中と `.git/` の中では
  `false` を出力して **rc=0** で終わる(実測)。git 管理外では `fatal: not a git repository` で rc=128、
  出力は空。どちらも `= "true"` に一致しないので案内は出ない。
- 2 段目 `git ls-files --error-unmatch -- <3 ファイル>` は、1 つでも index に無ければ rc=1 になる
  (実測: `plugins.json` だけ untracked で rc=1、stderr に
  `error: pathspec 'plugins.json' did not match any file(s) known to git`)。
  stdout / stderr は両方捨てる(漏れないことは check step 7 が固定する)。**当初の案は 2 段目だけを判定にしていたが、それだと
  git 管理外(rc=128)でも「失敗」になり誤って案内が出る**ので、1 段目が必須である(§7 R1)。
- **読み取りだけで index に触れない。** `rev-parse` と `ls-files` はどちらも書き込みをしない。
  check が `git status --porcelain` の不変で固定する(§6.1 step 7)。
- 案内するコマンドは `git add <lockDir>` ではなく
  **`git -C "<out>" add plugins.json flake.nix flake.lock`** にする。cwd がどこでも、`$out` が
  submodule の中でも(`git -C` がその submodule を対象にする)そのまま貼って動く。
  nix 自身のエラー文(§1.1)も `git -C "..." add "..."` 形である。
- `$(...)` は `[ ]` の中なので、`git` が rc=128 を返しても `set -e` には掛からない。
  `pkgs.git` は `runtimeInputs`(`:16`)に既にあるので依存は増えない。
- `--update` のサマリ(`:303-308`)より後、スクリプトの最後に出る(`--update` でも出ることは check step 7 が固定する)。
- 場合分け:

  | `$out` の場所 | 1 段目 | 2 段目 | 案内 |
  |---|---|---|---|
  | git 管理外 | 出力なし / rc=128 | — | 出ない |
  | bare リポジトリ内 / `.git/` 内 | `false` / rc=0 | — | 出ない |
  | work tree 内、3 ファイルとも tracked(未コミットでも可) | `true` | rc=0 | 出ない |
  | work tree 内、1 つ以上 untracked | `true` | rc=1 | **出る** |
  | work tree 内、`.gitignore` 対象 | `true` | rc=1 | 出る(`git add` には `-f` が要る。§7 R4) |
  | submodule 内 | `true`(submodule が対象) | submodule の index で判定 | work tree 内の行と同じ(3 ファイルとも tracked なら出ない、1 つ以上 untracked なら出る) |
  | linked worktree(`git worktree add`)内、untracked | `true` | rc=1 | **出る**(その worktree の index で判定) |
  | `git add -N`(intent-to-add)済み | `true` | rc=0 | 出ない(index にエントリがあり、nix からも見える) |
  | lockDir が repo 外への symlink | 出力なし / rc=128 | — | 出ない(`$out` は `realpath` 済みなので実体側で判定される) |
  | `safe.directory` 不一致など git 自体が拒否 | 出力なし / rc=128 | — | 出ない |
  | `GIT_DIR` が export されている(lockDir は管理外) | `true` | rc=1 | **誤って出る**(§7 R4) |

  linked worktree / `git add -N` / symlink / `GIT_DIR` の 4 行はスクラッチの git リポジトリで実測した
  (`stage1='true' stage2 rc=1` / `'true' rc=0` / `'' rc=128` / `'true' rc=1`)。

### 3.4 新 check `lock-app`

**結論: スタブ `nix` 方式の end-to-end は成立する。** §6.2 (d) で、下記スクリプトを
リポジトリ外の式として(スクラッチパッドに置いたパッチ済み `lock-app.nix` に対して)実際に
ビルドし、全 step が通ることを確認した。step 17 のような部分再現に落とす必要は無い。

成立する理由:

- **extract 段**(`timeout 120 nvim --headless ...`): `extractor-snapshot`(`:1416`)や
  `resolve-import-lazy-lock` step 16(`:3038-3065`)が既に同じ `basic-config` をサンドボックス内で
  抽出している。lock app 経由でも通る(`mktemp -d` は `$TMPDIR` 配下、`HOME=$TMPDIR`)。
- **resolve 段**: `basic-config` は `version` を持たないので `git ls-remote` に届かない。
  `--lazy "$seed"` は store path。
- **genflake + nixfmt**: どちらも `runtimeInputs` にある。
- **`nix` 段**: スタブが argv と cwd を記録し、**fixture の `flake.lock` を cwd にコピーする**。
  成功を返すだけでは `flake.lock` が生まれず、収束パス(`:280-281` の `--lock "$out/flake.lock"`)が
  落ちるので、この手当てが必須である。`tests/fixtures/basic-config/nvimx-lock/flake.lock` は
  `lazy-nvim` / `tokyonight-nvim` の 2 input を持ち、`basic-config` の生成 flake と一致する。
- **収束パス**: fixture の `flake.lock` を読んで 2 回目の resolve が走り、`plugins.json` が
  変わらなければ `:292` は呼ばれない。`:292` を踏ませるには `pin = true` のプラグインが要る
  (1 回目は凍結先が無く `resolvedRef = null`、スタブが置いた `flake.lock` の rev に 2 回目で凍結 →
  差分 → 再 genflake → 3 つ目の `nix` 呼び出し)。`tests/fixtures/merge-config` は `pin = true` を
  持つが `version = "^0.1"` もあり `git ls-remote` が要るので使えない。check の中で
  2 行の `init.lua` を heredoc で書く。

check の作りで決めたこと(いずれもレビューで「緑のまま通る変異」が見つかって足したもの):

- **スタブの失敗は終了コード 7**(`exit "$NVIMX_STUB_FAIL"`、step 4 / 4b は `NVIMX_STUB_FAIL=7`)。
  check 内の他の失敗(extract 失敗、usage)は 1 と 2 なので、失敗がすべて 1 だと
  「元の終了コードを保つ」実装と「非ゼロを 1 に丸める」実装を区別できない。rc と失敗行の `(exit 7)` の
  両方で見る。期待する失敗行は `fail_line <code>` という関数で作る。bash の `${var/1/7}` 形の置換は
  nix の `''` 文字列の中では nix の補間として評価されて落ちるので使わない(使うなら `''${`)。
- **専用の `TMPDIR` を切り、`tmp.*` が残っていないことを見る**(`no_leftover`)。`cleanup()` の
  `rm -rf "$sandbox"` は今回書き換える関数の中の行だが、main でもどの check も守っていない。
  neovim が同じ `TMPDIR` に `nvim.<user>/` を残すので、「空であること」ではなく名前で判定する
  (§6.2 (d) で中身を実測)。
- **パスの比較は `here=$(realpath .)` 基準**。lock app が `--out` を `realpath` するため。
- **step 7 は「1 つだけ index に無い」を 3 ファイル分**。1 状態だけだと判定を 1 ファイルに縮めても通る。

名前は **`lock-app`**。`resolve-*` / `extractor-*` が lua の各段を、`hm-module-*` がモジュールを
名指しするのと同じ流儀で、`nix/lib/lock-app.nix` のシェル配線そのもの(argv・trap・案内)を守る
最初の check である。`path:` だけを名前にすると失敗行と案内が名前から漏れる。

スタブが証明するのは「lock app が `nix` に何を渡すか」までで、**本物の nix が `path:.` を
受け付けることは証明しない**。そこは §6.2 (a)-(c) の実測と §6.4 の手動検証が受け持つ。

### 3.5 却下する代替案

- **`git add --intent-to-add`**(issue の案 2): ユーザーの index を黙って書き換える。却下(承認済み)。
- **`nix` を `runtimeInputs` に入れる**: ユーザーの nix(設定・バージョン・認証)と別物を掴む。
  今日の PATH 解決を変えない。スタブ方式もこの性質に乗っている。
- **`path:$out`(絶対パス、`cd` なし)**: `#` / `?` を含むパスで壊れる(§3.1 の実測)。
- **失敗時に warning を出さない**(issue の案 3「no further report」): #22 を壊す。
  warning は出したまま、最後に失敗行を足す(承認済み)。
- **check を step 17 型の部分再現にする**: end-to-end が成立したので不要。部分再現では
  `:239` / `:251` / `:292` の実際の argv を守れない。

## 4. 既存機能との関係

- **`flake.lock` の中身 / ビルド側**: 変わらない(§1.3、§6.2 (a)(c) で byte-identical を実測)。
  `sources.nix` / `make-env.nix` は触らない。既存ユーザーの lockDir は再 lock しても差分が出ない
  (tracked + commit 済みの lockDir に `nix flake lock "path:."` → `git status` clean、§6.2 (a) G)。
- **`--update`(#24)**: `:251` が `--flake "path:."` になるだけ。`update-plan.txt` の内容、
  サマリ、`flake.lock.before` との比較は不変。実機で `--update tokyonight.nvim` が untracked な
  lockDir に対して通ることを確認(§6.2 (c))。
- **`--import-lazy-lock`(#25)**: issue の再現コマンドはこれ。import レポートは従来どおり
  `flush_logs` が出す。成功時は `done` と案内がその後に来る。**`nix` が落ちたときは import レポートが
  2 回出る**(main からある既存挙動。原因とログは §7 R11)。失敗行はその 2 回分の後、最終行に来る。
  重複そのものは本件では直さない。check step 4b はこの経路の順序(error → import 行 → 失敗行)を
  固定するが、**import 行が何回出るかには依存しない**。
- **nix による `flake.lock` の intent-to-add**: 無くなる(§7 R12)。`flake.nix` だけ tracked な状態で lock すると、
  今日は nix が `flake.lock` を `git add -N` するが、変更後は untracked のまま残る。案内がそれを拾う。
- **#22(warning を握りつぶさない)**: `flush_logs` の呼び出し位置・回数・内容は不変。
- **home-manager ラッパ**(`nix/home-manager/default.nix:21-33` の `lockCommand`): `--config` /
  `--out` を前置して `exec` するだけなので無関係。`projectDir` 経由でも `$out` は work tree 内の
  絶対パスになり、案内はそのまま機能する。
- **既存 check**: `resolve-update` step 10、`resolve-import-lazy-lock` step 14 / 15 は trap 設定前に
  exit 2 で抜けるので stderr が変わらない(§3.2)。他に `nvimx-lock` を実行する check は無い
  (`grep -n 'nvimx-lock ' flake.nix` の実行行は `:2526` / `:3015` / `:3026` / `:3032` のみ)。
- **`packages.demo` / hm 系 check**: `makeEnv` しか通らず lock app の本文に依存しない。
  ただし `hm-module` 系は `nvimx-lock` を `home.packages` に入れるので、derivation のハッシュは変わる
  (再ビルドが走るだけ)。

## 5. 実装手順

### 5.1 `nix/lib/lock-app.nix`

パッチ全体(コメントを除く)。main `74aa086` に対して `git apply --check` が通ることと、適用後のファイルが
`writeShellApplication` の shellcheck を通ることを確認済み:

```diff
--- a/nix/lib/lock-app.nix
+++ b/nix/lib/lock-app.nix
@@ -158,8 +158,12 @@
       fi
     }
     cleanup() {
+      exit_code=$?
       flush_logs
       rm -rf "$sandbox"
+      if [ "$exit_code" -ne 0 ]; then
+        echo "nvimx-lock: failed (exit $exit_code) -- look for the error above; it may sit above the import report and warnings" >&2
+      fi
     }
     trap cleanup EXIT
     mkdir -p "$sandbox/config" "$sandbox/data/nvim/lazy" "$sandbox/state" "$sandbox/cache"
@@ -236,7 +240,7 @@
     nixfmt "$out/flake.nix"
 
     echo "nvimx-lock: pinning with nix flake lock" >&2
-    (cd "$out" && nix flake lock)
+    (cd "$out" && nix flake lock "path:.")
 
     # --update (#24): the plan resolve.lua wrote above is exactly the inputs whose previous
     # decision was force-discarded, so this is what actually walks them forward -- `nix flake
@@ -248,7 +252,7 @@
       mapfile -t update_inputs < "$sandbox/update-plan.txt"
       if [ "''${#update_inputs[@]}" -gt 0 ]; then
         echo "nvimx-lock: updating ''${#update_inputs[@]} input(s) with nix flake update" >&2
-        (cd "$out" && nix flake update "''${update_inputs[@]}")
+        (cd "$out" && nix flake update --flake "path:." "''${update_inputs[@]}")
       fi
     fi
 
@@ -289,7 +293,7 @@
       mv "$sandbox/plugins2.json" "$out/plugins.json"
       nvim -l "${luaDir}/genflake.lua" "$out/plugins.json" "$out/flake.nix"
       nixfmt "$out/flake.nix"
-      (cd "$out" && nix flake lock)
+      (cd "$out" && nix flake lock "path:.")
     fi
 
     flush_logs
@@ -308,5 +312,11 @@
     fi
 
     echo "nvimx-lock: done. commit $out/{plugins.json,flake.nix,flake.lock}" >&2
+    if [ "$(git -C "$out" rev-parse --is-inside-work-tree 2> /dev/null)" = "true" ] \
+      && ! git -C "$out" ls-files --error-unmatch -- plugins.json flake.nix flake.lock > /dev/null 2>&1; then
+      echo "nvimx-lock: note: this lock is not fully tracked by git. A flake only sees git-tracked files, so until you run" >&2
+      echo "nvimx-lock: note:   git -C \"$out\" add plugins.json flake.nix flake.lock" >&2
+      echo "nvimx-lock: note: home-manager switch cannot see it and builds the degraded (lazy.nvim-only) neovim instead" >&2
+    fi
   '';
 }
```

加えてコメントを 4 箇所。このファイルは「なぜ」を書く密度が高いので合わせる:

1. `flush_logs` 上の既存コメント(`:135-146`)の後、`cleanup()` の直上:
   `exit_code=$?` が 1 文目である理由、`if` 形である理由(`&&` 形は成功を 1 に化かす)、
   `exit` しない理由、失敗行が最後である理由(#71: nix の error が `flush_logs` の出力に埋もれた)。
   引数エラーは trap 設定前に抜けるので対象外であることも 1 行。
2. `:238` の `echo` の上:

   ```
   # "path:." on purpose (#71). With no flake ref nix resolves a directory inside a git work tree
   # as a git+file flake, which only sees tracked files -- and the flake.nix written a few lines
   # up is untracked on every first lock. A path: flake ignores git entirely. The ref stays
   # relative and `cd "$out"` stays: an absolute "path:$out" would hand `#` / `?` in the path to
   # the flake ref parser as a fragment / query. flake.lock does not record how the flake itself
   # was referred to (its root node has only `inputs`), so the file is byte-identical either way.
   ```
3. `:251` の上の既存コメント(`:241-246`)の末尾に、`--flake "path:."` は上と同じ理由であることを 1 行。
   `:292` は「上と同じ」の 1 行で足りる。
4. 案内の `if` の上: 2 段判定の理由(`rev-parse` は bare / `.git` 内で `false` を rc=0 で返すので
   出力を比較する)、読み取りだけで index に触れないこと(#71 の計画が `--intent-to-add` を却下した理由)、
   `make-env.nix` の `hasLock` が untracked な lock を見られないこと。加えて、3 ファイルを並べる理由:
   `path:` にしたので nix はもう `flake.lock` を intent-to-add しない。`flake.nix` が tracked でも
   `flake.lock` は untracked のまま残りうるので、外してはいけないのは `flake.lock`(と `plugins.json`)である(§7 R12)。
   `flake.nix` はビルドに読まれない(`hasLock` は他の 2 つしか見ない)が、3 ファイルを一緒にコミットさせるために並べている。

ファイル冒頭のコメント(`:1-2`)は変更不要。

### 5.2 `flake.nix`

**(1) 新 check。** `resolve-import-lazy-lock` の閉じ(`:3135` の `'';`)と `resolve-sources` の
コメント(`:3136`)の間に置く。**下のブロックは一字も変えずに `flake.nix:3135` の直後へ挿入すること。**
インデントも nixfmt の正規形にしてあり、本ファイルから機械的に抽出して挿入したツリーで
`nix fmt -- --ci`(0 changed)、`nix build`、darwin の `nix eval` が通っている(§6.2 (d))。
この check の本体は nix の `''` 文字列なので、**コメントを足す・直すときは `''` と `${` を書かないこと**
(`''` は文字列を閉じ、`${` は nix の補間になる。3 巡目の掲載版はコメント 1 つでこれを踏んだ)。

```nix
          # The lock app itself, end to end (#71). Every other check stops short of the `nix` calls
          # in nix/lib/lock-app.nix -- recursive nix cannot run in a build -- so until this check
          # nothing pinned what those calls are handed, what the EXIT trap prints, or anything
          # after them. `nix` is not in the app's runtimeInputs: it is resolved from the caller's
          # PATH, and the sandbox has no real one, so a stub named `nix` stands in. The stub
          # records argv and cwd, exits with whatever NVIMX_STUB_FAIL says when told to fail, and
          # otherwise drops a fixture flake.lock where the real one would write
          # it -- succeeding alone is not enough, because the convergence pass reads
          # "$out/flake.lock" right after. What this cannot prove is that the real nix accepts
          # `path:.`; that is the plan's §6.4 manual verification.
          lock-app =
            let
              stubNix = pkgs.writeShellScriptBin "nix" ''
                printf '%s\n' "$*" >> "$NVIMX_STUB_ARGV"
                pwd >> "$NVIMX_STUB_CWD"
                if [ -n "''${NVIMX_STUB_FAIL:-}" ]; then
                  echo "error: stub nix was told to fail" >&2
                  exit "$NVIMX_STUB_FAIL"
                fi
                cp "$NVIMX_STUB_LOCK" flake.lock
                chmod u+w flake.lock
              '';
            in
            pkgs.runCommand "lock-app"
              {
                nativeBuildInputs = [
                  pkgs.git
                  pkgs.jq
                  nvimxLib.lockApp
                  stubNix
                ];
              }
              ''
                export HOME=$TMPDIR
                fx=${./tests/fixtures/basic-config}
                # nvimx-lock realpath's --out, so every path compared against its output has to be
                # resolved the same way: $PWD may go through a symlink (darwin's /tmp), which is
                # why checks.resolve-import-lazy-lock step 15 says $(realpath cfg) too.
                here=$(realpath .)
                # A TMPDIR of its own, so that what nvimx-lock's `mktemp -d` leaves behind can be told
                # apart from everything else: its sandbox is the only thing here named tmp.*. neovim
                # keeps a nvim.<user>/ directory in TMPDIR too, which is why this looks for the name and
                # not for an empty directory.
                mkdir locktmp
                export TMPDIR=$here/locktmp
                no_leftover() {
                  if [ -n "$(find "$TMPDIR" -mindepth 1 -maxdepth 1 -name 'tmp.*')" ]; then
                    echo "nvimx-lock left its sandbox behind in $TMPDIR" >&2
                    exit 1
                  fi
                }
                export NVIMX_STUB_LOCK=$fx/nvimx-lock/flake.lock
                export NVIMX_STUB_ARGV=$here/argv NVIMX_STUB_CWD=$here/cwd
                reset() { : > argv; : > cwd; }
                # `! grep -q` would be vacuous: a `!`-negated command never trips errexit.
                absent() { # <pattern> <file>
                  if grep -q -- "$1" "$2"; then
                    echo "unexpected \"$1\" in $2" >&2
                    exit 1
                  fi
                }
                # The expected last line of a failed run, built by a function rather than by a bash
                # pattern substitution on a variable (nix would read that as its own interpolation here).
                fail_line() { # <exit code>
                  echo "nvimx-lock: failed (exit $1) -- look for the error above; it may sit above the import report and warnings"
                }

                # 1. First lock: one `nix flake lock`, with an explicit path: ref, run from inside
                # the lock dir. The generated files equal the committed fixture lock, which is what
                # makes the stub's flake.lock a faithful stand-in for the rest of this check.
                reset
                nvimx-lock --config $fx --out first 2> first.log
                no_leftover
                [ "$(cat argv)" = "flake lock path:." ]
                [ "$(cat cwd)" = "$here/first" ]
                cmp first/plugins.json $fx/nvimx-lock/plugins.json
                cmp first/flake.nix $fx/nvimx-lock/flake.nix
                [ "$(tail -n 1 first.log)" = "nvimx-lock: done. commit $here/first/{plugins.json,flake.nix,flake.lock}" ]
                absent 'nvimx-lock: note:' first.log
                absent 'nvimx-lock: failed' first.log

                # 2. --update: the second call site, `nix flake update`, carries the same ref.
                reset
                nvimx-lock --config $fx --out first --update 2> update.log
                printf '%s\n' 'flake lock path:.' 'flake update --flake path:. lazy-nvim tokyonight-nvim' > want-argv
                diff -u want-argv argv
                [ "$(sort -u cwd)" = "$here/first" ]

                # 3. The third call site only runs when the convergence pass changes plugins.json.
                # A first-time `pin = true` does that: nothing to freeze onto until the stub's
                # flake.lock exists. tests/fixtures/merge-config has a pin too, but also a
                # `version`, which needs git ls-remote -- hence a config written here. The `build`
                # is there for step 4: it gives resolve.lua a warning to hold back.
                mkdir pincfg
                cat > pincfg/init.lua <<'LUA'
                vim.opt.rtp:prepend(vim.fn.stdpath("data") .. "/lazy/lazy.nvim")
                require("lazy").setup({ { "folke/tokyonight.nvim", pin = true, build = ":Foo" } })
                LUA
                reset
                nvimx-lock --config pincfg --out pinned 2> pinned.log
                printf '%s\n' 'flake lock path:.' 'flake lock path:.' > want-argv
                diff -u want-argv argv
                [ "$(sort -u cwd)" = "$here/pinned" ]
                grep -q '^nvimx-lock: freezing pinned plugins$' pinned.log
                jq -e '.plugins["tokyonight.nvim"].resolvedRef | test("^[0-9a-f]{40}$")' pinned/plugins.json > /dev/null

                # 4. #71's actual symptom. When `nix` fails, the held-back warnings still come out
                # (#22) -- after nix's own error, which is how the error got buried. The exit code
                # survives the trap, and the very last line now says the run failed. The stub exits 7,
                # not 1: the other failures in this check are 1 and 2, so only this tells "the original
                # code is kept" apart from "anything non-zero becomes 1" -- in the exit status and
                # in the number the last line prints.
                reset
                rc=0
                NVIMX_STUB_FAIL=7 nvimx-lock --config pincfg --out failed 2> failed.log || rc=$?
                [ "$rc" -eq 7 ]
                [ "$(tail -n 1 failed.log)" = "$(fail_line 7)" ]
                [ ! -e failed/flake.lock ]
                no_leftover
                err_at=$(grep -n '^error: stub nix was told to fail$' failed.log | cut -d: -f1)
                warn_at=$(grep -n '^\[nvimx\] warning: plugin "tokyonight.nvim"' failed.log | cut -d: -f1)
                [ "$err_at" -lt "$warn_at" ]
                [ "$(grep -c '^nvimx-lock: failed' failed.log)" -eq 1 ]
                absent '^nvimx-lock: done' failed.log

                # 4b. The same failure on the path #71 was actually reported on: --import-lazy-lock.
                # The import report is held back like the warnings are, so it lands after nix's
                # error too, and the failure line still has to come last. Deliberately indifferent
                # to how many times the report is printed: today a failing first `nix` prints it
                # twice (pass 2 has not truncated resolve.log yet, so the lines sit in both
                # import.log and resolve.log) -- a known wart, and fixing it must not break this.
                cat > lazy-lock.json <<'JSON'
                { "tokyonight.nvim": { "branch": "main", "commit": "1234123412341234123412341234123412341234" } }
                JSON
                reset
                rc=0
                NVIMX_STUB_FAIL=7 nvimx-lock --config pincfg --out failed-import \
                  --import-lazy-lock lazy-lock.json 2> failed-import.log || rc=$?
                [ "$rc" -eq 7 ]
                [ "$(tail -n 1 failed-import.log)" = "$(fail_line 7)" ]
                [ "$(grep -c '^nvimx-lock: failed' failed-import.log)" -eq 1 ]
                err_at=$(grep -n '^error: stub nix was told to fail$' failed-import.log | cut -d: -f1)
                import_first=$(grep -n '^\[nvimx\] import: ' failed-import.log | head -n 1 | cut -d: -f1)
                import_last=$(grep -n '^\[nvimx\] import: ' failed-import.log | tail -n 1 | cut -d: -f1)
                [ "$err_at" -lt "$import_first" ]
                [ "$import_last" -lt "$(wc -l < failed-import.log)" ]

                # 5. A failure before `nix` is ever reached ends the same way (the trap is what
                # prints the line, not the nix step).
                mkdir nosetup
                echo 'vim.g.nvimx_no_setup = true' > nosetup/init.lua
                reset
                rc=0
                nvimx-lock --config nosetup --out nosetup-out 2> nosetup.log || rc=$?
                [ "$rc" -eq 1 ]
                [ "$(tail -n 1 nosetup.log)" = "$(fail_line 1)" ]
                [ ! -s argv ]
                no_leftover

                # 6. A usage error exits before the trap is installed, so it gets no failure line.
                rc=0
                nvimx-lock --config $fx 2> usage.log || rc=$?
                [ "$rc" -eq 2 ]
                absent 'nvimx-lock: failed' usage.log

                # 7. The `git add` note. Inside a work tree, with any of the three files untracked,
                # the lock still succeeds and says what is missing; once all three are tracked it
                # says nothing. Read-only throughout: the index is whatever the user left it as.
                git init -q -b main repo
                mkdir repo/nvim
                cp $fx/init.lua repo/nvim/
                lockdir=$here/repo/nvim/nvimx-lock
                note_cmd="nvimx-lock: note:   git -C \"$lockdir\" add plugins.json flake.nix flake.lock"
                nvimx-lock --config repo/nvim --out repo/nvim/nvimx-lock 2> untracked.log
                [ "$(grep -c '^nvimx-lock: note:' untracked.log)" -eq 3 ]
                grep -qxF "$note_cmd" untracked.log
                [ "$(tail -n 1 untracked.log)" = 'nvimx-lock: note: home-manager switch cannot see it and builds the degraded (lazy.nvim-only) neovim instead' ]
                # git's own complaint about the untracked files (`error: pathspec ...`) is not the
                # user's business: the probe's output is discarded, only its verdict is used.
                absent 'pathspec' untracked.log
                [ "$(git -C repo status --porcelain)" = "?? nvim/" ]
                # --update ends with the same note, after its summary: the note is the last thing
                # any successful run prints, not something only a plain lock does.
                nvimx-lock --config repo/nvim --out repo/nvim/nvimx-lock --update 2> untracked-update.log
                grep -q '^nvimx-lock: no plugins updated' untracked-update.log
                grep -qxF "$note_cmd" untracked-update.log
                [ "$(tail -n 1 untracked-update.log)" = 'nvimx-lock: note: home-manager switch cannot see it and builds the degraded (lazy.nvim-only) neovim instead' ]
                [ "$(git -C repo status --porcelain)" = "?? nvim/" ]
                # Each of the three files on its own is enough to trigger the note: one state per
                # file, with only that file missing from the index. A single partial state would
                # let a check narrowed to one file (whichever) pass unnoticed.
                for missing in plugins.json flake.nix flake.lock; do
                  git -C repo add nvim/nvimx-lock
                  git -C repo rm -q --cached nvim/nvimx-lock/$missing
                  nvimx-lock --config repo/nvim --out repo/nvim/nvimx-lock 2> partial-$missing.log
                  grep -qxF "$note_cmd" partial-$missing.log
                done
                git -C repo add nvim/nvimx-lock
                git -C repo status --porcelain > status.before
                # stdout too: with everything tracked the probe would list the three file names there.
                nvimx-lock --config repo/nvim --out repo/nvim/nvimx-lock > tracked.out 2> tracked.log
                absent 'nvimx-lock: note:' tracked.log
                [ ! -s tracked.out ]
                git -C repo status --porcelain | diff -u status.before -

                # 8. `git rev-parse --is-inside-work-tree` prints "false" and still exits 0 inside
                # a bare repository, so the note has to compare the output, not the exit code.
                git init -q --bare bare.git
                nvimx-lock --config $fx --out bare.git/lock 2> bare.log
                absent 'nvimx-lock: note:' bare.log

                touch $out
              '';
```

実装時の注意:

- step 7 は `nvim/init.lua` を **`git add` していない**(`?? nvim/`)。lock app は working tree を
  直接読むので抽出は通る。§1.5 の訂正(untracked な lua は抽出される)をこの step が実証している。
- `pkgs.git` は check 自身の `git init` 用に必要(lock app の `runtimeInputs` は check の PATH に
  伝播しない)。`pkgs.neovim-unwrapped` は lock app が自前で持つので不要。
- **否定側の assert を `! grep -q ...` と書いてはいけない。** `!` で反転したコマンドは `set -e` の
  対象外なので、一致しても check は止まらない(実測: `set -e; echo x > f; ! grep -q x f; echo survived`
  は `survived` を出す)。本計画の最初の下書きはこの形で、緑になるだけで何も守っていなかった。
  スニペットの `absent` ヘルパは、既存 check の流儀
  (`if grep -q ...; then echo ... >&2; exit 1; fi`、例: `flake.nix:2597` / `:3087-3090`)を
  7 箇所で繰り返さないためのものである。`[ ! -e ... ]` / `[ ! -s ... ]` は `[` 自身の終了コードなので問題ない。

**(2) 既存コメントの更新。** 「`nix` を呼ぶ行はどの check も通らない」という記述が古くなる:

- `resolve-update` ヘッダ(`:2385-2388`): 「the rest is covered by the plan's §6.4 manual verification」を
  「the calls themselves (argv, cwd) are pinned by checks.lock-app against a stub `nix`; that the
  real nix moves the inputs is the plan's §6.4 manual verification」相当に直す。
- `resolve-import-lazy-lock` step 17(`:3074-3076`): 「The full two-pass pipeline can't run inside
  this check」は本物の nix については今も正しい。checks.lock-app がスタブで通していることを 1 文足し、
  この step が残る理由(import 行の truncate は lock-app では検証していない)を書く。

### 5.3 `README.md`

1. **Usage 1(`:74-75`)** —— 事実と逆の説明を直す(§1.5):

   ```markdown
   1. Write your Lua config using the same definition method as lazy.nvim, then `git add` it.
      `nvimx-lock` reads your working tree, so it locks an untracked Lua file just the same — but a
      flake only sees git-tracked files, so home-manager would then deploy your config without it.
   ```
2. **Usage 3(`:90-95`)** —— コードブロックの後に:

   ```markdown
      Do not skip the `git add`. A flake only sees git-tracked files, so an untracked lock
      directory is invisible to home-manager and the build degrades exactly as if you had never
      locked. `nvimx-lock` prints a note when the lock it just wrote is not tracked yet. Locking
      itself does not need the directory to be tracked.
   ```
3. **Migrating 4(`:149-157`)** —— `git add nvim/nvimx-lock && git commit ...` の後の段落に 1 文:
   「Until the lock directory is tracked, home-manager cannot see it and builds the degraded
   Neovim; `nvimx-lock` reminds you if it is not.」
4. `:109-112`(Updating の段落)は、lock app が実行するコマンドの記述なので**直す**: 前半を `nix flake update --flake path:. <inputName>...` にし、手動フォールバックの `nix flake lock --update-input <name>` には「git リポジトリ内では lockDir が untracked の間は参照なしの形が落ちるので、先に追跡するか flake 参照に `path:.` を渡すこと」(README の文言は ``and inside a git repository that bare form fails while the lock directory is untracked, so track it first or pass `path:.` as the flake reference``)を足す(古い Nix での `path:.` 付き構文は手元で確かめられないので断定しない)。当初は「必要 Nix バージョンの説明として正しく、`--flake path:.` は実装の詳細」として据え置いたが、これは誤分類だった(実装・architecture.md `:287` とずれる)。
5. Migrating 1(`:122` 付近)「and `git add` all of it. Nix only sees git-tracked files.」は**直す**: 直後が lock の手順なので「git add しないと lock / import が拾わない」と読めてしまう。実際には `nvimx-lock` は `--config` も `lazy-lock.json` も working tree から読み、追跡が効くのはビルド時の deploy だけ。Usage 1 と同じ区別(`nvimx-lock` and the import read your working tree either way, but a flake only sees git-tracked files, so anything you leave untracked would be missing from the config home-manager deploys)に書き換える。当初は「一般論として正しい」として据え置いたが、同じ PR の Usage 1 と食い違うため訂正した。`git add` する手順自体は残す。
6. Migrating 3(`:136` 付近)「It is printed at the very end of the run」は**直す**: 今回の変更で、import レポートの後ろに `done` 行に加えて案内 3 行が続くようになり、「very end」が実態から離れた。「at the end of the run, after `nix flake lock`'s output,」にする。

lock 前に lockDir を `git add` しろという注記は**足さない**(不要になったので)。

### 5.4 `docs/architecture.md`

| 行 | 現在 | 変更 |
|---|---|---|
| `:90` | `L->>F: cd lockDir && nix flake lock` | `L->>F: cd lockDir && nix flake lock path:.` |
| `:156` | `[5] Place it in lockDir and run (cd lockDir && nix flake lock)` | `(cd lockDir && nix flake lock "path:.")` にし、`:157` の後に「`path:.` ignores git tracking: lockDir usually sits inside the user's git repository, where a bare `nix flake lock` would resolve it as a git+file flake and not see the just-generated, untracked flake.nix (#71)」を 2 行で足す |
| `:287` | ``then runs `nix flake lock` ... followed by `nix flake update <inputName...>` `` | 前半を ``then runs `nix flake lock "path:."` ``、後半を `nix flake update --flake path:. <inputName...>` にする(同じ文の中で表記を揃える。当初この行は後半しか挙げていなかった) |
| `:288` | ``Back door: plain `nix flake update <inputName>` in lockDir also works`` | 「(same as twist) once lockDir is tracked by git -- an untracked lockDir makes the bare form fail (#71), so add `--flake path:.` there --」の形に整理する。untracked だと落ちることは §1.1 で実測済み |
| `:470` | ``→ `git add` → `home-manager switch`.`` | 「(`nvimx-lock` says so when the lock it wrote is still untracked)」を足す |
| `:517` | checks 一覧 | **`resolve-import-lazy-lock,` の直後、`resolve-build-warnings` の前に `lock-app,` を足す**(lock パイプライン系の並びの末尾) |
| `:528` | Edge cases「lua files not tracked by git」 | 下記に置き換える |
| `:528` の後 | — | 下記の新しい行を足す |
| `:555` | ``After `nix run .#lock`, `cd lockDir && nix flake lock` must succeed`` | `cd lockDir && nix flake lock "path:."` |

Edge cases 表(`:528`)の置き換えと追加:

```markdown
| lua files not tracked by git | `nvimx-lock` reads `--config` straight from the working tree, so they *are* extracted and locked. The build is where they go missing: `configDir` is a flake path, so the copy home-manager deploys (`manageConfig = true`) leaves them out. Nothing detects this today -- `git add` before switching |
| lockDir not tracked by git (every first lock) | locking works regardless: `nix flake lock "path:."` ignores git tracking (#71). The build cannot see an untracked `plugins.json` / `flake.lock`, so it degrades until they are added; `nvimx-lock` ends with a note naming the `git add` to run (`checks.lock-app`) |
```

**`:528` の扱いの決定: 実態に合わせて直す。検出機能は今回実装しない。**
「lock app が working-tree の差分を検出して警告する」は実装されたことのない約束であり、
しかも前提(抽出で漏れる)が誤っているので、文言どおりに実装しても意味が無い。本当に役立つ検出は
「`configDir` 配下に untracked なファイルがあると、deploy される設定と lock がずれる」だが、
これは #71(lockDir が untracked)とは別の問題で、警告の文言・`manageConfig = false` での扱い・
`.gitignore` との関係を別途設計する必要がある。別 issue の候補として §7 R6 に残す。

Repository layout の `tests/fixtures/` 行(`:508`)は変更不要(fixture を足さない)。

### 5.5 `templates/default/README.md`

手順 3(`:9-14`)の順序(lock → `git add`)は既に正しい。コードブロックの後に README と同じ趣旨を 1 文:

```markdown
   Do not skip the `git add`: a flake only sees git-tracked files, so until the lock directory is
   tracked home-manager builds the degraded (lazy.nvim-only) Neovim. `nvimx-lock` says so if it is not.
```

加えて「Coming from plain lazy.nvim」の箇条書き(`lazy-lock.json` を `git add` させる行)に、README Migrating 1 と同じ区別を括弧で足す: `(the lock reads the working tree either way, but a flake only sees tracked files)`。当初は触らないつもりだったが、README 側を直したので食い違わないように合わせた。

### 5.6 触らないもの

- `nix/lib/sources.nix` / `nix/lib/make-env.nix` / `nix/home-manager/default.nix` —— 読む側は不変(§4)。
- `lua/nvimx/*.lua` —— lua は 1 行も変えない。
- `tests/fixtures/` —— 追加なし。check 内の 2 つの `init.lua` と step 4b の `lazy-lock.json` は heredoc / `echo` で書く。
- `CLAUDE.md` —— Commands / Gotchas に影響する変更は無い。
- `.github/workflows/` —— 新 check は `nix flake check` に乗るだけ。

## 6. テスト

### 6.1 assert 一覧(何を守るか)

| step | 守るもの | 壊れ方の例 |
|---|---|---|
| 1 | `:239` の argv が `flake lock path:.`、cwd が lockDir。成功時に失敗行・案内が出ない。最終行が `done`。**sandbox(`mktemp -d`)が残らない** | `"path:."` を消す / `cd` を消す / `&&` 形の失敗行(rc=1 に化ける) / `cleanup()` の `rm -rf` を消す |
| 2 | `:251` の argv が `flake update --flake path:. <inputs>`、cwd が lockDir | `--flake` を落とす / 順序を変える / `cd` を消す |
| 3 | `:292` の argv と **cwd(lockDir)**。収束パスの再 lock も `cd "$out"` して `path:.` | 3 箇所目だけ直し忘れる / 3 箇所目の `cd "$out" &&` を落とす |
| 4 | `nix` が **7** で失敗したとき: **rc=7(trap を通っても元の終了コードのまま)**、error → warning の順、**最終行が `failed (exit 7)` の失敗行**、失敗行は 1 回、`done` は出ない、sandbox が残らない | 失敗行を `flush_logs` の前に出す / trap で `exit 0` する / #22 を壊して warning を消す / trap が終了コードを 1 に丸める(失敗行の後で `exit 1`)/ 文言の `N` を `1` に固定する |
| 4b | issue の再現コマンドの経路(`--import-lazy-lock` + `nix` が 7 で失敗): rc=7、error → import 行 → **最終行が失敗行**、失敗行は 1 回。import 行の回数には依存しない(最初の import 行が error より後、最後の import 行が最終行より前) | import レポートを失敗行の後に出す / `nix` より前に出す |
| 5 | `nix` 以前の失敗(extract が rc=1)でも最終行が `failed (exit 1)` の失敗行。`nix` は呼ばれない。sandbox が残らない | 失敗行を `nix` 呼び出しの `\|\|` に付ける |
| 6 | exit 2 には失敗行が出ない | trap を引数パースより前に移す |
| 7 | untracked で案内 3 行(コマンド行は逐語、最終行は逐語)。**判定に使う git の出力が漏れない**(untracked 時の stderr に `pathspec` が無い、tracked 時の stdout が空)。**`--update` でもサマリの後、最終行まで案内が出る**。**3 ファイルのどれか 1 つだけが untracked な 3 状態すべてで出る**。全部 tracked で出ない。**index が不変** | `git add -N` を入れる / 判定を 3 ファイルのうち 1 つだけに縮める(どの 1 つでも赤) / 判定コマンドの `> /dev/null 2>&1` を外す / `--update` のとき案内を出さない |
| 8 | bare リポジトリ内で案内が出ない | 1 段目を終了コード判定にする |

### 6.2 計画作成時の実測(実装者への根拠)

**(a) `path:.` の妥当性 —— 通った。** 使い捨て git リポジトリ `e1/dot`(`nvim/init.lua` だけ commit 済み)に
`nvim/nvimx-lock/flake.nix`(input は `github:folke/lazy.nvim` と `github:nvim-lua/plenary.nvim`、
ともに `flake = false`)を untracked で置いた。`L=nvim/nvimx-lock`:

```console
$ git status --short
?? nvim/nvimx-lock/
$ (cd $L && nix flake lock); echo "rc=$?"                    # A: 現状
error: Path 'nvim/nvimx-lock/flake.nix' in the repository "$S/e1/dot" is not tracked by Git.
rc=1
$ (cd $L && nix flake lock "path:."); echo "rc=$?"; ls $L    # B: 変更後
warning: creating lock file "$S/e1/dot/nvim/nvimx-lock/flake.lock":
• Added input 'lazy-nvim':
    'github:folke/lazy.nvim/306a05526ada86a7b30af95c5cc81ffba93fef97?narHash=sha256-5A4k...' (2025-12-17)
• Added input 'plenary-nvim':
    'github:nvim-lua/plenary.nvim/74b06c6c75e4eeb3108ec01852001636d85a932b?narHash=sha256-nkfE...' (2026-04-10)
rc=0
flake.lock
flake.nix
$ cp $L/flake.lock ../lock.path
$ rm $L/flake.lock; git add $L/flake.nix; (cd $L && nix flake lock)   # C: 従来方式
warning: Git tree '$S/e1/dot' is dirty
warning: creating lock file "...": • Added input 'lazy-nvim': • Added input 'plenary-nvim':
$ cmp $L/flake.lock ../lock.path && echo IDENTICAL; sha256sum $L/flake.lock ../lock.path
IDENTICAL
e06722fef5e8dc6d6633a742e44b128bd069680079111d2d8110064a650a70ab  nvim/nvimx-lock/flake.lock
e06722fef5e8dc6d6633a742e44b128bd069680079111d2d8110064a650a70ab  ../lock.path
$ git reset -q                                               # 再び untracked に
$ (cd $L && nix flake update plenary-nvim)                   # D: 現状の update
error: Path 'nvim/nvimx-lock/flake.nix' in the repository "$S/e1/dot" is not tracked by Git.
$ (cd $L && nix flake update --flake "path:." plenary-nvim); echo "rc=$?"   # E: 変更後
rc=0
$ # F: flake.lock の plenary の rev を手で古い値に書き換えてから同じコマンド
warning: updating lock file "...":
• Updated input 'plenary-nvim':
    'github:nvim-lua/plenary.nvim/b9fd5226c2f76c951fc8ed5923d85e4de065e509?...'
  → 'github:nvim-lua/plenary.nvim/74b06c6c75e4eeb3108ec01852001636d85a932b?...'
rc=0                                                         # → lock.path と IDENTICAL に戻る
$ # G: lockDir を commit してから nix flake lock "path:." → rc=0、git status は clean(差分なし)
$ jq -c '.nodes.root, .root, .version' $L/flake.lock
{"inputs":{"lazy-nvim":"lazy-nvim","plenary-nvim":"plenary-nvim"}}
"root"
7
```

**(b) パス中の特殊文字。** `sp/a b#c?d%20e/lock/` に同じ `flake.nix` を置いて:

```console
$ nix flake lock "path:."; echo "rc=$?"          # → rc=0、lock.path と IDENTICAL
$ nix flake lock "path:$PWD"
error: getting status of "$S/e1/sp/a b#c?d%20e/lock/path:$S/e1/sp/a b": No such file or directory
```

**(c) パッチ済み lock app を本物の nix で実行 —— 通った。** §5.1 のパッチを当てた `lock-app.nix` を
スクラッチパッドからビルドし(リポジトリは無変更)、§1.1 と同じリポジトリ `e2/dot` で:

```console
$ $S/px/app/bin/nvimx-lock --config ./nvim --out ./nvim/nvimx-lock; echo "rc=$?"
nvimx-lock: extracting spec from $S/e2/dot/nvim
nvimx-lock: resolving plugins
nvimx-lock: generating lock flake
nvimx-lock: pinning with nix flake lock
warning: creating lock file "$S/e2/dot/nvim/nvimx-lock/flake.lock":
• Added input 'lazy-nvim':
• Added input 'nvim-treesitter':
• Added input 'tokyonight-nvim':
[nvimx] warning: plugin "nvim-treesitter": build is a neovim command (":TSUpdate") and cannot be run at build time. ...
[nvimx] See docs/architecture.md ("Plugin derivations").
nvimx-lock: done. commit $S/e2/dot/nvim/nvimx-lock/{plugins.json,flake.nix,flake.lock}
nvimx-lock: note: ...(このときの文言は最終版の 1 つ前の案。最終文言は (d) で確認)
rc=0
$ git status --short
A  nvim/init.lua
?? nvim/nvimx-lock/
```

- 従来方式との一致: `flake.lock` を消して lockDir を `git add` し、**main の(未パッチの)lock app**で
  lock し直す → `flake.lock IDENTICAL` / `plugins.json IDENTICAL`。
- `git add` 後にパッチ済みで再実行 → `note:` 行は 0 件、`git status` は不変。
- lockDir を `git rm -r --cached` で untracked に戻し、パッチ済みで `--update tokyonight.nvim`
  → `nvimx-lock: updating 1 input(s) with nix flake update` → `no plugins updated (all up to date)` →
  rc=0、`flake.lock` は IDENTICAL。同じ状態で main の lock app は §1.1 と同じ error で落ちる。

**(d) 新 check の成立 —— 通った(掲載版そのものをビルドした)。** 検証の手順:

```bash
git -C /home/myuron/ghq/github.com/myuron/nvimx archive HEAD | tar -x -C "$S/v/tree"   # main 74aa086 の素のツリー
# 本ファイルの ```diff ブロックの中身 → plan.diff、§5.2 の ```nix ブロックの中身 → plan.snippet(sed で行範囲を抜くだけ)
cd "$S/v/tree" && git init -q -b main && git add -A && git commit -qm base
git apply ../plan.diff
sed -i "3135r ../plan.snippet" flake.nix && git add -A
nix fmt -- --ci                                          # → formatted 51 files (0 changed)
nix build .#checks.x86_64-linux.lock-app                 # → rc=0
nix eval .#checks.aarch64-darwin.lock-app.drvPath        # → "/nix/store/3difsnk58y0q1m6zdawbzv1xn705i49m-lock-app.drv"
```

つまり §5.1 の diff と §5.2 のスニペットは、**一字も変えずに**入れれば整形も構文もビルドも通る。
3 巡目までの版は、スクラッチパッドの別ファイル(リポジトリ外の式)をビルドして「掲載版と一致」と
していたが、掲載版にだけあったコメントが nix の `''` 文字列を閉じており、逐語で入れると
`error: syntax error, unexpected ')'` で落ちた(4 巡目レビューで判明。§7 R2)。
スニペット内の `''` と `${` は grep で確認し、意図したものだけである: スタブの開閉、スタブ内の
`''${NVIMX_STUB_FAIL:-}`、check 本体の開閉、`fx=${./tests/fixtures/basic-config}`。

ログ抜粋(step 4 / 5 / 7。step 4b のログは §7 R11 に載せた)。**掲載版の check をビルドしてもこのログは出ない**:
掲載版は `nvimx-lock` の stderr をすべてファイルに落とし、assert は素の `[ ... ]` なので、緑でも赤でも
`lock-app>` の行は 1 行も出ない。下の抜粋は、check の末尾に `cat *.log` を足した計装ビルドのもの、
後ろの変異表の「止まった assert」は `export HOME=$TMPDIR` の直後に `set -x` を足した計装ビルドのものである
(どちらも検証用の一時的な改変で、掲載版には入れていない。実装者が同じものを見る手順は §8 手順 5):

```
lock-app> nvimx-lock: pinning with nix flake lock
lock-app> error: stub nix was told to fail
lock-app> [nvimx] warning: plugin "tokyonight.nvim": build is a neovim command (":Foo") and cannot be run at build time
lock-app> [nvimx] these plugins are installed with helptags only, or with some build steps skipped. ...
lock-app> [nvimx] See docs/architecture.md ("Plugin derivations").
lock-app> nvimx-lock: failed (exit 7) -- look for the error above; it may sit above the import report and warnings
...
lock-app> nvimx-lock: extracting spec from /build/nosetup
lock-app> [nvimx] extract failed: config did not call require("lazy").setup(...); nvimx requires a lazy.nvim spec
lock-app> nvimx-lock: failed (exit 1) -- look for the error above; it may sit above the import report and warnings
...
lock-app> nvimx-lock: done. commit /build/repo/nvim/nvimx-lock/{plugins.json,flake.nix,flake.lock}
lock-app> nvimx-lock: note: this lock is not fully tracked by git. A flake only sees git-tracked files, so until you run
lock-app> nvimx-lock: note:   git -C "/build/repo/nvim/nvimx-lock" add plugins.json flake.nix flake.lock
lock-app> nvimx-lock: note: home-manager switch cannot see it and builds the degraded (lazy.nvim-only) neovim instead
```

記録された argv(先行の探索ビルドで確認):
通常 lock = `flake lock path:.`、`--update` = `flake lock path:.` / `flake update --flake path:. lazy-nvim tokyonight-nvim`、
`pin = true` の初回 = `flake lock path:.` ×2、凍結後の `resolvedRef` = `cdc07ac78467a233fd62c493de29a17e0cf2b2b6`。

**最終版の check(4 巡のレビュー反映後)が実際に噛むこと。** 上の抽出ツリーをコピーし、
`nix/lib/lock-app.nix` を 1 箇所ずつ壊して確認した。§5.1 の diff を当てない(main のままの)lock app では
step 1 の `[ 'flake lock' = 'flake lock path:.' ]` で赤になる。
§8 手順 5 の変異 (a)〜(s) を **1 つずつ、すべて掲載版の check に対して**ビルドした
((m) は 3 通りなので計 21 ビルド)。**21 通りとも rc=1(赤)** で、`set -x` のログで止まった assert は次のとおり:

| 変異 | 止まった step と assert |
|---|---|
| (a) `:239` の `"path:."` を消す | step 1 `[ 'flake lock' = 'flake lock path:.' ]` |
| (b) `:251` の `--flake "path:."` を消す | step 2 `diff -u want-argv argv`(`+flake update lazy-nvim tokyonight-nvim`) |
| (c) `:292` の `"path:."` を消す | step 3 `diff -u want-argv argv`(2 行目が `+flake lock`) |
| (d) `exit_code=$?` を `flush_logs` の後に移す | step 4 最終行(失敗行が出ず、最終行が `[nvimx] See docs/architecture.md ...`)。rc は 7 のまま |
| (e) 失敗行を `flush_logs` の前に移す | step 4 最終行(同上。失敗行は warning の上に埋もれる) |
| (f) `if` 形を `[ ... ] && echo` に変える | step 1 の `nvimx-lock` 自体(成功した lock が rc=1 で終わる) |
| (g) 案内の 1 段目を外す | step 1 最終行(git 管理外で案内が出て `done` が最終行でなくなる) |
| (h) 案内の `if` の中に `git add -N` を足す | step 7 `[ "$(git -C repo status --porcelain)" = "?? nvim/" ]`(` A nvim/nvimx-lock/...` になる) |
| (i) 案内を丸ごと消す | step 7 `[ "$(grep -c '^nvimx-lock: note:' untracked.log)" -eq 3 ]`(0 件) |
| (j) 1 段目を終了コード判定にする | step 8 `absent 'nvimx-lock: note:' bare.log` |
| (k) import レポートを失敗行の後に出す | step 4b 最終行(`[nvimx] import: 1 pinned, ...` が最終行) |
| (l) import レポートを `nix` の前にも出す | step 4b `[ "$err_at" -lt "$import_first" ]`(`'[' 7 -lt 3 ']'`) |
| (m) 判定を `-- plugins.json` だけに縮める | step 7 `missing=flake.nix` の `grep -qxF "$note_cmd" ...` |
| (m) 判定を `-- flake.nix` だけに縮める | step 7 `missing=plugins.json` の `grep -qxF "$note_cmd" ...` |
| (m) 判定を `-- flake.lock` だけに縮める | step 7 `missing=plugins.json` の `grep -qxF "$note_cmd" ...` |
| (n) `:292` の `cd "$out" &&` を消す | step 3 `[ "$(sort -u cwd)" = "$here/pinned" ]`(`$'/build\n/build/pinned'`) |
| (o) 失敗行の `echo` の直後に `exit 1` を足す | step 4 `[ "$rc" -eq 7 ]`(`'[' 1 -eq 7 ']'`) |
| (p) 文言の `(exit $exit_code)` を `(exit 1)` に固定する | step 4 最終行(`failed (exit 1)` ≠ `failed (exit 7)`) |
| (q) `cleanup()` の `rm -rf "$sandbox"` を消す | step 1 `no_leftover`(`/build/locktmp/tmp.OeHAWl8gXc` が残る) |
| (r) 案内判定の 2 段目から `> /dev/null 2>&1` を外す | step 7 `absent 'pathspec' untracked.log`(git の `error: pathspec ...` が漏れる) |
| (s) `--update` のとき案内を出さない(`[ "$update_mode" -eq 0 ] &&` を前置) | step 7 `grep -qxF "$note_cmd" untracked-update.log` |
| (参考)(r) の半分: stdout だけ漏らす(`> /dev/null 2>&1` → `2> /dev/null`) | step 7 `[ ! -s tracked.out ]` |

(k)(l) は step 4 を通過して 4b で止まる(import 経路を守っているのは 4b だけ)。

この check が緑のまま通していた変異の履歴: 下書きの `! grep -q` は否定側が全部空振り。1 巡目レビュー前
(partial が 1 状態)は (m) の `flake.nix` だけ。2 巡目レビュー前(step 3 が cwd を見ない)は (n)。
3 巡目レビュー前(失敗がすべて rc=1、sandbox の後始末を見ない)は (o)(p)(q)。
4 巡目レビュー前(判定コマンドの出力と `--update` 時の案内を見ない)は (r)(s)。

**`no_leftover` が誤検知しないことの確認。** 専用の `TMPDIR`(`/build/locktmp`)で全 step を走らせた後の中身は
`nvim.nixbld/`(neovim 自身が `TMPDIR` に作る `nvim.<user>/`。中にランダム名のサブディレクトリ)だけで、
`tmp.*` は 1 つも無かった。lock app の `mktemp -d`(既定テンプレート `tmp.XXXXXXXXXX`)だけが
この名前を作るので、「`TMPDIR` 直下に `tmp.*` が無い」で判定する。「`TMPDIR` が空」で判定すると
`nvim.nixbld/` で必ず誤検知する。専用の `TMPDIR` を切らずにビルドディレクトリ(元の `$TMPDIR` = `/build`)で
見る形は、stdenv や他のツールが同じ場所に `tmp.*` を作らない保証が無いので採らなかった。

未確認: **darwin ではビルドしていない。** `drvPath` の評価は通った(上記)が、評価が保証するのは式が
組めることまでである。`here=$(realpath .)` と専用 `TMPDIR` は darwin の `/tmp` → `/private/tmp` を想定した
手当てだが、linux では `$PWD` と同じ値なので、効いていることは linux のビルドでは確かめられない。
darwin の CI(`ci-darwin.yml`)が最初の実証になる。

**(e) EXIT trap の終了コード(bash 5.3.15、`set -euo pipefail`)。**

```console
T1 trap が if 形、本体が exit 3            → "failed 3" を出して rc=3
T2 trap が if 形、本体が成功                → rc=0
T3 trap が `[ "$ec" -ne 0 ] && echo x`、成功 → rc=1   ← 成功が失敗に化ける
T4 本体が (cd /tmp && sh -c "exit 7")       → trap 内 ec=7、rc=7
T5 trap 内で false(元は exit 3)            → 以降は実行されず rc=1
T6 trap 内で f; ec=$?(元は exit 3)         → ec=0、rc=3   ← 1 文目で取らないと失う
T7 本体が kill -INT $$                       → trap 内 ec=0、rc=130
T8 trap 内で exit "$ec"                      → rc=3(動くが、exit しなくても同じなので書かない)
```

**(f) git の判定コマンド。**

```console
$ (cd bare.git && git rev-parse --is-inside-work-tree; echo "rc=$?")
false
rc=0
$ (cd plain && git rev-parse --is-inside-work-tree; echo "rc=$?")       # git 管理外
fatal: not a git repository (or any of the parent directories): .git
rc=128
$ (cd dot/.git && git rev-parse --is-inside-work-tree; echo "rc=$?")
false
rc=0
$ git -C nvim/nvimx-lock ls-files --error-unmatch -- plugins.json flake.nix flake.lock; echo "rc=$?"
error: pathspec 'plugins.json' did not match any file(s) known to git
Did you forget to 'git add'?
flake.lock
flake.nix
rc=1
```

### 6.3 既存 checks への影響

- stderr を見ている既存 step(`resolve-update` 10、`resolve-import-lazy-lock` 14 / 15)は trap 設定前に
  抜けるので無影響。`nix flake check` 全体で確認する(§8 手順 3)。
- `hm-module*` は lock app の store path が変わるので再ビルドになるが、中身の assert は無関係。

### 6.4 手動検証(ネットワーク必須。check では不可能な部分。PR 本文に結果を貼る)

スタブは本物の nix の挙動を証明しないので、実装ツリーの lock app で (c) をやり直す:

1. 一時ディレクトリで `git init`、`nvim/init.lua`(`tests/fixtures/basic-config/init.lua` 相当)だけ `git add`。
2. `nix run <repo>#lock -- --config ./nvim --out ./nvim/nvimx-lock` → rc=0、`flake.lock` が生成され、
   末尾に案内 3 行。`git status --short` で lockDir が `??` のまま(index 不変)。
3. `git add nvim/nvimx-lock` 後に再実行 → 案内が出ない。`git diff --cached --stat` に変化なし。
4. `flake.lock` を退避して削除 → **main の lock app を明示的に指定して** lock し直す(lockDir は `git add` 済みの状態で)→ 退避分と `cmp` で一致。
   `nix run "git+file:///home/myuron/ghq/github.com/myuron/nvimx?ref=main#lock" -- --config ./nvim --out ./nvim/nvimx-lock`
   (または `nix run github:myuron/nvimx#lock -- ...`)。作業ツリーの `.#lock` や `git stash` に頼らないこと:
   実装をコミットした後ではどちらもパッチ済みの lock app になり、比較がパッチ済み同士で必ず一致してしまう。
5. lockDir を `git rm -r --cached` して `--update tokyonight.nvim` → rc=0。
6. `lazy-lock.json` を置いて lockDir を消し、issue の再現コマンドそのもの
   (`--import-lazy-lock`)→ rc=0、import レポートの後に `done` と案内。
7. 失敗の見え方: `exit 7` するだけの偽の `nix` を PATH の先頭に置いて lock app を実行する。
   **他の手順と同じ `nix run <repo>#lock -- ...` の形で打ってはいけない**: 偽の `nix` が `nix run` 自体を
   食い、lock app は 1 行も実行されないのに rc=7 だけ合ってしまう(実測: 出力は偽 `nix` の 1 行だけで rc=7)。
   lock app の実体を先に取り出し、それを直接呼ぶ(`packages.<system>.lock` は無いので
   `nix build .#lock` も使えない。`lib.x86_64-linux.lockApp` と `apps.x86_64-linux.lock.program` が
   同じ store path を指すことは main で確認済み):

   ```bash
   fake=$(mktemp -d) && printf '#!/bin/sh\necho "error: fake nix" >&2\nexit 7\n' > "$fake/nix" && chmod +x "$fake/nix"
   app=$(nix eval --raw /home/myuron/ghq/github.com/myuron/nvimx#apps.x86_64-linux.lock.program)
   nix build --no-link /home/myuron/ghq/github.com/myuron/nvimx#lib.x86_64-linux.lockApp   # 実体化
   PATH="$fake:$PATH" "$app" --config ./nvim --out ./nvim/nvimx-lock; echo "rc=$?"
   ```

   **rc=7 だけで合格にしないこと。** `nvimx-lock: pinning with nix flake lock` → `error: fake nix` と進んだうえで、
   最終行が `nvimx-lock: failed (exit 7) -- ...` であることを見る(main の lock app で同じコマンドを打つと、
   rc=7 だが最終行は `error: fake nix` のままで失敗行は出ない —— それが修正前の姿である)。
   同じことを `--import-lazy-lock` 付きでも 1 回 → import レポートが 2 回出て(§7 R11。既存挙動)、
   その後の最終行が失敗行。

## 7. リスク / 未決事項

### R1: 計画時に確認した前提と、そこから修正した点

方針 5 点は変えていない。裏取りの結果:

| 方針の前提にあった記述 | 結果 |
|---|---|
| `lock-app.nix` の行番号(239 / 251 / 292 / 160 / 310) | **すべて正しい** |
| 終了コードは握りつぶされていない / エラーが `flush_logs` の出力に埋もれているだけ | **正しい**(§1.1 で rc=1 と出力順を実測) |
| `path:` に変えても `flake.lock` は変わらない | **正しい**(§6.2 (a)(c) で byte-identical) |
| 引数エラー(exit 2)は trap 設定前に抜ける | **正しい**(`:164` より前) |
| 案内の判定は `git -C "$out" ls-files --error-unmatch -- ...` が失敗すること | **不足。** git 管理外でも rc=128 で「失敗」になる。`rev-parse --is-inside-work-tree` の**出力**が `true` であることを先に見る 2 段判定が必要(bare / `.git` 内では `false` を rc=0 で返すので終了コードでも判定できない)。§3.3 |
| 失敗行 `nvimx-lock: failed (exit N); the error is above the report`「相当」 | 文言を確定: `nvimx-lock: failed (exit N) -- look for the error above; it may sit above the import report and warnings`。「report の上」が真なのは `nix` が落ちたときだけなので、全失敗経路で真になる言い方にした(§3.2) |
| 案内は「`git add <lockDir>`」 | コマンドを `git -C "<out>" add plugins.json flake.nix flake.lock` に確定(cwd と submodule に依存しない)。README 側は従来どおり `git add nvim/nvimx-lock` |
| 「extract / resolve 段がサンドボックスで通らない場合は部分再現に切り替える」 | **切り替え不要。** end-to-end が成立した(§6.2 (d))。スタブが `flake.lock` を置く手当てと、`:292` を踏むための `pin = true` 設定は当初の案に無かった追加 |
| `architecture.md` の 90 / 156 / 555 行、517 行、Edge cases 522–528 行 | 90 / 156 / 555 / 517 は**正しい**。表は `:524-539`、該当行は `:528`。加えて `:287` / `:288` / `:470` も `nix flake lock` / `update` / `git add` に言及しており更新対象(§5.4) |
| 「lock app が working-tree の差分を検出して警告する」は実装に存在しない | **正しい。** さらに同じ行の前半「missed during extraction」も誤りで、`README.md:74-75` に同じ誤りがある(§1.5)。当初の前提はここまで指摘していなかった |
| lock が成功しても `git add` しないと `hasLock` が false で縮退する | **ほぼ正しい。** `hasLock` が見るのは `plugins.json` と `flake.lock` だけなので、`flake.nix` だけが untracked なら縮退しない(R4) |
| README の更新は Usage 3 / Migrating 4 | これに加えて Usage 1(`:74-75`)の訂正を入れた(**当初挙げていた範囲を超える。この PR に含めると決定済み。R8**)。その後のレビューで Updating の段落(`:109-112`)/ Migrating 1(`:122` 付近)/ Migrating 3(`:136` 付近)も対象に加えた(§5.3 の 4〜6) |

### R2: check が「緑のまま何も守っていない」可能性、および掲載版と検証版の乖離

この check は、計画の段階で緑のまま変異を通していたことが 5 回ある(下書きの `! grep -q`、
1 巡目の (m)、2 巡目の (n)、3 巡目の (o)(p)(q)、4 巡目の (r)(s)。経緯は §6.2 (d))。どれも
「緑であること」しか確かめていなかった箇所で起きた。

もう 1 つ、性質の違う事故があった。**3 巡目までは、ビルドして確かめていたのがスクラッチパッドの
別ファイルで、本計画に掲載したスニペットそのものではなかった。** 掲載版にだけコメントが足されており、
そのコメントが nix の `''` 文字列を閉じてしまって、逐語で `flake.nix` に入れると構文エラーになった
(4 巡目で判明)。「ビルドしたものと掲載版はコメント以外一致」という確認では、コメントが壊す事故は防げない。

現在の状態:

- §5.1 の diff と §5.2 のスニペットは、**本ファイルから機械的に抽出したもの**を `git archive HEAD` の
  コピーに適用・挿入して検証した(§6.2 (d))。`nix fmt -- --ci` は 0 changed、
  `nix build .#checks.x86_64-linux.lock-app` は緑、
  `nix eval .#checks.aarch64-darwin.lock-app.drvPath` は評価できた。
- その同じツリーに対して §8 手順 5 の (a)〜(s) を全部(21 ビルド)通し、すべて赤になることを確認した
  (§6.2 (d) の表。止まった assert も記録した)。

残る留保:

- 実装者が §5.1 / §5.2 を書き写すときにコメントや整形を変えれば、同じ種類の事故はまた起きうる。
  **実装ツリーで §8 の手順 1〜5 を省略せずに通すこと。**
- (a)〜(s) は「これまでに思いついた / 指摘された壊し方」の一覧であり、網羅の証明ではない。
- **未固定の変異が 1 つ分かっている**(5 巡目レビューで判明): 既存の `:295` の `flush_logs` 呼び出しを消すと、
  成功時に warning が trap 経由で `done` / 案内の後ろへ回るが、check は緑のままである。今回変更しない行
  なので check は変えない。固めるなら step 3 に「`pinned.log` の最終行が `done` である」assert を足す
  (`pincfg` は `build = ":Foo"` で warning を出すので、step 3 がちょうどその状況になっている)。
- (r) は `absent 'pathspec' untracked.log` で止まるので、その後ろの `[ ! -s tracked.out ]` は (r) では
  踏まれない。こちらは stdout だけを漏らす変異(`> /dev/null 2>&1` → `2> /dev/null`)で単独に赤くなることを
  別途確認した(§6.2 (d))。§8 手順 5 の一覧には入れていない((r) の半分なので)。

### R3: 本物の nix に対する保証は手動検証だけ

スタブは argv を固定するが、`path:.` を本物の nix が受け付けることは保証しない。実測したのは
**nix 2.34.8(x86_64-linux)のみ**。未検証: Nix 2.19〜2.33、Lix、Determinate Nix、aarch64-darwin。
相対 `path:` 参照と `nix flake update --flake` はどちらも 2.19 以降の文書化された構文だが、
古いバージョンで `path:.` が lock file を書き戻せるかは確かめていない。

### R4: 案内の文言が正確でないケース

- `flake.nix` だけが untracked(`plugins.json` / `flake.lock` は tracked)の場合、`hasLock` は true で
  縮退しないが、案内は「cannot see it」と言う。3 ファイルを揃えて commit させるのが目的なので許容。
  **→ PR レビュー後に修正した(R13)。この場合は縮退を言わない別の案内を出す。**
- flake を使わない home-manager(channels)では untracked でも見える。案内は誤警報になるが無害。
- lockDir が `.gitignore` 対象だと、案内のコマンドは `-f` なしでは通らない。そこまでは面倒を見ない。
- `GIT_DIR` を export したシェルから実行すると、lockDir が git 管理外でも 1 段目が `true`、
  2 段目が rc=1 になり、案内が誤って出る(§3.3 の表、実測)。害は誤案内だけで、lock 自体と
  終了コードには影響しない。`GIT_DIR` を unset して判定する手もあるが、`resolve.lua` の
  `git ls-remote` は同じ環境をそのまま使っており、ここだけ環境をいじる理由が薄いので何もしない。

### R5: trap 内の失敗とシグナル

- stderr が閉じている等で `flush_logs` の `cat` が失敗すると、trap が打ち切られ(`rm -rf` も失敗行も
  実行されない)終了コードが化ける(§6.2 (e) T5)。**今日も同じ**であり、今回は直さない。
- Ctrl-C(SIGINT)では trap 内の `$?` が 0 になりうる(T7)。その場合失敗行は出ない。
  ユーザー自身が止めたので許容。終了コード(130)は変わらない。
  `$?` が 130 のまま trap に入った場合の最終行は、PR レビュー後に専用の文言へ変えた(R13)。

### R6: untracked な lua の検出は実装しない(別 issue の候補)

**決定済み: 実装しない。** §5.4 のとおり `architecture.md:528` と `README.md:74-75` は実態に合わせて
直すだけにする。「`configDir` 配下に untracked なファイルがあると警告する」機能は #71 の範囲外で、
別 issue の候補としてここに残す(issue は起こしていない)。

### R7: lock 失敗時に `plugins.json` / `flake.nix` が先に書き換わっている

`nix` が落ちた時点で `plugins.json` と `flake.nix` は新しく、`flake.lock` は古い(初回なら無い)。
§1.1 の `ls` と check step 4 の `[ ! -e failed/flake.lock ]` がこの状態を示す。今日からの挙動で、
再実行すれば収束する。#71 の原因(初回に必ず落ちる)が消えるので踏む頻度は下がる。今回は直さない。

### R8: README Usage 1 の訂正はこの PR に含める(決定済み)

方針 5 は「実態に合わせて更新する」で、当初挙げていた README の箇所は Usage 3 / Migrating 4 だけだった。
`README.md:74-75` は `architecture.md:528` と同じ誤りであり、`:528` だけを直すと
**同じ PR の中で 2 つのドキュメントが矛盾する**。計画レビューで、§5.3 の 1 をこの PR に含めると決めた。

### R9: `path:` は lockDir 全体を参照する

`path:.` は `$out` ディレクトリ全体を flake のソースとして扱う。lockDir は 3 ファイルしか無い想定なので
問題にならないが、`--out .` のように大きなディレクトリを指すと、その全体がコピー対象になりうる
(未計測)。README は一貫して専用ディレクトリ(`nvim/nvimx-lock`)を案内している。

### R10: check の実行時間

新 check は headless nvim の抽出を含む `nvimx-lock` を 13 回走らせる(step 7 だけで 6 回。ほかに usage で即終了する 1 回)。
計測はしていない(体感では既存の `resolve-*` check と同程度)。許容とする。step 7 の 3 状態は
「判定を 1 ファイルに縮める」変異を 3 通りとも赤にするために必要なので、削るなら他の step から。

### R11: `--import-lazy-lock` で `nix` が落ちると import レポートが 2 回出る(既存挙動・別件)

main からある挙動で、本件では直さない。原因は 2 箇所の組み合わせである:

- `lock-app.nix:230-232` が pass 1 の直後に `resolve.log` から `^\[nvimx\] import: ` の行を
  `import.log` に**コピー**する(`resolve.log` 側には残る)。
- `flush_logs`(`:148-159`)は `import.log` → `resolve.log` の順に両方を出す。

成功時は収束パス(`:280-282`)が同じ `resolve.log` を `2>` で開き直して truncate するので、import 行は
`import.log` にしか残らず 1 回で済む。**1 回目の `nix`(`:239`)が落ちた時点ではまだ truncate されて
いない**ので、同じ行が両方のファイルにあり 2 回出る。§6.2 (d) の計装ビルド(check の末尾に `cat failed-import.log` を
足したもの。掲載版はログを出さない)で step 4b が出したログ:

```
lock-app> error: stub nix was told to fail
lock-app> [nvimx] import: pinned tokyonight.nvim to 123412341234
lock-app> [nvimx] import: 1 pinned, 0 skipped, 0 ignored, 0 not in lazy-lock.json
lock-app> [nvimx] warning: plugin "tokyonight.nvim": build is a neovim command (":Foo") and cannot be run at build time
lock-app> [nvimx] import: pinned tokyonight.nvim to 123412341234
lock-app> [nvimx] import: 1 pinned, 0 skipped, 0 ignored, 0 not in lazy-lock.json
lock-app> [nvimx] these plugins are installed with helptags only, ...
lock-app> nvimx-lock: failed (exit 7) -- look for the error above; it may sit above the import report and warnings
```

issue #71 の再現コマンドはまさにこの経路だが、#71 を直すと初回の `nix` は落ちなくなるので、
踏むのは `nix` が別の理由(ネットワーク、存在しない rev)で落ちたときだけになる。

直し方の見当(別 PR): `flush_logs` で `import.log` が非空のときは、`resolve.log` を `cat` する代わりに
`grep -v '^\[nvimx\] import: ' "$sandbox/resolve.log" >&2 || true` で import 行を除いて出す
(`grep -v` は全行が除かれると rc=1 を返すので `|| true` が要る。`pkgs.gnugrep` は `runtimeInputs` に既にある)。
**check step 4b は import 行の回数に依存しないので、この修正を入れても壊れない。**

### R12: `path:.` にすると nix が `flake.lock` を intent-to-add しなくなる(既存挙動からの変化)

参照なしの `nix flake lock` は、`flake.nix` が tracked な git flake に lock file を書くとき、
`flake.lock` を自分で `git add --intent-to-add` する。`path:` flake は git を一切見ないので、これが起きない。
スクラッチの git リポジトリで `nvim/lk/flake.nix` だけを `git add` して実測した:

```console
$ (cd nvim/lk && nix flake lock); git status --short            # 現状
 A nvim/lk/flake.lock
A  nvim/lk/flake.nix
$ (cd nvim/lk && nix flake lock "path:."); git status --short   # 変更後(flake.lock を消してから)
A  nvim/lk/flake.nix
?? nvim/lk/flake.lock
```

結果が変わるのは「`flake.nix` は tracked だが `flake.lock` はまだ無い」状態で lock したときである:

- #71 の既知の回避手順(失敗後に `flake.nix` だけ `git add` して再実行)。今日は `flake.lock` が
  intent-to-add され、`plugins.json` さえ add してあれば `hasLock` が true になる。変更後は `flake.lock` が
  untracked のまま残り、`hasLock` は false(縮退)になる。ただしこの回避手順自体が不要になる。
- lockDir は追跡済みだが `flake.lock` だけ新規、という状態(lock 失敗後の再実行など)。

影響は小さいと判断する: 初回 lock 以外では 3 ファイルとも既に tracked なのが普通で、tracked な
`flake.lock` の書き換えにはどちらの方式でも `git add` は関係しない。そして新しい状態は黙って縮退しない ——
案内は 3 ファイルを個別に見ており、`flake.lock` だけが index に無い状態は check step 7 の
`missing=flake.lock` が固定している。**案内の判定から `flake.lock` を外してはいけない**(「`flake.nix` が
tracked なら nix が面倒を見る」という前提を置くと縮退を見逃す)理由がこれである(§5.1 のコメント 4 に残す)。
`flake.nix` 自体はビルドに読まれない(`hasLock` は `plugins.json` と `flake.lock` しか見ない)ので、
縮退を見逃さないだけなら `{plugins.json, flake.lock}` の 2 つで足りる。`flake.nix` を並べるのは、
3 ファイルを一緒にコミットさせるためである。

「ユーザーの index に触れない」という方針(§2 の 3)から見れば、nix が代わりに index を書き換えていた
副作用が消えるのは一貫した方向の変化でもある。README / `docs/architecture.md` /
`templates/default/README.md` に「nix が `flake.lock` を自動で add する」ことに依拠した記述は無く
(`grep -n 'intent\|automatically' README.md docs/architecture.md templates/default/README.md` に出るのは
`env` / `nixpkgsFallback` / `--update` / build / `devPlugins` に関する無関係な `automatically` だけ)、
§5.3〜§5.5 の文言はいずれも「lock の後に `git add nvim/nvimx-lock`」と書いているので、変更不要。

### R13: PR レビュー後に加えた修正(§3 / §5 / §6 の掲載コードはこの修正より前の姿)

PR #80 のコードレビューで出た指摘のうち、今回追加したメッセージとコメントの誤り 3 件を同じ PR で直した。
**§3.2 / §3.3 / §5.1 / §5.2 / §6.2 に載せたコードと出力は、この修正を入れる前のものである**
(§5.2 と `flake.nix` のバイト一致も、この修正の前までの話)。差分は次の 3 点だけ。

| 対象 | 修正前 | 修正後 |
|---|---|---|
| `flake.nix` だけが untracked のときの案内(R4 の 1 点目) | 3 行の案内が「縮退する」と言う。`hasLock` は `flake.nix` を見ないので誤り | 縮退を言う 3 行は `plugins.json` / `flake.lock` のどちらかが untracked のときだけ。`flake.nix` だけなら `flake.nix is not tracked by git. The build does not read it, but it belongs with plugins.json and flake.lock:` と `git -C "<out>" add flake.nix` の 2 行 |
| 案内の上のコメント | home-manager が「silently」縮退ビルドする、と書いていた | module は `hasLock` が false のとき warning を出す(`nix/home-manager/default.nix`)ので「silently」を削り、「switch 時にしか出ず原因も言わないので lock の時点で知らせる」に直した |
| 終了コードが 128 を超えるときの最終行(R5 の 2 点目) | `failed (exit 130) -- look for the error above; ...`。探すべきエラーは無い | `nvimx-lock: stopped by a signal (exit N)`。終了コードはそのまま |

check `lock-app` には step 4c(スタブ `nix` が 130 で終わる)を足し、step 7 の 1 ファイルずつのループを
「`flake.nix` だけ → 2 行の案内で `degraded` を含まない / 他の 2 つ → 3 行の案内」に分けた。
変異 3 種(128 の分岐を無効化 / 縮退側の判定に `flake.nix` を戻す / `flake.nix` 用の案内を消す)は
いずれも check が赤になることを実測した。

同じレビューで出た残りの指摘(`.gitignore` 対象の lockDir、`update-summary.lua` 失敗時に案内が出ない、
trap 内の EPIPE、`path:.` が lockDir 全体をコピーする、スタブ `nix` の粒度、import レポートの 2 重出力)は
R4 / R5 / R9 / R2 / R11 に既に書いた制限と同じか、その延長であり、別 issue に回す。

## 8. 検証手順(実装完了時に必ず全部通す)

**§6.2 の実測はスクラッチパッドのコピーで行ったものであり、実装ツリーの上で実際に走らせた結果を
もって完了とする。**

```bash
cd /home/myuron/ghq/github.com/myuron/nvimx

# 1. 整形 + lint(CI と同じ)。lua は変えていないので実質 nixfmt。
nix fmt -- --ci

# 2. 新 check だけを先に回す(速いループ用)
nix build .#checks.x86_64-linux.lock-app -L

# 3. フルチェック(CI と同じ)。resolve-update / resolve-import-lazy-lock の stderr assert が
#    無影響であること、hm-module* が再ビルドで通ることもここで確認される。
nix flake check

# 4. darwin。linux の flake check は darwin を omit する(CLAUDE.md)。
nix eval .#checks.aarch64-darwin.lock-app.drvPath

# 5. mutation。lock-app.nix を 1 箇所ずつ壊して手順 2 を回し、赤になることを確認して戻す。
#    (m) は 3 通りあるので計 21 回。止まる step は計画時に最終版の check で実測したもの(§6.2 (d))。
#      (a) :239 の "path:." を消す                          → step 1(argv)
#      (b) :251 の --flake "path:." を消す                  → step 2(argv)
#      (c) :292 の "path:." を消す                          → step 3(argv)
#      (d) cleanup の exit_code=$? を flush_logs の後に移す  → step 4(失敗行が出ない。rc は 7 のまま)
#      (e) 失敗行の if ブロックを flush_logs の前に移す      → step 4(最終行でなくなる)
#      (f) if 形を `[ ... ] && echo` に変える               → step 1(成功した lock が rc=1 になる)
#      (g) 案内の 1 段目を外す(ls-files だけにする)         → step 1(git 管理外で案内が出る)
#      (h) 案内の if の中に git add -N を足す                → step 7(status が変わる)
#      (i) 案内を丸ごと消す                                  → step 7(note が 0 行)
#      (j) 1 段目を終了コード判定にする
#          (`if git ... rev-parse ... > /dev/null 2>&1 && ! git ... ls-files`)→ step 8(bare で案内が出る)
#      (k) import レポートを失敗行の後に出す。flush_logs から import.log の cat を外し、cleanup() を
#          「flush_logs → 失敗行の if → import.log の cat → rm -rf "$sandbox"」の順に並べ替える
#          (rm -rf は消さずに末尾へ動かす)                 → step 4b(最終行が import 行になる)
#      (l) import レポートを nix の前にも出す(:231 の grep の直後に cat "$sandbox/import.log" >&2)
#                                                            → step 4b(import 行が error より前に来る)
#      (m) 案内の判定を 3 ファイルのうち 1 つだけに縮める。3 通りとも通すこと:
#            -- plugins.json だけ → step 7(missing=flake.nix)
#            -- flake.nix だけ    → step 7(missing=plugins.json)
#            -- flake.lock だけ   → step 7(missing=plugins.json)
#      (n) :292 の `cd "$out" &&` を消す(3 箇所目だけ)     → step 3(cwd が 2 行になる)
#      (o) 失敗行の echo の直後に exit 1 を足す              → step 4(rc が 7 でなく 1)
#      (p) 文言の (exit $exit_code) を (exit 1) に固定する   → step 4(最終行が failed (exit 7) でない)
#      (q) cleanup の rm -rf "$sandbox" を消す               → step 1(no_leftover: TMPDIR に tmp.* が残る)
#      (r) 案内判定の 2 段目(ls-files)から `> /dev/null 2>&1` を外す → step 7(untracked.log に pathspec が漏れる)
#      (s) --update のとき案内を出さない(if の先頭に `[ "$update_mode" -eq 0 ] &&`)→ step 7(untracked-update.log)
#    (k) で rm -rf を消したり、元の位置(失敗行の if より前)に残したりしないこと。消すと (q) と同じく
#    step 1 の no_leftover で先に止まり、元の位置に残すと sandbox ごと import.log が消えた後で cat する
#    ことになって何も出ず、どちらも 4b を試したことにならない。
#    (k)(l) は step 4 を通過して 4b で止まる —— step 4b を消すと緑になる
#    = import 経路を守っているのは 4b だけである。
#    緑のまま通る mutation があれば、その assert は空振りしている(R2)。
#
#    赤になったことだけでなく「どこで」赤になったかを必ず見ること。掲載版の check は nvimx-lock の stderr を
#    すべてファイルに落とし、assert は素の [ ... ] なので、落ちてもビルドログに lock-app> の行が 1 行も出ず、
#    rc=1 しか見えない。そのままでは次の 2 つを取り違える:
#      (1) どの step の assert で止まったか。mutation を回す間だけ、flake.nix の lock-app check 本体の
#          `export HOME=$TMPDIR` の直後に `set -x` を 1 行入れ(他の check にも同じ行があるので、lock-app の
#          ものだけ)、`nix build .#checks.x86_64-linux.lock-app -L` のトレース末尾(`+ exitHandler` の直前)の
#          assert が上の一覧の step であることを確かめる。
#      (2) 落ちた derivation が lock-app であること。変異の書き方によっては check の assert ではなく
#          nvimx-lock.drv 自体が shellcheck(例: 変数を使わなくなって SC2034)や構文エラーで落ちる。
#          それは「check が噛んだ」ではない。エラーの `Cannot build ...-lock-app.drv` /
#          `...-nvimx-lock.drv` のどちらかを見て、後者なら変異を書き直す。
#    mutation を始める前に、実装済みの状態を控えておく(未コミットでもコミット済みでも同じ手順で比べられる):
#      git diff HEAD > "${TMPDIR:-/tmp}/before-mutation.diff"
#    全部終わったら set -x と変異を必ず戻し、戻したことを確認する:
#      git diff HEAD | cmp - "${TMPDIR:-/tmp}/before-mutation.diff"   # → 一致(mutation / set -x の残りが無い)
#      nix fmt -- --ci                                        # → 0 changed
#      nix build .#checks.x86_64-linux.lock-app               # → 緑(check が掲載版に戻っている)
#    計画時の 21 ビルドは、すべて lock-app のトレースが `+ exitHandler` まで出ていること(= 落ちたのが
#    lock-app.drv であること)をログで確認してある。

# 6. 手動検証(オンライン)。§6.4 の 1〜7 を実装ツリーの lock app で通し、出力を PR 本文に貼る。
#    §6.4 手順 7(偽の nix で失敗させる)だけは nix run の形で打ってはいけない。§6.4 に書いた、
#    lock app の実体を直接呼ぶコマンドを使うこと。
#    使い捨て git リポジトリに cd してから、実装ツリーの lock app を絶対パスで指す(このブロック冒頭の
#    cd のままでは ./nvim が無い)。中心はこの形:
scratch=$(mktemp -d) && cd "$scratch" && git init -q -b main dot && cd dot && mkdir nvim
cp /home/myuron/ghq/github.com/myuron/nvimx/tests/fixtures/basic-config/init.lua nvim/ && git add nvim/init.lua
nix run /home/myuron/ghq/github.com/myuron/nvimx#lock -- --config ./nvim --out ./nvim/nvimx-lock
#    (--update / --import-lazy-lock も同じ場所から 1 回ずつ。main との比較は §6.4 手順 4 の ?ref=main の形で)
cd /home/myuron/ghq/github.com/myuron/nvimx

# 7. スモーク。lock app の変更は demo に届かない(makeEnv は fixture の lock を読むだけ)が、
#    承認済みの検証項目なので回す。:Lazy が全プラグインを local と表示すること。
nix build .#demo && ./result/bin/nvim

# 8. ドキュメントの整合
grep -n 'nix flake lock\|nix flake update' docs/architecture.md README.md templates/default/README.md
grep -c "resolve-import-lazy-lock, lock-app, resolve-build-warnings" docs/architecture.md   # → 1(checks 一覧)
grep -c "checks\.lock-app" docs/architecture.md   # → 1(Edge cases の新しい行)
#   素の `lock-app` で数えてはいけない: Repository layout の `lock-app.nix`(:494)が元から 1 件ヒットする。
grep -n 'detects working-tree' docs/architecture.md   # → 0 件
grep -n "skipped during extraction" README.md         # → 0 件
```

**CLAUDE.md の Commands のうち、本件で回さないものと理由:**

- `nix fmt -- --clear-cache` —— `stylua.toml` / `.luacheckrc` を触らないので不要。
- `nix run .#skills-install` —— `agent-skills` input に変更なし。`.claude/skills/` も触らない。
