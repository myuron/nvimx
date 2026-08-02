# #27 対応計画: `extraLuaPackages` による Lua rock サポート

対象 issue: [#27 feat(hm): add extraLuaPackages option](https://github.com/myuron/nvimx/issues/27)

Phase 7 の 2 番目。前提となる #26(`devPlugins` / `devPath`)は **main にマージ済み**(`cb96768` 時点)。
本計画の `file:line` は**現在の作業ツリー(`cb96768`)基準で全件を実ファイルで再検証済み**である
(**他の計画から引き写した番号も含めて**。3 回目のレビューで `resolve.lua:371-378` が
#36 から継承した古い番号のまま残っていたのを是正した。他計画からの**引用文の中**の番号だけは
原文のまま残し、その場で訂正を添えてある —— §3.6)。
**他ファイルからのコード引用は、逐語でないものに必ず `# ...` などの省略マーカーか但し書きを付けてある**
(§1.3(a)(b)(c)、§1.4、§3.6)。マーカーの無い引用は逐語である(§1.1 の `wrapper.nix` 全文、
§3.6 の `resolve.lua:533-536`、§4.4 の before、§4.7 の各 before)。
nixpkgs / home-manager 側の行番号は、`flake.lock` が固定している input の実ファイルからの引用である
(nixpkgs → `/nix/store/5ljrgyqskjl8g5kxm88a8gl8251m801x-source`、
home-manager → `/nix/store/fm93mv69y0ify036r6zgnhqy1chw3vd0-source`)。

**§1.4 の実測は本計画の中核である。** 「`--prefix LUA_PATH` に `;;` を混ぜれば Lua の既定パスが残る」という
素朴な想定は **makeWrapper の実装によって成立しない**ことが実測で判明しており、そこを外すと
「rock は読めるが既定の `package.path` が消える」という静かな退行になる。実装者は §1.4 と §3.3 を
必ず読むこと。

## 1. 背景 / 現状

### 1.1 現在の wrapper(`nix/lib/wrapper.nix`、全 24 行)

```nix
1  # wrapProgram the user-selected neovim (an unwrapped style package) and inject bootstrap.lua
2  { pkgs }:
3  {
4    package,
5    bootstrap,
6    extraPackages ? [ ],
7    vimAlias ? false,
8    viAlias ? false,
9  }:
10 let
11   inherit (pkgs) lib;
12 in
13 pkgs.symlinkJoin {
14   name = "nvimx-neovim";
15   paths = [ package ];
16   nativeBuildInputs = [ pkgs.makeWrapper ];
17   postBuild = ''
18     wrapProgram $out/bin/nvim \
19       --add-flags "--cmd 'luafile ${bootstrap}'" \
20       ${lib.optionalString (extraPackages != [ ]) "--prefix PATH : ${lib.makeBinPath extraPackages}"}
21     ${lib.optionalString vimAlias "ln -s $out/bin/nvim $out/bin/vim"}
22     ${lib.optionalString viAlias "ln -s $out/bin/nvim $out/bin/vi"}
23   '';
24 }
```

環境変数に触っているのは `:20` の `--prefix PATH` だけである。`LUA_PATH` / `LUA_CPATH` は
**リポジトリ全体で 1 箇所も出てこない**(`grep -rn 'LUA_PATH\|LUA_CPATH' .` が空)。

`make-env.nix:132-140` が `mkWrapper` を呼ぶ:

```nix
132  wrapped = mkWrapper {
133    inherit
134      package
135      bootstrap
136      extraPackages
137      vimAlias
138      viAlias
139      ;
140  };
```

`make-env.nix` の formals は `:6-21`(`extraPackages ? [ ],` が `:9`、`devPath ? "~/projects",` が `:20`、
閉じ `}:` が `:21`)。`...` は無い。

### 1.2 rocks を無効化している箇所と、ドキュメントが既に公表している逃げ道

- `lua/nvimx/bootstrap.lua.in:22` —— `rocks = { enabled = false, hererocks = false },`。
  forced opts なので**ユーザは runtime で覆せない**。
- `nix/lib/plugin-drv.nix:11` / `:45` —— `build.kind == "rockspec"` は分類だけされて**実行されない**。
- `docs/architecture.md:508`(edge-case 表):

  > | luarocks (rocks) | **explicitly unsupported**. `rocks.enabled=false` is forced during extraction, so a `build = "rockspec"` ... is recorded as `{ kind: "rockspec" }` and never run; warned about at lock time like any other unrunnable build |

- `docs/architecture.md:400`(hm モジュールの例):

  ```nix
    extraLuaPackages = ps: [ ];      # manual luarocks dependencies (escape hatch)
  ```

- `docs/architecture.md:525` —— `7. **Finishing touches**: devPlugins (#26), extraLuaPackages, ...`

つまり **architecture.md は既に `extraLuaPackages` を「ある体」で書いているが、実装は 1 行も無い**
(`grep -rn extraLuaPackages nix/ README.md` が空)。#26 とまったく同じ構図であり、本件でその差を埋める。

README には `extraLuaPackages` の記述は**まだ 1 行も無い**(`## Options` 表は `:186-205`)。

### 1.3 nixpkgs / home-manager 側の前例(pinned input で実読)

**(a) home-manager のオプション型** —— `modules/programs/neovim/default.nix:184-188`
(`mkOption` は `:195` まで続くが、以降は `description` なので省略):

```nix
      extraLuaPackages = mkOption {
        type = types.functionTo (types.listOf types.package);
        default = _: [ ];
        defaultText = literalExpression "ps: [ ]";
        example = literalExpression "luaPkgs: with luaPkgs; [ luautf8 ]";
```

**この pin では「関数のリスト」形式は採っていない。単一の関数 `ps: [ ... ]` だけである。**
`:524` で `wrapNeovimUnstable` にそのまま `inherit (cfg) extraLuaPackages` している。

**「新しめの home-manager ならリストも取れるのでは」という懸念は不要である。**
`types.functionTo` は複数定義のマージを elemType 側に委譲するので、`functionTo (listOf package)` は
**素の型のままモジュール横断で合成される**。pinned nixpkgs で実測:

```
lib.evalModules で f を functionTo (listOf str) と宣言し、2 つのモジュールが
  { f = ps: [ ps.a ]; } と { f = ps: [ ps.b ]; } を与える
→ config.f { a = "A"; b = "B"; } == [ "B" "A" ]
```

つまり `types.listOf (types.functionTo ...)` に**する必要は無い**し、するべきでもない
(home-manager と型が食い違い、`ps: [ ... ]` という見慣れた書き味も壊れる)。**単一関数で確定**。

**(b) 適用先の Lua パッケージセット** —— `pkgs/applications/editors/neovim/wrapper.nix:111-120`
(空行と `getLuaPath` についての 2 行コメント(`:117-118`)を `# ...` で省略):

```nix
        luaDeps = extraLuaPackages lua.pkgs ++ vimPackageInfo.luaDependencies;
        luaPathLuaRc =
          let
            luaEnv = lua.withPackages (_: luaDeps);
            # ...
            generatedLuaPath = lua.pkgs.getLuaPath luaEnv;
            generatedLuaCPath = lua.pkgs.getLuaCPath luaEnv;
```

`lua` は `neovim-unwrapped.lua`(passthru)である。**固定の `pkgs.lua51Packages` ではない。**

**(c) パス文字列の生成** —— `pkgs/development/lua-modules/lib.nix:36-42` と `:48-50`
(あいだの `:43-47` は本件に無関係な `luaPathRelStr` / `luaCPathRelStr` なので `# ...` で省略):

```nix
  luaPathList = [
    "share/lua/${lua.luaversion}/?.lua"
    "share/lua/${lua.luaversion}/?/init.lua"
  ];
  luaCPathList = [
    "lib/lua/${lua.luaversion}/?.so"
  ];
  # ...
  # generate LUA_(C)PATH value for a specific derivation, i.e., with absolute paths
  genLuaPathAbsStr = drv: lib.concatMapStringsSep ";" (x: "${drv}/${x}") luaPathList;
  genLuaCPathAbsStr = drv: lib.concatMapStringsSep ";" (x: "${drv}/${x}") luaCPathList;
```

`luaversion` は文字列連結の中で解決されるので、**`?.lua` / `?/init.lua` / `?.so` の並びも
`share/lua/5.1` / `lib/lua/5.1` というレイアウトも自前で書いてはならない**。`luaLib` を使う。
拡張子が darwin でも `.so` である(`.dylib` ではない)ことも `luaLib` 側の事実であり、
`stdenv.hostPlatform.extensions.sharedLibrary` を持ち出す必要は無い —— pinned nixpkgs の
`aarch64-darwin` で `luaCPathList == [ "lib/lua/5.1/?.so" ]` を実測済み(§5.6)。

**(d) 環境変数か `package.path` か** —— nixpkgs には 2 つの実装が同居している:

| 実装 | やり方 | 状態 |
|---|---|---|
| `neovim/wrapper.nix:113-125` | 生成した init lua で `package.path = "<生成>" .. ";" .. package.path` | **現行**。home-manager の `programs.neovim` はこちらを通る |
| `neovim/utils.nix:157-166`(`makeNeovimConfig`) | `--prefix LUA_PATH ";" <生成>` / 同 `LUA_CPATH` | **deprecated**(`:146` で `lib.warn`) |

issue #27 は明示的に「Wire the resulting packages into `LUA_PATH` / `LUA_CPATH` in the wrapper
(`nix/lib/wrapper.nix`)」と指示しており、Files にも `wrapper.nix` が挙がっている。本計画は
**環境変数方式を採る**(§3.4 で `package.path` 方式を却下する理由を書く)。ただし現行 nixpkgs が
`package.path` 方式で**既定パスを保存している**という事実は無視できないので、§3.3 で
「既定パスを失わない環境変数方式」を作る。

### 1.4 実測: `LUA_PATH` と makeWrapper の挙動(本件で唯一絶対に間違えてはならない点)

すべて pinned nixpkgs / `neovim-unwrapped 0.12.4`(LuaJIT 2.1、`luaversion = "5.1"`)で
ローカル実行した結果である。

**(1) neovim は `package.path` に手を入れない。素の LuaJIT 既定値である。**
(出力は実際には 1 行。読みやすさのために折り返し、LuaJIT の store path を `<luajit>` に置換してある。
以下 §1.4 の実測はすべて同じ表記規則である。)

```
$ env -u LUA_PATH -u LUA_CPATH nvim --clean --headless -c 'lua print(package.path)' +qa
./?.lua;<luajit>/share/luajit-2.1/?.lua;/usr/local/share/lua/5.1/?.lua;
/usr/local/share/lua/5.1/?/init.lua;<luajit>/share/lua/5.1/?.lua;<luajit>/share/lua/5.1/?/init.lua
```

neovim 自身の Lua ランタイム(`vim.*`)も rtp 上のプラグインも、`package.path` ではなく
neovim が `package.loaders` に差し込む独自 searcher で解決される。したがって既定パスが失われても
neovim は起動するが、**`require("jit.dump")` などの LuaJIT 付属モジュールは読めなくなる**
(`<luajit>/share/luajit-2.1/?.lua` がそこにしか無い)。

**(2) `LUA_PATH` を設定すると既定値は「置き換わる」。追記ではない。** `;;` を書いた場所にだけ
既定値が展開される(Lua の仕様)。実測:

| `LUA_PATH` | 結果 |
|---|---|
| `/A/?.lua;/B/?.lua` | `/A/?.lua;/B/?.lua` のみ。**既定値は消える** |
| `/A/?.lua;/B/?.lua;;` | `/A/?.lua;/B/?.lua;<既定値>` |
| `/A/?.lua;;;/USER/?.lua` | `/A/?.lua;<既定値>;;/USER/?.lua`(空要素が 1 個残るだけで無害) |

`LUA_CPATH` も同じ規則である。

**(3) ★ makeWrapper の `--prefix` は渡した値をセパレータで分割し、空要素を捨てる。**
したがって **`--prefix LUA_PATH ';' "<paths>;;"` と書いても `;;` は消滅する**。
実測(生成された wrapper スクリプトから、末尾の `;;` に対応するブロックだけを抜粋。
`# ←` は**この計画書が付けた注記**であり、生成物には無い):

```sh
LUA_PATH=${LUA_PATH:+';'$LUA_PATH';'}
LUA_PATH=${LUA_PATH/';'''';'/';'}     # ← 空要素として処理され
LUA_PATH=''$LUA_PATH                  # ← 何も足さない
LUA_PATH=${LUA_PATH#';'}
LUA_PATH=${LUA_PATH%';'}
```

**これが本件最大の罠である。** 素直に書くと、rock を 1 つ足しただけで LuaJIT の既定 `package.path` が
まるごと消える。

**(4) 解決策として `--set-default VAR ';;'` を `--prefix` の前に置くと成立する。**
`--set-default` は値を分割せず `export VAR=${VAR-';;'}` を出すだけであり、その後の `--prefix` ブロックが
その `;;` の**前に**自分のパスを挿す。実測(`--set-default LUA_PATH ';;' --set-default LUA_CPATH ';;'`
+ `--prefix LUA_PATH ';' <2 entries>` + `--prefix LUA_CPATH ';' <1 entry>`):

| 起動時の環境 | 結果の `package.path` |
|---|---|
| `LUA_PATH` 未設定 | `<rock env>/share/lua/5.1/?.lua;<同>/?/init.lua;<LuaJIT 既定値>;;` —— **rock が先、既定値も健在**。`require("jit.dump")` も通る |
| `LUA_PATH=/USER/?.lua;;` | `<rock 2 件>;/USER/?.lua;<既定値>` —— **ユーザの値も、その `;;` の意味も保存される** |
| `LUA_PATH=""`(空文字で export) | `<rock 2 件>` のみ。`--set-default` は `${VAR-...}`(未設定のみ)なので発火しない。**素の Lua でも `LUA_PATH=""` は既定値なしなので挙動は一致**しており、退行ではない |

**(5) rock は実際に読める。** 上記 wrapper 経由で
`nvim --clean -l script.lua` を実行し、`require("inspect")`(pure Lua / `LUA_PATH`)と
`require("lua-utf8")`(C rock / `LUA_CPATH`)がともに成功することを確認済み。
本物の `nvimx-neovim` wrapper(`--add-flags "--cmd 'luafile <bootstrap>'"` 付き)でも同様に成功する。

**(6) `require("inspect")` は素の neovim では失敗する** ので negative control として使える。
一方 **`require("lpeg")` は素の neovim でも成功する**(neovim が lpeg を同梱し preload している)ので、
C rock のテスト対象に lpeg を選んではならない。実測:

```
$ env -u LUA_PATH -u LUA_CPATH nvim --clean --headless \
    -c 'lua print(pcall(require,"inspect")); print(pcall(require,"lpeg"))' +qa
false   module 'inspect' not found: ...
true    table: 0x...
```

## 2. ゴール

issue の "Done when" を検証可能な形に落とす。

- **G1(rock が読める)**: `programs.nvimx.extraLuaPackages = ps: [ ps.inspect ]` を設定して作った
  neovim で `require("inspect")` が成功する。C rock(`ps.luautf8` → `require("lua-utf8")`)も同様に、
  すなわち `LUA_PATH` だけでなく `LUA_CPATH` も配線されている。`checks.extra-lua-packages` が
  実際に neovim を起動して証明する。
- **G2(既定の no-op)**: `extraLuaPackages` を設定しないとき、生成される wrapper スクリプトは
  **今日のものと(store path を除いて)バイト単位で同一**である。`LUA_PATH` / `LUA_CPATH` という
  文字列すら現れない。**計画作成時点で実測により確認済み**(§5.1 の assert がこれを固定する)。
  **これはスクリプトについての主張であって derivation についてではない。** `postBuild` の文字列は
  変わるので drv ハッシュは変わり、wrapper を含む check は一度だけ再ビルドされる(§5.5)。
- **G3(interpreter が正しい)**: 適用先のパッケージセットは `programs.nvimx.package` が実際に
  リンクしている Lua、すなわち `package.lua.pkgs` である。固定の `pkgs.lua51Packages` ではない。
  `package` に passthru.lua が無ければ(例: 既にラップ済みの `pkgs.neovim`)、**黙って別の
  interpreter のセットに当てず、評価時に throw する**。ただし rock を 1 つも要求していない限り
  throw してはならない(既定 `_: [ ]` は引数を捨てるので遅延評価により自然にそうなる)。
- **G4(既定の探索パスを壊さない)**: rock を足しても LuaJIT の既定 `package.path` / `package.cpath` が
  残る(§1.4(4))。ユーザが自分で export している `LUA_PATH` も残る(`--prefix` であって `--set` ではない)。
- **G5(`extraPackages` と重複しない・共存する)**: 両方を同時に設定したとき、1 回の `wrapProgram`
  呼び出しで PATH と LUA_PATH/LUA_CPATH の**両方**が生きる。rock env の `bin/`(`lua` / `luajit`)は
  **PATH に入らない** —— 実行ファイルを PATH に置くのは `extraPackages` の仕事であり、そこを侵さない。
- **G6(新規の fetch を足さない)**: `extra-lua-packages` は degraded モード(lock 無し)で作るので
  **プラグインソースの `fetchTree` が 1 つも起きない**。`hm-module-lua-packages` は `hm-module` が
  既に取得する basic-config の lock だけを使うので、こちらも新しい `fetchTree` は増えない。
  **「ネットワークを一切使わない」ではない** —— どちらの check も `inspect` / `luautf8` /
  `hello` / neovim をバイナリキャッシュから substitute する(いずれも両システムでキャッシュ済み、§5.3)。
  リポジトリで「オフライン」と言うときの意味は一貫して「プラグインソースを取りに行かない」である。
- **G7(ドキュメント)**: README の `## Options` 表に行が入り、`### Lua rocks` 節で
  「luarocks 自体は無効のままである」ことが明記される。`docs/architecture.md` の予告(`:400`, `:525`)が
  実装済みの記述になり、edge-case 表(`:508`)が新オプションを指す。
- **G8(#36 からの申し送りの返却)**: `nvimx-lock` が rockspec ビルドについて出す警告が、
  `nvim-treesitter` の警告と同じ形で `programs.nvimx.extraLuaPackages` を名指しする。
  `docs/plans/36-table-form-build.md:249` が「オプションがまだ存在しないので言及するな」と
  保留した 1 行を、オプションが存在するようになった本件で返す(§3.6)。
  `checks.resolve-build-warnings` が文言を verbatim で固定する(§5.4)。

## 3. 設計

### 3.1 オプションの型

```nix
    extraLuaPackages = lib.mkOption {
      type = lib.types.functionTo (lib.types.listOf lib.types.package);
      default = _: [ ];
      defaultText = lib.literalExpression "ps: [ ]";
      example = lib.literalExpression "ps: [ ps.inspect ]";
      ...
    };
```

- **home-manager の `programs.neovim.extraLuaPackages` と同一の型**(§1.3(a))。見慣れた書き味を壊さない。
- `default = _: [ ]` は**関数**なので `defaultText` が必須である。これを省くと
  `nix eval .#homeModules...` 系や将来の option ドキュメント生成で
  「function is not allowed」的な出力になる。home-manager も同じ理由で `literalExpression "ps: [ ]"` を置いている。
- **`listOf (functionTo ...)` にはしない。** `functionTo` は複数定義を elemType 側でマージするので、
  素の `functionTo (listOf package)` のままモジュール横断で合成される(§1.3(a) の実測)。

### 3.2 どの Lua パッケージセットに適用するか

**`package.lua.pkgs`**(`package` は `programs.nvimx.package`、すなわちユーザが選んだ neovim)。

根拠と実測(pinned nixpkgs):

| 事実 | 実測値 |
|---|---|
| `pkgs.neovim-unwrapped ? lua` | `true` |
| `pkgs.neovim-unwrapped.lua.name` | `luajit-2.1.1774638290` |
| `pkgs.neovim-unwrapped.lua.luaversion` | `"5.1"` |
| `pkgs.neovim-unwrapped.lua.pkgs.inspect == pkgs.luajitPackages.inspect` | `true`(同一 store path) |
| `pkgs.lua51Packages.inspect` | `lua5.1-inspect-3.1.3-0` —— **別の derivation** |
| `pkgs.neovim ? lua`(ラップ済み) | `false`(passthru は `initRc` / `packpathDirs` / `providerLuaRc` / `tests` / `unwrapped`) |
| `aarch64-darwin` でも同じ | `lua.name = luajit-2.1...`、`luaversion = "5.1"`、`luaCPathList = [ "lib/lua/5.1/?.so" ]` |

- **`pkgs.lua51Packages` を決め打ちにしてはならない。** neovim が LuaJIT をやめた日に静かに壊れるうえ、
  今日でも C rock は別の interpreter のヘッダ/ライブラリに対してコンパイルされたものになる。
  nixpkgs 自身が `pkgs/top-level/lua-packages.nix:39` に
  `# Dont take luaPackages from "global" pkgs scope to avoid mixing lua versions` と書いている。
- **neovim-overlay(nightly)でも壊れない。** それらは `neovim-unwrapped` を `overrideAttrs` した
  derivation であり、`overrideAttrs` は passthru を保存するので `.lua` はそのまま残る。
- **`package.lua` が無い場合は throw する。** 該当するのは「`package` にラップ済みの `pkgs.neovim` を
  渡した」ような、モジュールの description が既に否定している使い方である
  (`programs.nvimx.package` は「an -unwrapped style derivation」と書いてある)。
  fallback で `pkgs.luajit` に当てるのは**採らない** —— それは「ユーザの neovim とは無関係の
  interpreter 向けにビルドした C rock を `LUA_CPATH` に置く」ことであり、
  症状が runtime のロードエラーとしてしか出ない。

- **throw は遅延させる。** `luaPackages = extraLuaPackages lua.pkgs` と書けば、既定の `_: [ ]` は
  引数を捨てるので `lua` は**強制されない**。pinned nixpkgs で実測:
  `(_: [ ]) (throw "forced!")` → `[ ]`(例外は出ない)。また `{ }.lua.pkgs or "fallback"` → `"fallback"` も実測済み
  (`x.y.z or d` は途中の属性欠落も拾う)。
  結果として **passthru.lua を持たない package でも、rock を要求していなければ今日どおり wrap できる**
  (実測済み: `pkgs.neovim` + rock 無しは wrap 成功、`pkgs.neovim` + `ps: [ ps.inspect ]` は
  `tryEval` が `success = false` を返す)。

### 3.3 `LUA_PATH` / `LUA_CPATH` の作り方

```nix
  luaEnv = lua.withPackages (_: luaPackages);
  luaWrapperArgs = lib.optionalString (luaPackages != [ ]) (
    lib.concatStringsSep " " [
      "--set-default LUA_PATH ';;'"
      "--set-default LUA_CPATH ';;'"
      "--prefix LUA_PATH ';' ${lib.escapeShellArg (lua.pkgs.luaLib.genLuaPathAbsStr luaEnv)}"
      "--prefix LUA_CPATH ';' ${lib.escapeShellArg (lua.pkgs.luaLib.genLuaCPathAbsStr luaEnv)}"
    ]
  );
```

決定事項と根拠:

1. **`lua.withPackages` を使う**(生の list を `symlinkJoin` しない)。`withPackages` は
   `requiredLuaModules` を辿って rock の依存 rock まで env に入れる。自前で束ねるとそれが落ちる。
   引数は `(_: luaPackages)` —— 関数を 2 度適用しないため。nixpkgs の
   `neovim/wrapper.nix:115` と同型である。
   **ただしこの理由は check ではカバーされない**(§5.3 の末尾)。`inspect` も `luautf8` も依存 rock を
   持たないので、`symlinkJoin` に差し替えても `checks.extra-lua-packages` は緑のままである。
   `withPackages` を使うのは nixpkgs の作法に従うためであって、check が守るからではない。
2. **パス文字列は `luaLib.genLuaPathAbsStr` / `genLuaCPathAbsStr` で作る**(§1.3(c))。
   `?.lua` / `?/init.lua` / `?.so` も `share/lua/5.1` / `lib/lua/5.1` も**手で書かない**。
3. **`--set-default VAR ';;'` を `--prefix` より前に置く**(§1.4(3)(4))。これが既定パス保存の要である。
   makeWrapper は引数の順にブロックを吐くので、順序が意味を持つ。**`;;` を `--prefix` の値の末尾に
   付けても消える。**
4. **`--set` ではなく `--prefix`**。ユーザが既に export している `LUA_PATH` を握り潰さない
   (`extraPackages` が `--prefix PATH` であるのと同じ判断)。
5. **`lib.escapeShellArg` が必須。** 値には `;` と `?` が含まれる。`extraPackages` 側の
   `${lib.makeBinPath extraPackages}` は裸で書かれているが、store path には `;` も `?` も
   glob 文字も入らないので成立しているだけである。**`;` を裸で書くとその場でコマンドが切れる。**
   セパレータ引数 `';'` も同様にクォートする(上の文字列リテラル内で既にクォート済み)。
6. **`luaPackages == [ ]` のときは 1 文字も足さない。** `--set-default` すら出さない。
   これが G2(既定は今日とバイト同一)を成立させる。

**`postBuild` の行継続について(実装上の落とし穴)。** 現行 `:20` は最後の継続行なので末尾に `\` が無い。
lua 引数を足すには `:20` の末尾に `\` を付ける必要がある。`extraPackages` が空のとき、その行は
「空白 + `\`」だけの継続行になるが、これは POSIX シェルで正しく畳まれる。**計画作成時に実測済み**:

```sh
wrapProgram out/bin/nvim \
  --add-flags "--cmd X" \
   \
  
ln -s a b          # ← 次のコマンドとして正しく実行される
```
→ `ARGS: out/bin/nvim --add-flags --cmd X` と `alias line ran` の両方が出る。

最後の継続行(= 新設する `${luaWrapperArgs}`)には `\` を**付けない**。付けると両方が空のときに
次行の `ln -s` を吸い込む。

### 3.4 却下する代替案

**(A) `bootstrap.lua` の中で `package.path = "<生成>" .. ";" .. package.path` を実行する
(現行 nixpkgs `neovim/wrapper.nix:113-125` 方式)。**
既定パス保存が自明で、子プロセスに環境変数が漏れないという長所がある。しかし
(a) issue #27 が `wrapper.nix` と `LUA_PATH` / `LUA_CPATH` を名指ししている、
(b) `bootstrap.lua.in` は「lazy の forced opts を注入する」という単一の役割を持つファイルであり、
そこに wrapper の環境設定を混ぜると `nix/lib/bootstrap.nix` にプレースホルダを 2 個増やすことになる、
(c) wrapper は既に `PATH` を持っており、「実行環境の配線は wrapper が持つ」という現行の分担が明快である、
の 3 点で採らない。§1.4(4) の `--set-default` により (A) の唯一の実質的長所(既定パス保存)は
環境変数方式でも得られる。

**(B) `--prefix LUA_PATH ';' "<paths>;;"`(素朴案)。**
§1.4(3) のとおり `;;` が makeWrapper に食われて消える。**動くように見えて既定パスが消える**ので最も危険。

**(C) `--set LUA_PATH '<paths>;;'`。**
`;;` は生き残るが、ユーザが export している `LUA_PATH` を握り潰す。`extraPackages` が `--prefix` である
以上、ここだけ `--set` にする理由が無い。

**(D) rock env を `extraPackages` に足してもらう(新オプションを作らない)。**
`extraPackages` は `--prefix PATH` にしか効かないので `require` は通らない。加えて rock env の
`bin/lua` / `bin/luajit` が PATH に載り、ユーザの `lua` を静かに shadow する。issue の
「compose with the existing `extraPackages` option rather than duplicating it」はまさにこれを避けろという指示である。

**(E) `makeEnv` の返り値に `luaEnv` を足して外から見えるようにする。**
`extraPackages` に対応する出力が今も無いのと同じ理由で足さない。API 面(README の `env` 行、
モジュールの `env` description)を増やす代わりに得られるのは「check が assert しやすい」だけであり、
それは wrapper スクリプトを `grep` すれば同じことができる(§5.1)。**`makeEnv` の出力は変更しない。**

### 3.5 `extraPackages` との合成

- **1 回の `wrapProgram` 呼び出しに両方の引数を並べる。** `wrapProgram` を 2 回呼ぶと wrapper が
  二重にラップされ、`.nvim-wrapped` が入れ子になる。
- **rock env は `PATH` に載せない。** `luaEnv` には `bin/lua` / `bin/luajit` があるが、
  `--prefix PATH` には渡さない。役割分担は
  「`extraPackages` → `PATH` のみ」「`extraLuaPackages` → `LUA_PATH` / `LUA_CPATH` のみ」で固定する。
  §5.1 の `vim.fn.executable("luajit") == 0` がこれを固定する。
- 両方を同時に設定した状態が `checks.extra-lua-packages` の主ケースである(G5)。

### 3.6 lazy の `rocks` は無効のまま。ただし lock 時警告に出口を書く(#36 からの申し送り)

`bootstrap.lua.in:22` の `rocks = { enabled = false, hererocks = false }` は**触らない**。
本件は「lazy に luarocks を実行させる」のではなく「Nix が用意した rock を interpreter に見せる」機能である。
`build.kind == "rockspec"` の**分類**(`extract.lua` / `resolve.lua` の `classify_step`、`plugin-drv.nix`)も
**触らない** —— rockspec ビルドは相変わらず走らない。

**変えるのは警告文 1 行だけである。** これは #36 の計画が本 issue に明示的に預けた宿題である
(`docs/plans/36-table-form-build.md:249`。同行は `rockspec` kind 全般を論じる長い箇条書きで、
以下はその末尾部分の抜粋である):

> **警告文で `extraLuaPackages` に言及しないこと**: そのオプションは `nix/home-manager/default.nix` に
> **まだ存在しない**(`extraPackages` のみ)。3 つの hatch 案内(`resolve.lua:371-378`)に任せる。

(引用中の `resolve.lua:371-378` は #36 執筆時点の行番号であり、**現在は誤り**である。
3 hatch 案内の実体は今日の `lua/nvimx/resolve.lua:1205-1214` の `if unbuildable then note(...)` である。
引用なので原文のまま置いてある。)

同 `:389` も「#27 がまさにそのオプションを追加する issue なので放置してよい」と書いている。
**その前提は本件で消える**ので、預かった宿題をここで返す。

今日の `resolve.lua:533-536`(`build_warning` の scalar 分岐の末尾)には、`nvim-treesitter` にだけ
具体的な出口が付いている:

```lua
    local msg = ("build is %s (%q) and cannot be run at build time"):format(what, cmd)
    if name == "nvim-treesitter" then
      msg = msg .. ". nvimx merges parsers from nixpkgs instead -- set programs.nvimx.treesitter.grammars"
    end
```

rockspec にはそれが無く、汎用の 3 hatch(`overrides` / `nixpkgsFallback` / `nix/build-registry/`)だけが
案内される —— **どれも rock の依存を入れる手段ではない**ので、実質「出口なし」である。
`nvimx-lock` はユーザがこの問題に出会う唯一の場所であり、そこだけが治療法を名指ししていない状態は
放置しない。README の新節が「`nvimx-lock` still says so」と書く以上、その「says so」が
出口を指していないと片手落ちになる。

**設計**: `nvim-treesitter` の pointer とまったく同じ形・同じ位置に、rockspec 用の 1 節を足す。
どちらか一方しか付かない(`nvim-treesitter` が `build = "rockspec"` を書いた場合は grammars の方が有用)。
scalar 形式と `steps` 形式の両方の分岐で同じ判定を使うため、小さなヘルパに切り出す(§4.4)。
分類・kind・`plugins.json` のスキーマは 1 バイトも変わらない。

**スコープについての明示的な判断**: issue #27 の "What to do" / "Done when" は lock 時警告に
一言も触れていないので、**G8 は issue の要求を超えている**。しかも本件の変更の中で
**ユーザに届く文字列を書き換えるのはここだけ**である(他はオプション追加・wrapper の配線・
ドキュメント)。それでもやるのは、(a) #36 が明示的に本 issue に預けた宿題であること、
(b) README の新節が「`nvimx-lock` still warns about it — pointing you here」と書く以上、
その pointer が実在しないと文書の方が嘘になること、の 2 点による。
**受け入れたコストとして記録しておく** —— 文言は `checks.resolve-build-warnings` が
verbatim で固定するので(§5.4)、以後の変更はその golden を通すことになる。
README と architecture.md の文面でこの区別を明示する(§4.6(c) / §4.7)。

## 4. 実装手順

行番号は現在の作業ツリー基準。**行番号の大きい順に当てるか、シンボルで位置決めすること。**

### 4.1 `nix/lib/wrapper.nix`(全文差し替え)

以下は **nixfmt 正規形をそのまま貼ったもの**である(pinned nixpkgs の `nixfmt-rfc-style` に通して
無変更であることを実測済み)。逐語で書き写せば §6 手順 1 の `nix fmt -- --ci` がそのまま通る。

```nix
# wrapProgram the user-selected neovim (an unwrapped style package) and inject bootstrap.lua
{ pkgs }:
{
  package,
  bootstrap,
  extraPackages ? [ ],
  extraLuaPackages ? (_: [ ]),
  vimAlias ? false,
  viAlias ? false,
}:
let
  inherit (pkgs) lib;

  # The Lua the chosen neovim is actually built against -- the only package set whose rocks are
  # guaranteed to match it. nixpkgs exposes it as passthru.lua (LuaJIT, i.e. Lua 5.1, today), and
  # every -unwrapped-shaped derivation that goes through overrideAttrs keeps that passthru, so a
  # neovim-nightly-overlay package works the same way. Reaching for a fixed pkgs.lua51Packages
  # instead would mix interpreters -- exactly what nixpkgs keeps the sets separate to avoid.
  lua =
    package.lua or (throw ''
      nvimx: extraLuaPackages is set, but ${package.name or "the neovim package"} exposes no
      passthru.lua, so nvimx cannot tell which Lua the rocks would have to match.
      Point programs.nvimx.package at an -unwrapped style derivation (pkgs.neovim-unwrapped, or
      a neovim-nightly-overlay package); an already-wrapped pkgs.neovim has no passthru.lua.
    '');
  # Applied lazily: the default (_: [ ]) discards its argument, so a package with no passthru.lua
  # never reaches the throw above unless rocks were actually asked for.
  luaPackages = extraLuaPackages lua.pkgs;
  luaEnv = lua.withPackages (_: luaPackages);
  # ";;" is Lua's "and the interpreter's compiled-in default path here". It cannot ride along in
  # the --prefix value: makeWrapper splits that value on the separator and drops empty components,
  # so a trailing ";;" disappears. --set-default puts it in the variable instead (the wrapper emits
  # its blocks in argument order), and the --prefix blocks then prepend to it. Without this, adding
  # a single rock would silently drop LuaJIT's own package.path -- require("jit.dump") and friends.
  luaWrapperArgs = lib.optionalString (luaPackages != [ ]) (
    lib.concatStringsSep " " [
      "--set-default LUA_PATH ';;'"
      "--set-default LUA_CPATH ';;'"
      "--prefix LUA_PATH ';' ${lib.escapeShellArg (lua.pkgs.luaLib.genLuaPathAbsStr luaEnv)}"
      "--prefix LUA_CPATH ';' ${lib.escapeShellArg (lua.pkgs.luaLib.genLuaCPathAbsStr luaEnv)}"
    ]
  );
in
pkgs.symlinkJoin {
  name = "nvimx-neovim";
  paths = [ package ];
  nativeBuildInputs = [ pkgs.makeWrapper ];
  postBuild = ''
    wrapProgram $out/bin/nvim \
      --add-flags "--cmd 'luafile ${bootstrap}'" \
      ${lib.optionalString (extraPackages != [ ]) "--prefix PATH : ${lib.makeBinPath extraPackages}"} \
      ${luaWrapperArgs}
    ${lib.optionalString vimAlias "ln -s $out/bin/nvim $out/bin/vim"}
    ${lib.optionalString viAlias "ln -s $out/bin/nvim $out/bin/vi"}
  '';
}
```

**注意点 3 つ:**

- `--prefix PATH` の行の末尾に `\` が付いたこと(§3.3 の 6)。
- `${luaWrapperArgs}` の行には `\` を付けないこと。
- `lua.pkgs.luaLib` は `lua.pkgs`(= `luajitPackages`)の属性である。`pkgs.luaPackages.luaLib` ではない。
- **throw の接頭辞は `nvimx:` であって `programs.nvimx:` ではない。** リポジトリの規約であり、
  lib 側の throw はすべて `nvimx:` である(`sources.nix:11` / `resolve-plugin.nix:32` /
  `treesitter.nix:40` / `plugin-drv.nix:67`)。`programs.nvimx:` は hm モジュール自身の warning
  専用である(`home-manager/default.nix:258-282`)。`wrapper.nix` はモジュールを介さず
  `lib.makeEnv` から直接到達できるので、モジュール名前空間の接頭辞は事実としても不正確になる。
  **メッセージ本体の書き分けも既存 2 件に揃えてある**: 冒頭の 1 文はオプションの**短い名前**
  (`nvimx: extraLuaPackages is set, ...`)、直し方を示す行だけ**フルネーム**
  (`Point programs.nvimx.package at ...`)である —— `resolve-plugin.nix:33` の
  `nvimx: plugins.nixpkgsFallback lists "..."` + `:38` の
  `programs.nvimx.plugins.overrides."<name>" = ...`、`treesitter.nix:41` の
  `nvimx: treesitter.grammars lists "..."` とまったく同じ形である。

この wrapper は **rock 無しのとき今日の出力とバイト同一**であることを実測済み
(現行 `env.wrapped/bin/nvim` と差分ゼロ、store path の違いを除く)。

### 4.2 `nix/lib/make-env.nix`

1. **formals** —— `:9` の `extraPackages ? [ ],` の直後に 1 行:

   ```nix
     # A function over the Lua package set of `package` (ps: [ ps.foo ]), the same shape as
     # home-manager's programs.neovim.extraLuaPackages. Threaded straight to the wrapper, which is
     # what knows which Lua the chosen neovim links against.
     extraLuaPackages ? (_: [ ]),
   ```

2. **`mkWrapper` 呼び出し(`:132-140`)** —— `inherit` のリスト、`extraPackages`(`:136`)の直後に
   `extraLuaPackages` を足す:

   ```nix
     wrapped = mkWrapper {
       inherit
         package
         bootstrap
         extraPackages
         extraLuaPackages
         vimAlias
         viAlias
         ;
     };
   ```

3. **返り値(`:142-154`)は変更しない**(§3.4(E))。

**ここは評価器が守ってくれない。** `makeEnv` の formals には `...` が無いが、それが弾くのは
**宣言されていない引数を渡した**場合だけである。`extraLuaPackages ? (_: [ ])` は既定値付きなので、
**モジュール側で渡し忘れても常にエラーにならず、黙って既定値に落ちる**。
#26 の `devPlugins` / `devPath` とまったく同じ性質であり、**渡し忘れを検知するのは
`checks.extra-lua-packages` の `moduleWrapped` assert(§5.1)だけ**である。

### 4.3 `nix/home-manager/default.nix`

1. **`extraPackages`(`:88-93`)の直後、`devPlugins = lib.mkOption`(`:95`)の直前**にオプションを挿入。
   README の `## Options` 表もこの宣言順を写すので、§4.6(a) の挿入位置と必ず一致させること:

   ```nix
       extraLuaPackages = lib.mkOption {
         type = lib.types.functionTo (lib.types.listOf lib.types.package);
         default = _: [ ];
         defaultText = lib.literalExpression "ps: [ ]";
         example = lib.literalExpression "ps: [ ps.inspect ]";
         description = ''
           Lua rocks to put on the wrapper's LUA_PATH / LUA_CPATH, as a function over a Lua
           package set -- the same shape as home-manager's programs.neovim.extraLuaPackages.

           The set handed to the function is the one belonging to the neovim in `package`
           (its passthru.lua.pkgs, i.e. luajitPackages for a stock nixpkgs neovim), so the
           rocks always match the interpreter that will load them. A package with no
           passthru.lua -- an already-wrapped pkgs.neovim, say -- is rejected rather than
           matched against some other interpreter's rocks.

           This is the supported way to satisfy a luarocks dependency: nvimx forces lazy.nvim's
           rocks.enabled = false, so a `build = "rockspec"` is never run. Naming the rock here
           does not make that build run either; it puts the dependency in place instead.

           Only LUA_PATH / LUA_CPATH are touched. Use extraPackages for anything that has to
           land on PATH -- no Lua interpreter from this option is added to it.
         '';
       };
   ```

2. **`makeEnv` への受け渡し(`:284-298`)** —— `inherit (cfg)` のリスト、`extraPackages`(`:289`)の
   直後に `extraLuaPackages` を足す:

   ```nix
           inherit (cfg)
             package
             lockDir
             extraPackages
             extraLuaPackages
             vimAlias
             viAlias
             plugins
             treesitter
             devPlugins
             devPath
             ;
   ```

3. **`env` の description(`:237-247`)は変更しない**(§3.4(E) により `makeEnv` の出力は増えない)。
4. **warnings は増やさない。** 誤った rock 名は attrset の属性欠落として評価時に落ちるので、
   `unknownPluginNames` のような「報告して続行」の対象にならない。

### 4.4 `lua/nvimx/resolve.lua`(#36 からの申し送りの返却、§3.6)

**本件で変わる lua ファイルはこの 1 つだけ**であり、変わるのは警告文だけである。分類も kind も
`plugins.json` のスキーマも 1 バイトも動かない。

`build_warning`(`:520-565`)の中で `nvim-treesitter` の pointer が **scalar 分岐(`:534-536`)と
`steps` 分岐(`:561-563`)の 2 箇所に重複**している。rockspec の pointer も同じ 2 箇所に要るので、
**両方が呼ぶ小さなヘルパに切り出す**。重複を 1 つ増やすより素直で、`steps` に rockspec 要素が
混ざった `{ "make", "rockspec" }` も自動的に拾える。

1. **`build_warning` の doc コメント(`:520`)の直前**にヘルパを 2 つ挿入する:

   ```lua
   -- True when the build nvimx could not run is (or contains) a luarocks build. Both shapes have
   -- the same cure, so the "steps" form has to be inspected as well: { "make", "rockspec" } is
   -- exactly the table shape #36 taught this file to classify.
   ---@param build table the classified build
   ---@return boolean
   local function has_rockspec(build)
     if build.kind ~= "steps" then
       return build.kind == "rockspec"
     end
     -- Plain ipairs(build.steps), no `or {}`: the guard above already means kind == "steps",
     -- which the classifier only ever produces with a steps list. unrunnable_steps (:501) is
     -- written the same way for the same reason.
     for _, s in ipairs(build.steps) do
       if s.kind == "rockspec" then
         return true
       end
     end
     return false
   end

   -- The trailing clause naming the specific way out, when nvimx has one for the shape it could
   -- not run. The three generic hatches (overrides / nixpkgsFallback / nix/build-registry) are
   -- printed once at the end of the run and stay the fallback; these are the cases where none of
   -- the three is what the user actually wants. At most one clause is appended -- for
   -- nvim-treesitter the grammars pointer is the more useful of the two even if its spec somehow
   -- declared a rockspec build.
   ---@param name string
   ---@param build table
   ---@return string "" when there is no specific pointer
   local function build_pointer(name, build)
     if name == "nvim-treesitter" then
       return ". nvimx merges parsers from nixpkgs instead -- set programs.nvimx.treesitter.grammars"
     end
     if has_rockspec(build) then
       -- #27. nvimx forces lazy's rocks.enabled = false, so this build never runs; the rock has
       -- to come from Nix instead.
       return ". nvimx never runs luarocks -- add the rock with programs.nvimx.extraLuaPackages instead"
     end
     return ""
   end
   ```

2. **scalar 分岐(`:534-536`)** —— `if name == "nvim-treesitter" then ... end` の 3 行を消し、
   直後の `return msg` を `return msg .. build_pointer(name, build)` にする。

3. **`steps` 分岐(`:561-563`)** —— 同じく `if name == "nvim-treesitter" then ... end` の 3 行を消し、
   直後の `return msg` を `return msg .. build_pointer(name, build)` にする。

4. **`build_warning` の doc コメント(`:521-522`)を書き換える。** これは**必須**である ——
   今日の文面は「Scalar wording is kept byte-for-byte identical to before this file grew `steps`
   support」と言っており、本件のあと **scalar の rockspec だけはそれが偽になる**(節が 1 つ伸びる)。
   このファイルは自分のコメントに厳しいので、放置すると潜在的な嘘が残る。

   before(`:520-522`):
   ```lua
   -- The full message for a plugin whose build cannot run entirely (scalar excmd/function/rockspec/
   -- luafile) or only partially (some steps of a "steps" build). Scalar wording is kept byte-for-byte
   -- identical to before this file grew `steps` support (checks.resolve-build-warnings pins it).
   ```
   after:
   ```lua
   -- The full message for a plugin whose build cannot run entirely (scalar excmd/function/rockspec/
   -- luafile) or only partially (some steps of a "steps" build). The core sentence is kept
   -- byte-for-byte identical to before this file grew `steps` support; build_pointer may append one
   -- trailing clause on top of it. checks.resolve-build-warnings pins both.
   ```

**核の文は 1 文字も変わらない。** `nvim-treesitter` は今日と同一文字列を返し、rockspec でも
`nvim-treesitter` でもないプラグインは `""` を足すだけである。伸びるのは rockspec の 1 節だけであり、
`checks.resolve-build-warnings` の既存 assert
(`flake.nix:1332-1333` の verbatim 2 本、`:1344` の grammars pointer)は無変更で通る
(どちらも rockspec ではない。前者は `unbuildable-config` の excmd / function、
後者は部分一致の grep である)。

`extract.lua` / `plugin-drv.nix` / `nix/build-registry/` は**触らない**。
`resolve.lua:1205-1214` の 3 hatch 案内も**触らない** —— 汎用の逃げ道としてそのまま残す。

### 4.5 `flake.nix`

1. `hm-module-dev`(`:258-263`)の直後、`wrapper-aliases` のコメント(`:264`)の直前に
   `hm-module-lua-packages` を挿入(§5.2)。
2. `wrapper-aliases` の終端 `'';`(`:278`)の直後、`# build.kind == "shell"` のコメント(`:279`)の直前に
   `extra-lua-packages` を挿入(§5.1)。wrapper 関連の check を隣り合わせにするための位置である。
3. `checks.resolve-build-warnings` の golden に rockspec pointer の assert を足す(§5.4)。

### 4.6 `README.md`

**§4.7 と同じく、行番号の大きいものから当てること。** ここも編集どうしが行番号をずらす ——
(a) は `:195` に 1 行足すので (c) / (d) の番号が +1 し、(d-2) は 3 行を 4 行にするので
(d-1) の番号が +1 する。**当てる順は (c) → (d-1) → (d-2) → (a)**、あるいは文字列で位置決めする。
以下は読みやすさのため (a) から順に並べてある。

**(a) `## Options` の表** —— `extraPackages` の行(`:195`)と `devPlugins` の行(`:196`)の**あいだ**に 1 行。
**位置は §4.3 のモジュール側と揃えること**(README の表はモジュールのオプション宣言順を写したものである):

```
| `extraLuaPackages` | `functionTo (listOf package)` | `ps: [ ]` | Lua rocks to put on the wrapper's `LUA_PATH` / `LUA_CPATH`, as a function over the Lua package set of the Neovim you chose. luarocks itself stays disabled. See [Lua rocks](#lua-rocks). |
```

**(b) `env` の行(`:205`)は変更しない**(makeEnv の出力は増えない)。

**(c) 新しい節** —— `### Local plugin development` の末尾(`:395`、`projects.` で終わる行)の直後、
空行を挟んで `## How it works`(`:397`)の直前に挿入する。
以下は**インデント 4 桁で引用した README の実内容**であり、挿入時にはインデントを外すこと
(内部に ```` ```nix ```` フェンスがあるためこの計画書側ではネストできない):

    ### Lua rocks

    lazy.nvim can install luarocks dependencies for a plugin. nvimx switches that off — `rocks.enabled`
    is forced to `false`, so nothing is ever fetched or built at runtime — and lets you take the rock
    from Nix instead:

    ```nix
    programs.nvimx.extraLuaPackages = ps: [ ps.inspect ];
    ```

    The function receives the Lua package set of the Neovim *you* chose — `package`'s own
    `passthru.lua.pkgs`, which is `luajitPackages` for a stock nixpkgs Neovim — so the rocks always
    match the interpreter that will load them, C rocks included. It is the same shape as
    home-manager's `programs.neovim.extraLuaPackages`, and it composes: two modules can each add
    rocks and the lists are concatenated. A rock nixpkgs does not package is reachable too, since the
    argument is only a package set: `_: [ myOwnRock ]` works just as well.

    What it touches is `LUA_PATH` and `LUA_CPATH`, and nothing else. `extraPackages` stays the way to
    put an *executable* on `PATH`, and no Lua interpreter from this option is added to it. The
    interpreter's own default search path survives, and so does a `LUA_PATH` you already export — the
    rocks are prefixed to it, not substituted for it. (If that exported `LUA_PATH` has no `;;` in it,
    the defaults stay out, exactly as they would for any other Lua program you run.) Ask for no rocks
    and the wrapper is exactly what it was before, environment variables included.

    This does not resurrect `build = "rockspec"`: that build kind still cannot run, and `nvimx-lock`
    still warns about it — pointing you here. `extraLuaPackages` is how you satisfy the dependency
    such a build was going to install.

**(d) "rockspec" を説明している同じ段落(`:283-288`)に出口へのリンクを 2 本足す。**
`docs/architecture.md:508` の edge-case 表は §4.7(8) で `extraLuaPackages` を指すよう直すのに、
README の同じ内容の段落だけリンクが無いのは非対称である。

**ヒンク 2 つを、下(大きい行番号)から順に当てること。** (d-2) は 3 行を 4 行にするので、
先に当てると (d-1) の行番号が +1 ずれる。

**(d-1) `:288`** —— `nvimx-lock` が出す**プラグインごとの pointer を列挙している唯一の文**である。
§4.4 のあと pointer は 2 種類になるのに、treesitter しか名指ししていない状態は、
§3.6 が「pointer が実在しないと文書の方が嘘になる」と言ったのとちょうど裏返しの嘘になる:

before:
```
and pointing at the hatches above (at `treesitter.grammars` for `nvim-treesitter`). The same list is
```
after:
```
and pointing at the hatches above (at `treesitter.grammars` for `nvim-treesitter`, at
[`extraLuaPackages`](#lua-rocks) for a `rockspec` build). The same list is
```

**(d-2) `:283-285`** —— `build = "rockspec"` を挙げているその場でリンクする:

before:
```
`cd deps && make`. A spec whose `build` is an ex command (`build = ":TSUpdate"`), a Lua callback, a
luarocks build (`build = "rockspec"`), or a `*.lua` file has nothing nvimx can execute directly
(and neither do the non-shell elements of a list build), so that part is skipped and the plugin is
```
after:
```
`cd deps && make`. A spec whose `build` is an ex command (`build = ":TSUpdate"`), a Lua callback, a
luarocks build (`build = "rockspec"` — see [Lua rocks](#lua-rocks) for how to supply what it was
going to install), or a `*.lua` file has nothing nvimx can execute directly (and neither do the
non-shell elements of a list build), so that part is skipped and the plugin is
```

3 行が 4 行になるだけで、その次の行(`installed with helptags only,` で始まる行)以降は
(d-1) の 1 行増を除いて無変更である。

これで README 内の `(#lua-rocks)` リンクは **3 本**になる
(Options 表 1 + (d-1) 1 + (d-2) 1。§6 手順 8 の期待値)。

### 4.7 `docs/architecture.md`

以下は**行番号の小さい順**に並べてある。当てるときは**下(大きい番号)から**当てるか、文字列で位置決めすること。
編集 3(`:171`)は 1 行を 2 行にするので、それより下の行番号はすべて +1 ずれる。

1. **`:108`** —— build 時フローの mermaid 図。`:171` の散文と対になるノードなので、片方だけ直すと図と本文が食い違う:

   before: `    J --> K["wrapProgram neovim<br/>--cmd luafile"]`
   after:  `    J --> K["wrapProgram neovim<br/>--cmd luafile<br/>PATH / LUA_PATH / LUA_CPATH"]`

2. **`:121`** —— 設計原則 4。`:108` を直す理由(「片方だけ直すと図と本文が食い違う」)がそのまま当てはまる ——
   `LUA_PATH` / `LUA_CPATH` は Lua のモジュール解決を変えるので、まさに "runtime injection" である。
   後続文「The user's lua stays unmodified.」(`:122`)は依然として真なので**触らない**:

   before: `4. **Runtime injection is limited to the wrapper's \`--cmd luafile\` + \`package.preload["lazy"]\`**.`
   after:  `4. **Runtime injection is limited to the wrapper's \`--cmd luafile\` + \`package.preload["lazy"]\`, plus \`LUA_PATH\` / \`LUA_CPATH\` when \`extraLuaPackages\` asks for rocks**.`

3. **`:171`** —— build 時フローの `[5]` の直後の行に環境変数を書き足す:

   before:
   ```
         → wrapProgram neovim (the user-selected package) with --cmd 'luafile <bootstrap.lua>'
   ```
   after:
   ```
         → wrapProgram neovim (the user-selected package) with --cmd 'luafile <bootstrap.lua>',
           extraPackages on PATH and extraLuaPackages' rock env on LUA_PATH / LUA_CPATH
   ```

4. **`:400`** —— コメントを実装に合わせる:

   before:
   ```
     extraLuaPackages = ps: [ ];      # manual luarocks dependencies (escape hatch)
   ```
   after:
   ```
     extraLuaPackages = ps: [ ];      # lua rocks on the wrapper's LUA_PATH / LUA_CPATH (luarocks itself stays off)
   ```

5. **`:467`** —— ファイル一覧の wrapper.nix の説明:

   before: `    wrapper.nix              # wrapProgram for neovim`
   after:  `    wrapper.nix              # wrapProgram for neovim (PATH / LUA_PATH / LUA_CPATH)`

6. **`:491`** —— checks の列挙に 2 件を足す。**列挙は `hm-module-*` ファミリが連続する形になっているので、
   2 件を並べて置いてはならない** —— `hm-module-lua-packages` はファミリの末尾(`hm-module-dev` の直後)、
   `extra-lua-packages` は列挙の末尾(`wrapper-aliases` の直後)である。該当箇所だけを抜き出すと:

   before:
   ```
   ..., dev-plugins, hm-module, hm-module-degrade, hm-module-plugins, hm-module-treesitter, hm-module-dev, plugins-overrides, plugins-nixpkgs-fallback, plugins-escape-hatch, wrapper-aliases}`
   ```
   after:
   ```
   ..., dev-plugins, hm-module, hm-module-degrade, hm-module-plugins, hm-module-treesitter, hm-module-dev, hm-module-lua-packages, plugins-overrides, plugins-nixpkgs-fallback, plugins-escape-hatch, wrapper-aliases, extra-lua-packages}`
   ```

7. **`:505`** —— edge-case 表の「実行できない build」の行。README の (d-1) と同じ理由である ——
   この行も**警告が何を指すかを列挙している**のに、`rockspec` の出口が抜けている。
   下の luarocks 専用行(`:508`、編集 8)がほぼ肩代わりしているので必須ではないが、
   「列挙している以上は正しく列挙する」という (d-1) の基準を通す:

   before(末尾):
   ```
   ... Warns at lock time and points to registry / overrides / nixpkgsFallback |
   ```
   after:
   ```
   ... Warns at lock time and points to registry / overrides / nixpkgsFallback -- and, for a `rockspec`, to `extraLuaPackages` (see the luarocks row below) |
   ```

8. **`:508`** —— edge-case 表の luarocks の行の末尾に出口を書き足す:

   before(末尾):
   ```
   ... warned about at lock time like any other unrunnable build |
   ```
   after:
   ```
   ... warned about at lock time like any other unrunnable build. `programs.nvimx.extraLuaPackages` is the supported way out: it takes the rock from nixpkgs' Lua package set for the chosen neovim and puts it on the wrapper's LUA_PATH / LUA_CPATH, so the dependency the rockspec build was going to install is simply already there |
   ```

9. **`:525`** —— `extraLuaPackages` に issue 番号を付ける:

   ```
   7. **Finishing touches**: devPlugins (#26), extraLuaPackages (#27), non-GitHub validation, `checks.e2e-offline`, README
   ```

### 4.8 触らないもの

- `lua/nvimx/bootstrap.lua.in` —— `rocks = { enabled = false, hererocks = false }` は維持(§3.6)。
- `lua/nvimx/{extract,genflake}.lua`、`nix/lib/{bootstrap,farm,plugin-drv,resolve-plugin,sources,treesitter,lock-app,build-network}.nix`、
  `nix/build-registry/` —— 無関係。**`lua/nvimx/resolve.lua` だけは例外**で、§4.4 で警告文が 1 節伸びる
  (分類・kind・スキーマは不変)。
- `tests/fixtures/` —— **新規フィクスチャは 1 つも要らない**。degraded モード(存在しない lockDir)で
  wrapper を作れるので、rock の検証に lock は一切要らない。§4.4 の警告文も
  既存の `build-steps-config` がそのまま素材になる(§5.4)。
- `templates/default/flake.nix` —— コメントに `extraPackages` の例があるが、テンプレートは最小構成に
  保つ方針なので rock の例は足さない。

## 5. テスト

### 5.1 `checks.extra-lua-packages`(新設)

`flake.nix:278` の直後に挿入する。**degraded モードで作るのでプラグインソースの `fetchTree` が 1 つも起きない**
(farm は lazy.nvim seed だけになるが、rock の検証には farm の中身は関係しない)。

```nix
          # extraLuaPackages: the promise is a runtime one -- a rock has to be require-able from a
          # built neovim -- so this really starts neovim and requires one, a pure-Lua rock for
          # LUA_PATH and a C rock for LUA_CPATH. Deliberately built in degraded mode: the farm is
          # then the lazy.nvim seed alone, so not one plugin source is fetchTree'd, and rocks do
          # not depend on the lock at all.
          extra-lua-packages =
            let
              inherit (pkgs) lib;
              mkEnv =
                args:
                nvimxLib.makeEnv (
                  {
                    package = pkgs.neovim-unwrapped;
                    lockDir = ./tests/fixtures/basic-config/no-such-lock;
                  }
                  // args
                );
              # Both kinds of rock and an extraPackages entry at once: a single wrapProgram call has
              # to carry all three, which is what "composes with extraPackages" has to mean.
              # inspect is pure Lua (LUA_PATH) and luautf8 is compiled (LUA_CPATH); neither is
              # bundled with neovim, so requiring them proves the wiring. lpeg would not: neovim
              # ships and preloads it, so require("lpeg") succeeds with no LUA_CPATH at all.
              both = mkEnv {
                extraPackages = [ pkgs.hello ];
                extraLuaPackages = ps: [
                  ps.inspect
                  ps.luautf8
                ];
              };
              # The negative control, and the proof that the two options stay independent:
              # extraPackages alone must switch on no Lua wiring whatsoever.
              onlyPath = mkEnv { extraPackages = [ pkgs.hello ]; };
              # The default has to be a genuine no-op: with no rocks asked for the wrapper script
              # must not mention LUA_PATH / LUA_CPATH at all, which is what keeps it byte for byte
              # what it was before this option existed.
              untouched = mkEnv { };
              # The module's pass-through, read back at evaluation level. checks.hm-module-lua-packages
              # exercises the same option but cannot fail on this: mkHmCheck returns only an
              # activationPackage and asserts nothing about it, so dropping extraLuaPackages from
              # makeEnv's argument list in nix/home-manager/default.nix leaves it green -- the option
              # still type-checks, is silently ignored, and the package still builds. The formal in
              # nix/lib/make-env.nix carries a default, so a missing argument is never an error; the
              # absent `...` only rejects arguments makeEnv does not declare, the opposite direction.
              # This check is what catches that drop, and it catches it here: module.lua fails with
              # its own message. A neighbouring regression -- dropping extraLuaPackages from
              # mkWrapper's argument list in nix/lib/make-env.nix, or from wrapper.nix itself -- is
              # caught earlier instead, by the noLua assertion below, because a wrapper that never
              # applies extraLuaPackages also never rejects a package without passthru.lua. That
              # message ("must be refused when rocks are asked for") is then true but points at the
              # wrong symptom, so read this comment before believing it.
              # Degraded lockDir again, to stay offline.
              moduleWrapped =
                (home-manager.lib.homeManagerConfiguration {
                  inherit pkgs;
                  modules = [
                    self.homeModules.nvimx
                    {
                      # The three home.* settings homeManagerConfiguration requires, same values
                      # mkHmCheck uses. Only .config is read; no activation package is built.
                      home.username = "nvimx-test";
                      home.homeDirectory = "/home/nvimx-test";
                      home.stateVersion = "25.05";
                      programs.nvimx = {
                        enable = true;
                        configDir = ./tests/fixtures/basic-config;
                        lockDir = ./tests/fixtures/basic-config/no-such-lock;
                        extraLuaPackages = ps: [ ps.inspect ];
                      };
                    }
                  ];
                }).config.programs.nvimx.env.wrapped;
              # A neovim package with no passthru.lua cannot say which Lua a rock has to match, so
              # it must be refused rather than quietly matched against pkgs.lua51Packages -- an ABI
              # mismatch that would only surface as a load error at runtime. A stub stands in for
              # the real case (an already-wrapped pkgs.neovim) so the check does not depend on what
              # nixpkgs happens to put in that wrapper's passthru today.
              noLua = pkgs.runCommand "nvimx-neovim-without-lua" { } "mkdir -p $out/bin";
              wraps = args: (builtins.tryEval (builtins.seq (mkEnv args).wrapped.drvPath null)).success;
              failures =
                lib.optional (wraps {
                  package = noLua;
                  extraLuaPackages = ps: [ ps.inspect ];
                }) "a neovim package with no passthru.lua must be refused when rocks are asked for"
                # ... and only then: the default (_: [ ]) discards its argument, so laziness has to
                # keep the throw out of the way of everyone who never touches this option.
                ++ lib.optional (
                  !(wraps { package = noLua; })
                ) "a neovim package with no passthru.lua must still wrap when no rocks are asked for";
            in
            pkgs.runCommand "extra-lua-packages" { } (
              if failures == [ ] then
                ''
                  export HOME=$TMPDIR

                  # An empty list must leave the environment alone. Not "sets it to something
                  # harmless" -- absent, so that the wrapper stays what it was before #27.
                  for w in ${untouched.wrapped} ${onlyPath.wrapped}; do
                    if grep -q LUA_ "$w/bin/nvim"; then
                      echo "an empty extraLuaPackages must not touch LUA_PATH / LUA_CPATH: $w" >&2
                      exit 1
                    fi
                  done

                  cat > rocks.lua <<'LUA'
                  local function has(s, sub)
                    return s:find(sub, 1, true) ~= nil
                  end
                  assert(require("inspect"), "a pure-Lua rock must be require-able (LUA_PATH)")
                  assert(require("lua-utf8").len("ab") == 2, "a C rock must be loadable (LUA_CPATH)")
                  -- makeWrapper's --prefix drops empty components, so a trailing ";;" cannot be
                  -- smuggled in through the value; --set-default is what keeps the interpreter's
                  -- own default path alive. Without it a single rock would take out require("jit.dump").
                  assert(has(package.path, "./?.lua"), "default package.path lost: " .. package.path)
                  assert(has(package.cpath, "./?.so"), "default package.cpath lost: " .. package.cpath)
                  -- extraPackages still reaches PATH from the same wrapProgram call ...
                  assert(vim.fn.executable("hello") == 1, "extraPackages did not survive alongside rocks")
                  -- ... and the rock env's own bin/ does not. Putting an interpreter on PATH is
                  -- extraPackages' job, and this option must not start doing it. (Which is also why
                  -- this check must never put a Lua on the builder's PATH itself.)
                  assert(vim.fn.executable("luajit") == 0, "the rock env leaked onto PATH")
                  LUA
                  # env -u: the "the interpreter default survived" asserts only mean that if the
                  # builder hands nvim no LUA_PATH / LUA_CPATH of its own. Nothing sets them today,
                  # but the assert is about --set-default, so do not let the environment answer for it.
                  env -u LUA_PATH -u LUA_CPATH ${both.wrapped}/bin/nvim --clean -l rocks.lua

                  # --prefix, not --set: a LUA_PATH the user already exports has to survive.
                  cat > user.lua <<'LUA'
                  assert(package.path:find("/user/?.lua", 1, true), "an exported LUA_PATH was clobbered: " .. package.path)
                  assert(package.cpath:find("/user/?.so", 1, true), "an exported LUA_CPATH was clobbered: " .. package.cpath)
                  LUA
                  LUA_PATH='/user/?.lua' LUA_CPATH='/user/?.so' ${both.wrapped}/bin/nvim --clean -l user.lua

                  # Negative control: the same rock must not resolve without the option.
                  cat > norocks.lua <<'LUA'
                  assert(not pcall(require, "inspect"), "inspect resolved with no extraLuaPackages")
                  assert(vim.fn.executable("hello") == 1, "extraPackages did not reach PATH")
                  LUA
                  env -u LUA_PATH -u LUA_CPATH ${onlyPath.wrapped}/bin/nvim --clean -l norocks.lua

                  # The hm module really hands the option to makeEnv (see moduleWrapped above).
                  cat > module.lua <<'LUA'
                  assert(require("inspect"), "the hm module did not pass extraLuaPackages through")
                  LUA
                  ${moduleWrapped}/bin/nvim --clean -l module.lua

                  touch $out
                ''
              else
                ''
                  ${lib.concatMapStringsSep "\n" (f: "echo ${lib.escapeShellArg f} >&2") failures}
                  exit 1
                ''
            );
```

**実装上の注意:**

- `grep` の否定は **`! grep ...` と書かない**。`set -e` は `!` 付きパイプラインを無視するので、
  一致してしまっても build が落ちない。上のように `if grep -q ...; then ... exit 1; fi` にする
  (既存 check が `test ! -e` を使っているのと同じ理由)。
- ヒアドキュメントは `<<'LUA'`(クォート付き)にする。`$` や `\` を含む Lua を shell に展開させない。
  `runCommand` の中の `''` 文字列なので、Nix 側の `''${` エスケープが必要になる書き方は避ける。
- `nvim --clean -l <script>` を使う。`--clean` はユーザ設定を読まず、`-l` は assert 失敗を
  非ゼロ終了に変える。wrapper が `--add-flags "--cmd 'luafile <bootstrap>'"` を前置しても
  `-l` と共存することは**直接の実測で確認済み**である。`checks.build-registry`(`flake.nix:852`)も
  `nvim --clean ... -l` という同じ形を使っているが、**そちらが叩くのは nativeBuildInputs 由来の
  素の(ラップされていない)nvim** である —— ラップ済み nvim を `-l` で回す check はリポジトリに
  今のところ 1 つも無いので、これは前例ではなく本件が初出である。
- `nativeBuildInputs` は空でよい。neovim は wrapper の絶対パスで呼ぶ。
  **`pkgs.neovim-unwrapped` を `nativeBuildInputs` に足さないこと** —— `executable("luajit") == 0` の
  assert が意味を持つのは、builder の PATH に Lua interpreter が居ないからである。

### 5.2 `checks.hm-module-lua-packages`(新設)

`flake.nix:263` の直後(= `hm-module-dev` の直後、`wrapper-aliases` のコメントの直前)に挿入:

```nix
          # extraLuaPackages through the module's option type (functionTo (listOf package)), which
          # the lib-level check bypasses, and all the way to an activation package -- so the rock
          # env is part of a real home-manager build, not just of a wrapper built in isolation.
          # Uses the same basic-config lock hm-module already builds, so it adds no fetch of its own.
          hm-module-lua-packages = mkHmCheck {
            configDir = ./tests/fixtures/basic-config;
            lockDir = ./tests/fixtures/basic-config/nvimx-lock;
            extraPackages = [ pkgs.hello ];
            extraLuaPackages = ps: [ ps.inspect ];
          };
```

**これを足すのは意識的な判断である(issue は "covered by a check" しか要求していない)。**
`extra-lua-packages` の `moduleWrapped` とカバー範囲は大きく重なる —— どちらもモジュールを経由し、
どちらも `env.wrapped` に到達する。**固有のカバー範囲は「実 lock + activationPackage の完成まで」**、
すなわち `moduleWrapped` が意図的に踏まない部分(`.config.programs.nvimx.env.wrapped` だけを読み、
`home.packages` / `xdg.configFile` / `xdg.dataFile` の組み立ては見ない)である。
これは `hm-module-dev` が `checks.dev-plugins` の `moduleDevDirs` と並存している理由とまったく同じであり、
`hm-module-*` ファミリの既存の慣習に従う。**重複を理由に落とさない。**

**受け入れるコスト**: この check は **home-manager の generation を丸ごと 1 つビルドする**ので、
**両システムの CI 実行ごとに**その分の時間がかかる。`hm-module-*` は本件で 5 件から 6 件になる。
issue の "Done when" は "covered by a check"(単数)しか要求していないので、これは
**要求より 1 件多い**。それでも足すのは上の固有カバレッジのためであり、
「モジュール経由の型検査は `moduleWrapped` が見ているから十分」と判断したら落としてよい ——
そのときに失うものが何かは、この段落に書いてあるとおりである。

### 5.3 rock の選定根拠

| rock | 属性 | 種別 | require 名 | 理由 |
|---|---|---|---|---|
| `inspect` | `ps.inspect` | pure Lua | `"inspect"` | 3.1.3、**7.8 KiB download / 21.6 KiB unpacked**。`cache.nixos.org` にある。素の neovim では `require` が失敗する(§1.4(6))ので negative control が成立する |
| `luautf8` | `ps.luautf8` | C(`lib/lua/5.1/lua-utf8.so`) | `"lua-utf8"` | 小さな C 拡張。`LUA_CPATH` を実際に踏む唯一の手段。x86_64-linux / aarch64-darwin ともにキャッシュ済み |

**`lpeg` を選んではならない。** neovim が同梱・preload しているので `LUA_CPATH` が空でも
`require("lpeg")` が成功し、テストが空回りする(§1.4(6) で実測)。
`lua-cjson` / `luaposix` でも代用可能だが、`luautf8` の方が小さい。

`pkgs.hello` を `extraPackages` 側に使うのは、常にキャッシュ済みで最小だからである
(README の例は `ripgrep` だが、check にビルド時間を持ち込む理由が無い)。

**既知のカバレッジ欠落**: `inspect` も `luautf8` も **`requiredLuaModules` を持たない**ので、
§3.3 の 1 が言う「`withPackages` は依存 rock まで引き込む」という性質は**この check では検証されない**
(`lua.withPackages (_: luaPackages)` を素の `symlinkJoin` に差し替えても緑のままである)。
**依存を持つ重い rock を、それだけのために足すことはしない** —— check のビルド時間の方が高くつく。
`withPackages` は nixpkgs の neovim wrapper と同じ作法だから使うのであり、その一点は
レビューで担保する。

**同じ性質のカバレッジ欠落があと 2 つある。どちらも意識的に受け入れる:**

- **(b) rock のパスが interpreter 既定値より「前」に来ることは固定されていない。**
  `--prefix` を `--suffix` に取り違えても `require("inspect")` は成功する(既定パス上に
  同名モジュールが無いため)。順序が効くのは「rock と同名のモジュールが既定パスにもある」ときだけで、
  それを作るには `/usr/local/share/lua/5.1/` に置くか偽の interpreter を用意するしかなく、
  サンドボックスの中では割に合わない。§1.4(4) の実測(rock 2 件が先頭に来る)と
  §4.1 のコメントで担保する。
- **(c) 「2 つのモジュールが別々に rock を足すとリストが連結される」という README の約束に
  check が無い。** `types.functionTo` のマージ意味論に乗っているだけで、pinned nixpkgs では
  実測済み(§1.3(a))だが、**README に書いた時点でこれは API の約束になった**。
  `lib.evalModules` を回す小さな check を足すことは可能だが、守っているのは nixpkgs 側の
  型の性質であって nvimx のコードではないので、本件では足さない。
  nixpkgs 更新でここが壊れた場合、気づくのは README を信じたユーザである。

### 5.4 `checks.resolve-build-warnings` の golden 更新(§4.4 に対応)

§4.4 で rockspec の警告文が 1 節伸びる。既存 assert はすべて無変更で通るので、
**足すのは 2 本だけ**である。`build-steps-config` 側のブロック(`flake.nix:1416-1422`)、
`grep -q 'plugin "rockspec-build.nvim"' steps.log`(`:1421`)を次で置き換える:

```sh
                # #27: the rockspec warning has to name the cure, the way the nvim-treesitter one
                # already does. Pinned verbatim -- this is a shipped message, and the whole point
                # is that it says where to go. (build_warning's scalar wording is pinned the same
                # way in the unbuildable-config block above.)
                grep -q '^\[nvimx\] warning: plugin "rockspec-build.nvim": build is a luarocks build ("rockspec") and cannot be run at build time\. nvimx never runs luarocks -- add the rock with programs.nvimx.extraLuaPackages instead$' steps.log
                # ... and only that shape gets it: a *.lua build has no rock to add, so pointing it
                # at extraLuaPackages would be wrong.
                if grep -q 'plugin "luafile-build.nvim".*extraLuaPackages' steps.log; then
                  echo "the extraLuaPackages pointer must be specific to rockspec builds" >&2
                  exit 1
                fi
```

**変更しない既存 assert**(通ることを確認すること):

- `:1332-1333` —— `unbuildable-config` の scalar 文言 2 本。どちらも rockspec でも nvim-treesitter
  でもないので `build_pointer` は `""` を返す。**`nvim-treesitter` の excmd 警告には
  grammars pointer が付く**が、その assert(`:1344`)は `grep -q 'programs.nvimx.treesitter.grammars'`
  であって文言全体を見ていないので影響なし。
- `:1431` の `.warnings[3] | startswith("plugin \"rockspec-build.nvim\"")` —— 先頭は変わらない。
- `.warnings | length == 4`(`:1427`)—— 警告の**本数**は変わらない。

**フィクスチャは触らない。** `tests/fixtures/build-steps-config/init.lua` には
**scalar の `build = "rockspec"` はあるが、`rockspec` 要素を含む `steps` 形式は無い**。
`build_pointer` は `has_rockspec` 経由で `steps` 形式も拾う(§4.4)ので実装としては対応済みだが、
**その経路にはフィクスチャが無い** —— 意識的な判断である。足すには fixture にプラグインを 1 つ増やし、
`.warnings | length == 4` と `.warnings[N]` のインデックス群を全部ずらす必要があり、
「警告文 1 節」に対して golden の揺さぶりが釣り合わない。scalar 経路が緑なら
`has_rockspec` の `steps` 分岐は 3 行のループでしかない。

### 5.5 既存 checks への影響

- **`nix/lib/wrapper.nix` の変更は rock 無しのとき「生成される wrapper スクリプト」を 1 バイトも変えない**
  (§4.1 末尾の実測。`bin/nvim` を store path 正規化して diff すると差分ゼロ)。
  **ただし derivation ハッシュは変わる。** `--prefix PATH` の行に `\` を足し `${luaWrapperArgs}` の行を
  増やすので `postBuild` の文字列自体が変わり、rock を要求していなくても新しい drv になる。実測:

  | 対象 | before | after |
  |---|---|---|
  | wrapper の outPath | `…vqsjahb005paj386…` | `…919n34nslh8by9id…` |
  | `checks.wrapper-aliases` の drvPath | `w1dd9lxa…` | `w1pcxdnr…` |
  | `checks.hm-module` の drvPath | `g9sgn6pg…` | `jnki1s58…` |

  したがって `wrapper-aliases` / `hm-module*` / `build-shell` / `dev-plugins` / `treesitter-grammars` /
  `packages.demo` —— wrapper を含むものはすべて**一度だけ再ビルドされる**。これは想定内かつ無害である
  (中身が同じスクリプトを作り直すだけで、プラグイン derivation も farm も fetch も再利用される)。
  **実装後に再ビルドが走っても異常ではない。** G2 が主張しているのは
  「derivation が不変」ではなく「**生成されるスクリプトが不変**」であり、それを固定するのは
  §6 手順 5 の `diff` である。
- `make-env.nix` / `home-manager/default.nix` の変更は formals と `inherit` の追加だけで、
  既存の呼び出し結果を変えない。
- **lua 側で変わるのは `resolve.lua` の警告文だけ**である(§4.4)。影響を受ける check は
  **`resolve-build-warnings` 1 件のみ**で、そこには §5.4 で assert を足す。実測で確認済み:
  `rockspec` を含むフィクスチャは `tests/fixtures/build-steps-config/init.lua` **1 つだけ**であり、
  それを使うのは `resolve-build-warnings`(`flake.nix:1370`)だけである。
  コミット済みの `tests/fixtures/*/nvimx-lock/plugins.json` は**全件 `"warnings": []`** なので、
  `hm-module*` / `build-shell` / `dev-plugins` 等が読む lock は動かない。
  `extractor-*` は `resolve.lua` を通らないので無関係。他の `resolve-*` / `update-*` については、
  **文言が動きうるのは rockspec を含む build だけ**である —— `nvim-treesitter` の節は
  `build_pointer` に切り出したあとも 1 文字も変わらず、それ以外は `""` を返す(§4.4)。
  したがって「rockspec を含むフィクスチャが 1 つだけ」という上の事実だけで、影響範囲は閉じている。

### 5.6 CI / darwin

- CI は `.github/workflows/check.yml` が `nix flake check` と `nix fmt -- --ci` を回すだけなので、
  **ワークフローの変更は不要**である。
- ローカル(linux)の `nix flake check` は darwin を omit するので、CLAUDE.md の規約どおり
  評価だけを別途確認する(§6 手順 4)。**計画作成時点で、必要な部品が aarch64-darwin で
  評価できることは実測済み**:

  ```
  neovim-unwrapped.lua.name          = "luajit-2.1.1774638290"
  neovim-unwrapped.lua.luaversion    = "5.1"
  lua.pkgs.luaLib.luaCPathList       = [ "lib/lua/5.1/?.so" ]   ← darwin でも .so
  lua.pkgs.inspect.drvPath           = 評価成功
  lua.pkgs.luautf8.drvPath           = 評価成功
  (lua.withPackages (ps: [ ... ])).drvPath = 評価成功
  ```

  ただし `checks.aarch64-darwin.extra-lua-packages` は **linux では実行できない**(runtime 半分が
  darwin バイナリを走らせる)。CI の darwin ジョブが実際に走らせる。

## 6. 検証手順(実装完了時に必ず全部通す)

```bash
cd /home/myuron/ghq/github.com/myuron/nvimx

# 1. 整形 + lint(treefmt: nixfmt / stylua / luacheck)。lua は 1 行も変えていないので実質 nixfmt。
nix fmt -- --ci

# 2. 新 check だけを先に回す(速いループ用)
nix build .#checks.x86_64-linux.extra-lua-packages -L
nix build .#checks.x86_64-linux.hm-module-lua-packages -L

# 3. フルチェック(linux)
nix flake check -L

# 4. darwin 評価。ローカル linux の flake check は darwin を omit する(CLAUDE.md)
nix eval .#checks.aarch64-darwin.extra-lua-packages.drvPath
nix eval .#checks.aarch64-darwin.hm-module-lua-packages.drvPath
nix eval .#checks.aarch64-darwin.wrapper-aliases.drvPath

# 5. G2(rock 無しなら生成されるスクリプトが今日とバイト同一)を目視でも確認する。
#    drv ハッシュは変わる(§5.5)。ここで見るのは bin/nvim の中身だけである。
#    実装前の wrapper を先に取っておき、実装後と比べる。store path だけが違うことを確認する。
#    (手順の性質上、実装に着手する前に BEFORE を取っておくこと。)
#      git stash && nix build --impure --expr '<makeEnv ... lockDir=no-such-lock>.wrapped' -o /tmp/before
#      git stash pop
nix build --impure --expr 'let f = builtins.getFlake (toString ./.); p = f.inputs.nixpkgs.legacyPackages.x86_64-linux;
  in (f.lib.x86_64-linux.makeEnv { package = p.neovim-unwrapped;
       lockDir = ./tests/fixtures/basic-config/no-such-lock; }).wrapped' -o /tmp/after
# LUA_ という文字列が 1 度も現れないこと
grep -c LUA_ /tmp/after/bin/nvim || echo "no LUA_ (expected)"
diff <(sed "s|$(readlink -f /tmp/before)|OUT|g" /tmp/before/bin/nvim) \
     <(sed "s|$(readlink -f /tmp/after)|OUT|g" /tmp/after/bin/nvim) && echo "identical to today's wrapper"

# 6. G4 の手動確認(check でも見ているが、目で見ておく価値がある)
nix build --impure --expr 'let f = builtins.getFlake (toString ./.); p = f.inputs.nixpkgs.legacyPackages.x86_64-linux;
  in (f.lib.x86_64-linux.makeEnv { package = p.neovim-unwrapped;
       lockDir = ./tests/fixtures/basic-config/no-such-lock;
       extraLuaPackages = ps: [ ps.inspect ps.luautf8 ]; }).wrapped' -o /tmp/rocks
env -u LUA_PATH HOME=$(mktemp -d) /tmp/rocks/bin/nvim --clean --headless \
  -c 'lua print(package.path); print(package.cpath); print(require("inspect")({1,2}))' +qa
# rock の 2 エントリが先頭、その後ろに LuaJIT 既定値、末尾に空要素、が期待値

# 7. lua 側の変更が resolve.lua 1 ファイルに閉じていること(§4.8)
git diff --name-only -- lua/          # → lua/nvimx/resolve.lua の 1 行だけ
# その中身も build_warning 周辺だけであること(分類器 classify_step は触っていない)
git diff -- lua/nvimx/resolve.lua | grep -c '^[-+]' # 目視: build_pointer / has_rockspec / 2 箇所の return のみ

# 7b. #36 からの申し送りが返却されたこと(§3.6 / §4.4 / §5.4)。
#     lock を回したユーザが実際に見る文言なので、check だけでなく目でも一度見る。
nix build .#checks.x86_64-linux.resolve-build-warnings -L

# 8. ドキュメントのアンカーが生きていること
grep -c '(#lua-rocks)' README.md          # → 3(Options 表 1 + §4.6(d-1) 1 + §4.6(d-2) 1)
grep -n '^### Lua rocks' README.md        # → 1 件
# 行番号は書かない。§4.7 の編集 3 が :171 を 2 行にするので、それ以降は全体が +1 ずれる。
grep -c 'extraLuaPackages' docs/architecture.md            # → 6(設計原則 4 / build フロー / モジュール例 / edge-case 表 2 行 / phase 7)
grep -c 'extra-lua-packages\|hm-module-lua-packages' docs/architecture.md  # → 1(checks の列挙)
grep -c 'LUA_PATH' docs/architecture.md   # → 6(mermaid / 設計原則 4 / build フロー / モジュール例 / ファイル一覧 / edge-case 表)
```

## 7. リスク / 未決事項

### R1: `LUA_PATH` / `LUA_CPATH` が子プロセスに継承される

wrapper は環境変数を **export** するので、nvim から起動されるすべての子プロセス
(`:terminal` のシェル、LSP サーバ、`:!` で叩くコマンド)がこれを見る。
Lua で書かれた子プロセス(`lua-language-server` は C++ なので該当しないが、`busted` や
自作の Lua スクリプトは該当する)は nvim 用の rock env を先に見ることになる。

これは deprecated な `neovim/utils.nix:157-166` と同じ性質であり、現行 nixpkgs が
`package.path` 方式に移った理由の 1 つでもある(§1.3(d))。本計画は issue の指示に従って
環境変数方式を採るので、この副作用は**受け入れる**。緩和材料:

- **オプトインでしか起きない。** `extraLuaPackages` を設定しないユーザには変数自体が存在しない。
- `--set-default ';;'` により、子プロセスから見ても「rock env が先、その後ろに interpreter の既定値」
  という素直な形になる。既定値を失った状態は伝播しない。

**もしこの副作用が実運用で問題になったら**、`bootstrap.lua` 側で `package.path` を前置する
方式(§3.4(A))への移行が退路である。オプションの型と意味は変わらないので、
`wrapper.nix` と `bootstrap.nix` の内部だけの変更で済む。

### R2: C rock の ABI は interpreter に固定される

`LUA_CPATH` に載る `.so` は `package.lua` に対してビルドされている。R1 により
別の Lua interpreter の子プロセスがそれを `require` すると、ロードエラーになる可能性がある。
§3.2 のとおり「nvim にとって正しい interpreter」を選ぶことを優先し、この可能性は許容する。

### R3: ユーザが `;;` を含まない `LUA_PATH` を export している環境

`--set-default` は `${VAR-...}`(**未設定**のみ)なので、**設定済みなら値が何であれ発火しない**。
該当するのは 2 通りで、どちらも「既定値は復活しない」:

- **`LUA_PATH=""`(空文字)**: `--prefix` の結果は rock のパスだけになる。
- **`LUA_PATH=/x/?.lua`(`;;` 無し)**: 結果は `<rock1>;<rock2>;/x/?.lua` になり、LuaJIT の既定値は入らない。
  実測済み。**`checks.extra-lua-packages` の `user.lua` ケースがまさにこの形である** ——
  あの assert が言っているのは「ユーザのエントリが残る」ことだけであり、
  **「そのケースで既定値が保存される」ことは主張していない**。読み違えないこと。

いずれも**素の Lua がまったく同じ挙動をする** —— `;;` を書かない `LUA_PATH` は Lua の仕様として
「既定値なし」を意味する。そのユーザは nvimx が無くても同じ状態にあり、nvimx が新たに奪ったものは
何も無い(§1.4(2) の表)。退行ではないと判断し、対処しない。
`--set-default` が救うのは「`LUA_PATH` を一度も設定していない」大多数のケースであり、そこが本丸である。

### R4: `--prefix` の重複除去

makeWrapper の `--prefix` は同じ要素が既にある場合に取り除いてから前置する
(`${LUA_PATH/';'X';'/';'}`)。ユーザが偶然まったく同じ store path を `LUA_PATH` に入れている場合、
重複が消えるだけで意味は変わらない。無害。

### R5: rock env の `bin/` が PATH に載っていないことの保証

§5.1 の `vim.fn.executable("luajit") == 0` は「builder の PATH に Lua interpreter が居ない」ことに
依存している。将来この check の `nativeBuildInputs` に neovim や lua を足すと、この assert は
**偽陽性ではなく偽陰性**(常に通る)になる。check 内のコメントでその旨を明示してある(§5.1)。

### R6: `defaultText` を忘れると評価は通るが option ドキュメントで壊れる

`default` が関数なので `defaultText` は必須である(§3.1)。`nix flake check` は通ってしまうため、
**レビューで目視確認すること**。home-manager が同じ理由で `literalExpression "ps: [ ]"` を置いている。

### R7: `postBuild` の行継続

§3.3 の 6 と §4.1 の注意点のとおり、`--prefix PATH` の行に `\` を足し、最終行には足さない。
両方が空のときに次行の `ln -s` を吸い込む事故が唯一の失敗モードであり、
`checks.wrapper-aliases`(`vimAlias` / `viAlias` の symlink を見る)がそれを検知する ——
ただし `wrapper-aliases` は `extraPackages` も `extraLuaPackages` も設定しない env で走るので、
**まさに「両方が空」のケースを踏んでいる**。既存 check がそのまま守り手になる。

### R8: nixpkgs 側の `luaLib` / passthru の変化

`genLuaPathAbsStr` / `genLuaCPathAbsStr` / `passthru.lua` はいずれも nixpkgs の
neovim wrapper 自身が依存している API であり、消えれば nixpkgs の neovim も同時に壊れる。
自前でパスを組み立てるより追随コストが低いと判断する。

### R9: nixpkgs に無い rock

関数の引数はパッケージセットに過ぎないので、`_: [ myRock ]` で自前の
`buildLuarocksPackage` 由来 derivation を渡せる。README にその一文を入れてある(§4.6(c))。
専用のオプションは作らない。
