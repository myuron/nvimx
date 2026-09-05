# #47 対応計画: `dev` の無い明示 `dir` がリモートプラグイン扱いされるのを直す

対象 issue: [#47 fix(extract): a plugin with an explicit dir but no dev is treated as remote](https://github.com/myuron/nvimx/issues/47)

作業ツリー: `/home/myuron/ghq/github.com/myuron/nvimx`(`main` = `84d5fd0`、**#49 のマージ直後**)。
本計画の実測出力はすべてこのツリーで確認している。lazy.nvim 側の `file:line` は `flake.lock` が pin している seed
(`lazy-nvim`、rev `306a055` → `/nix/store/d9jq3s81p4i9q6g8gaa6f2pn51p8za9l-source`)の実ファイルからの引用である。

**nvimx 自身のファイルは行番号で参照しない。** 本件は `extract.lua` と `flake.nix` を編集するので、
計画が書いた行番号は計画自身の PR で動く。`6b13953 fix(lock): stop the import check from citing line
numbers it invalidates` が記録した教訓に従い、シンボル・アンカー(関数名 / check 名 / コメントの一節)で位置を指す。

§3 の設計判断は、`lua/nvimx/` を scratch にコピーして実際にパッチを当てたプロトタイプで全件実測している。
以下の `console` ブロックはすべてそのプロトタイプの出力そのものであり、手で書いたものは 1 行も無い。

---

## 1. 背景 / 現状

### 1.1 再現(実測)— lock が、手元にあるプラグインのために github.com へ出て失敗する

spec:

```lua
require("lazy").setup({
  { "folke/tokyonight.nvim", tag = "v1.0.0" },
  { "o/dirabs.nvim",   dir = "/nvimx-fixture/dirabs" },
  { "o/dirtilde.nvim", dir = "~/nvimx-fixture/dirtilde" },
  { "o/dirrel.nvim",   dir = "nvimx-fixture/dirrel" },
  { "o/bare.nvim", dev = true },
}, { defaults = { version = "*" } })
```

`dirabs.nvim` に `version = "^1.0"` を書いた(= `versionFromDefaults` でない、ユーザーが自分で書いた制約)状態で
今日の `nvim -l resolve.lua ... --lazy <seed>` を走らせた実測:

```console
nvimx-lock: resolving version constraints for 3 plugin(s)
[nvimx] resolve failed: plugin "dirabs.nvim": no tag matches version constraint "^1.0" (file:///.../repo/dirabs). 1 tags parsed; newest: v0.5.0. If this plugin does not use semver tags, drop `version` or set `version = false`.
[nvimx] resolve failed: plugin "dirrel.nvim": git ls-remote failed for https://github.com/o/dirrel.nvim.git (exit 128): remote: Repository not found. / fatal: repository 'https://github.com/o/dirrel.nvim.git/' not found
[nvimx] resolve failed: plugin "dirtilde.nvim": git ls-remote failed for https://github.com/o/dirtilde.nvim.git (exit 128): remote: Repository not found. / fatal: repository 'https://github.com/o/dirtilde.nvim.git/' not found
rc=1
```

**3 本とも、ユーザーが自分のディスク上の作業ツリーを指定したプラグインである。**
それに対して nvimx は github.com へ `git ls-remote` を撃ち、lock を失敗させている。
`plugins.json` は 1 バイトも書かれない(`report_resolve_errors` が先に落とす)ので、**lock コマンド自体が使えなくなる**。

同じ spec を修正後の extract に通すと:

```console
rc=0
{ "localPlugins": ["bare.nvim","dirabs.nvim","dirrel.nvim","dirtilde.nvim"],
  "plugins": ["tokyonight.nvim"] }
```

ネットワークアクセスはゼロ、`--lazy` すら要らない(§3.5)。

### 1.1.1 短縮名を書かない `dir` のみのプラグインは、今日は lock が**構造的に不可能**

lazy で最も自然な dir-only の書き方は `{ dir = "/path/to/plugin" }` ——
`o/x.nvim` のようなリポジトリ短縮名を書かない形である(ローカルにしか無いのだから書きようが無い)。
lazy はこの形を受理し、パスの basename からプラグイン名を導き、`url` は付けない。実測(raw-spec):

```console
$ jq -c '.plugins["dirnoname"]' raw-spec.json
{"dir":"/nvimx-fixture/dirnoname","name":"dirnoname","version":"*","versionFromDefaults":true}
```

`url` が無い。今日はこれがリモートプラグインとして `resolve.lua` に渡るので:

```console
[nvimx] resolve failed: plugin "dirnoname": has no url. lazy derives one from the spec, so a raw spec without it is malformed
```

**`--lazy` を渡そうが渡すまいが、ネットワークがあろうが無かろうが、この config は lock できない。**
§1.1 の「無駄な ls-remote」が性能とノイズの問題なのに対し、こちらは**機能が丸ごと使えない**形の実害である。
修正後は exit 0 で `localPlugins.dirnoname = { dir = "/nvimx-fixture/dirnoname" }` になる(実測)。

この形は `p.url == nil` なので `parse_source` に入る経路が §1.1 の 3 本と違う。fixture に別ケースとして入れる(§5.2)。

### 1.2 原因は `extract.lua` の 1 行

`dump_plugin` の

```lua
    dir = p.dev and p.dir or nil,
```

が `dev` なプラグインの `dir` しか raw-spec に載せない。`resolve.lua` はローカル / リモートを
`if p.dev or p.dir then` で振り分けるので、**振り分けの材料そのものが extract で捨てられている**。
結果は「`inputName` が付き、GitHub source を持ち、生成 flake に input が 1 本増える」である。実測(制約を外した同じ spec):

```console
$ jq -S '.plugins["dirabs.nvim"]' plugins.json
{ "branch": null, "build": { "kind": "none" }, "commit": null, "dependencies": [],
  "inputName": "dirabs-nvim", "pin": null, "resolvedRef": null,
  "source": { "owner": "o", "repo": "dirabs.nvim", "type": "github" },
  "tag": null, "version": null }
$ cat flake.nix
...
    dirabs-nvim = {
      url = "github:o/dirabs.nvim";
      flake = false;
    };
```

この欠落は `extract.lua` のコメントに**既に文書化されている**(`effective_version` の直前のコメント、
*"a plugin with an explicit `dir` and no `dev` is a different story ... Routing those to localPlugins is a
pre-existing gap, tracked separately"*)。
`docs/plans/26-dev-plugins.md` §7 R2 も同じことを「既存の欠落、本件では悪化も改善もしない」として記録している。
**本件はこの 2 箇所の申し送りを discharge する。**

### 1.3 issue の "Record `dir` whenever the spec sets it" を素直に実装すると**全滅する**(実測)

これが本件で唯一絶対に間違えてはならない点である。**lazy は `dir` を全プラグインに埋める。**
`lua/lazy/core/meta.lua:213-239`(`Meta:_rebuild` の dir/dev ブロック):

```lua
213  -- dir / dev
214  plugin.dev = super.dev
215  plugin.dir = super.dir
216  if plugin.dir then
217    plugin.dir = Util.norm(plugin.dir)
218  elseif super.virtual then
219    plugin.dir = Util.norm("/dev/null/" .. plugin.name)
220  else
...
229    if plugin.dev == true then
230      local dev_dir = type(Config.options.dev.path) == "string" and Config.options.dev.path .. "/" .. plugin.name
231        or Util.norm(Config.options.dev.path(plugin))
...
238    plugin.dir = plugin.dir or Config.options.root .. "/" .. plugin.name
239  end
```

`:238` が最後の受け皿なので、**`p.dir` が nil のプラグインは存在しない**。実測(現行 extract に probe を足したもの):

```console
bare.nvim      dev=true  dumped_dir=<HOME>/projects/bare.nvim  p.dir=<HOME>/projects/bare.nvim
dirabs.nvim    dev=nil   dumped_dir=nil                        p.dir=/abs/dirabs
dirrel.nvim    dev=nil   dumped_dir=nil                        p.dir=src/dirrel
dirtilde.nvim  dev=nil   dumped_dir=nil                        p.dir=<HOME>/src/dirtilde
tokyonight.nvim dev=nil  dumped_dir=nil                        p.dir=<HOME>/.local/share/nvim/lazy/tokyonight.nvim
```

したがって `dir = p.dir,` と書くと **spec 全体が `localPlugins` に落ち、`plugins` が空になる**。実測:

```console
$ nvim -l resolve.lua raw-naive.json out-naive.json ; echo rc=$?
rc=0
$ jq -S '{plugins:(.plugins|keys), localPlugins:(.localPlugins|keys)}' out-naive.json
{
  "localPlugins": [ "bare.nvim","devabs.nvim","devtilde.nvim","dirabs.nvim","dirrel.nvim","dirtilde.nvim","tokyonight.nvim" ],
  "plugins": []
}
```

**rc=0 である。** flake input が 1 本も生成されず、farm が空になり、それでも lock は成功する。
「素直な実装」は今のバグより悪い壊れ方をする。§3.1 はこの罠を避けるための判定を決める節である。

### 1.4 runtime は**今日も正しい** — 壊れているのは lock だけ(実測)

`bootstrap.lua` の `dev.path` 関数は、spec が `dir` を書いたプラグインに対しては**呼ばれもしない**
(`meta.lua:216` が短絡する)。`@farm@` / `@devDirs@` を手で埋めた bootstrap で実測:

```console
### dev_dirs = {}(= 今日。dirabs.nvim は farm に fetch 済みという想定)
tokyonight.nvim  <farm>/tokyonight.nvim   is_local=true
dirabs.nvim      /abs/dirabs              is_local=true
dirtilde.nvim    <HOME>/src/dirtilde      is_local=true
dirrel.nvim      src/dirrel               is_local=true

### dev_dirs = { ["dirabs.nvim"]="/devpath/dirabs.nvim", ["dirrel.nvim"]="/devpath/dirrel.nvim" }(= #47 後)
tokyonight.nvim  <farm>/tokyonight.nvim   is_local=true
dirabs.nvim      /abs/dirabs              is_local=true
dirtilde.nvim    <HOME>/src/dirtilde      is_local=true
dirrel.nvim      src/dirrel               is_local=true
```

**2 つの表は 1 文字も違わない。** 今日 nvimx が fetch して farm に置いている `dirabs.nvim` の store コピーは
**runtime では一度も読まれない死荷重**であり、`#47` の後に `devDirs` へ入る `<devPath>/dirabs.nvim` も
**同じ理由で無害な no-op** である。これが §3.7(Nix 側は無変更)の根拠であり、
`docs/plans/26-dev-plugins.md` §3.3 が `localPlugins[*].dir` を読まないと決めた決め手とまったく同じ事実である。

**したがって本件が変えるのは lock の中身だけで、ユーザーの Neovim の挙動は変わらない。**
変わるのは「無駄な fetch と無駄な制約解決が消える」ことである。

### 1.5 issue 本文の前提のうち、確認したもの / 補正が要るもの

| issue の記述 | 実測 | 扱い |
|---|---|---|
| lazy は `dir` と `dev` を同じに扱う。`Meta:resolve` が `_.is_local` を立て、`get_target` は最初の分岐で返る | **正しい**。`git.lua:118-123` の `if plugin._.is_local then return ... end` は `commit`(`:127`)/ `tag`(`:133`)/ `defaults.version`(`:141`)より前にある | §3.1 の根拠として採用 |
| 「`resolve.lua` は verify only、most likely」 | **正しいが検証が要る**。`p.dev or p.dir` を読む箇所は 5 つあり、うち 2 つはユーザーから見える挙動が変わる(§3.4) | §3.4 で全件確認。**コードは無変更** |
| 「`dir` を spec が設定したら常に記録する」 | **そのままでは実装できない**(§1.3) | §3.1 で判定を作り直す |
| `_.is_local` を使えばよい | **extract では使えない**。`_.is_local` を立てるのは `lua/lazy/core/plugin.lua:244-252` の `update_state()` で、これは本物の `lazy.setup` の経路にしか無い。extract は `Plugin.Spec.new` しか呼ばないので `p._.is_local` は常に nil(実測) | §3.1 で**同じ判定式を写す**形に落とす |

---

## 2. ゴール

issue の "Done when" を検証可能な形に落とす。

1. **`{ "foo/bar", dir = "..." }`(`dev` 無し)が `localPlugins` に入り、flake input を 1 本も作らない。**
2. **短縮名を書かない `{ dir = "..." }` でも lock が成功する。** 今日は `has no url` で必ず落ちる(§1.1.1)。
3. **通常のリモートプラグインは 1 つも `localPlugins` に落ちない。** `plugins` が空になる §1.3 の壊れ方を作らない。
4. **判定は lazy が使っているのと同じ軸(root 配下かどうか)であり、nvimx 独自の第 3 の軸を発明しない**
   (issue の *"nvimx should match it rather than invent a third behavior"*)。
   ただし「常に lazy と一致する」とは主張しない —— extract は使い捨てサンドボックスの root を見るため、
   1 ケースだけ食い違う(§3.1 / §7)。
5. **#42 が materialize した `defaults.version` は、ローカルプラグインでは記録されず、#23 の semver ゲートにも乗らない。**
   `git` も `--lazy` も無い環境で resolve が exit 0 することを check で固定し、
   **その前提(制約が実在すること)も同じ check で固定する**(§6.1 ステップ 1)。
6. **`dir` のみの lazy.nvim が `dev = true` の場合と同じ扱いになる**(§3.8)。
   `lazyNvim` は合成リテラルに戻り、素の `--update` が seed input を動かす。**挙動変更として check で固定する。**
7. **`dev` 無しの `dir` を持つ fixture と check を足す。** 既存 fixture / golden の**データ**は 1 バイトも動かさない
   (事実と食い違う `_comment` の訂正 1 行だけが例外。§5.5)。
8. **`extract.lua` の既存コメントと `docs/plans/26-dev-plugins.md` §7 R2 の申し送りに答える**(§1.2)。
9. **#56(`localPlugins` にマシン固有の `dir` を記録しない)の設計余地を狭めない**(§4.2)。
10. `nix flake check` が Linux でグリーン、`aarch64-darwin` でも評価できる。

---

## 3. 設計

### 3.1 判定 — **`meta.lua:238` のフォールバック式で「lazy が埋めた `dir`」を除外する**

`lua/lazy/core/plugin.lua:244-252`(`update_state()`):

```lua
244    if plugin.virtual then
245      plugin._.is_local = true
246      plugin._.installed = true -- local plugins are managed by the user
247    elseif plugin.dir:find(Config.options.root .. "/", 1, true) == 1 then
248      plugin._.installed = installed[plugin.name] ~= nil
249      installed[plugin.name] = nil
250    else
251      plugin._.is_local = true
252      plugin._.installed = vim.fn.isdirectory(plugin.dir) == 1
253    end
```

lazy にとって「ローカル」とは **`dir` が `Config.options.root .. "/"` の下に無いこと**である。
`dev` かどうかも、spec が `dir` を書いたかどうかも見ていない。**採用する判定はこれの逐語の写しである**:

```lua
local function local_dir(p, root_prefix)
  if type(p.dir) ~= "string" or p.dir:find(root_prefix, 1, true) == 1 then
    return nil
  end
  return p.dir
end
```

`root_prefix` は `capture()` の中で `Config.setup(...)` の**あと**に `Config.options.root .. "/"` として 1 回だけ作り、
`dump_plugin` に渡す。

**保証の強さを正確に述べる。** `root_prefix` は `meta.lua:238` が受け皿として使うのと**同じ式**なので、

> **lazy がその extract 実行の中で `<root>/<name>` を埋めたプラグインは、必ず除外される。**

これは構成上の保証である。一方、

> 「nvimx の判定は、ユーザーの runtime における lazy の `_.is_local` と常に一致する」

は**成り立たない**。`nix/lib/lock-app.nix` は extract を `sandbox=$(mktemp -d)` の使い捨て XDG サンドボックス
(`XDG_DATA_HOME="$sandbox/data"`)で走らせるので、extract 時の `Config.options.root` は
`<tmpdir>/data/nvim/lazy` であり、**ユーザーの runtime の root(既定 `~/.local/share/nvim/lazy`)とは無関係**である。
したがってユーザーが runtime root 配下を**リテラルで**書いた `dir`
(`dir = "/home/me/.local/share/nvim/lazy/foo"`)は、extract では前方一致せずローカルと判定され、
runtime では `plugin.lua:247` によりリモートと判定される。**この 1 ケースだけは食い違う**(§7 にリスクとして記録)。

採用理由は「常に一致する」ではなく次の 3 点である:

1. **フォールバック値を確実に除外できる唯一の式である。** `p.dir` が nil でない以上、
   除外すべきは「lazy が埋めた値」であり、それを言い当てる式は `meta.lua:238` の右辺しか無い。
2. **lazy が使っている概念(root 配下かどうか)と同じ軸で判断する。** 別の軸(spec が書いたかどうか)を
   持ち込む却下 B は、上の 1 ケースを直せないうえに軸が 2 本になる(§3.2)。
3. **root を知っているのは extract だけである**(§3.2 却下 C)。

この判定が満たす性質(extract 実行時の root を基準として):

| spec | `p.dir` | 記録 |
|---|---|---|
| `{ "o/x.nvim" }` | `<root>/x.nvim` | `nil` |
| `{ "o/x.nvim", dev = true }` | `<devpath>/x.nvim` | 記録 |
| `{ "o/x.nvim", dev = true, dir = "/abs" }` | `/abs` | 記録 |
| `{ "o/x.nvim", dir = "/abs" }` | `/abs` | **記録(これが #47)** |
| `{ dir = "/abs/noname" }`(短縮名なし、`url` も無い) | `/abs/noname` | **記録(§1.1.1)** |
| `{ "o/x.nvim", virtual = true }` | `/dev/null/x.nvim` | 記録 |

**`virtual` も自動的にローカルになる**のは意図した副作用である。lazy も virtual を is_local として扱い
(`plugin.lua:244-246`)、`meta.lua:218-219` が `/dev/null/<name>` を入れるので root の下には来ない。
今日は virtual なプラグインもリモート扱いされて input が作られている(`url` があれば)。
**本件はそれも同時に変える**が、`virtual` は本件のスコープではないので fixture には入れない(§7)。

### 3.2 却下した 3 案

#### 却下 A: `dir = p.dir`(issue 本文の字面どおり)

§1.3 の実測のとおり **spec 全体が `localPlugins` に落ちて `plugins` が空になり、それでも rc=0** になる。
今日のバグ(fetch しなくてよいものを fetch する)より重い壊れ方であり、しかも黙って壊れる。**論外。**

#### 却下 B: `dev` と「spec が書いた `dir`」の 2 条件にする(fragment を `rawget` する)

lazy の `LazyFragments` に降りて、そのプラグインを構成した fragment のどれかが `dir` を書いたかを見る。実測で**動く**:

```console
tokyonight.nvim  p.dir=<root>/tokyonight.nvim  frags={ 1 }  written_dir=nil
bare.nvim        p.dir=<HOME>/projects/bare.nvim  frags={ 3 }  written_dir=nil
dirabs.nvim      p.dir=/abs/dirabs             frags={ 2 }  written_dir=/abs/dirabs
```

却下理由:

1. **述語が 2 つになる。** `p.dev or written_dir` と書く必要があり、`dev` の分岐(`meta.lua:229-237`)と
   `dir` の分岐(`:216-217`)を nvimx 側で二重に再現し続けることになる。§3.1 は 1 つの式で両方を覆う。
   2 本になれば片方だけ直したときに中間状態が作れる —— §3.5 が `effective_version` にガードを足さないと決めたのと同じ理由である。
2. **lazy の内部表現(`p._.frags` → `s.meta.fragments:get(fid).spec`)に踏み込む。**
   `docs/plans/43-drop-optional-field.md` §3.4 が同種の変更を「seed 更新で壊れうる」と評価しているのと同じコスト。
   §3.1 が使う `Config.options.root` は lazy の**公開 opts** であり、`meta.lua` が受け皿として使う式と同一である。

**「B なら `dir = "<root>/foo"` を書いたユーザーとの食い違いが直る」という理由は挙げない。**
§3.1 のとおり extract は使い捨てサンドボックスの root を見るので、
**その食い違いは A でも B でもまったく同じに残る**(A は前方一致が当たらず、B は spec が書いたので、
どちらも「ローカル」と判定し、runtime の lazy はリモートと判定する)。B の利点にはならない。

**ただし B は #56 の option 2 が必要とする道具でもある。** そちらでは「ユーザーが書いた値かどうか」自体が目的なので、
評価が変わる。§4.2 で申し送る。

#### 却下 C: `resolve.lua` 側で「`dir` が root の下なら無視する」

extract は `dir = p.dir` を素直に dump し、判定を resolve に移す。

却下理由: **root は resolve に届かない。** `Config.options.root` は extract 実行時の Neovim の
`stdpath("data")`(または opts)から決まる値で、raw-spec には載っていない。
載せるなら raw-spec スキーマにマシン固有の絶対パスを 1 本増やすことになり、#56 が減らそうとしているものを増やす。
判定は root を知っている唯一の場所、すなわち extract で完結させる。

### 3.3 記録する値 — lazy が正規化したものを**そのまま**、検証もせず

`Util.norm`(`lua/lazy/core/util.lua:74-84`)は `~` を `vim.uv.os_homedir()` で展開し、`\` を `/` に、
連続する `/` を 1 つに畳み、末尾の `/` を落とす。**相対パスを絶対化はしない。** 実測(3 形すべて):

| spec が書いた `dir` | 記録される値 | マシン依存か | 誰がそうしたか |
|---|---|---|---|
| `/nvimx-fixture/dirabs` | `/nvimx-fixture/dirabs` | しない | `Util.norm` は絶対パスに何もしない |
| `~/nvimx-fixture/dirtilde` | `<HOME>/nvimx-fixture/dirtilde` | **する** | `meta.lua:217` の `Util.norm` が extract したマシンの `$HOME` で展開 |
| `nvimx-fixture/dirrel` | `nvimx-fixture/dirrel` | しない(が **cwd 依存**) | `Util.norm` は相対のまま通す |
| (`dev = true`、`dir` 無し) | `<HOME>/projects/bare.nvim` | **する** | lazy がユーザー自身の `dev.path` から導出(`meta.lua:229-231`) |

**採用: 4 通りとも `p.dir` を逐語で記録し、絶対化も存在確認もしない。**

- **絶対化しない理由**: lazy が絶対化しないから。runtime で `dirrel.nvim` が解決する先は
  `nvim` を起動した cwd 基準の `nvimx-fixture/dirrel` である(§1.4 の実測)。
  extract 時の cwd で絶対化すると **nvimx だけが違う場所を指す**ことになり、issue が禁じた第 3 の挙動になる。
- **存在確認しない理由**: `bootstrap.lua.in` の `fallback = false` は `docs/plans/26-dev-plugins.md` §3.1 の
  却下案 C で確定した設計であり、「作業ツリーが無ければ lazy が not installed と表示する」が正解である。
  lock 時に存在を確かめると、他人のマシンで作った lock がそのマシンで落ちる。
- **マシン依存の値をコミットさせ続ける問題は #56 の担当である。** 本件はその境界を動かさない(§4.2)。

**本件のどの主張も、記録された値そのものには依存しない。**
`nix/lib/make-env.nix` は `localPlugins` の**キーだけ**を読む(#26 §3.3)。
新 check も `plugins.json` については**キーしか assert しない**(値の assert は raw-spec = `extract.lua` 自身の契約に対してだけ行う)。
これは #56 が option 1(`{ }` を書く)を採っても本件の check が 1 行も動かないようにするための、意図的な線引きである(§4.2)。

### 3.4 `resolve.lua` は無変更 — ただし「確認のみ」を実コードで確かめた

issue は "verify only, most likely" と推測しているだけなので、`dev` / `dir` を読む箇所を**全件**追った。
`grep -n 'p\.dev or p\.dir'` は 5 箇所を返すが、**それだけでは足りない** —— #49 が入れた
`lazy_is_spec = lazy_p ~= nil and not (lazy_p.dev or lazy_p.dir)` は変数名が `lazy_p` なので同じ grep に掛からない。
`grep -nE '\.dev or [a-z_]*\.dir' lua/nvimx/resolve.lua` で 6 箇所を確認した:

| # | 場所 | `dir` のみのプラグインに何が起きるか | 判定 |
|---|---|---|---|
| 1 | メインループの先頭の分岐(`local_plugins[name] = { dir = p.dir }`) | `localPlugins` に入り、`inputName` も source も semver ゲートも通らない | **これが本件の本体**。実測 §3.5 |
| 2 | `--update <name>` の名前検証(`fail_plugin(name, "is a local plugin (dev/dir); nothing to lock or update")`) | 名前で指定すると fatal になる | **挙動変更**。正しい(update する対象が無い)。check で固定(§6.1 ステップ 5) |
| 3 | `update_all` の force 集合(`if not (p.dev or p.dir) and not is_true(p.pin)`) | 全体更新の対象から外れ、update-plan にも載らない | **挙動変更**。正しい。check で固定(§6.1 ステップ 5) |
| 4 | `--import-lazy-lock` の lazy-lock 側ループ(`local_skipped`) | classification 3L(`it is a local plugin (dev/dir), so there is nothing to pin`)で報告される | **挙動変更**。正しい。§3.6 |
| 5 | `--import-lazy-lock` の config 側ループ(`not_in_lock`) | 「lazy-lock.json に無い」の集計から外れる | 4 と対称。無害 |
| 6 | **#49 の `lazy_is_spec` / `lazy_pinned`**(ファイルスコープの 2 述語) | `dir` のみの lazy.nvim が `lazy_is_spec` から**外れる**。`lazyNvim` が synthetic に戻り、`tag`/`pin` が効かなくなり、素の `--update` の plan に `lazy-nvim` が戻る | **挙動変更。lock の中身が実際に動く**。§3.8 で実測付きに扱い、`checks.resolve-lazy-self` にケースを 1 つ足す |

さらに `import_accounted` のコメントが *"without depending on its own `p.dev or p.dir` check staying in sync
with this loop's"* と書いているとおり、4 と 5 は**互いに構造で同期している**ので、片方だけ動くことはない。

**したがって `resolve.lua` は 1 バイトも変えない。** ただし「変えない」は「何も起きない」ではないので、
2 / 3 / 4 / 6 の挙動変更にはそれぞれ assert を置く(§6)。
**6 は当初この表から漏れていた** —— `grep 'p\.dev or p\.dir'` では `lazy_p.` 版が拾えなかったためで、
「変数名の違いで網から落ちる」ことがそのまま計画の穴になった実例である。

もう 1 つ確認した点: `p.dev` は**引き続き dump する**。#47 後は `dev = true` なプラグインも `dir` が載るので
振り分けとしては冗長になるが、`dev` が真で `dir` が root の下に来る病的なケース
(ユーザーが `dev.path` を lazy の root に向けた場合)だけは `p.dev` が唯一の手掛かりとして残る。
`resolve.lua` の `p.dev or p.dir` をそのまま残すのは、この 1 ケースを落とさないためである(§7 に非対称として記録)。

### 3.5 #42 / #23 との関係 — 制約は**記録せず、警告もしない**

`localPlugins` のエントリは `{ dir = ... }` だけで、`version` も `build` も `tag` も記録されない
(`resolve.lua` のメインループの `local_plugins[name] = { dir = p.dir }`)。
`dev` プラグインについて今日そうなっているのと同じで、本件はこの意味論を変えない。

**警告も出さない。** #49 は lazy.nvim の `build` について「無視するなら黙って無視しない」と決めたが、
そこと事情が違う:

- lazy.nvim の場合、`build` を無視するのは **nvimx の都合**(farm に 2 つ置けない)だった。
- ローカルプラグインの場合、`version` / `tag` / `commit` を無視するのは **lazy がそうするから**である
  (`git.lua:118-123` が `_.is_local` で最初に return する)。nvimx が黙って捨てているのではなく、
  **lazy も見ない値を lock に持ち込まない**だけである。ここで警告を出すと「lazy では黙って無視されるものに
  nvimx だけが文句を言う」ことになる。

`extract.lua` 側でも `effective_version` に `dir` のガードは**足さない**。理由は 2 つ:

1. 足しても意味が無い。raw-spec の `version` を読むのは `resolve.lua` のリモート分岐だけで、
   ローカルプラグインはそこに到達しない(実測)。
2. `effective_version` に 2 つ目の述語が増えると、`local_dir` と条件が食い違ったときに
   「`dir` は記録されたが `version` も残った」といった中間状態が作れてしまう。
   **判定は `local_dir` の 1 箇所に閉じる。**

代わりに `extract.lua` のコメントを事実に合わせる(§5.1)。現在の
*"a plugin with an explicit `dir` and no `dev` is a different story: dump_plugin only records `dir` for dev
plugins, so resolve treats it as remote and this constraint reaches plugins.json even though lazy would never
consult it. Routing those to localPlugins is a pre-existing gap, tracked separately."*
は本件で**偽になる**。

**この決定を守るガードが check の設計を決める。** 新 check は `pkgs.git` も `--lazy` も**わざと持たない**。
振り分けが 1 つでも壊れると、fixture のローカルプラグインは **2 つの経路のどちらか**で resolve を落とす:

| 壊れたときにリモート扱いされるもの | 落ち方 |
|---|---|
| `dirnoname`(`url` が無い) | `source.parse` が `has no url` で `fail_plugin` |
| `url` を持つ 5 本(`defaults.version = "*"` を materialize 済み) | #23 の semver ゲートが発火し、`--lazy` が無いので `a version constraint needs --lazy ...` |

**どちらの経路でも非ゼロで終わるので、「resolve が exit 0 する」こと自体が assert である。**
`checks.resolve-import-lazy-lock` が *"Deliberately without pkgs.git: ... 'the resolve exits 0' is itself the
proof"* と書いているのと同じ仕掛けで、完全にオフラインである。

**ただし現 fixture では、実際に見えるのは前者だけである。** `report_resolve_errors()` は
`a version constraint needs --lazy ...` の `fail()` より**前**に呼ばれるので、`dirnoname` の
`has no url` が先に exit する。実測(現 fixture、`extract.lua` を未パッチに戻したもの = 摂動 (a)):

```console
$ nvim -l resolve.lua raw-spec.json plugins.json   # 修正前
[nvimx] resolve failed: plugin "dirnoname": has no url. lazy derives one from the spec, so a raw spec without it is malformed
rc=1
$ nvim -l resolve.lua raw-spec.json plugins.json   # 修正後
rc=0
```

`resolve.lua` のメインループを `if p.dev then` に狭めた場合(摂動 (e))も同じ 1 行で落ちる(実測)。
**semver ゲートの側は、`dirnoname` が居る限り現 fixture では発火しない。**
それでもステップ 1 が `version` を assert する価値は残る: `dirnoname` を将来外したり
`url` を足したりした瞬間に、ステップ 2 の根拠はゲートの側だけになるからである。
その日に「制約がもう存在しない」ことに気付けるのはステップ 1 の 3 行だけである。

### 3.6 `--import-lazy-lock` — classification 3L の発火条件が広がる

`dir` のみのプラグインが lazy-lock.json にエントリを持っている場合、今日は普通に pin される。
修正後は classification 3L(ローカルなので pin するものが無い)になる。実測:

```console
### 修正前
[nvimx] import: pinned dirabs.nvim to 111111111111
[nvimx] import: pinned tokyonight.nvim to 222222222222
[nvimx] import: 2 pinned, 0 skipped, 0 ignored, 0 not in lazy-lock.json

### 修正後
[nvimx] import: pinned tokyonight.nvim to 222222222222
[nvimx] import: skipped dirabs.nvim: it is a local plugin (dev/dir), so there is nothing to pin
[nvimx] import: 1 pinned, 1 skipped, 0 ignored, 0 not in lazy-lock.json
```

**これが正しい。** lazy-lock.json の commit は「lazy が管理している clone の rev」であり、
ローカルプラグインについては lazy 自身が記録しない(`lua/lazy/manage/lock.lua:25` の
`if not plugin._.is_local and plugin._.installed then`)。エントリがあるとすれば、
そのプラグインが以前はリモートだった名残である。

**採用: コードは変えず、`checks.resolve-import-lazy-lock` にケースを 1 つ足す**(§3.7 の #49 と同じ担当分け)。
既存の `raw-spec.json` は**触らない**: 触ると `golden/imported.plugins.json` と、
その check が持つ 3 箇所の `19`(`grep -c '^\[nvimx\] import: '` / `wc -l < out1.log` / `wc -l < seq-import.log`)が
同時に動く(`docs/plans/49-lazy-nvim-collision.md` §5.6 が同じ罠を記録している)。
代わりに `tests/fixtures/import-lazy-lock/raw-spec-dir-only.json` を新設する。

### 3.7 Nix 側(`make-env.nix` / `bootstrap.lua.in`)は**無変更**

`localPlugins` に新しい種類のエントリが増えるが、**`plugins.json` は `dev` 由来と `dir` 由来を区別しない** ——
どちらも `{ "<name>": { "dir": "..." } }` である。したがって:

| 消費者 | 読むもの | 影響 |
|---|---|---|
| `make-env.nix` の `localPlugins` | `hasLock` ガード付きで `pluginsDb.localPlugins or { }` | なし |
| `make-env.nix` の `devDirs` | `localPlugins` の**キーだけ**を `<devPath>/<name>` に写す | キーが 1 つ増えるが、§1.4 の実測どおり **runtime では参照されない**(lazy が spec の `dir` で短絡する) |
| `make-env.nix` の `unknownDevPluginNames` | `pluginsDb.plugins` と `localPlugins` の**両方**に無い `devPlugins` 名 | **変化なし。** 該当プラグインは修正前は `pluginsDb.plugins` に、修正後は `localPlugins` に居る。どちらでも述語の片方が真なので誤字扱いにはならない |
| `make-env.nix` の **`unknownPluginNames`**(`plugins.overrides` / `plugins.nixpkgsFallback` 用) | `pluginsDb.plugins` **のみ**(`localPlugins` を見ない) | **変化する。** `dir` のみのプラグインに `overrides` / `nixpkgsFallback` を書いていたユーザーには、#47 後に activation 時の警告が**新たに出る** |
| `make-env.nix` の farm / `pluginDrvs` | `pluginsDb.plugins` のみ | エントリが 1 つ減る = **fetch とビルドが減る**。これが本件の実利 |
| `bootstrap.lua.in` の `dev.path` 関数 | `dev_dirs[plugin.name]` | 呼ばれない(短絡)。§1.4 |

**`unknownPluginNames` の変化は望ましい。** `overrides` / `nixpkgsFallback` は
「lock にあるプラグインの derivation を差し替える」ための穴であり、ローカルプラグインには
そもそも derivation も farm エントリも無い。今日その名前を書いてもビルドされる src は
「GitHub から取ってきた、runtime では読まれないコピー」であり、**書いた意味は元から無かった**。
#47 後は「効果が無い」ことが警告として見えるようになる。これは `unknownPluginNames` が
*"a name that matches nothing in the lock is a typo that would otherwise be a silent no-op"* として
存在している目的そのものなので、`localPlugins` を見るように広げる変更は**しない**(§5.6)。

**Nix 側の fixture も増やさない。** `tests/fixtures/dev-plugins/nvimx-lock/plugins.json` に
`dir` のみ由来のエントリを足しても、`plugins.json` の形が `dev` 由来と同じである以上、
`checks.dev-plugins` が新しく固定できる事実は 1 つも無い(既に `bare.nvim` が「`dir` の無いキー」を、
`dirred.nvim` が「記録された `dir` を読まないこと」を固定している)。
足せば `builtins.attrNames locked.devDirs` の assert を書き換えるだけの純損である。

`checks.dev-plugins` の runtime 半分の `dirred.nvim`(spec が `dir` を書いたプラグインが `dev_dirs` を無視することの
assert)は `meta.lua:216` の短絡を固定しており、**その短絡は `dev` の有無に依存しない**
(`:214-217` は `plugin.dev` を見ずに `plugin.dir` だけで分岐する)。したがって §1.4 の事実は
**既存の check が既に守っている**。新しい runtime assert は要らない(§6.2.1)。

### 3.8 #49 のコードは無変更 — ただし `dir` のみの lazy.nvim の**分類は変わる**(実測)

#49 は `resolve.lua` のメインループに `dev/dir` → `is_lazy` → 通常 の順の 3 分岐を入れ、
`docs/plans/49-lazy-nvim-collision.md` §3.4 で「`dev`/`dir` な lazy.nvim は `local_plugins` に行き、
`lazyNvim` は synthetic のまま = #49 の対象外」と決めた。

**#49 のコードは 1 バイトも変えないが、「何も起きない」わけではない。**
spec `{ "folke/lazy.nvim", dir = "/src/lazy.nvim", tag = "v11.0.0", pin = true }` に対する実測:

| | 修正前 | 修正後 |
|---|---|---|
| `lazyNvim` | `synthetic: false`, `tag: "v11.0.0"`, `pin: true` | `synthetic: true`(`tag` / `pin` を持たない合成リテラル) |
| `localPlugins` | `{}` | `{ "lazy.nvim": { "dir": "/src/lazy.nvim" } }` |
| 生成 flake の `lazy-nvim` の URL | `github:folke/lazy.nvim/refs/tags/v11.0.0` | `github:folke/lazy.nvim`(= `flake.lock` の該当ノードが動く) |
| 名前なし `--update` の plan | `tokyonight-nvim` のみ | `lazy-nvim` が**増える**(`pin = true` が効かなくなる) |

これは §3.4 の表の最初の 5 経路ではなく **6 番目の経路**、すなわち `lazy_is_spec` / `lazy_pinned` を通る変化である。

**この変化は正しい方向だと判断する。** 理由:

1. **順序が既にそう決まっている。** 3 分岐の先頭は `if p.dev or p.dir then` で `is_lazy` より**前**にあり、
   `resolve.lua` のコメントが *"dev/dir wins over is_lazy"* と明示している。
   #47 は `p.dir` が立つ範囲を広げるだけで、分岐の順序にも条件式にも触らない。
2. **`dev` の有無で lazy.nvim の扱いが変わる非対称が消える。** `{ "folke/lazy.nvim", dev = true, dir = ... }` は
   今日も `local_plugins` に行く。`dev` を書き忘れただけで `lazyNvim` スロットの意味が変わるのは、
   #49 §3.4 が明文で決めた扱いと食い違っている。#47 はその食い違いを解消する。
3. **`lazy_pinned` の意味が正しくなる。** #49 §3.6 は「`dev`/`dir` な lazy.nvim では `lazyNvim` は synthetic であり、
   尊重すべき `pin` がそもそも存在しないので、素の `--update` は合成 seed input を必ず更新する」と決めている。
   修正後の挙動は**その規則そのもの**である。

**ただし「ユーザーが書いた `tag` / `pin` が効かなくなる」ことは事実であり、§7 に明記する。**
`dir` を書いた時点で lazy はその作業ツリーを使い、`tag` も `pin` も参照しない
(`git.lua:118-123`)ので、消えるのは「lazy も見ない指定」だが、
**生成 flake の URL と `flake.lock` のノードは実際に動く**ので黙って通すべき変化ではない。

**ガード**: `tests/fixtures/lazy-self/raw-spec-dir-only.json` を足し、`checks.resolve-lazy-self` に
ケースを 1 つ加える(§5.2 / §5.4.1)。`resolve.lua` は無変更なので**手書き raw-spec で足りる**。

**このケースが守るものを正確に言う。** 手書き raw-spec は `extract.lua` を通らないので、
**#47 の本体(extract が `dir` を載せること)はここでは守れない** —— そのガードは
`checks.extractor-local-dir` のステップ 1 の「`dir` を持つのはちょうど 6 件」だけである。
このケースが守るのは **#49 の `lazy_is_spec` の `.dir` 項**(摂動 (l))と
**メインループの `dev/dir` 分岐**(摂動 (e))の 2 つで、あわせて
「`dir` のみの lazy.nvim はこう分類される」を実行可能な形で文書化する役割を持つ。


つまり **#47 は #49 の 3 分岐の 1 番目の枝に入る母集団を広げるだけ**であり、
2 番目・3 番目の枝の条件も、`seen_inputs` の予約シードも、衝突検出も影響を受けない。
`{ "folke/lazy.nvim", dir = ... }` は `to_input_name` に到達しないので、予約名衝突にもならない。

`checks.resolve-lazy-self` の既存 fixture 5 本(`raw-spec-devpin.json` を含む)はどれも手書き raw-spec なので、
extract の変更は届かず**既存の出力は 1 バイトも動かない**(§4.5 で実測)。
新ケース(§5.4.1)が足す `raw-spec-dir-only.json` は、`raw-spec-devpin.json` と同じ位置に居る
「`dev` を書かなかった版」であり、`dev` の有無で扱いが変わらなくなったことを固定する。

### 3.9 まとめ — 変更点

| # | ファイル | 変更 |
|---|---|---|
| 1 | `lua/nvimx/extract.lua` | `local_dir(p, root_prefix)` を新設(`dump_plugin` の直前)。`dump_plugin` に `root_prefix` 引数を足し、`dir = p.dev and p.dir or nil` を `dir = local_dir(p, root_prefix)` に。`capture()` で `Config.options.root .. "/"` を 1 回作って渡す |
| 2 | `lua/nvimx/extract.lua` | ファイル冒頭の `effective_version` 前のコメントのうち、**"a plugin with an explicit `dir` and no `dev` is a different story ... tracked separately"** の段落を事実に合わせて書き換える(§5.1) |
| 3 | `tests/fixtures/local-dir-config/init.lua` | 新規 fixture(§5.2) |
| 4 | `tests/fixtures/import-lazy-lock/raw-spec-dir-only.json` | 新規 fixture(§5.2) |
| 5 | `tests/fixtures/lazy-self/raw-spec-dir-only.json` | 新規 fixture(§5.2)。§3.8 の分類変更のガード |
| 6 | `flake.nix` | `checks.extractor-local-dir` を新設(§5.3) |
| 7 | `flake.nix` | `checks.resolve-import-lazy-lock` にケースを 1 つ追加(§5.4)。既存の呼び出し・fixture・golden・3 箇所の `19` は 1 バイトも触らない |
| 8 | `flake.nix` | `checks.resolve-lazy-self` にケースを 1 つ追加(§5.4.1)。既存の 5 ステップ・5 fixture・golden 2 本は 1 バイトも触らない |
| 9 | `docs/architecture.md` / `README.md` / `nix/home-manager/default.nix` の 2 description | §5.5 |
| 10 | `tests/fixtures/dev-plugins/nvimx-lock/plugins.json` の `_comment` **2 箇所** | #47 で偽になる記述の訂正(最終行と `bare.nvim` 段落)。**データは 1 バイトも動かさない**(§5.5 / §5.6) |
| — | `lua/nvimx/resolve.lua` | **無変更**(§3.4 の 6 経路) |
| — | `nix/lib/**` | **無変更**(§3.7) |

---

## 4. 既存機能との関係

### 4.1 #26(`devPlugins` / `devPath`)

#26 は「`localPlugins` のキーを Nix 側に読ませる」機能であり、#47 はその母集団を広げるだけである。
`docs/plans/26-dev-plugins.md` §7 R2 が

> `extract.lua:114` の `dir = p.dev and p.dir or nil` により、`{ "o/x.nvim", dir = "..." }`(`dev` 無し)は
> raw-spec に `dir` を残さない。……これは既存の欠落であり、本件では**悪化も改善もしない**。

と書いた申し送りが、本件で解消される。

**#26 が確立した意味論のうち、本件が変えないもの**:

- `devDirs` の値は必ず `<devPath>/<name>`。`localPlugins[*].dir` は読まない(§3.7)。
- `dir` を書いたプラグインでは `devPath` が効かない(lazy が短絡する)。
  README と 2 つの option description がその限定を明記している。
  **#47 はこの記述の適用範囲を「`dev = true` かつ `dir` を書いた場合」から「`dir` を書いた場合」全般に広げる。**
  そのままでは README の *"Plugins your lazy spec already marks `dev = true` need no entry here"* が
  `dir` のみの spec を取りこぼすので、文言を更新する(§5.5)。
- `docs/architecture.md` の「Local plugin development」の edge-case 行と `dev.path is a function` の項も、
  `localPlugins` を「the spec's own `dev = true` plugins」と説明しているので更新が要る(§5.5)。

### 4.2 #56(`localPlugins` にマシン固有の `dir` を記録するのをやめる)

**本件は #56 の結論を先取りしない。** 記録する値は lazy が正規化したものそのままで(§3.3)、
そのうち 2 通り(`dev = true` 単独、`dir = "~/..."`)は `$HOME` を含む —— #56 が問題にしている状態が、
#47 で**エントリ数だけ増える**。

本件が #56 のためにやること:

1. **本件のどの assert も `plugins.json` の `localPlugins[*].dir` の**値**を見ない**(§3.3)。
   `dir` の値を assert するのは新 check の raw-spec に対してだけで、そちらは `extract.lua` 自身の契約である。
   したがって **#56 が option 1(`resolve.lua` が `{ }` を書く)を採っても、本件の check は 1 行も動かない。**
2. **#56 の option 2 への申し送り(重要)**: option 2 は「ユーザーが書いた `dir` だけを記録する」ために
   `extract.lua` で `rawget` を使うことを提案している。**#47 の後、raw-spec の `dir` は
   「記録すべき値」であると同時に「ローカル判定の唯一の材料」でもある**(§3.4 の 6 経路がすべてこれを読む)。
   したがって option 2 は **`dir` を絞り込んではならない** —— 絞り込むと `dev = true` 単独のプラグインが
   raw-spec から `dir` を失い、`p.dev` だけが頼りになり、`dir` を書いたのに root 配下を指すケースが
   誤分類される。option 2 を採るなら **`dir` は残したまま別フィールド(例 `dirFromSpec`)を足し、
   `resolve.lua` の `local_plugins` がそちらを記録する**形にしなければならない。
   この一文が無いと、#56 が #47 を静かに再発させる。

なお #56 の Notes が言及している `tests/fixtures/dev-plugins/nvimx-lock/plugins.json` の `bare.nvim`
(`dir` を持たないエントリ)については、本件は何もしない(§3.7)。

### 4.3 #49(spec の lazy.nvim)

§3.8 のとおり。**#49 のコードは 1 行も触らないが、`dir` のみの lazy.nvim の分類は実際に変わる**
(`lazyNvim` が synthetic に戻り、生成 flake の `lazy-nvim` URL と `flake.lock` のノードが動き、
素の `--update` の plan に `lazy-nvim` が戻る。実測は §3.8 の表)。
これは #49 の `lazy_is_spec` の `dev`/`dir` 除外が `dir` のみの lazy.nvim にも効くようになった結果であり、
#49 §3.4 / §3.6 が明文で決めた扱いに一致する方向である。

**既存の `checks.resolve-lazy-self` の出力は 1 バイトも動かない** —— 同 check の fixture 5 本は
すべて手書き raw-spec で、`extract.lua` を通らないからである(§4.5 で実測)。
新しい分類を固定するために **fixture を 1 本足してケースを 1 つ加える**(§5.2 / §5.4.1)。

### 4.4 #42(`defaults.version` の materialize)/ #23(semver)

issue の言うとおり **#42 は症状であって原因ではない**。#42 が入る前からルーティングは壊れていて、
今日の実害(#1.1 の lock 失敗)は #23 が制約を実際に解決するようになったことで顕在化した。
本件は #42 / #23 のコードには触らず、**制約が届く母集団からローカルプラグインを外す**だけである(§3.5)。

`checks.extractor-defaults-version`(#42 の owner)は fixture に `dev`/`dir` プラグインを 1 つも持たないので、
出力は変わらない(§4.5 で実測)。**#42 の check と #47 の check は担当が重ならない**:
前者は「制約が正しく materialize されること」、後者は「materialize された制約がローカルプラグインでは
記録も解決もされないこと」を見る。

### 4.5 既存 check / golden の出力への影響 — **ゼロ**(実測)

まず前提を確認した:

```console
$ grep -rn 'dev *=\|dir *=' tests/fixtures/*/init.lua | grep -v lazypath
(出力なし)
```

**既存の fixture config は 1 つも `dev` / `dir` を使っていない。** したがって新しい判定が値を変えるプラグインが
1 つも存在しない。実際に extract を通して確認した:

```console
$ diff -u tests/fixtures/golden/basic-config.raw-spec.json got.json && echo SAME
SAME
$ diff -q <(jq -S . dv-before.json) <(jq -S . dv-after.json) && echo "defaults-version: SAME"
defaults-version: SAME
```

手書き raw-spec を使う check(`resolve-*` / `update-summary` / `genflake-golden` / `resolve-lazy-self`)は
`extract.lua` を通らないので構造的に無影響である。`spec-matrix/raw-spec.json` の `devel.nvim` と
`import-lazy-lock/raw-spec.json` の `local.nvim` はどちらも `dev` + `dir` の両方を持っているので、
仮に extract を通しても分類は変わらない。

**既存 golden の再生成は 1 本も要らない。** 本件で増える fixture は 3 本、golden は 0 本である。
既存ファイルで編集するのは `tests/fixtures/dev-plugins/nvimx-lock/plugins.json` の `_comment` の 2 箇所だけで、
これは `make-env.nix` が読まない余剰キーなので `checks.dev-plugins` の出力も動かない(§5.5)。

### 4.6 check の担当分け

| 軸 | 担当 |
|---|---|
| extract の raw-spec 全体のスナップショット | `extractor-snapshot` |
| `defaults.version` の materialize 規則 | `extractor-defaults-version`(#42) |
| **`dev`/`dir` の raw-spec への載り方と、その先のルーティング** | **本件 `extractor-local-dir`** |
| `localPlugins` を Nix 側が消費する経路(`devDirs` / `unknownDevPluginNames` / runtime の短絡) | `dev-plugins`(#26) |
| `--import-lazy-lock` の報告分類 1-9(本件が動かすのは 3L の発火条件だけ) | `resolve-import-lazy-lock`(#25)。**本件はそこに 1 ケース足す** |
| **`lazyNvim` スロットそのもの**(合成 / 統合、予約名衝突、pin 凍結、semver) | `resolve-lazy-self`(#49)。**本件はそこに 1 ケース足す** —— `dir` のみの lazy.nvim がそのスロットから出ていく分類変更(§3.8) |
| spec フィールドのマトリクス / URL 形 / input_url ラダー | `resolve-golden` / `resolve-sources` / `genflake-golden`(#28/#29) |

重ならない。`extractor-local-dir` は **extract から genflake まで 1 本のパイプラインを通す唯一の check**であり、
それは本件の主張が「extract の 1 行が生成 flake の input を 1 本増減させる」という**縦の連鎖**だからである。

---

## 5. 実装手順

### 5.1 `lua/nvimx/extract.lua`

**(a)** `dump_build_step` の直後、`dump_plugin` の直前に `local_dir` を挿入する。
以下は stylua(`stylua.toml`: 2-space / AutoPreferDouble / 120 桁)と luacheck を**実際に通した形**である
(`stylua --check` が clean、`luacheck` が 0 warnings / 0 errors):

```lua
-- lazy fills in `dir` for *every* plugin, so `p.dir ~= nil` says nothing about whether the user
-- keeps this plugin in a working tree: Meta:_rebuild short-circuits on a dir the spec wrote
-- (lua/lazy/core/meta.lua:216-217), derives one for `dev = true` (:229-237), and otherwise falls
-- back to `<root>/<name>` (:238). Dumping p.dir unconditionally would therefore send the entire
-- spec down resolve.lua's localPlugins branch and leave `plugins` empty -- silently, with exit 0.
-- What separates the two is the root itself, the same axis lazy uses for `_.is_local`
-- (lua/lazy/core/plugin.lua:244-252): a dir under Config.options.root is one lazy manages.
-- Testing the prefix meta.lua:238 itself builds is what makes that fallback value come back nil,
-- so a `dir` with no `dev` keeps its dir here instead of being locked, fetched and farmed as an
-- ordinary remote plugin (#47).
-- This is deliberately not a promise that nvimx and lazy always classify a plugin the same way:
-- the lock app extracts inside a throwaway XDG sandbox, so a dir written as a literal path under
-- the *user's* runtime root looks local here and remote to lazy at runtime. Nothing available at
-- extraction time closes that gap -- `_.is_local` least of all, since lazy sets it in
-- update_state(), which only the real lazy.setup runs, never Plugin.Spec.new.
---@param p table the plugin object normalized by lazy
---@param root_prefix string Config.options.root .. "/", the same expression meta.lua:238 uses
---@return string|nil the plugin's directory, or nil when lazy would manage it under its own root
local function local_dir(p, root_prefix)
  if type(p.dir) ~= "string" or p.dir:find(root_prefix, 1, true) == 1 then
    return nil
  end
  return p.dir
end
```

**(b)** `dump_plugin` のシグネチャに `root_prefix` を足し(`---@param` も)、
`dir = p.dev and p.dir or nil,` を `dir = local_dir(p, root_prefix),` に置き換える。

**(c)** `capture()` の中、`local default_version = ...` の直後に

```lua
  -- meta.lua:238's own fallback expression, captured once: it decides local vs remote below.
  local root_prefix = Config.options.root .. "/"
```

を置き、`dump_plugin(p, default_version)` の呼び出しに渡す。
**`Config.setup(...)` より後でなければならない** —— `Config.options.root` はそこで確定する。

**(d)** ファイル冒頭付近、`effective_version` の直前のコメントの

> Local plugins are excluded by lazy first of all (git.lua:119-123). `dev` ones need no guard here
> because resolve.lua routes them to localPlugins, but a plugin with an explicit `dir` and no
> `dev` is a different story: dump_plugin only records `dir` for dev plugins, so resolve treats it
> as remote and this constraint reaches plugins.json even though lazy would never consult it.
> Routing those to localPlugins is a pre-existing gap, tracked separately.

を、**gap が閉じたことを述べる形**に書き換える。含めること:

- `git.lua:118-123` の early return は `commit`(`:127`)/ `tag`(`:133`)/ `defaults.version`(`:141`)より前にあること(既存)。
- ローカルプラグインに guard が要らないのは、`local_dir` が `dev` 由来のものも spec が書いた `dir` も
  同じ 1 つの述語で捕まえ、`resolve.lua` の `localPlugins` に送るからであること
  (唯一の例外は `dev.path` が lazy の root を指す病的なケースで、そこは `resolve.lua` の
  `p.dev or p.dir` が拾う。§7)。
- したがって materialize された制約はローカルプラグインの `plugins.json` に**到達しない**こと。
  `effective_version` に 2 つ目の述語を置かない理由(§3.5)。

**`lua/nvimx/` は stylua / luacheck の対象**(#31)なので `nix fmt -- --ci` を通すこと。

### 5.2 fixture(新規 3 本)

#### `tests/fixtures/local-dir-config/init.lua`

`tests/fixtures/defaults-version-config/init.lua` と同じ形(lazypath の bootstrap スニペット付き、
`nvimx-lock/` は持たない)。**リポジトリ初の、spec が `dev` / `dir` を使う fixture config である**(§4.5)。

```lua
-- A lazy.nvim-style config whose spec sets `dir` without `dev` (#47), for
-- checks.extractor-local-dir. The first fixture config to use dev/dir at all -- every other
-- tests/fixtures/*/init.lua is remote-only, which is a large part of why this gap survived.
-- Never built, only extracted and resolved, so it ships no nvimx-lock/ directory.
--
-- dirabs / dirtilde / dirrel are the three ways Util.norm can leave a dir the spec wrote
-- (lua/lazy/core/meta.lua:216-217): an absolute path verbatim, a "~" expanded against the
-- extracting machine's $HOME, and a relative path left relative. nvimx records exactly what lazy
-- produced and absolutizes nothing -- doing otherwise would make nvimx point somewhere lazy does
-- not. dirnoname and sibling.nvim below are not shapes but separate axes (no url at all; a path
-- that only the trailing slash in the predicate keeps out of lazy's root). None of the
-- directories has to exist: lazy's dev.fallback is false and nothing checks.
--
-- tokyonight.nvim carries a tag so that the defaults.version below never reaches it (extract.lua's
-- effective_version stops at tag). That leaves the local plugins as the only carriers of a version
-- constraint, which is one of the two ways a routing regression kills the check's resolve -- the
-- other being dirnoname, which has no url for source.parse to work with. Either way the resolve
-- exits non-zero, which is what lets the check run with neither git nor --lazy and treat "exit 0"
-- as the assertion. (In practice dirnoname's error is the one that surfaces, because
-- report_resolve_errors() runs first; the check still asserts the constraints exist so that the
-- second route does not quietly disappear.)
local lazypath = vim.fn.stdpath("data") .. "/lazy/lazy.nvim"
if not (vim.uv or vim.loop).fs_stat(lazypath) then
  local lazyrepo = "https://github.com/folke/lazy.nvim.git"
  vim.fn.system({ "git", "clone", "--filter=blob:none", lazyrepo, lazypath })
end
vim.opt.rtp:prepend(lazypath)

require("lazy").setup({
  -- An ordinary remote plugin. lazy still fills in its dir (<root>/<name>), and it must NOT be
  -- recorded: dumping p.dir unconditionally routes this one -- and every other remote plugin --
  -- into localPlugins, leaving `plugins` empty while the resolve still exits 0.
  { "folke/tokyonight.nvim", tag = "v1.0.0" },
  -- #47 itself: a dir with no dev, in each of the three shapes.
  { "o/dirabs.nvim", dir = "/nvimx-fixture/dirabs" },
  { "o/dirtilde.nvim", dir = "~/nvimx-fixture/dirtilde" },
  { "o/dirrel.nvim", dir = "nvimx-fixture/dirrel" },
  -- The most natural way to write a dir-only plugin: no repo shorthand, because there is no repo.
  -- lazy names it after the path's basename and leaves url unset, which used to make resolve.lua
  -- fail outright with "has no url" -- locking this config was impossible, not merely wasteful.
  { dir = "/nvimx-fixture/dirnoname" },
  -- A sibling of lazy's own root, built from stdpath so it tracks whatever root the sandbox has.
  -- This is what makes the trailing slash in the predicate's prefix load-bearing: <root> is
  -- ".../nvim/lazy", so "<root>/" does not match ".../nvim/lazy-sibling/..." but "<root>" does.
  -- Degrade the prefix and this plugin silently stops being recorded.
  { "o/sibling.nvim", dir = vim.fn.stdpath("data") .. "/lazy-sibling/sibling.nvim" },
  -- dev with no dir of its own: unchanged by #47, kept so the check pins that the new predicate
  -- still routes it. Its dir comes from lazy's own dev.path, not from the spec.
  { "o/bare.nvim", dev = true },
}, {
  -- #42 materializes this onto every plugin whose ref is not already decided. It is how #47
  -- surfaced: a dir-only plugin used to carry it all the way into #23's gate.
  defaults = { version = "*" },
})
```

**`git clone` は走らない** —— check が `$sb/data/nvim/lazy/lazy.nvim` に seed を symlink するので
`fs_stat` が真になる(`checks.extractor-defaults-version` と同じ手当て)。

この fixture を extract に通したときの実測(修正後):

```console
$ jq -S 'del(.lazyNvim)' raw-spec.json
{
  "disabled": [], "notifs": [],
  "plugins": {
    "bare.nvim":      { "dev": true, "dir": "<HOME>/projects/bare.nvim", "name": "bare.nvim",
                        "short": "o/bare.nvim", "url": "https://github.com/o/bare.nvim.git",
                        "version": "*", "versionFromDefaults": true },
    "dirabs.nvim":    { "dir": "/nvimx-fixture/dirabs", ..., "version": "*", "versionFromDefaults": true },
    "dirnoname":      { "dir": "/nvimx-fixture/dirnoname", "name": "dirnoname",
                        "version": "*", "versionFromDefaults": true },
    "dirrel.nvim":    { "dir": "nvimx-fixture/dirrel", ..., "version": "*", "versionFromDefaults": true },
    "dirtilde.nvim":  { "dir": "<HOME>/nvimx-fixture/dirtilde", ..., "version": "*", "versionFromDefaults": true },
    "sibling.nvim":   { "dir": "<XDG_DATA_HOME>/nvim/lazy-sibling/sibling.nvim", ...,
                        "version": "*", "versionFromDefaults": true },
    "tokyonight.nvim":{ "name": "tokyonight.nvim", "short": "folke/tokyonight.nvim",
                        "tag": "v1.0.0", "url": "https://github.com/folke/tokyonight.nvim.git" }
  }
}
```

**`dirnoname` に `short` も `url` も無い**ことに注意(§1.1.1)。`tokyonight.nvim` にだけ `dir` も `version` も無い。

resolve(`--lazy` 無し、`git` 無し)の実測:

```console
rc=0
{
  "localPlugins": {
    "bare.nvim":     { "dir": "<HOME>/projects/bare.nvim" },
    "dirabs.nvim":   { "dir": "/nvimx-fixture/dirabs" },
    "dirnoname":     { "dir": "/nvimx-fixture/dirnoname" },
    "dirrel.nvim":   { "dir": "nvimx-fixture/dirrel" },
    "dirtilde.nvim": { "dir": "<HOME>/nvimx-fixture/dirtilde" },
    "sibling.nvim":  { "dir": "<XDG_DATA_HOME>/nvim/lazy-sibling/sibling.nvim" }
  },
  "plugins": { "tokyonight.nvim": { ... "inputName": "tokyonight-nvim" ... } },
  "schemaVersion": 1,
  "warnings": []
}
```

genflake の実測:

```nix
# This file is generated by nvimx. Do not edit by hand.
{
  inputs = {
    lazy-nvim = {
      url = "github:folke/lazy.nvim";
      flake = false;
    };
    tokyonight-nvim = {
      url = "github:folke/tokyonight.nvim/refs/tags/v1.0.0";
      flake = false;
    };
  };
  outputs = _: { };
}
```

**golden ファイルは置かない。** `dirtilde.nvim` と `bare.nvim` の値がサンドボックスの `$HOME` を含むので
byte 一致では固定できない。代わりに `jq -e --arg h "$HOME"` で見る(§6.1)——
`$HOME` を式に持ち込むことそのものが、`~` を展開するのが nvimx ではなく lazy であることの assert になる。

#### `tests/fixtures/import-lazy-lock/raw-spec-dir-only.json`

`raw-spec-lazy-self.json`(#49 が同じ理由で新設した)と同じ位置取り。既存の `lazy-lock.json` をそのまま使う。

- `local.nvim`: `dir = "/some/local/path"`(**`dev` は書かない**)、`url = "file:///nvimx-nonexistent/local.nvim"`、
  `version = "*"` + `versionFromDefaults = true`。
- `plain.nvim`: 既存 `raw-spec.json` と同じもの(`lazy-lock.json` に `{ "commit": "7777…" }` があり seed できる)。
- それ以外は入れない。

`_comment` に書くこと:

(a) 手書きである理由と、`checks.resolve-import-lazy-lock` のどのケースが使うか。
(b) `dev` を**書いていない**ことが本質であること(書くと既存 `raw-spec.json` の `local.nvim` と同じものになる)。
(c) **`url` がある理由**: 退行時(`dir` が無視されてリモート扱いされたとき)に
   `source.parse` が `has no url` で落ちるのを避け、**`local.nvim` が実際に pin されるところまで進ませる**ため。
   そうしないと退行の症状が「別のエラーで落ちる」になり、§5.4 が assert したい
   「classification 3L が出る / 出ない」の対比が取れない。

**逆に、`version` を「semver ゲートのガード」として説明してはならない —— それは実測で偽である。**
`--import-lazy-lock` は #23 のゲートの**前**に `resolvedRef` を seed し、
`resolve.lua` 自身のコメントが *"a non-null resolvedRef closes that gate"* と書いている。
`local.nvim` が `lazy-lock.json` にエントリを持つのがこのケースの前提なので、
**退行させてもゲートは発火せず exit 0 になる**。実測(`dir` を落とした raw-spec):

```console
rc=0
[nvimx] import: pinned local.nvim to cccccccccccc
[nvimx] import: pinned plain.nvim to 777777777777
[nvimx] import: the config-wide version constraint "*" is not validated for 1 plugin(s) pinned from lazy-lock.json (run nvimx-lock --update <name> to resolve it again): local.nvim
[nvimx] import: 1 pinned, ... → 2 pinned, 0 skipped
```

**`version` を残す意味は別のところにある**: 退行時にだけ `is not validated` の 1 行が出るので、
その**不在**を assert すれば「ローカルプラグインが import の pin 経路に乗っていない」ことを直接固定できる。
`_comment` にはそう書く(§5.4 の 3 番目の grep)。

#### `tests/fixtures/lazy-self/raw-spec-dir-only.json`

§3.8 の分類変更を固定するための手書き raw-spec。`resolve.lua` は無変更なので extract を通す必要は無く、
`checks.resolve-lazy-self` が持つ既存 5 本と同じ流儀で足りる。

```json
{
  "_comment": [
    "Hand-written raw-spec.json for checks.resolve-lazy-self's #47 case: a spec lazy.nvim with a",
    "`dir` and NO `dev`. Before #47 extract.lua dropped that dir, so this entry reached resolve as",
    "an ordinary spec lazy.nvim and decided the lazy-nvim input -- tag, pin and all. Now it is a",
    "local plugin like `dev = true` + dir already was, so lazyNvim falls back to the synthetic",
    "literal and the seed input moves on a bare --update again (#49's own rule for a dev/dir",
    "lazy.nvim).",
    "tag and pin are here precisely because they are what stops applying: without them the case",
    "would only prove that lazyNvim went synthetic, not that the ref fields a user wrote stopped",
    "deciding the input. tokyonight.nvim is the control -- it must keep its inputName and its",
    "update-plan entry throughout.",
    "Next to raw-spec-devpin.json, which covers the dev = true + dir + pin form: this one drops",
    "dev and adds short / url / tag, so that genflake has a source to build a tagged URL from and",
    "the case can show that URL going bare. devpin needs none of that -- it never reaches",
    "genflake, so it has no URL to show going bare -- so the two fixtures are not one key apart."
  ],
  "disabled": [],
  "notifs": [],
  "plugins": {
    "lazy.nvim": {
      "name": "lazy.nvim",
      "short": "folke/lazy.nvim",
      "url": "https://github.com/folke/lazy.nvim.git",
      "dir": "/nvimx-fixture/lazy.nvim",
      "tag": "v11.0.0",
      "pin": true
    },
    "tokyonight.nvim": {
      "name": "tokyonight.nvim",
      "short": "folke/tokyonight.nvim",
      "url": "https://github.com/folke/tokyonight.nvim.git"
    }
  }
}
```

### 5.3 `flake.nix` — 新 check `extractor-local-dir`

**挿入位置**: `checks.extractor-defaults-version` の終端 `'';` の直後、
`checks.resolve-build-warnings` の説明コメント(*"A build nvimx cannot run ..."* で始まる)の直前。
extract 系が `extractor-snapshot` / `extractor-no-setup` / `extractor-defaults-version` と並んでいる位置を保つ。

構造は `checks.extractor-defaults-version` に倣う(XDG サンドボックス + seed の symlink)。
以下は nixfmt(`nixfmt-rfc-style`)を実際に通した形である。

```nix
          # #47: a spec plugin with an explicit `dir` and no `dev`. lazy treats that exactly like a
          # `dev = true` one -- Meta:_rebuild short-circuits on any dir the spec wrote
          # (lua/lazy/core/meta.lua:216-217), and get_target returns at its very first branch
          # (lua/lazy/manage/git.lua:118-123), before commit / tag / defaults.version are consulted
          # at all -- but extract.lua used to record `dir` only for dev plugins, so resolve.lua
          # filed it as an ordinary remote: an inputName, a github source, a flake input and a farm
          # entry, for a plugin the user keeps in a working tree. Since #42 materializes
          # defaults.version per plugin, it also picked up a constraint that #23 then resolves for
          # real -- measured, that means a git ls-remote against github.com for a plugin on the
          # user's own disk, and a failed lock when no tag matches.
          #
          # This check starts from a real config rather than a hand-written raw-spec because the
          # fact that makes the obvious fix wrong is lazy's, not nvimx's: lazy fills in plugin.dir
          # for *every* plugin (meta.lua:238 falls back to <root>/<name>), so `dir = p.dir` would
          # route the whole spec into localPlugins and leave `plugins` empty -- silently, exit 0.
          # extract.lua tests the prefix meta.lua:238 itself builds, which is the same axis lazy
          # judges _.is_local on (plugin.lua:244-252) -- close to it, not identical to it, since
          # extraction runs against a sandbox root rather than the user's (see extract.lua's own
          # comment on local_dir).
          #
          # Deliberately without pkgs.git and without --lazy, so that "the resolve exits 0" is
          # itself the assertion -- the same trick checks.resolve-import-lazy-lock uses. Filing any
          # of the fixture's local plugins as remote kills the resolve one of two ways: dirnoname
          # has no url at all (source.parse rejects it), and the other five carry a materialized
          # defaults.version that fires #23's gate with no --lazy to satisfy it. Today it is always
          # the first, since report_resolve_errors() runs before the fail() for a missing --lazy.
          # Step 1 asserts the version constraints exist so the second route stays a fact about
          # this fixture rather than an assumption this comment quietly outlives.
          # The dev/dir *consumer* side (devDirs, and lazy ignoring them at runtime) is
          # checks.dev-plugins' (#26); the import report's classification matrix is
          # checks.resolve-import-lazy-lock's (#25), which gets this issue's one case added to it.
          extractor-local-dir =
            pkgs.runCommand "extractor-local-dir"
              {
                nativeBuildInputs = [
                  pkgs.neovim-unwrapped
                  pkgs.jq
                ];
              }
              ''
                export HOME=$TMPDIR
                sb=$TMPDIR/sandbox
                mkdir -p $sb/config $sb/data/nvim/lazy $sb/state $sb/cache
                ln -s ${./tests/fixtures/local-dir-config} $sb/config/nvim
                # Makes the fixture's lazypath fs_stat succeed, so its bootstrap snippet never
                # reaches the `git clone` branch. Same handling as extractor-defaults-version.
                ln -s ${lazy-nvim} $sb/data/nvim/lazy/lazy.nvim
                env \
                  XDG_CONFIG_HOME=$sb/config \
                  XDG_DATA_HOME=$sb/data \
                  XDG_STATE_HOME=$sb/state \
                  XDG_CACHE_HOME=$sb/cache \
                  NVIMX_LAZY_SEED=${lazy-nvim} \
                  NVIMX_OUT=$sb/raw-spec.json \
                  nvim --headless --cmd "luafile ${./lua/nvimx/extract.lua}"

                # ... steps 1-5, see the plan's SS6.1 ...

                touch $out
              '';
```

ステップ 1-5 の中身(すべてこのビルダの中):

```bash
# (1) extract.lua's own contract. The dir shapes are recorded exactly as lazy normalized them:
#     absolute verbatim, "~" expanded against $HOME by Util.norm, relative left relative.
#     Absolutizing the relative one here would put nvimx somewhere lazy is not.
jq -e '.plugins["dirabs.nvim"].dir == "/nvimx-fixture/dirabs"' $sb/raw-spec.json > /dev/null
jq -e --arg h "$HOME" '.plugins["dirtilde.nvim"].dir == ($h + "/nvimx-fixture/dirtilde")' \
  $sb/raw-spec.json > /dev/null
jq -e '.plugins["dirrel.nvim"].dir == "nvimx-fixture/dirrel"' $sb/raw-spec.json > /dev/null
# The shorthand-less form: lazy names it after the path and leaves url unset. Locking this used
# to be impossible ("has no url"), not merely wasteful.
jq -e '.plugins["dirnoname"].dir == "/nvimx-fixture/dirnoname"' $sb/raw-spec.json > /dev/null
jq -e '.plugins["dirnoname"] | has("url") | not' $sb/raw-spec.json > /dev/null
# A sibling of lazy's root. Recorded only because the predicate's prefix ends in "/": drop that
# slash and "<root>" prefix-matches "<root>-sibling/..." and this plugin silently goes remote.
jq -e '.plugins["sibling.nvim"] | has("dir")' $sb/raw-spec.json > /dev/null
# dev with no dir of its own still works, and its dir comes from lazy's dev.path
jq -e '.plugins["bare.nvim"].dev == true' $sb/raw-spec.json > /dev/null
jq -e --arg h "$HOME" '.plugins["bare.nvim"].dir == ($h + "/projects/bare.nvim")' \
  $sb/raw-spec.json > /dev/null
# The other half of the predicate, and the one a `dir = p.dir` regression breaks: an ordinary
# remote plugin has a dir too (<root>/<name>), and it must not be recorded.
jq -e '.plugins["tokyonight.nvim"] | has("dir") | not' $sb/raw-spec.json > /dev/null
jq -e '[.plugins[] | select(has("dir"))] | length == 6' $sb/raw-spec.json > /dev/null
# Step 2 relies on a routing regression killing the resolve, and #23's gate firing with no --lazy
# is one of the two routes it can take (dirnoname's missing url is the other, and the one that
# actually surfaces today). That route only exists while the constraints do, so pin them here --
# otherwise a later change that stops materializing defaults.version onto local plugins retires
# half of step 2's coverage with nothing going red.
jq -e '.plugins["dirabs.nvim"].version == "*"' $sb/raw-spec.json > /dev/null
jq -e '.plugins["dirabs.nvim"].versionFromDefaults == true' $sb/raw-spec.json > /dev/null
jq -e '[.plugins[] | select(.version == "*")] | length == 6' $sb/raw-spec.json > /dev/null
jq -e '[.plugins[] | select(.versionFromDefaults == true)] | length == 6' $sb/raw-spec.json > /dev/null

# (2) resolve, offline and with no --lazy. Exit 0 is the assertion that no local plugin was filed
#     as remote: either route out of the header comment -- dirnoname's missing url, or #23's gate
#     with no --lazy to satisfy it -- would end this non-zero.
nvim -l ${./lua/nvimx}/resolve.lua $sb/raw-spec.json plugins.json 2> resolve.log
[ ! -s resolve.log ]
jq -e '(.localPlugins | keys) ==
       ["bare.nvim","dirabs.nvim","dirnoname","dirrel.nvim","dirtilde.nvim","sibling.nvim"]' \
  plugins.json > /dev/null
jq -e '(.plugins | keys) == ["tokyonight.nvim"]' plugins.json > /dev/null
jq -e '.warnings == []' plugins.json > /dev/null
# Only the *keys* of localPlugins are asserted on, never the recorded dir: nothing in nix/lib
# reads it (#26), and #56 is free to stop recording it without touching this check.

# (3) The lock's own statement of the fix: no flake input for a plugin that lives on disk.
nvim -l ${./lua/nvimx}/genflake.lua plugins.json flake.nix
grep -q 'tokyonight-nvim = {' flake.nix
! grep -qE 'dirabs|dirtilde|dirrel|dirnoname|sibling|bare' flake.nix
[ "$(grep -c 'flake = false;' flake.nix)" -eq 2 ]

# (4) --update by name is fatal for a local plugin, and plugins.json is never written. This is
#     resolve.lua's existing rule; #47 only widens which plugins it applies to.
rc=0
nvim -l ${./lua/nvimx}/resolve.lua $sb/raw-spec.json update.json --update dirabs.nvim \
  2> update.log || rc=$?
[ "$rc" -ne 0 ]
[ ! -e update.json ]
grep -q 'is a local plugin (dev/dir); nothing to lock or update' update.log
grep -q 'dirabs.nvim' update.log

# (5) A bare --update leaves them out of the plan entirely: there is nothing to move.
nvim -l ${./lua/nvimx}/resolve.lua $sb/raw-spec.json all.json --update --update-plan plan.txt
[ "$(wc -l < plan.txt)" -eq 2 ]
grep -qx 'lazy-nvim' plan.txt
grep -qx 'tokyonight-nvim' plan.txt
```

### 5.4 `flake.nix` — `checks.resolve-import-lazy-lock` にケース 1 件

**挿入位置**: `checks.resolve-import-lazy-lock` の builder 末尾、**ステップ `# 18.` の直後・`touch $out` の直前**に
`# 19.` として足す(#49 が `# 18.` を同じ位置に足したのと同じ場所取り)。
**既存の呼び出し・fixture・golden・3 箇所の `19` は 1 バイトも触らない**(§3.6)。追加分だけ:

```bash
# #47: a dir-only plugin that *is* in lazy-lock.json. Before #47 it was filed as remote and got
# pinned from the lock; now it takes classification 3L like any other local plugin, because lazy
# does not record a rev for a local plugin either (lua/lazy/manage/lock.lua:25).
#
# All four assertions matter and none of them is "the resolve exits 0": import seeds resolvedRef
# *before* #23's gate and a non-null resolvedRef closes it, so every way of breaking this still
# exits 0. Narrowing the main loop's dev/dir test pins local.nvim from the lock and reports its
# materialized defaults.version as unvalidated, which the `is not validated` line catches;
# narrowing only this loop's own test leaves it unpinned but unaccounted for, which the skipped
# line and the pinned/skipped counts catch. (The fixture's url exists so either regression gets
# that far instead of dying on "has no url"; it is not a gate guard.)
# $lua / $fx are the builder's own bindings, defined at the top of checks.resolve-import-lazy-lock
# and used by every other step in it.
nvim -l $lua/resolve.lua $fx/raw-spec-dir-only.json dir-only.json \
  --import-lazy-lock $fx/lazy-lock.json 2> dir-only.log
grep -q 'import: skipped local.nvim: it is a local plugin (dev/dir), so there is nothing to pin' \
  dir-only.log
grep -q 'import: 1 pinned, 1 skipped,' dir-only.log
! grep -q 'is not validated' dir-only.log
jq -e '.plugins["local.nvim"] == null' dir-only.json > /dev/null
# Keys only, never the recorded dir: #56 must be able to stop recording it without touching this.
jq -e '.localPlugins | has("local.nvim")' dir-only.json > /dev/null
```

実測(プロトタイプ + 既存 `lazy-lock.json`)。**正しい実装**:

```console
$ nvim -l resolve.lua raw-spec-dir-only.json do.json --import-lazy-lock lazy-lock.json ; echo rc=$?
rc=0
$ grep 'skipped\|pinned\|validated' do.log
[nvimx] import: pinned plain.nvim to 777777777777
[nvimx] import: skipped local.nvim: it is a local plugin (dev/dir), so there is nothing to pin
[nvimx] import: 1 pinned, 1 skipped, 13 ignored, 0 not in lazy-lock.json
$ jq -S '{plugins:(.plugins|keys), localPlugins:(.localPlugins|keys)}' do.json
{ "localPlugins": [ "local.nvim" ], "plugins": [ "plain.nvim" ] }
```

**ルーティングを退行させた場合**(同じ fixture から `dir` を落としたもの):

```console
rc=0
[nvimx] import: pinned local.nvim to cccccccccccc
[nvimx] import: pinned plain.nvim to 777777777777
[nvimx] import: the config-wide version constraint "*" is not validated for 1 plugin(s) pinned from lazy-lock.json (run nvimx-lock --update <name> to resolve it again): local.nvim
[nvimx] import: 2 pinned, 0 skipped, 13 ignored, 0 not in lazy-lock.json
```

**exit 0 のままである。** だから 3 つの grep(`skipped` の存在、`1 pinned, 1 skipped` の数、
`is not validated` の不在)が実際のガードであって、「exit 0 が assert」はこのケースには**当てはまらない**。
`13 ignored` の内訳は `ignored_missing` **10** 件 + `lazy_self` **1** 件(lazy.nvim は
`lock_names` ループの専用分岐 = classification 8 に行き、`ignored_missing` には入らない)+
`import_bad` **2** 件である(実測)。
**行数を assert に焼かないこと**: 前方一致で足り、既存 check が持つ 3 箇所の `19` とは無関係な別ログである。

### 5.4.1 `flake.nix` — `checks.resolve-lazy-self` にケース 1 件

**挿入位置**: `checks.resolve-lazy-self` の builder 末尾、**ステップ `5b` の直後・`touch $out` の直前**に
`5c` として足す。5b(`dev = true` + `dir` + `pin`)の真下に置くことで、
「`dev` を書いた場合」と「書かなかった場合」が並んで読める。
§3.8 の分類変更のガード。**既存の 5 ステップ・5 fixture・golden 2 本は 1 バイトも触らない。**

```bash
# A spec lazy.nvim with a `dir` and no `dev` (#47). extract.lua used to drop that dir, so this
# entry decided the lazy-nvim input like any other spec lazy.nvim -- tag, pin and all. Now it is
# a local plugin, exactly as `dev = true` + dir already was (step 5b), so lazyNvim falls back to
# the synthetic literal, the input URL loses the tag, and a bare --update moves the seed input
# again because there is no longer a spec pin to respect (#49's own rule, now applied
# symmetrically). The lazyNvim slot is this check's, so the new classification is pinned here
# rather than in checks.extractor-local-dir.
#
# What this case can and cannot catch: the raw-spec is hand-written, so extract.lua never runs and
# nothing here would notice #47's actual one-line fix being reverted (checks.extractor-local-dir
# owns that). What it does hold down is the two resolve.lua conditions the new classification
# rests on -- the main loop's dev/dir branch, which three of the four jq lines and both genflake
# greps follow (`.plugins["lazy.nvim"] == null` stays true either way: a spec lazy.nvim lands in
# the lazyNvim slot, never in `plugins`), and lazy_is_spec's own `.dir` term, which only the
# update-plan lines follow.
nvim -l $lua/resolve.lua $fx/raw-spec-dir-only.json dir-only.json --lazy $lazy \
  --update --update-plan plan-dir-only.txt 2> /dev/null
jq -e '.lazyNvim.synthetic == true' dir-only.json > /dev/null
jq -e '.lazyNvim | has("tag") | not' dir-only.json > /dev/null
jq -e '.localPlugins | has("lazy.nvim")' dir-only.json > /dev/null
jq -e '.plugins["lazy.nvim"] == null' dir-only.json > /dev/null
nvim -l $lua/genflake.lua dir-only.json dir-only.flake.nix
grep -q 'url = "github:folke/lazy.nvim";' dir-only.flake.nix
! grep -q 'refs/tags/v11.0.0' dir-only.flake.nix
# The seed input is back in the plan: a dev/dir lazy.nvim has no pin worth respecting.
grep -qx 'lazy-nvim' plan-dir-only.txt
grep -qx 'tokyonight-nvim' plan-dir-only.txt
```

実測(プロトタイプ、同じ spec の `dir` あり / なし):

| | `dir` なし(= 修正前の raw-spec) | `dir` あり(= 修正後) |
|---|---|---|
| `lazyNvim` | `{"synthetic":false,"tag":"v11.0.0","pin":true,...}` | `{"inputName":"lazy-nvim","source":{...},"synthetic":true}` |
| `localPlugins` | `[]` | `["lazy.nvim"]` |
| 生成 flake | `url = "github:folke/lazy.nvim/refs/tags/v11.0.0";` | `url = "github:folke/lazy.nvim";` |
| plan | `tokyonight-nvim` | `lazy-nvim` / `tokyonight-nvim` |

### 5.5 ドキュメント

| ファイル | 作業 |
|---|---|
| `docs/architecture.md` の `plugins.json` スキーマの `localPlugins` 行 | `// dev/dir plugins: not locked.` の説明はそのままで良いが、`dev` だけでなく **`dir` 単独でもここに来る**ことを明示する(現行は "dev/dir plugins" と書いてあるので実は既に正しい。**その記述が実装と一致するようになるのが本件である**旨を 1 節で触れる) |
| `docs/architecture.md` の `dev.path is a function` の項 | *"a key of the lock's `localPlugins` (the spec's own `dev = true` plugins)"* を「`dev = true` **または** `dir` を書いたプラグイン」に更新 |
| `docs/architecture.md` の edge-case 表の `Local plugin development` 行 | *"a spec-level `dev = true` is picked up automatically from `localPlugins`"* を `dev = true` / `dir` の両方に広げる。*"unless that spec entry also sets `dir` — then lazy short-circuits"* の但し書きは `dir` 単独にもそのまま当てはまるので、主語を「`dir` を書いた spec エントリ」に整理する |
| `docs/architecture.md` の fixtures 一覧 | `local-dir-config` を追加(`defaults-version-false-config` の隣) |
| `docs/architecture.md` の checks 一覧 | `extractor-local-dir` を追加(`extractor-defaults-version` の隣) |
| `README.md` の `### Local plugin development` | *"Plugins your lazy spec already marks `dev = true` need no entry here"* を「`dev = true` を書いたもの**と、`dir` を書いたもの**」に広げる。続く *"The exception is a spec entry that also sets `dir`"* は、主語が `dev = true` 前提になっているので「`dir` を書いた spec エントリは lazy がそのパスを直接使い、`devPath` は適用されない」に書き換える |
| **`README.md` の `## Options` 表の `devPath` 行** | 同じ限定が「`dev = true` を書いた spec エントリ」前提で書かれている。`dir` を書いた spec エントリ全般に広げる。**`devPlugins` 行はリンクだけなので触らない**(§8-8 の `grep -c '(#local-plugin-development)' README.md` が期待する 2 を動かさないため) |
| **`nix/home-manager/default.nix` の `devPlugins` の description** | *"Plugins your lazy spec itself marks `dev = true` are handled automatically ... unless that same spec entry also sets `dir`"* を、`dir` 単独のエントリも自動で拾われることを含む形に更新 |
| **`nix/home-manager/default.nix` の `devPath` の description** | *"The one exception is a spec entry that sets `dir` itself"* は文言としては既に正しいが、直前の文が「`dev = true` と書いた spec」に限定しているので、そこを `dir` 単独にも広げる |
| **`tests/fixtures/dev-plugins/nvimx-lock/plugins.json` の `_comment` — 最終行** | *"A plugin that sets `dir` without `dev` produces no entry at all (SS7 R2)."* は #47 で**偽になる**ので訂正する |
| **同 `_comment` — `bare.nvim` の段落** | *"Note this shape is hand-made: no current lock can emit it"* と *"but p.dir is never nil there"* も #47 で**偽になる**。#47 以前は `dir = p.dev and p.dir or nil` が「`dev` なら `dir` は必ず載る」を保証していたので真だったが、`local_dir` はユーザーの `dev.path` が lazy の `root` を指す病的な設定で **nil を返す**(§3.4 / §7 の 2 番目のリスク)。そのとき raw-spec は `dev: true` かつ `dir` 無しになり、`resolve.lua` が `p.dev` 側で拾って `{ }` を書くので、**実 lock がこの形を出せるようになる**。「手書きでしか作れない」ではなく「その病的な設定でだけ実 lock も出しうる」に書き換える。`bare.nvim` を置いた本来の目的(`v.dir` を `or` 無しで読む実装をここで落とす)は変わらない |
| — | どちらも `_comment` は `make-env.nix` が読まないトップレベルの余剰キーなので、**`checks.dev-plugins` の出力は 1 バイトも変わらない**(§5.6 / §8-5 の但し書き) |

**`docs/plans/*.md` は編集しない**(`docs/plans/26-dev-plugins.md` §7 R2 も含む)。
計画書は 1 度きりのコミットで記録された判断であり、13 本すべてがそう扱われている
(`docs/plans/49-lazy-nvim-collision.md` §1.2.1)。R2 への回答は本計画 §1.2 / §4.1 が持つ。
**fixture の `_comment` は計画書ではない** —— それは check が読む実物の一部として保守される散文なので、
偽になった記述はここで直す。

### 5.6 触らないもの

- **`lua/nvimx/resolve.lua`** — §3.4 で 6 経路を全件確認済み。**1 バイトも変えない。**
- **`lua/nvimx/genflake.lua` / `update-summary.lua` / `version.lua` / `json.lua`** — 無関係。
- **`lua/nvimx/source.lua`** — **意図的に触らない**(案 (ii) を採る)。ローカルパスを拒否するときの案内
  *"Use `dir = "..."` **with dev = true** for a plugin you keep on disk"* は、#47 以前は
  `dev = true` が**必須**だったところ(`dir` だけでは §1.1.1 のとおり lock が落ちる)、
  #47 後は不要になる。ただし **文言そのものは #47 後も正しく、示した手順も動く**(`dev = true` + `dir` は
  今までどおりローカルプラグインになる)ので、`extract.lua` のコメントのように**偽になるわけではない**。
  一方で編集すると `tests/source-parse-test.lua` の byte 一致 pin 2 行が同時に動き、
  §5.6 の「既存 fixture のデータは動かさない」と §8-5 のゲートに例外がもう 1 つ増える。
  **「最小限でなくなった案内」を直すために #28 の fixture 面を動かす取引は割に合わない**と判断した。
  §7 に follow-up として記録する。
- **`lua/nvimx/bootstrap.lua.in`** — §1.4 / §3.7。runtime は今日も正しい。
- **`nix/lib/**`** — §3.7。**コードは無変更。** `unknownPluginNames` を `localPlugins` も見るように広げる変更は
  **しない**(§3.7 の但し書き。効果の無い `overrides` を警告するのは望ましい)。
- **`nix/home-manager/default.nix`** — **2 つの option description 以外は無変更**(§5.5)。
  オプションの型も既定値も `makeEnv` への受け渡しも触らない。
- **既存 fixture / golden の**データ** — §4.5 で実測ゼロ差分。特に `tests/fixtures/golden/basic-config.raw-spec.json`、
  `import-lazy-lock/raw-spec.json` と `golden/imported.plugins.json`、`update/**`、`lazy-self/` の既存 5 本と
  `golden/` 2 本は触らない。
  **唯一の例外は `dev-plugins/nvimx-lock/plugins.json` の `_comment` の 2 箇所の事実訂正**(§5.5)で、
  `localPlugins` / `plugins` / `lazyNvim` のデータは 1 バイトも動かさない。`_comment` は
  `make-env.nix` が読まないので `checks.dev-plugins` の出力も動かない。
- **`tests/fixtures/local-plugin/`** — 名前は紛らわしいが `plugin-drv-phases` / `plugins-nixpkgs-fallback` /
  `build-registry` / `plugins-escape-hatch` 用の**プラグインのソースツリー**であり本件と無関係
  (`docs/plans/26-dev-plugins.md` §1.5 が同じ注意を書いている)。新 fixture を `local-dir-config` と名付けたのは
  この 2 つ、および `dev-plugins`(Nix 側の lock fixture)と区別するためである。
- **`tests/dev-path-test.lua`** — §3.7 / §6.2.1。`dirred.nvim` の assert が既に短絡を固定している。
- **`.github/workflows/*`** — check の追加は `nix flake check` の中身が増えるだけ。
- **`stylua.toml` / `.luacheckrc`** — 編集しないので `nix fmt -- --clear-cache` は不要。
- **`.claude/skills/`** — 触らないので `nix run .#skills-install` は不要。

---

## 6. テスト

### 6.1 `checks.extractor-local-dir` の 5 ステップ

| # | 何を走らせるか | 主張 |
|---|---|---|
| 1 | fixture を extract | `dirabs` = 逐語、`dirtilde` = `$HOME` 展開済み、`dirrel` = 相対のまま、`dirnoname` は `dir` があって `url` が**無い**、`sibling.nvim` に `dir` が**ある**(トレイリングスラッシュのガード)、`bare.nvim` は `dev == true` かつ dir が lazy の `dev.path` 由来、**`tokyonight.nvim` に `dir` が無い**、`dir` を持つのはちょうど 6 件。**加えて `version == "*"` が 6 件、`versionFromDefaults == true` も 6 件**(ステップ 2 の 2 本目の経路が実在することの固定) |
| 2 | resolve(`--lazy` 無し / `git` 無し) | **exit 0**。振り分けが壊れると `dirnoname` が `has no url` で、`url` を持つ 5 本が `--lazy` 不在の semver ゲートで落ちる —— **現 fixture では前者が先に exit する**(§3.5)。あわせて stderr が空、`localPlugins` のキーが 6 件、`plugins` のキーが `tokyonight.nvim` の 1 件、`warnings == []` |
| 3 | genflake | `tokyonight-nvim` の input があり、ローカル 6 件の名前が 1 つも出てこない、input はちょうど 2 本(`lazy-nvim` + `tokyonight-nvim`) |
| 4 | `--update dirabs.nvim` | 非ゼロ終了、`plugins.json` が**作られない**、`is a local plugin (dev/dir); nothing to lock or update` にプラグイン名が出る |
| 5 | `--update --update-plan` | plan が `lazy-nvim` と `tokyonight-nvim` の 2 行だけ |

ステップ 1 の `version` 3 行は**ステップ 2 を空虚にしないためにある**。ステップ 2 の主張は
「制約を持つローカルプラグインがゲートに乗らなかったから exit 0」であって、
制約が消えれば exit 0 は常に真になり、ガードが黙って死ぬ。

ステップ 2 が「exit 0 が assert」である理由は §3.5、ステップ 1 の `$HOME` 入り assert が
「`~` を展開するのは nvimx ではなく lazy」の固定である理由は §3.3。

**この 5 ステップは §5.3 に書いた bash そのままを、プロトタイプの出力に対して実際に通してある**
(`set -x` 付きで全行が非ゼロを返さないことを確認済み)。実装時は fixture のパスと
`${./lua/nvimx}` の interpolation を差し替えるだけでよい。

### 6.1.1 既存 check に相乗りする 2 ケース

| check | 主張 |
|---|---|
| `checks.resolve-import-lazy-lock` | `raw-spec-dir-only.json` + 既存 `lazy-lock.json` で、`import: skipped local.nvim: it is a local plugin (dev/dir), so there is nothing to pin` が出て、`import: 1 pinned, 1 skipped,` になり、**`is not validated` が出ず**、`.plugins["local.nvim"] == null`、`.localPlugins` が `local.nvim` を**持つ**こと(値は見ない)。**このケースでは「exit 0」は assert にならない** —— import は #23 のゲートの前に seed するので、退行しても exit 0 のままである(§5.4 の実測) |
| `checks.resolve-lazy-self` | `raw-spec-dir-only.json` で、`.lazyNvim.synthetic == true`、`lazyNvim` に `tag` が無い、`.localPlugins` が `lazy.nvim` を持つ、生成 flake の `lazy-nvim` URL が tag 無し、素の `--update` の plan に `lazy-nvim` が入る(§3.8 / §5.4.1)。`.plugins["lazy.nvim"] == null` も assert するが、**これは routing が壊れても真のまま**である(spec lazy.nvim は `lazyNvim` スロットに行くので `plugins` には入らない)—— characterization として置く |

### 6.2 摂動 — 直したものが本当に検出されるか

実装時に 1 つずつ試し、必ず戻すこと(§8-6)。

| # | 摂動 | 落ちるべきもの |
|---|---|---|
| (a) | `local_dir` を使うのをやめ、`dir = p.dev and p.dir or nil` に戻す(= 修正前) | ステップ **1**(`dirabs` / `dirtilde` / `dirrel` / `dirnoname` / `sibling` の 5 本と「`dir` を持つのは 6 件」)、ステップ **2**(実測: `dirnoname` の `has no url` で非ゼロ)、ステップ **3**、ステップ **4**(`--update dirabs.nvim` が受理されてしまい exit 0)。**§6.1.1 の 2 ケースには届かない** —— どちらも手書き raw-spec を直接 resolve に食わせるので、`extract.lua` の摂動は 1 バイトも動かさない |
| (b) | `dir = p.dir`(issue の字面どおり。§1.3) | **ステップ 2 の exit 0 では落ちない**摂動 —— これはゲートを緩める方向だからである。`set -e` なので実際に最初に発火するのはステップ **1** の `tokyonight.nvim | has("dir") | not`。到達すればステップ **1** の「6 件」、ステップ **2** の `plugins` キー(空になる)、ステップ **3**(`tokyonight-nvim` の input が消え、`flake = false;` が 1 件になる)もすべて落ちる |
| (c) | `local_dir` の前方一致から末尾の `/` を落とす(`p.dir:find(root, 1, true)`) | ステップ **1** の `sibling.nvim | has("dir")` と「6 件」。**実測で確認済み**: `<root>` は `<data>/nvim/lazy` なので、スラッシュを落とすと `<data>/nvim/lazy-sibling/sibling.nvim` に前方一致してしまい、`sibling.nvim` の `dir` が記録されなくなる |
| (d) | `extract.lua` で `dev = p.dev or nil` の dump をやめる | ステップ **1** の `.plugins["bare.nvim"].dev == true`。**#47 後は振り分けが `dir` で足りるので lock の中身は変わらない**が、raw-spec の契約としては後退なので assert で止める。`dev` が唯一の手掛かりになる病的ケースは §7 |
| (e) | `resolve.lua` のメインループの条件を `if p.dev then` に狭める | **3 本の check を落とす。** ステップ **2**(実測: `dirnoname` の `has no url` で非ゼロ終了し、`plugins.json` が書かれないのでステップ **3** / **4** / **5** も連鎖)。**§6.1.1 の `resolve-lazy-self` ケース**(`lazyNvim.synthetic` が `false` に戻り、生成 flake の URL に `refs/tags/v11.0.0` が現れる)。**§6.1.1 の import ケース**も —— `local.nvim` が remote 分岐に入って import seed から pin され、`is not validated` が出てサマリが `2 pinned, 1 skipped` になる(報告ループは `raw_plugins` の `p.dir` を独立に見るので `skipped local.nvim` の行は出続ける)。3 本とも実測 |
| (f) | `resolve.lua` の `--update` 名前検証の条件を `p.dev` に狭める | ステップ **4**。`--update dirabs.nvim` が受理されて exit 0 になる |
| (g) | `resolve.lua` の `update_all` の force 集合の条件を `p.dev` に狭める | ステップ **5**。plan に `dirabs-nvim` などが増えて `wc -l` が 2 を超える |
| (h) | `resolve.lua` の import の `local_skipped` 分岐の条件だけを `p.dev` に狭める | §6.1.1 の import ケース。実測、**exit 0 のまま**: `[nvimx] import: ignored local.nvim (matched a config plugin but was not accounted for by the import merge; this is a bug in nvimx, please report it)` になり、`import: 1 pinned, 0 skipped, 14 ignored` に変わる。メインループの routing は無傷なので `local.nvim` は import seed に入らず、`unaccounted` の else バケツに落ちる。**`2 pinned` にも `is not validated` にもならない** —— 落ちるのは `skipped local.nvim` の grep と `1 pinned, 1 skipped,` の grep の 2 本である |
| (i) | `local_dir` の戻り値を `vim.fn.fnamemodify(p.dir, ":p")` で絶対化する | ステップ **1** の `dirrel` の assert(`nvimx-fixture/dirrel` がサンドボックスの cwd 込みの絶対パスになる) |
| (j) | `root_prefix` を `Config.setup(...)` の**前**に取る | ステップ **1**。実測: setup 前の `Config.options` は table だが `Config.options.root` は **nil** なので、`Config.options.root .. "/"` がその場で error になり extract 全体が非ゼロで死ぬ(`[nvimx] extract failed: ...`) |
| (k) | `effective_version` に `dir` のガードを足す(§3.5 で足さないと決めたもの) | ステップ **1** の `version` / `versionFromDefaults` の 4 行。lock の中身は変わらず、現 fixture ではステップ 2 の落ち方も変わらない(`dirnoname` が先に落ちる)が、**ステップ 2 の 2 本目の経路を黙って消す**ので止める。§3.5 が「`dirnoname` を将来触ったときの最後の砦」と書いているのがこれである |
| (l) | `resolve.lua` の `lazy_is_spec` を `lazy_p ~= nil and not lazy_p.dev` に狭める(= §3.4 の 6 番目の経路から `dir` の項を落とす) | §6.1.1 の **`resolve-lazy-self` ケース**の plan 2 行。実測: `lazy_pinned` が真になり、素の `--update` の plan から `lazy-nvim` が消える。**jq / genflake の assert は落ちない** —— メインループの routing は無傷なので `lazyNvim` は synthetic のままである。そちら側((e) が落とす)と合わせて、§3.8 の分類が 2 つの摂動で覆われる |

### 6.2.1 §3 の全決定 × 摂動の照合表

**空欄はゼロにしてある。** 対応が無い決定は、摂動を足すか「なぜ摂動できないか」を書くかのどちらかにしてある。
初版では (c)(d)(k) の 3 件を「check で守れない」と倒していたが、レビューで**3 件とも 2 行で守れる**ことが
示されたので fixture とステップ 1 を拡張した。**「守れない」と書く前に、fixture を 1 行増やして守れないかを疑うこと。**

**逆に、2 巡目のレビューで「守れている」が 1 件崩れた。** §3.4 の経路 5(import の config 側 `not_in_lock`)は
新 fixture の構成上どんな摂動でも症状が出ず、症状を出すには既存 golden を動かす必要がある。
下の表ではそれを理由付きの行として残してある。**正確な内訳は「12 件のコード摂動 +
構造的に守れない決定 1 件(§3.4 経路 5)+ そもそも摂動できない決定(却下案・不作為・ドキュメント・
既存 check が兼ねるもの)」であり、「無ガードゼロ」ではない。**
また、`extract.lua` の摂動(**(a)(b)(c)(d)(i)(j)(k)**)は**手書き raw-spec を使う §6.1.1 の 2 ケースには一切届かない** ——
届くのは `resolve.lua` の摂動(**(e)(f)(g)(h)(l)**)だけである。

| §3 の決定 | ガード | 摂動 |
|---|---|---|
| §3.1 判定は `p.dir` が `Config.options.root .. "/"` の下に無いこと | ステップ 1(6 件 + `tokyonight` に `dir` 無し) | **(a)(b)** |
| §3.1 `root_prefix` は `Config.setup` の**後**に取る | ステップ 1(extract が死ぬ) | **(j)** |
| §3.1 前方一致は末尾の `/` を含む | ステップ 1 の `sibling.nvim | has("dir")` と「6 件」 | **(c)**。実測で落ちることを確認済み |
| §3.1 `virtual` も自動的にローカルになる | — | **無し(意図的)**。`virtual` は本件のスコープ外で fixture を持たない。§7 に「今日から挙動が変わるが、check していない」と明記 |
| §3.1 短縮名の無い `{ dir = ... }`(`url` なし)も記録される | ステップ 1 の `dirnoname` 2 行 + ステップ 2 | **(a)**。修正前はこの形で lock が hard-fail していた(§1.1.1) |
| §3.2 却下 B(fragment の `rawget`) | — | **無し**。却下案はコードにならない。#56 への申し送り(§4.2)が代替の記録である |
| §3.3 `dir` は lazy が正規化した値を逐語で記録し、絶対化しない | ステップ 1 の `dirrel` / `dirtilde` | **(i)** |
| §3.3 存在確認をしない | ステップ 1-3 全体(fixture の 6 ディレクトリはどれも存在しない) | **無し(専用の摂動は不要)**。存在確認を足せばステップ 1 以降が全部落ちる |
| §3.3 `plugins.json` の `localPlugins` は**キーしか** assert しない(#56 の自由度) | — | **無し(意図的)**。「assert しない」という決定は摂動できない。守るのは §5.3 / §5.4 / §5.4.1 のレビューである |
| §3.4 `resolve.lua` のメインループは無変更で足りる | ステップ 2 | **(e)** |
| §3.4 `--update <name>` の fatal | ステップ 4 | **(f)** |
| §3.4 `update_all` の除外 | ステップ 5 | **(g)** |
| §3.4 `p.dev` の dump を残す | ステップ 1 の `bare.nvim.dev == true` | **(d)** |
| §3.4 `resolve.lua` の `p.dev or p.dir` を残す(病的ケース用) | — | **無し(意図的)**。`dev` が真で `dir` が root 配下という組み合わせを fixture にすると、§7 で「病的」と評価した挙動を契約として固定してしまう。§7 に非対称として記録 |
| §3.5 制約は記録せず、警告も出さない | ステップ 2 の exit 0 + `warnings == []` | **(a)(e)** が両方ここを落とす |
| §3.5 `effective_version` にガードを足さない | ステップ 1 の `version == "*"` 3 行 | **(k)** |
| §3.6 import は classification 3L になる | §6.1.1 の import ケース(4 grep。**exit 0 は assert にならない**。§5.4) | **(h)(e)**。(h) は `skipped` の行と件数、(e) は `is not validated` を落とす。(a) は届かない(手書き raw-spec) |
| §3.4 経路 5(import の config 側 `not_in_lock` ループ) | — | **無し(構造的に守れない)**。新 fixture の `local.nvim` は `lazy-lock.json` にエントリを持つので `import_db[rn] ~= nil` であり、この条件を `p.dev` に狭めても `not_in_lock` の中身は変わらない。守るには「lazy-lock.json に**居ない** `dir` のみのプラグイン」を足す必要があるが、それは `not in lazy-lock.json` の集計(classification 5)を動かすので既存 golden に触れる。**経路 4 と構造で同期している**(`import_accounted` のコメントが根拠)ことを実装レビューの拠り所とする |
| §3.6 既存 `raw-spec.json` を触らず新ファイルで足す | — | **無し**。`git status --porcelain -- tests/fixtures` が §8-5 で守る |
| §3.7 Nix 側は無変更、`devDirs` のキーは inert | 既存 `checks.dev-plugins` の `dirred.nvim` 行(runtime 半分) | **無し(既存 check が兼ねる)**。`meta.lua:216` の短絡は `dev` を見ないので、`dirred.nvim` の assert が `dir` 単独のケースも同時に守る。#26 §7 R10 が seed 追随のガードとして置いたものがそのまま効く |
| §3.7 `unknownPluginNames` を `localPlugins` も見るようには広げない | — | **無し(意図的)**。「広げない」という不作為は摂動できない。効果の無い `overrides` が警告されるのは望ましい挙動なので、§3.7 と §7 に記録するに留める |
| §3.7 Nix 側の fixture を増やさない | — | **無し(意図的)**。`plugins.json` は `dev` 由来と `dir` 由来を区別しないので、足しても固定できる新事実が無い(§3.7) |
| §3.8 `dir` のみの lazy.nvim は `localPlugins` に行く(routing 側) | §6.1.1 の `resolve-lazy-self` ケースの **3 jq + genflake 2 grep**(4 本目の `.plugins["lazy.nvim"] == null` は routing が壊れても真のまま。spec lazy.nvim は `lazyNvim` スロットに行き `plugins` には入らないため) | **(e)** |
| §3.8 `lazy_is_spec` がそれを spec lazy.nvim と見なさない(述語側) | §6.1.1 の `resolve-lazy-self` ケースの plan 2 行 | **(l)** |
| §3.8 #49 のコード自体は無変更 | `checks.resolve-lazy-self` の既存 5 ステップが緑のまま | **無し(意図的)**。#49 の既存 fixture 5 本は手書き raw-spec なので extract の変更が届かない。§4.5 の「差分ゼロ」がその表明であり、§8-3 で個別に build する |
| §3.9 `extract.lua` の既存コメントを事実に合わせる | — | **無し**。ドキュメントは摂動できない。§8-9 の grep で存在を確認する |

### 6.3 既存 check への影響

**既存の assert / golden に対しては期待差分ゼロ**(§4.5 で実測)。それでも §8-3 で
`extractor-snapshot` / `extractor-defaults-version` / `resolve-import-lazy-lock` / `dev-plugins` /
`resolve-lazy-self` / `resolve-merge` / `resolve-update` / `update-summary` / `resolve-golden` /
`genflake-golden` / `resolve-build-warnings` を個別に build して確認する。
`extractor-snapshot` は `extract.lua` の出力を byte 単位で固定している唯一の check なので特に重要である。

---

## 7. リスク / 未決事項

- **extract は使い捨てサンドボックスの root を見るので、runtime root をリテラルで書いた `dir` は lazy と食い違う。**
  `nix/lib/lock-app.nix` は extract を `sandbox=$(mktemp -d)` の XDG サンドボックス(`XDG_DATA_HOME="$sandbox/data"`)で
  走らせるため、`Config.options.root` は `<tmpdir>/data/nvim/lazy` である。
  ユーザーが `dir = "/home/me/.local/share/nvim/lazy/foo"` と runtime の root 配下を**リテラルで**書いた場合、
  extract では前方一致せずローカルと判定され、runtime の lazy は `plugin.lua:247` でリモートと判定する。
  **却下案 B(fragment の `rawget`)でもまったく同じに起きる**ので、判定の選択で回避できる問題ではない。
  実害は「lazy が自分の root に clone しようとしているディレクトリを nvimx がローカル扱いする」ことだが、
  そもそもユーザーが lazy の管理ディレクトリを自分で名指しするのは意味の無い書き方である。**check していない。**
- **`{ "o/x.nvim", dev = true }` で、ユーザーの `dev.path` が lazy の `root` を指している場合も同じくずれる。**
  `local_dir` は `nil` を返すが、`resolve.lua` の `p.dev or p.dir` の `p.dev` 側で拾われてローカル扱いになる。
  `p.dev` を落として `dir` だけで振り分ければ揃うが、それは #26 が確立した
  「`dev = true` は nvimx にとってローカルプラグインである」という意味論の変更であり、本件のスコープではない。
  **意図的に fixture を作らない** —— 作れば「病的」と評価した挙動を契約として固定してしまう(§6.2.1)。
- **`virtual = true` なプラグインの扱いが今日から変わる。** 今日はリモート扱いされて(`url` があれば)input が作られ、
  修正後は `localPlugins` に入る。lazy の扱い(`plugin.lua:244-246` が `is_local = true`)に一致する方向の変更だが、
  **fixture も check も持たない**。`virtual` は lazy の中でも周辺的な機能で、nvimx のドキュメントは一度も触れていない。
  必要になったら別 issue で扱う。
- **`extract.lua` が `Config.options.root` に依存するようになる。** ユーザーが `root` を設定していれば
  その値が使われる(lazy と同じ)ので挙動は一貫するが、raw-spec の内容が opts の 1 つに依存する点は新しい。
  `extractor-snapshot` の golden がサンドボックスの XDG に依存しないのは、
  リモートプラグインでは `local_dir` が必ず `nil` を返すからである(実測で golden 一致を確認済み)。
- **`version` / `tag` / `commit` / `build` はローカルプラグインで黙って捨てられる。** これは `dev` について
  今日そうなっていることで、本件は母集団を広げるだけである(§3.5)。lazy 自身も `git.lua:118-123` で
  それらを見ないので警告しないと決めたが、`build` については lazy が**ローカルプラグインでも実行する**ため、
  「nvimx ではローカルプラグインの `build` が走らない」という差は残る。
  これは #26 以前から存在する別件で、本件では扱わない。**follow-up issue の候補。**
- **アップグレード後の初回 lock で、`plugins.json` から該当プラグインが消え、`flake.lock` からも input が消える。**
  `--update` で走らせた場合、`update-summary` はそれを `removed: <name>` として報告する
  (`plugins_before` にあって `plugins_after` に無い)。正直な報告であり、コードは変えない。
  ユーザーから見れば「不要な pin が 1 つ消えた」ことの表明である。
- **`dir` のみの lazy.nvim を書いていたユーザーは、`tag` / `commit` / `branch` / `version` / `pin` が効かなくなる**(§3.8)。
  修正後は `lazyNvim` が合成リテラルに戻るので、生成 flake の `lazy-nvim` URL がベアになり、
  `flake.lock` の該当ノードが動き、素の `--update` が seed input を更新するようになる(実測は §3.8 の表)。
  `dir` を書いた時点で lazy はその作業ツリーを読み、これらの指定を一切参照しない(`git.lua:118-123`)ので
  **runtime の挙動は変わらない**が、lock は動く。#49 §3.4 / §3.6 が `dev = true` な lazy.nvim について
  決めた扱いに揃える変更であり、`checks.resolve-lazy-self` の新ケースが固定する(§5.4.1)。
  この形を書いていたユーザーがどれだけ居るかは不明だが、**PR 本文に挙動変更として明記すること。**
- **`dir` のみのプラグインに `plugins.overrides` / `plugins.nixpkgsFallback` を書いていたユーザーには、
  activation 時の `unknownPluginNames` 警告が新たに出る**(§3.7)。
  その指定は元から効果が無かった(runtime では作業ツリーが読まれる)ので、
  「効かないことが見えるようになった」変更である。`unknownPluginNames` を `localPlugins` も見るように
  広げることは**しない** —— 広げると、この無効な指定が再び黙って無視される状態に戻る。
- **`dir` が相対パスの場合、runtime の解決先は `nvim` を起動した cwd に依存する。** これは lazy の挙動そのもので
  (実測: `dirrel.nvim` が `src/dirrel` のまま解決される)、nvimx は何もしない(§3.3)。
  `devDirs` に入る `<devPath>/<name>` は short-circuit されるので無関係である。
- **`source.lua` のローカルパス案内が最小限でなくなる。** *"Use `dir = "..."` with dev = true for a plugin
  you keep on disk"* は #47 後も正しいが、`dev = true` はもう要らない。文言を最小化するには
  `tests/source-parse-test.lua` の byte 一致 pin 2 行を同時に動かす必要があるので、
  **本件では触らない**(§5.6 の案 (ii))。#28 の文言まわりを次に触るとき、
  あるいは #56 の fixture 再生成に相乗りさせるのが安い。**follow-up issue の候補。**
- **#56 が `extract.lua` に触る場合、`dir` を絞り込んではならない**(§4.2 の申し送り)。
  絞り込むと #47 が静かに再発する。#56 の計画書 §3 に入れるべき項目として記録する。
- **オンラインの実 lock は check で覆えない。** ビルドは完全にオフラインなので、
  「github.com への無駄な ls-remote が実際に消える」ことは §8 の手動確認で 1 回だけ通す。
- **check が 1 本増え、既存 2 本にケースが 1 つずつ増える。** nvim 7 回程度、fetch はゼロ。

---

## 8. 検証手順(実装完了時に必ず全部通す)

**計画レビューで一部が実行済みであっても、実装後に全手順を改めて通すこと。**

```bash
# 0. リポジトリルートで。新規ファイルは git add してあること(nix は git 管理下のファイルしか見ない)
cd /home/myuron/ghq/github.com/myuron/nvimx
git add tests/fixtures/local-dir-config \
        tests/fixtures/import-lazy-lock/raw-spec-dir-only.json \
        tests/fixtures/lazy-self/raw-spec-dir-only.json
git status --short

# 1. CI と同一の 2 本(CLAUDE.md の Commands より)。これが通ることが必須条件
nix flake check
nix fmt -- --ci

# 2. 新規 check 単体(失敗時の切り分け用)
nix build .#checks.x86_64-linux.extractor-local-dir -L

# 3. 影響を受けうる既存 check 単体。extract.lua を触るので extractor-* は全部、
#    localPlugins の生成側 / 消費側を持つものと、#49 が入れたばかりの経路も確認する
nix build .#checks.x86_64-linux.extractor-snapshot
nix build .#checks.x86_64-linux.extractor-defaults-version
nix build .#checks.x86_64-linux.extractor-no-setup
# resolve-semver も extract.lua を通る(merge-config を extract してから resolve する)
nix build .#checks.x86_64-linux.resolve-semver
nix build .#checks.x86_64-linux.resolve-import-lazy-lock
nix build .#checks.x86_64-linux.dev-plugins
nix build .#checks.x86_64-linux.resolve-lazy-self
nix build .#checks.x86_64-linux.resolve-merge
nix build .#checks.x86_64-linux.resolve-update
nix build .#checks.x86_64-linux.update-summary
nix build .#checks.x86_64-linux.resolve-golden
nix build .#checks.x86_64-linux.genflake-golden
nix build .#checks.x86_64-linux.resolve-build-warnings

# 4. darwin 評価(linux の nix flake check は darwin を omit するため必須。CLAUDE.md)
nix eval .#checks.aarch64-darwin.extractor-local-dir.drvPath
nix eval .#checks.aarch64-darwin.resolve-import-lazy-lock.drvPath
nix eval .#checks.aarch64-darwin.resolve-lazy-self.drvPath

# 5. 既存 fixture / golden の *データ* が 1 本も動いていないこと(§4.5 / §5.6)
git status --porcelain -- tests/fixtures
# -> 新規追加(A / ??)は tests/fixtures/local-dir-config/,
#    tests/fixtures/import-lazy-lock/raw-spec-dir-only.json,
#    tests/fixtures/lazy-self/raw-spec-dir-only.json の 3 つだけ。
#    M になってよいのは tests/fixtures/dev-plugins/nvimx-lock/plugins.json ただ 1 本で、
#    その diff は _comment の 2 箇所(最終行と bare.nvim 段落)だけであること(§5.5)。
#    下の 2 行で確かめる:
git diff -- tests/fixtures/dev-plugins/nvimx-lock/plugins.json   # _comment の中だけ
diff <(git show HEAD:tests/fixtures/dev-plugins/nvimx-lock/plugins.json | jq -S 'del(._comment)') \
     <(jq -S 'del(._comment)' tests/fixtures/dev-plugins/nvimx-lock/plugins.json)   # 差分ゼロ
#    それ以外の既存ファイルは 1 本も M にならないこと -- 特に
#    golden/basic-config.raw-spec.json, import-lazy-lock/raw-spec.json,
#    import-lazy-lock/golden/imported.plugins.json, lazy-self/ の既存 5 本と golden/ 2 本

# 6. 摂動(§6.2)。(a)(b)(c)(d)(e)(f)(g)(h)(i)(j)(k)(l) を 1 つずつ試し、毎回必ず戻す。
#    §6.2.1 の照合表が「§3 のどの決定をどの摂動が守るか」の一覧である。全 12 件が何かを落とす。
#    どの check が落ちるかは摂動の *対象ファイル* で決まる:
#      extract.lua の摂動 (a)(b)(c)(d)(i)(j)(k) -> extractor-local-dir だけ。
#        §6.1.1 の 2 ケースは手書き raw-spec を直接 resolve に食わせるので届かない。
#      resolve.lua の摂動 (e)(f)(g)(h)(l) -> (f)(g) は extractor-local-dir、
#        (h) は resolve-import-lazy-lock、(l) は resolve-lazy-self、
#        (e) は extractor-local-dir / resolve-lazy-self / resolve-import-lazy-lock の 3 本すべて。
#    (b) は「ステップ 2 の exit 0 では落ちない」摂動。exit 0 のままステップ 1 の has("dir") | not で
#        落ちるのが正しい姿である(set -e なので最初に発火するのがそこ、というだけで、
#        到達すればステップ 1 の 6 件・ステップ 2 の keys・ステップ 3 も落ちる)。
#    (h) も exit 0 のままである。import は #23 のゲートの前に seed するので、落ちるのは
#        `skipped local.nvim` と `1 pinned, 1 skipped,` の 2 つの grep だけで、
#        stderr は `ignored local.nvim (... not accounted for by the import merge ...)` になる。
#        `2 pinned` や `is not validated` を期待しないこと(それは fixture から dir を落とした場合の症状)。
#    (l) が落とすのは resolve-lazy-self の update-plan 2 行だけである。jq / genflake の assert は
#        通ったままなのが正しい姿で、そちらは (e) が落とす。
#    (k) が落とすのはステップ 1 の version / versionFromDefaults の 4 行だけ。ステップ 2 の落ち方は
#        変わらない(dirnoname が先に落ちる)。落ちない場合、その 4 行が既に空虚ということなので、
#        その時点で止めて原因を追うこと。
nix build .#checks.x86_64-linux.extractor-local-dir       # 落ちることを確認
nix build .#checks.x86_64-linux.resolve-import-lazy-lock  # (h) はこちら
nix build .#checks.x86_64-linux.resolve-lazy-self         # (l) はこちら
git checkout -- lua/nvimx
nix build .#checks.x86_64-linux.extractor-local-dir       # 戻したら通ることを確認
nix build .#checks.x86_64-linux.resolve-import-lazy-lock
nix build .#checks.x86_64-linux.resolve-lazy-self

# 7. スモークテスト(CLAUDE.md の Commands)。demo の config は dev/dir を使っていないので
#    退行が無いことの確認である
nix build .#demo && ./result/bin/nvim   # :Lazy が全プラグインを local 表示、git 操作ゼロ

# 8. ドキュメント(§5.5)。書いたことが実物と合っているか突き合わせる
grep -n 'local-dir-config' docs/architecture.md        # fixtures 一覧
grep -n 'extractor-local-dir' docs/architecture.md     # checks 一覧
grep -n 'Local plugin development' docs/architecture.md README.md
grep -n 'localPlugins' docs/architecture.md
grep -n 'dev = true' nix/home-manager/default.nix      # 2 つの description が dir にも触れていること
grep -c '(#local-plugin-development)' README.md        # -> 2 のまま(#26 が置いた 2 本を増減させない)

# 9. 事実と食い違うコメントが 1 つも残っていないこと(§5.1(d) / §5.5)
grep -n 'pre-existing gap' lua/nvimx/extract.lua                              # -> 出力が無いこと
grep -n 'produces no entry at all' tests/fixtures/dev-plugins/nvimx-lock/plugins.json  # -> 出力が無いこと
```

### 手動確認(check にできない部分)

**オンラインでの実 lock を 1 回通すこと。** 本件が消すのは「手元にあるプラグインのために github.com へ出る」
挙動であり、check はネットワークに触れない。`nvim/init.lua` に

```lua
require("lazy").setup({
  { "folke/tokyonight.nvim" },
  { "o/my-plugin.nvim", dir = "~/src/my-plugin.nvim" },
}, { defaults = { version = "*" } })
```

を書いた config で:

```bash
nix run .#lock -- --config ./nvim --out ./nvim/nvimx-lock
```

確認すること:

1. **成功して終わること。** 従来は `my-plugin.nvim` に対する `git ls-remote https://github.com/o/my-plugin.nvim.git` が
   走り、リポジトリが存在しなければそこで lock が落ちていた(§1.1)。
2. `nvim/nvimx-lock/plugins.json` の `plugins` に `my-plugin.nvim` が**居ない**こと、
   `localPlugins["my-plugin.nvim"].dir` が `$HOME/src/my-plugin.nvim` になっていること。
3. `nvim/nvimx-lock/flake.nix` と `flake.lock` に `my-plugin-nvim` input が**無い**こと。
4. **修正前に作った lock がある状態で走らせた場合**、`plugins.json` から該当エントリが消え、
   `flake.lock` から input ノードが 1 つ消える差分が出ること(§7)。
5. 続けて `home-manager switch` 相当のビルドが通り、`:Lazy` で `my-plugin.nvim` が
   `~/src/my-plugin.nvim` を指す local 表示になること(= §1.4 の実測が実環境でも成り立つこと)。
6. **もう一度同じ lock を実行して `git diff` が空であること**(2 パス収束の不動点)。

`{ "o/my-plugin.nvim", dir = "~/src/my-plugin.nvim" }` を `nvimx-lock` の `--update my-plugin.nvim` に渡すと
`[nvimx] resolve failed: plugin "my-plugin.nvim": is a local plugin (dev/dir); nothing to lock or update`
で止まることも 1 回確認する(§3.4 の 2)。

**短縮名を書かない形も 1 回通すこと**(§1.1.1)。`{ dir = "~/src/my-plugin.nvim" }` だけを書いた config で
`nix run .#lock` が成功し、`localPlugins["my-plugin.nvim"]` が作られること。
修正前はこの config が `[nvimx] resolve failed: plugin "my-plugin.nvim": has no url. ...` で
**必ず落ちていた**(オフライン / オンラインを問わず)ので、成功すること自体が確認である。
