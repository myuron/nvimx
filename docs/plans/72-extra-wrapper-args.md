# #72 対応計画: `extraWrapperArgs` による wrapper 引数の追加

対象 issue: [#72 feat(hm): add extraWrapperArgs for the wrapped neovim](https://github.com/myuron/nvimx/issues/72)

本計画の `file:line` は**現在の作業ツリー(`6e0ebe3`、ブランチ `feat/extra-wrapper-args`)基準で
全件を実ファイルで確認済み**である。nixpkgs / home-manager 側の行番号は `flake.lock` が固定している
input の実ファイルからの引用である(nixpkgs → `/nix/store/5ljrgyqskjl8g5kxm88a8gl8251m801x-source`、
home-manager → `/nix/store/fm93mv69y0ify036r6zgnhqy1chw3vd0-source`。
`nix eval --raw --impure --expr '(builtins.getFlake (toString ./.)).inputs.nixpkgs.outPath'` で確認)。

**§5 と §6 のコードは「貼れば通る」ことを確認済みである。** 計画作成時に、リポジトリを
`git archive HEAD` で scratch ディレクトリへ写し、そこに §5 の全変更(nix 3 ファイル + `flake.nix` の
check 2 件 + README + architecture.md)を当てたうえで次を実行した。リポジトリ本体は計画ファイル以外
1 バイトも変更していない。

| 実行したもの | 結果 |
|---|---|
| `nix fmt -- --ci` | exit 0(`formatted 51 files (0 changed)`)。§5 / §6 のスニペットは nixfmt 正規形である |
| `nix build …#checks.x86_64-linux.extra-wrapper-args` | 緑 |
| `nix build …#checks.x86_64-linux.hm-module-wrapper-args` | 緑 |
| `nix flake check`(x86_64-linux、check 37 件 = 既存 35 + 新設 2) | `all checks passed!` |
| `nix eval …#checks.aarch64-darwin.{extra-wrapper-args,hm-module-wrapper-args,wrapper-aliases,extra-lua-packages}.drvPath` | 4 件とも評価成功 |
| §6.3 の mutation 10 通り | 10 通りとも赤 |

設計はユーザーと合意済みであり(名前 / 型 / `escapeShellArgs` / 位置は nvimx の引数の後ろ / 保護なし /
`makeEnv` の返り値は増やさない / attrset 版は見送り)、**本計画はそのどれも覆していない**。
合意の範囲内で計画側が決めたことは 3 点で、理由はそれぞれの節に書いてある:
`extraWrapperArgs = [ ]` のとき drv ハッシュまで不変にする書き方(§3.2)、
`--set PATH` が勝つことを check で固定すること(§6.1 の `overridden`、範囲は §7 R6)、
README に注意点を 3 つ書くこと(§5.5)。

## 1. 背景 / 現状

### 1.1 現在の wrapper(`nix/lib/wrapper.nix`、全 59 行)

formal は `:3-10`、`wrapProgram` は `:51-58` である(逐語):

```nix
3  {
4    package,
5    bootstrap,
6    extraPackages ? [ ],
7    extraLuaPackages ? (_: [ ]),
8    vimAlias ? false,
9    viAlias ? false,
10 }:
```

```nix
51   postBuild = ''
52     wrapProgram $out/bin/nvim \
53       --add-flags "--cmd 'luafile ${bootstrap}'" \
54       ${lib.optionalString (extraPackages != [ ]) "--prefix PATH : ${lib.makeBinPath extraPackages}"} \
55       ${luaWrapperArgs}
56     ${lib.optionalString vimAlias "ln -s $out/bin/nvim $out/bin/vim"}
57     ${lib.optionalString viAlias "ln -s $out/bin/nvim $out/bin/vi"}
58   '';
```

- 引数は 3 群で、順に `--add-flags`(`:53`)、`--prefix PATH`(`:54`)、`luaWrapperArgs`(`:55`、
  定義は `:38-45`)である。
- `:53-54` は素の文字列補間である。`:54` の `${lib.makeBinPath extraPackages}` は裸だが、store path には
  空白も `;` も glob 文字も入らないので成立している。`luaWrapperArgs` は値に `;` と `?` を含むので
  `lib.escapeShellArg` を通している(`:42-43`)。formal(`:3-10`)に自由な文字列を取るものは無く、
  本件が最初である。
- 最後の継続行 `:55` には `\` が無い。#27 計画の R7 が記録しているとおり、ここに `\` を付けると
  `luaWrapperArgs` が空のとき次行の `ln -s` を吸い込む。

オプションとしては、ユーザーがこの `wrapProgram` に引数を足す手段は無い。issue が挙げている経路は
`programs.nvimx.env` を丸ごと差し替えること(`nix/home-manager/default.nix:293-303` の escape hatch)で、
それは `makeEnv` の再実装を意味する。

### 1.2 オプションが wrapper に届くまでの経路

`nix/home-manager/default.nix:340-355`:

```nix
340    programs.nvimx.env = lib.mkDefault (
341      nvimxLib.makeEnv {
342        inherit (cfg)
343          package
344          lockDir
345          extraPackages
346          extraLuaPackages
347          vimAlias
348          viAlias
349          plugins
350          treesitter
351          devPlugins
352          devPath
353          ;
354      }
355    );
```

`nix/lib/make-env.nix:136-145`:

```nix
136  wrapped = mkWrapper {
137    inherit
138      package
139      bootstrap
140      extraPackages
141      extraLuaPackages
142      vimAlias
143      viAlias
144      ;
145  };
```

`make-env.nix` の formal は `:6-25`(`extraLuaPackages ? (_: [ ]),` が `:13`、その説明コメントが
`:10-12`)で、`...` は無い。`wrapper.nix` の formal にも `...` は無い。返り値は `:147-159` の 9 属性で、
**`extraPackages` / `extraLuaPackages` に対応する出力は無い**(#27 計画 §3.4(E))。

この経路の性質は #26 / #27 が記録したものと同じである:

- formal を**宣言せずに**渡すと評価エラーになる(`...` が無いので)。計画作成時に実測:
  `error: function 'anonymous lambda' called with unexpected argument 'extraWrapperArgs'`。
- formal は既定値付きなので、**渡し忘れは常に黙って既定値に落ちる**。`inherit (cfg)` から 1 語落としても
  型検査は通り、ビルドも通り、オプションは無視される。

### 1.3 home-manager / nixpkgs 側の前例(pinned input で実読)

**(a) home-manager のオプション** —— `modules/programs/neovim/default.nix:223-243`
(`example` の中身 `:227-236` は `# ...` で省略):

```nix
      extraWrapperArgs = mkOption {
        type = types.listOf types.str;
        default = [ ];
        example = literalExpression ''
          # ...
        '';
        description = ''
          Extra arguments to be passed to the neovim wrapper.
          This option sets environment variables required for building and running binaries
          with external package managers like mason.nvim.
        '';
      };
```

型は `listOf str`、既定は `[ ]`。**合意済みの型と同一である。**

**(b) home-manager がそれを置く位置** —— 同ファイル `:508-513` と `:538`:

```nix
      extraMakeWrapperArgs = optionals (cfg.extraPackages != [ ]) [
        "--suffix"
        "PATH"
        ":"
        (lib.makeBinPath cfg.extraPackages)
      ];
```
```nix
          wrapperArgs = cfg.extraWrapperArgs ++ extraMakeWrapperArgs;
```

**ユーザーの引数が先、home-manager 自身の `--suffix PATH`(`extraPackages`)が後**である。
home-manager 自身もこのオプションを `--add-flags` の運搬に使っている(`:579-582`、`sideloadInitLua`)。

**(c) nixpkgs がそれをクォートして置く位置** —— `pkgs/applications/editors/neovim/wrapper.nix`
`:151` と `:336`、および `finalMakeWrapperArgs`(`:219-233`)の末尾:

```nix
        wrapperArgsStr = if lib.isString wrapperArgs then wrapperArgs else lib.escapeShellArgs wrapperArgs;
```
```nix
        ++ finalAttrs.generatedWrapperArgs;
```
```nix
            makeWrapper ${lib.escapeShellArgs finalMakeWrapperArgs} ${wrapperArgsStr}
```

リストなら **`lib.escapeShellArgs`** を通し、nixpkgs 自身が生成した引数
(`--set NVIM_SYSTEM_RPLUGIN_MANIFEST …` / provider 用の `--add-flags` など)の**後ろ**に置く。

**(d) nvimx の決定との差**

| | home-manager + nixpkgs | nvimx(本計画) |
|---|---|---|
| 型 | `listOf str` | 同じ |
| クォート | `lib.escapeShellArgs` | 同じ |
| ラッパー自身の生成引数との順 | 生成引数 → ユーザー | 同じ(nvimx の引数 → ユーザー) |
| `extraPackages` の PATH との順 | **ユーザー → `extraPackages`**(`:538`) | **`extraPackages` → ユーザー** |
| `extraPackages` の PATH の向き | `--suffix PATH` | `--prefix PATH`(`wrapper.nix:54`) |

差は下 2 行だけである。home-manager では `extraPackages` が最後に来るので、ユーザーの `--set PATH` は
`extraPackages` を消せない。nvimx ではユーザーが最後なので消せる。これは合意済みの
「ユーザーが最終決定権を持つ」の帰結であり、README とオプション説明に適用順を明記して埋める(§5.3 / §5.5)。
`--prefix` と `--suffix` の差は本件以前からのもので、**本件はそれを変えない** —— issue の言う
「`--prefix` でなく `--suffix PATH`」は、そのパッケージを `extraPackages` から外して
`extraWrapperArgs` に `--suffix` で書くことで実現する(README に書く。§5.5)。

### 1.4 実測: makeWrapper の挙動

すべて pinned nixpkgs の `makeWrapper`(shell 版。`pkgs/build-support/setup-hooks/make-wrapper.sh`)と
`neovim-unwrapped 0.12.4` で、**§5.1 の `wrapper.nix` そのもの**を使ってローカル実行した結果である。
実行は `env -i HOME=… PATH=/base/bin <wrapped>/bin/nvim --clean -l p.lua` の形。
出力中の store path のハッシュは `<store>` に置換し、長い行は折り返してある。

**根拠となる実装**(`make-wrapper.sh`):引数は `:123` の `for` で**先頭から順に**処理され、環境変数系は
その場で 1 ブロックずつ wrapper に追記される(`--set` は `:130` の
`echo "export $varName=${value@Q}"`、`--set-default` は `:135`)。フラグ系は `flagsBefore` に
**出現順に連結**され(`--add-flags` は `:179-182`)、最後に `:201-202` の `exec` 行 1 本にまとめて出る。

**(1) 引数順 = ブロック順。** `extraPackages = [ hello ]`、`extraLuaPackages = ps: [ ps.inspect ]`、
`extraWrapperArgs = [ "--set" "NVIMX_A" "1" "--suffix" "PATH" ":" "/user/suffix" "--prefix" "PATH" ":"
"/user/prefix" "--prefix" "LUA_PATH" ";" "/user/?.lua" "--add-flags" "--cmd 'lua …'" ]` で生成された
wrapper(各ブロックの中身を `# …` で省略。`# ←` は本計画の注記):

```sh
#! <store>/bash-5.3p15/bin/bash -e
PATH=${PATH:+':'$PATH':'}                 # ← nvimx: --prefix PATH (extraPackages)
# …
export PATH
export LUA_PATH=${LUA_PATH-';;'}          # ← nvimx: --set-default LUA_PATH ';;'
export LUA_CPATH=${LUA_CPATH-';;'}
LUA_PATH=${LUA_PATH:+';'$LUA_PATH';'}     # ← nvimx: --prefix LUA_PATH (rock env、2 要素ぶん)
# …
export LUA_CPATH
export NVIMX_A='1'                        # ← ここから下がユーザーの引数。書いた順に並ぶ
PATH=${PATH:+':'$PATH':'}
if [[ $PATH != *':''/user/suffix'':'* ]]; then
    PATH=$PATH'/user/suffix'
fi
# …
PATH='/user/prefix'$PATH
# …
LUA_PATH='/user/?.lua'$LUA_PATH
# …
exec -a "$0" "<store>/nvimx-neovim/bin/.nvim-wrapped"  --cmd 'luafile <store>/nvimx-bootstrap.lua' --cmd 'lua vim.g.nvimx_user_cmd = (package.preload.lazy ~= nil)' "$@"
```

**(2) nvimx の `--prefix PATH` の後ろに置いた `--prefix PATH` / `--suffix PATH`。** 上の wrapper の実行結果:

```
PATH="/user/prefix:<store>/hello-2.12.3/bin:/base/bin:/user/suffix"
```

ユーザーの `--prefix` は `extraPackages` の**前**に、`--suffix` は起動時の PATH の**後ろ**に入る。
`extraPackages` は無傷で残る(`vim.fn.executable("hello") == 1`)。

**(3) nvimx の `--prefix PATH` の後ろに置いた `--set PATH`。**
`extraPackages = [ hello ]` + `extraWrapperArgs = [ "--set" "PATH" "/only/this" ]`:

```sh
# … nvimx の --prefix PATH ブロック …
export PATH
export PATH='/only/this'
```
```
PATH="/only/this"      executable("hello") == 0
```

**`extraPackages` ごと消える。** 合意済みの「保護しない」の実際の姿である。

**(4) `--set-default LUA_PATH ';;'` の後ろに置いた `--prefix LUA_PATH`。** (1) の wrapper の実行結果:

```
LUA_PATH="/user/?.lua;<rock env>/share/lua/5.1/?.lua;<rock env>/share/lua/5.1/?/init.lua;;;"
package.path=/user/?.lua;<rock 2 件>;./?.lua;<luajit>/share/luajit-2.1/?.lua;…(LuaJIT 既定値)…;;
require("inspect") → 成功    require("jit.dump") → 成功
```

ユーザーのエントリが先頭、rock が続き、**`;;` も既定値も生き残る**。後ろに置くぶんには nvimx の
`--set-default` の仕掛けを壊さない。

これは起動時に `LUA_PATH` が未設定の場合である。同じ wrapper を `LUA_PATH='/sh/?.lua'`(`;;` なし)で
起動すると `package.path` は `/user/?.lua;<rock 2 件>;/sh/?.lua` で、`;;` も既定値も入らない
(nvimx の引数は `--set-default` なので発火しない。#27 計画 R3 と同じ性質)。README の箇条書き 2 は
この条件を書いてある(§5.5)。

`--suffix LUA_PATH ';' '/user/?.lua'` にした場合は `LUA_PATH="<rock 2 件>;;;;/user/?.lua"` になり、
`;;` が 2 回現れるので **`package.path` に LuaJIT 既定値が 2 回展開される**(rock → 既定値 → 既定値 →
`/user/?.lua`)。重複するだけで無害。`require("inspect")` も `require("jit.dump")` も成功する。

**(5) `--set-default LUA_PATH ';;'` の後ろに置いた `--set LUA_PATH`。**
`extraLuaPackages = ps: [ ps.inspect ps.luautf8 ]` + `extraWrapperArgs = [ "--set" "LUA_PATH" "/user/?.lua" ]`:

```
LUA_PATH="/user/?.lua"
package.path=/user/?.lua
LUA_CPATH="<rock env>/lib/lua/5.1/?.so;;;"
require("inspect") → 失敗    require("jit.dump") → 失敗    require("lua-utf8") → 成功
```

**消えるのは `LUA_PATH` 側だけである**: pure-Lua の rock(`inspect`)と、LuaJIT 既定の `package.path`
(`jit.dump`)。`LUA_CPATH` は別の変数なので、C rock(`lua-utf8`)は読めるままである。
neovim 自体は起動する
(`package.preload.lazy` は残る —— `vim.*` と rtp は `package.path` を使わない。#27 計画 §1.4(1))。
合意済みの「`--set LUA_PATH` で `;;` の仕掛けを潰せる」の実際の姿である。

**(6) ★ `extraLuaPackages` を使わずに `--prefix LUA_PATH` だけを書くと、既定値が消える。**
`extraWrapperArgs = [ "--prefix" "LUA_PATH" ";" "/user/?.lua" ]` のみ:

```
LUA_PATH="/user/?.lua"
package.path=/user/?.lua
require("jit.dump") → 失敗
```

nvimx の `--set-default ';;'` は rock があるときしか出ない(`wrapper.nix:38`)ので、ユーザーが
手で `LUA_PATH` を足すと #27 計画 §1.4(2) の罠をそのまま踏む。**nvimx の退行ではなく Lua の仕様だが、
このオプションで最初に踏みそうな穴**なので README に書く(§5.5)。回避は実測済み:

```
extraWrapperArgs = [ "--set-default" "LUA_PATH" ";;" "--prefix" "LUA_PATH" ";" "/user/?.lua" ]
→ package.path=/user/?.lua;./?.lua;…(LuaJIT 既定値)…;;      require("jit.dump") → 成功
```

`LUA_CPATH` も同じ規則であることを 1 点だけ実測した: rock ありの wrapper を `LUA_CPATH='/u/?.so'`
(`;;` なし)で起動すると `package.cpath` は `<rock env>/lib/lua/5.1/?.so;/u/?.so` で、既定値は入らない。

**(7) `--add-flags` は nvimx の `--cmd 'luafile …'` の後ろに並ぶ。** (1) の `exec` 行のとおり、
`flagsBefore` は出現順の連結なので `… --cmd 'luafile <bootstrap>' --cmd 'lua …' "$@"` になる。
neovim は `--cmd` を書かれた順に実行するので、ユーザーの `--cmd` が走る時点で
`bootstrap.lua` は済んでいる。(1) の wrapper での実測:

```
g.nvimx_user_cmd=true        ← package.preload.lazy ~= nil がユーザーの --cmd の中で真
```

`nvim --clean -l <script>` と併用しても、`--cmd` で立てた `vim.g.*` は `-l` のスクリプトから見える
(§6.1 の assert がこれに依存する)。

**(8) 空白・`;`・`$`・`'`・`"`・バックスラッシュ・バッククォート・`*`・改行を含む値は、
`escapeShellArgs` 経由でそのまま届く。**
下の Nix 文字列を `--set NVIMX_ESC` の値にしたときの、`lib.escapeShellArgs` の出力(別の短い値で)・
生成された wrapper・実行結果:

```nix
extraWrapperArgs = [ "--set" "NVIMX_ESC" "a b;c$HOME'd\"e\\f `id` * #x\nline2" "--set" "NVIMX_EMPTY" "" ];
```
```
lib.escapeShellArgs [ "--set" "A" "a b;c$HOME'd\"e" "" "--suffix" "PATH" ":" "/x/bin" ]
→ --set A 'a b;c$HOME'\''d"e' '' --suffix PATH : /x/bin
lib.escapeShellArgs [ ] → ""
```
```sh
export NVIMX_ESC=$'a b;c$HOME\'d"e\\f `id` * #x\nline2'
export NVIMX_EMPTY=''
```
```
NVIMX_ESC="a b;c$HOME'd\"e\\f `id` * #x\nline2"      ← vim.inspect(vim.env.NVIMX_ESC)。入力と一致
```

`$HOME` は展開されず、`` `id` `` は実行されず、`*` は glob されない。クォートは 2 段ある ——
ビルド時のシェルに対しては `lib.escapeShellArgs`、wrapper スクリプトに対しては makeWrapper 自身の
`${value@Q}`(`make-wrapper.sh:130`)—— ので、nvimx が受け持つのは前者だけでよい。

**(9) ★ `--add-flags` / `--append-flags` / `--run` の値は「シェルのテキスト」であり、起動のたびに
解釈される。** これは makeWrapper の仕様(`make-wrapper.sh:31` の `prepend ARGS verbatim to the
Bash-interpreted invocation`、`:32` の `append ARGS verbatim to …`、`:147` の `echo "$command"`)で
あって、`escapeShellArgs` では止まらない(止めてはならない)。**この 3 つで全部だとも言わない** ——
末尾の「それ以外」を参照。
`"--add-flags" "--cmd \"let g:nvimx_home = '$HOME'\""` を `HOME=/my/home` で起動した実測:

```sh
exec -a "$0" "…/.nvim-wrapped"  --cmd 'luafile …' --cmd "let g:nvimx_home = '$HOME'" "$@"
```
```
g.nvimx_home="/my/home"                ← 起動時に展開された
```

対して `--add-flag`(単数)は `${…@Q}` を通るのでリテラルである(`:171-174`)。
`"--add-flag" "--cmd" "--add-flag" "let g:nvimx_lit = '$HOME a  b'"` → `g.nvimx_lit="$HOME a  b"`。
`--run` はコマンド行がそのまま wrapper に書かれ、`--unset VAR` は `unset VAR` になる(どちらも実測)。

**`--append-flags` も `--add-flags` と同じ扱いである**(ハンドラ `:183-186` は
`flagsAfter="${flagsAfter-} $flags"` で `@Q` を通さない)。
`[ "--append-flags" "--cmd \"let g:nvimx_app = '$HOME'\"" "--append-flag" "--cmd" "--append-flag"
"let g:nvimx_applit = '$HOME'" ]` を `HOME=/my/home` で起動した実測:

```sh
exec -a "$0" "…/.nvim-wrapped"  --cmd 'luafile …' "$@"  --cmd "let g:nvimx_app = '$HOME'" '--cmd' 'let g:nvimx_applit = '\''$HOME'\'''
```
```
app="/my/home" applit="$HOME"          ← nvim --clean --headless -c 'lua …' +qa で起動
app=nil applit=nil                     ← nvim --clean -l q.lua で起動
```

複数形は起動時に展開され、単数形(`--append-flag`、`:175-178`)はリテラルである。
2 行目は別の性質で、**後置フラグは `"$@"` の後ろに付くので、`-l <script>` で起動すると neovim の
オプションではなくスクリプトの引数になる**。check が `-l` で起動する以上、後置フラグを assert の
材料にしてはならない(§6.1 は `--add-flags` しか使っていない)。

**それ以外(列挙を閉じないための記録)。** `--argv0 NAME` は `exec -a "$argv0"` と**二重引用符の中**に
書かれる(`:187-189`、`:201`)ので、これも起動時に展開される。実測:
`[ "--argv0" "$HOME/x" ]` → wrapper は `exec -a "$HOME/x" …`、`HOME=/my/home` で `vim.v.argv[1]` は
`/my/home/x`。また `--set` / `--set-default` / `--unset` / `--prefix` / `--suffix` の**変数名**は
クォートされずにスクリプトへ書かれる(`:130` の `echo "export $varName=…"`、`:139` の `echo "unset $varName"`)。
`--set` について実測: `[ "--set" "NVIMX_$(echo X)" "v" ]` → wrapper は `export NVIMX_$(echo X)='v'`、
起動すると `vim.env.NVIMX_X == "v"`(変数名の中のコマンド置換が起動時に走った)。
`--set-default` / `--unset` / `--prefix` / `--suffix` の変数名は同じ書き方だが個別には**未実測**。
**ユーザー向けの文面では `--argv0` と変数名を名指ししない**: 前者は neovim の wrapper で使う理由が
ほぼ無く、後者は変数名に `$` や空白を書く人がいない。3 つを挙げたうえで「some」と書き、
数を断定しないことで足りる(§5.3 / §5.5)。網羅表を nvimx の文書に持つと、§3.4 の理由 2 と同じく
makeWrapper のフラグ表の複製になる。

**(10) 壊れた引数列の失敗の仕方。**

| 入力 | 結果 |
|---|---|
| 未知のフラグ `[ "--frobnicate" "x" ]` | **wrapper のビルドが失敗**: `Builder called die: makeWrapper doesn't understand the arg --frobnicate` |
| 値の欠けた末尾 `[ "--set" "NVIMX_TRUNC" ]` | **黙ってビルドが通り**、`export NVIMX_TRUNC=''` が出る。`vimAlias` の symlink も作られる(次行は吸い込まれない) |

評価時ではなくビルド時に出る。nvimx は引数列を検証しない(§3.5(C))。

**(11) 空文字の環境変数は `vim.env` からは `nil` に見える。** (8) の `NVIMX_EMPTY=''` は wrapper には
出ているが `vim.inspect(vim.env.NVIMX_EMPTY)` は `nil` だった。neovim 側の性質で本件とは無関係だが、
**check の assert に空文字の値を使ってはならない**(届いていないのと区別できない)。

**(12) リスト型のマージ。** `lib.evalModules` で `listOf str` に 3 つのモジュールが
`[ "--set" "A" "1" ]` / `[ "--set" "B" "2" ]` / `lib.mkAfter [ "--set" "Z" "9" ]` を与えた結果:

```
[ "--set" "B" "2" "--set" "A" "1" "--set" "Z" "9" ]
```

定義は**丸ごと**連結されるので、1 つの定義の中の 3 つ組が割れることは無い。モジュール間の順は
記述順とは限らない(上では B が A より前)が、`lib.mkBefore` / `lib.mkAfter` は効く。
また `[ "--set" "A" pkgs.hello ]`(補間しない素のパッケージ)は `types.str` に弾かれる
(`tryEval` → `success = false`)。`"${pkgs.hello}"` と書けば通る。home-manager と同じ挙動である。

## 2. ゴール

- **G1(届く)**: `programs.nvimx.extraWrapperArgs = [ "--set" "X" "v" ]` を設定した neovim で
  `vim.env.X == "v"` になる。`checks.extra-wrapper-args` が実際に neovim を起動して証明する。
- **G2(そのまま届く)**: リストの 1 要素が `wrapProgram` の 1 引数になる。空白・`;`・`$`・`'`・`"`・`*` を
  含む値がバイト単位で保存される(§1.4(8))。
- **G3(最後に適用される)**: 適用順は「`--add-flags`(bootstrap)→ `--prefix PATH`(`extraPackages`)→
  `LUA_PATH` / `LUA_CPATH`(`extraLuaPackages`)→ `extraWrapperArgs`」である。3 つの境界それぞれを
  check が固定する。
- **G4(共存する)**: `extraPackages` / `extraLuaPackages` と同時に設定しても、1 回の `wrapProgram`
  呼び出しで 3 つとも生きる。
- **G5(既定は完全な no-op)**: `extraWrapperArgs = [ ]`(既定)のとき、`postBuild` の文字列が
  今日とバイト単位で同一であり、したがって **wrapper の drv ハッシュが変わらない**。
  既存 check 35 件と `packages.demo` の drvPath が変わらないことを計画作成時に実測済み(§3.2 / §6.5)。
- **G6(渡し忘れを検知する)**: hm モジュールが `inherit (cfg)` から落としたとき、check が赤になる。
  新オプションは `makeEnv` に専用の出力属性を持たず、`wrapped` を通してしか見えない。
  評価レベルで `wrapped.buildCommand` を文字列照合する手はある(引数列が載っていることは実測した)が、
  makeWrapper へ渡すクォートの形に依存するので採らず、**モジュール経由で作った wrapper を実際に
  走らせる**(§6.1 の `moduleWrapped`)。
- **G7(ドキュメント)**: オプション説明と README に適用順と「保護しない」が明記される。
  `docs/architecture.md` の設計原則 4 が、任意の wrapper 引数があっても偽にならない文面になる。
- **G8(新規の fetch を足さない)**: `extra-wrapper-args` は degraded モードで作るので
  プラグインソースの `fetchTree` が 1 つも起きない。`hm-module-wrapper-args` は `hm-module` が
  既に取得する basic-config の lock だけを使う。

## 3. 設計

### 3.1 オプション

```nix
    extraWrapperArgs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = lib.literalExpression ''…'';
      description = ''…'';
    };
```

- 名前・型・既定は合意どおりで、home-manager の `programs.neovim.extraWrapperArgs` と同一(§1.3(a))。
- `default = [ ]` は関数ではないので `defaultText` は不要(`extraPackages` と同じ)。
- `example` は `lib.literalExpression` にする。store path の補間を見せたいので、評価されるリストではなく
  文字列として書く(`extraPackages` の `example` と同じ流儀。全文は §5.3)。
- 宣言位置は `extraLuaPackages` の直後、`devPlugins` の直前。wrapper に効く 3 オプションを並べる。
  README の `## Options` 表はモジュールの宣言順を写しているので、表の行も同じ位置に入れる(§5.5)。

### 3.2 `wrapProgram` 末尾への足し方 —— drv ハッシュを動かさない

**決定**: 新しい継続行を足さず、最後の行に載っている `luaWrapperArgs` と**同じ行に連結**する。
空の側は区切りごと落とす。

```nix
  trailingWrapperArgs = lib.concatStringsSep " " (
    lib.filter (s: s != "") [
      luaWrapperArgs
      (lib.escapeShellArgs extraWrapperArgs)
    ]
  );
```
```nix
      ${lib.optionalString (extraPackages != [ ]) "--prefix PATH : ${lib.makeBinPath extraPackages}"} \
      ${trailingWrapperArgs}
```

`postBuild` の変更は `:55` の `${luaWrapperArgs}` → `${trailingWrapperArgs}` の **1 語だけ**である。

**なぜこの形か。** 素直に書けばこうなる:

```nix
      ${luaWrapperArgs} \
      ${lib.escapeShellArgs extraWrapperArgs}
```

これは動く(空行 + `\` の継続が POSIX シェルで正しく畳まれることは #27 計画 §3.3 が実測済み)が、
**`extraWrapperArgs` が空でも `postBuild` の文字列が変わる**(`\` と 1 行が増える)。すると rock も
引数も要求していないユーザーの wrapper まで新しい drv になり、それを含む出力が作り直される
(下の「対照」で実測)。#27 はこれを「想定内かつ無害」として受け入れた。
本件は上の形で避けられるので**避ける**。得られるものは 3 つ:

1. **「既定は no-op」が構成上の事実になる。** `lib.escapeShellArgs [ ] == ""`(§1.4(8))なので
   `filter` がそれを落とし、`trailingWrapperArgs == luaWrapperArgs` が文字列として成り立つ。
   スクリプトを diff して確かめる必要が無く、**drvPath の一致という 1 行のコマンドで証明できる**(§8 手順 5)。
2. **行継続の罠(#27 計画 R7)に新しい面を作らない。** 継続行の本数も、最後の行に `\` が無いことも
   今日のままである。
3. **誰の wrapper も再ビルドされない。**

**実測(計画作成時)。** 現行 `wrapper.nix` と §5.1 の `wrapper.nix` に同じ引数を与えて `drvPath` を比較:

| 引数 | 現行の drvPath | §5.1 版(未指定) | §5.1 版(`extraWrapperArgs = [ ]` を明示) |
|---|---|---|---|
| なし | `nl3yh761…` | 同一 | 同一 |
| `extraPackages = [ hello ]` | `qnx7l7kn…` | 同一 | 同一 |
| `extraLuaPackages = ps: [ ps.inspect ]` | `zwa1xza5…` | 同一 | 同一 |
| 両方 | `g10mw9vr…` | 同一 | 同一 |
| `vimAlias` + `viAlias` | `2pq4kgrc…` | 同一 | 同一 |

さらに §5 の全変更を当てた scratch コピーと現在の `HEAD` とで、flake 出力の `drvPath` を比較:

| 出力 | HEAD | 変更後 |
|---|---|---|
| `checks.x86_64-linux.wrapper-aliases` | `w1pcxdnr…` | 同一 |
| `checks.x86_64-linux.extra-lua-packages` | `5wk75zbp…` | 同一 |
| `checks.x86_64-linux.build-shell` | `lc0cg7pw…` | 同一 |
| `checks.x86_64-linux.dev-plugins` | `bfnw6sds…` | 同一 |
| `checks.x86_64-linux.treesitter-grammars` | `3j4slsz4…` | 同一 |
| `checks.x86_64-linux.hm-module` | `wxaln15f…` | 同一 |
| `checks.x86_64-linux.hm-module-lua-packages` | `1yavdggg…` | 同一 |
| `packages.x86_64-linux.demo` | `3ip2dq1c…` | 同一 |

**対照(素直な 2 行版)。** 同じ scratch コピーの `postBuild` だけを `${luaWrapperArgs} \` +
`${lib.escapeShellArgs extraWrapperArgs}` の 2 行に差し替えて §8 手順 5 のループを回すと、
4 本とも `DIFF` になる(`wrapper-aliases` は `w1pcxdnr…` → `hiacl3hl…`、`demo` は `3ip2dq1c…` →
`b5zfv7kr…`)。`checks.wrapper-aliases` 自体はその版でも緑である —— つまり 2 行版は動くが、
全員の wrapper を作り直させる。

**両方が非空のとき**は `<lua 引数> <ユーザー引数>` が 1 行に並ぶ。`luaWrapperArgs` 自体が既に
`concatStringsSep " "` で 4 引数を 1 行に並べているので(`wrapper.nix:39`)、書式として新しいことは無い。

### 3.3 エスケープ

**`lib.escapeShellArgs extraWrapperArgs`**(複数形。リスト全体を取り、各要素を `escapeShellArg` して
空白で繋ぐ。nixpkgs `lib/strings.nix:1253`)。

- 合意どおり。nixpkgs の neovim wrapper と同じ関数である(§1.3(c))。
- `escapeShellArg` は `[[:alnum:],._+:@%/-]+` に一致する文字列を**裸のまま**通し、それ以外を
  単引用符で包む(`lib/strings.nix:1222-1225`)。したがって `--set` / `PATH` / `:` / store path は
  裸のまま、`;` や空白を含む値だけがクォートされる(§1.4(8) の出力)。空文字は `''` になり、
  引数として保存される。
- **素の `concatStringsSep " "` に「簡略化」してはならない。** §6.3 の mutation M5a で実測:
  値に空白があると `makeWrapper doesn't understand the arg the` で wrapper のビルドが落ちる。
  (`;` や `$` を裸で渡した場合にシェルがどう解釈するかは、ビルドが先に落ちるので個別には**未実測**。)`wrapper.nix` のコメントに
  その旨を書く(§5.1)。
- **`--add-flags` / `--append-flags` / `--run` の値はエスケープしても「シェルのテキスト」のままである**
  (§1.4(9))。これは makeWrapper がそれらをそう定義しているからで、nvimx が上書きする筋ではない。
  オプション説明と README には、この 3 つを名指ししつつ**個数を断定しない**形で書く
  (`--argv0` なども起動時に展開されるため。§1.4(9) の末尾)。

### 3.4 適用順と「保護しない」

**位置は nvimx 自身の引数の後ろ**(合意どおり)。§3.2 の `trailingWrapperArgs` でリストの 2 番目に
置くことがそれを実装する。makeWrapper は引数順にブロックを出す(§1.4(1))ので、帰結は次のとおり:

| ユーザーが書くもの | 結果 | 実測 |
|---|---|---|
| `--set VAR v`(nvimx が触らない変数) | そのまま設定される | §1.4(1)(8) |
| `--prefix PATH : X` | `extraPackages` の**前**に入る | §1.4(2) |
| `--suffix PATH : X` | 起動時の PATH の**後ろ**に入る。`extraPackages` は無傷 | §1.4(2) |
| `--set PATH X` | **`extraPackages` ごと置き換わる** | §1.4(3) |
| `--prefix LUA_PATH ';' X`(rock あり) | rock の**前**に入る。起動時に `LUA_PATH` が未設定なら `;;` と既定値は残る(`;;` なしで export 済みなら既定値は入らない) | §1.4(4) |
| `--prefix LUA_PATH ';' X`(rock なし) | **既定の `package.path` が消える**(Lua の仕様) | §1.4(6) |
| `--set LUA_PATH X` | **rock の Lua モジュール(`LUA_PATH` 側)と既定の `package.path` が消える。** `LUA_CPATH` は別の変数なので C rock は残る | §1.4(5) |
| `--add-flags F` | nvimx の `--cmd 'luafile <bootstrap>'` の**後ろ**に並ぶ | §1.4(7) |

**保護はしない**(合意どおり)。`PATH` / `LUA_PATH` / `LUA_CPATH` を名指しする引数を弾く、
警告する、nvimx の引数をユーザーの後ろにもう一度出す、のいずれもしない。理由は 3 つ:

1. issue が求めているのは「the generic escape hatch」である。escape hatch に柵を付けると、
   柵の外に出たい人がまた `programs.nvimx.env` の差し替えに戻る。
2. フラグ列を解釈する必要が出る(`--set` は 2 引数、`--prefix` は 3 引数、`--add-flag` は 1 引数…)。
   makeWrapper のフラグ表を nvimx が複製することになり、nixpkgs が増やすたびに追随が要る。
3. 「後ろに置く」だけで、**壊すには `--set` と書く必要がある** —— `--prefix` / `--suffix` /
   無関係な変数の `--set` という普通の使い方は nvimx の設定と自然に合成される(上の表)。

そのぶん文書で埋める(文面は §5.3 / §5.5 を正とする): オプション説明と README に適用順と、
nvimx が自分の引数を保護しないことを書く。check は PATH についてそれを固定する(§6.1 の `overridden`、
範囲は R6)。

### 3.5 却下する代替案

**(A) attrset 版 `extraEnv = { VAR = "v"; }`。** 合意どおり見送り。`--suffix PATH` も `--add-flags` も
`--unset` も表現できない。issue 自身が `--suffix` を理由に挙げている。

**(B) `makeEnv` の返り値に引数列を足す。** 合意どおり足さない(#27 計画 §3.4(E) の方針)。
得るものは「check が assert しやすくなる」ことで、その assert は wrapper を走らせれば書ける(§6.1)。
`makeEnv` の出力 9 属性・`env` オプションの description・README の `env` 行は**変更しない**。

**(C) 引数列を検証する(奇数個の `--set`、未知のフラグなど)。** しない。§3.4 の理由 2 と同じ。
未知のフラグは makeWrapper 自身がビルド時に名指しで落とす(§1.4(10))。値の欠けた末尾は
黙って空文字になるが、これは home-manager の同名オプションでも同じ挙動であり、nvimx だけが
厳しくする理由が無い(§7 R4)。

**(D) ユーザーの引数を nvimx の引数の前に置く。** nvimx の設定が常に勝つので安全側に見えるが、
`--prefix PATH` がユーザーの意図と逆(`extraPackages` の後ろ)に入り、`--prefix LUA_PATH` は
`--set-default ';;'` より先に変数を設定してしまって**既定の `package.path` を消す**
(§6.3 の mutation M6 で実測)。合意済みの位置のほうが、普通の使い方で壊れない。

**(E) 素直な 2 行版(`${luaWrapperArgs} \` + 新しい行)。** §3.2 のとおり。drv ハッシュが動く。

**(F) 型を `either str (listOf str)` にする**(nixpkgs の `wrapperArgs` は文字列も受ける。§1.3(c) の
`lib.isString`)。しない。文字列形は「エスケープ済みのシェル断片」であり、本件がまさに避けたいもの。
home-manager も `listOf str` だけである。

## 4. 既存機能との関係

- **`extraPackages`**: 変更なし。`--prefix PATH` は今日のまま、`extraPackages` が非空のときだけ出る。
  ユーザーの引数はその後ろなので、`--prefix` / `--suffix` は合成され、`--set PATH` は置き換える(§3.4)。
  「`--prefix` ではなく `--suffix` にしたい」は、`extraPackages` から外して `extraWrapperArgs` に
  書くことで実現する(§1.3(d))。`extraPackages` 側に向きを選ぶオプションは足さない。
- **`extraLuaPackages`**: 変更なし。`luaWrapperArgs` の中身(`wrapper.nix:38-45`)も、passthru.lua の
  throw とその遅延(`:19-31`)も触らない。`extraWrapperArgs` は `lua` を一切強制しないので、
  passthru.lua を持たない package でも、rock を要求していなければ今日どおり wrap できる
  (`checks.extra-lua-packages` の `noLua` の 2 本がそのまま守る)。
- **`programs.nvimx.env`(escape hatch)**: 変更なし。`env` を自分で与えたユーザーには、他のオプションと
  同じく `extraWrapperArgs` も効かない(`mkDefault` された `makeEnv` 呼び出しが使われなくなるため)。
  本件はこの hatch に手を出す理由を 1 つ減らすものである。
- **`vimAlias` / `viAlias`**: 変更なし。symlink は `wrapProgram` の次の行で作られ、wrapper は
  `exec -a "$0"`(`make-wrapper.sh:236` の `--inherit-argv0`)なので、`vim` として起動しても
  ユーザーの引数は同じように効く(§1.4(9) の実測は `out/bin/vim` 経由で行った)。
- **`defaultEditor`(#67)**: 無関係。あちらは `home.sessionVariables` で、wrapper を通らない。
- **`lib.makeEnv`(flake の `lib` 出力)**: 引数が 1 つ増える(`extraWrapperArgs ? [ ]`)。既定値付きなので
  既存の呼び出しは無変更で通る。README は `makeEnv` の引数を列挙していないので、文書の変更は無い。
- **`packages.demo` / `templates/default/flake.nix`**: 触らない。demo は `makeEnv` を既定の引数で呼ぶので
  drv ハッシュも変わらない(§3.2 の表)。
- **`lua/` 一式・`nix/lib/bootstrap.nix`・`build-network.nix`**: 触らない。`build-network.nix` が
  見るのはプラグインの build コマンドであり、wrapper の引数は対象外。`--run` で起動時に何を
  実行させるかはユーザーの責任である(§7 R2)。

## 5. 実装手順

行番号は現在の作業ツリー(`6e0ebe3`)基準。**1 ファイルに複数の編集があるものは下(大きい行番号)から
当てるか、文字列で位置決めすること。**

### 5.1 `nix/lib/wrapper.nix`(全文差し替え)

以下は scratch コピーで `nix fmt -- --ci` を通した**逐語**である。現行との差分は 3 箇所だけ:
formal に 1 行(`extraLuaPackages ? (_: [ ]),` の直後)、`luaWrapperArgs` の定義の直後・`in` の直前に
コメント 13 行 + `trailingWrapperArgs` 6 行、`postBuild` の `${luaWrapperArgs}` →
`${trailingWrapperArgs}`。それ以外は 1 文字も変えない。

```nix
# wrapProgram the user-selected neovim (an unwrapped style package) and inject bootstrap.lua
{ pkgs }:
{
  package,
  bootstrap,
  extraPackages ? [ ],
  extraLuaPackages ? (_: [ ]),
  extraWrapperArgs ? [ ],
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
  # never reaches the throw above. What forces it is the list coming back non-empty (luaEnv then
  # needs lua.withPackages), or the function strictly using the set to compute it. Either alone is
  # enough: `_: [ someRock ]` throws without ever touching ps, while `ps: lib.optionals false
  # [ ps.foo ]` returns [ ] without forcing ps and does not. A syntactic mention is not a force.
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
  # extraWrapperArgs (#72) go last, after everything nvimx passes itself. makeWrapper handles its
  # arguments in order -- environment blocks are written out as it meets them, flags are collected
  # in the same order onto the final exec line -- so last means the user has the final word: a
  # --prefix PATH lands in front of extraPackages, a --set PATH replaces what was built up for
  # it, and an --add-flags follows the --cmd 'luafile <bootstrap>' below. That is what an escape
  # hatch is for, and nothing here guards against it.
  # They are free-form user text, hence lib.escapeShellArgs: each list element reaches
  # wrapProgram as one argument, whatever is in it. Do not "simplify" this to a plain join.
  # Joined onto luaWrapperArgs rather than given a continuation line of its own, and filtered so
  # that an empty side contributes no separator: with no extraWrapperArgs the postBuild text is
  # then byte for byte what it was before the option existed, so the derivation -- not merely the
  # script it produces -- is unchanged, and the last continuation line still ends without a
  # backslash to swallow the `ln -s` under it.
  trailingWrapperArgs = lib.concatStringsSep " " (
    lib.filter (s: s != "") [
      luaWrapperArgs
      (lib.escapeShellArgs extraWrapperArgs)
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
      ${trailingWrapperArgs}
    ${lib.optionalString vimAlias "ln -s $out/bin/nvim $out/bin/vim"}
    ${lib.optionalString viAlias "ln -s $out/bin/nvim $out/bin/vi"}
  '';
}
```

**注意点:**

- `--prefix PATH` の行の末尾の `\` は今日のまま。**`${trailingWrapperArgs}` の行には `\` を付けない。**
- `lib.escapeShellArgs`(複数形)であって `lib.escapeShellArg` ではない。後者にリストを渡すと
  `toString` で空白連結されたうえ全体が 1 引数としてクォートされる。
- `lib.filter (s: s != "")` を省いて `concatStringsSep " " [ luaWrapperArgs (…) ]` と書くと、
  片方が空のとき行末や行頭に空白が 1 個付き、**G5(drv ハッシュ不変)が壊れる**。シェルとしては
  動いてしまうので新設 check では赤にならない —— 検知するのは §8 手順 5 の drvPath 比較である。

### 5.2 `nix/lib/make-env.nix`(2 箇所)

1. **formal** —— `:13` の `extraLuaPackages ? (_: [ ]),` の直後、`:14` の `vimAlias ? false,` の直前:

   ```nix
     # Extra makeWrapper arguments, appended after nvimx's own (programs.nvimx.extraWrapperArgs).
     # Threaded straight to the wrapper like the two above, and like them it gets no output of its
     # own -- it is visible only through `wrapped`.
     extraWrapperArgs ? [ ],
   ```

2. **`mkWrapper` 呼び出し(`:136-145`)** —— `inherit` のリスト、`extraLuaPackages`(`:141`)の直後:

   ```nix
     wrapped = mkWrapper {
       inherit
         package
         bootstrap
         extraPackages
         extraLuaPackages
         extraWrapperArgs
         vimAlias
         viAlias
         ;
     };
   ```

3. **返り値(`:147-159`)は変更しない**(§3.5(B))。

### 5.3 `nix/home-manager/default.nix`(2 箇所)

1. **オプション** —— `extraLuaPackages` の `mkOption` の閉じ `};`(`:146`)と
   `devPlugins = lib.mkOption`(`:148`)のあいだ。**`:147` の空行の直後に下のブロックを挿入し、
   ブロックの後ろにも空行を 1 つ置く**(前後とも空行 1 つ。結果は `};` / 空行 / 新オプション / 空行 /
   `devPlugins`)。`:146` の直後に詰めて貼らないこと —— nixfmt は空行を足さないので
   `nix fmt -- --ci` は通ってしまい、既存の「オプション間は空行 1 つ」(`:114-115`、`:121-122`、
   `:146-148`)から外れたまま残る。逐語(nixfmt 済み。リスト項目の中なので 3 桁余分に字下げしてある —— 実ファイルでは `extraWrapperArgs` は 5 桁目から始まる):

   ```nix
       extraWrapperArgs = lib.mkOption {
         type = lib.types.listOf lib.types.str;
         default = [ ];
         example = lib.literalExpression ''
           [
             "--set"
             "MY_ASSET_DIR"
             "''${pkgs.someAsset}/share"
             "--suffix"
             "PATH"
             ":"
             "''${lib.makeBinPath [ pkgs.nodejs ]}"
           ]
         '';
         description = ''
           Extra arguments for the makeWrapper call that builds the wrapped neovim, as a flat list
           with one makeWrapper argument per element -- the same shape as home-manager's
           programs.neovim.extraWrapperArgs. Every element is shell-escaped on its way there, so it
           may contain spaces, quotes, `;` or `$` and still reaches makeWrapper as the one argument
           you wrote.

           Use it for what extraPackages and extraLuaPackages do not cover: an environment variable
           set for neovim rather than for your whole session (a path to a Nix-built asset that Lua
           reads through vim.env), a PATH entry that should lose to the PATH you already have rather
           than win (--suffix, where extraPackages uses --prefix), an extra command-line flag.

           The arguments are appended after nvimx's own, and makeWrapper applies them in order:
           first --add-flags "--cmd 'luafile <bootstrap.lua>'", then --prefix PATH for
           extraPackages, then LUA_PATH / LUA_CPATH for extraLuaPackages, then these. They
           therefore act on what nvimx set up: a --prefix PATH here lands in front of
           extraPackages, an --add-flags here follows nvimx's --cmd, and a --set replaces the
           variable outright.

           nvimx protects none of its own arguments from them. `--set PATH` discards
           extraPackages, `--set LUA_PATH` discards the rocks' Lua modules and the interpreter's
           own default search path (LUA_CPATH is a separate variable and stays), and an --add-flags
           can change how neovim starts. That is deliberate -- this is the escape hatch -- so what
           you write here is yours to keep working.

           Some makeWrapper arguments take shell text rather than a literal value: --add-flags,
           --append-flags and --run are spliced into the wrapper script as they are and interpreted
           by the shell each time neovim starts, so a `$VAR` in them is expanded then. Use
           --add-flag / --append-flag for a single literal argument. A variable set here is
           exported, so the processes neovim starts -- a :! command, a :terminal shell, a language
           server -- inherit it unless they are started with an environment of their own.
         '';
       };
   ```

   `example` の中の `''${` は Nix の indented string のエスケープで、表示上は `${` になる。
   description の中の `$VAR` と `` `$` `` は `{` が続かないのでエスケープ不要である(評価・整形とも確認済み)。

2. **`makeEnv` への受け渡し(`:340-355`)** —— `inherit (cfg)` のリスト、`extraLuaPackages`(`:346`)の直後:

   ```nix
         inherit (cfg)
           package
           lockDir
           extraPackages
           extraLuaPackages
           extraWrapperArgs
           vimAlias
           viAlias
           plugins
           treesitter
           devPlugins
           devPath
           ;
   ```

   **ここは評価器が守ってくれない**(§1.2)。落としても全 `hm-module-*` が緑のままになる。
   新設 2 件のうち、これを検知するのは `checks.extra-wrapper-args` の `module.lua` である(§6.3 の M1)。

3. **`env` の description(`:293-303`)は変更しない。** `warnings` も増やさない。

### 5.4 `flake.nix`(check 2 件)

1. `hm-module-lua-packages` の閉じ `};`(`:275`)の直後、`# defaultEditor (#67) deploys through …` の
   コメント(`:276`)の直前に `hm-module-wrapper-args` を挿入する(§6.2)。`hm-module-*` の並びを保つ。
2. `extra-lua-packages` の閉じ `);`(`:595`)の直後、`# build.kind == "shell": …` のコメント(`:596`)の
   直前に `extra-wrapper-args` を挿入する(§6.1)。wrapper を走らせる check を隣り合わせにする。

**2 → 1 の順(下から)に当てること。** 1 を先に当てると 2 の行番号が 18 行ずれる。

**どちらも前後に空行を入れない。** `flake.nix` の check は、前の check の閉じ(`};` / `);` / `'';`)の
次の行に、次の check のコメントが空行なしで続く並びである(`:275-276`、`:433-434`、`:595-596`)。
スニペットは先頭のコメント行から末尾の閉じまでをそのまま 1 かたまりで差し込む。

### 5.5 `README.md`(2 箇所)

**(b) → (a) の順(下から)に当てること。**

**(a) `## Options` の表** —— `extraLuaPackages` の行(`:225`)と `devPlugins` の行(`:226`)のあいだに 1 行:

```
| `extraWrapperArgs` | `listOf str` | `[ ]` | Extra `makeWrapper` arguments for the wrapped Neovim, one per list element, appended after nvimx's own: environment variables set for Neovim rather than session-wide, `--suffix PATH`, extra flags. nvimx protects none of its own arguments from them. See [Wrapper arguments](#wrapper-arguments). |
```

`env` の行(`:235`)は変更しない。

**(b) 新しい節** —— `### Lua rocks` の末尾(`:458`、`such a build was going to install.` で終わる行)
と `## How it works`(`:460`)のあいだ。**`:459` の空行の直後に挿入し、節の後ろにも空行を 1 つ置く**
(前後とも空行 1 つ。結果は `…going to install.` / 空行 / `### Wrapper arguments` … 節の最終行 /
空行 / `## How it works`)。以下は**インデント 4 桁で引用した README の実内容**であり、
挿入時にはインデントを外すこと(内部に ```` ```nix ```` フェンスがあるため):

    ### Wrapper arguments

    `extraPackages` and `extraLuaPackages` each look after one part of the wrapper's environment. For
    anything else, `extraWrapperArgs` hands you the `makeWrapper` call itself, in the same shape as
    home-manager's `programs.neovim.extraWrapperArgs`:

    ```nix
    programs.nvimx.extraWrapperArgs = [
      # A variable set for Neovim only, not for your login shell; Lua reads it as vim.env.MY_ASSET_DIR.
      "--set" "MY_ASSET_DIR" "${pkgs.someAsset}/share"
      # Tools that should lose to whatever is already on PATH. extraPackages would make them win.
      "--suffix" "PATH" ":" "${lib.makeBinPath [ pkgs.nodejs ]}"
    ];
    ```

    It is a flat list with one `makeWrapper` argument per element, and every element is shell-escaped
    for you: one containing spaces, quotes, `;` or `$` still reaches `makeWrapper` as the one argument
    you wrote.

    The arguments are appended after nvimx's own, and `makeWrapper` applies them in the order given:

    1. `--add-flags "--cmd 'luafile <bootstrap.lua>'"`
    2. `--prefix PATH` for `extraPackages`
    3. `--set-default` and `--prefix` on `LUA_PATH` / `LUA_CPATH` for `extraLuaPackages`
    4. your `extraWrapperArgs`

    So yours act on what the first three built. A `--prefix PATH` lands in front of `extraPackages`, an
    `--add-flags` follows nvimx's `--cmd`, and a `--set` replaces the variable outright. nvimx protects
    none of its own arguments: `--set PATH` discards `extraPackages`, and `--set LUA_PATH` discards the
    rocks' Lua modules together with the interpreter's default search path (`LUA_CPATH` is a separate
    variable and stays). That is what makes this an escape hatch, and it is also why whatever you put
    here is yours to keep working.

    Three things worth knowing before you reach for it:

    - nvimx's own `--prefix PATH` is there only while `extraPackages` is non-empty, and no option turns
      it into a `--suffix`. To have a tool lose to the `PATH` you already have, leave it out of
      `extraPackages` and add it here with `--suffix`, as above.
    - Adding to `LUA_PATH` / `LUA_CPATH` by hand has the catch it has in any Lua program: once the
      variable is set, the interpreter's defaults are included only where the value says `;;`. When
      `extraLuaPackages` is in use nvimx has already put that `;;` there — unless you already export
      the variable without one — and a `--prefix` here keeps it. Otherwise start with
      `"--set-default" "LUA_PATH" ";;"` yourself — or use `extraLuaPackages`, which does.
    - Some arguments take shell text rather than a literal value — `--add-flags`, `--append-flags` and
      `--run`: the value is written into the wrapper script as-is and interpreted every time Neovim
      starts, so a `$HOME` in it is expanded then. `--add-flag` / `--append-flag` (singular) pass one
      literal argument instead.

    A variable set here is exported, so the processes Neovim starts — a `:!` command, a `:terminal`
    shell, a language server — inherit it unless they are started with an environment of their own.

- 例のリストは 1 行に 1 組で書いてある(`"--set" "MY_ASSET_DIR" "…"`)。nixfmt はこれを 1 要素 1 行に
  ばらすが、README のコードブロックは整形対象ではなく、組が見えるほうが読みやすいのでこのままにする。
- 番号付きリストの 1〜3 は `wrapper.nix` の `postBuild` の並びそのものである。将来 nvimx 自身の引数を
  増やすときは、ここ・オプション説明(§5.3)・`docs/architecture.md` の build フロー(§5.6 の 3)の
  3 箇所を一緒に直すこと。
- 箇条書き 3 つの根拠: 1 つ目は §1.3(d)(ソースの確認)、2 つ目は §1.4(6)、3 つ目は §1.4(9)(いずれも実測)。

### 5.6 `docs/architecture.md`(6 箇所)

以下は行番号の小さい順。**当てるときは下から**、または文字列で位置決めすること
(編集 2 と 3 と 4 がそれぞれ 1 行増やす)。

1. **`:108`** —— build 時フローの mermaid 図。`:173-174` の散文と対のノードである:

   before: `    J --> K["wrapProgram neovim<br/>--cmd luafile<br/>PATH / LUA_PATH / LUA_CPATH"]`
   after:  `    J --> K["wrapProgram neovim<br/>--cmd luafile<br/>PATH / LUA_PATH / LUA_CPATH<br/>+ extraWrapperArgs"]`

2. **`:121-122`** —— 設計原則 4。今日の文面は注入経路を**限定列挙**している
   (「Runtime injection is limited to …」)。任意の wrapper 引数を通せるようになると、
   `--add-flags "--cmd 'lua …'"` 1 つでこの文は偽になるので、主語を「nvimx が注入するもの」に絞り、
   `extraWrapperArgs` は「その外にある」と 1 文で書く。あわせて、今日の列挙から漏れている
   `extraPackages` の `PATH`(`wrapper.nix:54`。同じ文書の mermaid ノードと build フロー `[5]` には
   載っている)を列挙に足す —— この文を書き直す以上、限定列挙は正しくしておく。

   before:
   ```
   4. **Runtime injection is limited to the wrapper's `--cmd luafile` + `package.preload["lazy"]`, plus `LUA_PATH` / `LUA_CPATH` when `extraLuaPackages` asks for rocks**.
      The user's lua stays unmodified.
   ```
   after:
   ```
   4. **What nvimx injects at runtime is limited to the wrapper's `--cmd luafile` + `package.preload["lazy"]`, plus `PATH` for `extraPackages` and `LUA_PATH` / `LUA_CPATH` when `extraLuaPackages` asks for rocks**.
      The user's lua stays unmodified.
      `extraWrapperArgs` sits outside that limit on purpose: it appends the user's own arguments to the same `wrapProgram` call, after nvimx's, and whatever those inject is the user's doing rather than nvimx's.
   ```

3. **`:173-174`** —— build 時フローの `[5]`。`:174` の行末に `,` を足し、1 行足す:

   before:
   ```
         → wrapProgram neovim (the user-selected package) with --cmd 'luafile <bootstrap.lua>',
           extraPackages on PATH and extraLuaPackages' rock env on LUA_PATH / LUA_CPATH
   ```
   after:
   ```
         → wrapProgram neovim (the user-selected package) with --cmd 'luafile <bootstrap.lua>',
           extraPackages on PATH and extraLuaPackages' rock env on LUA_PATH / LUA_CPATH,
           then the user's extraWrapperArgs (shell-escaped, last, so they act on all of the above)
   ```

4. **`:427` の直後** —— hm モジュールの例に 1 行足す(コメントは既存 2 行と同じ 36 桁目から):

   before:
   ```
     extraPackages = [ ];             # prepended to the wrapper's PATH (ripgrep, lsp, etc.)
     extraLuaPackages = ps: [ ];      # lua rocks on the wrapper's LUA_PATH / LUA_CPATH (luarocks itself stays off)
   ```
   after:
   ```
     extraPackages = [ ];             # prepended to the wrapper's PATH (ripgrep, lsp, etc.)
     extraLuaPackages = ps: [ ];      # lua rocks on the wrapper's LUA_PATH / LUA_CPATH (luarocks itself stays off)
     extraWrapperArgs = [ ];          # extra makeWrapper arguments, appended after nvimx's own (escape hatch)
   ```

5. **`:494`** —— ファイル一覧の `wrapper.nix` の説明:

   before: `    wrapper.nix              # wrapProgram for neovim (PATH / LUA_PATH / LUA_CPATH)`
   after:  `    wrapper.nix              # wrapProgram for neovim (PATH / LUA_PATH / LUA_CPATH / extraWrapperArgs)`

6. **`:519`** —— checks の列挙に 2 件。`hm-module-*` は連続させ、wrapper 系は末尾に置く
   (`flake.nix` 側の挿入位置と一致させる)。該当部分だけを抜き出すと:

   before:
   ```
   ..., hm-module-dev, hm-module-lua-packages, hm-module-default-editor, plugins-overrides, plugins-nixpkgs-fallback, plugins-escape-hatch, wrapper-aliases, extra-lua-packages}`
   ```
   after:
   ```
   ..., hm-module-dev, hm-module-lua-packages, hm-module-wrapper-args, hm-module-default-editor, plugins-overrides, plugins-nixpkgs-fallback, plugins-escape-hatch, wrapper-aliases, extra-lua-packages, extra-wrapper-args}`
   ```

**変更しない箇所**:

- **`:554`(Implementation phases の 7)** —— `devPlugins (#26), extraLuaPackages (#27), …` の行。
  #67 計画 §5.4 の判断に従う: この行は当時の予告リストであり、`extraWrapperArgs` は最初から
  載っていないので**後から名前を足さない**。
- **edge-case 表(`:521-538` 付近)** —— 制限でも edge case でもない。

### 5.7 触らないもの

- `templates/default/flake.nix` —— `:45` に `# extraPackages = [ pkgs.ripgrep ];` の例があるが、
  テンプレートは最小構成に保つ(合意どおり)。
- `lua/` 一式、`tests/` 一式 —— **新規フィクスチャは 1 つも要らない。** degraded モード
  (存在しない lockDir)で wrapper を作れる。
- `nix/lib/{default,bootstrap,farm,plugin-drv,resolve-plugin,sources,treesitter,lock-app,build-network}.nix`、
  `nix/build-registry/`、`.github/workflows/` —— 無関係。CI は `nix flake check` と `nix fmt -- --ci` を
  回すだけなので、ワークフローの変更は不要である。
- `CLAUDE.md` —— Conventional Commits の scope 一覧に `hm` も `wrapper` も既にある。
  本件のコミットは issue の表題どおり `feat(hm): add extraWrapperArgs option` とする
  (`4979aa3 feat(hm): add extraLuaPackages option` と同形)。

## 6. テスト

### 6.1 `checks.extra-wrapper-args`(新設)

`flake.nix:595` の直後に挿入する。逐語(nixfmt 済み、scratch コピーで緑を確認済み):

```nix
          # extraWrapperArgs (#72): the user's own makeWrapper arguments, appended to the one
          # wrapProgram call. Like extraLuaPackages the promise is a runtime one, and like
          # extraPackages and extraLuaPackages this argument has no makeEnv output of its own. Its
          # text could be read back from wrapped's build command at evaluation time, but that would
          # pin how lib.escapeShellArgs happens to quote it rather than the promise, so the check
          # starts the wrapped neovim and looks at the environment it actually got. Three promises
          # are pinned: each list element arrives as one argument whatever characters it holds
          # (lib.escapeShellArgs), the arguments come after nvimx's own so that they act on what
          # nvimx set up, and they sit in the same call as extraPackages / extraLuaPackages without
          # costing either. Degraded mode for the same reason as checks.extra-lua-packages: nothing
          # here depends on the lock, so not one plugin source is fetchTree'd.
          extra-wrapper-args =
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
              # A value picked to trip the usual careless quotings: a space and a `;` for a bare
              # join, a `'` for naive single-quoting, a `"` and a `$HOME` for naive double-quoting,
              # a `*` for anything left unquoted. all.lua spells the same value out a second time
              # by hand rather than having it interpolated from here, so that one mistake cannot
              # hide on both sides.
              awkward = "a b;c$HOME'd\"e *";
              # Everything at once. extraPackages and extraLuaPackages are set so that there is
              # something of nvimx's for each user argument to land after, which is how
              # "after" gets observed: --prefix PATH has to end up in front of hello's bin/,
              # --prefix LUA_PATH in front of the rock env, and the --cmd has to run once
              # bootstrap.lua has already installed package.preload["lazy"].
              all = mkEnv {
                extraPackages = [ pkgs.hello ];
                extraLuaPackages = ps: [ ps.inspect ];
                extraWrapperArgs = [
                  "--set"
                  "NVIMX_TEST_ESCAPE"
                  awkward
                  "--prefix"
                  "PATH"
                  ":"
                  "/nvimx-test/prefix"
                  "--suffix"
                  "PATH"
                  ":"
                  "/nvimx-test/suffix"
                  "--prefix"
                  "LUA_PATH"
                  ";"
                  "/nvimx-test/?.lua"
                  "--add-flags"
                  "--cmd 'lua vim.g.nvimx_test_after_bootstrap = package.preload.lazy ~= nil'"
                ];
              };
              # The escape hatch taken all the way: a --set after nvimx's --prefix PATH replaces
              # it, extraPackages included. Nothing protects nvimx's own arguments, on purpose, and
              # the option description and the README both say so -- this pins the PATH half of
              # that: a later guard on PATH, or a reordering, has to come here and change the
              # documented contract knowingly.
              overridden = mkEnv {
                extraPackages = [ pkgs.hello ];
                extraWrapperArgs = [
                  "--set"
                  "PATH"
                  "/nvimx-test/only"
                ];
              };
              # The control: a wrapper that was given no arguments, checked for the absence of the
              # variable, the PATH entries and the marker all.lua looks for, so that those are known
              # to come from the wrapper and not from the builder.
              untouched = mkEnv { };
              # The module's pass-through. checks.hm-module-wrapper-args exercises the same option
              # but cannot fail on this, for exactly the reason checks.extra-lua-packages'
              # moduleWrapped gives: mkHmCheck asserts nothing, and the formal in
              # nix/lib/make-env.nix has a default, so dropping extraWrapperArgs from the
              # `inherit (cfg)` list in nix/home-manager/default.nix type-checks, builds, and
              # silently ignores the option. And where extraLuaPackages at least has a second
              # symptom (the passthru.lua throw), this option has no such thing: the drop shows nowhere
              # but in the module-built wrapper, which is why that gets run. The neighbouring drop --
              # from mkWrapper's inherit list in nix/lib/make-env.nix -- is caught by all.lua, and
              # dropping the formal from nix/lib/wrapper.nix or nix/lib/make-env.nix is an
              # evaluation error: an undefined variable while its use is still there, an unexpected
              # argument once that is gone as well, since neither function takes `...`. Degraded
              # lockDir again, to stay offline.
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
                        extraWrapperArgs = [
                          "--set"
                          "NVIMX_TEST_MODULE"
                          "from the module"
                        ];
                      };
                    }
                  ];
                }).config.programs.nvimx.env.wrapped;
            in
            pkgs.runCommand "extra-wrapper-args" { } ''
              export HOME=$TMPDIR

              cat > all.lua <<'LUA'
              -- Escaping: one list element, one argument, byte for byte.
              local want = [[a b;c$HOME'd"e *]]
              assert(vim.env.NVIMX_TEST_ESCAPE == want, "extraWrapperArgs value mangled: " .. vim.inspect(vim.env.NVIMX_TEST_ESCAPE))

              -- Order against extraPackages: the user's --prefix PATH comes after nvimx's, so it
              -- ends up in front of it, and the two share one wrapProgram call.
              local path = vim.split(vim.env.PATH, ":", { plain = true })
              assert(path[1] == "/nvimx-test/prefix", "extraWrapperArgs must come after nvimx's own PATH argument: " .. vim.env.PATH)
              assert(vim.uv.fs_stat(path[2] .. "/hello"), "extraPackages must sit right behind the user's --prefix: " .. vim.env.PATH)
              -- --suffix PATH is the issue's own example of what extraPackages cannot express.
              assert(path[#path] == "/nvimx-test/suffix", "--suffix PATH did not reach the end of PATH: " .. vim.env.PATH)

              -- Order against extraLuaPackages. Were the user's --prefix LUA_PATH emitted first,
              -- it would not just land behind the rocks: it would set LUA_PATH before nvimx's
              -- --set-default ';;' could, and the interpreter's default path would be gone too.
              assert(package.path:find("/nvimx-test/?.lua;", 1, true) == 1, "extraWrapperArgs must come after the rock arguments: " .. package.path)
              assert(require("inspect"), "extraLuaPackages did not survive alongside extraWrapperArgs")
              assert(package.path:find("./?.lua", 1, true), "default package.path lost: " .. package.path)

              -- Order against the bootstrap: flags are prepended in argument order, so the user's
              -- --cmd runs once bootstrap.lua has installed package.preload["lazy"]. nil would
              -- mean the flag never arrived, false that it ran too early.
              assert(vim.g.nvimx_test_after_bootstrap == true, "the user's --add-flags must follow nvimx's --cmd: " .. vim.inspect(vim.g.nvimx_test_after_bootstrap))
              LUA
              # env -u for the reason checks.extra-lua-packages gives: the LUA_PATH asserts are
              # about what the wrapper does to an unset variable.
              env -u LUA_PATH -u LUA_CPATH ${all.wrapped}/bin/nvim --clean -l all.lua

              cat > overridden.lua <<'LUA'
              assert(vim.env.PATH == "/nvimx-test/only", "a --set after nvimx's arguments must win: " .. vim.env.PATH)
              assert(vim.fn.executable("hello") == 0, "--set PATH was expected to discard extraPackages")
              LUA
              ${overridden.wrapped}/bin/nvim --clean -l overridden.lua

              cat > untouched.lua <<'LUA'
              assert(vim.env.NVIMX_TEST_ESCAPE == nil, "the builder leaks NVIMX_TEST_ESCAPE; all.lua proves nothing")
              assert(not vim.env.PATH:find("/nvimx-test/", 1, true), "the builder's PATH already holds the test entries: " .. vim.env.PATH)
              assert(vim.g.nvimx_test_after_bootstrap == nil, "the marker is set without any extraWrapperArgs")
              LUA
              ${untouched.wrapped}/bin/nvim --clean -l untouched.lua

              # The hm module really hands the option to makeEnv (see moduleWrapped above).
              cat > module.lua <<'LUA'
              assert(vim.env.NVIMX_TEST_MODULE == "from the module", "the hm module did not pass extraWrapperArgs through")
              LUA
              ${moduleWrapped}/bin/nvim --clean -l module.lua

              touch $out
            '';
```

**各 assert が守るもの**(mutation の実測は §6.3):

| # | assert | 捕まえる退行 |
|---|---|---|
| 1 | `all.lua`: `vim.env.NVIMX_TEST_ESCAPE == want` | `make-env.nix` の `mkWrapper` への渡し忘れ(値が `nil`、M2)。クォートの退行は 2 通りに分かれる(§6.3): M5a / M5b / M5c の 3 通りはこの値を含む wrapper の**ビルド自体**が落ち、ビルドが通る誤クォート(M5d)はこの assert が `value mangled` で落とす |
| 2 | `all.lua`: `path[1] == "/nvimx-test/prefix"` | ユーザーの引数が nvimx の `--prefix PATH` より**前**に出る退行(`hello` の bin が先頭に来る) |
| 3 | `all.lua`: `fs_stat(path[2] .. "/hello")` | `extraWrapperArgs` を足したことで `extraPackages` の PATH が消える・位置がずれる退行。実測: `wrapper.nix` の `--prefix PATH` の行を空にすると、2 番は通り、ここ(`all.lua:9`)で最初に落ちる |
| 4 | `all.lua`: `path[#path] == "/nvimx-test/suffix"` | issue の使用例そのもの(`--suffix PATH`)が効かなくなる退行 |
| 5 | `all.lua`: `package.path:find("/nvimx-test/?.lua;", 1, true) == 1` | ユーザーの引数が rock 引数より**前**に出る退行(M6)。**`trailingWrapperArgs` から `luaWrapperArgs` が脱落する退行もここで最初に落ちる**(実測: `all.lua:16: … must come after the rock arguments: /nvimx-test/?.lua` —— 後ろに rock が無いので `;` 付きの検索が外れる) |
| 6 | `all.lua`: `require("inspect")` | rock の配線が消える退行。`luaWrapperArgs` の脱落は 5 番が先に落とすが、**5 番を外しても単独で捕まえる**(実測: 5 番の行を消すと `all.lua:16: module 'inspect' not found`。無改変では 17 行目)。固有に守るのは「`LUA_PATH` の並びは正しいのに rock が require できない」場合である |
| 7 | `all.lua`: `package.path:find("./?.lua", 1, true)` | 5 と同じ退行の、より深刻な側の症状(`--set-default ';;'` が発火せず既定値が消える)。5 番が先に落ちるが、5 番を外しても単独で捕まえる(§6.3 末尾の実測) |
| 8 | `all.lua`: `vim.g.nvimx_test_after_bootstrap == true` | ユーザーの `--add-flags` が nvimx の `--cmd` より前に出る退行(`false`)、`--add-flags` が届かない退行(`nil`)。引数全体を先頭に移す退行(M7)では 2 番が先に落ちるが、2・3・5・7 を外しても単独で捕まえる(§6.3 末尾の実測)。**M10 では落ちない**: ユーザーの引数は `--add-flags` の後ろに残るので、この assert は真のままである(同) |
| 9 | `overridden.lua` の 2 本 | 「保護しない」という文書化済みの契約が、柵の追加で黙って変わること。順序の入れ替えは `all.lua`(2・5 番)が先に落とすので、固有に守るのは「順序はそのままで nvimx が PATH を守り始める」場合である。順序の退行に対しても独立に効く: M10 から 2・3・5・7 を外すと `all.lua` は全通過し、`overridden.lua:1` が落とす(§6.3 末尾の実測) |
| 10 | `untouched.lua` の 3 本 | **空振りの緑**: builder の環境が `NVIMX_TEST_*` や `/nvimx-test/` を元から持っていて、1〜8 が wrapper と無関係に成立してしまうこと |
| 11 | `module.lua` | hm モジュールの `inherit (cfg)` からの渡し忘れ。新設 2 件のうち、これを捕まえるのはこの 1 本である(M1 では `hm-module-wrapper-args` は緑のまま) |

**「空振りで緑になる」経路の塞ぎ方:**

- **値は `nil` との比較にならない形で assert する。** 1・9・11 は期待値との `==`、8 は `== true`
  (`nil` も `false` も落ちる)。`~= nil` や truthy 判定だけの assert は 1 本も無い ——
  3・6・7 は truthy 判定だが、それぞれ「実在するファイルの stat」「実在するモジュールの require」
  「部分文字列の位置」であり、届いていなければ `nil` になる側である。
- **空文字の値を使わない**(§1.4(11))。
- **`grep` による否定 assert を使わない。** `extra-lua-packages` は `if grep -q …` の前に `test -f` を
  置いて空振りを塞いでいるが、本 check は wrapper スクリプトを grep せず、すべて neovim の中から見る。
  スクリプトの文面(makeWrapper の出力形式)に依存する assert は nixpkgs 更新で黙って空振りしうる。
- **`nvim -l` は assert 失敗を非ゼロ終了にする。** `runCommand` は `set -e` なので、どの 1 本が落ちても
  check 全体が落ちる。4 本のスクリプトは 4 回の独立した起動である。
- **期待値を Nix から補間しない。** `awkward` と `want` は同じ値を 2 箇所に手で書いてある。
  `${lib.escapeShellArg awkward}` のように同じ関数を通して Lua 側に埋めると、エスケープの退行が
  両側で同じように起きて assert が一致してしまう。
- **`nativeBuildInputs` は空のままにする。** neovim は wrapper の絶対パスで呼ぶ。
  PATH に何かを足すと 2〜4 の「先頭 / 2 番目 / 末尾」の意味は変わらないが、`untouched.lua` の
  前提(builder の PATH に `/nvimx-test/` が無い)を崩さないこと。

**スニペット内のコメントは削らずにそのまま入れること。** 各コメントが何を言っているかは
スニペット自体を正とする(ここで言い換えない)。

### 6.2 `checks.hm-module-wrapper-args`(新設)

`flake.nix:275` の直後に挿入する。逐語(nixfmt 済み、scratch コピーで緑を確認済み):

```nix
          # extraWrapperArgs (#72) through the module's option type (listOf str) with a
          # context-carrying string, and all the way to an activation package against a real lock --
          # checks.extra-wrapper-args' moduleWrapped goes through the same type but stops at the
          # wrapper. The last element is the shape the issue asks for, a store path interpolated
          # into a string. Like every mkHmCheck it asserts nothing about the result: that the
          # module actually hands the option on is checked by checks.extra-wrapper-args'
          # moduleWrapped, for the reason spelled out there. Uses the same basic-config lock
          # hm-module already builds, so it adds no fetch of its own.
          hm-module-wrapper-args = mkHmCheck {
            configDir = ./tests/fixtures/basic-config;
            lockDir = ./tests/fixtures/basic-config/nvimx-lock;
            extraPackages = [ pkgs.hello ];
            extraWrapperArgs = [
              "--set"
              "NVIMX_TEST_ASSET"
              "${pkgs.hello}/share"
            ];
          };
```

**固有のカバー範囲**は `hm-module-lua-packages` が `extra-lua-packages` に対して持つものと同じである:
モジュールのオプション型(`listOf str`)を通り、**実 lock + activationPackage の完成まで**行く。
`moduleWrapped` は `.config.programs.nvimx.env.wrapped` だけを読み、`home.packages` /
`xdg.configFile` / `xdg.dataFile` の組み立ては踏まない。加えて本 check は、issue の例そのものの形
(`"${pkgs.hello}/share"` —— store path を補間した、context 付きの文字列)を `types.str` に通す。

**この check は何も assert しない**(`mkHmCheck` の性質)。渡し忘れは検知できない ——
それは §6.1 の `module.lua` の仕事であり、コメントにそう書いてある。

**受け入れるコスト**: home-manager の generation を 1 つ丸ごとビルドする。`hm-module-*` は 7 件から
8 件になる。`moduleWrapped` で十分と判断するなら落とせるが、依頼は 2 件とも新設することを
前提にしているので、本計画は足す(§7 U2)。

### 6.3 mutation の実測(計画作成時)

scratch コピーに §5 の全変更を当てた状態から、1 箇所ずつ壊して
`nix build …#checks.x86_64-linux.extra-wrapper-args` を実行した結果。**10 通りすべて赤**。

| # | 壊し方 | 結果 |
|---|---|---|
| M1 | `home-manager/default.nix` の `inherit (cfg)` から `extraWrapperArgs` を削除 | `module.lua:1: the hm module did not pass extraWrapperArgs through`(**他の 3 本のスクリプトは通過**) |
| M2 | `make-env.nix` の `mkWrapper` の `inherit` から削除 | `all.lua:3: extraWrapperArgs value mangled: nil` |
| M3 | M2 に加えて `make-env.nix` の formal も削除 | 評価エラー: `function 'anonymous lambda' called with unexpected argument 'extraWrapperArgs'` |
| M5a | `lib.escapeShellArgs` → `lib.concatStringsSep " "` | wrapper のビルド失敗: `Builder called die: makeWrapper doesn't understand the arg the`(`moduleWrapped` の wrapper。`"from the module"` の 2 語目)。**メッセージは一意ではない**: `all` の wrapper も同じ mutation で `unexpected EOF while looking for matching` で落ち(`--keep-going` で両方を確認)、どちらが先に報告されるかはビルドの順序次第である。どちらが出ても赤であればよい |
| M5b | 各要素を `"…"` で包むだけ | wrapper のビルド失敗: `unexpected EOF while looking for matching` |
| M5c | 各要素を `'…'` で包むだけ(`'` を逃がさない) | 同上 |
| M5d | 各要素を `"…"` で包み、中の `"` だけを逃がす(`lib.replaceStrings [ "\"" ] [ "\\\"" ]`) | **wrapper のビルドは通る。** `all.lua:3: extraWrapperArgs value mangled: "a b;c/homeless-shelter'd\"e *"` —— `$HOME` がビルド時に展開された |
| M6 | `trailingWrapperArgs` の 2 要素を入れ替える(ユーザー → rock) | `all.lua:16: extraWrapperArgs must come after the rock arguments: <rock>;<rock>;/nvimx-test/?.lua` —— **既定値も消えている**(§3.5(D)) |
| M7 | ユーザーの引数を `wrapProgram $out/bin/nvim \` の直後(全部の前)に移す | `all.lua:8: extraWrapperArgs must come after nvimx's own PATH argument: <hello>/bin:/nvimx-test/prefix:…` |
| M10 | ユーザーの引数を `--add-flags` と `--prefix PATH` のあいだに移す | 同上(`all.lua:8`) |

M7 から PATH / LUA_PATH の assert(§6.1 の表の **2・3・5・7** の 4 行)を**行ごと削除して**再実行すると、
`all.lua:19: the user's --add-flags must follow nvimx's --cmd: false` で落ちる
(8 番の assert は無改変の `all.lua` では 23 行目にある。4 行消したので 19 行目に見える。
行を消さずコメントに置き換えた場合は `all.lua:23` で同じメッセージになる —— 両方とも実測)。
**8 番の assert は単独でも発火する**ことの確認である(M7 では先に 2 番が落ちるので見えない)。
**2・3・5 の 3 行だけを消した場合は、先に 7 番が落ちる**: `all.lua:15: default package.path lost: …`
(無改変では 18 行目)。M7 ではユーザーの `--prefix LUA_PATH` が `--set-default ';;'` より先に出るので
既定値が消えるためで、7 番が 5 番とは独立に同じ退行を捕まえることの実測でもある。

**M10 は 8 番では捕まらない。** M10 はユーザーの引数を `--add-flags` と `--prefix PATH` のあいだに移すだけ
なので、ユーザーの `--add-flags` は nvimx の `--cmd 'luafile …'` の後ろに残り、8 番は真のままである。
M10 に対して assert を上から 1 行ずつ削除していった実測(行番号は削除後のもの):

| M10 から削除した assert | 落ちる場所 |
|---|---|
| なし | 2 番: `all.lua:8: extraWrapperArgs must come after nvimx's own PATH argument: <hello>/bin:/nvimx-test/prefix:…` |
| 2 | 3 番: `all.lua:8: extraPackages must sit right behind the user's --prefix: <hello>/bin:/nvimx-test/prefix:…` |
| 2・3 | 5 番: `all.lua:14: extraWrapperArgs must come after the rock arguments: <rock>;<rock>;…` |
| 2・3・5 | 7 番: `all.lua:15: default package.path lost: <rock>;<rock>;…` |
| 2・3・5・7 | `all.lua` は全通過し、9 番: `overridden.lua:1: a --set after nvimx's arguments must win: <hello>/bin:/nvimx-test/only` |

つまり M10 は 2・3・5・7・9 番の 5 段で守られており、8 番はその中に入らない。

**M5a 以外の mutation のメッセージは一意である。** M5d は check 本体の `all.lua:3` で落ちる。M5b / M5c で落ちる wrapper は `all` の 1 本だけ
(`moduleWrapped` の値 `from the module` と `overridden` の値は、単純な引用符で包むだけでも通るため。
`--keep-going` で確認)。M1 / M2 / M6 / M7 / M10 は check 本体の中で最初の assert が落ちるので 1 通り、
M3 は評価エラーである。M1 のとき `hm-module-wrapper-args` が緑のままであることも実測した。

上の表の行番号(`all.lua:3` / `:8` / `:16`、`module.lua:1`)はいずれも**無改変の check** での番号である。

**formal だけを削除した場合は、M3 とは別の評価エラーになる**(実測。参照が残っているため):

| 壊し方 | 結果 |
|---|---|
| `wrapper.nix` の `extraWrapperArgs ? [ ],` だけを削除 | `error: undefined variable 'extraWrapperArgs'`、`at …/nix/lib/wrapper.nix:62:28` |
| `make-env.nix` の `extraWrapperArgs ? [ ],` だけを削除 | `error: undefined variable 'extraWrapperArgs'`、`at …/nix/lib/make-env.nix:145:7` |

行番号はどちらも formal の 1 行を消した後のファイルでのもので、指しているのは残った参照である
(`wrapper.nix` は `(lib.escapeShellArgs extraWrapperArgs)`、`make-env.nix` は `mkWrapper` の `inherit`)。
`unexpected argument`(`...` が無いことによるエラー)になるのは、formal と参照を**両方**消して
呼び出し側だけが渡し続けるとき(M3)である。§1.2 の実測は「formal を足す前に渡した」場合で、
M3 と同じ側にあたる。`moduleWrapped` のコメントはこの 2 段を書き分けてある(§6.1)。

### 6.4 check がカバーしないもの(意識的に受け入れる)

- **G5(drv ハッシュ不変)を常時守る check は無い。** `(mkEnv { }).wrapped.drvPath ==
  (mkEnv { extraWrapperArgs = [ ]; }).wrapped.drvPath` は既定値の定義そのものなので恒真であり、
  足しても何も守らない。「変更前と同じ」は 2 つの版を比べないと言えないので、§8 手順 5 の
  実装時の比較で担保する(#27 の `untouched` のコメントが「standing proxy であって proof ではない」と
  書いているのと同じ構図だが、本件の比較は drvPath の一致なので proxy ではなく証明である)。
- **`LUA_CPATH` へのユーザー引数。** `LUA_PATH` と同じコード経路なので足さない。
- **`--run` / `--unset` / `--chdir` / `--add-flag` / `--append-flag(s)` / `--argv0`。** makeWrapper の
  機能であり、nvimx のコードは引数の種類を区別しない。§1.4(9) で `--chdir` 以外は手で実測済み
  (`--chdir` は**未実測**)。
- **複数モジュールからのマージ順**(§1.4(12))。`types.listOf` の性質であり、README にも約束として
  書かない。
- **darwin での実行。** linux からは評価しかできない(§6.6)。

### 6.5 既存 checks への影響

**無い。** 既存 check 35 件すべてについて、`HEAD` と §5 の全変更を当てた scratch コピーとで
`checks.x86_64-linux.<name>.drvPath` を比べ、35 件とも同一であることを実測した
(差分は新設 2 件が増えることだけ)。`packages.x86_64-linux.demo` も同一である(§3.2 の表)。
drv が同じなので、これらは本件で再ビルドされない。

- `checks.wrapper-aliases`(`flake.nix:419-433`)は、#27 計画 R7 が行継続の守り手に指名した check で
  ある。本件は継続行の構造を変えないが、守り手としての役割はそのまま残る。
- `checks.extra-lua-packages` の `untouched` / `onlyPath`(`LUA_` が現れないこと)は、
  `trailingWrapperArgs` が `luaWrapperArgs` を空のときに何も足さないことを引き続き守る。
- `hm-module-default-editor` は `env.wrapped` を強制しないので無関係。
- lua 側は 1 行も変えないので、`extractor-*` / `resolve-*` / `genflake-*` / `lock-app` は無関係。

### 6.6 CI / darwin

- ワークフローの変更は不要(§5.7)。
- ローカル(linux)の `nix flake check` は darwin を omit するので、評価だけを別途確認する(§8 手順 4)。
  **計画作成時に scratch コピーで実測済み**:

  ```
  checks.aarch64-darwin.extra-wrapper-args.drvPath      = /nix/store/6am3v014…-extra-wrapper-args.drv
  checks.aarch64-darwin.hm-module-wrapper-args.drvPath  = /nix/store/4h88869n…-home-manager-generation.drv
  checks.aarch64-darwin.wrapper-aliases.drvPath         = /nix/store/12ywkr58…-wrapper-aliases.drv
  checks.aarch64-darwin.extra-lua-packages.drvPath      = /nix/store/9i1535hk…-extra-lua-packages.drv
  ```

- 本件が足すコードにシステム依存の部分は無い(`lib.escapeShellArgs` と文字列連結だけ)。
  check が使うのも `pkgs.hello` / `ps.inspect` / `neovim-unwrapped` で、いずれも
  `extra-lua-packages` が既に両システムで使っているものである。
- **`checks.aarch64-darwin.extra-wrapper-args` の実行は未実測**である(linux からは走らせられない)。
  CI の darwin ジョブが初めて走らせる。懸念点は 1 つだけ: `all.lua` の `path[#path] ==
  "/nvimx-test/suffix"` と `untouched.lua` は builder の PATH の中身に依存しないように書いてあるが、
  darwin の sandbox で `vim.env.PATH` が空になることは無い前提である(stdenv が設定する)。

## 7. リスク / 未決事項

### R1: 適用順が home-manager と 1 点だけ違う

§1.3(d) のとおり、home-manager では `extraPackages` の PATH がユーザーの引数の**後**に来るが、
nvimx では**前**である。`programs.neovim` から移ってきたユーザーが `--set PATH` を持ち込むと、
home-manager では残っていた `extraPackages` が nvimx では消える。合意済みの設計の帰結であり、
オプション説明と README の両方に名指しで書いてある(「`--set PATH` discards `extraPackages`」)。
home-manager との差そのものは README には書かない —— 読者が知るべきは nvimx の順序であって、
他所との差分ではない。

### R2: `--add-flags` / `--append-flags` / `--run` などは起動時にシェルが解釈する

§1.4(9)。`escapeShellArgs` が守るのはビルド時のシェルだけで、これらの値は makeWrapper の仕様として
wrapper スクリプトにそのまま書かれる。値の中に `$(…)` を書けば起動のたびに実行される。
`--argv0` の値も二重引用符の中に入るので展開される。**文書はこの種の引数の個数を断定しない**
(「Some makeWrapper arguments …」)—— nixpkgs が makeWrapper に引数を足しても文面が偽にならない。
ユーザー自身が自分の設定に書く文字列なので脅威ではないが、「every element is shell-escaped」と
書いた直後に例外があるのは読者を驚かせるので、説明と README の両方に書いてある。
`build-network.nix` の「ビルドはオフライン」という保証とは別の層の話である(あれはビルド時、
これは実行時)。

### R3: `extraLuaPackages` なしで `LUA_PATH` を足すと既定値が消える

§1.4(6)。Lua の仕様だが、このオプションで最初に踏みそうな穴である。README の箇条書きに回避策
(`--set-default LUA_PATH ';;'` を先に書く、または `extraLuaPackages` を使う)を書いてある。
**nvimx が常に `--set-default LUA_PATH ';;'` を出すようにはしない** —— それは rock を要求していない
全ユーザーの wrapper と drv ハッシュを変え、子プロセスに `LUA_PATH=;;` を漏らす。#27 の G2 を壊す。

### R4: 壊れた引数列はビルド時まで分からない(一部は分からないまま通る)

§1.4(10)。未知のフラグは makeWrapper が名指しで落とすが、値の欠けた末尾の `--set VAR` は
黙って空文字になる。検証は足さない(§3.5(C))。home-manager の同名オプションと同じ挙動である。

### R5: 子プロセスへの継承

`--set` した変数は export されるので、neovim が起動するプロセスが継承する。計画作成時に実測したのは
`vim.fn.system("printenv NVIMX_A")` と `:!printenv NVIMX_A`(どちらも値が見えた)で、`:terminal` と
LSP サーバは**未実測**である。文面は「inherit it unless they are started with an environment of
their own」と条件付きにしてある(ジョブ API は環境を差し替えて起動できるため)。
#27 計画 R1 と同じ性質であり、issue が求めている「Neovim プロセス限定」は「ログインシェルには
出ない」という意味では満たされるが、「neovim の子には出ない」という意味ではない。
オプション説明と README の末尾に 1 文ずつ書いてある。

### R6: `overridden` の assert は PATH について「保護しない」を固定する

将来 nvimx が PATH を守りたくなったら、この assert を意図的に書き換えることになる(§3.4)。
固定しているのは PATH だけである。文書が挙げるもう 1 つの例(`--set LUA_PATH`)を固定する wrapper は
check に無いので、`LUA_PATH` 側に柵を足す変更は `extra-wrapper-args` を通る。ドキュメントの例を
すべて check で固定することはしない(assert を増やすと表・mutation・行番号が連動して変わる)。

### U1(未決): `extraWrapperArgs` の位置を `extraPackages` の前にも選べるようにするか

home-manager 互換の順序(R1)が欲しいという要望が出た場合の話である。本計画は足さない ——
`lib.mkBefore` で解決できる問題ではなく(1 つのリストの中の順序ではなく、nvimx の引数との相対位置
なので)、別オプションが要る。issue はそこまで求めていない。

### U2(未決): `hm-module-wrapper-args` を本当に足すか

固有のカバー範囲とコストは §6.2 のとおり。依頼に含まれているので足す側に倒してある。
落とす場合に連動して直す箇所: §5.4 の 1、§5.6 の 6、§6.1 の `moduleWrapped` コメント(この check を
名指ししている)、§6.2 全体、§6.5 / §6.6 と冒頭の表の件数と darwin の行、§8 の手順 2・3(37 件)・4・
8(M1 の期待)・10(grep 対象)。

### U3(未決): README の例に出すパッケージ名

`pkgs.someAsset` は実在しない名前である(issue の `${somePackage}` に倣った)。実在するパッケージに
したい場合は差し替えてよいが、オプションの `example` と README の 2 箇所を揃えること。

## 8. 検証手順(実装完了時に必ず全部通す)

```bash
cd /home/myuron/ghq/github.com/myuron/nvimx

# 1. 整形 + lint(treefmt: nixfmt / stylua / luacheck)。lua は 1 行も変えていないので実質 nixfmt。
#    §5 / §6 のスニペットは nixfmt 正規形を逐語で貼ったものなので、書き写せばそのまま通る。
#    stylua.toml / .luacheckrc は触らないので --clear-cache は不要。
nix fmt -- --ci

# 2. 新 check だけを先に回す(速いループ用)
nix build .#checks.x86_64-linux.extra-wrapper-args -L
nix build .#checks.x86_64-linux.hm-module-wrapper-args -L
#    隣の wrapper 系 check も。本件では再ビルドされないはずである(§6.5)
nix build .#checks.x86_64-linux.extra-lua-packages -L
nix build .#checks.x86_64-linux.wrapper-aliases -L

# 3. フルチェック(linux)。check は 37 件(既存 35 + 新設 2)
nix flake check

# 4. darwin 評価。ローカル linux の flake check は darwin を omit する(CLAUDE.md)
nix eval .#checks.aarch64-darwin.extra-wrapper-args.drvPath
nix eval .#checks.aarch64-darwin.hm-module-wrapper-args.drvPath
nix eval .#checks.aarch64-darwin.extra-lua-packages.drvPath
nix eval .#checks.aarch64-darwin.wrapper-aliases.drvPath

# 5. G5: extraWrapperArgs を設定しない wrapper の drv が 1 つも変わっていないこと(§3.2)。
#    main のコミット済みツリーと作業ツリーを比べる。stash は要らない。
#    G5 を常時守る check は無い(§6.4)ので、この手順で確かめる。空振りしない形にしてある:
#    評価の失敗は握り潰さず(2>/dev/null を付けない)、失敗と空文字は same と区別して報告し、
#    最後の 1 行で合否を言う。bash で実行すること(ユーザーのシェルは fish)。
#    手順 2 で新 check が緑になった**後**に走らせること —— 実装前のツリーは main と同じなので、
#    そこで走らせると当然 4/4 same になり、何も証明しない。
#    評価警告(degraded mode の trace、nixfmt-rfc-style)が stderr に混ざるのは正常である。
fail=0
for a in checks.x86_64-linux.wrapper-aliases checks.x86_64-linux.extra-lua-packages \
         checks.x86_64-linux.hm-module packages.x86_64-linux.demo; do
  b=$(nix eval --raw "git+file://$PWD?ref=main#$a.drvPath") || { echo "EVAL FAILED (main)  $a"; fail=1; continue; }
  n=$(nix eval --raw ".#$a.drvPath")                        || { echo "EVAL FAILED (tree)  $a"; fail=1; continue; }
  if [ -n "$b" ] && [ "$b" = "$n" ]; then echo "same  $a  ${b#/nix/store/}"
  else echo "DIFF  $a  $b  $n"; fail=1; fi
done
[ "$fail" = 0 ] && echo "G5 holds: 4/4 same" || echo "G5 NOT PROVEN"
#    合格の表示(計画作成時に実測。flake.lock を動かしていなければハッシュもこのとおり):
#      same  checks.x86_64-linux.wrapper-aliases  w1pcxdnry45zip6kjsl89za16vz8dhfk-wrapper-aliases.drv
#      same  checks.x86_64-linux.extra-lua-packages  5wk75zbpsv72gcmvrw4fiw1la31rw1p2-extra-lua-packages.drv
#      same  checks.x86_64-linux.hm-module  wxaln15f5wzalwh897zkgf909ppw8nnx-home-manager-generation.drv
#      same  packages.x86_64-linux.demo  3ip2dq1cchgrkfxizfqn48mnh5djcrlr-nvim.drv
#      G5 holds: 4/4 same
#    "G5 holds: 4/4 same" の行と same 4 行の両方が出ていること。ハッシュが上と違う場合は
#    flake.lock か main が動いている —— それ自体は不合格ではないが、理由を説明できること。
#    不合格の表示も実測済み: 存在しない属性を渡すと nix の error に続いて
#    "EVAL FAILED (main)  <attr>" と "G5 NOT PROVEN"、素直な 2 行版の wrapper.nix(§3.2 の対照)では
#    "DIFF  <attr>  <main の drv>  <tree の drv>" が 4 行と "G5 NOT PROVEN" になる。
#    1 本でも DIFF なら wrapper.nix の postBuild が既定で変わっている。§5.1 の注意点 3 つ目
#    (lib.filter を省いた)をまず疑うこと。

# 6. smoke test(CLAUDE.md)。:Lazy で全プラグインが local、git 操作なし、を目で確認する。
#    demo の drv は変わっていないので(手順 5)、これは「壊していない」の確認である。
nix build .#demo && ./result/bin/nvim

# 7. 手で 1 度だけ: issue の例の形が実際に効くこと(check でも見ているが、目で見ておく)
nix build --impure --no-link --print-out-paths --expr '
  let f = builtins.getFlake (toString ./.); p = f.inputs.nixpkgs.legacyPackages.x86_64-linux;
  in (f.lib.x86_64-linux.makeEnv {
       package = p.neovim-unwrapped;
       lockDir = ./tests/fixtures/basic-config/no-such-lock;
       extraWrapperArgs = [ "--set" "SOME_VAR" "${p.hello}" "--suffix" "PATH" ":" "${p.hello}/bin" ];
     }).wrapped'
#    出てきた <out>/bin/nvim の中身に export SOME_VAR=… と PATH の suffix ブロックがあり、
#    <out>/bin/nvim --clean --headless -c 'lua print(vim.env.SOME_VAR)' +qa が store path を出すこと

# 8. §6.3 の mutation を実装ツリーで再現する(確認後は必ず戻すこと)。
#    check が「何も検知していない」状態で緑なのが本件最大の失敗モードである。最低限この 3 つ:
#      M1  nix/home-manager/default.nix の inherit (cfg) から extraWrapperArgs を消す
#            → extra-wrapper-args が module.lua:1 で赤(hm-module-wrapper-args は緑のまま)
#      M5a nix/lib/wrapper.nix の lib.escapeShellArgs を lib.concatStringsSep " " にする
#            → wrapper のビルドが赤。出るメッセージは "makeWrapper doesn't understand the arg the" か
#              "unexpected EOF while looking for matching" のどちらか(wrapper が 2 本落ち、
#              どちらが先に報告されるかは決まっていない。§6.3)。どちらでも合格
#      M6  trailingWrapperArgs の 2 要素を入れ替える
#            → extra-wrapper-args が all.lua の "must come after the rock arguments" で赤
#    戻し忘れの検知: `git diff --stat` は使えない。実装が未 commit なら実装そのものの差分が
#    常に出るうえ、1 行を書き換えただけの mutation では要約行(N files changed, …)が変わらない
#    (計画作成時に、mutation を残した状態と残していない状態で要約行が同じになることを確認した)。
#    mutation の前に差分全体を
#    リポジトリ外へ退避し、戻した後に一致を見る。実装が commit 済みでも未 commit でも同じ手順でよい
#    (commit 済みなら退避ファイルが空になるだけ)。
snap=$(mktemp)                 # リポジトリの外。mutation を始める前に 1 度だけ取る
git diff > "$snap"
#    … ここで M1 / M5a / M6 を 1 つずつ当て、赤を確認し、戻す …
if git diff | diff -q - "$snap" >/dev/null; then echo "mutations reverted"
else echo "MUTATION LEFT BEHIND:"; git diff | diff - "$snap"; fi
rm -f "$snap"
#    "mutations reverted" が出ること。計画作成時に実測: escapeShellArgs を concatStringsSep に
#    したまま走らせると "MUTATION LEFT BEHIND:" と差分(index 行と該当行)が出て、戻すと
#    "mutations reverted" になる。

# 9. 変更が想定のファイルに閉じていること
#     git diff は未追跡ファイルを出さない。§8 を commit の前に行う場合、計画ファイルは未追跡なので
#     git status にだけ現れる(commit 後なら git diff --name-only main に現れる)。
#     どちらの場合も、両方を合わせて下の 7 件になること。
git status --short
git diff --name-only main
#    → README.md / docs/architecture.md / docs/plans/72-extra-wrapper-args.md / flake.nix /
#      nix/home-manager/default.nix / nix/lib/make-env.nix / nix/lib/wrapper.nix の 7 件だけ。
#      lua/ tests/ templates/ .github/ が出たら範囲外に触っている。

# 10. ドキュメント
grep -c '(#wrapper-arguments)' README.md                 # → 1(Options 表)
grep -n '^### Wrapper arguments' README.md               # → 1 件、### Lua rocks と ## How it works のあいだ
grep -c 'extraWrapperArgs' README.md                     # → 5
grep -c 'extraWrapperArgs' docs/architecture.md          # → 5(mermaid / 設計原則 4 / build フロー / モジュール例 / ファイル一覧)
grep -c 'extra-wrapper-args\|hm-module-wrapper-args' docs/architecture.md   # → 1(checks の列挙)
grep -c 'Runtime injection is limited' docs/architecture.md                 # → 0(設計原則 4 を書き換えた)
```
