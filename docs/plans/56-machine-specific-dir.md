# #56 対応計画: `localPlugins` にマシン固有の `dir` を記録するのをやめる

対象 issue: [#56 fix(lock): stop recording a machine-specific dir in localPlugins](https://github.com/myuron/nvimx/issues/56)

作業ツリー: `/home/myuron/ghq/github.com/myuron/nvimx`(`main` = `e28d713`、**#47 のマージ直後**、その 1 つ前が #49)。
本計画の実測出力はすべてこのツリーで採った。lazy.nvim 側の `file:line` は `flake.lock` が pin している seed
(`lazy-nvim`、rev `306a055` → `/nix/store/d9jq3s81p4i9q6g8gaa6f2pn51p8za9l-source`)の実ファイルからの引用である。

**nvimx 自身のファイルは行番号で参照しない。** 本件は `lua/nvimx/resolve.lua` / `flake.nix` / `nix/lib/make-env.nix` /
`docs/architecture.md` / `README.md` / `tests/fixtures/**` / `tests/dev-path-test.lua` を編集するので、
計画が書いた行番号は計画自身の PR で動く。`6b13953 fix(lock): stop the import check from citing line numbers it
invalidates` の教訓に従い、シンボル・アンカー(関数名 / check 名 / コメントの一節 / JSON のキー)で位置を指す。

§3 の設計判断は、`lua/nvimx/` を scratch にコピーして実際にパッチを当てたプロトタイプと、
lazy の `LazyFragments` に降りる probe スクリプトで全件実測している。
以下の `console` ブロックはすべてその出力そのものであり、手で書いたものは 1 行も無い
(サンドボックスの絶対パスだけ `<HOME>` / `<DATA>` / `<ROOT>` に置換してある)。

---

## 1. 背景 / 現状

### 1.1 実測 —— 他人の home ディレクトリが `plugins.json` に入る

#47 が新設した `tests/fixtures/local-dir-config` を、今日の extract + resolve に通した実測。
`localPlugins` はこうなる:
```console
$ nvim -l resolve.lua raw-spec.json out.json ; echo rc=$?
rc=0
$ jq -c .localPlugins out.json
{"bare.nvim":{"dir":"<HOME>/projects/bare.nvim"},
 "dirabs.nvim":{"dir":"/nvimx-fixture/dirabs"},
 "dirnoname":{"dir":"/nvimx-fixture/dirnoname"},
 "dirrel.nvim":{"dir":"nvimx-fixture/dirrel"},
 "dirtilde.nvim":{"dir":"<HOME>/nvimx-fixture/dirtilde"},
 "sibling.nvim":{"dir":"<DATA>/nvim/lazy-sibling/sibling.nvim"}}
```

6 件のうち **3 件がそのマシン固有**である —— `bare.nvim` と `dirtilde.nvim` は extract したマシンの `$HOME`、
`sibling.nvim` は lock app が使う**使い捨て XDG サンドボックス**のパスである。
`plugins.json` はユーザーが git にコミットするファイルなので、これはそのまま dotfiles リポジトリに入って
チームメイトのマシンに配られる。

`sibling.nvim` の行は issue 本文の表に無い 4 つ目の形である。issue は `dev = true` 単独 / `dir` 絶対 / `dir` が `~` の
3 通りを挙げているが、**`dir` が `stdpath("data")` などから組み立てられていれば、`$HOME` ですらない
lock 実行時のサンドボックスパスが入る**。issue の分類より実際の被害は広い(§1.5)。

### 1.2 なぜそうなるか —— 3 段の連鎖

**(1) `extract.lua` の `safe_opts` に `dev` キーが無い。** ここは意図的で、
*"Do not add `defaults` here: `defaults.version` is the user's intent and must reach Config.options unmodified"*
と同じ理由でユーザーの opts をできるだけそのまま `Config.options` に届ける設計になっている。
結果として **lazy 自身の `dev` サブツリー全体(`path` / `patterns` / `fallback`)が抽出時に生きている**。

**(2) lazy が `dir` を埋める。`~` を展開しているコードは 1 箇所ではない。**
**ここは「例を 3 つ挙げる」ではなく「代入箇所を全部数える」で押さえる**
—— そうしないと網羅性を主張できず、実際 2 版・3 版とも取りこぼした(§5.6 の該当行)。
**そして数え上げは seed の `lua/` 全体でやる。1 ファイルに閉じると、それは全数え上げではない**
(4 版がまさにそれをやって `meta.lua` の外の 2 箇所を落とした)。

`grep -rn '\.dir *=' <seed>/lua/ | grep -v '=='` と `grep -rn 'dev_dir *=' <seed>/lua/` の実出力 —— **8 行で全部**:

```console
lua/lazy/core/plugin.lua:341:    lazy.dir = Config.me
lua/lazy/pkg/packspec.lua:41:    p.dir = p.dir or plugin.dir
lua/lazy/core/meta.lua:215:  plugin.dir = super.dir
lua/lazy/core/meta.lua:217:    plugin.dir = Util.norm(plugin.dir)
lua/lazy/core/meta.lua:219:    plugin.dir = Util.norm("/dev/null/" .. plugin.name)
lua/lazy/core/meta.lua:233:        plugin.dir = dev_dir
lua/lazy/core/meta.lua:238:    plugin.dir = plugin.dir or Config.options.root .. "/" .. plugin.name
lua/lazy/core/meta.lua:230:      local dev_dir = type(Config.options.dev.path) == "string" and ...
```

対応づけ: `:215` は raw の受け取り、`:217` が **(A)**、`:219` が **(D) virtual**、
`:238` が **(E) 受け皿**。**`:233` の `plugin.dir = dev_dir` は `:230-231` が作った値をそのまま入れているだけ**なので、
値の出所としては **(B)(文字列形)/ (C)(関数形)** に含める —— 経路としては 2 行で 1 つである。
残る `plugin.lua:341` と `packspec.lua:41` は下のとおり抽出経路に現れない。

**`meta.lua` の外の 2 つは、どちらも extract が通らない経路にある。**

- **`plugin.lua:341`(`lazy.dir = Config.me`)は `M.load()`(`:322`)の中**である。
  `extract.lua` は `Config.setup(...)` と `Plugin.Spec.new(spec, { pkg = false })` を**直接**呼ぶだけで、
  `Plugin.load()` を呼ばない —— `M.load()` は本物の `lazy.setup` の経路にしか無い。
  **これは #47 が `_.is_local` について確認したのとまったく同じ境界**である
  (`extract.lua` の `local_dir` の docstring が *"lazy sets it in update_state(), which only the real
  lazy.setup runs, never Plugin.Spec.new"* と書いているのがそれ)。
  `tests/dev-path-test.lua` がこの行(`plugin.lua:333` / `:338-341`)を引いているのは
  **runtime の話**(本物の `lazy.setup` が走る側)であり、抽出の話ではない。両立する。
- **`packspec.lua:41` は `pkg` モジュールの `M.get(plugin)`(`:13`)の中**で、
  `Spec.new` に `{ pkg = false }` を渡している以上呼ばれない
  (`safe_opts` の `pkg = { enabled = false }` も同じ方向に効く)。
  そもそも書き込み先は正規化済みの plugin ではなく spec fragment 側(`pkg.lazy`)であり、
  値は `plugin.dir` の複製なので新しい経路にもならない。

**したがって抽出時に効くのは `meta.lua` の 5 箇所だけである。** その中身:

```lua
-- lua/lazy/core/meta.lua
213  -- dir / dev
214  plugin.dev = super.dev
215  plugin.dir = super.dir
216  if plugin.dir then
217    plugin.dir = Util.norm(plugin.dir)                      -- (A) spec 自身が書いた dir
218  elseif super.virtual then
219    plugin.dir = Util.norm("/dev/null/" .. plugin.name)     -- (D) virtual
220  else
221    if plugin.dev == nil and plugin.url then
222      for _, pattern in ipairs(Config.options.dev.patterns) do
223        if plugin.url:find(pattern, 1, true) then
224          plugin.dev = true
225          break
226        end
227      end
228    end
229    if plugin.dev == true then
230      local dev_dir = type(Config.options.dev.path) == "string" and Config.options.dev.path .. "/" .. plugin.name
231        or Util.norm(Config.options.dev.path(plugin))        -- (C) dev.path の関数形
232      if not Config.options.dev.fallback or vim.fn.isdirectory(dev_dir) == 1 then
233        plugin.dir = dev_dir                                 -- (B) は :230 の文字列形
234      else
235        plugin.dev = false
236      end
237    end
238    plugin.dir = plugin.dir or Config.options.root .. "/" .. plugin.name   -- (E) 受け皿
239  end
```

**マシン固有の値が入りうる経路は、コードとして 3 つに分かれる。**

| | 経路 | `~` を展開するコード | 該当する形 |
|---|---|---|---|
| **(A)** | spec 自身が書いた `dir` | **`meta.lua:217`** の `Util.norm`(`lua/lazy/core/util.lua:74-84`) | 絶対 / `~` / 相対 / `stdpath()` で組んだもの —— **綴りが違っても全部この 1 本を通る** |
| **(B)** | `dev = true` + `dev.path` が**文字列** | **`config.lua:287-288`**(`Config.setup` 時) | 既定の `~/projects` はここで展開済み。`meta.lua:230` は `/<name>` を継ぐだけで **norm を呼ばない** |
| **(C)** | `dev = true` + `dev.path` が**関数** | **`meta.lua:231`** の `Util.norm` | `config.lua:288` は `type(...) == "string"` ガードなので**通らない**。norm はここでしか起きない |

```lua
-- lua/lazy/core/config.lua
286  M.options.root = Util.norm(M.options.root)
287  if type(M.options.dev.path) == "string" then
288    M.options.dev.path = Util.norm(M.options.dev.path)
289  end
```

(D) の `virtual` は `/dev/null/<name>` なので `~` は入らない。(E) は `local_dir` が構造的に除外する(#47)。

**(C) は既知の第一級概念である。** `docs/architecture.md` の項目 4 の見出しがそのまま
*"dev.path is a function"* で、`tests/dev-path-test.lua` は `meta.lua:229-231` の
文字列形 / 関数形の非対称を runtime で固定している。実測:

```console
### dev = { path = function(p) return "~/myworktrees/" .. p.name end }
raw-spec    : {"dev":true,"dir":"<HOME>/myworktrees/fn.nvim"}
plugins.json: {"fn.nvim":{"dir":"<HOME>/myworktrees/fn.nvim"}}
```

**そして `dev.patterns`(`meta.lua:221-228`)は 4 本目の経路ではない。**
(B) / (C) を**誰が**通るかを広げるだけで、`dir` の作られ方は変えない。
それでも重要なのは、**spec エントリ側に手掛かりが 1 文字も残らない**からである(§1.6 軸 2)。

**この区別は本計画のあちこちに効く。** `dev = true` 単独のプラグインが `$HOME` を持つ理由を
`meta.lua:216-217` に帰すのは誤りで、`resolve.lua` に永続的に入るコメント(§5.1)で
そう書けば **pin した seed に対して偽の citation をコミットすることになる**。

**(3) `extract.lua` の `local_dir` がその値を raw-spec に載せ、`resolve.lua` のメインループの `dev/dir` 分岐が
`local_plugins[name] = { dir = p.dir }` として `plugins.json` に書き出す。**

(1) と (2) は正しい。**問題は (3) の「書き出す」だけである。**

### 1.3 なぜ死重か —— Nix 側は**キーしか**読まない(実コード)

`nix/lib/make-env.nix` の `devDirs` は、`localPlugins` の**キーだけ**を `<devPath>/<name>` に写す:

```nix
  devDirs = lib.genAttrs (lib.unique (devPlugins ++ builtins.attrNames localPlugins)) (
    n: "${devPath}/${n}"
  );
```

`builtins.attrNames` しか呼ばれておらず、`localPlugins.<name>.dir` を読む式はファイル中に 1 つも無い。
同ファイルのコメントが理由も書いている ——
*"reading it could not change a single resolved directory. A `dir` the user wrote in the spec short-circuits lazy
before dev.path is ever consulted (lua/lazy/core/meta.lua:214-217)"*。

これは #26 の設計判断(`docs/plans/26-dev-plugins.md` §3.3)であり、
`tests/dev-path-test.lua` の `dirred.nvim` の assert が**実行時に**その前提(spec の `dir` が `dev.path` に勝つ)を
固定している。#47 §1.4 は runtime の実測で「記録された `dir` は一度も読まれない」ことを別途確認済みである。

### 1.4 `localPlugins` の全消費者

**件数ではなくキー集合で書く。** 件数は行送りや無関係な追記で簡単にずれるので、
「その消費者が `plugins.json` のトップレベルから読むキーは何か」を示す。

| 消費者 | トップレベルから読むキー | `localPlugins[*].dir` を読むか |
|---|---|---|
| `nix/lib/make-env.nix` の `localPlugins` / `devDirs` | `localPlugins`(`builtins.attrNames` のみ) | **読まない**(§1.3 の実コード) |
| `nix/lib/make-env.nix` の `unknownDevPluginNames` | `plugins` / `localPlugins`(どちらも `? ${n}` によるキーの有無) | 読まない |
| `lua/nvimx/genflake.lua` | `plugins` / `lazyNvim`(`grep -n localPlugins lua/nvimx/genflake.lua` が無出力) | 読まない |
| `lua/nvimx/update-summary.lua` | `plugins` / `lazyNvim`(同上) | 読まない |
| `lua/nvimx/resolve.lua`(`--prev` として) | **`schemaVersion` / `plugins` / `lazyNvim` の 3 つだけ** | **読まない**(下の注) |
| `flake.nix` の全 check | `has(...)` / `keys` / golden の byte 一致のみ | 読まない |
| `tests/dev-path-test.lua` | 読まない(`bootstrap.lua` の `dev_dirs` を通してしか見ない) | 読まない |

**`--prev` の read 集合の注**: `grep -n 'prev\.\|prev\[' lua/nvimx/resolve.lua` は 7 行を返すが、
そのうち**トップレベルの `prev`(`--prev` で読み込んだ文書そのもの)を触っているのは 5 行だけ**で、
読んでいるキーは `schemaVersion` / `plugins` / `lazyNvim` の 3 つである。
残り 2 行(`norm(prev.resolvedRef)` と `is_true(prev.pin)`)の `prev` は
**マージループの中でシャドウされた別変数**(`prev_plugins[name]` = 1 プラグインぶんのエントリ)であり、
トップレベルの文書ではない。**どちらの `prev` も `localPlugins` を読む行を 1 つも持たない。**

**書き手は 1 箇所、読み手はゼロ。** これが issue の言う「dead weight」の正確な内訳である。
この表は 1 ファイルずつ読んで作ったものではなく、**リポジトリ全体の grep で閉じてある**:

```console
$ grep -rn localPlugins nix/
nix/lib/make-env.nix:91,97,98      # コメント 3 行
nix/lib/make-env.nix:95            # localPlugins = if hasLock then pluginsDb.localPlugins or { } else { };
nix/lib/make-env.nix:109           # builtins.attrNames localPlugins
nix/lib/make-env.nix:118           # localPlugins ? ${n}
nix/home-manager/default.nix:307   # 警告文の散文(コードではない)

$ grep -rn localPlugins lua/
lua/nvimx/resolve.lua:1514         # localPlugins = json.object(local_plugins)
lua/nvimx/extract.lua:65,102       # コメント 2 行
```

**`nix/` 側に値を読む式は 1 つも無く、`lua/` 側に読み手は 1 つも無い。**
`nix/lib` の外に読み手が現れていないことまで含めて、この 2 本の grep が閉じている。

**`resolve.lua:1514` は `localPlugins` キーを `plugins.json` に書き出す唯一の箇所だが、本件では無変更である。**
本件が変えるのは**メインループの `local_plugins[name] = { dir = p.dir }`**(§3.1 / §5.1)で、
そちらは変数名が `local_plugins` なので**この grep には出てこない**。
「`localPlugins` を grep すれば #56 の変更点が出る」と読まないこと ——
`grep -n 'local_plugins' lua/nvimx/resolve.lua` が返す 3 行(束縛 / 代入 / `json.object` への引き渡し)のうち、
本件が触るのは真ん中の 1 行だけである。

`--prev` の側は実測でも確かめた。`--prev` に「#56 以前の nvimx が書いた plugins.json」を模した
`localPlugins` 入りのファイルを渡しても、出力は 1 バイトも変わらない:

```console
$ jq '.localPlugins = {"ghost.nvim": {"dir": "/home/alice/projects/ghost.nvim"}}' m1.json > m1-pre56.json
$ nvim -l resolve.lua raw-spec-base.json m2.json --prev m1-pre56.json --lock flake.lock --lazy <seed> ; echo rc=$?
rc=0
$ jq -c .localPlugins m2.json
{}
$ diff -u tests/fixtures/merge/golden/base.plugins.json m2.json && echo SAME
SAME
```

`ghost.nvim` は引き継がれない —— `localPlugins` は毎回 raw-spec から作り直され、prev は参照されない。

### 1.5 issue 本文の主張の検証 / 補正

| issue の記述 | 実測 | 扱い |
|---|---|---|
| `safe_opts` に `dev` が無いので lazy の `dev.path` が生きている | **正しい**(`extract.lua` の `safe_opts` に `dev` キーが無いことを確認) | §1.2 (1) |
| `meta.lua` が `dev = true` の `dir` を埋め、`Util.norm` が `~` を展開する | **前半は正しいが後半は誤り。** `dev = true` 単独の `~` を展開するのは `config.lua:287-288`(文字列形)か `meta.lua:231`(関数形)で、`meta.lua:216-217` は走らない | §1.2 (2) の経路 A / B / C |
| `extract.lua` は `p.dev` が真なときに `p.dir` を dump する | **#47 で古くなった**。今日の `local_dir` は `dev` を見ず、`p.dir` が lazy の root 配下に無いことだけを見る | §1.6 |
| 記録されうる形は 3 通り | **足りない。** `dir` を `stdpath(...)` から組み立てた場合はサンドボックスパスが入り(§1.1 の `sibling.nvim`)、`dev.patterns` / 関数形 `dev.path` は spec に手掛かりを残さない(§1.6 軸 2)。**そもそも spec の書き方を数え上げても母集団は閉じない** | §2 のゴール 1 は形の列挙ではなく `p.dev or p.dir` の述語で書く |
| #26 で Nix 側は値を完全に無視する | **正しい**(§1.3 の実コード) | §3.1 の根拠 |
| `tests/fixtures/dev-plugins/.../plugins.json` の `bare.nvim`(`dir` 無し)は手製で、現行 lock は出せない | **#47 で古くなった**。#47 の計画 §5.5 が `_comment` を訂正済みで、病的な `dev.path` 設定では実 lock も出しうる。本件後は**すべてのエントリがこの形になる** | §3.8 |
| option 1 は「診断情報を失う」 | **正しいが、失う情報はユーザー自身の `init.lua` に既にある**(§3.3) | §3.1 / §7 |

### 1.6 #47 が広げた母集団 —— `localPlugins` に入る形(11 経路。ただし全称ではない)

`extract.lua` の `local_dir` は `dev` を見ない。`p.dir` が `Config.options.root .. "/"` の下に無ければ記録する。
`resolve.lua` のメインループはそれを `p.dev or p.dir` で受ける。

**軸は 2 本ある。** spec が書いた形だけを数えると母集団を閉じられない ——
`extract.lua` の `safe_opts` に `dev` キーが無い(§1.2 (1))ので、
**`setup` の `opts.dev` サブツリーも `localPlugins` の中身を決めている**。

**軸 1: spec エントリが書いた形。**

| # | spec | `p.dir`(lazy が決めた値) | マシン固有か | `local-dir-config` にあるか |
|---|---|---|---|---|
| 1 | `{ "o/x.nvim", dev = true }` | `<dev.path>/x.nvim`(既定なら `<HOME>/projects/x.nvim`) | **する**(`config.lua:287-288` が `dev.path` を norm 済みにする。§1.2 経路 B) | **ある**(`bare.nvim`) |
| 2 | `{ "o/x.nvim", dev = true, dir = "/abs" }` | `/abs` | しない | **無い** |
| 3 | `{ "o/x.nvim", dir = "/abs" }`(#47) | `/abs` | しない | **ある**(`dirabs.nvim`) |
| 4 | `{ "o/x.nvim", dir = "~/mine/x" }` | `<HOME>/mine/x` | **する**(`meta.lua:216-217` の `Util.norm`。§1.2 経路 A) | **ある**(`dirtilde.nvim`) |
| 5 | `{ "o/x.nvim", dir = "mine/x" }`(相対) | `mine/x` | しない(が **cwd 依存**) | **ある**(`dirrel.nvim`) |
| 6 | `{ dir = "/abs/noname" }`(短縮名なし、#47) | `/abs/noname` | しない | **ある**(`dirnoname`) |
| 7 | `{ "o/x.nvim", dir = vim.fn.stdpath("data") .. "/..." }` | `<lock サンドボックス>/...` | **する**(§1.1) | **ある**(`sibling.nvim`) |
| 8 | `{ "o/x.nvim", virtual = true }`(#47 の副作用) | `/dev/null/x.nvim` | しない | **無い** |

**軸 2: `setup` の `opts.dev` が決める形。spec エントリ側には手掛かりが 1 文字も無い。**

| # | opts | 効果 | マシン固有か | fixture にあるか |
|---|---|---|---|---|
| 9 | `dev = { patterns = { "folke" } }` | `url` がパターンに当たる**すべて**のプラグインが `plugin.dev = true` になる(`meta.lua:221-228`) | **する**(#1 と同じ `<dev.path>/<name>`) | **無い** |
| 10 | `dev = { path = function(p) ... end }`(関数形) | `config.lua:288` のガードを外れるので、norm は `meta.lua:231` でしか起きない(§1.2 経路 C)。**リポジトリの第一級概念**(`docs/architecture.md` の項目 4 の見出しがこれ) | **する**(実測: `<HOME>/myworktrees/fn.nvim`) | **無い** |
| 11 | `dev = { path = <lazy の root 配下> }` | `local_dir` が前方一致で `nil` を返し、`resolve.lua` の `p.dev` 側だけで拾われる | しない(`dir` が記録されない) | **無い**(#47 §7 が「意図的に fixture を作らない」と決めた) |

**#9 は病的な設定ではない。** `patterns = {}` の既定値の脇に lazy 自身が
*"For example {"folke"}"*(`config.lua:75`)と書いている**公開オプション**である。実測:

```console
$ cat init.lua
require("lazy").setup({
  { "folke/tokyonight.nvim" },   -- dev も dir も書いていない
  { "o/plain.nvim" },            -- pattern に当たらない対照
  { "o/bare.nvim", dev = true },
}, { dev = { patterns = { "folke" } } })

$ jq -S '.plugins | map_values({dev, dir})' raw-spec.json
{ "bare.nvim":      { "dev": true, "dir": "<HOME>/projects/bare.nvim" },
  "plain.nvim":     { "dev": null, "dir": null },
  "tokyonight.nvim":{ "dev": true, "dir": "<HOME>/projects/tokyonight.nvim" } }

$ jq -c '{plugins:(.plugins|keys), localPlugins:.localPlugins}' plugins.json
{"plugins":["plain.nvim"],
 "localPlugins":{"bare.nvim":{"dir":"<HOME>/projects/bare.nvim"},
                 "tokyonight.nvim":{"dir":"<HOME>/projects/tokyonight.nvim"}}}
```

**`{ "folke/tokyonight.nvim" }` —— `dev` も `dir` も書いていないエントリ —— が `$HOME` 入りで
コミットされる。** #56 が直そうとしている被害そのものであり、しかも設定 1 行で起きる。

**#11 の実測**(`dev.path` を lazy の root に向けたもの):

```console
raw-spec: {"dev":true,"dir":null}
resolve  : {"plugins":[],"localPlugins":["bare.nvim"]}
```

`dir` が落ちるので `localPlugins` のエントリは **今日すでに `{ }`** である。
`resolve.lua` の `p.dev or p.dir` の `p.dev` 側が拾っている(#47 §3.4 / §7、
`tests/fixtures/dev-plugins/nvimx-lock/plugins.json` の `_comment` が記録している経路)。

**逆向きの経路もある: `dev.fallback = true` は `dev = true` を remote に落とす。**
`meta.lua:232-235` は作業ツリーが存在しなければ `plugin.dev = false` に戻す。実測:

```console
### dev = { fallback = true }、作業ツリーは存在しない
raw-spec: {"dev":null,"dir":null}
resolve  : {"plugins":["bare.nvim"],"localPlugins":[]}
```

したがって **#1 の「必ず `<HOME>/projects/x.nvim` になる」は `fallback = false`(既定)限定の主張**である。

**この表は全称ではない。** 上の 11 行は今日たどれた経路であって、
`localPlugins` の母集団を定義しているのは
**「`extract.lua` の `local_dir` が値を返すか、`p.dev` が真になるかのいずれか」**という述語のほうである。
本計画が「N 形すべて」と書くときは常にこの述語のことを指し、表は例示として扱う(§2 ゴール 1)。

**#56 はこの表の「マシン固有か」の列を無意味にする。** どれが `localPlugins` に入るかには 1 つも触らない。

**fixture が持つのは 11 行のうち 6 行だけである。** `local-dir-config` は #1 と #3-#7 を持ち、
#2 / #8 / #9 / #10 / #11 の 5 つを持たない。#2 は `spec-matrix` の `devel.nvim` と `import-lazy-lock` の `local.nvim` が
**どちらも `dev: true` と `dir` を両方持つ**ので、その 2 本の golden が押さえる(§4.6)。
**#8 / #9 / #10 / #11 はどの fixture にも無い**(§7)。
**「6」と「11」を混同しないこと**: 以降で「6」と書くのは `local-dir-config` の
**`localPlugins` 行きのエントリ数**であって、経路の全体ではない(§5.2 (a) のコメント)。

---

## 2. ゴール

1. **`plugins.json` の `localPlugins` に、マシン固有の値が 1 つも入らない。**
   §1.6 の表に挙げた 11 経路だけでなく、**`p.dev or p.dir` が真になる任意の経路**について成り立つこと。
   §1.6 の表は例示であって全称ではない(`opts.dev` が決める形が 2 つある以上、
   spec の書き方を数え上げても母集団は閉じない)。**「エントリに値を書かない」で達成するので、
   経路を列挙しきる必要が無い**のが本件の設計上の最大の利点である ——
   逆に、経路ごとに値を選び分ける案(issue の option 2)は列挙が閉じないことに直接ぶつかる(§3.2 / §3.3)。
   「`$HOME` を含まない」ではなく「**値を持たない**」で達成する。
2. **`localPlugins` のキーの集合は 1 つも変わらない。** #47 が決めたルーティングを本件は動かさない。
3. **#47 を壊さない。** raw-spec の `dir` はルーティング信号を兼ねているので、
   **`extract.lua` には触らない**(§3.2 で「触ると壊れる」ことを実測で示す)。
4. **`schemaVersion` は 1 のまま**で、新旧双方向に読める(§3.6)。
5. **生成 `flake.nix` と `flake.lock` は 1 バイトも動かない。** 再 fetch も再ビルドも起こさない(§4.6 で実測)。
6. **既存ユーザーの再 lock で起きることを、golden の差分として先に確定させる。**
   動く golden は 2 本、動くのは 1 箇所ずつ、それ以外はゼロ(§4.6)。
7. **`make-env.nix` が `localPlugins[*].dir` を読み始めたら落ちる、という既存のガードを死なせない。**
   本件はそのガードが載っている fixture の形を「実 lock が出せない形」に変えるので、
   前提そのものを check に固定する(§3.8)。
8. **事実と食い違う散文をリポジトリに 1 行も残さない。** **§5.6 の照合表(24 項目)を語単位で通すこと。**
9. `nix flake check` が Linux でグリーン、`aarch64-darwin` でも評価できる。

---

## 3. 設計

### 3.1 採用 —— option 1。`resolve.lua` が空オブジェクトを書く

変更は `resolve.lua` のメインループの `dev/dir` 分岐、**1 行**である:

```lua
    local_plugins[name] = json.object({})
```

`extract.lua` は無変更、`nix/lib/**` も無変更、`genflake.lua` / `update-summary.lua` も無変更。

**なぜ「値を空にする」で足りるのか。** §1.4 のとおり読み手がゼロだからである。
issue が挙げる 2 案のうち option 2 は「診断を残す」ために内部表現に降りるが、
残す診断の中身を実測すると**ほとんど残らない**(§3.3)。

**`{ }` にする(値を消す)のであって、キーを消すのではない。** キーは `make-env.nix` の
`devDirs` / `unknownDevPluginNames` が実際に読む唯一の情報であり、これを落とすと #26 が壊れる。
摂動 (e) がこれを守る(§6.2)。

**`json.object({})` と書く理由。** `json.lua` の `is_array` は
`vim.islist(t) and #t > 0` なので、素の `{}` も結果としては `{}` に符号化される
(実測: `local_plugins[name] = {}` と `json.object({})` の出力は byte 一致)。
それでも明示するのは、`json.lua` 冒頭が *"Marker used to tell arrays from objects for empty tables"* と
書いているとおり**空テーブルの型を明示するのがこのモジュールの作法**だからであり、
`is_array` の条件が将来変わっても `[]` に化けないようにするためである。
`localPlugins` が `[]` を含むと `make-env.nix` の `builtins.attrNames` の入力型が変わる。

実測(#47 の fixture、修正後):

```console
$ nvim -l resolve.lua raw-spec.json out.json ; echo rc=$?
rc=0
$ jq -c .localPlugins out.json
{"bare.nvim":{},"dirabs.nvim":{},"dirnoname":{},"dirrel.nvim":{},"dirtilde.nvim":{},"sibling.nvim":{}}
```

§1.1 の 6 件と**キーが完全に一致**していること、`$HOME` もサンドボックスパスも 1 つも残っていないことに注意。

### 3.2 却下 A —— option 2 を「raw-spec の `dir` を絞り込む」形で実装する

issue の option 2 は *"Distinguish the derived value from the written one in `extract.lua` — e.g. `rawget` on
the spec fragment before lazy's meta pass fills it in — and record only the latter"* と書いている。
`docs/plans/47-dir-without-dev.md` §4.2 は **これをそのまま実装すると #47 を静かに壊す**と申し送った。
**自分で確かめた。結論: 申し送りは正しい。**

まず「ユーザーが書いた `dir`」が実際に取れるかを probe した。`p._.frags` の各 fragment について
`rawget(s.meta.fragments:get(fid).spec, "dir")` を読む(= 却下案の機構そのもの):

```console
root_prefix = <DATA>/nvim/lazy/
bare.nvim        dev=true  p.dir=<HOME>/projects/bare.nvim        local_dir=<HOME>/projects/bare.nvim   written=nil
devboth.nvim     dev=true  p.dir=<HOME>/nvimx-fixture/devboth     local_dir=<HOME>/nvimx-fixture/devboth written=~/nvimx-fixture/devboth
dirabs.nvim      dev=nil   p.dir=/nvimx-fixture/dirabs            local_dir=/nvimx-fixture/dirabs       written=/nvimx-fixture/dirabs
dirtilde.nvim    dev=nil   p.dir=<HOME>/nvimx-fixture/dirtilde    local_dir=<HOME>/nvimx-fixture/dirtilde written=~/nvimx-fixture/dirtilde
tokyonight.nvim  dev=nil   p.dir=<ROOT>/tokyonight.nvim           local_dir=nil                         written=nil
underroot.nvim   dev=nil   p.dir=<ROOT>/underroot.nvim            local_dir=nil                         written=<ROOT>/underroot.nvim
virt.nvim        dev=nil   p.dir=/dev/null/virt.nvim              local_dir=/dev/null/virt.nvim         written=nil
```

**機構としては動く。** しかも `written` は `Util.norm` **より前**の値なので、`~/nvimx-fixture/dirtilde` が
チルダのまま取れる —— つまり「ユーザーが書いた値だけを記録する」は `$HOME` 漏れを本当に消せる。
ここまでは issue の想定どおりである。

**壊れるのは `local_dir` の列と `written` の列が一致しないところである。** 上の表で 2 箇所ずれている:

- `virt.nvim`: `local_dir` は値を返す(= ローカル)が、`written` は nil(= リモート)。
- `underroot.nvim`: `local_dir` は nil(= リモート)だが、`written` は値を返す(= ローカル)。

`extract.lua` の `dir` を `written` に絞ると、この 2 件の**分類が入れ替わる**。実測(同じ spec を
今日の extract に通した raw-spec と、`dir` を `written` に置き換えた raw-spec を、それぞれ resolve に食わせたもの):

```console
--- 今日 (#47):  {"plugins":["tokyonight.nvim","underroot.nvim"],
                 "localPlugins":["bare.nvim","devboth.nvim","dirabs.nvim","dirtilde.nvim","virt.nvim"]}
--- 絞り込み後: {"plugins":["tokyonight.nvim","virt.nvim"],
                 "localPlugins":["bare.nvim","devboth.nvim","dirabs.nvim","dirtilde.nvim","underroot.nvim"]}
```

`virt.nvim` は `url` を持つので、リモート側に移れば **flake input が 1 本増え、farm にコピーが増え、
runtime では一度も読まれない**。これは #47 が閉じた穴が `virtual` について再び開くことである。
`underroot.nvim` の側は #47 §3.1 が明示的に**却下した軸**(却下 B、「spec が書いたかどうか」)への逆戻りで、
lazy が `_.is_local` を判定する軸(`lua/lazy/core/plugin.lua:244-252` の root 前方一致)から外れる。

**却下理由(3 点)**:

1. **#47 の分類を 2 件変える。** 上の実測。しかも `plugins.json` の見た目は変わらないので、
   気付けるのは `flake.lock` に input が 1 本増えたときだけである。まさに「静かに壊す」。
2. **述語が 2 本になる。** `extract.lua` の `dir` が「記録すべき値」と「ルーティング信号」の
   2 役を兼ねている以上、片方だけを絞ると 2 つの述語が食い違える中間状態ができる。
   #47 §3.5 が `effective_version` にガードを足さないと決めたのと同じ理由である。
3. **`bare.nvim` が守っていた assert が落ちる。** `checks.extractor-local-dir` の
   `.plugins["bare.nvim"].dir == ($h + "/projects/bare.nvim")` と「`dir` を持つのはちょうど 6 件」は、
   絞り込むと `written=nil` なので即座に赤になる —— つまり**この却下案は既存 check で検出できる**。
   これは §6.2 の摂動 (f) として記録し、「#56 が #47 を壊さないこと」のガードに使う。

### 3.3 却下 B —— option 2 を「フィールドを足す」形で実装する(`dirFromSpec`)

`docs/plans/47-dir-without-dev.md` §4.2 が「option 2 を採るならこの形でなければならない」と指定した案:
`extract.lua` は `dir` を今までどおり載せたまま、`written` を `dirFromSpec` として**追加**し、
`resolve.lua` が `local_plugins[name] = { dir = <dirFromSpec> }` を書く。

**この案は #47 を壊さない。** §3.2 の 2 件の分類は `dir` が残っているので不変であり、
記録される値も `~` のままなので `$HOME` 漏れは消える。**技術的には成立する。** それでも採らない。

**却下理由(4 点)**:

1. **issue が守ろうとした診断が、ほとんど残らない。** §3.2 の probe のとおり、
   **`dev = true` 単独のプラグインの `written` は `nil`** である。
   ところが issue が「最悪」として挙げているのがまさにその形(`<HOME>/projects/<name>`)である。
   つまり option 2 は、**問題が一番大きいケースについては option 1 と同じ `{ }` を書く**。
   値が残るのは「ユーザーが `dir` を明示的に書いた場合」だけであり、
   **その文字列はユーザー自身の `init.lua` に、同じリポジトリの数ファイル隣に、既にコミットされている。**
   lock がそれを複製して得るものは無い。
2. **lazy の内部表現に依存する。** `p._.frags` と `s.meta.fragments:get(fid).spec` は
   `LazyFragments` の内部であり、`docs/plans/43-drop-optional-field.md` §3.4 が同種の依存を
   「seed 更新で壊れうる」と評価している。§3.1 は lazy の API に一切触れずに済む。
3. **raw-spec のスキーマにフィールドが 1 つ増える。** `extractor-snapshot` の golden が動き、
   `dir` と `dirFromSpec` の関係(片方が nil でもう片方が非 nil な組合せが 4 通り)を
   固定する check が要る。**1 行の削除で済む問題に、check 1 本ぶんの保守を足す取引になる。**
4. **`plugins.json` のスキーマにも新しい意味が入る。** `localPlugins.<n>.dir` の意味が
   「lazy が解決したディレクトリ」から「ユーザーが書いた文字列(正規化前)」に変わる。
   **キーは同じで意味だけが変わる**ので、`schemaVersion` を上げずに済ませる論証(§3.6)が
   「読み手がいないから安全」ではなく「読み手がいないうえに意味も変わった」になる。
   #43 §3.2 が確立した基準からいちばん遠い形である。

**ただし本件が完全に閉じるわけではない。** 「ローカルプラグインの由来を機械可読に残したい」という
要求が将来出たときのために、§3.4 / §3.5 でエントリの**形**の自由度は残す。§7 に follow-up として記録する。

### 3.4 却下 C —— `localPlugins` を名前の配列にする

値が全部空なら `{"a":{},"b":{}}` より `["a","b"]` のほうが素直に見える。**採らない。**

**却下理由**: `make-env.nix` は `builtins.attrNames localPlugins` と `localPlugins ? ${n}` を使う。
配列にすると両方が型エラーになるので `nix/lib/make-env.nix` も同時に変える必要があり、そうすると
**旧 nvimx が新 `plugins.json` を読めなくなる**(`builtins.attrNames` にリストを渡して評価が落ちる)。
`docs/plans/43-drop-optional-field.md` §3.2 の基準でいう「削除は additive でない」のさらに先、
**型の変更**であり、`schemaVersion` を上げる議論を呼び込む。得られるのは見た目だけである。

**`localPlugins.<n> = true`(値をスカラーにする)も、ここで併せて却下する。**
配列ほど破壊的ではない —— `make-env.nix` はマップ側にしか触らないので `attrNames` も `? ${n}` も動く ——
が、**additive にフィールドを足す余地が消える**。#56 が値を空にする以上、
将来「ローカルにした理由」なり何なりを 1 つ記録したくなる可能性は残っており(§3.5 / §7)、
そのときオブジェクトなら 1 キー足すだけの additive な変更で済むのに対し、`true` からの移行は
**型の変更**になって §3.6 の双方向互換の論証をやり直すことになる。
`{ }` は「今は何も無い」と「後から足せる」を同時に表せる唯一の形なので、これを採る。

### 3.5 却下 D —— 由来フラグ(`dev` / `specDir`)を値に入れる(論点 5 の結論)

#47 で `dev = true` と `dir` 明示は同じ `localPlugins` に入るようになった。両者はマシン固有性の度合いが違うので、
`{ "dev": true }` / `{ "specDir": true }` のような**マシン非依存の由来フラグ**なら記録しても漏れは起きない。

**採らない。両者の区別は潰す。** 却下理由:

1. **読み手がいない。** リポジトリの先例が一貫している ——
   `docs/plans/43-drop-optional-field.md` は `optional` を「読み手が 1 つも存在しない」ことを理由に削除し、
   `docs/plans/49-lazy-nvim-collision.md` §3.4 は `lazyNvim` の `build` / `dependencies` を同じ理由で載せないと決めた。
   由来フラグは今日どの消費者も要求していない。
2. **区別は `plugins.json` の外に既にある。** どのプラグインが `dev = true` でどれが `dir` を書いたかは、
   ユーザー自身の lazy spec に書いてある。lock はそれを pin するファイルであって、複製する場所ではない。
3. **一番使えそうな用途は、それ単体では成立しない。** 想定できる唯一の実用は
   「`devPath` が効かないエントリ(= spec が `dir` を書いたもの)に `devPlugins` を書いているユーザーへの警告」だが、
   これは `unknownDevPluginNames` と並ぶ**新しい警告の設計**であり、#56 のスコープではない。
   本件はその余地を**残す**: エントリを `{ }`(オブジェクト)にしておけば、後からフィールドを 1 つ足すのは
   additive な変更で済む(`true` や配列にするとそれができない —— 論証は §3.4 の末尾にある)。

**したがって #56 は「`dev = true` 由来か `dir` 由来か」を `plugins.json` から消す。**
消えても壊れるものは無い —— `resolve.lua` のルーティングも `make-env.nix` の `devDirs` も
raw-spec 側の `p.dev` / `p.dir` を見ており、`plugins.json` の側は見ていない。

### 3.6 `schemaVersion` は 1 のまま

`docs/plans/43-drop-optional-field.md` §3.2 が確立した基準を本件に当てはめる。
その基準は「追加は additive、削除は additive でない。危険なのは**キーの存在を前提に読む読み手**である。
上げると既存ユーザーの committed plugins.json が新 nvimx から読めなくなり、
`resolve.lua` の案内どおり削除すれば pin が全損する」というものだった。

本件は `localPlugins` の各エントリからキー 1 つを削除する変更なので、**そのまま鵜呑みにはできない**。
#49 §3.3 と同じく双方向で確認した:

- **新 nvimx が旧 `plugins.json` を読む。**
  - `--prev` として: §1.4 の grep のとおり `prev.localPlugins` を読む行が存在しない。
    実測でも、`localPlugins` に余計なエントリを仕込んだ prev を渡して出力が golden と byte 一致した(§1.4)。
  - `make-env.nix` として: `builtins.attrNames` だけなので、値に `dir` があってもなくても同じ。
    **これは check で実証済みである** —— `tests/fixtures/dev-plugins/nvimx-lock/plugins.json` は
    `bare.nvim: {}` と `dirred.nvim: {"dir": ...}` を**同時に**持っており、`checks.dev-plugins` が
    両方に対して `~/proj/<name>` を要求して緑である。旧形式と新形式の混在が既に固定されている。
- **旧 nvimx が新 `plugins.json` を読む。**
  - 旧 `make-env.nix`: 同じく `builtins.attrNames` のみ。`{ }` でも問題ない(上と同じ fixture が証拠)。
  - 旧 `resolve.lua` が `--prev` として: `prev.localPlugins` を読まないのは旧版も同じ
    (この read 集合は #18 でスキーマが確定して以来変わっていない)。
  - 旧 `genflake.lua` / `update-summary.lua`: `localPlugins` を読まない。

**両方向で「pin の喪失」も「評価の失敗」も起きない。結論: `schemaVersion` は 1 のまま。**
理由は「削除だから安全」ではなく、**`localPlugins[*].dir` を読む消費者が新旧どちらにも 1 つも存在しないから**である。

#43 が残した債務(将来 non-additive な変更が要るなら `resolve.lua` に v1 受理の互換読みを書く)は
本件でも返済しない —— 返済する必要が無いことが上の分析の帰結である。

### 3.7 `extract.lua` は無変更 —— raw-spec の `dir` はルーティング信号として残る

**raw-spec の `dir` は `plugins.json` の `dir` とは別物である。** 前者は
`resolve.lua` のメインループの `p.dev or p.dir` が読む**判定材料**であり、後者はどこも読まない**記録**である。
本件は後者だけを消す。

したがって:

- raw-spec のスキーマは変わらない。`extractor-snapshot` の golden は動かない(§4.6 で実測)。
- `checks.extractor-local-dir` のステップ 1(raw-spec の `dir` / `dev` / `version` を assert する `jq -e` の並び)は 1 行も動かない。
- **#47 の `local_dir` の述語は本件の保護対象になる。** 摂動 (f)(§3.2 の絞り込み)を
  既存 check が捕まえることを §6.2 で確認する。

raw-spec は lock の中間生成物で、`nvimx-lock/` にはコミットされない
(`nix/lib/lock-app.nix` はサンドボックスに書く)。**`$HOME` を含んでよいのはこちらだけである。**

### 3.8 `tests/fixtures/dev-plugins` の `dirred.nvim` は**残す**。ただし前提を check に固定する

`checks.dev-plugins` は `dirred.nvim` に `dir = "~/elsewhere/dirred.nvim"` を持たせ、
「`devPath` が決めた `~/proj/dirred.nvim` になること」を assert している ——
つまり **`make-env.nix` が記録された `dir` を読み始めたら赤になる**ガードである。

本件の後、**この形の lock を実 lock は出せなくなる**(すべて `{ }` になる)。
issue の Notes も *"Option 1 would make it [= `bare.nvim` の形] the realistic shape"* と書いている。

**それでも `dirred.nvim` の `dir` は残す。** 理由:

1. **#56 以前にコミットされた `plugins.json` は現実に存在する。** 本件は既存の lock ファイルを
   書き換えない —— ユーザーが再 lock するまで、その `dir` はそのまま git に残る。
   **新しい nvimx は、そういう lock を今までどおり無視できなければならない。**
   `dirred.nvim` はその後方互換をそのまま表現している。
2. ガードとしての価値は #56 で減らない。`make-env.nix` が値を読み始める退行は今日も明日も同じように起きうる。

**ただし危険が 1 つ増える。** 実 lock がこの形を出せなくなるので、
「fixture を実物に合わせよう」とする変更が将来来うる。そのとき
`checks.dev-plugins` の *"a localPlugins entry's recorded dir must be ignored"* は
**赤にならずに空虚になる**。空虚化の経路は 2 つある:

- **(g1) `dir` を消す**。無視すべき値が無くなり、assert は `devPath` の答えを見るだけになる。
- **(g2) `dir` を `"~/proj/dirred.nvim"` に書き換える**。値は在るが `devPath` の答えと一致するので、
  `make-env.nix` が値を読み始めても assert は通ってしまう。

**守るべき前提は「`dir` が在ること」ではなく「`dir` が `devPath` の答えと違うこと」である。**
fixture の `_comment` 自身が *"deliberately pointing somewhere devPath would never produce"* と
書いているとおりで、`dir` の存在だけを固定すると (g2) が素通りする。

**したがって前提そのものを assert する**。`checks.dev-plugins` の `let` で fixture を評価時に読み戻し、
`dirred.nvim` の `dir` が **null でも `~/proj/dirred.nvim` でもない**ことを 1 件の `lib.optional` で固定する(§5.2 (b))。
これは #47 §6.1 が「ステップ 1 の `version` 3 行はステップ 2 を空虚にしないためにある」と書いたのと同じ規律である。
実測(この式が IFD 無しで評価でき、2 経路とも捕まえること):

```console
$ nix eval --impure --expr 'let d = (builtins.fromJSON (builtins.readFile <repo>/tests/fixtures/dev-plugins/nvimx-lock/plugins.json)).localPlugins."dirred.nvim".dir or null;
                            in { dir = d; fails = d == null || d == "~/proj/dirred.nvim"; }'
{ dir = "~/elsewhere/dirred.nvim"; fails = false; }
$ nix eval --impure --expr 'let d = null;                   in d == null || d == "~/proj/dirred.nvim"'   # (g1)
true
$ nix eval --impure --expr 'let d = "~/proj/dirred.nvim";   in d == null || d == "~/proj/dirred.nvim"'   # (g2)
true
```

### 3.9 まとめ —— 変更点

| # | ファイル | 変更 |
|---|---|---|
| 1 | `lua/nvimx/resolve.lua` | メインループの `dev/dir` 分岐: `local_plugins[name] = { dir = p.dir }` → `local_plugins[name] = json.object({})`。**理由を書いたコメントを付ける**(§5.1 に最終形をそのまま置いてある。**行数は減らさないこと** —— citation と限定がそれぞれ 5 巡のレビューで足されたものである) |
| 2 | `tests/fixtures/spec-matrix/golden/matrix.plugins.json` | 再生成(`devel.nvim` の 1 ハンク。§4.6) |
| 3 | `tests/fixtures/import-lazy-lock/golden/imported.plugins.json` | 再生成(`local.nvim` の 1 ハンク。§4.6) |
| 4 | `flake.nix` `checks.extractor-local-dir` | assert を 1 行追加(`localPlugins` の全エントリが `{ }`)+ *"Only the keys ... #56 is free to"* のコメントを事実に合わせる(§5.2) |
| 5 | `flake.nix` `checks.dev-plugins` | `let` に fixture の読み戻しを 1 本、`failures` に前提固定を 1 件追加(§3.8 / §5.2 (b))。**加えて `dirred.nvim` assert 直前のコメントの *"a dir the user wrote absolute is kept verbatim"* を事実に合わせる**(§5.2 (b2)) |
| 6 | `flake.nix` `checks.resolve-golden` | *"the half that survives #56 whichever way that issue goes"* のコメントを事実に合わせる(§5.2) |
| 7 | `flake.nix` `checks.resolve-import-lazy-lock` | #47 のケースの *"#56 must be able to stop recording it"* のコメントを事実に合わせる(§5.2) |
| 8 | `nix/lib/make-env.nix` | `devDirs` の直前のコメント(記録される値を 3 通りに分けて説明している段落)を書き換える(§5.4) |
| 9 | `docs/architecture.md` | `plugins.json` スキーマの `localPlugins` 行、`dev.path is a function` の項(§5.4) |
| 10 | `README.md` | `### Local plugin development` の 3 つ目の bullet の括弧書き(§5.4) |
| 11 | `tests/fixtures/dev-plugins/nvimx-lock/plugins.json` の `_comment` | #56 で偽になる記述の訂正。**データは 1 バイトも動かさない**(§5.3 / §5.4) |
| 12 | `tests/fixtures/spec-matrix/raw-spec.json` の `_comment` | *"If #56 changes what resolve.lua records ..."* の申し送りを discharge する(§5.4) |
| 13 | `tests/dev-path-test.lua` | *"the rationale for not reading localPlugins[*].dir would collapse"* の一節を事実に合わせる(§5.4) |
| — | `lua/nvimx/extract.lua` | **無変更**(§3.7) |
| — | `nix/lib/make-env.nix` の**コード** | **無変更**(コメントのみ。§3.1) |
| — | `lua/nvimx/genflake.lua` / `update-summary.lua` / `json.lua` | **無変更** |
| — | 新規 fixture / 新規 check | **無し**(§6.1) |

---

## 4. 既存機能との関係

### 4.1 #26(`devPlugins` / `devPath` / `localPlugins`)

#26 は `localPlugins` の**キー**を Nix 側に読ませる機能であり、`docs/plans/26-dev-plugins.md` §3.3 で
「`localPlugins[*].dir` は読まない」を明文で決めている。**#56 はその決定の帰結を書き手の側にも通すだけである。**

#26 が確立した意味論のうち、本件が変えないもの:

- `devDirs` の値は必ず `<devPath>/<name>`。
- `dir` を書いたプラグインでは `devPath` が効かない(lazy が `meta.lua:216` で短絡する)。
  `tests/dev-path-test.lua` の `dirred.nvim` の assert が runtime でそれを固定している。
- `unknownDevPluginNames` は `pluginsDb.plugins` と `localPlugins` の**キー**で判定する。

#26 の計画 §7 が残したリスクのうち、*"localPlugins に記録されるパスは lock を走らせたマシンのもの"* は
**本件で解消する**。

### 4.2 #47(`dev` の無い `dir`)

**#47 のコードは 1 バイトも変えない。** `extract.lua` の `local_dir` も、
`resolve.lua` のメインループの `p.dev or p.dir` も、そのままである。

#47 が残した申し送り(`docs/plans/47-dir-without-dev.md` §4.2)への回答:

1. > 本件のどの assert も `plugins.json` の `localPlugins[*].dir` の**値**を見ない ……
   > したがって #56 が option 1 を採っても、本件の check は 1 行も動かない。

   **確認した。動かない。** `checks.extractor-local-dir` は
   `(.localPlugins | keys) == [...]` しか書いておらず、実測でも #56 の前後で緑のままである
   (§4.6)。本件が同 check に足す 1 行は、#47 のガードを保つための**追加**であって既存行の変更ではない。

2. > option 2 は **`dir` を絞り込んではならない** …… この一文が無いと、#56 が #47 を静かに再発させる。

   **確かめた。正しい。** §3.2 の実測で、絞り込むと `virt.nvim` と `underroot.nvim` の分類が入れ替わる。
   本件はそもそも `extract.lua` に触らないので、この罠には入らない。
   **さらに、この罠を将来踏んだ場合に何が赤くなるかも確定させた**: `checks.extractor-local-dir` の
   `bare.nvim` の 2 行と「`dir` を持つのはちょうど 6 件」である(摂動 (f)、§6.2)。

3. > #47 の計画の assert はすべて `localPlugins` の**キー**のみに触れるので、#56 の option 1 は
   > この check を編集せずに入れられる。

   **正しい。** 本件が同 check を編集するのは、「編集しないと入らない」からではなく
   「#56 の主張(全エントリが空)を、`localPlugins` 行きのエントリを 6 件まとめて持つ
   唯一の fixture の上で言うため」である(§6.1)。
   **§1.6 の 11 経路すべてを持つ fixture ではない** —— `dev` + 明示 `dir` は `resolve-golden` の
   golden が押さえ、`virtual` / `dev.patterns` / root 配下の `dev.path` はどの fixture も持たない(§1.6 / §7)。

**#47 が広げた母集団は 1 件も変わらない。** #56 の前後で `localPlugins` のキー集合が同一であることは、
§3.1 の実測(6 キーが一致)と §4.6 の golden 差分(キーは動かず値だけが動く)で二重に確認してある。

### 4.3 #49(spec の lazy.nvim)

`checks.resolve-lazy-self` は `localPlugins` について `has("lazy.nvim")` しか見ておらず、
golden(`golden/tag.plugins.json`)の `localPlugins` は `{}` である。
**#56 の前後で同 check の出力は 1 バイトも動かない**(§4.6 で実測)。

#49 §3.3 が `schemaVersion` を上げないと決めたときの論法(双方向確認)は本件にもそのまま当てはまる。
違いは方向だけで、#49 は `lazyNvim` へのキー**追加**、本件は `localPlugins` エントリからのキー**削除**である。
削除側は #43 §3.2 が扱っているので、§3.6 では両方の基準を突き合わせてある。

### 4.4 #25(`--import-lazy-lock`)

classification 3L(*"it is a local plugin (dev/dir), so there is nothing to pin"*)の発火条件も、
`import_accounted` の集計も、raw-spec の `p.dev` / `p.dir` を見ており `plugins.json` の側は見ない。
**ロジックは無変更。** 動くのは `golden/imported.plugins.json` の `local.nvim` の 1 ハンクだけである(§4.6)。

`--import-lazy-lock` を通した後の `localPlugins` の中身が `{ }` になっても、
「pin するものが無い」という報告の意味は変わらない —— そもそもその報告は `plugins.json` ではなく
stderr のログとして出ている。

### 4.5 #18(`--prev` によるマージ)/ #24(`--update`)/ #42・#23

- **#18**: `resolve.lua` は prev から `schemaVersion` / `plugins` / `lazyNvim` / `resolvedRef` / `pin` しか読まない
  (§1.4 の grep が全件)。`localPlugins` は毎回 raw-spec から作り直される。**マージ契約は無関係。**
- **#24**: `update-summary.lua` は `plugins` と `lazyNvim` しか読まない。
  したがって **本件の差分は update-summary に 1 行も出ない**(§4.6 で実測)。
- **#42 / #23**: ローカルプラグインは制約を記録しないので(`localPlugins` のエントリには元から
  `version` も `tag` も無い)、本件は semver 経路に一切触れない。

### 4.6 既存 check / golden への影響 —— **動く golden は 2 本、各 1 ハンク**(実測)

`tests/` 以下で `localPlugins` という語を含むファイルは 23 本ある(main = `e28d713` の実測)。
**そのうち `localPlugins` を非空の JSON として持つのは 3 本だけである**:

| ファイル | 種別 | #56 の影響 |
|---|---|---|
| `tests/fixtures/spec-matrix/golden/matrix.plugins.json` | golden(`checks.resolve-golden`) | **動く**(下の実測) |
| `tests/fixtures/import-lazy-lock/golden/imported.plugins.json` | golden(`checks.resolve-import-lazy-lock`) | **動く**(下の実測) |
| `tests/fixtures/dev-plugins/nvimx-lock/plugins.json` | 手書きの**入力** fixture | **データは動かない**(§3.8)。`_comment` のみ訂正 |

残り 20 本の内訳(実測):

- **16 本**は `"localPlugins": {}` を持つ `plugins.json` 系。空なので影響ゼロ。
- **2 本は raw-spec** で、`localPlugins` キーを持たない(`_comment` に語が出るだけ):
  `spec-matrix/raw-spec.json` と `lazy-self/raw-spec-devpin.json`。
- **2 本は散文だけ**: `tests/dev-path-test.lua` と `local-dir-config/init.lua` のコメント。

**このうち #56 が編集するのは、上の golden 2 本と、`_comment` / コメントのみ 3 本
(`dev-plugins/nvimx-lock/plugins.json`、`spec-matrix/raw-spec.json`、`dev-path-test.lua`)である。**

プロトタイプで採った実際のハンク。まず**修正前の出力が現行 golden と byte 一致する**ことを確認してから、
修正後との差を採った:

```console
$ diff -u tests/fixtures/spec-matrix/golden/matrix.plugins.json got-before.json && echo SAME
SAME
$ diff -u tests/fixtures/spec-matrix/golden/matrix.plugins.json got-after.json
@@ -9,9 +9,7 @@
     "synthetic": true
   },
   "localPlugins": {
-    "devel.nvim": {
-      "dir": "/nvimx-fixture/dev-root/devel.nvim"
-    }
+    "devel.nvim": {}
   },
   "plugins": {
```

```console
$ diff -u tests/fixtures/import-lazy-lock/golden/imported.plugins.json imp-before.json && echo SAME
SAME
$ diff -u tests/fixtures/import-lazy-lock/golden/imported.plugins.json imp-after.json
@@ -9,9 +9,7 @@
     "synthetic": true
   },
   "localPlugins": {
-    "local.nvim": {
-      "dir": "/some/local/path"
-    }
+    "local.nvim": {}
   },
   "plugins": {
```

**それ以外はゼロである**ことも実測した:

```console
$ nvim -l genflake.lua got-before.json fl-before.nix
$ nvim -l genflake.lua got-after.json  fl-after.nix
$ diff -u fl-before.nix fl-after.nix && echo "genflake output: IDENTICAL"
genflake output: IDENTICAL
$ diff -u tests/fixtures/spec-matrix/golden/matrix.flake.nix fl-after.nix && echo "matches the committed flake golden too"
matches the committed flake golden too

$ nvim -l update-summary.lua got-before.json got-after.json fl.json fl.json
nvimx-lock: no plugins updated (all up to date)
```

**生成 `flake.nix` が同一** ⇒ `flake.lock` も動かない ⇒ 再 fetch も再ビルドも無い。
**`update-summary` は 1 行も報告しない** —— #47 が `removed: <name>` を出したのと違い、
本件の差分はユーザーには `git diff` でしか見えない。§7 に上げる。

`checks.extractor-local-dir` の resolve ステップ(`(.localPlugins | keys) == [...]`)は
#56 の前後どちらでも通る。実測:

```console
before rc=0  stderr=0 bytes
  localPlugins: {"bare.nvim":{"dir":"<HOME>/projects/bare.nvim"}, ... 6 keys ...}
after  rc=0  stderr=0 bytes
  localPlugins: {"bare.nvim":{},"dirabs.nvim":{},"dirnoname":{},"dirrel.nvim":{},"dirtilde.nvim":{},"sibling.nvim":{}}
```

キーは 6 件で同一。**#47 の申し送りどおり、既存行は 1 つも動かない。**

### 4.7 check の担当分け

| 軸 | 担当 |
|---|---|
| raw-spec に `dir` がどう載るか(#47 の fixture が持つ 6 エントリ)、そこから先のルーティング | `extractor-local-dir`(#47)。**本件は「その先で記録される値が空であること」を 1 行足す** |
| `resolve.lua` が書く `plugins.json` の**バイト**(spec フィールドのマトリクス) | `resolve-golden`(#29)。golden が動く |
| `--import-lazy-lock` の報告分類と出力 | `resolve-import-lazy-lock`(#25)。golden が動く |
| `localPlugins` を Nix 側が消費する経路(`devDirs` / `unknownDevPluginNames` / 記録値の無視) | `dev-plugins`(#26)。**本件は「無視すべき値が fixture に実在すること」を 1 行足す** |
| runtime で spec の `dir` が `dev.path` に勝つこと | `tests/dev-path-test.lua`(`checks.dev-plugins` の runtime 半分) |
| `lazyNvim` スロット | `resolve-lazy-self`(#49)。無影響 |
| extract の raw-spec スナップショット | `extractor-snapshot`。無影響(`extract.lua` 無変更) |

重ならない。**新 check は作らない** —— 本件の主張は「`resolve.lua` が書く 1 つの値」であり、
その値をバイト単位で固定する check(`resolve-golden`)が既にあるからである(§6.1)。

---

## 5. 実装手順

### 5.1 `lua/nvimx/resolve.lua`

メインループの `dev/dir` 分岐の中、`local_plugins[name] = { dir = p.dir }` を置き換える。
以下は stylua(`stylua.toml`)と luacheck(`.luacheckrc`)を**実際に通した形**である
(`stylua --check` が clean、luacheck が 0 warnings / 0 errors。120 桁超えの行は 1 行も増えていない):

```lua
    -- #56: the entry is deliberately empty. make-env.nix only ever asks this map for its names --
    -- builtins.attrNames for devDirs, `? name` for unknownDevPluginNames -- and never for a
    -- value, so the dir lazy resolved never decided anything, while recording it put a path off
    -- the machine that ran the lock into a file users commit. Several separate pieces of code can
    -- put one there, which is why this is fixed by writing nothing rather than by filtering: a
    -- dir the spec wrote is normed at lua/lazy/core/meta.lua:217, whatever its spelling
    -- (absolute, "~", relative, or built out of stdpath); a string dev.path -- `~/projects` by
    -- default -- is normed back at config.lua:287-288 and meta.lua:230 only appends `/<name>` to
    -- it; and a *function* dev.path skips that guard entirely and is normed at meta.lua:231.
    -- Nor does the spec entry decide who is subject to those: dev.patterns turns a plugin that
    -- wrote neither dir nor dev, but whose url matches, into a `dev = true` one
    -- (meta.lua:221-228) with the entry untouched. Treat that as the set this file knows of
    -- rather than an exhaustive one -- it is the reason not to keep a list.
    -- An empty object rather than `true` or a bare list of names: it keeps localPlugins an object
    -- keyed by name, the one shape make-env.nix already reads, and it leaves room for a field
    -- that is actually machine-independent should one ever be needed.
    -- The raw-spec `dir` still does its other job -- it is half of the `p.dev or p.dir` test just
    -- above, which is what routed this plugin here (#47) -- it simply stops being written down.
    local_plugins[name] = json.object({})
```

既存の #49 のコメント(*"dev/dir wins over is_lazy ..."*)はこのブロックの**上**にあり、
分岐の条件についての説明なので**触らない**。新しいコメントはその下、代入の直前に置く。

`json` は同ファイル冒頭で `dofile(...)` により束縛済みで、この位置から見える(実測で動作確認済み)。

### 5.2 `flake.nix`(4 箇所)

#### (a) `checks.extractor-local-dir` —— assert を 1 行追加し、コメントを事実に合わせる

**挿入位置**: 同 check のステップ (2) の中、`jq -e '.warnings == []'` の直後。
現在そこにある次のコメントを差し替える:

> Only the *keys* of localPlugins are asserted on, never the recorded dir: nothing in nix/lib
> reads it (#26), and #56 is free to stop recording it without touching this check.

差し替え後(nixfmt / シェルとも既存の書き方に合わせる):

```bash
# The keys above are the whole of what nix/lib reads: make-env.nix only ever asks this map for
# its names (builtins.attrNames for devDirs, `? name` for unknownDevPluginNames), never for a
# value (#26). So #56 stopped writing anything else down -- for three of these six the dir lazy
# resolved came off the machine that ran the lock (bare.nvim's from dev.path, dirtilde's from a
# `~`, sibling's from stdpath), and this file gets committed. This is the only fixture whose
# resolve fills localPlugins with six entries at once -- a bare `dev`, three dir spellings
# (absolute, "~", relative), a shorthand-less dir, and a sibling of lazy's root -- so it is the
# one place "no matter which of those made a plugin local, the entry carries no value" can be
# said. It is deliberately not a list of every way in: a spec that writes `dev = true` *and* a
# dir (that shape is in checks.resolve-golden's fixture, whose golden pins its exact bytes),
# lazy's `virtual = true`, a dev.path aimed back under lazy's own root, and anything
# dev.patterns routes here off a plugin's url alone are all outside this fixture -- which is why
# the assertion is written over whatever localPlugins ended up holding rather than over a set of
# names. A plugins.json committed before #56 still carries the dirs it wrote then, and make-env
# still ignores those -- checks.dev-plugins' fixture is what holds *that* down.
jq -e '[.localPlugins[] | select(. != { })] | length == 0' plugins.json > /dev/null
```

実測(このまま走らせたもの。修正前は落ち、修正後は通る):

```console
before: jq '[.localPlugins[] | select(. != {})] | length == 0' -> FAIL
after : jq '[.localPlugins[] | select(. != {})] | length == 0' -> PASS
```

**`.localPlugins | keys` の既存 assert は 1 バイトも触らない。**

#### (b) `checks.dev-plugins` —— 前提の固定(§3.8)

**守るべき前提は「`dir` が在ること」ではなく「`dir` が `devPath` の答えと違うこと」である。**
既存 assert が空虚化する経路は 2 つあり、両方を塞ぐ:

| 経路 | fixture への変更 | 既存 assert は |
|---|---|---|
| (g1) | `dirred.nvim` の `dir` を削除する(「#56 後の実 lock に合わせる」) | 無視すべき値が消え、**通ってしまう** |
| (g2) | `dir` を `"~/proj/dirred.nvim"` に書き換える | `devPath` の答えと一致し、**通ってしまう** |

fixture の `_comment` 自身が *"deliberately pointing somewhere devPath would never produce"* と
書いているとおり、値の**存在**ではなく**不一致**が本体である。

`let` の `devRoot` の隣に読み戻しを 1 本足す:

```nix
              # Same evaluation-time guard checks.resolve-sources and checks.genflake-golden use:
              # the fixture is a source file, so reading it is a plain readFile and never IFD, and
              # the assertion below is what proves the value it holds still matters. #56 made
              # resolve.lua record `{ }` for every local plugin, so no lock this repo produces
              # still carries a dir here at all, and two edits then make the "recorded dir must be
              # ignored" assertion pass for the wrong reason: strip the fixture's dir to "match
              # reality" and there is nothing left to ignore, or set it to what devPath would
              # produce and reading it would give the same answer as ignoring it. What the dir
              # stands for is a plugins.json committed before #56, a shape make-env has to keep
              # tolerating for as long as anyone still has one checked in.
              dirredRecordedDir =
                (builtins.fromJSON (builtins.readFile ./tests/fixtures/dev-plugins/nvimx-lock/plugins.json))
                .localPlugins."dirred.nvim".dir or null;
```

`failures` の *"a localPlugins entry's recorded dir must be ignored: devPath decides"* の**直後**に:

```nix
                ++ lib.optional (
                  dirredRecordedDir == null || dirredRecordedDir == "~/proj/dirred.nvim"
                ) "the fixture's dirred.nvim needs a recorded dir devPath could never produce"
```

**nixfmt(`nixfmt-rfc-style`)を実際に通してあり、この字下げのまま安定する**(実測。
条件を `let ... in` としてインラインに埋めると nixfmt が chain を崩すので、束縛は `let` に上げてある)。
実測(現物と 2 つの摂動):

```console
$ nix eval --impure --expr '... .localPlugins."dirred.nvim".dir or null ...'
{ dir = "~/elsewhere/dirred.nvim"; fails = false; }     # 今日 -> 通る
(g1) d = null                     -> true               # -> 落ちる
(g2) d = "~/proj/dirred.nvim"     -> true               # -> 落ちる
```

`builtins.readFile` はソースパスに対するもので **IFD ではない**(§3.8 の `nix eval` 実測)。

**実装者への申し送り —— 語彙を発明しないこと。上のコメントがそのまま最終形である。**
`flake.nix` に `builtins.fromJSON` / `builtins.readFile` の使用例は**無い**
(`grep -c 'builtins.fromJSON\|builtins.readFile' flake.nix` が 0)。
一方、**「評価時に source ファイルを読み戻して assert が空虚になるのを防ぐ」パターンには先例が 2 本ある**
—— `checks.resolve-sources` と `checks.genflake-golden` の `goldenFlake` / `goldenFlakes` の束縛で、
どちらも *"a golden is a source file, so importing it is a plain readFile and never IFD, and the derivation
below is what proves the generated flake still equals it"* という**同じ言い回しで no-IFD の理由を説明している**。
上のコメントの 1-3 行目はその言い回しを借りたもので、違うのは
**読む対象が Nix 式ではなく JSON なので `import` が `builtins.fromJSON (builtins.readFile ...)` になる**点だけである。

**`checks.resolve-lazy-self` も `goldenFlake` を `import` しているが、先例には数えない** ——
そちらのコメントは「重複属性が Nix の *parse* エラーであること」と `parseFlakeRef` の話だけで、
**no-IFD にも `readFile` にも言及していない**(実測)。3 本と書くと言い回しの出所を取り違える。

**したがって新しい説明文を書き起こす必要は無い** —— 書き起こせば、この言い回しの **3 本目**として
独自表現が 1 つ増えるだけである。上のコメントをそのまま使うこと。

#### (b2) `checks.dev-plugins` —— `dirred.nvim` assert 直前のコメントの事実訂正

**§5.4 が `make-env.nix` について書き換えさせている主張と、字句レベルで同じものがここにもある。**
`dirred.nvim` の `lib.optional` の直前:

> It is ignored not because it is machine-specific -- **a dir the user wrote absolute is kept verbatim**
> -- but because a spec-level dir short-circuits lazy before dev.path is ever consulted
> (lua/lazy/core/meta.lua:214-217), so reading it could not change any resolved directory.

`make-env.nix` の *"while `dir = "/abs/x"` is kept verbatim"* と同じ「記録される値がどうであるか」の主張で、
**#56 後は今日の resolve が何も記録しないので現在形が偽になる。**

**最終形をそのまま置く**(§8-9 のガードは `kept verbatim` / `recorded verbatim` の**消滅**を要求するので、
「過去形にする」だけでは 2 語が残ってガードと衝突する。**言い換えて 2 語ごと落とす**):

```nix
                # The fixture records dir = "~/elsewhere/dirred.nvim" for this one precisely so that
                # reading it back would produce a different answer. Since #56 resolve.lua records no
                # dir at all, a value here means a plugins.json committed before that change; back
                # then a dir the spec wrote absolute came through unchanged, which is why this one
                # is ignored not for being machine-specific but because a spec-level dir
                # short-circuits lazy before dev.path is ever consulted (lua/lazy/core/meta.lua
                # :214-217) -- reading it could not change any resolved directory. devPath decides,
                # and stays the only thing that does. dirredRecordedDir above is what keeps this
                # value from being "tidied up" into something devPath could produce, which would
                # leave this assertion passing with nothing left to ignore.
```

**確認事項**: `deliberately pointing somewhere devPath would never produce` はこの書き換えで
**言い換えて残っている**(*"keeps this value from being 'tidied up' into something devPath could produce"*)。
§3.8 の (g2) を守っているのは今や `dirredRecordedDir` の `lib.optional` 本体なので、
散文側は理由の説明に徹してよい —— **ただし §8-9 の「残るべき」grep は
`devPath would never produce` を見ているので、その語句自体は fixture の `_comment` 側((b3))に残す。**

#### (b3) `tests/fixtures/dev-plugins/nvimx-lock/plugins.json` の `_comment` —— 同じ 1 文

同じ主張が `_comment` の `dirred.nvim` の段落にもある(*"a dir the user wrote absolute is **recorded
verbatim**"*)。§5.4.1 の 1 点目と**同じ段落**なので、そこで一緒に直す(§5.4.1)。

**この 3 箇所(`make-env.nix` / `flake.nix` / fixture の `_comment`)は同じ主張のコピーである。**
1 つだけ直すと残り 2 つが偽のまま残るので、**§8-9 の guard grep はファイル限定にしない**(§8-9)。

#### (c) `checks.resolve-golden` —— コメントを事実に合わせる

現在の

> A dev plugin has no lock entry and no flake input at all -- that is the whole contract of
> localPlugins, and it is the half that survives #56 whichever way that issue goes (the recorded
> `dir` may stop being recorded; these two do not read it). The golden pins the value; these two
> pin the structure.

を、次の趣旨に書き換える:

- `devel.nvim` に lock エントリも flake input も無いことが `localPlugins` の契約の全部であること(既存)。
- **#56 は記録される値をやめた**ので、golden が今 pin しているのは空オブジェクトであること。
- 下の 2 行はどちらも記録値を読まないので #56 で動かなかったこと(構造の側を pin する役割は不変)。

**`jq` の 2 行は触らない**(`.plugins["devel.nvim"] == null` と `.localPlugins | has("devel.nvim")`)。
golden の byte 一致が値の側を pin しているので、ここに `== { }` を足すのは純粋な重複である(§6.1)。

#### (d) `checks.resolve-import-lazy-lock` —— コメントを事実に合わせる

#47 が足したケース(`raw-spec-dir-only.json` を使うステップ)の

> Keys only, never the recorded dir: #56 must be able to stop recording it without touching this.

を、「#56 は実際に記録をやめ、この行は動かなかった。値の側はステップ 1 の golden が pin している」の趣旨に直す。
**`jq` の行そのものは触らない。**

### 5.3 golden の再生成

**手で編集しないこと。** 2 本は難易度がまったく違うので、それぞれ手順を書く。

#### (1) `tests/fixtures/spec-matrix/golden/matrix.plugins.json`(`checks.resolve-golden`)

手順は `docs/plans/29-genflake-golden.md` §3.9 が持っている
(`tests/fixtures/spec-matrix/raw-spec.json` の `_comment` がそこを指している)。
`versioned.nvim` の URL を一時 git リポジトリに差し替えてから `sed` で戻す往復が要るので、
**§3.9 のスクリプトをそのまま走らせる**のが唯一安全な方法である。
往復を外すとサンドボックスの絶対パスが golden に混入する
(check 自身が `grep -q "$TMPDIR" got.json` で検出するが、再生成の段階で気付くほうが早い)。

**`genflake` の 2 本(`golden/matrix.flake.nix` / `golden/priority.flake.nix`)は再生成不要**である。
§3.9 のスクリプトはステップ 3 でそれも作り直すが、`genflake.lua` は `localPlugins` を読まないので
出力は同一になる(§4.6 で実測済み)。走らせても差分は出ない。

#### (2) `tests/fixtures/import-lazy-lock/golden/imported.plugins.json`(`checks.resolve-import-lazy-lock`)

**`docs/plans/29-genflake-golden.md` §3.9 はこちらを 1 行も扱っていない。**
そちらが扱うのは `spec-matrix` の 3 本だけである。こちらは往復も一時リポジトリも `--lazy` も要らず、
`checks.resolve-import-lazy-lock` のステップ 1 の 1 コマンドをそのまま実行すれば足りる:

```bash
lua=lua/nvimx; fx=tests/fixtures/import-lazy-lock
nvim -l $lua/resolve.lua $fx/raw-spec.json $fx/golden/imported.plugins.json \
  --import-lazy-lock $fx/lazy-lock.json
```

check 側は同じコマンドの出力を `out1.json` に書いて `diff -u $fx/golden/imported.plugins.json out1.json` する。
`git` も `--lazy` も**わざと持たない** check なので、再生成もその 2 つ無しで通ること
(= 通らなければそれ自体が異常であること)を確認すること。**実測でこの 1 本で golden が再現できている**(§4.6)。

#### (3) 期待差分

**§4.6 の 2 ハンクだけである。** それ以外が動いたら止めて原因を追うこと。
`tests/fixtures/spec-matrix/golden/matrix.flake.nix` と `golden/priority.flake.nix` は**動かない**
(§4.6 の実測)。`tests/fixtures/import-lazy-lock/golden/` には `imported.plugins.json` 1 本しか無い。

`tests/fixtures/dev-plugins/nvimx-lock/plugins.json` は**再生成しない**(手書き fixture、§3.8)。
`_comment` 以外は 1 バイトも動かさない。

### 5.4 ドキュメント / リポジトリ内の散文

| ファイル | 現在の記述(アンカー) | 作業 |
|---|---|---|
| `docs/architecture.md` `plugins.json` スキーマの `localPlugins` 行 | `"localPlugins": { "myplugin": { "dir": "/home/you/projects/myplugin" } }` + *"the recorded dir is ignored"* | 例を `{ "myplugin": { } }` にし、コメントを「名前だけを記録する。値は空。make-env は名前を `devPath` に写す」に。**加えて、#56 以前に書かれた lock は `dir` を持ちうるが無視される**ことを 1 節で書く |
| `docs/architecture.md` の `localPlugins` の意味を説明する段落(*"`localPlugins` here means both a spec's own `dev = true` plugins and ..."*) | #47 が書いた説明 | **無変更**。キーの集合の話であり本件は動かさない |
| `docs/architecture.md` `4. **dev.path is a function**` の項 | *"That also keeps the lock's recorded paths — absolute, and `$HOME`-bearing unless the user wrote an absolute `dir` themselves — from having any effect on another machine (the lock still records them; nothing reads them)."* | **この文は #56 で偽になる。** 「lock は名前しか記録しない(#56)。記録が無いので、他人のマシンに影響しうる値がそもそも存在しない。#56 以前に書かれた lock の `dir` も同じく読まれない」に書き換える |
| `README.md` `### Local plugin development` の *"**`devPath` is per-machine, and it is yours.**"* bullet | *"(The lock does still *record* the directory lazy resolved on the machine that ran it; nvimx simply never reads it.)"* | **この括弧書きは #56 で偽になる。** 「lock に入るのは名前だけで、ディレクトリは一切記録されない」に書き換える。**#56 はこの bullet の主張を弱めるのではなく強めるので、括弧の中身を否定形から肯定形にできる** |
| `nix/lib/make-env.nix` の `devDirs` の直前のコメント | *"That also spares us having to care what the recorded value even is: `dev = true` alone records the path lazy derived ... `dir = "/abs/x"` is kept verbatim."* の段落 | 記録される値の 3 分類の説明は **#56 で古くなる**。「#56 以降エントリは空で、キーだけが情報である。#56 以前に書かれた lock は `dir` を持ちうるが、このコードは元から読んでいないので何も変わらない」に置き換える。**`kept verbatim` の 2 語は §8-9 のガードが消滅を要求するので、段落ごと落とすか (b2) と同じ `came through unchanged` に言い換える。** **最後の括弧(`dir` を書いた spec エントリでは `devPath` が効かないこと)は真のままなので残す** |
| `nix/lib/make-env.nix` の `localPlugins` の束縛のコメント(*"tolerant of a plugins.json written before the key existed"*) | — | **無変更**(真のまま) |
| `tests/fixtures/dev-plugins/nvimx-lock/plugins.json` の `_comment` | (下の §5.4.1) | 訂正 |
| `tests/fixtures/spec-matrix/raw-spec.json` の `_comment` | *"devel.nvim writes an absolute `dir` on purpose: lazy would otherwise derive one from dev.path and Util.norm would expand ~ against the extracting machine's $HOME. If #56 changes what resolve.lua records in localPlugins, regenerate golden/matrix.plugins.json -- the check's own two jq assertions about devel.nvim are written not to depend on the recorded value."* | **申し送りを discharge する**。**置換するのは *"devel.nvim writes an absolute `dir` on purpose: … not to depend on the recorded value."* の 1 文だけ**で、`_comment` の他の行 —— とりわけ最終行の *"Regenerating the goldens: see docs/plans/29-genflake-golden.md §3.9."* —— は**残す**(§5.3 (1) がまさにその行に依拠している。§8-9 の `If #56 changes` の grep はこの行の消失を検出できない)。置換後に書くのは次の 3 点だけ:(a) #56 で実際に変わり、`golden/matrix.plugins.json` を再生成したこと。(b) この fixture に残る `dir` の役割は **`resolve.lua` の `p.dev or p.dir` 分岐に `devel.nvim` をルーティングすること**だけであり、絶対パスにしてあるのは実 extract が出す形を模すためであること。(c) 2 つの jq は記録値を読まないので動かなかったこと。**`~` と `$HOME` の話は書かない**(下の注) |
| **`tests/fixtures/local-dir-config/init.lua` のヘッダコメント** | *"nvimx records exactly what lazy produced and absolutizes nothing -- doing otherwise would make nvimx point somewhere lazy does not."* | **#56 後は目的語が曖昧になる。** この文は `dirabs` / `dirtilde` / `dirrel` の 3 綴りの直後にあり、**raw-spec の話としては今も真**(`checks.extractor-local-dir` のステップ 1 がその 3 つの値を逐語で assert している)だが、`plugins.json` の話として読むと **#56 後は偽**(何も記録しない)。**主語を raw-spec に固定する 2 語を足すだけにする**: *"nvimx records exactly what lazy produced **in the raw-spec** and absolutizes nothing"*。同ファイルの他の記述(`dev.fallback is false and nothing checks` を含む)は真のままなので触らない |
| `tests/dev-path-test.lua` の `dirred.nvim` の assert のコメント | *"If a seed bump ever stopped short-circuiting, the rationale for not reading localPlugins[*].dir would collapse -- and this line would go red"* | 「記録された `dir` を読まない理由」は #56 で「そもそも記録が無い」に変わるので、この一節だけを言い直す。**この行が pin している事実(spec の `dir` が `dev.path` に勝つ)は不変**であり、それが崩れたときに壊れるものは #56 の前後で変わらない: 「seed が短絡をやめたら `devPath` が spec の `dir` を上書きし始め、option description が約束している例外(`dir` を書いた spec エントリには `devPath` が適用されない)が破れる」。**「#56 が何も失わなかった理由がこれである」とは書かない** —— #56 が何も失わなかった理由は「読み手が 1 つも無かった」ことであって、短絡はその一部(`make-env` が読まなくてよい理由、#26)にすぎない |
| `README.md` の `## Options` の `devPath` 行 / `devPlugins` 行 | — | **無変更**(記録値に言及していない) |
| `nix/home-manager/default.nix` の 2 つの option description と `unknownDevPluginNames` の警告文 | — | **無変更**(記録値に言及していない。`grep -rn 'record' nix/home-manager/default.nix` が該当ゼロ) |
| `docs/architecture.md` の fixtures 一覧 / checks 一覧 | — | **無変更**(新規 fixture も新規 check も無い) |
| `docs/plans/*.md` | — | **編集しない。** 計画書は 1 度きりのコミットで記録された判断であり、14 本すべてがそう扱われている(`docs/plans/49-lazy-nvim-collision.md` §1.2.1、`docs/plans/47-dir-without-dev.md` §5.5)。#47 §4.2 の申し送りへの回答は本計画 §4.2 が持つ |

**`spec-matrix/raw-spec.json` について `~` / `$HOME` を書いてはならない理由(注)。**
既存の `_comment` の 1 文目 —— *"lazy would otherwise derive one from dev.path and Util.norm would expand ~
against the extracting machine's $HOME"* —— は、**この fixture については成り立たない**。
`spec-matrix/raw-spec.json` は**手書きの raw-spec** であり、`extract.lua` も lazy の `Util.norm` も一度も通らない。
`"dir": "~/x"` と書いてもリテラルの `~` がそのまま `resolve.lua` に渡るだけで、`$HOME` は展開されない
(そして #56 後は `plugins.json` に写りすらしない)。`$HOME` 混入が起きうるのは
**extract 経路(`local-dir-config` のような本物の config)だけ**である。
1 文目は #29 が「extract ならこうなるから、それに合わせて絶対パスにした」という**動機**として書いたものだが、
#56 後は「記録されないのだから動機ごと消えた」と読めてしまう。
**したがって `~` / `$HOME` には触れず、上の (b) の「ルーティング信号としてだけ要る」に一本化する。**
そうしないと、計画が §3.7 で引いた「raw-spec の `dir` と `plugins.json` の `dir` は別物」という線が
コメント側で崩れる。

#### 5.4.1 `tests/fixtures/dev-plugins/nvimx-lock/plugins.json` の `_comment`

**データは 1 バイトも動かさない。** `_comment` は `make-env.nix` が読まないトップレベルの余剰キーなので、
`checks.dev-plugins` の出力も動かない。訂正するのは次の 3 点:

1. `dirred.nvim` の段落。**残すもの / 直すものが同じ段落に同居している。**
   - **残す**: *"deliberately pointing somewhere devPath would never produce, so the check fails loudly if
     anyone starts reading it"* —— これが (g2) を防いでいる唯一の文である。**絶対に消さない。**
   - **直す**: *"It is ignored not because it is machine-specific -- a dir the user wrote absolute is
     **recorded verbatim**"*。`make-env.nix` と `flake.nix` にある同じ主張のコピーであり(§5.2 (b2) / (b3))、
     **#56 後は現在形として偽になる** —— 今日の resolve は `{ }` しか書かない。
     **単に過去形にするのでは足りない**: §8-9 のガードは `kept verbatim` / `recorded verbatim` の
     **消滅**を要求するので、`was recorded verbatim` と書くと 2 語が残って衝突する。
     **(b2) と同じ言い換え(`came through unchanged`)で 2 語ごと落とす。** 最終形:

     > It is ignored not for being machine-specific -- back when a lock still recorded a dir, one
     > the spec wrote absolute came through unchanged -- but because a spec-level dir
     > short-circuits lazy before dev.path is ever consulted (lua/lazy/core/meta.lua:214-217), so
     > reading it could not change any resolved directory.

     後半の短絡の説明(`lua/lazy/core/meta.lua:214-217`)は真のままなので**そのまま残す**。
   - **足す**: **#56 以降この形は実 lock が出せない**ので何を代表しているのか(=「#56 以前にコミットされた
     plugins.json」)と、`failures` に足した前提固定(§5.2 (b))への参照 ——
     **`dir` を消しても `~/proj/dirred.nvim` に書き換えても上の assert が空虚になる**ので、
     そちらがこの値そのものを守っていること。
2. `bare.nvim` の段落。#47 が「病的な `dev.path` 設定でだけ実 lock も出しうる」と書き足した箇所は
   **#56 で「これがすべてのエントリの形になった」に格上げされる**。
   `v.dir` を `or` 無しで読む実装をここで落とす、という本来の目的は不変。
3. 最終段落 *"What a real lock *does* produce is a dir-bearing entry like dirred.nvim -- either the path lazy
   derived from dev.path, or the one the spec wrote ... A plugin that sets `dir` without `dev` at all now
   produces exactly that shape too (#47)."* は **#56 で丸ごと偽になる。**
   「#56 以降、実 lock が出すのは `bare.nvim` の形だけである。`dirred.nvim` は #56 以前の lock を代表する」
   に書き換える。

### 5.5 触らないもの

- **`lua/nvimx/extract.lua`** —— §3.7。raw-spec の `dir` はルーティング信号として必要。**1 バイトも変えない。**
- **`lua/nvimx/genflake.lua` / `update-summary.lua` / `json.lua` / `version.lua` / `source.lua`** —— 無関係。
- **`nix/lib/` 以下のコード** —— §3.1。`make-env.nix` は**コメントのみ**変更する。`bootstrap.lua.in` は無関係。
- **`nix/home-manager/default.nix`** —— §5.4。
- **`localPlugins` が空の 16 本と、raw-spec 2 本のうち `lazy-self/raw-spec-devpin.json`** ——
  §4.6 で「動かない」と実測したもの。特に `tests/fixtures/golden/basic-config.raw-spec.json`、
  `lazy-self/` の fixture 6 本と golden 2 本、`merge/**`、`update/**`、`source-urls/golden/**`、
  `import-lazy-lock/raw-spec*.json` と `prev.json`。
- **`tests/fixtures/local-dir-config/init.lua` の *大部分*** —— #47 の fixture。spec も、
  プラグインごとの説明も触らない。**ただし 1 文だけ §5.4 で明示的に直す**(据え置きではない)。
- **`checks.extractor-local-dir` の既存 assert(ステップ 1 の `jq -e` 群、ステップ 2 の keys、ステップ 3-5)** —— §4.6。
  **本件が足すのはステップ 2 の末尾の 1 行だけで、既存の assert は 1 つも編集しない**(§5.2 (a))。
- **`stylua.toml` / `.luacheckrc`** —— 編集しないので `nix fmt -- --clear-cache` は不要。
- **`.claude/skills/`** —— 触らないので `nix run .#skills-install` は不要。
- **`.github/workflows/*`** —— check の本数が増えないので何も要らない。

### 5.6 リポジトリに入る散文の全件照合

**§5 が「書け」と指示した文章を全部並べ、本計画の本文と食い違っていないかを最後にまとめて確認する。**
`docs/plans/47-dir-without-dev.md` の計画レビューで 4 巡連続して出た欠陥への対策である。

**この表は 3 度やり直してある。** 経緯そのものが方式の根拠なので残す:

- **初版**は「主張 → 根拠 → OK」方式で、コメントの `all six shapes` を
  「§1.6 の表 → OK」と監査して通した(当時の §1.6 の表は 7 行、fixture は 6 エントリで、そもそも軸が違った)。
- **2 版**は「主張のどの語がどの実測に対応するか」を**語単位で当てる**方式に変え、
  初版が OK を出していた 4 件を赤にした(下の「Three ways in」/「that shape is in …」/「two edits」/
  `dev-plugins` fixture の `_comment` の 4 行)。
- **3 版**は、2 版が**引用の中の `file:line` を検査語に含めていなかった**ために
  `Util.norm expands a spec's own ~ against $HOME (lua/lazy/core/meta.lua:216-217, :229-237)` という
  **偽の citation** を通したことを受けて、**`file:line` を独立した検査軸に格上げした**(下の `config.lua:287-288` の行)。
  そのとき同時に、§1.6 の表が `dev.patterns` 経由の経路を落としていたため
  「every way in」を主張していた列挙も赤になった(下の「every way in ではない」の行)。

- **4 版(現行)**は、3 版が row 2 の根拠を **「§1.1 に 3 例が存在する」という存在の実測**で置いていたために
  *"Three ways in, and they are not the same code"* を通したことを受けた。この主張は
  (i) `stdpath` 由来の `dir` も spec が書いた `dir` なので **`meta.lua:217` を通る**(= コードは別でない)、
  (ii) 本当に別コードの **`dev.path` 関数形(`meta.lua:231`)が漏れている**、の 2 点で偽だった。

**教訓は 4 つとも同じ形をしている**: 照合表が「本文の表」や「例が存在すること」を根拠にしていると、
**その表や例が不完全なときに照合表も一緒に間違える**。したがって現行の方式では次の 2 つを守る:

1. 検査語ごとに **seed の実ファイルか、プロトタイプの実測出力か、`grep` の生の出力**のどれかを根拠に置き、
   「§x.y の表」だけを根拠にした行を残さない。
2. **根拠の種類が主張の強さに足りているかを、判定と別に検査する。**
   コメントが「N 通りである」「every way in ではこれで全部」のような**網羅を主張する**なら、
   根拠は**全数え上げ**(その値を作りうる代入箇所を `grep` で全部出し、1 つずつ潰す)でなければならない。
   **例が N 個見つかったことは、N 個しか無いことの根拠にならない。**
   網羅を主張しない書き方(非閉包形)に直せるなら、そちらを優先する ——
   §5.1 と §5.2 (a) はどちらも 4 版で非閉包形に揃えた。

| # | どこに書くか | 検査した語(**`file:line` を含む**) | 対応する実測 / 生の根拠(**網羅を主張する語には全数え上げを要求する**) | 判定 |
|---|---|---|---|---|
| 1 | `resolve.lua`: *"make-env.nix only ever asks this map for its names -- builtins.attrNames for devDirs, `? name` for unknownDevPluginNames -- and never for a value"* + `extractor-local-dir`: *"The keys above are the whole of what nix/lib reads"* | `attrNames` / `? name` / **2 箇所であること**、および **"nix/lib" というファイルより広いスコープ** | **単一ファイルの読みではなく `nix/` 全体の grep。** `grep -rn 'localPlugins' nix/` は `make-env.nix` の 6 行(コメント 3 + コード 3: `:95` 束縛 / `:109` `builtins.attrNames` / `:118` `? ${n}`)と `home-manager/default.nix:307` の**警告文の散文 1 行**だけを返す —— `nix/lib` に他の読み手は無く、値を読む式は 1 つも無い。あわせて `grep -rn 'localPlugins' lua/` は `resolve.lua:1514` の**書き込み 1 箇所**と `extract.lua` のコメント 2 行だけ(= §1.4 の「書き手 1、読み手 0」) | OK(**5 版で根拠を `nix/` 全体の grep に差し替えた** —— 主張が "nix/lib" というファイルより広いスコープなのに、4 版の根拠は `make-env.nix` 1 ファイルの読みだった。finding 1 と同じ形なので予防的に是正。**結論は変わらない**) |
| 2 | 同: *"Several separate pieces of code can put one there … meta.lua:217 … config.lua:287-288 … meta.lua:231."* + *"Treat that as the set this file knows of rather than an exhaustive one -- it is the reason not to keep a list."* | **数詞を持たないこと**、および挙げた 3 つの `file:line` | **存在の実測ではなく、seed の `lua/` 全体の代入箇所の全数え上げ。** `grep -rn '\.dir *=' <seed>/lua/ \| grep -v '=='` + `grep -rn 'dev_dir *=' <seed>/lua/` の実出力は **8 行**(`meta.lua:215/217/219/230/233/238`、`plugin.lua:341`、`packspec.lua:41`)。`:233` は `:230-231` が作った値をそのまま入れる行なので経路としては (B)/(C) に含み、抽出時に効くのは `meta.lua` の 5 つ。`plugin.lua:341` は `M.load()`(本物の `lazy.setup` 専用)、`packspec.lua:41` は `{ pkg = false }` で無効 —— §1.2 がこの 8 行と 2 つの除外理由をそのまま持つ。`~` を展開しうるのは `meta.lua:217` / `config.lua:287-288` / `meta.lua:231` の 3 つで、`:219` は `/dev/null/<name>`、`:238` は `local_dir` が構造的に除外する | **2 版・3 版・4 版とも赤だった。** 2 版は `$HOME` の 2 経路のみ。3 版は「3 通り、しかもコードが別」と書いたが、**way2(`~`)と way3(`stdpath`)は同じ `meta.lua:217`** で "not the same code" が偽、かつ **`dev.path` 関数形(`meta.lua:231`)が漏れていた**。4 版は根拠を全数え上げに替えたが**その grep が `meta.lua` 1 ファイルに閉じており**、`plugin.lua:341` / `packspec.lua:41` を落として「`meta.lua` の 5 つで全部」という偽の太字を通した —— **rule 2 が防ごうとした形の 5 度目**。5 版で grep を `lua/` 全体に広げ、コメント側の数詞も落とし、**6 版で生の出力が 8 行であること(4 版以来 `:233` を畳んで 7 行と書いていた)に揃えた** |
| 3 | 同: *"dev.patterns turns a plugin that wrote neither dir nor dev, whose url matches, into a `dev = true` one (meta.lua:221-228)"* | **「a plugin that wrote neither dir nor dev」という限定** | `meta.lua:221` は `if plugin.dev == nil and plugin.url then` で、しかも `:216 if plugin.dir` の **else 枝の中**(`:220`)。`dev = false` を書いたエントリにも `dir` を書いたエントリにも当たらない | **4 版は赤だった。** *"turns **any plugin whose url matches** into a `dev = true` one"* は引用した `:221-228` が支えない全称主張で、**§5.6 にこの語を当てた行が無かった**(5 巡目 finding 7) |
| 4 | 同: *"An empty object rather than `true` or a bare list of names"* | `true` / `list` の 2 案 | §3.4(配列と `true` の却下論証は両方 §3.4 にある) | OK(**2 版では `true` の根拠を §3.5 に振っていたが、§3.4 ↔ §3.5 の循環参照だった。§3.4 に本体を置いて解消**) |
| 5 | 同: *"the one shape make-env.nix already reads"* | 「already」 | `builtins.attrNames` も `?` も attrset 専用(nix の言語仕様) | OK |
| 6 | 同: *"it leaves room for a field that is actually machine-independent should one ever be needed"* | 「room」= additive に足せること | §3.4 末尾(`true` からの移行は型変更になる)/ §7 の follow-up | OK |
| 7 | 同: *"The raw-spec `dir` still does its other job -- it is half of the `p.dev or p.dir` test just above, which is what routed this plugin here"* | 「half of」/ 「just above」 | `resolve.lua` の分岐は代入の直前。**関係代名詞は「test」に掛かる**ので「`dir` だけが振り分けている」とは読めない(§1.6 軸 2 #11 の経路を排除しない) | OK |
| 8 | 同: *"(lua/lazy/core/config.lua:287-288)"* / *"meta.lua:230"* / *"(meta.lua:216-217)"* / *"(meta.lua:221-228)"* | **引用した `file:line` そのもの** | pin した seed(`/nix/store/d9jq…-source`)の実ファイルを 1 本ずつ開いて確認: `config.lua:286` は root の norm、`:287-288` が `dev.path` の norm。`meta.lua:230` は文字列形で **norm を呼ばない**(呼ぶのは関数形の `:231`)。`meta.lua:216-217` は `super.dir` があるときだけ走る。`meta.lua:231` は関数形の `dev.path` を norm する唯一の場所。`meta.lua:221-228` が `dev.patterns` のループ | **2 版は赤だった。** 2 版は `Util.norm expands a spec's own ~ against $HOME (meta.lua:216-217, :229-237)` と書かせており、**`dev = true` 単独では `:216-217` は 1 度も走らない**ので citation として偽だった。`config.lua` の言及が計画全体でゼロだったのが原因(major M1) |
| 9 | `extractor-local-dir`: *"the only fixture whose resolve fills localPlugins with six entries at once"* | **「six entries」/「fixture whose resolve」** | **全 fixture の全称否定なので、根拠は §4.6 の全数え上げ。** `tests/` で `localPlugins` を含む **23 本**を分類した結果、非空の `localPlugins` を持つのは 3 本だけで、うち resolve が作るのは `spec-matrix`(1 件)と `import-lazy-lock`(1 件)、`dev-plugins` は手書き lock で resolve を通らない。**6 件を作る fixture は `local-dir-config` 以外に存在しない。** §1.6 の右列は内訳(6 件が何か)を示すだけで、この全称否定は支えない | OK(**初版の「all six shapes」から書き換えたもの。major 1**) |
| 10 | 同: *"for three of these six the dir lazy resolved came off the machine that ran the lock (bare.nvim's from dev.path, dirtilde's from a `~`, sibling's from stdpath)"* | **「three of these six」という限定**と、括弧の 3 つの帰属 | §1.1 の実測。`dirabs.nvim` / `dirnoname` / `dirrel.nvim` はマシン固有ではない(絶対パス 2 件と相対 1 件) | **2 版は赤だった。** 2 版は *"the dir lazy resolved came off the machine that ran the lock"* と**無条件形**で、6 件中 3 件しか該当しないのに全件がそうであるかのように読めた。同じコメントの §5.1 側は「Three ways in」と限定していたのに、§5.2 (a) 側だけ限定が抜けており、**2 版の照合表にはこの語を当てた行が 1 つも無かった**(minor m1) |
| 11 | 同: *"It is deliberately not a list of every way in: ... `dev = true` *and* a dir ..., lazy's `virtual = true`, a dev.path aimed back under lazy's own root, and anything dev.patterns routes here off a plugin's url alone are all outside this fixture -- which is why the assertion is written over whatever localPlugins ended up holding rather than over a set of names"* | **「every way in ではない」と明示していること**、および挙げた 4 例の実在 | §1.6 の軸 2 の実測(`dev.patterns` / root 配下の `dev.path` を実際に走らせた出力)。`virtual` は **`tests/` を含めたリポジトリ全体**で無出力(`grep -rn virtual lua/ nix/ flake.nix docs/architecture.md tests/`)—— 主張が「**この fixture の外**」である以上、対象 fixture が住む `tests/` を検査対象から外しては根拠にならない(5 巡目 finding 2) | **2 版は赤だった。** 2 版は *"It is not every way in: ... A and B"* と**閉じた 2 例の列挙**で、`dev.patterns` と root 配下の `dev.path` が落ちていた。1 巡目 major 1(「all six shapes」)と同型で、**今度は永続コメントに入る手前だった**(major M2)。列挙をやめ、「網羅ではない」と明示したうえで assert が集合ではなく実際の中身に対して書かれている理由に接続した |
| 12 | `dev-plugins` の `dirredRecordedDir` コメント: *"no lock this repo produces still carries a dir here at all"* | 「produces」(これから書く lock) | §3.1 / §4.6 | OK。既存 lock は同コメント後半が扱う |
| 13 | 同: *"two edits then make that assertion pass for the wrong reason: strip ... or set it to what devPath would produce"* | **2 経路であること** | §3.8 の (g1)(g2) と §5.2 (b) の `nix eval` 実測 | **初版は赤だった。** 初版は「`dir` を消す」1 経路しか書かず、しかも理由を "with nothing left to ignore" と (g1) 側だけで説明していた(minor 4) |
| 14 | 同: *"What the dir stands for is a plugins.json committed before #56"* | 「stands for」 | §3.8 の 1 点目 | OK |
| 15 | `resolve-golden` の書き換え後コメント(3 点) | 「golden が空オブジェクトを pin」/「jq 2 行は動かなかった」 | §4.6 の実測(keys-only の assert は不変)/ §6.1 の担当分け | OK |
| 16 | `resolve-import-lazy-lock` の書き換え後コメント | 「この行は動かなかった」/「値はステップ 1 の golden が pin」 | §4.6 の実測。ステップ 1 は `diff -u golden/imported.plugins.json` | OK |
| 17 | `make-env.nix` の書き換え後コメント | 「エントリは空」/「旧 lock の `dir` も読まない」/**`devPath` の括弧を残すこと** | §3.6 / §4.1 | OK。最後の括弧(`dir` を書いた spec エントリに `devPath` は効かない)は #56 と無関係に真なので**削らない** |
| 18 | `docs/architecture.md` の 2 箇所 | スキーマ行の例 / `dev.path is a function` の該当文 | §3.1 / §3.6。§8-9 の grep 3 本(`the lock still records them` / `/home/you/projects/myplugin` / `the recorded dir is ignored`)が消えたことを確認する | OK |
| 19 | `README.md` の bullet の括弧 | 「記録しない」 | §3.1 | OK。**#56 はこの bullet を弱めず強める**ので、否定形の括弧を肯定形にできる |
| 20 | `dev-plugins` fixture `_comment` の 3 点(§5.4.1) | *"pointing somewhere devPath would never produce"* を**残す**こと | §3.8 の (g2)。**この 1 文が (g2) を防いでいる唯一の散文** | **初版は赤だった。** 初版は「`dir` を消すと空虚になる」としか書かず、(g2) を落としていた。3 点目の「実 lock が出すのは `bare.nvim` の形だけ」は §3.1 のとおり真 |
| 21 | `spec-matrix/raw-spec.json` の `_comment`(§5.4 の (a)(b)(c)) | (b) の「`dir` の役割はルーティングだけ」 | §3.7。**`~` / `$HOME` には触れない**(§5.4 の注。この fixture は手書きで `Util.norm` を通らない) | OK(**初版は `~` を書くと `$HOME` が入ると書いており偽だった。major 2**) |
| 22 | `make-env.nix` / `flake.nix` (b2) / `dev-plugins` fixture `_comment` の 3 箇所で、**`kept verbatim` / `recorded verbatim` の 2 語が消えていること** | **書き換え後の文言が §8-9 のガードと両立するか** | §8-9 は `grep -rn 'kept verbatim\|recorded verbatim' flake.nix nix/lib tests/fixtures` が **0 行**を要求する。§5.2 (b2) と §5.4.1 が置く最終形はどちらも `came through unchanged` に言い換えており、2 語を含まない(実測で確認) | **4 版は赤だった。** 4 版は 3 箇所とも「**過去形にする**」としか指示しておらず、最も自然な過去形(`was kept verbatim`)は同じ 2 語を保つので **§8-9 のガードと衝突**した。しかも (b2) / §5.4.1 は §5.2 (b) と違い**最終形の文言を与えていなかった**ため、実装者は「過去形にしろ」と「この語を消せ」のどちらに従うか判断できなかった(5 巡目 finding 2)。3 箇所すべてに最終形を書き下ろして解消 |
| 23 | `local-dir-config/init.lua`: *"nvimx records exactly what lazy produced **in the raw-spec** and absolutizes nothing"* | **足す 2 語**(`in the raw-spec`)が何を排除するか | 元の文は `dirabs` / `dirtilde` / `dirrel` の 3 綴りの説明の直後にあり、raw-spec の話としては真(`checks.extractor-local-dir` のステップ 1 が 3 つの値を逐語で assert)。`plugins.json` の話として読むと #56 後は偽 | **2 版は網の外だった。** 2 版は §5.5 でこのファイルを「据え置き(§5.6 で確認済み)」としていたが、§5.6 の対象は「§5 が書けと指示した文章」なので**据え置き対象は範囲に入らず、確認された行はどこにも無かった**(minor m3)。§5.4 に編集指示として移し、この行で監査する |
| 24 | `tests/dev-path-test.lua` の言い直し | 「短絡が崩れたら `devPath` が spec の `dir` を上書きする」 | §4.1 / option description | OK。**「#56 が何も失わなかった理由がこれ」とは書かない**(理由は「読み手ゼロ」であり短絡はその一部) |

**逆向きの照合 —— 本文が訂正・限定した主張が、コメントに漏れていないか。**

| 本文の訂正・限定 | コメントへの反映 |
|---|---|
| §1.1 「6 件中 **3 件**がマシン固有」 | **「for three of these six」の行で反映済み**(2 版は無条件形だった。m1) |
| §1.2 「`dev = true` の `~` を展開するのは `config.lua:287-288`(文字列形)/ `meta.lua:231`(関数形)であって `meta.lua:216-217` ではない」 | **`config.lua:287-288` の行と「Several separate pieces of code」の行で反映済み**(2 版は偽の citation、3 版は関数形の脱落。M1 / 4 巡目 major 1) |
| §1.5 / §1.1 「issue の 3 分類より被害は広い(サンドボックスパス)」 | **「Several separate pieces of code」の行で反映済み**(初版は落としていた) |
| §1.6 軸 1「fixture が持つのは 11 経路のうち 6 経路」 | **「six entries」の行で反映済み**(初版は落としていた) |
| §1.2 経路 C(`dev.path` の関数形は `meta.lua:231` で norm される) | **「Several separate pieces of code」の行で反映済み**(3 版はこの経路を落としていた。4 巡目 major 1) |
| §1.6 軸 2「`dev.patterns` と root 配下の `dev.path` は spec に手掛かりが無い」 | **「every way in ではない」の行で反映済み**(2 版は列挙を閉じていた。M2)。`resolve.lua` 側にも `dev.patterns` の 1 文を入れた |
| §1.6 「`dev.fallback = true` は `dev = true` を remote に落とす」 | **コメントには書かない。** #56 が変えるものと無関係(そのプラグインは `localPlugins` に来ない)であり、書くと `resolve.lua` のコメントが lazy の `dev` サブツリーの解説になる。本計画 §1.6 と §7 が持つ |
| §3.2 「option 2 を絞り込むと #47 を壊す」 | **コメントには書かない。** 却下案の記録は計画書の仕事で、本件は `extract.lua` に触らないので置き場所が無い。代わりに「The raw-spec `dir` still does its other job」の行が「raw-spec の `dir` はまだ仕事をしている」と言い、`extract.lua` の既存 docstring がその仕事を説明している |
| §3.4 「`true` は additive に足せないので却下」 | **「An empty object rather than `true`」の行で反映済み** |
| §3.5 「由来フラグは今日読み手がいないだけで、形としては塞いでいない」 | **「leaves room for a field」の行で反映済み** |
| §3.8 の (g2)(値が `devPath` の答えと一致する経路) | **「two edits」の行と `dev-plugins` fixture の `_comment` の行で反映済み**(初版は両方落としていた。m4) |
| §5.4 の注「`spec-matrix/raw-spec.json` は `Util.norm` を通らない」 | **`spec-matrix/raw-spec.json` の行で反映済み**(初版は逆のことを書かせていた。M2 / 1 巡目) |
| §5.4 「`local-dir-config` の 1 文は raw-spec の話としてだけ真」 | **`local-dir-config/init.lua` の行で反映済み**(2 版は照合表の範囲外に落ちていた。m3) |
| §1.2 「代入箇所の数え上げは seed の `lua/` 全体でやる(`plugin.lua:341` / `packspec.lua:41` は抽出経路に無い)」 | **「Several separate pieces of code」の行で反映済み** —— コメント側は数詞を落としたので、除外理由まで書く必要が無くなった。除外の論証は本計画 §1.2 が持つ |
| §5.4 / §5.4.1 / §5.2 (b2) 「`kept verbatim` の 2 語は §8-9 のガードと両立しない」 | **`kept verbatim` の消滅を見る行で反映済み**(4 版は「過去形にする」としか書かず衝突していた。5 巡目 finding 2) |
| §7「`virtual` は check していない」 | **「every way in ではない」の行で反映済み**(*"lazy's `virtual = true` ... outside this fixture"*) |
---

## 6. テスト

### 6.1 新 check を作らない理由 / 足す assert は 2 行

本件の主張は「`resolve.lua` が `localPlugins` の各エントリに何も書かない」ことであり、
これを**バイト単位で固定する check は既にある**(`checks.resolve-golden` の `diff -u matrix.plugins.json`、
`checks.resolve-import-lazy-lock` の `diff -u imported.plugins.json`)。
新 check を作れば同じ主張を 3 度目に書くだけになる。

足すのは 2 行だけである:

| check | 足す assert | なぜそこか |
|---|---|---|
| `extractor-local-dir` | `[.localPlugins[] | select(. != { })] | length == 0` | **`localPlugins` 行きのエントリを 6 件まとめて持つ唯一の fixture**(§1.6 の 11 経路のうち 6 経路。`dev` + 明示 `dir` / `virtual` / `dev.patterns` / root 配下の `dev.path` は無い)であり、しかも golden を持たない(#47 §5.2 が `$HOME` 混入を理由に置かなかった)ので、jq でしか言えない。「その 6 通りのどれがローカルにしたかによらずエントリは空」という一般化はここでしか書けない |
| `dev-plugins` | `dirredRecordedDir` が **null でも `~/proj/dirred.nvim` でもない**こと | §3.8。**assert ではなく assert の前提**を固定する。#56 が無ければ要らなかった 1 件で、`dir` の存在だけを見る弱い版だと (g2) が素通りする |

`resolve-golden` / `resolve-import-lazy-lock` には **jq を足さない**。
golden が byte 一致で値を固定しており、`.localPlugins | has(...)` は #47 の構造 assert として既にある。
足すのは重複である(§5.2 (c)(d) はコメントだけを直す)。

### 6.2 摂動 —— 直したものが本当に検出されるか

実装時に 1 つずつ試し、必ず戻すこと(§8-6)。

| # | 摂動 | 落ちるべきもの |
|---|---|---|
| (a) | `resolve.lua`: `local_plugins[name] = { dir = p.dir }` に戻す(= 修正前) | `resolve-golden`(`diff -u matrix.plugins.json`)、`resolve-import-lazy-lock`(`diff -u imported.plugins.json`)、`extractor-local-dir`(新 jq)。**実測で 3 本とも確認済み**(§4.6 の 2 ハンク + §5.2 (a) の FAIL) |
| (b) | `resolve.lua`: `local_plugins[name] = { dev = p.dev or nil }`(= 却下 D、由来フラグ) | 同じ 3 本。`spec-matrix` の `devel.nvim` と `import-lazy-lock` の `local.nvim` は**どちらも `dev: true` を持つ**ので両 golden が `{"dev": true}` になり、`extractor-local-dir` の新 jq は `bare.nvim` で落ちる(同 fixture で `dev` を持つのは `bare.nvim` だけ) |
| (c) | `resolve.lua`: `local_plugins[name] = true`(= 却下 C の亜種) | 同じ 3 本。jq の `. != { }` は `true` に対して真になる |
| (d) | `resolve.lua`: `local_plugins[name] = json.array({})` | 同じ 3 本。golden に `[]` が出て、jq も落ちる。**`json.object({})` と明示する理由がこれ**(§3.1) |
| (e) | `resolve.lua`: 記録そのものをやめる(この行を消す) | `extractor-local-dir` のステップ 2 の `(.localPlugins | keys) == [6 件]`、`resolve-golden` の `.localPlugins | has("devel.nvim")`、`resolve-import-lazy-lock` の #47 ケースの `has("local.nvim")`、両 golden。**新 jq は落ちない**(空集合に対して `length == 0` は真)—— キーを守っているのは既存 assert のほうである |
| (f) | `extract.lua`: `local_dir` を「fragment が書いた `dir`」に絞る(= 却下 A / issue の option 2 を素直に実装) | `extractor-local-dir` のステップ 1 の `.plugins["bare.nvim"].dir == ($h + "/projects/bare.nvim")` と `[.plugins[] | select(has("dir"))] | length == 6`。**実測で `written=nil`**(§3.2 の probe)。**#56 のどの check にも届かない** —— `plugins.json` の側は `{ }` のままだからである。守っているのは #47 の check だけ |
| (g1) | fixture: `tests/fixtures/dev-plugins/nvimx-lock/plugins.json` から `dirred.nvim` の `dir` を**消す** | `dev-plugins` の新しい前提固定。**この 1 件が無いと何も落ちない**(§3.8)——「無視すべき値」が消えるだけで、`devPath` の答えは変わらないため。`nix eval` で実測済み |
| (g2) | 同 fixture の `dirred.nvim` の `dir` を **`"~/proj/dirred.nvim"` に書き換える** | 同上。**`dir` の存在だけを見る弱い guard では素通りする**ので、条件を「null でも `~/proj/dirred.nvim` でもない」にしてある(§3.8 / §5.2 (b))。`nix eval` で実測済み |
| (h) | `make-env.nix`: `devDirs` が記録値を読むようにする(`localPlugins.${n}.dir or "${devPath}/${n}"`) | `dev-plugins` の *"a localPlugins entry's recorded dir must be ignored: devPath decides"* と *"every devDirs value must sit under devPath"*。**既存のガード**で、本件はそれを (g1)(g2) で守るだけ |
| (i) | `resolve.lua`: `schemaVersion = 2` にする | `plugins.json` 系の全 golden(`base` / `matrix` / `imported` / `ok` / `tag` / `update-pinned`)と、`resolve-merge` の 2 パス目(`--prev pass1.json` が `schemaVersion 2` を拒否する)。**既存のガード**。§3.6 の決定はこれで守られている |

**摂動 (a)-(e) は `resolve.lua` の摂動なので、resolve を走らせる check にしか届かない。**
`checks.dev-plugins` は手書きの `nvimx-lock/plugins.json` を `makeEnv` に渡すだけで resolve を走らせないので、
**(a)-(e) はどれも `dev-plugins` には届かない**。逆に (g1)(g2)(h) は `dev-plugins` にしか届かない。
`checks.resolve-lazy-self` は `localPlugins` について `has("lazy.nvim")` しか見ず、その golden の
`localPlugins` は `{}` なので、**(a)-(e) はどれも `resolve-lazy-self` には届かない**(§4.6 で実測)。
`checks.extractor-snapshot` は `extract.lua` の出力しか見ないので、(a)-(e)(g1)(g2)(h)(i) はどれも届かない。

### 6.3 §3 の全決定 × 摂動の照合表

**空欄はゼロにしてある。** 対応が無い決定は、摂動を足すか「なぜ摂動できないか」を書くかのどちらかにしてある。

| §3 の決定 | ガード | 摂動 |
|---|---|---|
| §3.1 `localPlugins` の各エントリは値を持たない | `resolve-golden` / `resolve-import-lazy-lock` の golden + `extractor-local-dir` の新 jq | **(a)(b)(c)(d)** |
| §3.1 キーは消さない(`make-env` が読む唯一の情報) | `extractor-local-dir` の keys、`resolve-golden` の `has("devel.nvim")`、`resolve-import-lazy-lock` の `has("local.nvim")` | **(e)** |
| §3.1 `json.object({})` と明示する(空配列に化けさせない) | 両 golden + 新 jq | **(d)** |
| §3.2 却下 A(`extract.lua` の `dir` を絞る) | `extractor-local-dir` のステップ 1(#47 の既存 assert) | **(f)**。実測で `written=nil` を確認済み |
| §3.2 却下 A で `virtual` の分類が反転すること | — | **無し(既存の穴)**。`virtual` の fixture は存在しない。#47 §7 が「今日から挙動が変わるが check していない」と既に記録しており、**本件はその穴を広げも狭めもしない**(`extract.lua` に触らないため)。§7 に再掲 |
| §3.3 却下 B(`dirFromSpec` を足す) | — | **無し**。却下案はコードにならない。却下の実測根拠(`dev = true` 単独では `written=nil`)は §3.2 の probe が持つ |
| §3.4 却下 C(名前の配列にする) | 両 golden(`[]` が出る)+ 新 jq | **(d)** が同じ形を通る。map そのものを配列にする摂動は `make-env.nix` の同時変更が要るので単独では試さない |
| §3.5 却下 D(由来フラグを入れる)= `dev` と `dir` の区別を潰す | 両 golden + 新 jq | **(b)** |
| §3.6 `schemaVersion` は 1 のまま | `plugins.json` 系 golden 6 本 + `resolve-merge` の 2 パス目 | **(i)**(既存のガード) |
| §3.6 新 resolve は旧 `plugins.json` を `--prev` で問題なく読む | — | **無し(構造的に摂動できない)**。「読まない」ことを壊す摂動は「読むコードを足す」ことだが、`prev.localPlugins` を読む機能は存在しないので追加は仕様変更そのものである。代わりに §1.4 のキー集合(トップレベル `prev` が読むのは `schemaVersion` / `plugins` / `lazyNvim` の 3 つだけ)と §1.4 の実測(仕込んだ `ghost.nvim` が引き継がれない)を根拠とする |
| §3.6 旧 nvimx が新 `plugins.json` を読める | `checks.dev-plugins`(fixture が `bare.nvim: {}` と `dirred.nvim: {dir}` を**同時に**持ち、両方に `~/proj/<name>` を要求している) | **無し(既存 check が兼ねる)**。空エントリを受け付ける経路は #26 以来ずっと緑である |
| §3.7 `extract.lua` は無変更 | `extractor-snapshot` の golden(byte 一致)+ `extractor-local-dir` のステップ 1 | **(f)**。`extract.lua` を触る摂動はすべてここで落ちる |
| §3.7 raw-spec の `dir` はルーティング信号として残る | `extractor-local-dir` のステップ 2-5 | **(f)** |
| §3.8 `dirred.nvim` の記録 `dir` は「存在する」だけでなく「`devPath` の答えと違う」こと | `dev-plugins` の新しい前提固定 | **(g1)(g2)**。**この 1 件を足さないと 2 経路とも無検出**であり、`dir` の存在だけを見る弱い版では (g2) が素通りする |
| §3.8 `make-env.nix` は記録値を読まない | `dev-plugins` の既存 2 行 | **(h)** |
| §4.6 生成 `flake.nix` / `flake.lock` が動かない | `genflake-golden`(`matrix.flake.nix` / `priority.flake.nix` の byte 一致)。**`resolve-golden` が `diff -u` するのは `matrix.plugins.json` 1 本だけで、flake 側は見ていない** | **無し(専用の摂動は不要)**。`genflake.lua` は `localPlugins` を読まないので、本件のどの摂動も flake 側を動かせない。実測で同一を確認済み(§4.6) |
| §4.6 `update-summary` に差分が出ない | `checks.update-summary` の golden 3 本 | **無し(専用の摂動は不要)**。`update-summary.lua` は `localPlugins` を読まない(§1.4)。実測で `no plugins updated` を確認済み |
| §3.4 却下 C の亜種(`localPlugins.<n> = true`) | 両 golden + 新 jq | **(c)** |
| §1.2 経路 C(`dev.path` の関数形。norm は `meta.lua:231` でしか起きない) | — | **無し(意図的)**。§1.6 軸 2 #10。`dev.patterns` と同じ理由で fixture を足さない(独立 fixture が固定するのは経路の存在であって #56 の主張ではない)。**ただし `tests/dev-path-test.lua` が文字列形 / 関数形の非対称そのものは runtime で固定している** —— そちらは #26 の担当軸で、#56 は触らない |
| §1.6 軸 2「`dev.patterns` / root 配下の `dev.path` も `localPlugins` を埋める」 | — | **無し(意図的)**。案は 2 つとも潰してある(§7)。(i) `local-dir-config` に足すと `length == 6` / `(.plugins | keys)` / `has("dir") | not` の 3 行が同時に動き、**#47 の check を #56 が書き換える**(§2 ゴール 2 を優先)。(ii) 独立 fixture + 専用 check なら `extractor-local-dir` に触らず足せるが、それが固定するのは**「この経路が存在すること」(#47 / #26 の担当軸)**であって #56 の主張ではない。**#56 の主張はこの経路にも成り立つ** —— 値を書かないので経路に依存しない —— ので、固定できていないのは「成り立つこと」ではなく「この経路が存在すること」である。§8 の手動確認 7 と §7 の follow-up が代替 |
| §1.6 軸 2 #11(root 配下の `dev.path`)が今日すでに `{ }` を出すこと | `checks.dev-plugins` の `bare.nvim` エントリ(`{}` を受け付ける経路) | **無し(既存 check が兼ねる)**。#47 §7 が「fixture を作れば病的挙動を契約として固定してしまう」として意図的に作らないと決めた経路であり、本件もその判断を引き継ぐ。独立 fixture を作らない理由は `dev.patterns` の行と同じ(固定できるのは経路の存在であって #56 の主張ではない) |
| §5.3 golden を手編集せず再生成する | — | **無し**。手順の話なので摂動できない。§8-5 の「差分が §4.6 の 2 ハンクだけ」で確認する |
| §5.4 散文の訂正 | — | **無し**。ドキュメントは摂動できない。§5.6 の照合表と §8-9 の grep で確認する |
| §6.1 新 check を作らない | — | **無し(意図的)**。不作為は摂動できない。根拠は §4.7 の担当分け |

**「無ガードゼロ」ではない。** 正確な内訳は
「10 件のコード / fixture 摂動((a)-(f)(g1)(g2)(h)(i))+ 構造的に摂動できない決定 1 件(§3.6 の prev 読み)+
既存 check が兼ねる決定 3 件 + そもそも摂動できない決定(却下案・不作為・ドキュメント・手順)」である。
**「意図的に守らない」と倒した決定が 3 件あり**(§3.2 の `virtual`、§1.6 軸 2 の `dev.patterns`、
§1.6 軸 2 #11 の root 配下 `dev.path`)、いずれも「fixture を足すと #47 の check を書き換えることになる」
という同じ理由で倒している。3 件とも §7 に follow-up として残し、§8 の手動確認 7 が
`dev.patterns` の 1 件だけを人手で覆う。
うち **(f) は #56 の check には 1 つも届かない** —— これは欠陥ではなく担当分けであり、
#47 の check が守っている決定を本計画が §3.7 で援用しているだけである。
`docs/plans/47-dir-without-dev.md` §6.2.1 が確立した規則
(「extract の摂動は手書き raw-spec の check には届かない」)の、本件における対応物である。

### 6.4 既存 check への影響

**期待差分は golden 2 本の 1 ハンクずつだけ**(§4.6 で実測)。それでも §8-3 で
`resolve-golden` / `resolve-import-lazy-lock` / `extractor-local-dir` / `dev-plugins` /
`resolve-lazy-self` / `resolve-merge` / `resolve-update` / `update-summary` / `resolve-sources` /
`genflake-golden` / `extractor-snapshot` / `resolve-semver` / `hm-module-dev` を個別に build して確認する。

`extractor-snapshot` は `extract.lua` の出力を byte 単位で固定している唯一の check であり、
本件が `extract.lua` に触らないことの実証になるので特に重要である。

---

## 7. リスク / 未決事項

- **アップグレード後の初回 lock で `plugins.json` に差分が出る。**
  `localPlugins` の各エントリから `"dir"` 行が消える。**それだけである** ——
  生成 `flake.nix` は同一、したがって `flake.lock` も同一で、再 fetch も再ビルドも起きない(§4.6 で実測)。
  `--update` で走らせても `update-summary` は `no plugins updated (all up to date)` と言うだけで、
  この変化を 1 行も報告しない(実測)。**#47 が `removed: <name>` を出したのと対照的に、
  本件の差分はユーザーには `git diff` でしか見えない。**
  したがって **v0.2.0 のリリースノートに「lock フォーマットの変更」として明記すること**:
  「`localPlugins` のエントリからマシン固有の `dir` が消えます。初回の再 lock で 1 度だけ差分が出ますが、
  `flake.lock` は動かず再ビルドも起きません。`schemaVersion` は 1 のままで、
  新旧どちらの nvimx もどちらの lock も読めます。」
- **本件は既存の lock ファイルを書き換えない。** ユーザーが再 lock するまで、コミット済みの `plugins.json` には
  他人の `$HOME` が残り続ける。nvimx が勝手に書き換えることはしない(lock は明示的なコマンドである)。
  リリースノートで再 lock を促す以上のことはしない。
- **診断情報を 1 つ失う。** issue の option 1 の但し書きどおりである。
  失うのは「lazy が解決したディレクトリ」で、名前が間違って見えるときに確認できた値である。
  ただし §3.3 のとおり、**問題が一番大きい `dev = true` 単独の場合、option 2 でも同じものは残らない**。
  spec が書いた `dir` はユーザーの `init.lua` にあり、runtime では `:Lazy` が実際の解決先を表示する。
  **代替の確認手段はある**と判断した。
- **「ローカルプラグインの由来」を機械可読に残したくなったら、`{ }` にフィールドを足せる。**
  想定される用途は「spec が `dir` を書いたエントリに `devPlugins` を指定しているユーザーへの警告」
  (今日 `devPath` は効かないのに、それが分かるのは README の散文だけである)。
  §3.5 で却下したのは「今日それを読む消費者がいない」からであって、形として塞いだわけではない。
  エントリをオブジェクトのままにしたのはこのためである。**follow-up issue の候補。**
- **`checks.dev-plugins` の fixture が「実 lock が出せない形」になる。**
  §3.8 のとおり、それを維持するための前提固定を 1 行足す。
  それでも「fixture を実物に合わせる」提案は将来また出るはずなので、
  `_comment` に**何の代表なのか(= #56 以前にコミットされた lock)**を明記する(§5.4.1)。
- **`virtual = true` なプラグインが `localPlugins` に入ることは check されていない。**
  #47 §7 が記録した既存の穴で、本件は `extract.lua` に触らないので広げも狭めもしない。
  ただし §3.2 の probe で「却下案 A を採ると `virt.nvim` がリモートに移る」ことが**実測で分かった**ので、
  この穴が塞がれていないことの実害が 1 段はっきりした。`virtual` の fixture を足すのは
  **本件のスコープ外**だが、#47 §7 の記録を補強する事実として残す。**follow-up issue の候補。**
- **`dev.patterns` 経由でローカルになるプラグインも check されていない ——
  そしてこちらは病的な設定ではない。** `dev = { patterns = { "folke" } }` は
  lazy 自身が既定値の脇に例として書いている公開オプション(`lua/lazy/core/config.lua:75`)で、
  `extract.lua` の `safe_opts` に `dev` キーが無い以上、抽出時に生きている(§1.6 軸 2 #9)。
  実測では `{ "folke/tokyonight.nvim" }` —— `dev` も `dir` も書いていないエントリ —— が
  `$HOME` 入りで `localPlugins` に記録された。**#56 はこれも同時に直す**(値を書かないので、
  どの経路で来たかによらない)が、**それを固定する fixture も check も無い。**
  **案は 2 つあり、両方とも潰してある。**
  (i) `local-dir-config` に opts を 1 行足す案は、同 fixture の 6 エントリという前提と
  `checks.extractor-local-dir` のステップ 1 の `length == 6` /
  `(.plugins | keys) == ["tokyonight.nvim"]` / `.plugins["tokyonight.nvim"] | has("dir") | not` を
  **同時に**動かす(`tokyonight.nvim` がローカル側へ移るため)ので、#47 の check を #56 が書き換えることになる。
  **本件はエントリ数を 1 つも動かさないという約束(§2 ゴール 2 / §4.2)を優先する。**
  (ii) **独立 fixture + 専用 check なら `extractor-local-dir` に 1 バイトも触らずに足せる。**
  それでも足さないのは、その check が固定するのが**「この経路が存在すること」**
  —— すなわち #47(どれがローカルになるか)と #26(それを Nix 側がどう消費するか)の担当軸 ——
  であって、**#56 の主張(値を書かない)ではない**からである。#56 の主張はこの経路にも成り立つが、
  それは経路に依存しない性質なので、経路ごとに fixture を足しても新しく固定できる事実は 1 つも無い。
  代わりに §8 の手動確認にこの経路を 1 件入れてある。**follow-up issue の候補**(#47 §7 の
  `virtual` と同じ「`p.dev` を真にする経路のうち fixture が無いもの」という括りで 1 本にできる)。
- **`dev.fallback = true` は逆に `dev = true` を remote へ落とす**(`meta.lua:232-235`。実測は §1.6)。
  #56 とは無関係(そのプラグインは `localPlugins` に来ない)だが、
  §1.6 軸 1 #1 の「必ず `<HOME>/projects/x.nvim`」が既定値限定の主張であることの根拠なので記録する。
- **`_.frags` を使う診断は将来も選択肢として残る。** §3.3 で却下したのは費用対効果であって、
  機構が使えないからではない(§3.2 の probe で動くことを確認済み)。
  ただし採るなら **`dir` を絞り込まず別フィールドを足す**形でなければならない(#47 §4.2 / 本計画 §3.2)。
  この制約は #47 の申し送りとして既に記録されており、本件はそれを実測で追認しただけである。
- **`localPlugins` が空オブジェクトの map になることの見た目。** `{"a":{},"b":{}}` は
  配列にしたくなる形だが、§3.4 のとおり型を変えると旧 nvimx が読めなくなる。
  **見た目のために互換性を捨てない**という判断であり、`schemaVersion` を上げてよい機会
  (non-additive な変更が別途必要になったとき)に一緒に検討するのが安い。
- **`resolve.lua` の変更は 1 行だが、golden は 2 本動く。** レビュー時に
  「この 2 ハンク以外が動いていないこと」を必ず確認すること(§8-5)。
  特に `matrix.plugins.json` の再生成は一時 git リポジトリの往復を伴うので、
  手順を外すとサンドボックスのパスが golden に混入する(check 自身がその検出を持っているが、
  再生成の段階で気付けるほうが早い)。

---

## 8. 検証手順(実装完了時に必ず全部通す)

**計画レビューで一部が実行済みであっても、実装後に全手順を改めて通すこと。**

```bash
# 0. リポジトリルートで。新規ファイルは無いが、golden 2 本が変更されていること
cd /home/myuron/ghq/github.com/myuron/nvimx
git status --short

# 1. CI と同一の 2 本(CLAUDE.md の Commands より)。これが通ることが必須条件
nix flake check
nix fmt -- --ci

# 2. 値そのものを見る check(失敗時の切り分け用)
nix build .#checks.x86_64-linux.resolve-golden -L
nix build .#checks.x86_64-linux.resolve-import-lazy-lock -L
nix build .#checks.x86_64-linux.extractor-local-dir -L
nix build .#checks.x86_64-linux.dev-plugins -L

# 3. 影響が無いと §4.6 で実測した既存 check。無影響であることを個別に確認する。
#    extractor-snapshot は extract.lua に触っていないことの実証なので特に重要
nix build .#checks.x86_64-linux.extractor-snapshot
nix build .#checks.x86_64-linux.extractor-defaults-version
nix build .#checks.x86_64-linux.extractor-no-setup
nix build .#checks.x86_64-linux.resolve-lazy-self
nix build .#checks.x86_64-linux.resolve-merge
nix build .#checks.x86_64-linux.resolve-update
nix build .#checks.x86_64-linux.resolve-semver
nix build .#checks.x86_64-linux.resolve-sources
nix build .#checks.x86_64-linux.update-summary
nix build .#checks.x86_64-linux.genflake-golden
nix build .#checks.x86_64-linux.hm-module-dev

# 4. darwin 評価(linux の nix flake check は darwin を omit するため必須。CLAUDE.md)
nix eval .#checks.aarch64-darwin.resolve-golden.drvPath
nix eval .#checks.aarch64-darwin.resolve-import-lazy-lock.drvPath
nix eval .#checks.aarch64-darwin.extractor-local-dir.drvPath
nix eval .#checks.aarch64-darwin.dev-plugins.drvPath

# 5. 動いた *データ* が §4.6 の 2 ハンクだけであること
git status --porcelain -- tests/fixtures
#    -> M になってよいのは次の 4 本だけ:
#         tests/fixtures/spec-matrix/golden/matrix.plugins.json
#         tests/fixtures/import-lazy-lock/golden/imported.plugins.json
#         tests/fixtures/spec-matrix/raw-spec.json                (_comment のみ)
#         tests/fixtures/dev-plugins/nvimx-lock/plugins.json       (_comment のみ)
#    tests/dev-path-test.lua もコメントを直すが、この pathspec の外なのでここには出ない
git diff -- tests/fixtures/spec-matrix/golden/matrix.plugins.json
git diff -- tests/fixtures/import-lazy-lock/golden/imported.plugins.json
#    -> どちらも localPlugins の 1 ハンクだけ("dir" 行が消えて {} になる)であること
#    _comment しか動いていない 2 本は、_comment を落として差分ゼロを確認する:
diff <(git show HEAD:tests/fixtures/dev-plugins/nvimx-lock/plugins.json | jq -S 'del(._comment)') \
     <(jq -S 'del(._comment)' tests/fixtures/dev-plugins/nvimx-lock/plugins.json)
diff <(git show HEAD:tests/fixtures/spec-matrix/raw-spec.json | jq -S 'del(._comment)') \
     <(jq -S 'del(._comment)' tests/fixtures/spec-matrix/raw-spec.json)
#    生成 flake の golden が動いていないことも明示的に見る(§4.6 の実測)
git diff --stat -- tests/fixtures/spec-matrix/golden/matrix.flake.nix   # -> 出力なし

# 6. 摂動(§6.2)。(a)(b)(c)(d)(e)(f)(g1)(g2)(h)(i) の 10 件を 1 つずつ試し、毎回必ず戻す。
#    §6.3 の照合表が「§3 のどの決定をどの摂動が守るか」の一覧である。
#
#    ** 先にコミットすること。** 摂動の対象(lua/nvimx, nix/lib, tests/fixtures, flake.nix)と
#    #56 の実装成果物は同じ pathspec に入るので、未コミットのまま `git checkout --` すると
#    実装ごと消える。手順 1-5 が通った時点でコミットする。
#    **`git add -A` は使わないこと** -- この計画書 (docs/plans/56-machine-specific-dir.md) は
#    未追跡なので fix(...) コミットに巻き込まれる。#47 / #49 と同じ 3 コミット分割にする:
git add docs/plans/56-machine-specific-dir.md
git commit -m 'docs: add implementation plan for #56'
git add lua/nvimx/resolve.lua flake.nix nix/lib/make-env.nix tests/fixtures tests/dev-path-test.lua
git commit -m 'fix(resolve): stop recording a machine-specific dir in localPlugins'
git add docs/architecture.md README.md
git commit -m 'docs(resolve): document localPlugins as names only'
git status --porcelain   # -> 空。ここが摂動の原点になる
#
#    どの check が落ちるかは摂動の *対象ファイル* で決まる:
#      resolve.lua の摂動 (a)(b)(c)(d)(e) -> resolve-golden / resolve-import-lazy-lock /
#        extractor-local-dir の 3 本。dev-plugins には *届かない*(resolve を走らせないため)。
#        resolve-lazy-self にも *届かない*(その golden の localPlugins は {} のため)。
#      extract.lua の摂動 (f) -> extractor-local-dir だけ。#56 の check には 1 つも届かない。
#      fixture の摂動 (g1)(g2) と make-env.nix の摂動 (h) -> dev-plugins だけ。
#      (i) は plugins.json 系 golden 全部 + resolve-merge。
#    (e) は「新 jq が落ちない」のが正しい姿である(空集合に length == 0 は真)。
#        落ちるのは keys の assert と has(...) の 3 本であることを確認すること。
nix build .#checks.x86_64-linux.resolve-golden            # (a)(b)(c)(d)(e)(i)
nix build .#checks.x86_64-linux.resolve-import-lazy-lock  # (a)(b)(c)(d)(e)(i)
nix build .#checks.x86_64-linux.extractor-local-dir       # (a)(b)(c)(d)(e)(f)
nix build .#checks.x86_64-linux.dev-plugins               # (g1)(g2)(h)
#    毎回ここに戻す。commit 済みなので実装は失われない
git checkout -- lua/nvimx nix/lib tests/fixtures flake.nix
git status --porcelain   # -> 空であることを毎回確認する
nix build .#checks.x86_64-linux.resolve-golden            # 戻したら通ること
nix build .#checks.x86_64-linux.resolve-import-lazy-lock
nix build .#checks.x86_64-linux.extractor-local-dir
nix build .#checks.x86_64-linux.dev-plugins

# 7. スモークテスト(CLAUDE.md の Commands)。demo の config は dev/dir を使っていないので、
#    退行が無いことの確認である
nix build .#demo && ./result/bin/nvim   # :Lazy が全プラグインを local 表示、git 操作ゼロ

# 8. ドキュメント(§5.4)。書いたことが実物と合っているか突き合わせる
grep -n 'localPlugins' docs/architecture.md
grep -n 'dev.path is a function' docs/architecture.md
grep -n 'per-machine, and it is yours' README.md
grep -n 'localPlugins' nix/lib/make-env.nix
grep -c '(#local-plugin-development)' README.md   # -> 2 のまま(#26 が置いた 2 本を増減させない)

# 9. 事実と食い違う散文が 1 つも残っていないこと(§5.4 / §5.6)
#    いずれも「出力が無いこと」を期待する。アンカーはすべて main = e28d713 で *1 行* にマッチする
#    ことを確認済みである -- 行送りされた文言をアンカーにすると、書き換えを丸ごと忘れても
#    このステップが緑のまま通ってしまう(`whichever way that issue goes` が flake.nix で
#    ちょうどそうなっており、`survives #56` に差し替えてある)。
#    アンカーを足すときは必ず先に `grep -c` して 1 が返ることを確かめること。
grep -n 'the lock still records them' docs/architecture.md
grep -n '/home/you/projects/myplugin' docs/architecture.md   # スキーマ行の例
grep -n 'the recorded dir is ignored' docs/architecture.md
grep -n 'The lock does still \*record\*' README.md
grep -n 'What a real lock \*does\* produce' tests/fixtures/dev-plugins/nvimx-lock/plugins.json
grep -n 'If #56 changes' tests/fixtures/spec-matrix/raw-spec.json
grep -n 'survives #56' flake.nix
grep -n '#56 is free to' flake.nix
grep -n '#56 must be able to' flake.nix
grep -n 'rationale for not reading' tests/dev-path-test.lua
#    make-env.nix / flake.nix / fixture の _comment に散らばる *同じ主張のコピー*。
#    ファイル限定の grep ではこのクラスを原理的に検出できない -- #56 前の時点で 3 箇所に
#    (`is kept verbatim` x2, `is recorded verbatim` x1)あり、1 つだけ直しても残り 2 つが
#    偽のまま緑で通ってしまう。再帰で 3 箇所まとめて見る:
grep -rn 'kept verbatim\|recorded verbatim' flake.nix nix/lib tests/fixtures
#    -> #56 前は 3 行(nix/lib/make-env.nix / flake.nix の dev-plugins / dev-plugins fixture の
#       _comment)。#56 後は 0 行になること。tests/fixtures/local-plugin/scripts/run と
#       import-lazy-lock/raw-spec-dir-only.json にも "verbatim" はあるが別の意味なので、
#       パターンを "kept/recorded verbatim" に絞ってある(実測でこの 2 本は掛からない)。
#    local-dir-config は 2 語足すだけなので、旧い言い回しが消えたことで確認する(§5.4)
grep -n 'produced and absolutizes nothing' tests/fixtures/local-dir-config/init.lua
#    逆に、存在すべきものが在ること
grep -n 'json.object({})' lua/nvimx/resolve.lua
grep -n 'select(. != { })' flake.nix                     # extractor-local-dir の新 assert
grep -n 'dirredRecordedDir' flake.nix                     # dev-plugins の前提固定
#    (g2) を防いでいる唯一の散文。消さずに残っていること
grep -n 'devPath would never produce' tests/fixtures/dev-plugins/nvimx-lock/plugins.json
grep -n 'produced in the raw-spec' tests/fixtures/local-dir-config/init.lua
#    §5.3 (1) が依拠している再生成手順へのポインタ。置換で巻き添えにしないこと(§5.4)
grep -n 'docs/plans/29-genflake-golden.md' tests/fixtures/spec-matrix/raw-spec.json
```

### 手動確認(check にできない部分)

**アップグレード経路を実 lock で 1 回通すこと。** check はすべて 1 回きりの resolve であり、
「#56 以前の lock を持っているユーザーが再 lock したときに何が起きるか」は覆えない。

**nvimx の作業ツリーの中でやらないこと。** 検証にはスクラッチの config と、
その lock を 2 世代コミットするための git リポジトリが要る。nvimx 本体の feature branch でやると
`nvim/` のスクラッチ config とゴミコミットが PR に残る。**別ディレクトリに使い捨てのリポジトリを作る。**

```bash
nvimx=$PWD                                  # nvimx の作業ツリー(ここには何も書かない)
scratch=$(mktemp -d) && cd $scratch
git init -q -b main . && mkdir nvim
cat > nvim/init.lua <<'LUA'
local lazypath = vim.fn.stdpath("data") .. "/lazy/lazy.nvim"
if not (vim.uv or vim.loop).fs_stat(lazypath) then
  vim.fn.system({ "git", "clone", "--filter=blob:none",
                  "https://github.com/folke/lazy.nvim.git", lazypath })
end
vim.opt.rtp:prepend(lazypath)
require("lazy").setup({
  { "folke/tokyonight.nvim" },
  { "o/my-plugin.nvim", dir = "~/src/my-plugin.nvim" },
  { "o/dev-plugin.nvim", dev = true },
})
LUA
git -C $scratch add -A && git -C $scratch commit -qm 'scratch config'

# 1. まず #56 の *前* の nvimx で lock を作り、スクラッチ側にコミットする。
#    ** `git stash` は使えない。** §8-6 で実装をコミット済みなので stash は
#    "No local changes to save" の no-op になり、手順 1 が #56 *適用後* の lock を作ってしまう
#    (`nix run <path>#lock` は git 管理下の内容を使う)。そうなると確認項目 1 は差分ゼロ、
#    確認項目 2 は #56 前を一度も通さずに緑になり、検証が黙って空振りする。
#    #56 を含まないコミットに checkout して作る:
#    §8-6 は 3 コミットに分けるので `HEAD~1` は fix コミット(= #56 適用済み)になる。
#    その 1 つ前、計画書だけを足したコミットを名前で拾う:
base=$(git -C $nvimx rev-list -1 --grep='docs: add implementation plan for #56' HEAD)
[ -n "$base" ] || { echo 'base commit not found'; exit 1; }
git -C $nvimx checkout -q $base
nix run $nvimx#lock -- --config $scratch/nvim --out $scratch/nvim/nvimx-lock
jq .localPlugins $scratch/nvim/nvimx-lock/plugins.json   # -> $HOME 入りの dir が 2 件。
                                                         #    ここが 2 件でなければ base が違う
git -C $scratch add -A && git -C $scratch commit -qm 'pre-56 lock'

# 2. #56 を戻して、同じ config を再 lock する
git -C $nvimx checkout -q -                 # 実装コミットへ戻る
git -C $nvimx status --porcelain            # -> 空(detached HEAD から戻っただけ)
nix run $nvimx#lock -- --config $scratch/nvim --out $scratch/nvim/nvimx-lock
```

確認すること(すべて `$scratch` の中で。**`git -C $nvimx status` は最後まで実装差分だけであること**):

1. `git -C $scratch diff` が `plugins.json` の `localPlugins` の 2 エントリだけを変えていること
   (`"dir"` 行が消えて `{}` になる)。**`flake.lock` に差分が出ないこと。**
2. `grep "$HOME" $scratch/nvim/nvimx-lock/plugins.json` が 1 件も出ないこと。
3. `$scratch/nvim/nvimx-lock/flake.nix` に `my-plugin-nvim` / `dev-plugin-nvim` の input が**無い**こと(#47 の維持)。
4. **もう一度同じ lock を実行して `git -C $scratch diff` が空であること**(2 パス収束の不動点)。
5. `home-manager switch` 相当のビルドが通り、`:Lazy` で `my-plugin.nvim` が `~/src/my-plugin.nvim` を、
   `dev-plugin.nvim` が `<devPath>/dev-plugin.nvim` を指す local 表示になること
   (= 記録値を消しても runtime の解決が変わらないこと)。
6. `--update` で走らせたとき、`update-summary` がこの変化を報告しないこと
   (`no plugins updated` になる。§4.6 の実測が実環境でも成り立つこと)。
7. **`dev.patterns` の経路も 1 回通すこと**(§1.6 #9)。上の config の opts に
   `{ dev = { patterns = { "folke" } } }` を足すと `tokyonight.nvim` —— `dev` も `dir` も
   書いていないエントリ —— が `localPlugins` に入る。#56 後はそれも `{}` になり、
   `plugins.json` に `$HOME` が 1 文字も残らないこと。**この経路は fixture を持たないので、
   手動確認が唯一のカバレッジである。**

終わったら `rm -rf $scratch`。**nvimx 側には 1 バイトも残らないこと**を
`git -C $nvimx status --porcelain` で確認する。

**逆方向(ロールバック)も 1 回確認すること**: #56 後の lock(`localPlugins` が `{}`)を、
#56 **以前**の nvimx でビルドできること。`make-env.nix` は `builtins.attrNames` しか使わないので通るはずで、
これが §3.6 の「旧 nvimx が新 plugins.json を読める」の実環境での確認になる。
