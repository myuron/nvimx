# #26 対応計画: `devPlugins` / `devPath` によるローカルプラグイン開発サポート

対象 issue: [#26 feat: support local plugin development (devPlugins / devPath)](https://github.com/myuron/nvimx/issues/26)

Phase 7 の先頭。前提となる #18 / #42 / #31 / #36 / #23 / #24 / #25 / #43 は**すべて main にマージ済み**
(`5681366` 時点)。本計画の `file:line` は**現在の作業ツリー(`5681366`)基準で全件を実ファイルで再検証済み**である。
lazy.nvim 側の行番号は、`flake.lock` が固定している seed
(`rev = 306a05526ada86a7b30af95c5cc81ffba93fef97` → `/nix/store/d9jq3s81p4i9q6g8gaa6f2pn51p8za9l-source`)の
実ファイルからの引用である。

本計画の設計は事前に承認済みであり、以下の 5 点は**再検討しない**:

1. オプション面は `programs.nvimx.devPlugins`(`listOf str`)+ `programs.nvimx.devPath`(`str`)。
   プラグインごとにパスを持つ attrset にはしない。
2. 作業ツリーが存在しない場合の **fallback は無い**。dev ディレクトリはその存在に関わらず返す。
3. `dev.path` を Lua の**関数**にする。関数はプラグインディレクトリを**フルパスで**返さなければならない。
4. `devPlugins` に挙げたプラグインも lock と farm には残る。変わるのは lazy に教えるディレクトリだけ。
5. `plugins.json` の `localPlugins` を `make-env.nix` で消費する。ただし**消費するのはキー(プラグイン名)だけ**で、
   記録されている `dir` の値は**使わない**。`devPlugins` 由来か `localPlugins` 由来かに関わらず、
   すべての名前が `<devPath>/<name>` に写る。

**5 は当初「spec 由来の `dir` が `devPath` に勝つ」という規則だったが、その前提が実測で崩れたため訂正済みである。**
`localPlugins[*].dir` に何が入るかは spec の書き方で 3 通りに分かれる(§6.6(c) で全件実測):

| spec | 記録される `dir` | マシン依存か |
|---|---|---|
| `dev = true`(`dir` 無し) | lazy が `dev.path` から導出した絶対パス。`extract.lua:43-50` の `safe_opts` に `dev` キーが無いのでユーザの `dev.path`(既定 `~/projects`)が extract 中も生きており、`config.lua:287-288` で `~` は展開済み | **する** |
| `dev = true` + `dir = "/abs/x"` | `/abs/x` を**逐語で**。`meta.lua:214-217` が dev 分岐より前に短絡する | **しない** |
| `dev = true` + `dir = "~/x"` | `meta.lua:217` の `Util.norm` が `~` を展開した絶対パス | **する** |

つまり「記録値は常にマシン依存」は**言い過ぎ**であり、2 番目のケースではユーザが書いたとおりの値が入る。
それでも `dir` を読まないという判断は変わらない。決め手は**マシン依存性ではなく §3.3 の 2 番目の理由**、
すなわち「spec に `dir` を書いたプラグインでは `meta.lua:216` が短絡するので `dev.path` はそもそも呼ばれず、
`devDirs` に何を入れても runtime の結果に影響しない」ことである。1 番目と 3 番目のケースで
マシン依存の値を他人の `bootstrap.lua` に焼き込まずに済むのは、その判断から**副次的に得られる利点**である。
詳細は §3.3 と §7 R1。結果として **`devDirs` の値は必ず `<devPath>/<name>` になる**
(`devPath` が実際に位置を決めるのは「`devPlugins` の名前」と「`dir` を持たない素の `dev = true`」であって、
spec が `dir` を書いたプラグインでは lazy がそちらで短絡する —— G3' の但し書き)。

## 1. 背景 / 現状

### 1.1 現在の runtime bootstrap(`lua/nvimx/bootstrap.lua.in`)

- `:4` `local farm = "@farm@"` —— 唯一のプレースホルダ。
- `:6` `vim.opt.rtp:prepend(farm .. "/lazy.nvim")`。
- `:8-42` `package.preload["lazy"]` の shim。`:14-29` が `forced` opts、`:33-39` が `lazy.setup` の差し替え
  (`vim.tbl_deep_extend("force", opts or {}, forced)`)。
- **本件の対象は `:21-28`**:

  ```lua
      -- Treat every plugin as is_local under the farm so that lazy's git/install
      -- pipeline is skipped entirely (we only read from the store)
      dev = {
        -- TODO (Phase 7): make this a function that accounts for devPlugins / devPath
        path = farm,
        patterns = { "" },
        fallback = false,
      },
  ```

  `:24` の TODO が issue 本文の引用元である。
- `bootstrap.lua.in` は `*.lua` にマッチしないので **stylua も luacheck も見ない**
  (`flake.nix:146-150` の `settings.formatter.luacheck.includes = [ "*.lua" ]`(`:148`)、
  `.luacheckrc:16-17` の申し送り、
  `docs/architecture.md:480`)。したがってこのファイルに Lua のテーブルリテラルを埋め込んでも
  フォーマッタと衝突しない。

### 1.2 lazy.nvim 側の契約(seed で実読) —— 本件で唯一絶対に間違えてはならない点

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
231        or Util.norm(Config.options.dev.path(plugin))
232      if not Config.options.dev.fallback or vim.fn.isdirectory(dev_dir) == 1 then
233        plugin.dir = dev_dir
234      else
235        plugin.dev = false
236      end
237    end
238    plugin.dir = plugin.dir or Config.options.root .. "/" .. plugin.name
239  end
```

ここから読み取れる契約:

| 事実 | 根拠 | 本件への含意 |
|---|---|---|
| **string 形式は `"/" .. plugin.name` を後置する。function 形式は後置しない** | `:230-231` | 関数は**フルのプラグインディレクトリ**を返さなければならない。`farm` を返すと全プラグインが farm 直下に潰れる。**本件で最も起こりやすいバグ** |
| function 形式の戻り値は `Util.norm` を通る | `:231` | `~` が実行時に展開される(`lua/lazy/core/util.lua:74-84`、`:75-81` が `vim.uv.os_homedir()` による `~` 展開)。Nix 側でのシェル展開は不要 |
| string 形式は `Util.norm` を通らない(代わりに setup 時に 1 回だけ norm される) | `lua/lazy/core/config.lua:287-288` の `if type(M.options.dev.path) == "string" then M.options.dev.path = Util.norm(...)` | function 化すると `:287-288` は素通りし、代わりに `:231` が毎回 norm する。store path は norm しても不変なので**現行挙動と等価**(§6.3 で実測済み) |
| spec に明示的な `dir` があると `:216` で短絡し、`dev.path` は**一切参照されない** | `:214-217` | **`devDirs` が実際に行き先を決められるのは、素の `dev = true`(spec に `dir` が無い)エントリだけ**である。ユーザが自分で `dir` を書いたプラグインは runtime でその値が無条件に勝つので、`devDirs` にその名前が載っていても無害な no-op になる。これが「`localPlugins` の `dir` を読む必要がそもそも無い」ことの根拠(§3.3) |
| `fallback = false`(維持)なので、返したディレクトリは存在しなくてもそのまま使われる | `:232` | 「作業ツリーが無くても fallback しない」という決定はコード変更なしで成立する |
| `patterns = { "" }` は `plugin.dev == nil` かつ `plugin.url` があるときにだけ発火する | `:221-228` | 全プラグインが `dev` ブランチに入り、したがって我々の関数に到達する。今日と同じ |
| lazy の既定は `dev = { path = "~/projects", patterns = {}, fallback = false }` | `lua/lazy/core/config.lua:69-77` | nvimx の `devPath` 既定値 `"~/projects"` はこれに一致させたもの |

### 1.3 今日壊れているもの(issue 本文の 2 点を実コードで確認)

**(1) spec の `dev = true` プラグインは runtime で行き先を失う。**

- `lua/nvimx/extract.lua:114` の `dir = p.dev and p.dir or nil` と `:115` の `dev = p.dev or nil` で
  raw-spec に `dev` / `dir` が載る。
- `lua/nvimx/resolve.lua:616-619`:
  ```lua
  for name, p in pairs(raw.plugins or {}) do
    if p.dev or p.dir then
      local_plugins[name] = { dir = p.dir }
    else
  ```
  → **`local_plugins` に落ちたものは以降のマージ処理・input 生成に一切到達しない**。flake input も farm エントリも無い。
- `lua/nvimx/resolve.lua:1224` `localPlugins = json.object(local_plugins),` で `plugins.json` に書かれる。
- runtime では `dev.path = farm` なので `<farm>/<name>` に解決される。そのディレクトリは存在せず、
  `install.missing = false` のため lazy は黙って読み込まない。**実測済み**(§6.3 の 3 番目の表)。

**(2) `localPlugins` を読むコードが 1 つも存在しない。**

| 読み手 | 実際に読むキー | `localPlugins` |
|---|---|---|
| `nix/lib/make-env.nix` | `pluginsDb.lazyNvim.inputName`(`:35`)、`pluginsDb.plugins`(`:49`, `:76`) | 読まない |
| `nix/lib/sources.nix` | `flake.lock` のみ(`:6-8`) | 読まない |
| `nix/lib/resolve-plugin.nix` | make-env から渡る `name` / `src` / `build` のみ | 読まない |
| `lua/nvimx/genflake.lua` | `plugins` / `lazyNvim` | 読まない |
| `lua/nvimx/resolve.lua`(prev として) | `schemaVersion` / `plugins` | 読まない(prev の `localPlugins` は毎回 raw-spec から作り直す) |
| `nix/home-manager/default.nix` | `cfg.env.*` のみ | 読まない |

→ 書きっぱなしのフィールドである。本件はこれを Nix 側に読ませる。

### 1.4 ドキュメントが既に公表しているインタフェース

- `docs/architecture.md:396-397` —— `devPlugins = [ ];` / `devPath = "~/projects";` がモジュール例に載っている。
- `docs/architecture.md:366` —— forced opts の列挙が既に `dev = { path = <function>, ... }` になっている。
- `docs/architecture.md:367` —— 「**dev.path is a function**: names listed in `devPlugins` return `devPath`
  (e.g. `~/projects`), everything else returns the farm」。
- `docs/architecture.md:510` —— edge-case 表の
  `| Local plugin development (dev=true) | supported alongside via devPlugins / devPath + the dev.path function |`。
- `docs/architecture.md:525` —— `7. **Finishing touches**: devPlugins, extraLuaPackages, ...`。
- `README.md` には `devPlugins` / `devPath` の記述は**まだ 1 行も無い**(`## Options` は `:182-205`)。

つまり architecture.md は「実装済みの体」で書かれているが実装が無い。本件でその差を埋める。

### 1.5 既存フィクスチャ / checks の状況

- `tests/fixtures/local-plugin/` は**名前が紛らわしいが本件とは無関係**である。中身は
  `Makefile` / `doc/local-plugin.txt` / `lua/local-plugin.lua` / `scripts/run` で、
  「ビルドや解決の素材となるプラグインのソースツリー」として使われている。使用箇所は
  `checks.plugin-drv-phases`(`flake.nix:289`)、`checks.plugins-nixpkgs-fallback`(`:646`)、
  `checks.build-registry`(`:721`, `:764`, `:774`, および `blinkRefuses` の probe `:834`)、
  `checks.plugins-escape-hatch`(`:892`)。**`checks.build-shell`(`:269-280`)は使っていない** ——
  そちらが読むのは `tests/fixtures/build-plugins/nvimx-lock` である。本件では**触らない**。
- `localPlugins` が非空の fixture は**現在 1 つも存在しない**
  (`tests/fixtures/*/nvimx-lock/plugins.json` はすべて `"localPlugins": {}`。
  例: `tests/fixtures/basic-config/nvimx-lock/plugins.json:11`)。
  `tests/fixtures/import-lazy-lock/raw-spec.json` に `local.nvim`(`dev`/`dir` 付き)があるが、
  そちらは resolve.lua の分類テスト用であって Nix 側には渡らない。
- `checks` は `flake.nix:154-2530`。mkHmCheck ベースの 4 件は `:216-251`、末尾の check は
  `resolve-import-lazy-lock`(`:2200-2528`)で、`:2528` の `'';` の次の `:2529` が `checks` を閉じる `}`。

## 2. ゴール

issue の "Done when" を検証可能な形に落とす。

- **G1(dev への切り替え)**: `programs.nvimx.devPlugins = [ "<name>" ]` を設定すると、生成された
  `bootstrap.lua` を通した実 lazy.nvim が `<name>` の `dir` を `<devPath>/<name>` に解決し、
  他のプラグインは `<farm>/<name>` のままである。`checks.dev-plugins` の runtime 半分が機械的に証明する。
- **G2(既定の no-op)**: `devPlugins` を設定しないとき、実 lazy.nvim が解決する全プラグインの `dir` が
  `<farm>/<name>` になる —— すなわち今日の `path = farm` という string 形式と**完全に同一**。
  issue の「with no dev plugins, the generated bootstrap.lua is functionally identical to today's」の直接証明。
- **G3(`localPlugins` の消費)**: `plugins.json` の `localPlugins` の**各キー**が `makeEnv` の新出力 `devDirs` に現れ、
  値は `<devPath>/<name>` になる。spec 由来の `dev = true` プラグインは、`devPlugins` に書かなくても
  作業ツリーから読み込まれる(§1.3(1) の破綻の修正)。
- **G3'(`devDirs` の値は必ず `devPath` 配下)**: `localPlugins[*].dir` に記録された値は読まないので、
  `devDirs` の**全 value** が `<devPath>/<name>` になる。したがって
  **`plugins.json` 由来のマシン依存な値は `bootstrap.lua` に 1 バイトも入らない** ——
  `grep -F "$HOME" <生成された bootstrap.lua>` が(`devPath` にユーザ自身が絶対パスを書いた場合を除き)空になる。

  **これは `devDirs` についての主張であって、「`devPath` が全ての dev プラグインの位置を決める」ではない。**
  spec が `dir` を書いたプラグインは lazy が `meta.lua:214-217` で短絡するので、`devDirs` に何が載っていても
  そちらが勝つ。`devPath` が実際に位置を決めるのは
  「`devPlugins` に挙げた名前」と「`dir` を持たない素の `dev = true`」だけである。
  この限定は shipped な doc string 4 箇所(module の 2 オプション、README、architecture.md `:510`)にも
  明示する —— そうしないと `{ "o/x.nvim", dev = true, dir = "~/mine/x" }` を書いているユーザが
  `devPath` を変えて「何も起きない」に遭遇する。しかもその名前は `localPlugins` のキーなので
  `unknownDevPluginNames` にも出ない(§3.3 の判定規則)ため、**完全に無言の no-op** になる。
- **G4(誤字の可視化)**: lock にも `localPlugins` にも無い `devPlugins` の名前が `unknownDevPluginNames` として
  報告され、home-manager の activation warning になる。lock が無い degraded モードでは**報告しない**。
- **G5(lock を汚さない)**: `devPlugins` に挙げたプラグインも lock と farm に残る。
  `plugins.json` / `flake.lock` / `flake.nix` および resolve/extract/genflake の出力は**1 バイトも変わらない**。
  名前を外せば再 lock 無しで pin されたビルドに戻る。
- **G6(オフラインで検証可能)**: 新しい check 2 件のうち `dev-plugins` はネットワークを一切使わない。
  `hm-module-dev` は `hm-module` が既に取得する basic-config の lock だけを使い、**新規の fetch を足さない**。
- **G7(ドキュメント)**: README に `devPlugins` / `devPath` の行と `### Local plugin development` 節が入り、
  「dev プラグインは意図的に再現性保証の外である」ことが明記される。architecture.md の予告が実装済みの記述になる。

## 3. 設計

### 3.1 `bootstrap.lua.in`: `dev.path` を関数にする

プレースホルダを 1 個増やす(`:4` の直後):

```lua
local farm = "@farm@"
-- Plugin name -> working-tree directory, for plugins under local development.
-- Empty unless devPlugins / devPath (or a dev/dir entry in the spec) put something in it.
local dev_dirs = @devDirs@
```

`dev` ブロック(`:21-28`)を差し替える:

```lua
    -- Treat every plugin as is_local under the farm so that lazy's git/install
    -- pipeline is skipped entirely (we only read from the store). Plugins named in
    -- devPlugins -- and the spec's own dev/dir plugins, which have no farm entry at
    -- all -- resolve to their working tree instead, deliberately outside the
    -- reproducibility guarantee.
    dev = {
      -- A function, not a string: lazy appends "/<name>" only to the string form
      -- (lua/lazy/core/meta.lua:229-231), so the function has to return the full plugin
      -- directory itself. With dev_dirs empty this is exactly the old `path = farm`.
      -- The result goes through Util.norm, which is what expands a leading "~".
      path = function(plugin)
        return dev_dirs[plugin.name] or (farm .. "/" .. plugin.name)
      end,
      patterns = { "" },
      fallback = false,
    },
```

`dev_dirs` は `farm` の直後・`vim.opt.rtp:prepend` の前に置く。クロージャが `farm` と `dev_dirs` の
両方を上位スコープから捕まえる形になる。

**却下する代替案 A: `devDirs` をシェル/Nix 文字列連結で書く。**
キーはプラグイン名で `.` や `-` を含み、値はユーザ指定のパスである。素朴な `"${k}" = "${v}"` 連結は
引用符・バックスラッシュのエスケープを自前で持つことになる。`lib.generators.toLua` が
`{\n  ["a.nvim"] = "/x/y"\n}` を正しく生成することを pinned nixpkgs で実測確認済み(§6.5)なので、それを使う。

**却下する代替案 B: `dev.path` を string のままにして `devPath` を指し、`patterns` で振り分ける。**
`patterns` は url に対する部分一致であって名前に対する指定ではないうえ、string 形式は全プラグインに
`"/" .. name` を後置するので「一部だけ farm、一部だけ作業ツリー」が原理的に表現できない。
architecture.md:367 が既に function を宣言しているのもこの理由による。

**却下する代替案 C: `dev.fallback = true` にして「作業ツリーが無ければ farm に戻る」。**
`:232` の `vim.fn.isdirectory(dev_dir) == 1` が真のときだけ dev dir を使う挙動になる。
一見親切だが、(a) 作業ツリーの clone を忘れたまま store のコピーで作業してしまう事故が起きる、
(b) ビルド結果が評価時に決まらずユーザのファイルシステムに依存する、という 2 点で nvimx の方針に反する。
**`fallback = false` を維持する**(決定済み)。

### 3.2 `nix/lib/bootstrap.nix`: `devDirs` を受け取って埋め込む

現在は `{ farm }` の 1 引数(`:3`)。`devDirs` を既定値付きで足す。既定値を付けるのは、
このファイルの唯一の呼び出し元が `make-env.nix:95` だけであるにせよ
(`grep -rn 'bootstrap.nix\|mkBootstrap' --include=*.nix .` で確認済み)、
「dev プラグインが 1 つも無い」が構造上の既定であることをシグネチャに書いておくためである。

`pkgs.lib.generators.toLua { } { }` は `"{}"` を返す(pinned nixpkgs で実測、§6.5)。したがって
`devDirs` 省略時の生成物は `local dev_dirs = {}` になり、関数は常に `farm .. "/" .. plugin.name` を返す。

### 3.3 `nix/lib/make-env.nix`: `localPlugins` の消費と `devDirs` の導出

新しい formal は `plugins` / `treesitter` のような attrset にはせず、`vimAlias` / `extraPackages` と同じ
**フラットなスカラ 2 個**にする。`devPlugins` と `devPath` は互いに独立した 2 つのトップレベルオプションであり、
`plugins.overrides` / `plugins.nixpkgsFallback` のような「同じ対象に対する複数の手段」ではないからである。
モジュール側の `programs.nvimx.devPlugins` / `programs.nvimx.devPath` とも 1 対 1 に対応する。

`devDirs` は **`devPlugins` と `localPlugins` のキーを合わせた名前集合を、一様に `<devPath>/<name>` に写した map**である。
2 つの供給源は同じ値の形しか作らないので、優先順位も `//` によるマージも存在しない:

```nix
  devDirs = lib.genAttrs (lib.unique (devPlugins ++ builtins.attrNames localPlugins)) (
    n: "${devPath}/${n}"
  );
```

- `lib.unique` は `devPlugins` と `localPlugins` に同じ名前が両方あっても 1 回だけ数えるためのもの。
  `genAttrs` は重複キーを黙って畳むので厳密には不要だが、意図を書き残す意味で置く。
- **`devPlugins` の名前は、lock に一致するものが無くても `devDirs` に載る。**
  つまり `devDirs` のキー数は `unknownDevPluginNames` の中身とは無関係であり、
  `devPlugins = [ "typo.nvim" ]` は `devDirs."typo.nvim" = "<devPath>/typo.nvim"` を作ったうえで
  `unknownDevPluginNames = [ "typo.nvim" ]` も出す。**意図的にそうする**:
  1. **エントリは不活性である。** その名前を持つプラグインが spec に存在しない以上、
     lazy は `dev_dirs` をその名前で引くことが無い。害は `bootstrap.lua` の 1 行だけである。
  2. **誤字を伝える役目は `unknownDevPluginNames` が既に負っている。** `devDirs` から取り除いても
     ユーザに伝わる情報は 1 ビットも増えない。
  3. **取り除くと `devDirs` を lock の検証に結合させてしまう。** そうすると `devDirs` の意味が
     「lock がある時」と「無い時」で変わる —— degraded モードでは `hasLock = false` なので
     判定材料が無く(§3.3 の `unknownDevPluginNames` の規則)、同じ `devPlugins` に対して
     lock の有無だけで `devDirs` が変わることになる。挙動上の利得ゼロでこの結合を買う理由が無い。
  `checks.dev-plugins` の `attrNames` 行がこの決定を固定する(§6.3)。
- **`localPlugins[*].dir` は意図的に読まない。** 根拠は 2 つあり、**決め手は 2 番目**である:
  1. **読んでも行き先は変わらない(決め手)。** ユーザが spec に `dir` を書いた場合、lazy は
     `meta.lua:214-217` で短絡し、`dev.path` を**一切参照しない**。したがって `devDirs` が実際に
     行き先を決められるのは「`dir` を持たない素の `dev = true`」エントリだけであり、
     **それはまさに `devPath` の担当**である。`dir` 付きのエントリを `devDirs` に載せても
     runtime では無視される無害な no-op になる —— §6.6(b) の 1 行目と 2 行目で
     `dirred.nvim` の値が `dev_dirs` の中身に関わらず一致することが実測されている。
     すなわち `dir` を読むコードは**定義上 1 度も観測可能な効果を持たない**。
  2. **読むと、読まなくてよかったマシン依存の値を運んでしまう(副次的)。** 記録される `dir` は
     spec の書き方で 3 通りに分かれる(冒頭の表、§6.6(c) で実測):
     `dev = true` のみなら lazy が `dev.path` から導出した絶対パス、
     `dir = "~/x"` なら `meta.lua:217` の `Util.norm` が `~` を展開した絶対パス —— **この 2 つは
     lock を走らせたマシンの `$HOME` を含む**。`dir = "/abs/x"` のときだけ逐語の、
     マシンに依存しない値が入る。つまり「記録値は常にマシン依存」ではないが、
     **3 通りのうち 2 通りではそうである**。1 の判断に従えば、この区別を気にする必要がそもそも無くなる。
- 結果として `devDirs` の**全 value が `<devPath>/<name>`** になり、`plugins.json` 由来の
  マシン依存な値は `bootstrap.lua` に一切入らない(G3')。ただし G3' の但し書きのとおり、これは
  「`devPath` が全ての dev プラグインの位置を決める」という意味ではない —— spec が `dir` を書いた
  プラグインでは lazy がそちらで短絡する。shipped な doc string ではこの限定を明示すること。
- `localPlugins` は `hasLock` でガードする。他の `pluginsDb` 読みと同じ扱いで、degraded モードを壊さない。
- 古い `plugins.json`(`localPlugins` キーが無い世代)に備えて `pluginsDb.localPlugins or { }`。

**却下する代替案: `localPlugins[*].dir` を優先する(当初案)。**
「spec が明示した `dir` は lazy 側でも勝つのだから map もそれを映すべき」という筋は、
記録値が常に spec 由来だという誤った前提に立っていた(上記 2 の 3 通り)。しかもミラーリングとしての
価値もゼロである —— 上記 1 のとおり、`dir` を持つエントリでは lazy が短絡するので、
map が何を言おうと runtime の結果は同じだからである。この案を採ると得るものが無いまま
(a) `devPath` が `localPlugins` エントリに対して一度も適用されない、
(b) 3 通りのうち 2 通りで、コミットされた lock 経由で他人の `$HOME` が配られる、
(c) `devPlugins` に明示した名前が記録値に黙って負ける、という 3 つの実害だけが残る。詳細は §7 R1。

`unknownDevPluginNames` は `unknownPluginNames`(`:74-80`)と同型にする:

- **throw ではなく報告**。degraded パスを壊さないため、そして「効果が無いだけで壊れてはいない」ため。
- `hasLock` が偽のときは**空リスト**。判断材料が無い状態で誤字と断じてはならない。
- 判定は `pluginsDb.plugins` と `localPlugins` の**両方**に無いこと。`localPlugins` にある名前を
  `devPlugins` に重ねて書くのは無意味ではあるが誤字ではない(その名前は現に dev 扱いされる)。

**却下する代替案: 未知の名前を throw する。**
`unknownPluginNames` が既に「報告するが落とさない」という前例を作っており(`make-env.nix:72-73` のコメント)、
throw にすると degraded モード(lock がまだ無い初回)で `devPlugins` を先に書いたユーザが
evaluation ごと落ちる。lock を作るためのコマンド自体が手に入らなくなる鶏卵問題の再来である。

### 3.4 `nix/home-manager/default.nix`: オプションと warning

- `devPlugins`: `lib.types.listOf lib.types.str`、既定 `[ ]`。
- `devPath`: `lib.types.str`、既定 `"~/projects"`。

**`types.path` ではなく `types.str` である理由**(description にも書く): `types.path` は値を store にコピーする。
作業ツリーを store にコピーしたら、それは編集しても反映されない不変のコピーであって、
この機能の目的そのものを破壊する。加えて `~` を含むリテラルは path 型では表現できない。
`lock.projectDir`(`:174-183`)が同じ理由で `nullOr str` になっているのと同じ判断であり、
そちらも `:26-27` で `''${project/#\~/$HOME}` と自前展開している。本件では Nix 側の展開は不要で、
lazy の `Util.norm` が実行時に展開する(§1.2)。

warning は既存 3 本(`:218-235`)の末尾に 4 本目を足す。`unknownPluginNames` の文面
(`:224-229`)を踏襲し、最後の 1 行(「Use the name lazy derived for the plugin」)も揃える。

`makeEnv` へ渡す `inherit (cfg)` リスト(`:239-247`)にも**両方**を足す。

**ここは評価器が守ってくれない。** `makeEnv` の formals には `...` が無い(`make-env.nix:6-16`)が、
それが弾くのは**宣言されていない引数を渡した**場合だけである。`devPlugins ? [ ]` /
`devPath ? "~/projects"` はどちらも既定値付きなので、**渡し忘れは常にエラーにならず、
黙って `makeEnv` 側の既定値に落ちる**(Nix の formals の意味論。実測確認済み)。
したがって `devPlugins` だけ・`devPath` だけ・両方、のいずれを落としても評価は通り、
`hm-module-dev` もグリーンのままになる。**この 3 通りすべてを検知するのは
`checks.dev-plugins` の `moduleDevDirs` assert(§6.3)だけ**である。
`...` が無いことが実際に効くのは逆方向 —— `inherit` リストに名前を足して formal を足し忘れた場合であり、
そちらは確かに即エラーになる。この性質は維持する。

### 3.5 「dev プラグインは再現性保証の外」という位置づけ

- `devPlugins` に挙げたプラグインは **lock にも farm にも残り続ける**。resolution / flake input / `pluginDrvs` は
  何も変わらない。変わるのは lazy に教えるディレクトリだけである。したがって名前を外せば、
  再 lock なしでその瞬間から pin されたビルドに戻る。これは「一時的に外す」ことを安全にするための設計である。
- **これは `devPlugins` 由来の名前だけの性質である。** spec が `dev = true` と書いたプラグインは
  `resolve.lua:616-619` が `local_plugins` へ振り分けるので、そもそも flake input も lock エントリも
  farm エントリも持たない(`make-env.nix:40-51` / `:82-93` はどちらも `pluginsDb.plugins` しか走査しない。
  §1.3(1) / G3)。外すべき「名前」が存在しないので、pin されたビルドに戻すには spec から
  `dev = true` を消して再 lock する必要がある。2 つを混同しないこと ——
  README と architecture.md の文面でも区別する(§5.8(c) / §5.9 の `:510` 行)。
- 一方、名前が載っている間はそのプラグインの内容が `flake.lock` から決まらない。README と
  module の description の両方で明言する(G7)。
- `devDirs` は `bootstrap.lua` に焼き込まれるので、`devPlugins` / `devPath` を変えると
  `bootstrap.lua` と wrapper が作り直される。farm もプラグイン derivation も再利用されるので、
  再 fetch も再ビルドも起きない(数百バイトの `writeText` と `wrapProgram` だけ)。

## 4. 既存機能との関係

### 4.1 `vim.tbl_deep_extend("force", opts, forced)`(`bootstrap.lua.in:36`, `:38`)

ユーザが自分で `dev.path` / `dev.fallback` を設定していても、スカラなので `forced` が上書きする ——
**今日と同じ**。`dev.patterns` も **`forced` の `{ "" }` で丸ごと置き換わる**:
`vim.tbl_deep_extend` が再帰するのは「table であり、かつ非空のリストでない」値だけなので、
リスト同士はインデックス単位でマージされずに右辺が勝つ。ユーザの `{ "folke", "x" }` は
`{ "", "x" }` ではなく `{ "" }` になる(実測確認済み)。これも**今日と同じ**であり、
本件はマージの形を変えないので新たな露出は無い。コード変更は不要だが、この事実は §7 R4 に残す。

**ユーザ自身の `dev.path` は、runtime では `forced` に上書きされて完全に無効である。**
`programs.nvimx.devPath` がそれを置き換える —— これは今日 `path = farm` が同じことをしているのと同型であり、
本件で新しく生じる制約ではない。ユーザは lazy の `dev.path` ではなく nvimx の `devPath` を設定する。

一方 **extract 時には** ユーザの `dev.path` が生きている(`extract.lua:43-50` の `safe_opts` に `dev` キーが無い)。
結果として、`dir` を書いていない `dev = true` プラグインの `localPlugins[*].dir` は
「lock を走らせたマシンで、ユーザ自身の `dev.path`(既定 `~/projects`)から導かれ、`~` が展開済みの絶対パス」になる。
`dir` も書いてある場合はその値が(`~` 始まりなら展開されて)入るので、記録値は一様ではない。
§3.3 がこの値を読まないと決めた**決め手はその一様でなさではなく**、
`dir` を持つエントリでは `meta.lua:214-217` の短絡により読んでも結果が変わらないことである。詳細は §7 R1。

### 4.2 `lazy.nvim` 自身 —— `dev.path` は関与しない

runtime では実 `lazy.setup` が `{ "folke/lazy.nvim" }` を spec に足す(`lua/lazy/core/plugin.lua:333`)。
**ただしその `dir` は `dev.path` からは決まらない。** spec の parse(`:335`)が終わった直後に
`:338-341` が `lazy.dir = Config.me` で無条件に上書きするからである。`Config.me` は
`config.lua:299-300` の `debug.getinfo(1, "S").source` を 4 階層遡って正規化した値、すなわち
**rtp 上で実際にロードされた lazy.nvim のルート**である。bootstrap は `:6` で
`farm .. "/lazy.nvim"` を rtp に prepend しているので、これは常に `<farm>/lazy.nvim` になる ——
実測済み(§6.6(a) の全 3 行で一致)。

帰結:

- `devPlugins` に `"lazy.nvim"` と書いても**何も起きない**。`dev_dirs` にエントリは入るが、
  `lazy.dir` は `Config.me` に上書きされるので参照されない。
  加えてその名前は `unknownDevPluginNames` として**報告される** ——
  `lazy.nvim` は `pluginsDb.plugins` ではなく `pluginsDb.lazyNvim` という別のキーに居るためである(§3.3)。
  これは望ましい挙動で、「lazy.nvim 自体を dev にすることはできない」ことがユーザに伝わる。
- `tests/dev-path-test.lua` の `lazy.nvim` に対する assert は、したがって `dev_dirs` ではなく
  **rtp の prepend と `Config.me` の経路**を守るものである(§6.2 のコメントもそう書く)。
  farm の外の lazy.nvim が拾われていれば落ちる。

### 4.3 #25(`--import-lazy-lock`)との関係

`resolve.lua` の import は `local_plugins` に落ちたプラグインを分類 3L
(`import: skipped <name>: it is a local plugin (dev/dir), so there is nothing to pin`)で明示的に扱っており、
`localPlugins` の意味論は既に「pin する対象が無いもの」で固定されている。本件はその意味論を変えず、
**Nix 側にその情報を読ませるだけ**である。`resolve.lua` / `lock-app.nix` は無変更。

### 4.4 #49(spec に `folke/lazy.nvim` を書くと synthetic input と衝突)

無関係。本件は input を 1 つも増減させない。

## 5. 実装手順

行番号は現在の作業ツリー基準。**行番号の大きい順に当てるか、シンボルで位置決めすること。**

### 5.1 `lua/nvimx/bootstrap.lua.in`

1. `:4`(`local farm = "@farm@"`)の**直後**に 3 行を挿入(§3.1 の前半をそのまま)。
2. `:21-28` の `dev` ブロックを §3.1 の後半で置き換える。`:24` の TODO 行はここで消える。

変更後のファイル全体(**この内容をそのまま書く**):

```lua
-- nvimx runtime bootstrap (injected via the wrapper's --cmd luafile)
-- The user's lua stays unmodified. require("lazy") is intercepted via preload and
-- replaced with a setup that merges in the forced opts.
local farm = "@farm@"
-- Plugin name -> working-tree directory, for plugins under local development.
-- Empty unless devPlugins / devPath (or a dev/dir entry in the spec) put something in it.
local dev_dirs = @devDirs@

vim.opt.rtp:prepend(farm .. "/lazy.nvim")

package.preload["lazy"] = function()
  -- Unregister ourselves first, then require the real lazy
  package.preload["lazy"] = nil
  package.loaded["lazy"] = nil
  local lazy = require("lazy")

  local forced = {
    install = { missing = false },
    checker = { enabled = false },
    change_detection = { enabled = false },
    pkg = { enabled = false },
    rocks = { enabled = false, hererocks = false },
    readme = { enabled = false },
    -- Treat every plugin as is_local under the farm so that lazy's git/install
    -- pipeline is skipped entirely (we only read from the store). Plugins named in
    -- devPlugins -- and the spec's own dev/dir plugins, which have no farm entry at
    -- all -- resolve to their working tree instead, deliberately outside the
    -- reproducibility guarantee.
    dev = {
      -- A function, not a string: lazy appends "/<name>" only to the string form
      -- (lua/lazy/core/meta.lua:229-231), so the function has to return the full plugin
      -- directory itself. With dev_dirs empty this is exactly the old `path = farm`.
      -- The result goes through Util.norm, which is what expands a leading "~".
      path = function(plugin)
        return dev_dirs[plugin.name] or (farm .. "/" .. plugin.name)
      end,
      patterns = { "" },
      fallback = false,
    },
  }

  local setup = lazy.setup
  ---@diagnostic disable-next-line: duplicate-set-field
  lazy.setup = function(spec, opts)
    -- Also handle the setup(opts) form, where the spec lives in opts.spec
    if type(spec) == "table" and spec.spec ~= nil and not vim.islist(spec) then
      return setup(vim.tbl_deep_extend("force", spec, forced))
    end
    return setup(spec, vim.tbl_deep_extend("force", opts or {}, forced))
  end

  return lazy
end
```

### 5.2 `nix/lib/bootstrap.nix`

ファイル全体を差し替える(**この内容をそのまま書く**):

```nix
# Generates bootstrap.lua by replacing @farm@ / @devDirs@ in bootstrap.lua.in
{ pkgs }:
{
  farm,
  # Plugin name -> working-tree directory, for plugins under local development. Rendered straight
  # into the Lua source, so it goes through lib.generators.toLua rather than string concatenation:
  # the keys are plugin names and the values are user-supplied paths, neither of which this file
  # should be quoting by hand.
  devDirs ? { },
}:
pkgs.writeText "nvimx-bootstrap.lua" (
  builtins.replaceStrings
    [ "@farm@" "@devDirs@" ]
    [
      "${farm}"
      (pkgs.lib.generators.toLua { } devDirs)
    ]
    (builtins.readFile ../../lua/nvimx/bootstrap.lua.in)
)
```

上記は**nixfmt 正規形をそのまま貼ったもの**なので、逐語で書き写せば §8 手順 1 の `nix fmt -- --ci`
(`--fail-on-change` を含意する。CI も同じコマンドを走らせる ——
`.github/workflows/check.yml:22`)がそのまま通る。`replaceStrings` の 3 引数を 1 行にまとめた形は
nixfmt が上記へ展開し直すので、短く書き直さないこと。
`@devDirs@` を空 attrset で呼んだときの生成結果が `local dev_dirs = {}` になることは §6.5 で実測済み。

### 5.3 `nix/lib/make-env.nix`

1. **formals(`:6-16`)** —— `treesitter ? { },`(`:15`)の直後、閉じ `}`(`:16`)の直前に:

   ```nix
     # Plugin names to load from a working tree under devPath instead of the Nix store. Flat
     # scalars rather than a `dev = { ... }` attrset: unlike plugins / treesitter these are two
     # independent top-level options, and they map 1:1 onto the module's own two options.
     devPlugins ? [ ],
     devPath ? "~/projects",
   ```

2. **`let` の中、`unknownPluginNames`(`:74-80`)の直後・`farm`(`:82`)の直前**に:

   ```nix
     # localPlugins: the plugins the spec marked dev/dir, which resolve.lua deliberately keeps out
     # of the lock (there is nothing to pin). They have no farm entry either, so without a dev dir
     # they resolve to a store path that does not exist. Guarded by hasLock like every other
     # pluginsDb read, and tolerant of a plugins.json written before the key existed.
     localPlugins = if hasLock then pluginsDb.localPlugins or { } else { };

     # Name -> working-tree directory, handed to bootstrap.lua. Only the *keys* of localPlugins are
     # used; the recorded localPlugins[*].dir is deliberately NOT -- reading it could not change a
     # single resolved directory. A `dir` the user wrote in the spec short-circuits lazy before
     # dev.path is ever consulted (lua/lazy/core/meta.lua:214-217), so the only entries this map can
     # actually decide are the bare `dev = true` ones, which is exactly what devPath is for. That
     # also spares us having to care what the recorded value even is: `dev = true` alone records the
     # path lazy derived from the user's own dev.path (defaulting to ~/projects) and `dir = "~/x"`
     # records a norm'd one, both absolute and both carrying the $HOME of whoever ran the lock,
     # while `dir = "/abs/x"` is kept verbatim. Every value here is therefore <devPath>/<name>, and
     # nothing machine-specific out of plugins.json reaches bootstrap.lua. (Which is not the same as
     # devPath deciding where every dev plugin loads from: for a spec entry that sets `dir`, lazy
     # short-circuits on that dir and never reaches this map. The option descriptions say so.)
     devDirs = lib.genAttrs (lib.unique (devPlugins ++ builtins.attrNames localPlugins)) (
       n: "${devPath}/${n}"
     );

     # Same rationale as unknownPluginNames: a name matching nothing is a typo that would otherwise
     # be a silent no-op. Reported rather than thrown so it cannot break the degraded (no lock)
     # path, and only computed when there is a lock to judge against.
     unknownDevPluginNames =
       if hasLock then
         builtins.filter (n: !(pluginsDb.plugins ? ${n}) && !(localPlugins ? ${n})) devPlugins
       else
         [ ];
   ```

3. **`:95`** —— `bootstrap = mkBootstrap { inherit farm; };` → `bootstrap = mkBootstrap { inherit farm devDirs; };`

4. **返り値の `inherit` ブロック(`:107-115`)** —— `treesitterWithoutPlugin`(`:113`)の直後、
   `hasLock`(`:114`)の直前に `devDirs` と `unknownDevPluginNames` を足す:

   ```nix
     inherit
       farm
       bootstrap
       wrapped
       pluginDrvs
       unknownPluginNames
       treesitterWithoutPlugin
       devDirs
       unknownDevPluginNames
       hasLock
       ;
   ```

### 5.4 `nix/home-manager/default.nix`

1. **`extraPackages`(`:88-93`)の直後、`plugins = {`(`:95`)の直前**に 2 オプションを挿入。
   README の `## Options` 表もこの宣言順を写すので、§5.8(a) の挿入位置と必ず一致させること:

   ```nix
       devPlugins = lib.mkOption {
         type = lib.types.listOf lib.types.str;
         default = [ ];
         example = [ "my-plugin.nvim" ];
         description = ''
           Plugin names to load from a working tree under devPath instead of the Nix store,
           keyed by the name lazy derived (the key in nvimx-lock/plugins.json).

           These plugins stay in the lock and in the farm, so removing a name here restores the
           pinned build with no re-lock. While a name is listed, that plugin is deliberately
           outside nvimx's reproducibility guarantee: the lock no longer describes what you run.

           Plugins your lazy spec itself marks `dev = true` are handled automatically and need
           no entry here; they follow devPath just the same -- unless that same spec entry also
           sets `dir`, in which case lazy uses the `dir` you wrote and devPath does not apply.
         '';
       };

       devPath = lib.mkOption {
         type = lib.types.str;
         default = "~/projects";
         example = "~/src";
         description = ''
           Where dev working trees live. A plugin nvimx develops locally -- named in devPlugins,
           or marked `dev = true` by your own lazy spec -- resolves to <devPath>/<name>. A
           leading `~` is expanded by lazy.nvim at runtime, not here.

           The one exception is a spec entry that sets `dir` itself: lazy uses that path directly
           and never consults devPath for it. Short of that, devPath is the only thing deciding
           where a dev plugin is loaded from.

           This replaces lazy.nvim's own `dev.path`, which nvimx overrides the same way it
           overrides the rest of dev: set this rather than `dev.path` in your spec.

           A str rather than a path on purpose: a path would copy the working tree into the
           Nix store, which is an immutable snapshot -- exactly what this option exists to avoid.
         '';
       };
   ```

2. **`env` の description(`:201-206`)** —— 出力の列挙に 2 つ足す。

   before(`:202-203`):
   ```
           The result of makeEnv (farm / bootstrap / wrapped / pluginDrvs /
           unknownPluginNames / treesitterWithoutPlugin / hasLock).
   ```
   after:
   ```
           The result of makeEnv (farm / bootstrap / wrapped / pluginDrvs /
           unknownPluginNames / treesitterWithoutPlugin / devDirs / unknownDevPluginNames /
           hasLock).
   ```

3. **warnings(`:218-235`)** —— `:235` の `'';` を `''` に変え、その後ろに 4 本目を足す:

   ```nix
         ++ lib.optional ((cfg.env.unknownDevPluginNames or [ ]) != [ ]) ''
           programs.nvimx: devPlugins names plugins that are in neither the lock nor its
           localPlugins, so they have no effect:
           ${lib.concatMapStringsSep "\n" (n: "  - ${n}") (cfg.env.unknownDevPluginNames or [ ])}
           Use the name lazy derived for the plugin (the key in nvimx-lock/plugins.json).
         '';
   ```

4. **`makeEnv` への受け渡し(`:239-247`)** —— `inherit (cfg)` のリストに 2 つ足す:

   ```nix
           inherit (cfg)
             package
             lockDir
             extraPackages
             vimAlias
             viAlias
             plugins
             treesitter
             devPlugins
             devPath
             ;
   ```

### 5.5 `tests/fixtures/dev-plugins/`(新規)

§6.1 を参照。3 ファイル(`nvimx-lock/plugins.json`、`nvimx-lock/flake.lock`、
`dev-root/tokyonight.nvim/lua/tokyonight-dev.lua`)。**`git add` を忘れないこと** —— nix は
git 管理下のファイルしか見ない。

### 5.6 `tests/dev-path-test.lua`(新規)

§6.2 を参照。全文をそのまま書く。`*.lua` なので stylua(2-space / double quotes / 120 桁)と
luacheck(`std = "luajit"`、`globals = { "vim" }`、`arg` は luacheck 標準)の対象である。

### 5.7 `flake.nix`

1. `hm-module-treesitter`(`:247-251`)の直後、`wrapper-aliases` のコメント(`:252`)の直前に
   `hm-module-dev` を挿入(§6.4)。
2. 末尾の `resolve-import-lazy-lock` の終端 `'';`(`:2528`)の直後、`checks` を閉じる `}`(`:2529`)の
   直前に `dev-plugins` を挿入(§6.3)。

### 5.8 `README.md`

**(a) `## Options` の表(`:186-203`)** —— `extraPackages` の行(`:195`)と
`plugins.overrides` の行(`:196`)の**あいだ**に 2 行。

**位置は §5.4 のモジュール側と揃えること。** README の表はモジュールのオプション宣言順を
行単位でそのまま写したものであり(`enable` → `package` → `configDir` → `lockDir` → `manageConfig` →
`vimAlias` → `viAlias` → `extraPackages` → `plugins.*` → `treesitter.grammars` → `lock.*` → `env`)、
§5.4 は `extraPackages`(`default.nix:88-93`)の直後に 2 オプションを挿入する。
表だけ `treesitter.grammars` の後に置くと両者がずれる。

```
| `devPlugins` | `listOf str` | `[ ]` | Plugin names to load from a working tree under `devPath` instead of the Nix store. See [Local plugin development](#local-plugin-development). |
| `devPath` | `str` | `"~/projects"` | Where dev working trees live. A locally developed plugin — named in `devPlugins`, or marked `dev = true` by your own spec — resolves to `<devPath>/<name>`, unless that spec entry also sets `dir`, which lazy uses directly instead. Replaces lazy.nvim's own `dev.path`. A `str`, not a `path`: a path would copy the tree into the store. |
```

`devPath` の行に `#local-plugin-development` へのリンクは**足さない**。この表のリンクは
`devPlugins` の行 1 本と `## How it works`(§5.8(d))の 1 本の計 2 本であり、
§8 手順 8 の `grep -c '(#local-plugin-development)' README.md` がその 2 を期待している。
代わりに但し書きをセル内に書き切る —— この行を読んだだけで終わる読者を、
`{ ..., dev = true, dir = ... }` を書いているのに `devPath` を変えても何も起きない
(しかも `unknownDevPluginNames` にも出ない)状況に落とさないため(§2 G3')。

**(b) `env` の行(`:203`)** ——

before:
```
| `env` | `attrs` | _(derived)_ | The result of `makeEnv` (`farm` / `bootstrap` / `wrapped` / `pluginDrvs` / `unknownPluginNames` / `treesitterWithoutPlugin` / `hasLock`). Built automatically from the options above; a direct escape hatch for advanced users. |
```
after:
```
| `env` | `attrs` | _(derived)_ | The result of `makeEnv` (`farm` / `bootstrap` / `wrapped` / `pluginDrvs` / `unknownPluginNames` / `treesitterWithoutPlugin` / `devDirs` / `unknownDevPluginNames` / `hasLock`). Built automatically from the options above; a direct escape hatch for advanced users. |
```

**(c) 新しい節** —— `### Tree-sitter grammars` の末尾(`:352`、`a parser may refuse to load.` で終わる段落)の
直後、空行を挟んで `## How it works`(`:354`)の直前に挿入する。
以下は**インデント 4 桁で引用した README の実内容**であり、挿入時にはインデントを外すこと
(内部に ```` ```nix ```` フェンスがあるためこの計画書側ではネストできない):

    ### Local plugin development

    Sometimes you are not using a plugin, you are writing one. Name it, and nvimx points lazy.nvim at
    your working tree instead of the Nix store:

    ```nix
    programs.nvimx = {
      devPlugins = [ "my-plugin.nvim" ];
      devPath = "~/projects";        # the default
    };
    ```

    `my-plugin.nvim` is then loaded from `~/projects/my-plugin.nvim`, and every other plugin still
    comes from the store exactly as before. The name is the one lazy derived — the key in
    `nvimx-lock/plugins.json` — and a name that matches nothing there is reported as a warning during
    `home-manager switch` rather than silently doing nothing.

    Plugins your lazy spec already marks `dev = true` need no entry here: `nvimx-lock` records them
    and nvimx wires them up on its own, under `devPath` just the same. The exception is a spec entry
    that also sets `dir` — lazy uses that path directly and never consults `devPath` for it, so
    changing `devPath` will not move it. Short of that, `devPath` is the one place that decides where
    dev working trees live. If you were setting lazy.nvim's own `dev.path`, set `devPath` instead —
    nvimx overrides `dev.path` along with the rest of `dev`.

    Three things are deliberate:

    - **A missing working tree is not a fallback.** If `~/projects/my-plugin.nvim` does not exist,
      lazy simply shows the plugin as not installed. Quietly loading the store copy instead would
      mean editing files that are not the ones being loaded.
    - **A dev plugin is outside the reproducibility guarantee.** While a name is listed, `flake.lock`
      no longer describes what you actually run. That is the whole point while you are working on it
      — and it is why the plugin also *stays* in the lock and in the farm: remove the name from
      `devPlugins` and the pinned build is back, with no re-lock and no re-fetch.
    - **`devPath` is per-machine, and it is yours.** Nothing about where your working trees live is
      read back out of `nvimx-lock/`, so a lock you commit never *decides* where another machine
      loads a dev plugin from. (The lock does still *record* the directory lazy resolved on the
      machine that ran it; nvimx simply never reads it.) Point `devPath` wherever you keep your
      projects.

**(d) `## How it works` の段落(`:359-363`)** —— 「lazy.nvim loads everything from the Nix store」が
無条件には成り立たなくなるので和らげる。

before(`:360-363`):

    nvimx builds one derivation per plugin, collects them into a linkFarm, and wraps Neovim with a
    generated `bootstrap.lua` so lazy.nvim loads everything from the Nix store instead of running its
    own git/install pipeline. The same lock always yields the same result, no matter how often you
    switch.

after:

    nvimx builds one derivation per plugin, collects them into a linkFarm, and wraps Neovim with a
    generated `bootstrap.lua` so lazy.nvim loads from the Nix store instead of running its own
    git/install pipeline. The same lock always yields the same result, no matter how often you switch
    — the one exception being any plugin you deliberately point at a working tree with
    [`devPlugins`](#local-plugin-development).

### 5.9 `docs/architecture.md`

| 行 | before | after |
|---|---|---|
| `:67` | `... require('lazy') → preload shim<br/>dev.path = farm makes every plugin is_local"]` | `... require('lazy') → preload shim<br/>dev.path fn makes every plugin is_local (farm, or a devPlugins working tree)"]` |
| `:179` | 段落**全体**を差し替え(下記) | 下記 |
| `:202` | `  "localPlugins": { "myplugin": { "dir": "~/projects/myplugin" } },  // dir-specified. not locked` | `  "localPlugins": { "myplugin": { "dir": "/home/you/projects/myplugin" } },  // dev/dir plugins: not locked. make-env reads the *names* and routes them to devPath; the recorded dir is ignored, because a spec-level dir short-circuits lazy before dev.path is consulted anyway` |
| `:367` | `4. **dev.path is a function**: names listed in `devPlugins` return `devPath` (e.g. `~/projects`), everything else returns the farm → this keeps the user's own local plugin development (dev=true) workflow intact` | `4. **dev.path is a function**: `make-env.nix` bakes a name → directory table into `bootstrap.lua` (`devDirs`). Every name it holds — from `devPlugins`, or a key of the lock's `localPlugins` (the spec's own `dev = true` plugins) — maps to `<devPath>/<name>`; anything else falls back to `<farm>/<name>`. `devPath` is the single knob for the entries this table decides, and it replaces lazy's own `dev.path`, which the forced opts override anyway. `localPlugins[*].dir` is **not** read, because reading it could not change any resolved directory: a `dir` the user wrote in the spec short-circuits lazy before `dev.path` is consulted at all (`meta.lua:214-217`), so the only entries the table can decide are the bare `dev = true` ones. That also keeps the lock's recorded paths — absolute, and `$HOME`-bearing unless the user wrote an absolute `dir` themselves — from having any effect on another machine (the lock still records them; nothing reads them). The function must return the **full** plugin directory: lazy appends `/<name>` only to the string form (`lua/lazy/core/meta.lua:229-231`). `fallback = false` is kept, so a working tree that does not exist is *not* silently replaced by the store copy. A name in neither the lock nor `localPlugins` is reported as `unknownDevPluginNames` and warned about at activation time, like `unknownPluginNames`` |
| `:482` | fixtures 一覧。末尾は `... / update / import-lazy-lock / golden/` | `import-lazy-lock /` と `golden/` のあいだに `dev-plugins /` を挿入(`golden/` は末尾のまま) |
| `:491` | checks 一覧 | `treesitter-grammars,` の後に `dev-plugins,` を、`hm-module-treesitter,` の後に `hm-module-dev,` を追加 |
| `:510` | `| Local plugin development (dev=true) | supported alongside via `devPlugins` / `devPath` + the dev.path function |` | `| Local plugin development | `devPlugins` names them, `devPath` says where they live, and the dev.path function routes them; a spec-level `dev = true` is picked up automatically from `localPlugins` and follows `devPath` too, unless that spec entry also sets `dir` — then lazy short-circuits on the `dir` and `devPath` never applies to it. A plugin named in `devPlugins` stays in the lock and in the farm, so removing the name restores the pinned build with no re-lock; a spec-level `dev = true` plugin was never locked in the first place. A missing working tree is not fallen back on |` |
| `:525` | `7. **Finishing touches**: devPlugins, extraLuaPackages, non-GitHub validation, `checks.e2e-offline`, README` | `7. **Finishing touches**: devPlugins (#26), extraLuaPackages, non-GitHub validation, `checks.e2e-offline`, README` |

`:366`(forced opts の列挙)は既に `dev = { path = <function>, patterns = {""}, fallback = false }` と
書かれているので**無変更**。

#### `:179` の段落全体(**追記ではなく差し替え**)

既存の文が `dev.path = farm` という **string 形式**を名指ししているため、末尾に
「`dev.path` は関数である」という文を足すだけだと**同じ段落の連続する 2 文が矛盾する**。
`:366` / `:367`(どちらも `<function>`)とも食い違う。`:67` の mermaid ノードは既に
差し替える方針にしてあるので、ここも同様に既存の節を書き換える。
併せて「everything is loaded from the store」も、README `:361`(§5.8(d))と同じ理由で和らげる。

before(`:179` の 1 行、全文):

    At runtime the user's init.lua runs as-is, and `require("lazy")` goes through the preload shim so that `setup` receives the merged forced opts. Every plugin is treated as `is_local` via `dev.path = farm, patterns = {""}, fallback = false` → lazy's git/install pipeline is skipped entirely and everything is loaded from the store.

after:

    At runtime the user's init.lua runs as-is, and `require("lazy")` goes through the preload shim so that `setup` receives the merged forced opts. Every plugin is treated as `is_local` via `dev.path` (a function of the plugin, returning `<farm>/<name>` for anything not under local development), `patterns = {""}`, `fallback = false` → lazy's git/install pipeline is skipped entirely and everything is loaded from the store, the one exception being a plugin you deliberately point at a working tree with `devPlugins` (or one the spec itself marked `dev`). The function has to return the *full* plugin directory, because lazy appends `/<name>` only to the string form (`lua/lazy/core/meta.lua:229-231`).

### 5.10 触らないもの

- **`lua/nvimx/resolve.lua` / `extract.lua` / `genflake.lua` / `version.lua` / `update-summary.lua` / `json.lua`**
  —— `localPlugins` は既に正しい形をしている。本件は Nix 側にそれを読ませるだけであり、lock 生成の出力は
  1 バイトも変わらない(G5)。`extract.lua:61-65` に記録された既存の欠落
  (「`dev` の無い明示 `dir` は `localPlugins` に行かない」)は**別 issue として据え置き**(§7 R2)。
- **`nix/lib/sources.nix` / `wrapper.nix` / `farm.nix` / `plugin-drv.nix` / `resolve-plugin.nix` /
  `treesitter.nix` / `build-network.nix` / `lock-app.nix`**、`nix/build-registry/` 一式。
- **`plugins.json` のスキーマと `schemaVersion`** —— 読む側が増えるだけで、書式は変わらない。
- **`tests/fixtures/local-plugin/`** —— 名前は紛らわしいが `plugin-drv-phases` /
  `plugins-nixpkgs-fallback` / `build-registry` / `plugins-escape-hatch` 用のプラグインソースであり
  本件と無関係(§1.5)。
- **`tests/fixtures/*/nvimx-lock/plugins.json` の既存 4 件**
  (`basic-config` / `build-plugins` / `registry-plugins` / `treesitter-config`)—— 再生成不要。
- **`.github/workflows/*`** —— `nix flake check` の中身が増えるだけ。CLAUDE.md の規約により、
  仮にステップ追加が必要になっても編集は `check.yml` のみ。
- **`templates/default/`** —— dev 開発は「テンプレートから始めた直後」の話題ではないので触らない。
- **`CLAUDE.md`**、`docs/plans/` の既存ファイル。

## 6. テスト

新設は `checks.dev-plugins` と `checks.hm-module-dev` の 2 件。

### 6.1 新規フィクスチャ `tests/fixtures/dev-plugins/`

```
tests/fixtures/dev-plugins/
  nvimx-lock/
    plugins.json     # basic-config のものに非空の localPlugins(dir 無し / dir 有りの 2 形)を足した手書き
    flake.lock       # basic-config のものを逐語コピー
  dev-root/
    tokyonight.nvim/
      lua/tokyonight-dev.lua   # マーカー。作業ツリーが実在するディレクトリであることの担保
```

#### `tests/fixtures/dev-plugins/nvimx-lock/plugins.json`

```json
{
  "_comment": [
    "Hand-written plugins.json for checks.dev-plugins: basic-config's lock plus a non-empty",
    "localPlugins, which no other fixture has.",
    "make-env reads only the *keys* of localPlugins; every one of them routes to <devPath>/<name>,",
    "and the value is never looked at. The two entries pin that from both sides:",
    "  dirred.nvim has a `dir`, deliberately pointing somewhere devPath would never produce, so the",
    "  check fails loudly if anyone starts reading it. It is ignored not because it is machine-",
    "  specific -- a dir the user wrote absolute is recorded verbatim -- but because a spec-level",
    "  dir short-circuits lazy before dev.path is ever consulted (lua/lazy/core/meta.lua:214-217),",
    "  so reading it could not change any resolved directory. See the plan's SS3.3 and SS7 R1.",
    "  bare.nvim has no `dir` at all, so make-env must not need one. Note this shape is hand-made:",
    "  no current lock can emit it. resolve.lua builds localPlugins entries as { dir = p.dir } and",
    "  json.lua would render the resulting empty table as {}, but p.dir is never nil there --",
    "  extract.lua dumps Plugin.Spec.new's meta-resolved plugins, and lua/lazy/core/meta.lua",
    "  :229-238 always fills a dev plugin's dir in (measured: a bare `dev = true` came out",
    "  {\"dev\":true,\"dir\":\"<HOME>/projects/...\"}).",
    "  It stands for a plugins.json written by an older or future resolve.lua that omits the key,",
    "  and it is what makes `v.dir` reintroduced without an `or` fallback fail here rather than in",
    "  a user's config.",
    "What a real lock *does* produce is a dir-bearing entry like dirred.nvim -- either the path lazy",
    "derived from dev.path, or the one the spec wrote (verbatim if absolute, norm'd if it began",
    "with ~). Only this fixture's literal `~` is unrealistic; it is kept because it contrasts so",
    "visibly with devPath. A plugin that sets `dir` without `dev` produces no entry at all (SS7 R2)."
  ],
  "lazyNvim": {
    "inputName": "lazy-nvim",
    "source": {
      "owner": "folke",
      "repo": "lazy.nvim",
      "type": "github"
    },
    "synthetic": true
  },
  "localPlugins": {
    "bare.nvim": {},
    "dirred.nvim": {
      "dir": "~/elsewhere/dirred.nvim"
    }
  },
  "plugins": {
    "tokyonight.nvim": {
      "branch": null,
      "build": {
        "kind": "none"
      },
      "commit": null,
      "dependencies": [],
      "inputName": "tokyonight-nvim",
      "pin": null,
      "resolvedRef": null,
      "source": {
        "owner": "folke",
        "repo": "tokyonight.nvim",
        "type": "github"
      },
      "tag": null,
      "version": null
    }
  },
  "schemaVersion": 1,
  "warnings": []
}
```

`_comment` はトップレベルの余剰キーである。`make-env.nix` は `builtins.fromJSON` してから
必要なキーだけを引くので無害であり、`tests/fixtures/import-lazy-lock/prev.json` に前例がある。
このファイルが `resolve.lua` に `--prev` として渡ることは無い。

**リポジトリの慣習(本計画の全コード片で守ること)**: 出荷されるコメント
(`flake.nix` / `nix/**` / `lua/**` / fixture の `_comment`)から `file:line` の形で参照してよいのは
**pin された lazy.nvim seed のファイルだけ**である。実際、現在のツリーで出荷されているコメント中の
`file:line` は `lua/lazy/manage/task/plugin.lua` / `lua/lazy/manage/git.lua` / `lua/lazy/types.lua` の
3 種のみで、**nvimx 自身のファイルを行番号付きで参照している箇所は 1 つも無い**(確認済み)。
理由は明快で、seed は `flake.lock` が固定しているので行番号が動くのは意図的な bump のときだけ
(そのときは §7 R10 の check が落ちる)なのに対し、nvimx 自身のファイルは通常のリファクタで動き、
それを検知する手立てが無いからである。`6b13953 fix(lock): stop the import check from citing line
numbers it invalidates` はこの教訓の記録である。
したがって上の `_comment` でも `resolve.lua` / `json.lua` / `extract.lua` は**ファイル名だけ**で参照し、
行番号を付けるのは `lua/lazy/core/meta.lua:229-238` のような seed 側だけにしてある。
計画本文(この Markdown)側の `file:line` はこの制約の対象外 —— 計画は特定時点の記録だからである。

#### `tests/fixtures/dev-plugins/nvimx-lock/flake.lock`

`tests/fixtures/basic-config/nvimx-lock/flake.lock` の**逐語コピー**。手写しせず:

```bash
mkdir -p tests/fixtures/dev-plugins/nvimx-lock
cp tests/fixtures/basic-config/nvimx-lock/flake.lock \
   tests/fixtures/dev-plugins/nvimx-lock/flake.lock
```

このファイルの役割は `hasLock`(`make-env.nix:22-23` の
`pathExists (lockDir + "/plugins.json") && pathExists (lockDir + "/flake.lock")`)を真にすることだけである。
`sources.nix` は `getSource` という関数を返すだけの遅延評価であり(`nix/lib/sources.nix:9`)、
`checks.dev-plugins` の評価半分は `devDirs` / `unknownDevPluginNames` しか読まないので
`fetchTree` は 1 回も走らない。

#### `tests/fixtures/dev-plugins/dev-root/tokyonight.nvim/lua/tokyonight-dev.lua`

```lua
-- Marker file for checks.dev-plugins: it only has to make dev-root/tokyonight.nvim a real,
-- non-empty directory in the store, so that the dev dir the check asserts on is not merely a
-- string that happens to match. Never sourced: the test spec marks every plugin `lazy = true`.
return {}
```

**注意**: このファイルは `*.lua` なので stylua / luacheck の対象である。上記はどちらも通る形になっている。

### 6.2 新規 Lua ドライバ `tests/dev-path-test.lua`

`tests/semver-select-test.lua` と同じ流儀(素の `assert`、ローカルの `eq` ヘルパ、非ゼロ終了が失敗シグナル)。
**全文**:

```lua
-- Runtime test driver for the dev.path function in the generated bootstrap.lua (#26), run via
-- `nvim --clean -l` by checks.dev-plugins. Entirely offline: every spec entry below is
-- `lazy = true` and the bootstrap already forces install.missing = false, so the plugin
-- directories only ever have to be *resolved* -- nothing is fetched, sourced, or required.
--
-- Failure is a plain Lua error from assert(): letting the script die non-zero is enough to fail
-- the pkgs.runCommand check that drives this file.
--
--   arg[1]  the generated bootstrap.lua to exercise
--   arg[2]  that env's farm
--   arg[3]  the directory tokyonight.nvim must resolve to
--   arg[4]  the directory plenary.nvim must resolve to
--   arg[5]  the directory bare.nvim (a spec-level `dev = true`) must resolve to

-- The `dir` the spec below writes for dirred.nvim. Absolute on purpose: Util.norm leaves it
-- alone, so the expected value is a constant and nothing here depends on $HOME.
local DIRRED_DIR = "/nvimx-test/dirred"

local bootstrap, farm, want_tokyonight, want_plenary, want_bare = arg[1], arg[2], arg[3], arg[4], arg[5]
assert(
  bootstrap and farm and want_tokyonight and want_plenary and want_bare,
  "usage: nvim --clean -l dev-path-test.lua <bootstrap.lua> <farm> <tokyonight dir> <plenary dir> <bare dir>"
)

local function eq(a, b, msg)
  assert(a == b, (msg or "not equal") .. (": got %s, want %s"):format(tostring(a), tostring(b)))
end

-- Installs the preload shim, exactly as the wrapper's --cmd luafile does at runtime, so the
-- require("lazy") below goes through it and setup() sees the forced opts -- dev.path among them.
dofile(bootstrap)

require("lazy").setup({
  { "folke/tokyonight.nvim", lazy = true },
  { "nvim-lua/plenary.nvim", lazy = true },
  -- A spec-level dev plugin with no dir of its own: dev.path decides where it lives.
  { "o/bare.nvim", dev = true, lazy = true },
  -- ... and one that writes its own dir: lazy must short-circuit on it (meta.lua:214-217) and
  -- never consult dev.path, even though the check gives this name a dev_dirs entry too.
  { "o/dirred.nvim", dev = true, dir = DIRRED_DIR, lazy = true },
})

local plugins = require("lazy.core.config").plugins

-- The one contract this file exists for: lazy appends "/<name>" only to the *string* form of
-- dev.path (lua/lazy/core/meta.lua:229-231), so the function form has to return the full plugin
-- directory itself. A function returning the farm root would collapse onto it every plugin that
-- takes the fallback branch -- so with an empty dev_dirs all three of these fail, and with a
-- populated one whichever of them dev_dirs does not cover.
eq(plugins["tokyonight.nvim"].dir, want_tokyonight, "tokyonight.nvim")
eq(plugins["plenary.nvim"].dir, want_plenary, "plenary.nvim")
eq(plugins["bare.nvim"].dir, want_bare, "bare.nvim")

-- The fact make-env's whole devDirs design rests on, pinned at runtime rather than merely argued
-- for in the plan: a spec-level `dir` short-circuits lazy before dev.path is consulted, so this
-- plugin ignores its dev_dirs entry entirely. If a seed bump ever stopped short-circuiting, the
-- rationale for not reading localPlugins[*].dir would collapse -- and this line would go red
-- instead of nix flake check staying green.
eq(plugins["dirred.nvim"].dir, DIRRED_DIR, "dirred.nvim (spec dir must beat dev.path)")

-- A different contract, not a third case of the one above: lazy.nvim's own dir never comes from
-- dev.path at all. The real setup adds { "folke/lazy.nvim" } to the spec (lua/lazy/core/plugin.lua
-- :333) and then overwrites lazy.dir with Config.me right after parsing (:338-341), Config.me being
-- derived from where lazy itself was loaded from (lua/lazy/core/config.lua:299-300). So this pins
-- the bootstrap's own rtp prepend instead: nvimx's lazy.nvim has to be the farm's copy. It would
-- fail if the prepend were dropped or aimed elsewhere -- and it is unaffected by dev_dirs, which is
-- exactly why naming "lazy.nvim" in devPlugins does nothing.
eq(plugins["lazy.nvim"].dir, farm .. "/lazy.nvim", "lazy.nvim")

print("dev-path-test: all assertions passed")
```

### 6.3 `checks.dev-plugins`(新設)

挿入位置: `flake.nix:2528` の `'';` の直後、`:2529` の `}` の直前。

評価半分は `checks.treesitter-grammars`(`:941-1084`)の `failures` リスト方式、runCommand の形は
`checks.semver-select`(`:1153-1162`)に倣う。

**評価半分の assert 一覧(何を守るか)**

| assert | 何を守るか |
|---|---|
| `locked.devDirs."tokyonight.nvim" == "~/proj/tokyonight.nvim"` | `devPlugins` の名前が lock に載っているプラグインを上書きする |
| `locked.devDirs."bare.nvim" == "~/proj/bare.nvim"` | `localPlugins` のキーが消費されている。`dir` の無いエントリが `<devPath>/<name>` に落ちる |
| `locked.devDirs."dirred.nvim" == "~/proj/dirred.nvim"` | **記録されている `dir` が無視される**。フィクスチャの `dirred.nvim` は `"~/elsewhere/dirred.nvim"` を持っているので、`v.dir` を読む実装に戻した瞬間にこの行が落ちる —— §3.3 / §7 R1 の決定を固定する回帰ガード |
| `builtins.attrNames locked.devDirs == [ "bare.nvim" "dirred.nvim" "tokyonight.nvim" "typo.nvim" ]` | 余計なキーが混ざらない(3 本の個別 assert が「たまたま通る」ことを防ぐ)ことに加え、**`typo.nvim` を含むことで §3.3 の「lock に無い `devPlugins` 名も `devDirs` に載る(不活性であって除外はしない)」という決定を固定する**。`devDirs` から未知名を filter する実装に変えるとこの行が落ちる |
| `builtins.attrValues locked.devDirs` の全要素が `"~/proj/"` 始まり | `devDirs` の全 value が `devPath` 配下である(G3')ことの網羅的な言い換え。将来キーを増やしても効く |
| `locked.unknownDevPluginNames == [ "typo.nvim" ]` | 誤字だけが報告される。実在する名前が誤検知されない |
| `untouched.devDirs == { }` | 既定が真の no-op(`localPlugins` が空 + `devPlugins` 未指定) |
| `degraded.unknownDevPluginNames == [ ]` | lock が無いときは判断材料が無いので名前を裁かない |
| `moduleDevDirs == { "tokyonight.nvim" = "~/proj/tokyonight.nvim"; }` | **home-manager モジュールの受け渡し**。§5.4 手順 4 の `inherit (cfg)` から `devPlugins` / `devPath` の**どちらか一方でも**落とすと値が変わる。`checks.hm-module-dev` はこれを**検知できない**(下記)ので、ここで塞ぐ |

**なぜ `hm-module-dev` では足りないか**: `mkHmCheck`(`flake.nix:196-212`)は
`.activationPackage` を返すだけで中身について何も assert しない。`inherit (cfg)` から
`devPlugins` / `devPath` を落としても、オプションは型検査を通り、黙って無視され、
activation package はそのままビルドできてしまう(実測確認済み: exit 0 のまま)。

**「片方だけ落とせば eval エラーになるから半分は守られている」という考えは誤りである。**
`makeEnv` の formals は `devPlugins ? [ ]` / `devPath ? "~/projects"` と**既定値付き**なので
(`nix/lib/make-env.nix`。§5.3 手順 1 がコメント 3 行と一緒に挿入するため、行番号は挿入前後で動く)、
渡し忘れは**常に**黙って既定値に落ちる。`...` が無いことが弾くのは
「宣言されていない引数を渡した」場合だけで、方向が逆である(§3.4)。実測:
`devPath` だけ落とすと `devDirs` が `{ "tokyonight.nvim" = "~/projects/tokyonight.nvim"; }` になり
(`~/proj/...` ではない)、それでも評価は通り `hm-module-dev` はグリーンのままだった。

したがって **3 通りの落とし方(`devPath` のみ / `devPlugins` のみ / 両方)すべてを検知するのは
この assert だけ**である。3 通りとも `moduleDevDirs` の期待値と食い違うので、
いずれも "the hm module must pass devPlugins / devPath through to makeEnv" で落ちる(実測確認済み)。
一方 `checks.dev-plugins` の他の env は `nvimxLib.makeEnv` を直接呼ぶのでモジュール層を迂回する。よって
**モジュールを評価して `devDirs` を読み返す assert を 1 本足す**。

**runtime 半分の assert 一覧**

| 実行 | 期待 |
|---|---|
| `test -f <dev-root>/tokyonight.nvim/lua/tokyonight-dev.lua` | 作業ツリーが store に実在する(文字列一致の空振りでない) |
| `grep -qF 'dev_dirs[plugin.name]' ${plainEnv.bootstrap}` | 出荷されたのは関数形式である。string に戻す退行を検知 |
| `dev-path-test.lua ${devEnv.bootstrap} ...` | tokyonight → `<dev-root>/tokyonight.nvim`、plenary → `<devEnv.farm>/plenary.nvim`、**bare.nvim → `<dev-root>/bare.nvim`**、**dirred.nvim → `/nvimx-test/dirred`**、lazy.nvim → `<devEnv.farm>/lazy.nvim` |
| `dev-path-test.lua ${plainEnv.bootstrap} ...` | tokyonight / plenary / **bare.nvim** が `<plainEnv.farm>/<name>` —— **issue の「no dev plugins なら今日と機能的に同一」の直接証明**。**dirred.nvim は `/nvimx-test/dirred`** のまま(`dev_dirs` が空でも短絡は効く)、lazy.nvim → `<plainEnv.farm>/lazy.nvim` |

どちらの実行も**同じ 5 本**を assert する(`lazy.nvim` を含む)。期待値だけが違う。

**新規の 2 プラグインが守るもの(§3.3 の 2 本柱を runtime で固定する)**

| プラグイン | spec | 期待 | 何を守るか |
|---|---|---|---|
| `bare.nvim` | `dev = true`(`dir` 無し) | `devEnv` では `<devPath>/bare.nvim`、`plainEnv` では `<farm>/bare.nvim` | 素の `dev = true` では **`devPath` が行き先を決める**。§1.3(1) の破綻(今日は `<farm>/<name>` に解決されて存在しない)の修正そのもの |
| `dirred.nvim` | `dev = true` + `dir = "/nvimx-test/dirred"` | **両方の env で** `/nvimx-test/dirred` | spec の `dir` が `meta.lua:214-217` で短絡し、`dev_dirs` にエントリがあっても**参照されない**。`devDirs` が `localPlugins[*].dir` を読まなくてよい理由(§3.3 の決め手)が、議論ではなく実行で固定される |

`dirred.nvim` は `devEnv` の `devPlugins` に**わざと入れる** —— `dev_dirs` にエントリがあってもなお
spec の `dir` が勝つ、という所を見たいからである。`dir` は絶対パスなので `Util.norm` が素通しし、
期待値は `$HOME` に依存しない定数になる。どちらのプラグインも作業ツリーが存在する必要は無い
(`fallback = false` なので lazy は存在を確かめない)。

計画作成時に 4 プラグイン全ての解決結果を両 bootstrap で実測し、上表のとおりであることを確認済み。

**完全なスニペット**。以下は**nixfmt 正規形**である —— 実際に `flake.nix:2528` の直後へ挿入して
`nixfmt` を掛け、差分ゼロになることを確認済みなので、逐語で書き写せば §8 手順 1 の
`nix fmt -- --ci`(`--fail-on-change` を含意。CI も同じコマンドを走らせる ——
`.github/workflows/check.yml:22`)がそのまま通る。特に `failures` の各 `lib.optional` は
条件を `(\n … \n)` に収める形が正規形であり、短くまとめ直すと nixfmt に戻される:

```nix
          # dev.path is the one forced lazy opt that stops being a constant with #26, so this check
          # has two halves. The first is pure evaluation of makeEnv's new devDirs /
          # unknownDevPluginNames outputs -- neither forces the farm, so it costs nothing and
          # fetches nothing -- in the `failures`-list style of checks.treesitter-grammars. The
          # second runs the *generated bootstrap* through a real lazy.nvim and reads back the
          # directory it resolved each plugin to: the only place the string-vs-function "/<name>"
          # asymmetry of lua/lazy/core/meta.lua:229-231 can actually be caught.
          dev-plugins =
            let
              inherit (pkgs) lib;
              devRoot = ./tests/fixtures/dev-plugins/dev-root;
              # Evaluation half. A lock with a non-empty localPlugins -- one entry with no `dir`
              # and one whose recorded `dir` points somewhere devPath would never produce -- plus
              # one devPlugins name that matches a locked plugin and one that matches nothing.
              locked = nvimxLib.makeEnv {
                package = pkgs.neovim-unwrapped;
                lockDir = ./tests/fixtures/dev-plugins/nvimx-lock;
                devPlugins = [
                  "tokyonight.nvim"
                  "typo.nvim"
                ];
                devPath = "~/proj";
              };
              # The default has to be a genuine no-op: basic-config's localPlugins is empty and
              # nothing is named here, so devDirs must come out empty and bootstrap.lua must keep
              # resolving every plugin under the farm.
              untouched = nvimxLib.makeEnv {
                package = pkgs.neovim-unwrapped;
                lockDir = ./tests/fixtures/basic-config/nvimx-lock;
              };
              # Degraded mode has no lock to judge a name against, so it must never call one a typo.
              degraded = nvimxLib.makeEnv {
                package = pkgs.neovim-unwrapped;
                lockDir = ./tests/fixtures/basic-config/no-such-lock;
                devPlugins = [ "typo.nvim" ];
              };
              # The module's pass-through, read back at evaluation level. checks.hm-module-dev
              # exercises the same options but cannot fail on this: mkHmCheck returns only an
              # activationPackage and asserts nothing about it, so dropping devPlugins or devPath
              # from makeEnv's argument list in nix/home-manager/default.nix leaves it green -- the
              # options still type-check, are silently ignored, and the package still builds.
              # Dropping either one is equally silent: both formals carry defaults
              # (nix/lib/make-env.nix), so a missing argument is never an error -- the absent `...`
              # only rejects arguments makeEnv does not declare, which is the opposite direction.
              # This assertion is the only guard for all three drop combinations. Every other env
              # here calls makeEnv directly and so bypasses the module, which is why this one does
              # not.
              moduleDevDirs =
                (home-manager.lib.homeManagerConfiguration {
                  inherit pkgs;
                  modules = [
                    self.homeModules.nvimx
                    {
                      # The three home.* settings homeManagerConfiguration requires, same values
                      # mkHmCheck uses. Nothing here is built -- only .config is read.
                      home.username = "nvimx-test";
                      home.homeDirectory = "/home/nvimx-test";
                      home.stateVersion = "25.05";
                      programs.nvimx = {
                        enable = true;
                        configDir = ./tests/fixtures/basic-config;
                        lockDir = ./tests/fixtures/basic-config/nvimx-lock;
                        devPlugins = [ "tokyonight.nvim" ];
                        devPath = "~/proj";
                      };
                    }
                  ];
                }).config.programs.nvimx.env.devDirs;
              # Runtime half, deliberately built in degraded mode: the farm is then the lazy.nvim
              # seed alone -- no lock, no fetchTree, fully offline -- while devPlugins / devPath
              # still apply, because they do not depend on the lock at all.
              # dirred.nvim is named here on purpose even though the driver's spec gives it a
              # `dir`: the point is that it gets a dev_dirs entry and lazy still ignores it.
              devEnv = nvimxLib.makeEnv {
                package = pkgs.neovim-unwrapped;
                lockDir = ./tests/fixtures/basic-config/no-such-lock;
                devPlugins = [
                  "tokyonight.nvim"
                  "bare.nvim"
                  "dirred.nvim"
                ];
                devPath = "${devRoot}";
              };
              plainEnv = nvimxLib.makeEnv {
                package = pkgs.neovim-unwrapped;
                lockDir = ./tests/fixtures/basic-config/no-such-lock;
              };
              failures =
                lib.optional (
                  (locked.devDirs."tokyonight.nvim" or null) != "~/proj/tokyonight.nvim"
                ) "a devPlugins name must override a plugin that is in the lock"
                ++ lib.optional (
                  (locked.devDirs."bare.nvim" or null) != "~/proj/bare.nvim"
                ) "a localPlugins key must route to <devPath>/<name>"
                # The fixture records dir = "~/elsewhere/dirred.nvim" for this one precisely so that
                # reading it back would produce a different answer. It is ignored not because it is
                # machine-specific -- a dir the user wrote absolute is kept verbatim -- but because
                # a spec-level dir short-circuits lazy before dev.path is ever consulted
                # (lua/lazy/core/meta.lua:214-217), so reading it could not change any resolved
                # directory. devPath decides, and stays the only thing that does.
                ++ lib.optional (
                  (locked.devDirs."dirred.nvim" or null) != "~/proj/dirred.nvim"
                ) "a localPlugins entry's recorded dir must be ignored: devPath decides"
                # typo.nvim is in this list on purpose. A devPlugins name that matches nothing in
                # the lock still gets a devDirs entry: it is inert (no plugin carries that name, so
                # lazy never looks it up), unknownDevPluginNames is what reports the typo, and
                # filtering it here would tie the dev-dir map to lock validation -- making devDirs
                # mean something different with and without a lock -- for no behavioral gain.
                ++ lib.optional (
                  builtins.attrNames locked.devDirs != [
                    "bare.nvim"
                    "dirred.nvim"
                    "tokyonight.nvim"
                    "typo.nvim"
                  ]
                ) "devDirs must hold exactly the devPlugins names plus the localPlugins keys"
                # The same statement without naming keys, so it keeps holding as the fixture grows:
                # nothing machine-specific out of plugins.json may ever reach a value here.
                ++ lib.optional (
                  !lib.all (lib.hasPrefix "~/proj/") (builtins.attrValues locked.devDirs)
                ) "every devDirs value must sit under devPath, whatever the lock recorded"
                ++ lib.optional (
                  locked.unknownDevPluginNames != [ "typo.nvim" ]
                ) "a devPlugins name in neither the lock nor localPlugins must be reported, and only that one"
                ++ lib.optional (
                  untouched.devDirs != { }
                ) "devDirs must be empty when nothing asked for a dev plugin"
                ++ lib.optional (
                  degraded.unknownDevPluginNames != [ ]
                ) "degraded mode has no lock to judge devPlugins names against, so it must report none"
                ++ lib.optional (
                  moduleDevDirs != { "tokyonight.nvim" = "~/proj/tokyonight.nvim"; }
                ) "the hm module must pass devPlugins / devPath through to makeEnv";
            in
            pkgs.runCommand "dev-plugins"
              {
                nativeBuildInputs = [ pkgs.neovim-unwrapped ];
              }
              (
                if failures == [ ] then
                  ''
                    export HOME=$TMPDIR

                    # The working tree really is a directory in the store, so the dev dir asserted
                    # on below is not merely a string that happens to match.
                    test -f ${devRoot}/tokyonight.nvim/lua/tokyonight-dev.lua

                    # What shipped is the function form, not a string. Guards against a revert to
                    # `path = farm` that would still pass every evaluation-level assertion above.
                    grep -qF 'dev_dirs[plugin.name]' ${plainEnv.bootstrap}

                    # With devPlugins: the named plugins resolve to their working trees (both the
                    # devPlugins one and the spec's own bare `dev = true`), everything else still
                    # to the farm. The driver additionally pins dirred.nvim to the `dir` its spec
                    # writes, proving lazy short-circuits past the dev_dirs entry devEnv gave it.
                    nvim --clean -l ${./tests/dev-path-test.lua} ${devEnv.bootstrap} \
                      ${devEnv.farm} ${devRoot}/tokyonight.nvim ${devEnv.farm}/plenary.nvim \
                      ${devRoot}/bare.nvim

                    # Without: every plugin dev.path decides resolves to <farm>/<name>, byte for
                    # byte what the old `path = farm` string produced. This is #26's "with no dev
                    # plugins, the generated bootstrap.lua is functionally identical to today's".
                    nvim --clean -l ${./tests/dev-path-test.lua} ${plainEnv.bootstrap} \
                      ${plainEnv.farm} ${plainEnv.farm}/tokyonight.nvim ${plainEnv.farm}/plenary.nvim \
                      ${plainEnv.farm}/bare.nvim

                    touch $out
                  ''
                else
                  ''
                    ${lib.concatMapStringsSep "\n" (f: "echo ${lib.escapeShellArg f} >&2") failures}
                    exit 1
                  ''
              );
```

**この check が完全オフラインである根拠**:

- 評価半分は `pluginsDb`(`builtins.fromJSON` + `builtins.readFile`)しか触らない。`getSource` は
  `resolvedDrvs`(`make-env.nix:40-51`)の中でしか呼ばれず、`devDirs` / `unknownDevPluginNames` は
  それを一切参照しない。
- runtime 半分の `devEnv` / `plainEnv` は `lockDir = .../no-such-lock` なので `hasLock = false`。
  farm は `lazyNvimSeed`(nvimx 自身の flake input、既に store にある)1 件だけになる ——
  `checks.hm-module-degrade`(`flake.nix:225-228`)が既に踏んでいる経路である。
- `nvim --clean` + `HOME=$TMPDIR` + 全 spec が `lazy = true` + `install.missing = false` で
  ネットワークもファイル生成も起きない。

**この形が実際に動くことは、計画作成時に実測で確認済み**である(§6.6)。

### 6.4 `checks.hm-module-dev`(新設)

挿入位置: `hm-module-treesitter`(`flake.nix:247-251`)の直後、`wrapper-aliases` のコメント(`:252`)の直前。
`hm-module-treesitter` と同型で、オプションがモジュールの型レイヤ(`listOf str` / `str`)を通ることを守る。

```nix
          # devPlugins / devPath through the module's option types (listOf str / str), which the
          # lib-level dev-plugins check bypasses. Uses the same basic-config lock hm-module already
          # builds, so it adds no fetch of its own.
          hm-module-dev = mkHmCheck {
            configDir = ./tests/fixtures/basic-config;
            lockDir = ./tests/fixtures/basic-config/nvimx-lock;
            devPlugins = [ "tokyonight.nvim" ];
            devPath = "~/projects";
          };
```

`devPlugins` に挙げた名前は lock に実在するので `unknownDevPluginNames` は空になり、
home-manager の warning は出ない。

**この check が守る範囲は「ビルドが通ること」だけである。** `mkHmCheck` は
`.activationPackage` を返すだけで中身を一切 assert しないので、
`inherit (cfg)` から `devPlugins` / `devPath` を落としても素通りする —— **どちらか一方だけでも、
両方でも同じ**である(§3.4: 両 formal とも既定値付きなので渡し忘れはエラーにならない。実測確認済み)。
値が実際に `makeEnv` へ渡っていることは `checks.dev-plugins` の `moduleDevDirs` 行が担当する(§6.3)。
あちらは 3 通りの落とし方すべてを検知する。
同じ理由で、`devPath` にリテラルの `~` を書いていることは
「`types.str` が `~` を通す」ことの**証明にはならない** —— この check は文字列であれば何でも通し、
そもそもオプションを渡さなくても通るからである。`~` を書いているのは
実際の設定例と形を揃えるためであり、`types.path` を選ばなかった理由(§3.4)の記録にすぎない。

### 6.5 `lib.generators.toLua` の実測(pinned nixpkgs)

```
$ nix eval --impure --expr '(builtins.getFlake (toString ./.)).inputs.nixpkgs.lib.generators.toLua { } { }'
"{}"
$ nix eval --impure --expr '(builtins.getFlake (toString ./.)).inputs.nixpkgs.lib.generators.toLua { } { "a.nvim" = "/x/y"; }'
"{\n  [\"a.nvim\"] = \"/x/y\"\n}"
```

- 空 attrset は `{}` —— `local dev_dirs = {}` になり、既定パスの生成物が Lua として自明に正しい。
- 非空はキーを `["..."]` 形式で、値を Lua 文字列としてクォートする。`.` を含むプラグイン名も安全。
- 生成される多行文字列は `local dev_dirs = ` の右に置かれても、2 行目以降が桁 0 から始まるだけで
  Lua としては問題ない(`bootstrap.lua.in` はフォーマッタの対象外なので整形要求も無い)。

### 6.6 計画作成時に行った実測(実装者への根拠)

以下は seed `306a055` + `pkgs.neovim-unwrapped` を使い、`@farm@` / `@devDirs@` を手で埋めた
プロトタイプで確認したものである。**実装後に `checks.dev-plugins` が再現する内容と同じ**。

**(a) 関数形式が正しく解決すること / 既定が今日と同一であること**

| bootstrap | `tokyonight.nvim` | `plenary.nvim` | `lazy.nvim` |
|---|---|---|---|
| `dev_dirs = { ["tokyonight.nvim"] = "<dev-root>/tokyonight.nvim" }` | `<dev-root>/tokyonight.nvim` | `<farm>/plenary.nvim` | `<farm>/lazy.nvim` |
| `dev_dirs = {}` | `<farm>/tokyonight.nvim` | `<farm>/plenary.nvim` | `<farm>/lazy.nvim` |
| 現行 `path = farm`(string) | `<farm>/tokyonight.nvim` | `<farm>/plenary.nvim` | `<farm>/lazy.nvim` |

→ 2 行目と 3 行目が一致する。**G2 が成立する**。すべて exit 0、`nvim --clean -l` で完走。

**(b) `dev = true` / 明示 `dir` の spec に対する挙動**

spec: `{ "folke/tokyonight.nvim" }`, `{ "o/bare.nvim", dev = true }`, `{ "o/dirred.nvim", dir = "~/elsewhere/dirred.nvim" }`

| bootstrap | `bare.nvim` の `dir` | `dirred.nvim` の `dir` |
|---|---|---|
| `dev_dirs = { ["bare.nvim"] = "~/projects/bare.nvim", ["dirred.nvim"] = "~/elsewhere/dirred.nvim" }` | `$HOME/projects/bare.nvim`(**`~` が実行時に展開された**) | `$HOME/elsewhere/dirred.nvim` |
| 現行 `path = farm`(string) | `<farm>/bare.nvim`(**存在しない = 今日壊れている**) | `$HOME/elsewhere/dirred.nvim` |

→ §1.3(1) の破綻と、その修正、および `~` 展開が Nix ではなく `Util.norm` によって実行時に行われることが確認できた。

**この表は当初案(`localPlugins[*].dir` を `dev_dirs` に入れる)のまま実行した記録である。**
訂正後の設計では `dev_dirs` の `dirred.nvim` は `<devPath>/dirred.nvim` になるが、
**runtime の結果は 1 文字も変わらない** —— 上の表の 1 行目と 2 行目で `dirred.nvim` の値が一致していること
(`dev_dirs` に何を入れても `$HOME/elsewhere/dirred.nvim`)がその証拠であり、
spec に `dir` を書いたプラグインでは `meta.lua:214-216` の短絡が先に効いて `dev.path` が呼ばれもしないからである。
これが §3.3 の「`dir` を読む必要がそもそも無い」という主張の実測による裏付けになっている。

**(c) 実 extract を通したときの `localPlugins` の中身** —— §3.3 / §7 R1 / R2 の根拠。
4 通りの spec(`{ "o/bare.nvim", dev = true }` / `{ "o/both.nvim", dev = true, dir = "/abs/both" }` /
`{ "o/tilde.nvim", dev = true, dir = "~/mine/tilde.nvim" }` / `{ "o/dirred.nvim", dir = "~/elsewhere/dirred.nvim" }`)を
`lua/nvimx/extract.lua` に通した raw-spec の該当部分:

```json
"bare.nvim":  { "dev": true, "dir": "<HOME>/projects/bare.nvim",  "name": "bare.nvim",  ... },
"both.nvim":  { "dev": true, "dir": "/abs/both",                  "name": "both.nvim",  ... },
"tilde.nvim": { "dev": true, "dir": "<HOME>/mine/tilde.nvim",     "name": "tilde.nvim", ... }
```

(`dirred.nvim` はこの一覧に**現れない** —— `dev` も `dir` も持たないエントリとして dump される。)

| spec | 記録された `dir` | マシン依存か | 由来 |
|---|---|---|---|
| `dev = true` のみ | `<HOME>/projects/bare.nvim` | **する** | lazy が `dev.path`(既定 `~/projects`、`config.lua:287-288` で norm 済み)から導出 |
| `dev = true` + `dir = "/abs/both"` | `/abs/both` | **しない** | `meta.lua:214-217` が短絡し、ユーザの値が**逐語で**通る |
| `dev = true` + `dir = "~/mine/tilde.nvim"` | `<HOME>/mine/tilde.nvim` | **する** | 同じく短絡するが、`meta.lua:217` の `Util.norm` が `~` を展開する |
| `dir` のみ(`dev` 無し) | 記録されない | —— | `extract.lua:114` の `dir = p.dev and p.dir or nil` で落ちる |

- したがって **「記録値は常にマシン依存」は誤り**である。3 通りのうち 2 通りではそうなるが、
  ユーザが絶対パスの `dir` を書いた場合は逐語の、マシンに依存しない値が入る。
  §3.3 が `dir` を読まない決め手を「マシン依存性」ではなく「短絡により読んでも結果が変わらないこと」に
  置いているのはこのためである。
- `dirred.nvim`(`dev` 無しの `dir`)は `resolve.lua:617` の条件を満たさず、
  **リモートプラグインとして lock に載る**(§7 R2 の既存欠落)。

### 6.7 既存 checks への影響

| check | 影響 |
|---|---|
| `hm-module`(`:216`)/ `hm-module-degrade`(`:225`)/ `hm-module-plugins`(`:233`)/ `hm-module-treesitter`(`:247`) | `bootstrap.lua` の中身が変わる(dev ブロックが関数になる)ので activation package のハッシュは変わるが、内容は機能的に同一。ビルドは通る |
| `wrapper-aliases`(`:253`)/ `build-shell`(`:269`)/ `plugin-drv-phases`(`:283`)/ `build-registry`(`:694`)/ `plugins-*` / `treesitter-grammars`(`:941`) | `makeEnv` の formals が増えるだけ(既定値付き)。呼び出し側は無変更で通る |
| `extractor-*` / `semver-select` / `resolve-*` / `update-summary` | lua の lock 生成系は 1 行も変えないので**完全に無影響**。特に `resolve-import-lazy-lock`(`:2200`)は `localPlugins` の生成側を検査しており、本件はその消費側だけを足す |
| `packages.demo`(`flake.nix:93`) | `env.wrapped` を使うので bootstrap が変わる。`devPlugins` 未指定なので挙動は不変 |

### 6.8 CI / darwin

- CI は `.github/workflows/check.yml` が `nix flake check` を回すので、**ワークフローの編集は不要**。
- CLAUDE.md の規約どおり、ローカル(linux)の `nix flake check` は darwin を omit する。
  新 check 2 件について評価だけを別途確認する:
  ```bash
  nix eval .#checks.aarch64-darwin.dev-plugins.drvPath
  nix eval .#checks.aarch64-darwin.hm-module-dev.drvPath
  ```
  `dev-plugins` は `failures` が非空だと `runCommand` の本文が差し替わるだけで **`drvPath` は常に評価できる**
  点に注意。評価の確認は「darwin で eval が壊れていない」ことの確認であって、assert の確認ではない
  (assert は linux の `nix flake check` で見る)。

### 6.9 手動確認(実 dotfiles の switch が要るので check にできない)

1. 適当なプラグイン 1 個について `devPlugins = [ "<name>" ]` / `devPath = "~/projects"` を設定し、
   `~/projects/<name>` にそのプラグインを clone して `home-manager switch`。
2. `:Lazy` —— 当該プラグインだけが作業ツリーのパスを、他は `/nix/store/...` を表示し、
   どちらについても git タスクが 1 つも走っていないこと。
3. 作業ツリーのファイルを編集 → Neovim を再起動 → 変更が反映されていること。
4. `~/projects/<name>` を一時的にリネームして switch し直し、**store のコピーに落ちない**こと
   (`:Lazy` でそのプラグインが not installed と表示される)。fallback 無しの確認。
5. `devPlugins` から名前を外して switch —— `nvimx-lock` を再実行せずに store のパスへ戻ること。
   `git status` が lockDir に差分を出さないこと(G5)。
6. lock に無い名前(例 `typo.nvim`)を `devPlugins` に入れて switch —— activation 時に
   `programs.nvimx: devPlugins names plugins that are in neither the lock nor its localPlugins`
   という warning が出て、それでも switch は成功すること(G4)。

## 7. リスク / 未決事項

### R1(**上の設計で解消済み**。残るのは lock ファイル側の申し送り): `localPlugins[*].dir` が何であれ読まない

**事実**(§6.6(c) で 4 通りの spec を実測):`dev = true` のプラグインは lazy が正規化する時点で
必ず `plugin.dir` を持ち(`meta.lua:229-238`)、`extract.lua:114` がそれを dump する。
値の由来は spec の書き方で分かれる:

- `dir` を書かなければ lazy が `dev.path` から導出する。extract 中は `safe_opts`(`extract.lua:43-50`)に
  `dev` キーが無いのでユーザの `dev.path`(既定 `~/projects`)が生きており、`config.lua:287-288` で
  `~` は展開済み → **lock を走らせたマシンの `$HOME` を含む絶対パス**。
- `dir = "~/x"` を書いた場合も `meta.lua:217` の `Util.norm` が展開する → **同じくマシン依存**。
- `dir = "/abs/x"` を書いた場合だけ**逐語で通る** → マシンに依存しない、ユーザが書いたとおりの値。

当初の設計は「記録値は常に spec 由来」と誤認して「spec 由来の `dir` が `devPath` に勝つ」という規則を置いていた。
3 通りのうち 2 通りでその前提が崩れるので**規則は撤回済み**である(§3.3)。

**ただし撤回の決め手はマシン依存性ではない。** 仮に全ケースが逐語だったとしても規則は無意味だった ——
spec に `dir` を書いたプラグインでは `meta.lua:214-217` が短絡して `dev.path` を呼ばないので、
`devDirs` にその `dir` を載せても**行き先は 1 文字も変わらない**からである(§6.6(b) で実測)。
つまり「`dir` を読むコード」は定義上 1 度も観測可能な効果を持たない。

規則を撤回していなければ出ていた実害:

1. `devPath` が `localPlugins` エントリに対して一度も適用されない(`or` 分岐が実 lock からは死んだ枝になる)。
2. `devPlugins = [ "foo.nvim" ]` + `devPath = "~/src"` と明示しても、`foo.nvim` が `localPlugins` にいる限り
   記録済みの値が黙って勝つ。
3. 上記 3 通りのうち 2 通りでは、他人の `$HOME` を含むパスがコミットされた lock 経由で
   別マシンの `bootstrap.lua` に焼き込まれる。

**現在の設計ではいずれも起きない。** `devDirs` は `localPlugins` のキーしか読まず、値は必ず
`<devPath>/<name>` になる。`checks.dev-plugins` の `dirred.nvim` 行と
「全 value が `devPath` 始まり」の行が、この決定を機械的に固定する(§6.3)。

**残る申し送り(本件のスコープ外)**: それでも `plugins.json` には依然として
`localPlugins[*].dir` が**記録され続ける**。もはや誰も読まないので lock ファイルに残った死んだ重みであり、
しかも上記 2 通りのケースでは他人の `$HOME` を git にコミットさせ続ける。
本来は `resolve.lua` / `extract.lua` 側で直すべきである:

- **(i)** `resolve.lua:618` の `local_plugins[name] = { dir = p.dir }` を `= { }` にする(最小)。
  ただし `dir` を診断情報として残したいなら、
- **(ii)** `extract.lua` が「spec に明示された `dir`」と「`dev.path` から導出された `dir`」を区別して dump し、
  後者は記録しない(前者はユーザが書いた情報なので残す価値がある)。raw-spec は lazy の正規化後の値しか
  持たないので、`Plugin.Spec` の fragment 側(`rawget(fragment.spec, "dir")`)を見る必要がある。
  #43 §3.4 と同種の「lazy の内部表現に踏み込む」変更。

どちらも `plugins.json` の内容が変わるため、golden / fixture の再生成を伴う。
**別 issue を 1 本立て、#26 の PR 本文からリンクする**(本件では実施しない)。
フィクスチャの `_comment` にもこの事実を書き残す(§6.1)。

### R2: `dev` の無い明示 `dir` は `localPlugins` に到達しない(既存の欠落)

`extract.lua:114` の `dir = p.dev and p.dir or nil` により、`{ "o/x.nvim", dir = "..." }`(`dev` 無し)は
raw-spec に `dir` を残さない。結果 `resolve.lua:617` の `if p.dev or p.dir` を満たさず、
**リモートプラグインとして lock に載り、input が作られ、farm に置かれる**。§6.6(c) で実測確認済み。
これは `extract.lua:61-65` に既に記録された既存の欠落であり、本件では**悪化も改善もしない**。

**この欠落は `dev` を伴わない `dir` にだけ効く。** `dev = true` と `dir` を両方書けば
`localPlugins` に `dir` 付きで載る(§6.6(c) の `both.nvim` / `tilde.nvim`)ので、
**`dir` を持つ `localPlugins` エントリ自体は実 lock も普通に生む**。
`tests/fixtures/dev-plugins/nvimx-lock/plugins.json` の `dirred.nvim` が手書きなのは
その*形*ではなく、値にリテラルの `~` を使っている点だけである(実 lock なら
`meta.lua:217` の `Util.norm` で展開済みの絶対パスになる)。`devPath` と目視で区別しやすいので
そのままにしてある。フィクスチャの `_comment` にこの区別を明記する。

### R3: string 形式と function 形式の `"/" .. name` の非対称性

本件で最も起こりやすいバグ(§1.2)。関数が `.. "/" .. plugin.name` を忘れると
`dev_dirs` に載っていないプラグインが全て farm 直下に潰れる。ドライバの 5 本の assert のうち、
どれが捕まえるかは実行ごとに違う:

| 実行 | 落ちる assert | 理由 |
|---|---|---|
| `plainEnv`(`dev_dirs = {}`) | `tokyonight.nvim` / `plenary.nvim` / `bare.nvim` の **3 本** | 全プラグインが fallback 経路を通るので全滅する。**このバグの主たる検知者** |
| `devEnv`(`dev_dirs` 3 件) | `plenary.nvim` の **1 本**のみ | `tokyonight.nvim` と `bare.nvim` は `dev_dirs` に当たるので fallback 経路を通らず、正しい値のまま通る |

**`dirred.nvim` と `lazy.nvim` の assert はこのバグを検知しない。** 前者は spec の `dir` で短絡し
(`meta.lua:214-217`)、後者は `lazy.dir` が `Config.me` で上書きされる(§4.2)ため、
どちらも `dev.path` を経由しないからである。この 2 本はそれぞれ別の契約を守っている(§7 R10)。

関連して、`config.lua:287-288` の「setup 時に 1 回だけ `Util.norm`」が function 形式では走らなくなり、
代わりに `meta.lua:231` が戻り値ごとに norm するようになる。store path に対しては norm は恒等なので
現行挙動と等価であることを §6.6(a) の 2 行目 / 3 行目の一致で確認済み。

### R4: `vim.tbl_deep_extend` による `dev` のマージ

ユーザ自身の `dev.path` / `dev.fallback` はスカラなので `forced` が上書きする(今日と同じ)。
`dev.patterns` も **`forced` の `{ "" }` で丸ごと置き換わる**: `vim.tbl_deep_extend` が再帰するのは
「table であり、かつ非空のリストでない」値だけなので、リスト同士はインデックス単位でマージされず右辺が勝つ。
ユーザの `{ "folke", "x" }` は `{ "", "x" }` **ではなく** `{ "" }` になる(実測確認済み)。
これも今日と同じであり、**本件はマージの形を変えないので新たな露出は無い**。
したがって「ユーザの `dev.patterns` の残骸が url に部分一致して意図しないプラグインが dev 扱いになる」
という懸念は原理的に生じない —— そもそも残骸が残らないし、仮に残っても
`patterns = { "" }` が既に全プラグインを dev 扱いにしているため観測できない。コード変更は不要。

### R5: `nvim -l` の中で `lazy.setup` を呼ぶこと

計画作成時に**実際に走らせて確認済み**(§6.6)。`install.missing = false` /
`checker` / `change_detection` / `pkg` / `rocks` / `readme` がすべて無効化されているうえ、
テスト spec の全エントリが `lazy = true` なので、プラグインは 1 つも source されない。
それでも将来 flaky になった場合の退避策は
`require("lazy.core.config").options.dev.path({ name = "..." })` を直接呼んで戻り値を assert する形
(契約は同じで、プラグインのロードが一切起きない)。**まずは実 spec を通す現形を採る** ——
`meta.lua:229-231` の分岐そのものを踏むのはこちらだけだからである。

### R6: 作業ツリーが存在しないときに何も言わない

`fallback = false` を維持するので、dev ディレクトリが無ければ lazy が「not installed」と表示するだけで、
nvimx 側からは何も警告できない(Nix の評価時に `builtins.pathExists` で見ることはできるが、
それは `~` を含む str に対しては使えないし、`--impure` 相当の外界依存を評価に持ち込むことになる)。
README でこの挙動を明記する(§5.8(c))。**意図した設計**。

### R7: `devPath` が `types.str` なので型検査が効かない

`~/projcts`(タイポ)を書いても home-manager は何も言わない。`devPlugins` の名前は
`unknownDevPluginNames` で守られるが、**パスは守られない**。R6 と同じ理由でこれ以上はできない。

### R8: 古い `plugins.json` に `localPlugins` キーが無い場合

`pluginsDb.localPlugins or { }` で吸収する。`schemaVersion` は 1 のまま
(読む側が増えるだけで書式は変わらないので bump 不要)。

### R9: `devDirs` 変更時の再ビルド範囲

`bootstrap.lua` と wrapper だけが作り直される。farm もプラグイン derivation も再利用されるので
再 fetch は起きない。`devPath` を変えただけでも wrapper のハッシュは変わる(避けられないし、安い)。

### R10: seed 更新時の追随

本件が依拠する lazy.nvim の実装詳細は 2 つあり、**どちらも `checks.dev-plugins` の runtime 半分が
固定している**。`extractor-snapshot` が extract について果たすのと同じ「lazy の挙動変化を検知する」役割である。

| 依拠する挙動 | 場所 | 落ちる assert |
|---|---|---|
| string 形式にだけ `/<name>` が後置され、function 形式には後置されない | `meta.lua:229-231` | `tokyonight.nvim` / `plenary.nvim` / `bare.nvim`(特に `plainEnv` 側。全プラグインが farm 直下に潰れる) |
| spec に `dir` があると dev 分岐の前に短絡する | `meta.lua:214-217` | `dirred.nvim`(`/nvimx-test/dirred` ではなく `<devPath>/dirred.nvim` になる) |

2 行目が特に重要である。この短絡は §3.3 が `localPlugins[*].dir` を読まないと決めた**決め手**そのものなので、
seed 更新で短絡が消えれば設計の根拠が崩れる。`dirred.nvim` の assert が無ければ、
その崩壊は `nix flake check` がグリーンのまま起きる —— 評価半分の `dirred.nvim` 行は
Nix 側の決定を固定するだけで、lazy の挙動については何も言わないからである。

## 8. 検証手順(実装完了時に必ず全部通す)

**計画レビューで一部が実行済みであっても、実装後に全手順を改めて通すこと。**
本計画は複数回のレビューを経て §5 / §6 のコード片を編集しており、
「以前のレビュー回で通った」ことは最新の本文が通ることを意味しない。特に手順 2 / 3 / 4
(`nix build` の新 check 2 件、`nix flake check`、darwin の `nix eval`)は、
実装ツリーの上で**実際に走らせた結果**をもって完了とする。

```bash
# 0. 新規ファイルは git add してあること(nix は git 管理下のファイルしか見ない)
git add tests/fixtures/dev-plugins tests/dev-path-test.lua
git status --short

# 1. 整形 + lint (treefmt: nixfmt / stylua / luacheck)
#    bootstrap.lua.in は *.lua ではないので対象外。tests/dev-path-test.lua と
#    tests/fixtures/dev-plugins/dev-root/.../tokyonight-dev.lua は対象。
nix fmt -- --ci

# 2. 新 check だけを先に回す(速いループ用)
nix build .#checks.x86_64-linux.dev-plugins -L
nix build .#checks.x86_64-linux.hm-module-dev -L

# 3. フルチェック(linux)
nix flake check

# 4. darwin 評価。ローカル linux の flake check は darwin を omit する(CLAUDE.md)
nix eval .#checks.aarch64-darwin.dev-plugins.drvPath
nix eval .#checks.aarch64-darwin.hm-module-dev.drvPath

# 5. G2(既定が今日と機能的に同一)を目視でも確認する。
#    devPlugins 未指定で生成した bootstrap.lua が関数形式で、dev_dirs が空テーブルであること。
#    degraded な lockDir を使うのはネットワークを踏まないため(dev_dirs は lock と無関係)。
#    コマンドの形は計画作成時に実行して確認してあるが、出力の確認は実装後に改めて行うこと。
boot=$(nix build --impure --no-link --print-out-paths --expr '
  let
    f = builtins.getFlake (toString ./.);
    system = builtins.currentSystem;
    pkgs = import f.inputs.nixpkgs { inherit system; };
  in
  (f.lib.${system}.makeEnv {
    package = pkgs.neovim-unwrapped;
    lockDir = ./tests/fixtures/basic-config/no-such-lock;
  }).bootstrap')
# §5.1 の dev ブロックのコメント自体が `dev_dirs` と `path = farm` の両方を含む文字列であることに
# 注意。素朴に grep すると「退行が残っている」ように見えるが、それはコメントである。
grep -c 'dev_dirs' "$boot"          # 3(宣言 / コメント / 関数本体)
# 実際の退行ガードは行頭アンカー付きで見る。今日の string 形式 (`      path = farm,`) だけに一致し、
# コメント行には一致しない。POSIX 文字クラスを使うのは darwin の grep でも同じ意味になるようにするため。
! grep -q '^[[:space:]]*path = farm,' "$boot"   # string 形式が残っていないこと
grep -q 'path = function(plugin)' "$boot"       # 関数形式が出荷されていること

# 5b. G3'(devDirs の全 value が devPath 配下 / lock 由来のマシン依存値が漏れない)。
#     localPlugins が非空の fixture を使い、生成された bootstrap.lua の dev_dirs が
#     すべて devPath 配下であること = 記録された dir が 1 つも入っていないこと。
#     この lockDir は tokyonight.nvim を fetch するが、rev は basic-config と同一なので
#     手順 3 の時点で既にキャッシュ済みである(新規の fetch にはならない)。
boot2=$(nix build --impure --no-link --print-out-paths --expr '
  let
    f = builtins.getFlake (toString ./.);
    system = builtins.currentSystem;
    pkgs = import f.inputs.nixpkgs { inherit system; };
  in
  (f.lib.${system}.makeEnv {
    package = pkgs.neovim-unwrapped;
    lockDir = ./tests/fixtures/dev-plugins/nvimx-lock;
    devPath = "~/proj";
  }).bootstrap')
grep -n 'dev_dirs' -A 5 "$boot2"    # localPlugins の 2 キー(bare.nvim / dirred.nvim)だけが載り、
                                    # どちらも "~/proj/<name>" であること(devPlugins は渡していない)
! grep -q 'elsewhere' "$boot2"      # fixture の記録済み dir が漏れていないこと

# 6. G5(lock 生成の出力が 1 バイトも変わらない)。lua 側は無変更なので構造上自明だが、
#    既存 check がその保証を担っていることを確認する。
nix build .#checks.x86_64-linux.extractor-snapshot \
          .#checks.x86_64-linux.resolve-merge \
          .#checks.x86_64-linux.resolve-import-lazy-lock -L
#    bootstrap.lua.in は §5.1 で意図的に書き換えるので pathspec から除外する。
#    resolve.lua / extract.lua / genflake.lua を個別に列挙するのではなく除外にするのは、
#    「他の lua ファイルが 1 つも変わっていない」という G5 の主張をそのまま保つため
#    (将来 lua/nvimx/ にファイルが増えてもこの行が守り続ける)。
git diff --stat -- lua/ ':!lua/nvimx/bootstrap.lua.in' \
  tests/fixtures/basic-config tests/fixtures/merge          # 空であること

# 7. 既存の hm 系がすべて通ること(bootstrap.lua が変わるので全部作り直される)
nix build .#checks.x86_64-linux.hm-module \
          .#checks.x86_64-linux.hm-module-degrade \
          .#checks.x86_64-linux.hm-module-plugins \
          .#checks.x86_64-linux.hm-module-treesitter -L

# 8. ドキュメントのアンカーが生きていること
grep -n '^### Local plugin development' README.md     # 見出しが 1 件だけ存在する
grep -c '(#local-plugin-development)' README.md       # 参照が 2 件(Options の devPlugins 行 / How it works)
grep -n 'devPlugins\|devPath' README.md docs/architecture.md
```

手動確認は §6.9。実 dotfiles の `home-manager switch` が必要なので `checks` にはできない。
