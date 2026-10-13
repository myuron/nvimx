# #73 対応計画: provider オプション(`withPython3` / `withRuby` / `withNodeJs` / `extraPython3Packages`)

対象 issue: [#73 feat(hm): add provider options (withPython3 / withRuby / withNodeJs)](https://github.com/myuron/nvimx/issues/73)

本計画の `file:line` は**現在の作業ツリー(`1d09b26`、ブランチ `feat/provider-options`)基準で
実ファイルを確認したもの**である。nixpkgs / home-manager 側の行番号は `flake.lock` が固定している
input の実ファイルからの引用である(nixpkgs → `/nix/store/5ljrgyqskjl8g5kxm88a8gl8251m801x-source`
(`.version` は `26.11`)、home-manager → `/nix/store/fm93mv69y0ify036r6zgnhqy1chw3vd0-source`
(`release.json` は `26.11`)。
`nix eval --raw --impure --expr '(builtins.getFlake (toString ./.)).inputs.nixpkgs.outPath'` で確認)。
pinned nixpkgs の `neovim-unwrapped` は 0.12.4 である。

**§5 と §6 の nix コードは「貼れば通る」ことを確認済みである。** 計画作成時に、リポジトリを
`git archive HEAD` で scratch ディレクトリへ写し、そこに §5.1〜§5.5 の全変更(nix 4 ファイル +
`flake.nix` の check 2 件)を当てたうえで次を実行した。リポジトリ本体は計画ファイル以外 1 バイトも
変更していない。README / `docs/architecture.md` の変更(§5.6 / §5.7)も同じ scratch に当て、
§8 手順 10 の `grep` の件数はそこで実測した値である(どちらのファイルも treefmt の対象外で、
check も読まない)。

| 実行したもの | 結果 |
|---|---|
| `nix fmt -- --ci` | exit 0(`formatted 52 files (0 changed)`)。§5 / §6 のスニペットは nixfmt 正規形である |
| `nix build …#checks.x86_64-linux.providers` | 緑(sandbox 内で python3 / ruby / node の host が実際に起動する) |
| `nix build …#checks.x86_64-linux.hm-module-providers` | 緑 |
| `nix flake check`(x86_64-linux、check 39 件 = 既存 37 + 新設 2) | `all checks passed!` |
| `nix eval …#checks.aarch64-darwin.{providers,hm-module-providers,wrapper-aliases,extra-lua-packages,extra-wrapper-args,hm-module}.drvPath` | 6 件とも評価成功 |
| `nix eval --option allow-import-from-derivation false …#checks.x86_64-linux.{providers,hm-module-providers}.drvPath` | 2 件とも評価成功(IFD なし) |
| 既存 check 37 件の drvPath を main と比較 | **37 件とも不変**(§6.5)。`packages.{x86_64-linux,aarch64-darwin}.demo` も不変 |
| §6.3 の mutation 20 通り | 20 通りとも赤 |
| §8 手順 10 の `grep` 10 本(README / architecture.md を scratch に当てた状態) | 件数は手順 10 に書いたとおり |

**darwin で実際にビルドして走らせることはできていない**(手元は x86_64-linux)。評価が通ることだけを
確認した。§7 R6 を参照。

この issue にはコメントが無く、設計についてユーザーとの事前合意は無い。**本計画が自分で決めた点は
次の 6 つ**で、どれも理由を該当節に、覆す場合の影響を §7 に書いてある:

1. `with*` は `bool` ではなく `nullOr bool`、既定は `null`(= 今日の挙動のまま)。§3.1 / R1
2. host は nixpkgs の公開パッケージから直接組む。`wrapNeovimUnstable` から借りるのは `rubyEnv` だけ。§3.3
3. `GEM_HOME` は設定しない(nixpkgs の wrapper との意図的な差)。§3.4 / R2
4. `withPerl` は入れない。§3.6 / U1
5. `extraPython3Packages` を `withPython3 = true` なしで書いたら警告する(`makeEnv` の出力を 1 つ足す)。§3.5 / U3
6. remote plugin の manifest(`rplugin.vim`)はビルド時に生成しない。文書化だけする。§3.6 / R4

## 1. 背景 / 現状

### 1.1 nvimx は今日 provider について何もしていない

`provider` という語は `nix/` `lua/` `README.md` `docs/architecture.md` `templates/` のどこにも無い
(`grep -rn provider nix lua README.md docs/architecture.md templates` が 0 件)。wrapper が neovim に
渡すものは `nix/lib/wrapper.nix:71-78` の `wrapProgram` 1 回がすべてである(逐語):

```nix
71   postBuild = ''
72     wrapProgram $out/bin/nvim \
73       --add-flags "--cmd 'luafile ${bootstrap}'" \
74       ${lib.optionalString (extraPackages != [ ]) "--prefix PATH : ${lib.makeBinPath extraPackages}"} \
75       ${trailingWrapperArgs}
76     ${lib.optionalString vimAlias "ln -s $out/bin/nvim $out/bin/vim"}
77     ${lib.optionalString viAlias "ln -s $out/bin/nvim $out/bin/vi"}
78   '';
```

`trailingWrapperArgs`(`:60-65`)は `luaWrapperArgs` と `lib.escapeShellArgs extraWrapperArgs` を
空文字を除いて空白で連結したものである(#72)。`vim.g.*_host_prog` も `vim.g.loaded_*_provider` も
どこにも出てこない。

したがって今日の nvimx の neovim は、**neovim 自身の provider 探索にすべてを任せている**。
neovim は初めて provider が要るとき(`:python3`、`has("python3")`、remote plugin の最初の呼び出し)に
`PATH` から host を探す。計画作成時の実測(pinned の `neovim-unwrapped` 0.12.4、`env -i` で `PATH` を空に
して起動):

```
== 何も設定しない(今日の nvimx と同じ)
has py3   0
py3eval   Vim:E319: No "python3" provider found. Run ":checkhealth vim.provider"
has ruby  0
node      Cannot find the "neovim" node package. Try :checkhealth
```

逆に、ユーザーの `PATH` に pynvim 入りの `python3` や `neovim-ruby-host` があれば、それが黙って使われる
(`PATH` に nixpkgs の ruby env の `bin/` だけを足して `has("ruby")` が `1` になることを実測した)。
つまり今日の挙動は「環境次第で動いたり動かなかったりする」であり、issue の言う「supported way が無い」は
正確である。ユーザーが今できる回避は `extraPackages` に host を入れて `PATH` 経由で見つけさせるか、
`init.lua` で `vim.g.python3_host_prog` を自分で書くかで、後者は store path を lua に書けないので
`extraWrapperArgs` で環境変数を渡すという回り道になる。

### 1.2 オプションが wrapper に届くまでの経路

#72 計画 §1.2 が記録したものと同じである。`nix/home-manager/default.nix:390-406` が
`inherit (cfg) package lockDir extraPackages extraLuaPackages extraWrapperArgs vimAlias viAlias …` で
`nvimxLib.makeEnv` を呼び、`nix/lib/make-env.nix:140-150` が `mkWrapper { inherit package bootstrap
extraPackages extraLuaPackages extraWrapperArgs vimAlias viAlias; }` を呼ぶ。`make-env.nix` の formal
(`:6-29`)にも `wrapper.nix` の formal(`:3-11`)にも `...` は無い。この経路の性質も同じである:

- formal を**宣言せずに**渡すと評価エラーになる。
- formal は既定値付きなので、**渡し忘れは常に黙って既定値に落ちる**。`inherit (cfg)` から 1 語落としても
  型検査は通り、ビルドも通り、オプションは無視される。本件は 4 語足し、さらに `wrapper.nix` から
  新設の `providers.nix` への `inherit`(§5.2。`providers.nix` の formal も既定値付きである)という
  3 つ目の受け渡しを作るので、落とし得る箇所が **3 か所 × 4 語**ある: module → `makeEnv`、
  `makeEnv` → `mkWrapper`、`wrapper.nix` → `providers.nix`。§6.3 に載せたのは前 2 か所の一部
  (M1〜M5 / M18)だが、3 か所目も穴ではない: そこで落ちた語は `on` の wrapper に届かないので
  `on.lua` が落ちる。レビューが 3 か所 × 4 語の 12 通りをすべて落として、12 通りとも赤になることを
  確認している。formal の既定値はそのままにする。

`makeEnv` の返り値は `make-env.nix:152-164` の 9 属性
(`farm` / `bootstrap` / `wrapped` / `pluginDrvs` / `unknownPluginNames` / `treesitterWithoutPlugin` /
`devDirs` / `unknownDevPluginNames` / `hasLock`)である。

### 1.3 home-manager 側の前例(pinned input で実読)

`modules/programs/neovim/default.nix` の provider 関連オプションは次の 5 つである。

| オプション | 行 | 型 | 既定 |
|---|---|---|---|
| `withNodeJs` | `:108-115` | `bool` | `false` |
| `withPerl` | `:117-124` | `bool` | `false` |
| `withPython3` | `:126-147` | `bool` | **stateVersion 依存**: `< 26.05` は `true`、`>= 26.05` は `false` |
| `withRuby` | `:149-169` | `bool` | **stateVersion 依存**: 同上 |
| `extraPython3Packages` | `:171-182` | `functionTo (listOf package)` | `_: [ ]` |

`withPython3` の定義(`:126-147`、逐語):

```nix
      withPython3 = mkOption {
        type = types.bool;
        inherit
          (lib.hm.deprecations.mkStateVersionOptionDefault {
            inherit (config.home) stateVersion;
            since = "26.05";
            optionPath = [
              "programs"
              "neovim"
              "withPython3"
            ];
            legacy.value = true;
            current.value = false;
          })
          default
          defaultText
          ;
        description = ''
          Enable Python 3 provider. Set to `true` to
          use Python 3 plugins.
        '';
      };
```

issue 本文との差が 2 点ある:

- **`extraPythonPackages`(Python 2)はもう存在しない。** pinned の home-manager に該当オプションは無く、
  nixpkgs 側も `withPython2` を渡すと throw する(`wrapper.nix:74-76`)。本件の対象は
  `extraPython3Packages` だけである。
- **既定値は 1 つではない。** issue は「parity」と言うが、`programs.neovim` の `withPython3` / `withRuby` は
  `home.stateVersion` によって `true` にも `false` にもなる。どちらに合わせても、もう片方の世代の
  ユーザーにとっては parity にならない(§3.1)。

値の使われ方(`:518-540`、関係する行だけ):

```nix
      wrappedNeovim' =
        (pkgs.wrapNeovimUnstable cfg.package {
          withNodeJs = cfg.withNodeJs || cfg.coc.enable;
          # …
          inherit (cfg)
            extraLuaPackages
            extraName
            withPython3
            withRuby
            withPerl
            # …
            ;
          extraPython3Packages =
            ps: (cfg.extraPython3Packages ps) ++ (lib.concatMap (f: f ps) vimPackageInfo.pluginPython3Packages);
          # …
          wrapRc = false;
        }).overrideAttrs
```

`wrapRc = false` なので、provider の設定(`luaRcContent`)は wrapper ではなく
`~/.config/nvim/init.lua` に `lib.mkOrder 200` で書き込まれる(`:598-602`)。nvimx の `init.lua` は
ユーザーのものなので、この経路は使えない。

### 1.4 nixpkgs 側の実装(pinned input で実読)

issue は「`wrapNeovimUnstable` / `neovimUtils.makeNeovimConfig` already know how」と書いている。
pinned の nixpkgs では半分だけ正しい:

- **`neovimUtils.makeNeovimConfig` は deprecated で、provider を扱っていない。**
  `pkgs/applications/editors/neovim/utils.nix:146-147` が
  `lib.warn "neovimUtils.makeNeovimConfig is deprecated. Use wrapNeovim or wrapNeovimUnstable directly."`
  を出し、返すのは `neovimRcContent` / `luaRcContent` / `LUA_PATH` 系の `wrapperArgs` だけである(`:149-167`)。
- **host を組むのは `wrapNeovimUnstable`(`wrapper.nix`)である。** 該当箇所(逐語):

```nix
 86         rubyEnv = bundlerEnv {
 87           name = "neovim-ruby-env";
 88           gemdir = ./ruby_provider;
 89           postBuild = ''
 90             ln -sf ${ruby}/bin/* $out/bin
 91           '';
 92         };
```

```nix
140         python3Env =
141           lib.warnIf (attrs ? python3Env)
142             "Pass your python packages via the `extraPython3Packages`, e.g., `extraPython3Packages = ps: [ ps.pandas ]`"
143             python3.pkgs.python.withPackages
144             (
145               ps:
146               [ ps.pynvim ]
147               ++ (extraPython3Packages ps)
148               ++ (lib.concatMap (f: f ps) vimPackageInfo.pluginPython3Packages)
149             );
```

```nix
173           ++ lib.optionals finalAttrs.withRuby [
174             "--set"
175             "GEM_HOME"
176             "${rubyEnv}/${rubyEnv.ruby.gemPath}"
177           ]
178           ++ lib.optionals (finalAttrs.runtimeDeps != [ ]) [
179             "--suffix"
180             "PATH"
181             ":"
182             (lib.makeBinPath finalAttrs.runtimeDeps)
183           ];
```

```nix
185         providerLuaRc =
186           let
187             hostPython3 =
188               runCommand "nvim-host-${python3Env.name}"
189                 {
190                   nativeBuildInputs = [
191                     makeWrapper
192                   ];
193                 }
194                 ''
195                   makeWrapper ${python3Env.interpreter} $out/bin/nvim-python3 --unset PYTHONPATH --unset PYTHONSAFEPATH
196                 '';
197
198             genProviderCommand =
199               prog: withProg: exec:
200               if withProg then
201                 "vim.g.${prog}_host_prog='${exec}'"
202               else
203                 # speeds up neovim by bypassing provider discovery
204                 "vim.g.loaded_${prog}_provider=0";
205           in
206           lib.concatStringsSep ";" [
207             (genProviderCommand "node" finalAttrs.withNodeJs "${neovim-node-client}/bin/neovim-node-host")
208             (genProviderCommand "perl" finalAttrs.withPerl "${perlEnv}/bin/perl")
209             (genProviderCommand "ruby" finalAttrs.withRuby "${finalAttrs.rubyEnv}/bin/neovim-ruby-host")
210             (genProviderCommand "python3" finalAttrs.withPython3 "${hostPython3}/bin/nvim-python3")
211           ];
```

```nix
271         runtimeDeps =
272           lib.optionals finalAttrs.waylandSupport [ wl-clipboard ]
273           ++ lib.optional finalAttrs.withRuby rubyEnv
274           ++ lib.optional finalAttrs.withNodeJs nodejs
275           ++ lib.optionals finalAttrs.autowrapRuntimeDeps vimPackageInfo.runtimeDeps;
```

読み取れること:

- **`providerLuaRc` は 2 値である。** 4 つの provider それぞれについて「host を指す」か
  「`loaded_<prog>_provider=0` で無効化する」のどちらかを必ず書く。何もオプションを渡さないときの値は
  (実測)`vim.g.loaded_node_provider=0;vim.g.loaded_perl_provider=0;vim.g.loaded_ruby_provider=0;vim.g.loaded_python3_provider=0`
  である。「何も言わない」という状態が無い。
- `hostPython3` は `let` の中にあり、外からは `providerLuaRc` の文字列の一部としてしか取れない。
- `python3Env` と `rubyEnv` は `:268` の `inherit python3Env rubyEnv;` で derivation の属性として公開されている。
- wrapper 全体(`makeWrapper` の呼び出し、`NVIM_SYSTEM_RPLUGIN_MANIFEST`、ビルド中に neovim を起動して
  `+UpdateRemotePlugins` を流す `:292-331`、`.desktop` の書き換え)は nvimx の wrapper とは別物である。

### 1.5 実測: host は何があれば動くか

pinned nixpkgs から host を 3 つビルドし(`python3-3.14.6-env` + pynvim 0.6.0、`neovim-ruby-env`
(ruby 3.4.9 / neovim gem 0.10.0)、`node-client-5.4.0` + `nodejs-24.18.0`)、`env -i` で `PATH` を
存在しないディレクトリだけにした neovim 0.12.4 に `--cmd` で `vim.g.*_host_prog` だけを渡した結果:

```
== host_prog だけ、PATH は空
has py3      1
py3eval      2
has ruby     1
rubyeval     2
node detect  { "/nix/store/…-node-client-5.4.0/bin/neovim-node-host", "" }
node require Vim(let):E475: Invalid value for argument cmd: 'node' is not executable
             Failed to load node host. …
```

```
== 同じ設定で PATH の末尾に nodejs の bin を足す
node require 5        ← host のチャンネル id。起動した
```

`:checkhealth vim.provider` の Ruby の節(同じ neovim、`host_prog` は設定済み):

```
== PATH に ruby env が無い
Ruby provider (optional) ~
- ⚠️ WARNING `ruby` and `gem` must be in $PATH.
  - ADVICE:
    - Install Ruby and verify that `ruby` and `gem` commands work.

== PATH の末尾に ruby env の bin を足す(GEM_HOME は設定しない)
Ruby provider (optional) ~
- Ruby: 3.4.9
- Host: /nix/store/…-neovim-ruby-env/bin/neovim-ruby-host
- ✅ OK Latest "neovim" gem is installed: 0.10.0
```

まとめると:

| provider | `host_prog` だけで動くか | `PATH` に要るもの | `GEM_HOME` |
|---|---|---|---|
| python3 | 動く | 何も要らない | — |
| ruby | 動く(`rubyeval` が通る) | `:checkhealth` が `ruby` / `gem` を探す。無いと動いている provider が警告になる | **要らない**。無くても host は動き、`:checkhealth` も OK になる |
| node | **動かない**。neovim は host を `node <host>` として起動する(`provider#node#Require`) | `node` が必須 | — |

nixpkgs が `GEM_HOME` を設定している(`wrapper.nix:173-177`)のは、この実測の範囲では機能上の必要が無い。

### 1.6 実測: remote plugin の manifest

issue が名指ししている用途は「Python plugins via `:UpdateRemotePlugins`」である。最小の Python remote plugin
(`rplugin/python3/hello.py`、同期関数 `NvimxHello` を 1 つ登録)で流れを通した:

```
$ nvim -u NORC --headless --cmd "lua vim.g.python3_host_prog='…/bin/nvim-python3'" \
       --cmd "set rtp+=<dir>/plug" -c UpdateRemotePlugins -c qa
remote/host: python3 host registered plugins ['hello.py']
remote/host: generated rplugin manifest: <HOME>/.local/share/nvim/rplugin.vim

$ cat <HOME>/.local/share/nvim/rplugin.vim
" python3 plugins
call remote#host#RegisterPlugin('python3', '<dir>/plug/rplugin/python3/hello.py', [
      \ {'sync': v:true, 'name': 'NvimxHello', 'type': 'function', 'opts': {}},
     \ ])

$ nvim … -c 'lua print(vim.fn.NvimxHello())' -c qa
hello from python
```

- manifest は `stdpath("data")/rplugin.vim` に書かれる。nvimx ではここはユーザーの領域で書き込める
  (`docs/architecture.md` の edge case 表「lazy writing state」と同じ理由)。**`:UpdateRemotePlugins` は
  nvimx でそのまま動く。**
- manifest は**プラグインの絶対パス**を記録する。プラグインのディレクトリを動かして同じ関数を呼ぶと
  `ModuleNotFoundError: No module named 'hello'` になった(実測)。nvimx ではプラグインのパスは
  `<farm>/<name>` で、farm は lock が動くたびに store path が変わる。**プラグインを更新したら
  `:UpdateRemotePlugins` をやり直す必要がある**(R4)。
- `--clean` では manifest が読まれない。`runtime/plugin/rplugin.vim` の末尾が
  `if index(v:argv, "--clean") < 0 | call s:LoadRemotePlugins() | endif` であり、`--clean` 付きで
  `:UpdateRemotePlugins` を流すと `E482: Can't open file /path/to/manifest for writing` になる(実測)。
  check でこの流れを通す部分だけ `-u NORC` を使う理由である(§6.1)。
- nixpkgs の `neovim-unwrapped` は `$NVIM_SYSTEM_RPLUGIN_MANIFEST` を読むパッチが当たっている
  (`rplugin.vim.orig` との diff が `:59-62` の 4 行)。upstream の neovim(neovim-nightly-overlay)には
  無い。ビルド時 manifest をやるならこの差が効いてくる(R4)。

## 2. ゴール

- **G1(動く)**: `withPython3 = true` / `withRuby = true` / `withNodeJs = true` を設定した neovim で、
  ユーザーの `PATH` に何も無くても 3 つの host が起動して応答する。`checks.providers` が sandbox の中で
  実際に `py3eval` / `rubyeval` / node host の起動を行って証明する。
- **G2(issue の用途が通る)**: Python の remote plugin を `:UpdateRemotePlugins` で登録し、その関数を
  呼べる。同じ check が通す。
- **G3(`extraPython3Packages` が届く)**: 指定したパッケージが python3 の host から import できる。
- **G4(無効化できる)**: `with* = false` で `vim.g.loaded_<prog>_provider == 0` になる。
- **G5(既定は完全な no-op)**: 4 オプションすべてが既定のとき、`postBuild` の文字列が今日とバイト単位で
  同一であり、**wrapper の drv ハッシュが変わらない**。既存 check 37 件と `packages.demo` の drvPath が
  変わらないことを計画作成時に実測済み(§6.5)。既存ユーザーの provider の挙動は 1 つも変わらない。
- **G6(3 つは独立)**: ある provider の設定が別の provider に漏れない(`null` が `false` に化けない、
  node だけ有効にして ruby が `PATH` に入らない)。
- **G7(ユーザーが最後に勝つ)**: provider の引数は `extraWrapperArgs` の前に置く。`--cmd` で設定するので
  `init.lua` の `vim.g.python3_host_prog = …` も勝つ。
- **G8(neovim を選ばない)**: host のビルドは `programs.nvimx.package` の passthru に何も要求しない。
  stub のパッケージでも評価が通ることを check が固定する。
- **G9(渡し忘れを検知する)**: hm モジュールの `inherit (cfg)` から 4 語のどれを落としても check が赤になる。
- **G10(黙った no-op を作らない)**: `withPython3 = true` なしで `extraPython3Packages` を書いたら
  activation 時に警告が出る。
- **G11(ドキュメント)**: README の option 表に 4 行、`### Providers` 節、`docs/architecture.md` の
  設計原則 4 ほかが更新される。`programs.neovim` との差(既定値、`GEM_HOME`、`withPerl`、manifest)が
  明記される。
- **G12(純粋・オフライン・IFD なし)**: ビルドに network を足さない。評価に IFD を足さない
  (`allow-import-from-derivation false` で評価が通ることを実測済み)。

## 3. 設計

### 3.1 オプションと既定値 —— 3 値にする

| オプション | 型 | 既定 |
|---|---|---|
| `programs.nvimx.withPython3` | `nullOr bool` | `null` |
| `programs.nvimx.withRuby` | `nullOr bool` | `null` |
| `programs.nvimx.withNodeJs` | `nullOr bool` | `null` |
| `programs.nvimx.extraPython3Packages` | `functionTo (listOf package)` | `_: [ ]` |

各 `with*` の意味:

| 値 | nvimx がすること | neovim の挙動 |
|---|---|---|
| `true` | nixpkgs から host を組み、`vim.g.<prog>_host_prog` をそれに向ける | `PATH` に関係なくその host を使う |
| `false` | `vim.g.loaded_<prog>_provider = 0` を設定する | provider は無効。探索もしない |
| `null`(既定) | **何もしない** | 今日と同じ。初めて要るときに `PATH` から探す |

**`true` と `false` の意味は `programs.neovim` と同じである。** したがって `programs.neovim` から持ってきた
値は意味を変えずに動く。`null` だけが nvimx 独自の状態である。

なぜ `bool` にしないか。`bool` にする場合、既定値と `false` の意味の決め方は 2 通りしかなく、どちらも
問題がある:

- **(a) `bool`・既定 `false`・`false` = 無効化(`programs.neovim` の現行世代と同じ)。**
  既存の nvimx ユーザー全員の wrapper に `loaded_*_provider = 0` が入る。今日 `PATH` 上の
  pynvim 入り python で remote plugin を動かしている人(§1.1 のとおり黙って動いている)は、
  アップデートしただけで壊れる。drv も全員ぶん変わる。**制約「既存ユーザーの挙動を黙って変えない」に
  正面から反する。**
- **(b) `bool`・既定 `false`・`false` = 何もしない。**
  既存ユーザーは守られるが、`false` の意味が `programs.neovim` と食い違う。`programs.neovim` で
  `withPython3 = false`(= 無効化)と書いていた人が同じ行を持ってくると、nvimx では「`PATH` から探す」に
  なる。名前を揃えておいて意味を変えるのは、揃えない方がましである。無効化する手段も無くなる。

3 値はこの両方を避ける: 既定は今日のまま(G5)、`true` / `false` は `programs.neovim` と同じ意味。
代償は型が `nullOr bool` になることと、「`programs.neovim` の既定値」とは一致しないことである。
後者はそもそも一致させようがない(§1.3: stateVersion で `true` にも `false` にもなる)。移行する人には
「今まで得ていた値を明示的に書く」ことを README と option description で求める(§5.6)。

`null` の欠点も書いておく。`null` は「環境次第」であり、nvimx の再現性の売りに反する状態である。
それでも既定にするのは、既定を変えると既存ユーザーが壊れるからで、望ましい状態だからではない。
description には「再現性が欲しければ `true` か `false` を書け」と明記する。

### 3.2 設定の入れ方 —— 2 本目の `--cmd luafile`

provider の設定は Lua 3 行までのファイル(`nvimx-providers.lua`)にして、wrapper に
`--add-flags "--cmd 'luafile <nvimx-providers.lua>'"` を 1 つ足す。全部 `true` のときの中身(実測):

```lua
vim.g.python3_host_prog = "/nix/store/…-nvimx-host-python3-3.14.6-env/bin/nvim-python3"
vim.g.ruby_host_prog = "/nix/store/…-neovim-ruby-env/bin/neovim-ruby-host"
vim.g.node_host_prog = "/nix/store/…-node-client-5.4.0/bin/neovim-node-host"
```

そのときの wrapper スクリプト(実測、`extraPackages = [ pkgs.hello ]` 付き。PATH ブロックは要約):

```
#! /nix/store/…-bash-5.3p15/bin/bash -e
…  PATH の先頭に hello の bin を足すブロック(nvimx の --prefix PATH)…
…  PATH の末尾に neovim-ruby-env の bin を足すブロック(--suffix)…
…  PATH の末尾に nodejs-24.18.0 の bin を足すブロック(--suffix)…
exec -a "$0" "/nix/store/…-nvimx-neovim/bin/.nvim-wrapped"  --cmd 'luafile /nix/store/…-nvimx-bootstrap.lua' --cmd 'luafile /nix/store/…-nvimx-providers.lua' "$@"
```

- **`--cmd` である理由**: `--cmd` はユーザーの config より前に走る。したがって nvimx が入れるのは
  「既定値」であり、`init.lua` で `vim.g.python3_host_prog = …` と書けばそちらが勝つ(G7)。provider の
  探索は遅延なので、`init.lua` の後で初めて使われる時点の値が効く。home-manager が `init.lua` の
  order 200 に入れている(§1.3)のと同じ位置づけである。
- **ファイルにする理由**: nixpkgs の legacy wrapper は `--cmd "lua ${providerLuaRc}"` とインラインで書く
  (`wrapper.nix:156-160`)。`--add-flags` は値をシェルのテキストとして wrapper に埋めるので(#72 計画 R2)、
  Lua の文字列リテラルをその中に入れるとクォートが 3 重になる。パスなら何もクォートするものが無い。
  `bootstrap.lua` と同じ形でもある。
- **`bootstrap.lua` に混ぜない理由**: `bootstrap.lua.in` にプレースホルダを足すと、全 provider が `null` の
  ときにもテンプレートの文字列が変わり、`bootstrap` の store path が全員ぶん動く(G5 が破れる)。
  `bootstrap` は farm と lazy の shim という 1 つの責務に留める。
- **値は `lib.generators.toLua` で書く**: `bootstrap.nix` が `devDirs` にしているのと同じ理由で、
  Lua ソースへの埋め込みを手でクォートしない。

### 3.3 host の組み方 —— 公開パッケージから直接、`rubyEnv` だけ借りる

| provider | host | 出どころ |
|---|---|---|
| python3 | `pkgs.python3.withPackages (ps: [ ps.pynvim ] ++ extraPython3Packages ps)` を `PYTHONPATH` / `PYTHONSAFEPATH` を外す wrapper で包んだもの | nixpkgs の公開 API だけ。`hostPython3`(§1.4)と同じ 2 行を自前で書く |
| ruby | `(pkgs.wrapNeovimUnstable package { }).rubyEnv` の `bin/neovim-ruby-host` | **nixpkgs の wrapper から属性を借りる** |
| node | `pkgs.neovim-node-client` の `bin/neovim-node-host` | nixpkgs の公開パッケージ |

**`wrapNeovimUnstable` を wrapper として使う案は採らない。** nvimx の wrapper を丸ごと置き換えることになり、
`NVIM_SYSTEM_RPLUGIN_MANIFEST` の設定、ビルド中の neovim 起動、`.desktop` の書き換え、wayland の
`wl-clipboard` が全員に入り、G5 が成立しない。nvimx の設計原則 4(注入を最小に保つ)にも反する。

**`providerLuaRc` を文字列として借りる案も採らない。** 2 値なので 3 値(§3.1)を表現できない。
`null` の provider についても `loaded_<prog>_provider=0` が入り、さらに perl が常に無効化される
(§1.4 の実測値)。

**`rubyEnv` だけ借りる理由**: neovim gem を固定している `Gemfile` / `gemset.nix` は
`pkgs/applications/editors/neovim/ruby_provider/` にあり、nixpkgs の属性としては wrapper の
`rubyEnv` からしか届かない。`pkgs.path + "/pkgs/applications/…/ruby_provider"` を `bundlerEnv` に渡す
手もあるが、nixpkgs 内のファイル配置に依存する(by-name への移動で壊れる)。属性の方が安定している。
計画作成時の実測:

- `(pkgs.wrapNeovimUnstable X { }).rubyEnv.drvPath` は `X` が `pkgs.neovim-unwrapped` でも、
  `bin/` しか無い stub(`runCommand "stub" { } "mkdir -p $out/bin"`)でも、`pkgs.neovim.rubyEnv` でも
  **同じ**(`8j5v5cw4lmpw7n2d8iri69x9ybyxg0y1-neovim-ruby-env.drv`)。`rubyEnv` は `package` に依存しない。
  したがって G8 を損なわない。属性を 1 つ読むだけで、wrapper 自体は評価もビルドもされない。
- `programs.neovim` で `withRuby = true` にしたときと同じ derivation なので、移行するユーザーは
  ビルド済みのものをそのまま使える。
- gem(`ruby3.4-neovim-0.10.0` / `msgpack`)は cache.nixos.org から取れた。env 自体はローカルで
  組まれる(symlink を張るだけ)。

ユーザーの `pkgs` は nvimx の pin とは別物であり得る。nixpkgs 24.11 以降はどれも実体のある
`bundlerEnv` を `rubyEnv` として出しているので、そこでは問題にならない(R3 の表)。

§5.1 の `borrowedRubyEnv` は `(…).rubyEnv or null` で受けて `!= null` を見る 2 段にしてあり、
借りられないときは理由と回避を書いた `throw` になる。**これは `wrapNeovimUnstable` の返り値の形が
将来変わった場合への備えであって、今ある nixpkgs のどれかのための経路ではない。** 拾う形は 2 つ:
属性そのものが無くなる場合(`or null`)と、属性はあるが値が `null` になる場合(`or (throw …)` の 1 式では
属性が存在するので発火せず、`cannot coerce null to a string` になる)。計画作成時に、
`wrapNeovimUnstable` を `_: _: { rubyEnv = null; }` と `_: _: { }` に差し替えた**合成の** `pkgs` で
`providers.nix` を評価し、どちらも `nvimx: withRuby = true, but this nixpkgs' wrapNeovimUnstable exposes
no rubyEnv, …` で止まることを確認した。この 2 つは実在する nixpkgs を模したものではない。

**nixpkgs 23.11 / 24.05(どちらも EOL)はこの `throw` に届かない。** 属性の形だけ見れば
`rubyEnv ? null` を `inherit python3Env rubyEnv;` でそのまま出す「値が `null`」の形だが、その wrapper は
既定値の無い必須引数 `packpathDirs` を取るので(release-23.11 `wrapper.nix:37`、release-24.05
`wrapper.nix:40`)、`pkgs.wrapNeovimUnstable package { }` が呼び出しの時点で落ち、`.rubyEnv` を選ぶ前に
終わる。`or` はこれを捕まえられない。nixos-24.05 で `withRuby = true` にしたときの実際のエラーは
`error: function 'wrapper' called without required argument 'packpathDirs'` である(レビューの実測)。
EOL のリリースのために version guard は足さない。R3。

python の interpreter は `pkgs.python3` 固定である。Lua(`package.lua`、`wrapper.nix:20-26`)と違って
host は msgpack-rpc で話す別プロセスなので、選んだ neovim と何かを一致させる必要が無い。nixpkgs の
wrapper も `python3` を callPackage の引数として固定で受けている(`wrapper.nix:12`)。

### 3.4 `PATH` に足すもの、足さないもの

§1.5 の実測に従う:

| | 足すもの | 形 | 理由 |
|---|---|---|---|
| `withNodeJs = true` | `pkgs.nodejs` の `bin/` | `--suffix PATH` | **必須**。無いと host が起動しない |
| `withRuby = true` | `rubyEnv` の `bin/` | `--suffix PATH` | host には不要。`:checkhealth` が `ruby` / `gem` を探すので、無いと動いている provider が「無い」と表示される |
| `withPython3 = true` | 何も足さない | — | `host_prog` が直接実行される |
| (ruby)`GEM_HOME` | **設定しない** | — | 下記 |

- **`--suffix` にする**: nixpkgs と同じ(`wrapper.nix:178-183`)。ユーザーが既に持っている `node` / `ruby`、
  および `extraPackages`(`--prefix`)が前に残る。host 用の interpreter がユーザーの道具を押しのけない。
- **`GEM_HOME` を設定しない**: nixpkgs は `withRuby` のとき `--set GEM_HOME <store path>` を入れるが、
  §1.5 のとおり host の動作にも `:checkhealth` にも要らなかった。一方で wrapper が export した変数は
  neovim が起動するすべてのプロセス(`:terminal` のシェル、`:!`、language server)に継承される
  (#72 計画 R5)。read-only な store path を指す `GEM_HOME` が `:terminal` の中の `gem` / `bundle` に
  効くのは、ruby を書くユーザーにとって害である。nvimx の設計原則 4 は「注入は必要なものだけ」であり、
  必要性を示せないものは入れない。要る人は `extraWrapperArgs = [ "--set" "GEM_HOME" "…" ]` で足せる
  (provider の引数の後に適用される)。**これは `programs.neovim` との意図的な差であり、description と
  README に書く。** R2。
- **`node` が `PATH` に入るのは副作用でもある**: `programs.neovim.withNodeJs = true` を、provider のためでは
  なく「プラグインが `node` を実行できるように」(copilot 系など)書いている人は多い。nvimx でも同じ行で
  同じ効果になる。description に書く。

### 3.5 `extraPython3Packages` が使われないときの警告

`extraPython3Packages` は `withPython3 = true` が組む host にしか届かない。`programs.neovim` も同じで、
あちらは黙って無視する。nvimx では警告する。理由は移行の罠になるからである: `programs.neovim` は
stateVersion `< 26.05` で `withPython3` の既定が `true` だった(§1.3)ので、**`extraPython3Packages` だけ
書いて `withPython3` の行が無い設定が普通に存在する**。それを nvimx に持ってくると、`withPython3` は
`null` になり、パッケージは黙って捨てられ、neovim は `PATH` から別の python を拾う(か、拾えない)。

仕組みは `unknownPluginNames` / `treesitterWithoutPlugin` と同じにする: `makeEnv` が報告し、module が
warning に変える。`make-env.nix` に 1 属性足す:

```nix
unusedPython3Packages = withPython3 != true && extraPython3Packages pkgs.python3.pkgs != [ ];
```

- `!= [ ]` はリストの長さしか見ない。計画作成時に `[ (throw "x") ] != [ ]` が `true` に評価されることを
  確認した。したがって **`makeEnv` を直接呼ぶ場合**、この行は要素を 1 つも force しない
  (`ps: [ (throw "boom") ]` でも評価が通る)。hm module 経由では話が別で、`functionTo (listOf package)` の
  merge が各要素を force するので、`withPython3` を書かずに `extraPython3Packages = ps: [ ps.thisDoesNotExist ]`
  とすると `config.warnings` を読んだ時点で `attribute 'thisDoesNotExist' missing` になる(レビューの実測)。
  存在しないパッケージを書けばエラーになる、という当たり前の挙動であり、直さない。
  起きているのは**要素の force であって型検査ではない**。module 経由で
  `config.programs.nvimx.env.unusedPython3Packages` を読んだ 4 通りの実測(レビューが測り、計画作成者も
  prototype で同じ結果を再現した):

  | `extraPython3Packages` | `withPython3` | 結果 |
  |---|---|---|
  | `ps: [ 42 ]` | 未設定 | `true`(型エラーにならない) |
  | `ps: [ "str" ]` | 未設定 | `true`(同上) |
  | `ps: [ (throw "boom") ]` | 未設定 | `error: boom` |
  | `ps: [ (throw "boom") ]` | `true` | `false`(throw しない。`&&` が短絡し、関数が呼ばれない) |

  つまり要素が force されるのは merge 済みの関数が**呼ばれたとき**で、関数が渡ってきた時点ではない。
  `make-env.nix` に commit するコメントは module 経由の挙動に**一切触れない**。書くのは、この行自体は
  要素を force しないことと、既定の `_: [ ]` が package set に触れないことの 2 点だけである。
  module 経由の挙動の記録はこの表が持つ。
- 既定の `_: [ ]` は引数を捨てるので、`pkgs.python3.pkgs` に触れない。既定の評価コストは増えない
  (既存 check 37 件の drvPath が不変であることと合わせて、G5 の一部)。
- `makeEnv` の返り値が 9 → 10 属性になる。`env` option の description と README の `env` 行の列挙を
  更新する(§5.4 / §5.6)。module 側だけで判定する案は U3。

### 3.6 やらないこと

- **`withPerl`**: issue の題と本文が挙げているのは 3 つである。nixpkgs 自身が
  `# Perl is problematic https://github.com/NixOS/nixpkgs/issues/132368` と書いている(`utils.nix:227`)。
  perl の host は本計画では動作を実測していない。3 値の設計なら後から同じ形で足せる
  (`providers.nix` の `lines` に 1 行)。U1。
- **ビルド時の manifest 生成**: nixpkgs の wrapper がやっている「ビルド中に neovim を起動して
  `+UpdateRemotePlugins`」は、nvimx では (1) remote plugin が lazy.nvim の遅延ロード下にあり、どの
  プラグインを rtp に載せて流すかを farm から決め直す必要がある、(2) 読ませる側の
  `$NVIM_SYSTEM_RPLUGIN_MANIFEST` が nixpkgs 独自パッチで、neovim-nightly-overlay の neovim には無い
  (§1.6)、の 2 点で別の設計になる。本件は「provider を得る supported way」までとし、manifest は
  ユーザーが `:UpdateRemotePlugins` を流す(§1.6 で動くことを確認済み)。R4。
- **`extraPythonPackages` / `withPython2`**: 上流に存在しない(§1.3)。
- **python の interpreter を選ぶオプション**: `programs.neovim` にも無い。R7。
- **`coc.enable` 連動の `withNodeJs`**(home-manager `:520`): nvimx に coc オプションは無い。

### 3.7 `wrapProgram` への足し方 —— drv ハッシュを動かさない

#72 が作った `trailingWrapperArgs`(`wrapper.nix:60-65`)に 1 要素足すだけである:

```nix
  trailingWrapperArgs = lib.concatStringsSep " " (
    lib.filter (s: s != "") [
      luaWrapperArgs
      providerWrapperArgs
      (lib.escapeShellArgs extraWrapperArgs)
    ]
  );
```

`providerWrapperArgs` は `lib.escapeShellArgs (… ++ providers.wrapperArgs)` で、全 provider が `null` なら
リストが空になり、`lib.escapeShellArgs [ ]` は `""` なので `lib.filter` に落とされる。`postBuild` の
文字列はバイト単位で今日のままになる(G5、§6.5 で実測)。

適用順は次のとおりになる:

1. `--add-flags "--cmd 'luafile <bootstrap.lua>'"`
2. `--prefix PATH`(`extraPackages`)
3. `LUA_PATH` / `LUA_CPATH`(`extraLuaPackages`)
4. **provider: `--add-flags "--cmd 'luafile <nvimx-providers.lua>'"`、`--suffix PATH`**(本件)
5. `extraWrapperArgs`

provider を `extraWrapperArgs` の**前**に置くのは #72 の合意(「ユーザーの引数は nvimx の引数の後ろ、
保護しない」)をそのまま延長したものである。ユーザーの `--add-flags "--cmd '…'"` は provider のファイルの
後に走るので `vim.g.*` を読めるし書き換えられる。`--set PATH` は provider の `--suffix` ごと捨てる。
3 と 4 の順は互いに無関係(触る変数が違う)なので、既存の並びの後ろに足す。

## 4. 既存機能との関係

| 機能 | 関係 |
|---|---|
| `extraPackages`(`--prefix PATH`) | 同じ `wrapProgram` 呼び出しに入る。`extraPackages` は先頭、provider は末尾(`--suffix`)。`extraPackages = [ pkgs.nodejs_22 ]` と `withNodeJs = true` を両方書くと、host は `PATH` で先に見つかる `nodejs_22` で起動される。意図どおりの優先順である |
| `extraLuaPackages`(#27) | 独立。Lua の rocks は neovim 内の LuaJIT が読むので `package.lua` に合わせる必要があったが、provider の host は別プロセスなので `package` に何も要求しない(G8)。`extraLuaPackages` が拒否する「passthru.lua の無いパッケージ」でも provider は組める |
| `extraWrapperArgs`(#72) | provider の後に適用される(§3.7)。option description と README の適用順の列挙を 1 項目増やす(§5.4 / §5.6)。#72 の check(`extra-wrapper-args`)は provider を設定しないので drv ごと不変 |
| `package`(neovim の選択) | provider は neovim のビルドに触らない。neovim-nightly-overlay のパッケージでも同じ host が使われる |
| `bootstrap.lua` / lazy の forced opts | 触らない。`bootstrap` の store path は不変 |
| lock パイプライン(`nvimx-lock`) | 無関係。抽出用の headless nvim は lock app が自分で起動する `pkgs.neovim-unwrapped` で、wrapper を通らない |
| `packages.demo` | provider を設定しないので drv 不変(実測)。smoke test の意味も変わらない |
| degraded モード(lock 無し) | provider は lock に依存しない。lock が無くても host は組まれる。`unusedPython3Packages` は `hasLock` を見ない(`unknownPluginNames` と違い、lock が無くても判定できる) |
| 設計原則 4(`docs/architecture.md:121-123`) | 「nvimx が注入するのは … に限る」の列挙に provider を足す。既定では何も注入しないことも書く(§5.7) |
| `defaultEditor`(#67) | 無関係 |

## 5. 実装手順

ブランチは `feat/provider-options`(作成済み)。コミットは 2 つに分ける。#72 の前例
(`60f0b2f docs: add implementation plan for #72` → `ad2f946 feat(hm): add extraWrapperArgs option`)と
同じである:

1. `docs: add implementation plan for #73` —— 本計画ファイル(`docs/plans/73-provider-options.md`)だけ。
   現在は未追跡なので、これを commit しないと §8 手順 9 の `git diff --name-only main` に現れない。
2. `feat(hm): add provider options` —— §5.1〜§5.7 の実装(scope は #72 と同じく `hm`)。本文に
   `Closes #73` を入れる。

**新規ファイル `nix/lib/providers.nix` を作ったら、nix コマンドを叩く前に必ず `git add` すること**
(flake は git に追跡されたファイルしか見ない。忘れると `error: path '…/nix/lib/providers.nix' does not exist`
になる)。

### 5.1 `nix/lib/providers.nix`(新規、全文)

```nix
# Remote-plugin provider hosts (python3 / ruby / node) for the wrapped neovim (#73).
# Returns what nix/lib/wrapper.nix needs and nothing else: `rc`, a Lua file to run with --cmd
# (null when there is nothing to say), and `wrapperArgs`, a flat list of makeWrapper arguments.
#
# Each with* argument has three states, and the third is why this file writes its own lines
# instead of reusing wrapNeovimUnstable's providerLuaRc, which only knows two:
#   null  -> say nothing. neovim searches for a host itself at first use, exactly as it did
#            before this option existed. This is the default, so that nobody's provider changes
#            under them, and so that the wrapper derivation stays byte for byte what it was.
#   true  -> build the host from nixpkgs and point vim.g.<prog>_host_prog at it.
#   false -> vim.g.loaded_<prog>_provider = 0: the provider is off, and neovim skips the search.
# true and false mean what they mean in home-manager's programs.neovim, so a value carried over
# from there keeps its meaning; null is the state programs.neovim does not have.
{ pkgs }:
{
  package,
  withPython3 ? null,
  withRuby ? null,
  withNodeJs ? null,
  extraPython3Packages ? (_: [ ]),
}:
let
  inherit (pkgs) lib;

  # pkgs.python3, the interpreter nixpkgs' own wrapper uses. Unlike Lua (see `lua` in
  # wrapper.nix) the host is a separate process speaking msgpack-rpc, so it does not have to
  # match anything inside the chosen neovim.
  python3Env = pkgs.python3.withPackages (ps: [ ps.pynvim ] ++ extraPython3Packages ps);
  # The interpreter behind a wrapper that drops PYTHONPATH / PYTHONSAFEPATH, the same two
  # nixpkgs' hostPython3 drops: a PYTHONPATH exported for a project (a devShell, a direnv
  # activation) would otherwise be imported into the host and could shadow pynvim itself.
  hostPython3 =
    pkgs.runCommand "nvimx-host-${python3Env.name}" { nativeBuildInputs = [ pkgs.makeWrapper ]; }
      ''
        makeWrapper ${python3Env.interpreter} $out/bin/nvim-python3 \
          --unset PYTHONPATH --unset PYTHONSAFEPATH
      '';

  # The one piece borrowed from nixpkgs' wrapper rather than built here: the Gemfile / gemset.nix
  # that pin the neovim gem live next to that wrapper (pkgs/applications/editors/neovim/
  # ruby_provider), and the wrapper exposes the bundlerEnv built from them as an attribute. It
  # does not depend on `package` at all -- any argument gives the same derivation -- so nothing
  # is assumed about the chosen neovim, and only this attribute is forced, never the wrapper
  # itself.
  # `or null` and then a test for null, not `or (throw ...)`: this guards against the shape of
  # the wrapper's result changing, in either direction it can -- the attribute going away, or
  # being there with nothing in it (a null would get past `or` and surface as "cannot coerce
  # null to a string"). Every nixpkgs from 24.11 on has a real bundlerEnv here. 24.05 and
  # earlier never get this far: their wrapper has a required argument the call below does not
  # pass, and that error is raised before any attribute is looked at.
  borrowedRubyEnv = (pkgs.wrapNeovimUnstable package { }).rubyEnv or null;
  rubyEnv =
    if borrowedRubyEnv != null then
      borrowedRubyEnv
    else
      throw ''
        nvimx: withRuby = true, but this nixpkgs' wrapNeovimUnstable exposes no rubyEnv, so nvimx
        has no Ruby host to point neovim at. Leave withRuby unset and set vim.g.ruby_host_prog
        yourself, to the bin/neovim-ruby-host of a bundlerEnv holding the neovim gem.
      '';

  # One provider, one line -- or none. `exec` is only forced when the provider is on.
  line =
    prog: enabled: exec:
    if enabled == null then
      [ ]
    else if enabled then
      [ "vim.g.${prog}_host_prog = ${lib.generators.toLua { } exec}" ]
    else
      [ "vim.g.loaded_${prog}_provider = 0" ];
  lines =
    line "python3" withPython3 "${hostPython3}/bin/nvim-python3"
    ++ line "ruby" withRuby "${rubyEnv}/bin/neovim-ruby-host"
    ++ line "node" withNodeJs "${pkgs.neovim-node-client}/bin/neovim-node-host";

  # What goes on PATH for a provider that is on. --suffix, not --prefix: these are fallbacks,
  # and a node or ruby the user already has on PATH -- or one named in extraPackages -- stays
  # in front.
  #   node: required. neovim starts the host as `node <host>` (provider#node#Require), so
  #         g:node_host_prog alone fails with "'node' is not executable".
  #   ruby: not required to run the host, which carries its own interpreter. It is what
  #         :checkhealth looks for (`ruby` and `gem` on PATH), and without it a working provider
  #         is reported as missing.
  # python3 needs nothing: g:python3_host_prog is executed directly.
  runtimeDeps =
    lib.optional (withRuby == true) rubyEnv ++ lib.optional (withNodeJs == true) pkgs.nodejs;
in
{
  rc =
    if lines == [ ] then
      null
    else
      pkgs.writeText "nvimx-providers.lua" (lib.concatStringsSep "\n" lines + "\n");
  wrapperArgs = lib.optionals (runtimeDeps != [ ]) [
    "--suffix"
    "PATH"
    ":"
    (lib.makeBinPath runtimeDeps)
  ];
}
```

注意点:

- `line` の 3 分岐の順(`== null` を最初に見る)を崩さないこと。`if enabled then … else …` だけにすると
  `null` で評価エラー、`if enabled == true then … else …` にすると `null` が無効化に化ける(§6.3 M7)。
- `runtimeDeps` の条件は `== true` と書く。`with*` は `null` であり得るので `lib.optional withRuby …` は
  `null` で評価エラーになる。
- `rc` は「言うことが無ければ `null`」である。空のファイルを作ってはいけない(全員の wrapper に
  `--cmd` が 1 本増え、G5 が破れる)。
- `rubyEnv` を `(…).rubyEnv or (throw …)` の 1 式に「簡略化」しないこと。属性が `null` という値で
  存在する形では `or` が発火しない。`or null` で受けて `!= null` を見る 2 段は、wrapper の返り値の形が
  将来変わったときのための備えである(§3.3)。今ある nixpkgs でこの `throw` に届くものは無い ——
  24.11 以降は `rubyEnv` が実体を持ち、24.05 以前は呼び出し自体が `packpathDirs` のエラーで先に落ちる。
  `providers.nix` に commit するコメントもそのとおりに書いてある。「24.05 のための経路」と書き直さないこと。
- `line "python3" …` の第 3 引数は `hostPython3` の wrapper であって `python3Env.interpreter` ではない。
  後者でも `py3eval` は通るが、`PYTHONPATH` が host に漏れる(§6.3 M19)。

### 5.2 `nix/lib/wrapper.nix`(3 箇所)

```diff
@@ -6,6 +6,10 @@
   extraPackages ? [ ],
   extraLuaPackages ? (_: [ ]),
   extraWrapperArgs ? [ ],
+  withPython3 ? null,
+  withRuby ? null,
+  withNodeJs ? null,
+  extraPython3Packages ? (_: [ ]),
   vimAlias ? false,
   viAlias ? false,
 }:
@@ -44,6 +48,29 @@
       "--prefix LUA_CPATH ';' ${lib.escapeShellArg (lua.pkgs.luaLib.genLuaCPathAbsStr luaEnv)}"
     ]
   );
+  # Provider hosts (#73). nix/lib/providers.nix decides what there is to say; here it only has to
+  # reach wrapProgram. The Lua goes in as a second --cmd, after the bootstrap's and before the
+  # user's config, so vim.g.<prog>_host_prog is a default that init.lua can still overwrite.
+  # A file rather than an inline `--cmd "lua ..."`: --add-flags splices its value into the
+  # wrapper script as shell text, and a path has nothing in it to quote.
+  # lib.escapeShellArgs [ ] is "", so with every provider left at null this contributes nothing
+  # and the filter below drops it -- see the note on trailingWrapperArgs.
+  providers = import ./providers.nix { inherit pkgs; } {
+    inherit
+      package
+      withPython3
+      withRuby
+      withNodeJs
+      extraPython3Packages
+      ;
+  };
+  providerWrapperArgs = lib.escapeShellArgs (
+    lib.optionals (providers.rc != null) [
+      "--add-flags"
+      "--cmd 'luafile ${providers.rc}'"
+    ]
+    ++ providers.wrapperArgs
+  );
   # extraWrapperArgs (#72) go last, after everything nvimx passes itself. makeWrapper handles its
   # arguments in order -- environment blocks are written out as it meets them, flags are collected
   # in the same order onto the final exec line -- so last means the user has the final word: a
@@ -60,6 +87,7 @@
   trailingWrapperArgs = lib.concatStringsSep " " (
     lib.filter (s: s != "") [
       luaWrapperArgs
+      providerWrapperArgs
       (lib.escapeShellArgs extraWrapperArgs)
     ]
   );
```

`postBuild`(`:71-78`)は 1 文字も変えない。

### 5.3 `nix/lib/make-env.nix`(4 箇所)

```diff
@@ -15,6 +15,17 @@
   # Threaded straight to the wrapper like the two above, and like them it gets no output of its
   # own -- it is visible only through `wrapped`.
   extraWrapperArgs ? [ ],
+  # Remote-plugin provider hosts (#73): null leaves neovim's own discovery alone, true builds the
+  # host and sets vim.g.<prog>_host_prog, false sets vim.g.loaded_<prog>_provider = 0. Four flat
+  # arguments rather than a `providers = { ... }` attrset, for the reason devPlugins / devPath
+  # give below: they map 1:1 onto the module's options, which are flat because
+  # programs.neovim's are. Threaded straight to the wrapper, which hands them to providers.nix.
+  withPython3 ? null,
+  withRuby ? null,
+  withNodeJs ? null,
+  # A function over pkgs.python3's package set (ps: [ ps.foo ]), the same shape as
+  # programs.neovim.extraPython3Packages. Only reaches a host when withPython3 = true.
+  extraPython3Packages ? (_: [ ]),
   vimAlias ? false,
   viAlias ? false,
   # Same shape as the module's programs.nvimx.plugins, so it can be passed straight through
@@ -136,6 +147,15 @@
     }) pluginDrvs;
   };
 
+  # extraPython3Packages only ever reaches a host that withPython3 = true builds, so naming
+  # packages without it is a silent no-op -- and an easy one to walk into: home-manager's
+  # programs.neovim defaulted withPython3 to true before stateVersion 26.05, so a config written
+  # against it can carry extraPython3Packages and no withPython3 line at all. Reported rather than
+  # thrown, like unknownPluginNames. Comparing against [ ] looks at the list's length and nothing
+  # in it, so this line forces no element of the list by itself; the default (_: [ ]) never
+  # touches the package set at all.
+  unusedPython3Packages = withPython3 != true && extraPython3Packages pkgs.python3.pkgs != [ ];
+
   bootstrap = mkBootstrap { inherit farm devDirs; };
   wrapped = mkWrapper {
     inherit
@@ -144,6 +164,10 @@
       extraPackages
       extraLuaPackages
       extraWrapperArgs
+      withPython3
+      withRuby
+      withNodeJs
+      extraPython3Packages
       vimAlias
       viAlias
       ;
@@ -159,6 +183,7 @@
     treesitterWithoutPlugin
     devDirs
     unknownDevPluginNames
+    unusedPython3Packages
     hasLock
     ;
 }
```

### 5.4 `nix/home-manager/default.nix`(6 箇所)

オプション 4 つを `extraWrapperArgs`(`:148-196`)と `devPlugins`(`:198`)のあいだに足す。
`extraWrapperArgs` の description は 2 か所直す: 適用順の文(`:174-176`)に provider を足し、
「保護しない」の段落(`:183-184`)の「`--set PATH` discards extraPackages」に、**provider が足した
`PATH` も一緒に消え、node の host が起動しなくなる**ことを書き足す(§3.7 のとおり、`--set PATH` は
provider の `--suffix` ごと捨てる。今日の文面のままだと、この変更の後は半分しか本当でなくなる)。
`env` の description の列挙、`warnings`、`makeEnv` の `inherit (cfg)` を更新する。

```diff
@@ -173,7 +173,8 @@
 
         The arguments are appended after nvimx's own, and makeWrapper applies them in order:
         first --add-flags "--cmd 'luafile <bootstrap.lua>'", then --prefix PATH for
-        extraPackages, then LUA_PATH / LUA_CPATH for extraLuaPackages, then these. They
+        extraPackages, then LUA_PATH / LUA_CPATH for extraLuaPackages, then what withPython3 /
+        withRuby / withNodeJs ask for (a second --cmd and a --suffix PATH), then these. They
         therefore act on what nvimx set up: a --prefix PATH here lands in front of
         extraPackages, an --add-flags here follows nvimx's --cmd, and a --set replaces the
         variable outright. home-manager orders this differently: it applies extraPackages (as
@@ -181,9 +182,11 @@
         that touches PATH can behave differently here.
 
         nvimx protects none of its own arguments from them. `--set PATH` discards
-        extraPackages. `--set LUA_PATH` discards the rocks' Lua modules, and the interpreter's
-        own default search path too unless the new value contains `;;` (LUA_CPATH is a separate
-        variable and stays). An --add-flags can change how neovim starts. That is deliberate --
+        extraPackages, and with it the PATH entries withRuby / withNodeJs added -- the Node.js
+        host no longer starts without its node. `--set LUA_PATH` discards the rocks' Lua
+        modules, and the interpreter's own default search path too unless the new value
+        contains `;;` (LUA_CPATH is a separate variable and stays). An --add-flags can change
+        how neovim starts. That is deliberate --
         this is the escape hatch -- so what you write here is yours to keep working.
 
         Some makeWrapper arguments take shell text rather than a literal value: --add-flags,
@@ -195,6 +198,92 @@
       '';
     };
 
+    withPython3 = lib.mkOption {
+      type = lib.types.nullOr lib.types.bool;
+      default = null;
+      example = true;
+      description = ''
+        The Python 3 provider, for remote plugins written in Python (rplugin/python3) and for
+        :python3 / py3eval().
+
+        true builds a host from nixpkgs -- pkgs.python3 with pynvim, plus extraPython3Packages --
+        and points vim.g.python3_host_prog at it. false sets vim.g.loaded_python3_provider = 0:
+        the provider is off and neovim does not search for one. Both mean what they mean in
+        home-manager's programs.neovim.withPython3.
+
+        null (the default) is the state programs.neovim does not have: nvimx says nothing, and
+        neovim looks for a python3 with pynvim on PATH the first time something needs it. That is
+        what nvimx did before this option existed, so a setup relying on it keeps working -- but
+        it depends on what happens to be on PATH, so set true or false to make it reproducible.
+        programs.neovim's own default is false from stateVersion 26.05 on and true before; when
+        porting a configuration, write the value you were getting.
+
+        The setting is applied with --cmd, before your init.lua, so a vim.g.python3_host_prog
+        you set there still wins.
+
+        nvimx does not generate a remote-plugin manifest. Run :UpdateRemotePlugins yourself, and
+        again after a plugin update: the manifest records the plugin's path, which is a Nix store
+        path that changes with the lock.
+      '';
+    };
+
+    extraPython3Packages = lib.mkOption {
+      type = lib.types.functionTo (lib.types.listOf lib.types.package);
+      default = _: [ ];
+      defaultText = lib.literalExpression "ps: [ ]";
+      example = lib.literalExpression "ps: [ ps.jupyter-client ]";
+      description = ''
+        Python packages to add to the Python 3 provider's host, as a function over a Python
+        package set -- the same shape as home-manager's programs.neovim.extraPython3Packages.
+        The set is pkgs.python3's (pkgs.python3.pkgs); pynvim is always included.
+
+        Only used when withPython3 = true: there is no host to add them to otherwise, and nvimx
+        warns at activation time if packages are named without it. They are importable by
+        Python remote plugins and by :python3, not by a python you start from :terminal -- no
+        interpreter is put on PATH. Use extraPackages for that.
+      '';
+    };
+
+    withRuby = lib.mkOption {
+      type = lib.types.nullOr lib.types.bool;
+      default = null;
+      example = true;
+      description = ''
+        The Ruby provider, for remote plugins written in Ruby and for :ruby / rubyeval().
+
+        true points vim.g.ruby_host_prog at the neovim-ruby-host nixpkgs builds for its own
+        neovim wrapper, false sets vim.g.loaded_ruby_provider = 0, and null (the default) leaves
+        neovim's own discovery alone -- the same three states as withPython3, with the same
+        relation to home-manager's programs.neovim.withRuby (false from stateVersion 26.05 on,
+        true before).
+
+        With true, that Ruby environment's bin/ is appended to the wrapper's PATH (--suffix, so
+        a ruby you already have stays in front), which is what :checkhealth looks for. Unlike
+        nixpkgs' wrapper, nvimx does not set GEM_HOME: the host runs without it, and it would be
+        exported to every process neovim starts. Add it with extraWrapperArgs if you need it.
+      '';
+    };
+
+    withNodeJs = lib.mkOption {
+      type = lib.types.nullOr lib.types.bool;
+      default = null;
+      example = true;
+      description = ''
+        The Node.js provider, for remote plugins written in JavaScript (rplugin/node).
+
+        true points vim.g.node_host_prog at pkgs.neovim-node-client's neovim-node-host, false
+        sets vim.g.loaded_node_provider = 0, and null (the default) leaves neovim's own discovery
+        alone -- the same three states as withPython3. programs.neovim.withNodeJs defaults to
+        false.
+
+        With true, pkgs.nodejs's bin/ is appended to the wrapper's PATH (--suffix, so a node you
+        already have stays in front): neovim starts the host as `node <host>`, so it has to be
+        there. As with programs.neovim, appending it also makes `node` available to plugins
+        that run it themselves. The host therefore runs under the first node on PATH -- yours,
+        if you have one; put pkgs.nodejs in extraPackages to pin it.
+      '';
+    };
+
     devPlugins = lib.mkOption {
       type = lib.types.listOf lib.types.str;
       default = [ ];
@@ -346,7 +435,7 @@
       description = ''
         The result of makeEnv (farm / bootstrap / wrapped / pluginDrvs /
         unknownPluginNames / treesitterWithoutPlugin / devDirs / unknownDevPluginNames /
-        hasLock).
+        unusedPython3Packages / hasLock).
         By default it is built automatically from the options above.
         This is an escape hatch for advanced users who want to supply it directly.
       '';
@@ -385,6 +474,12 @@
         ${lib.concatMapStringsSep "\n" (n: "  - ${n}") (cfg.env.unknownDevPluginNames or [ ])}
         Use the name lazy derived for the plugin (the key in nvimx-lock/plugins.json); if you
         added the plugin to your spec without re-locking, re-run `nvimx-lock`.
+      ''
+      ++ lib.optional (cfg.env.unusedPython3Packages or false) ''
+        programs.nvimx: extraPython3Packages names packages, but withPython3 is not true, so
+        there is no Python 3 host to add them to and they are ignored.
+        Set withPython3 = true. (home-manager's programs.neovim turned it on by default before
+        stateVersion 26.05; nvimx never does.)
       '';
 
     programs.nvimx.env = lib.mkDefault (
@@ -395,6 +490,10 @@
           extraPackages
           extraLuaPackages
           extraWrapperArgs
+          withPython3
+          withRuby
+          withNodeJs
+          extraPython3Packages
           vimAlias
           viAlias
           plugins
```

description は英語(リポジトリの他の option と同じ)。書いてあることは §3 の決定そのものである:
3 値の意味、`programs.neovim` の既定値との関係、`--cmd` なので `init.lua` が勝つこと、`PATH` に足すもの、
`GEM_HOME` を設定しないこと、manifest を生成しないこと。

### 5.5 `flake.nix`(check 2 件)

- `hm-module-providers` を `hm-module-wrapper-args`(`:284-293`)の直後、`# defaultEditor (#67) deploys …`
  のコメント(`:294`)の前に足す。本文は §6.2。
- `providers` を `extra-wrapper-args`(`:625-778`)の直後、`# build.kind == "shell": …` のコメント(`:779`)の
  前に足す。本文は §6.1。

どちらも `checks = forAllSystems (system: …)` の中なので、`forAllSystems` の扱いは既存 check と同じである
(CLAUDE.md の Multi-system の注意は満たしている)。`.github/workflows/` は触らない(`nix flake check` が
新 check を自動で拾う)。

### 5.6 `README.md`(4 箇所)

**(1) Options 表**(`:210-` の表)。`extraWrapperArgs` の行の直後に 4 行足す:

```markdown
| `withPython3` | `nullOr bool` | `null` | The Python 3 provider. `true`: build a host from nixpkgs (`pkgs.python3` with `pynvim`) and point `vim.g.python3_host_prog` at it. `false`: disable the provider. `null`: leave Neovim's own discovery alone, as before this option existed. See [Providers](#providers). |
| `extraPython3Packages` | `functionTo (listOf package)` | `ps: [ ]` | Python packages to add to the Python 3 provider's host, as a function over `pkgs.python3`'s package set. Only used when `withPython3 = true`. See [Providers](#providers). |
| `withRuby` | `nullOr bool` | `null` | The Ruby provider, with the same three states. `true` uses the `neovim-ruby-host` nixpkgs builds and appends its Ruby to the wrapper's `PATH`; `GEM_HOME` is not set. See [Providers](#providers). |
| `withNodeJs` | `nullOr bool` | `null` | The Node.js provider, with the same three states. `true` uses `pkgs.neovim-node-client` and appends `pkgs.nodejs` to the wrapper's `PATH`. See [Providers](#providers). |
```

**(2) 同じ表の `env` の行**。列挙の `unknownDevPluginNames` と `hasLock` のあいだに
`` `unusedPython3Packages` `` を足す(`… / `unknownDevPluginNames` / `unusedPython3Packages` / `hasLock`)`)。

**(3) `### Wrapper arguments` の適用順の列挙と、その直後の段落**(`:480-492`)。4 番目に provider を入れ、
`extraWrapperArgs` を 5 番目にする。直後の「So yours act on what the first three built.」を
「the first four」に直す。同じ段落の「`--set PATH` discards `extraPackages`;」(`:489`)には、§5.4 の
description と同じ半文を足す(provider の `PATH` も消え、node の host が起動しなくなる):

```markdown
1. `--add-flags "--cmd 'luafile <bootstrap.lua>'"`
2. `--prefix PATH` for `extraPackages`
3. `--set-default` and `--prefix` on `LUA_PATH` / `LUA_CPATH` for `extraLuaPackages`
4. a second `--cmd` and a `--suffix PATH` for `withPython3` / `withRuby` / `withNodeJs`
5. your `extraWrapperArgs`

So yours act on what the first four built. A `--prefix PATH` lands in front of `extraPackages`, an
`--add-flags` follows nvimx's `--cmd`, and a `--set` replaces the variable outright. nvimx protects
none of its own arguments: `--set PATH` discards `extraPackages`, and with it the `PATH` entries
`withRuby` / `withNodeJs` added (the Node.js host no longer starts without its `node`);
`--set LUA_PATH` discards the
rocks' Lua modules, …(以降は変更なし)
```

(`--set LUA_PATH discards the` で行を切ってあるのは、後続の行を動かさないためである。見た目を
整えたければ段落ごと reflow してよい。markdown の出力は変わらない。)

**(4) 新しい節 `### Providers`**。`### Wrapper arguments` の節の末尾(「A variable set here is exported, …」
の段落)と `## How it works` のあいだに足す:

````markdown
### Providers

Remote plugins written in Python, Ruby or JavaScript — and `:python3` / `:ruby` — need a *provider*:
a host process Neovim starts and talks to. Three options, named after home-manager's
`programs.neovim` ones, say where each host comes from:

```nix
programs.nvimx = {
  withPython3 = true;                                # rplugin/python3, :python3, py3eval()
  extraPython3Packages = ps: [ ps.jupyter-client ];  # importable from that host
  withRuby = false;                                  # never used here: switch it off
  # withNodeJs is not mentioned, so Neovim keeps searching for a host by itself
};
```

Each `with*` option has three states:

| value | what nvimx does | what Neovim does |
| --- | --- | --- |
| `true` | builds the host from nixpkgs and sets `vim.g.<name>_host_prog` | uses that host instead of searching for one |
| `false` | sets `vim.g.loaded_<name>_provider = 0` | the provider is off, and no search happens |
| `null` (the default) | nothing | searches for a host itself the first time one is needed (`:help provider`) |

`true` and `false` mean what they mean in `programs.neovim`. `null` is nvimx's own: it is what
nvimx did before these options existed, so nothing changes for a setup that relies on it — but it
depends on what that search finds on the machine. Write `true` or `false` to take it out of the
picture: with `true` the host comes from Nix on every machine (for Node.js the host does, its
interpreter not quite — see below).

**Coming from `programs.neovim`, write the value you were getting.** Its defaults are not nvimx's:
there `withPython3` and `withRuby` default to `true` before `home.stateVersion = "26.05"` and to
`false` from then on, and `withNodeJs` to `false`. In particular, an `extraPython3Packages` line
that worked without any `withPython3` line needs `withPython3 = true` here; nvimx warns at
activation time when it sees one without the other.

What `true` builds, and what it adds to the wrapper besides the `vim.g` setting:

- **Python 3** — `pkgs.python3` with `pynvim` and your `extraPython3Packages`. Nothing is added to
  `PATH`: the packages are importable by Python remote plugins and `:python3`, not by a `python`
  you start from `:terminal`.
- **Ruby** — the `neovim-ruby-host` nixpkgs builds for its own Neovim wrapper. Its Ruby is appended
  to the wrapper's `PATH`, which is what `:checkhealth` looks for. Unlike nixpkgs' wrapper, nvimx
  does not set `GEM_HOME`: the host runs without it, and it would be exported to every process
  Neovim starts. Add it through [`extraWrapperArgs`](#wrapper-arguments) if you need it.
- **Node.js** — `pkgs.neovim-node-client`, with `pkgs.nodejs` appended to the wrapper's `PATH`:
  Neovim starts the host as `node <host>`, so it has to be there. As with `programs.neovim`,
  appending it also makes `node` available to plugins that run it themselves. The host therefore
  runs under the first `node` on `PATH` — yours, if you have one; put `pkgs.nodejs` in
  `extraPackages` to pin it.

`PATH` entries are *appended*, so a `node` or `ruby` you already have — or one in `extraPackages` —
stays in front. The `vim.g` settings are applied with `--cmd`, before your `init.lua`, so a
`vim.g.python3_host_prog` you set there still wins.

Two things these options do not do:

- **No remote-plugin manifest is generated.** Run `:UpdateRemotePlugins` yourself, and again after
  every plugin update: the manifest records each plugin's path, which is a Nix store path that
  changes with the lock.
- **There is no `withPerl`.** Neovim's own discovery applies to Perl as it always has; put
  `vim.g.loaded_perl_provider = 0` in your `init.lua` to switch it off.
````

`#providers` というアンカーが README 内で他と衝突しないことを確認すること(計画作成時点で
`grep -n '^#\+ .*[Pp]rovider' README.md` は 0 件)。

### 5.7 `docs/architecture.md`(7 箇所)

1. **Build flow の mermaid**(`:108`)。`K` のラベルに provider を足す:
   `K["wrapProgram neovim<br/>--cmd luafile<br/>PATH / LUA_PATH / LUA_CPATH<br/>+ provider hosts<br/>+ extraWrapperArgs"]`
2. **設計原則 4**(`:121-123`、3 文ある)。`:122` の `The user's lua stays unmodified.` の**直後**、
   `:123` の `` `extraWrapperArgs` sits outside that limit on purpose: … `` の**直前**に、独立した 1 行として
   1 文足す(`:121` の太字の文と `:122` のあいだではない。§8 手順 10 の件数ではこの 2 つの位置を
   区別できないので、ここで決める):
   ``With `withPython3` / `withRuby` / `withNodeJs` set, a second `--cmd luafile` (one `vim.g` line per provider that was given a value) and, for Ruby / Node.js set to `true`, a `--suffix PATH` join that list; left at `null`, the default, they add nothing at all.``
3. **build 時のデータフロー [5]**(`:173-176`、該当行は `:175`)。`extraPackages on PATH and extraLuaPackages' rock env on
   LUA_PATH / LUA_CPATH,` の行の後に
   `the providers' --cmd 'luafile <nvimx-providers.lua>' (only for providers given a value) and --suffix PATH (Ruby / Node.js set to true),`
   を足す(`then the user's extraWrapperArgs …` の行はそのまま)。
4. **hm module interface の例**(`:428-430`)。`extraWrapperArgs = [ ];` の行の後に 4 行足す。
   下のコードブロックはこのリスト項目の中にあるので、markdown のソースからそのまま写すと行頭に空白が
   3 つ余分に付く。**それを落として**、前後の行(行頭の空白 2 つ)に揃えること:

   ```nix
     withPython3 = null;              # true: host from nixpkgs / false: provider off / null (default): neovim's own discovery
     extraPython3Packages = ps: [ ];  # python packages for that host (withPython3 = true only)
     withRuby = null;                 # same three states
     withNodeJs = null;               # same three states
   ```
5. **Repository layout**(`:497`)。`wrapper.nix` の行のコメントを
   `# wrapProgram for neovim (PATH / LUA_PATH / LUA_CPATH / provider hosts / extraWrapperArgs)` にし、
   その直後に 1 行足す:
   `    providers.nix            # provider hosts (python3 / ruby / node): the --cmd lua file + PATH entries`
6. **flake outputs の checks 列挙**(`:522`)。`hm-module-wrapper-args,` の後に `hm-module-providers,` を、
   末尾の `extra-wrapper-args` の後に `, providers` を足す。
7. **Edge cases 表**(`:529-545`)。`luarocks (rocks)` の行の後に 1 行足す:

   ```markdown
   | Remote plugins (Python / Ruby / Node.js providers) | `withPython3` / `withRuby` / `withNodeJs` build the host from nixpkgs (`true`), switch the provider off (`false`), or leave neovim's own discovery alone (`null`, the default). With `true`, only the Node.js host's interpreter still comes from `PATH`: neovim runs `node <host>`, and nvimx appends its `node` rather than prepending it. The remote-plugin manifest is **not** generated at build time: `:UpdateRemotePlugins` writes it to stdpath("data"), which is user-owned, and it has to be re-run after a plugin update because it records store paths. There is no `withPerl` |
   ```

### 5.8 触らないもの

- `lua/`(lua は 1 行も変えない。`stylua.toml` / `.luacheckrc` も触らないので `--clear-cache` は不要)
- `nix/lib/bootstrap.nix` / `lua/nvimx/bootstrap.lua.in`(§3.2)
- `nix/lib/default.nix`(`providers.nix` は `wrapper.nix` が直接 import する。`lib` の出力には足さない。
  `treesitter.nix` などが公開されているのは check が単体で使うからで、本件の check は `makeEnv` 経由で足りる)
- `tests/fixtures/`(remote plugin の fixture は check の中の heredoc で足りる。ファイルを増やさない)
- `templates/default/`(provider に触れていない。既定が no-op なので書き足す必要が無い)
- `.github/workflows/`(CLAUDE.md: check の追加は `check.yml` も含めて編集不要。`nix flake check` が拾う)
- `CLAUDE.md` / `.claude/skills/`

## 6. テスト

### 6.1 `checks.providers`(新設)

degraded モード(lock 無し)で wrapper を 5 つ作り、**実際に neovim を起動して provider を使う**。
`vim.g.*_host_prog` を読み返すだけでは足りない: node は `host_prog` が正しくても `PATH` に `node` が無ければ
動かない(§1.5)ので、「設定された」と「動く」が別である。

| wrapper | 設定 | 見るもの |
|---|---|---|
| `untouched` | 何も設定しない | wrapper スクリプトに `providers` の文字が無い。`vim.g` の 6 変数がすべて `nil`。builder の `PATH` に `python3` / `ruby` / `node` が無い(= `on` の結果が wrapper 由来であることの対照) |
| `on` | 3 つとも `true`、`extraPython3Packages = ps: [ ps.six ]`、`extraPackages = [ pkgs.hello ]` | `host_prog` が store path。`py3eval("1 + 1") == 2`、`six` が import できる、`rubyeval("1 + 1") == 2`、`remote#host#Require("node") > 0`。`PATH` の先頭が hello、末尾 2 つが ruby / node。`python3` は `PATH` に無い。`GEM_HOME` が `nil`。`PYTHONPATH` / `PYTHONSAFEPATH` を export して起動しても host の `os.environ` に届かない(`pythonpath.lua`)。Python の remote plugin を `:UpdateRemotePlugins` で登録して呼べる |
| `off` | 3 つとも `false` | `loaded_<prog>_provider == 0`、`host_prog` が `nil`、`ruby` / `node` が `PATH` に無い |
| `mixed` | `withPython3 = false`、`withNodeJs = true`(ruby は書かない) | python3 は無効、ruby は 2 変数とも `nil`、node は `host_prog` あり・`PATH` に `node` あり・`ruby` 無し |
| `ordered` | `withRuby = false` + `extraWrapperArgs` の `--cmd` で `vim.g.loaded_ruby_provider` を別の変数に写す | 写した値が `0`(= ユーザーの `--cmd` が provider のファイルの後に走った) |

評価レベルの assert(`failures`):

- stub の neovim パッケージ(`bin/` だけ)に 3 つとも `true` を渡して `wrapped.drvPath` が評価できる(G8)
- module の `withPython3` / `withRuby` / `withNodeJs` の宣言された既定値が `null`(G5 の宣言側)
- `unusedPython3Packages` の 4 隅(既定 / `withPython3 = true` だけ / パッケージだけ / 両方)
- module が警告を出す場合と出さない場合

module の pass-through(`moduleWrapped`)は 4 オプションすべてに「見える値」を与える:
python3 を on、パッケージ 1 つ、ruby を off、node を off。`inherit (cfg)` から 1 語落とすごとに別の
assert が落ちる(§6.3 M1〜M4)。

本文(nixfmt 正規形、逐語):

```nix
          # withPython3 / withRuby / withNodeJs / extraPython3Packages (#73). Like
          # extraLuaPackages the promise is a runtime one -- a host that neovim can actually start
          # and talk to -- so this starts the wrapped neovim and uses each provider, rather than
          # reading vim.g.*_host_prog back and believing it. That distinction is the point for
          # node: its host_prog can be set perfectly and the provider still fail, because neovim
          # runs it as `node <host>` and needs node on PATH (measured: "'node' is not
          # executable"). Each option has three states, so the wrappers below are chosen to tell
          # them apart: `on` (all true), `off` (all false), `mixed` (one of each), `untouched`
          # (all null, the default). Degraded mode for the same reason as checks.extra-lua-packages:
          # nothing here depends on the lock, so not one plugin source is fetchTree'd.
          providers =
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
              # six: a pure-Python package that pynvim does not pull in (its own dependencies are
              # msgpack and greenlet), so importing it proves extraPython3Packages reached the
              # host rather than riding along with pynvim.
              pythonPackages = ps: [ ps.six ];
              # Everything on, with an extraPackages entry so that there is a --prefix PATH of
              # nvimx's for the providers' --suffix PATH to be told apart from.
              on = mkEnv {
                withPython3 = true;
                extraPython3Packages = pythonPackages;
                withRuby = true;
                withNodeJs = true;
                extraPackages = [ pkgs.hello ];
              };
              off = mkEnv {
                withPython3 = false;
                withRuby = false;
                withNodeJs = false;
              };
              # One of each state, on three different providers: python3 off, ruby not mentioned,
              # node on. `on` and `off` alone cannot see one option leaking into another -- a
              # runtimeDeps that put ruby on PATH whenever *any* provider is on, or a null that
              # falls through to the false branch -- because in them all three always agree.
              mixed = mkEnv {
                withPython3 = false;
                withNodeJs = true;
              };
              # The control, and the proof that the default is a genuine no-op: no provider file,
              # no vim.g.* of nvimx's, nothing new on PATH. (That the derivation itself is
              # unchanged, not merely the script, is shown by the drvPath comparison in the plan's
              # verification steps -- like checks.extra-lua-packages' `untouched`, this is the
              # cheap standing proxy for that, not a proof of it.)
              untouched = mkEnv { };
              # Order against extraWrapperArgs: the provider arguments come before the user's, so
              # a --cmd of the user's runs after nvimx's provider file and can read -- or replace
              # -- what it set. withRuby = false, so that seeing the order costs no host build.
              ordered = mkEnv {
                withRuby = false;
                extraWrapperArgs = [
                  "--add-flags"
                  "--cmd 'lua vim.g.nvimx_test_seen = vim.g.loaded_ruby_provider'"
                ];
              };
              # Evaluates the module with the given programs.nvimx settings. The results are read
              # through .config (the wrapper, the warnings) and, for moduleEval, .options (the
              # declared defaults). Degraded lockDir, to stay offline.
              evalHm =
                nvimxConfig:
                home-manager.lib.homeManagerConfiguration {
                  inherit pkgs;
                  modules = [
                    self.homeModules.nvimx
                    {
                      # The three home.* settings homeManagerConfiguration requires, same values
                      # mkHmCheck uses. Only .config and .options are read; no activation package
                      # is built.
                      home.username = "nvimx-test";
                      home.homeDirectory = "/home/nvimx-test";
                      home.stateVersion = "25.05";
                      programs.nvimx = {
                        enable = true;
                        configDir = ./tests/fixtures/basic-config;
                        lockDir = ./tests/fixtures/basic-config/no-such-lock;
                      }
                      // nvimxConfig;
                    }
                  ];
                };
              # The module's pass-through, for the reason checks.extra-lua-packages' moduleWrapped
              # gives: mkHmCheck asserts nothing, and the four formals in nix/lib/make-env.nix all
              # carry defaults, so dropping any one of them from the `inherit (cfg)` list in
              # nix/home-manager/default.nix type-checks, builds, and silently ignores the option.
              # All four are set, each to something module.lua can see, so that each drop has its
              # own failing assert: python3 on, a package for it, ruby off, node off.
              # Two of the four drops are reported somewhere else first, though. Without
              # withPython3 or without extraPython3Packages, unusedPython3Packages flips, so the
              # evaluation-level warning asserts in `failures` fail before module.lua is ever
              # run ("must not warn when withPython3 = true" / "must warn about
              # extraPython3Packages ..."), naming the symptom rather than the dropped word.
              # module.lua's first two asserts are the backstop for the day those two change.
              moduleEval = evalHm {
                withPython3 = true;
                extraPython3Packages = pythonPackages;
                withRuby = false;
                withNodeJs = false;
              };
              moduleWrapped = moduleEval.config.programs.nvimx.env.wrapped;
              # extraPython3Packages without withPython3: the silent no-op the warning exists for.
              forgotten = evalHm { extraPython3Packages = pythonPackages; };
              warnsAboutPython = eval: lib.any (lib.hasInfix "extraPython3Packages") eval.config.warnings;
              # A stub for a neovim package nvimx knows nothing about. The hosts are separate
              # processes, so unlike extraLuaPackages nothing here may ask the package for a
              # passthru (lua, version, meta, ...): users bring their own neovim, and
              # wrapNeovimUnstable -- which nix/lib/providers.nix reaches into for rubyEnv -- is
              # exactly the kind of function that might.
              stub = pkgs.runCommand "nvimx-neovim-stub" { } "mkdir -p $out/bin";
              wraps = args: (builtins.tryEval (builtins.seq (mkEnv args).wrapped.drvPath null)).success;
              failures =
                lib.optional (
                  !(wraps {
                    package = stub;
                    withPython3 = true;
                    withRuby = true;
                    withNodeJs = true;
                  })
                ) "the provider hosts must not depend on anything the neovim package exposes"
                # The declared defaults, read out of the declaration rather than observed: no
                # behavioural assert here can tell a module default of null from one of false.
                # moduleEval sets all three explicitly, `forgotten` warns under either, and
                # `untouched` goes through makeEnv's defaults, not the module's. null is what
                # keeps an existing user's wrapper unchanged, so a default of false --
                # programs.neovim's -- would silently switch their providers off.
                ++
                  lib.concatMap
                    (
                      n:
                      lib.optional (
                        moduleEval.options.programs.nvimx.${n}.default != null
                      ) "${n} must be declared with default = null"
                    )
                    [
                      "withPython3"
                      "withRuby"
                      "withNodeJs"
                    ]
                # unusedPython3Packages, all four corners. The last two are the pair that matters:
                # packages with no host must be reported, and the same packages with a host must
                # not.
                ++ lib.optional ((mkEnv { }).unusedPython3Packages
                ) "the default extraPython3Packages must not be reported as unused"
                ++ lib.optional ((mkEnv { withPython3 = true; }).unusedPython3Packages
                ) "withPython3 = true alone must not be reported as unused packages"
                ++ lib.optional (
                  !(mkEnv { extraPython3Packages = pythonPackages; }).unusedPython3Packages
                ) "extraPython3Packages without withPython3 = true must be reported as unused"
                ++ lib.optional on.unusedPython3Packages "extraPython3Packages with withPython3 = true must not be reported as unused"
                # ... and the module has to turn the report into a warning, and only then.
                ++ lib.optional (
                  !(warnsAboutPython forgotten)
                ) "the module must warn about extraPython3Packages without withPython3 = true"
                ++ lib.optional (warnsAboutPython moduleEval) "the module must not warn when withPython3 = true";
            in
            pkgs.runCommand "providers" { } (
              if failures == [ ] then
                ''
                  export HOME=$TMPDIR

                  # The default must leave the wrapper alone: no provider file among its flags.
                  # test -f first, for the reason checks.extra-lua-packages gives (grep -q on a
                  # missing file is indistinguishable from "no match" inside an `if`).
                  test -f ${untouched.wrapped}/bin/nvim
                  if grep -q providers ${untouched.wrapped}/bin/nvim; then
                    echo "with every provider left at null the wrapper must not mention providers" >&2
                    exit 1
                  fi

                  cat > untouched.lua <<'LUA'
                  for _, prog in ipairs({ "python3", "ruby", "node" }) do
                    assert(vim.g[prog .. "_host_prog"] == nil, prog .. ": host_prog is set with the option at null")
                    assert(vim.g["loaded_" .. prog .. "_provider"] == nil, prog .. ": provider disabled with the option at null")
                  end
                  -- The control for everything on.lua concludes: the builder has none of the three
                  -- interpreters, so a provider that works in on.lua got its host from the wrapper.
                  for _, exe in ipairs({ "python3", "ruby", "node" }) do
                    assert(vim.fn.executable(exe) == 0, "the builder's PATH already has " .. exe .. "; on.lua proves nothing")
                  end
                  assert(vim.fn.has("python3") == 0 and vim.fn.has("ruby") == 0, "a provider works with no option set")
                  LUA
                  ${untouched.wrapped}/bin/nvim --clean -l untouched.lua

                  cat > on.lua <<'LUA'
                  local function in_store(p)
                    return type(p) == "string" and p:find("${builtins.storeDir}/", 1, true) == 1
                  end
                  for _, prog in ipairs({ "python3", "ruby", "node" }) do
                    assert(in_store(vim.g[prog .. "_host_prog"]), prog .. ": host_prog is not a store path: " .. vim.inspect(vim.g[prog .. "_host_prog"]))
                    assert(vim.g["loaded_" .. prog .. "_provider"] == nil, prog .. ": disabled and enabled at once")
                  end

                  -- Each host has to start and answer, not merely be named.
                  assert(vim.fn.has("python3") == 1, "the python3 provider is not usable")
                  assert(vim.fn.py3eval("1 + 1") == 2, "the python3 host did not evaluate")
                  assert(vim.fn.py3eval('__import__("six").__name__') == "six", "extraPython3Packages did not reach the python3 host")
                  assert(vim.fn.has("ruby") == 1, "the ruby provider is not usable")
                  assert(vim.fn.rubyeval("1 + 1") == 2, "the ruby host did not evaluate")
                  -- There is no has("node"): node only ever serves remote plugins. Requiring the
                  -- host is what a node remote plugin's first call does, and it returns the
                  -- channel of the started process. This is the assert that fails without node on
                  -- PATH.
                  assert(vim.fn["remote#host#Require"]("node") > 0, "the node host did not start")

                  -- PATH: the hosts' entries are appended (--suffix), so extraPackages -- and
                  -- anything the user already had -- stays in front of them.
                  local path = vim.split(vim.env.PATH, ":", { plain = true })
                  assert(vim.uv.fs_stat(path[1] .. "/hello"), "extraPackages must stay at the front of PATH: " .. vim.env.PATH)
                  assert(vim.uv.fs_stat(path[#path - 1] .. "/ruby"), "the ruby env must be appended to PATH: " .. vim.env.PATH)
                  assert(vim.uv.fs_stat(path[#path] .. "/node"), "nodejs must be appended to PATH: " .. vim.env.PATH)
                  -- python3 is executed through host_prog and needs nothing on PATH; the option
                  -- must not start putting an interpreter there (that is extraPackages' job).
                  assert(vim.fn.executable("python3") == 0, "the python3 host leaked onto PATH")
                  -- Deliberately not nixpkgs' wrapper: the ruby host runs without GEM_HOME, and a
                  -- GEM_HOME here would be exported to every process neovim starts.
                  assert(vim.env.GEM_HOME == nil, "GEM_HOME must not be set: " .. tostring(vim.env.GEM_HOME))
                  LUA
                  ${on.wrapped}/bin/nvim --clean -l on.lua

                  # The host is started through a wrapper that drops PYTHONPATH / PYTHONSAFEPATH,
                  # so that a PYTHONPATH exported for a project cannot be imported into it (and
                  # shadow pynvim). Everything in on.lua passes with host_prog pointed straight at
                  # the interpreter instead, so this needs a run of its own, with the variables
                  # set. vim.env is read back first, for both: it is the control that the variables
                  # did reach neovim, without which the two asserts after it would pass vacuously.
                  cat > pythonpath.lua <<'LUA'
                  assert(vim.env.PYTHONPATH == "/nvimx-test/pythonpath", "PYTHONPATH did not reach neovim; the asserts below prove nothing")
                  assert(vim.env.PYTHONSAFEPATH == "1", "PYTHONSAFEPATH did not reach neovim; the last assert proves nothing")
                  assert(vim.fn.py3eval('__import__("os").environ.get("PYTHONPATH")') == vim.NIL, "PYTHONPATH leaked into the python3 host")
                  assert(vim.fn.py3eval('__import__("os").environ.get("PYTHONSAFEPATH")') == vim.NIL, "PYTHONSAFEPATH leaked into the python3 host")
                  LUA
                  PYTHONPATH=/nvimx-test/pythonpath PYTHONSAFEPATH=1 ${on.wrapped}/bin/nvim --clean -l pythonpath.lua

                  # The use case the issue names: a Python remote plugin, registered with
                  # :UpdateRemotePlugins and then called. -u NORC rather than --clean on purpose:
                  # runtime/plugin/rplugin.vim skips loading the manifest when --clean is among
                  # the arguments, and :UpdateRemotePlugins then has no path to write to. The
                  # manifest lands in $HOME/.local/share/nvim, and HOME is this build's TMPDIR.
                  mkdir -p plug/rplugin/python3
                  cat > plug/rplugin/python3/nvimx_test.py <<'PY'
                  import pynvim


                  @pynvim.plugin
                  class NvimxTest(object):
                      def __init__(self, nvim):
                          self.nvim = nvim

                      @pynvim.function("NvimxTestHello", sync=True)
                      def hello(self, args):
                          return "hello from python"
                  PY
                  cat > register.lua <<'LUA'
                  vim.opt.rtp:append(vim.uv.cwd() .. "/plug")
                  vim.cmd("runtime! plugin/rplugin.vim")
                  vim.cmd("UpdateRemotePlugins")
                  LUA
                  ${on.wrapped}/bin/nvim -u NORC -l register.lua
                  cat > call.lua <<'LUA'
                  vim.opt.rtp:append(vim.uv.cwd() .. "/plug")
                  vim.cmd("runtime! plugin/rplugin.vim")
                  assert(vim.fn.NvimxTestHello() == "hello from python", "the remote plugin did not answer")
                  LUA
                  ${on.wrapped}/bin/nvim -u NORC -l call.lua

                  cat > off.lua <<'LUA'
                  for _, prog in ipairs({ "python3", "ruby", "node" }) do
                    assert(vim.g["loaded_" .. prog .. "_provider"] == 0, prog .. ": false must disable the provider")
                    assert(vim.g[prog .. "_host_prog"] == nil, prog .. ": a disabled provider must not get a host")
                  end
                  assert(vim.fn.executable("ruby") == 0 and vim.fn.executable("node") == 0, "a disabled provider put its interpreter on PATH")
                  LUA
                  ${off.wrapped}/bin/nvim --clean -l off.lua

                  cat > mixed.lua <<'LUA'
                  assert(vim.g.loaded_python3_provider == 0 and vim.g.python3_host_prog == nil, "python3 = false")
                  assert(vim.g.loaded_ruby_provider == nil and vim.g.ruby_host_prog == nil, "ruby was not mentioned and must be left alone")
                  assert(vim.g.loaded_node_provider == nil and vim.g.node_host_prog ~= nil, "node = true")
                  assert(vim.fn.executable("node") == 1, "node = true must put node on PATH")
                  assert(vim.fn.executable("ruby") == 0, "ruby reached PATH without withRuby = true")
                  LUA
                  ${mixed.wrapped}/bin/nvim --clean -l mixed.lua

                  cat > ordered.lua <<'LUA'
                  -- nil would mean the user's --cmd ran before nvimx's provider file.
                  assert(vim.g.nvimx_test_seen == 0, "extraWrapperArgs must come after the provider arguments: " .. vim.inspect(vim.g.nvimx_test_seen))
                  LUA
                  ${ordered.wrapped}/bin/nvim --clean -l ordered.lua

                  # The hm module really hands all four options to makeEnv (see moduleWrapped above).
                  cat > module.lua <<'LUA'
                  assert(vim.fn.has("python3") == 1, "the hm module did not pass withPython3 through")
                  assert(vim.fn.py3eval('__import__("six").__name__') == "six", "the hm module did not pass extraPython3Packages through")
                  assert(vim.g.loaded_ruby_provider == 0, "the hm module did not pass withRuby through")
                  assert(vim.g.loaded_node_provider == 0, "the hm module did not pass withNodeJs through")
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

補足:

- **`six` を選んだ理由**: pynvim の依存は `msgpack` と `greenlet` だけ(計画作成時に
  `python3.pkgs.pynvim.propagatedBuildInputs` で確認)で、`six` はその closure に無い。
  `extraPython3Packages` を host に渡さない mutation(M15)で `ModuleNotFoundError: No module named 'six'`
  になることを実測した。
- **`pythonpath.lua` を `on.lua` と別の起動にしている理由**: `hostPython3` の wrapper
  (`--unset PYTHONPATH --unset PYTHONSAFEPATH`)は、変数が**設定されている**ときにしか観測できない。
  `on.lua` の assert は `host_prog` を interpreter に直接向けても全部通る(M19 の mutation を
  この assert が無い状態で当てて緑のままだったことをレビューが実測し、本計画で assert を足した)。
  1〜2 行目の `vim.env.PYTHONPATH` / `vim.env.PYTHONSAFEPATH` の assert は、それぞれ 3 行目 / 4 行目の
  対照である: 変数が neovim まで届いていなければ、後ろの 2 つは空振りで通ってしまう。`py3eval` は Python の `None` を `vim.NIL` で返す(実測)。
- **remote plugin の部分だけ `-u NORC`**: §1.6。`--clean` では manifest が読まれず、書き先も無い。
  nvimx の wrapper は `-u NORC` でも `--cmd` の 2 本(bootstrap / providers)を走らせる。manifest は
  `$HOME/.local/share/nvim/rplugin.vim`、つまり `$TMPDIR` の下に書かれる(sandbox 内の実測ログ:
  `remote/host: generated rplugin manifest: /build/.local/share/nvim/rplugin.vim`)。
- **heredoc の中の Python のインデント**: nix の indented string が共通の先頭空白を落とすので、
  `PY` までの本文は行頭から始まる Python になる(実測で登録が通っている)。インデントを 1 段でも
  ずらすと heredoc の終端(`PY` / `LUA`)が行頭に来なくなるので、貼るときは逐語で。
- **`${builtins.storeDir}`**: `on.lua` の中で 1 回だけ nix の補間を使っている(`'LUA'` はシェルの
  展開を止めるだけで、nix の補間は止めない)。

### 6.2 `checks.hm-module-providers`(新設)

```nix
          # The provider options (#73) through the module's option types (nullOr bool, and
          # functionTo (listOf package) for extraPython3Packages), all the way to an activation
          # package against a real lock -- so the three hosts are part of a real home-manager
          # build, next to a real farm. checks.providers' moduleWrapped goes through the same
          # types but stops at the wrapper, in degraded mode. Like every mkHmCheck it asserts
          # nothing about the result: that the module actually hands the four options on is
          # checked by checks.providers' moduleWrapped, for the reason spelled out at
          # checks.extra-lua-packages. Uses the same basic-config lock hm-module already builds,
          # and the same three hosts checks.providers builds, so it adds no fetch of its own.
          hm-module-providers = mkHmCheck {
            configDir = ./tests/fixtures/basic-config;
            lockDir = ./tests/fixtures/basic-config/nvimx-lock;
            withPython3 = true;
            extraPython3Packages = ps: [ ps.six ];
            withRuby = true;
            withNodeJs = true;
          };
```

`hm-module-lua-packages` / `hm-module-wrapper-args` と同じ位置づけ: module の型を通し、実 lock に対して
activation package まで組む。assert はしない(U2)。

### 6.3 mutation の実測(計画作成時)

scratch に §5 を当てた状態から 1 か所ずつ壊し、`nix build …#checks.x86_64-linux.providers` を回した。
**20 通りすべて赤**である(レビュー指摘への対応で check と `providers.nix` を直すたびに回し直しており、
M19 / M20 は `pythonpath.lua` を今の形にした後の実測である)。

| # | 壊し方 | 赤になった箇所(実際の出力) |
|---|---|---|
| M1 | `home-manager/default.nix` の `inherit (cfg)` から `withPython3` を落とす | `the module must not warn when withPython3 = true`(評価レベルが先に落ちる。`module.lua` より手前) |
| M2 | 同 `extraPython3Packages` を落とす | `the module must warn about extraPython3Packages without withPython3 = true` |
| M3 | 同 `withRuby` を落とす | `module.lua:3: the hm module did not pass withRuby through` |
| M4 | 同 `withNodeJs` を落とす | `module.lua:4: the hm module did not pass withNodeJs through` |
| M5 | `make-env.nix` の `mkWrapper` の `inherit` から `withNodeJs` を落とす | `on.lua:5: node: host_prog is not a store path: nil` |
| M18 | 同 `withPython3` を落とす | `on.lua:5: python3: host_prog is not a store path: nil` |
| M6 | `providers.nix` の `runtimeDeps` から `pkgs.nodejs` を落とす | `on.lua:19`(`remote#host#Require("node")` が `'node' is not executable` で throw する) |
| M7 | `line` の最初の 2 分岐を `if enabled == true then` 1 つに置き換える(`null` が無効化の分岐に落ちる)。`if enabled == null then [ ] else` を消すだけだと `if enabled then …` が残り、`error: expected a Boolean but found null` という別の赤になる(§5.1 の注意点 1 つ目) | `with every provider left at null the wrapper must not mention providers` |
| M17 | `line` の `false` 分岐を `[ ]` にする(無効化が効かない) | `off.lua:2: python3: false must disable the provider` |
| M8 | `trailingWrapperArgs` で provider を `extraWrapperArgs` の後ろに回す | `ordered.lua:2: extraWrapperArgs must come after the provider arguments: nil` |
| M9 | module の `withRuby` の `default` を `false` にする | `withRuby must be declared with default = null` |
| M10 | `--set GEM_HOME …` を足す(nixpkgs と同じにする) | `on.lua:32: GEM_HOME must not be set: /nix/store/…-neovim-ruby-env/lib/ruby/gems/3.4.0` |
| M11 | `--suffix` を `--prefix` にする | `on.lua:24: extraPackages must stay at the front of PATH: …` |
| M12 | `unusedPython3Packages = false;` に固定する | `extraPython3Packages without withPython3 = true must be reported as unused` |
| M13 | module の warning を消す | `the module must warn about extraPython3Packages without withPython3 = true` |
| M14 | `rubyEnv` を node だけ有効でも `PATH` に入れる | `mixed.lua:5: ruby reached PATH without withRuby = true` |
| M15 | `python3Env` から `extraPython3Packages ps` を落とす | `ModuleNotFoundError: No module named 'six'`(`on.lua:12`) |
| M16 | `rubyEnv` を組む前に `package.lua` を force する(neovim に passthru を要求する) | 評価エラー `attribute 'lua' missing` |
| M19 | `line "python3"` の host を `"${python3Env.interpreter}"` にする(`PYTHONPATH` を外す wrapper を迂回する) | `pythonpath.lua:3: PYTHONPATH leaked into the python3 host` |
| M20 | `hostPython3` の `makeWrapper` から `--unset PYTHONSAFEPATH` だけを落とす | `pythonpath.lua:4: PYTHONSAFEPATH leaked into the python3 host` |

読み方の注意:

- M1 / M2 は `module.lua` の「did not pass … through」ではなく、評価レベルの warning の assert が先に
  落ちる(`withPython3` が落ちると `unusedPython3Packages` が真になるため)。メッセージは症状を
  指しているが原因(pass-through の欠落)は指していない。したがって `module.lua` の 1〜2 行目が
  この 2 つの欠落を報告することは無く、あの 2 つの assert は控えである。`checks.extra-lua-packages` の
  `noLua`(`flake.nix:499-503` のコメント)と同じ性質であり、同じように `moduleWrapped` のコメントに
  書いてある(§6.1 の `# Two of the four drops are reported somewhere else first, …`)。
- M16 は `failures` のメッセージではなく素の評価エラーになる。`builtins.tryEval` が捕まえるのは `throw` /
  `assert` だけで、属性の欠落は捕まえないからである。赤にはなる。

### 6.4 check がカバーしないもの(意識的に受け入れる)

- **G5 の「drv が不変」そのもの**。`untouched` は「wrapper スクリプトに `providers` と書かれていない」
  「`vim.g` が空」を見るだけで、drv ハッシュは見ない(`checks.extra-lua-packages` の `untouched` と同じ
  割り切り)。§8 の手順 5 で main と比較して確かめる。
- **ruby / node の remote plugin の end-to-end**。python3 だけ `:UpdateRemotePlugins` まで通す。
  ruby は `rubyeval`、node は host の起動までである。node の remote plugin を通すには npm パッケージの
  形をした fixture が要り、得るものに対して重い。
- **`:checkhealth` の表示**。`PATH` に ruby env があることは見るが、`:checkhealth` の出力は照合しない
  (neovim のバージョンで文面が変わる。python の節は sandbox では PyPI に届かず常に ERROR を含む)。
- **`init.lua` が `vim.g.*_host_prog` を上書きできること**。`--cmd` が config より前に走るのは neovim の
  仕様であり、`ordered` が「ユーザーの `--cmd` が後」を見ているのでそれ以上は足さない。
- **`rubyEnv` を借りられない nixpkgs での `throw`**。check には入れない: `makeEnv` は `pkgs` を
  `nix/lib/default.nix` の引数で受けるので、`wrapNeovimUnstable` を差し替えた `pkgs` で check 用の lib を
  もう 1 つ組むことになり、1 分岐のために重い。しかも今ある nixpkgs でこの分岐に届くものは無い
  (§3.3: 将来の形の変化への備えである)。代わりに計画作成時に合成の `pkgs` で手で確かめた(属性が
  `null` の場合と属性が無い場合の両方で、§5.1 の文面の `throw` になる)。実装後に §8 手順 7b で同じことを
  1 度行う。
- **nixpkgs 24.05 以前での挙動**。pinned の nixpkgs でしか check は走らない。`withRuby = true` /
  `withNodeJs = true` が素の評価エラーになることは R3 に書いたとおりで、守ってもいないし直しもしない。
- **darwin での実行**。評価(`.drvPath`)しか手元では確かめられない。R6。

### 6.5 既存 checks への影響

計画作成時に、main(`1d09b26`)と §5 を当てた scratch とで `checks.x86_64-linux` 全体の drvPath を比べた:

```
{ "main": 37, "tree": 39, "changed": [], "added": [ "hm-module-providers", "providers" ] }
```

**既存 37 件は 1 つも drv が変わらない。** 個別には:

```
same  checks.x86_64-linux.wrapper-aliases  w1pcxdnry45zip6kjsl89za16vz8dhfk-wrapper-aliases.drv
same  checks.x86_64-linux.extra-lua-packages  5wk75zbpsv72gcmvrw4fiw1la31rw1p2-extra-lua-packages.drv
same  checks.x86_64-linux.extra-wrapper-args  7v0vkcqkcgs33f7ds8fk7zyr3cpgj4iv-extra-wrapper-args.drv
same  checks.x86_64-linux.hm-module  wxaln15f5wzalwh897zkgf909ppw8nnx-home-manager-generation.drv
same  checks.x86_64-linux.hm-module-wrapper-args  46dcap8zqa4yhj93mbkn5d3cwr0r74n2-home-manager-generation.drv
same  packages.x86_64-linux.demo  3ip2dq1cchgrkfxizfqn48mnh5djcrlr-nvim.drv
```

darwin も `checks.aarch64-darwin.hm-module`(`1jmwhiqwib310ffk8pivjp9mv241j1jx-…`)と
`packages.aarch64-darwin.demo`(`8b0i296xim9qc3zmskmh7nc7aijzppvi-nvim.drv`)が不変である。

module に option を 4 つ足し、description を 1 つ書き換え、`warnings` に項を足しても
`hm-module` の activation package の drv は動かなかった(option の説明文は derivation に入らない)。

新 check のビルド時間への上乗せ: host 3 つ(python env 1、ruby env 1、nodejs + node-client は cache から)と
wrapper 6 本、neovim の起動が 9 回(`pythonpath.lua` を含む)。`hm-module-providers` は `providers` と同じ host を使う。

### 6.6 CI / darwin

- `.github/workflows/check.yml` は `nix flake check` を回すだけなので、新 check は両 system で自動的に走る。
  ワークフローは編集しない。
- `nix eval .#checks.aarch64-darwin.{providers,hm-module-providers}.drvPath` は計画作成時に評価が通った
  (`75pcd48m5abvckphlnk92ycha9k1x50g-providers.drv` /
  `xqhl96s12r30zrjz4vdfpdjh4vgg533n-home-manager-generation.drv`)。つまり `pkgs.python3` / `bundlerEnv` /
  `pkgs.nodejs` / `pkgs.neovim-node-client` はすべて aarch64-darwin で評価できる。
- darwin の runner で host が実際に起動するかは CI が初めて確かめる(R6)。

## 7. リスク / 未決事項

### R1: 既定値と型が `programs.neovim` と一致しない

§3.1 の決定の帰結である。`programs.neovim` は `bool`、nvimx は `nullOr bool` で既定 `null`。
「parity」を文字どおり型と既定値の一致と読むなら、本計画はそれを満たしていない。満たしているのは
「同じ名前のオプションに `true` / `false` を書けば同じ意味で動く」である。

覆す場合: (a) `bool`・既定 `false`・無効化、にすると G5 が成立せず、既存ユーザー全員の wrapper が変わり、
`PATH` 経由で provider を使っていた人が壊れる(リリースノートでの告知が必須になる)。(b) `bool`・
既定 `false`・no-op、にすると実装は `providers.nix` の `line` が 2 分岐になるだけで済むが、
`withPython3 = false` の意味が `programs.neovim` と逆向きにずれる。**レビューで最初に確認してほしい点である。**

### R2: `GEM_HOME` を設定しない

§1.5 の実測(pinned の nixpkgs、ruby 3.4.9、neovim gem 0.10.0)では不要だった。ただし実測したのは
`rubyeval`、`has("ruby")`、`:checkhealth` の 3 つであり、**ruby の remote plugin が他の gem を
require する場合**は試していない。`rubyEnv` に入っているのは neovim gem とその依存だけなので、
そういうプラグインは `GEM_HOME` の有無にかかわらず nixpkgs の wrapper でも動かないはずだが、確かめては
いない。必要になった場合の逃げ道は `extraWrapperArgs`(`--set GEM_HOME …`)で、README に書く。
check の `on.lua` が `GEM_HOME == nil` を固定している(M10)ので、後から設定する変更は check を直して
意図的に行うことになる。

### R3: ユーザーの `pkgs` は nvimx の pin と別物であり得る

hm module は `import ../lib { inherit pkgs lazyNvimSeed; }` でユーザーの `pkgs` を使う。本件が nixpkgs に
求める属性は `pkgs.python3` / `python3.pkgs.pynvim` / `pkgs.neovim-node-client` / `pkgs.nodejs` /
`pkgs.wrapNeovimUnstable` とその `.rubyEnv` である。リリースごとの状況(レビューが各ブランチの
`pkgs/applications/editors/neovim/wrapper.nix` を読み、nixos-24.05 と nixos-24.11 では実際に評価して
確認したもの。本計画の作成者が手元で確かめたのは pinned の 26.11 だけである):

| nixpkgs | `wrapNeovimUnstable package { }` | `rubyEnv` | `neovim-node-client` | `withRuby = true` | `withNodeJs = true` |
|---|---|---|---|---|---|
| 24.11 / 25.05 / 25.11 / 26.05 / pinned(26.11) | 呼べる | 実体のある `bundlerEnv` | ある | 動く(24.11 は stub のパッケージでも評価が通る) | 動く |
| 23.11 / 24.05(EOL) | **呼べない**。必須引数 `packpathDirs` に既定値が無い | (届かない。形としては `rubyEnv ? null` をそのまま `inherit`) | 無い(`nodePackages.neovim` だった) | 素の評価エラー `function 'wrapper' called without required argument 'packpathDirs'` | 素の評価エラー `attribute 'neovim-node-client' missing` |

つまり 24.11 以降なら 3 つとも動き、24.05 以前は ruby と node が素の評価エラーになる(python3 は
`pkgs.python3` と `pynvim` しか使わないので影響を受けない。round-3 のレビューが nixos-23.11 と
nixos-24.05 で `withPython3 = true; extraPython3Packages = ps: [ ps.six ];` と 3 つとも `false` の場合の
`rc.drvPath` を評価して確認した。評価のみで、ビルドはしていない)。**§5.1 の親切な `throw` は 24.05 以前の
ための経路ではない** —— そこでは呼び出しが先に落ちるので届かない。あれは wrapper の返り値の形が
将来変わった場合への備えである(§3.3)。24.05 以前を素のエラーのままにするのは意図的である:
どちらのエラーも原因の名前(`packpathDirs` / `neovim-node-client`)を含み、対象は EOL のリリースで、
version guard を足すと nixpkgs のバージョン判定という別の壊れ方を持ち込む。
どれも **`true` を書いた provider についてだけ**起きる(`line` が `exec` を遅延評価するため)。
既定の `null` では nixpkgs のどの属性にも触れない。nvimx は既に `pkgs.vimPlugins.nvim-treesitter.grammarPlugins`
など nixpkgs の内部寄りの属性に依存しており、同じ種類のリスクである。

### R4: manifest は生成しない。プラグイン更新のたびに `:UpdateRemotePlugins` が要る

§1.6 のとおり、manifest は store path を記録するので lock が動くと古くなる。`programs.neovim` はビルド時に
生成するのでこの手間が無い。**issue の言う「supported way to get a provider」は満たすが、
`programs.neovim` と同じ使い心地にはならない。** README と option description に書く。
ビルド時生成は別 issue とするのが妥当である: lazy.nvim の遅延ロードとの関係、
`$NVIM_SYSTEM_RPLUGIN_MANIFEST` が nixpkgs 独自パッチであること(neovim-nightly-overlay では読まれない)、
ビルド中に host を起動することの 3 点を設計し直す必要がある。本 PR をマージするとき、follow-up の issue を
立てるかどうかをユーザーに確認すること。

### R5: `--cmd` の本数

neovim は `--cmd` / `-c` / `+cmd` をそれぞれ 10 個までしか受けない(実測: 11 個目で
`nvim: Too many "+command", "-c command" or "--cmd command" arguments`、exit 1)。nvimx は今日 1 本、
provider を 1 つでも設定すると 2 本使う。ユーザーが `extraWrapperArgs` とコマンドラインで使える `--cmd` は
9 本から 8 本になる。nixpkgs が provider の設定を 1 本の `--cmd` にまとめているのも同じ理由である
(`wrapper.nix:157` のコメント)。本件も provider 3 つを 1 ファイルにまとめているので 1 本で済む。

### R6: darwin では評価しか確かめていない

`checks.providers` は sandbox の中で python / ruby / node の 3 プロセスを起動する。linux では通した。
aarch64-darwin では drvPath の評価までである。懸念は (1) darwin の runner で 3 つの host がそれぞれ
起動するか、(2) `untouched.lua` の対照(builder の `PATH` に `python3` / `ruby` / `node` が無い)が darwin の
builder でも成り立つか、の 2 点。(2) は stdenv が `PATH` を `initialPath` だけに組み直すので成り立つはず
だが、macOS の nix は sandbox が既定で無効なので、`/usr/bin` が `PATH` に漏れていないことは CI で初めて
分かる。漏れていた場合に落ちるのは対照の assert であり(`the builder's PATH already has …`)、メッセージが
原因を言う。CI(`ci-darwin.yml`)が赤になったらまずここを見ること。

### R7: python は `pkgs.python3` 固定

host の interpreter を選ぶオプションは無い(`programs.neovim` も同じ)。`extraPython3Packages` に渡される
package set は `pkgs.python3.pkgs` で、ユーザーが overlay で `python3` を差し替えていればそれに従う。
`python3` を上げると pynvim が追従していない期間があり得る(pinned では python 3.14.6 + pynvim 0.6.0 で
動作を確認した)。

### R8: `PATH` の末尾に足したものは子プロセスに継承される

`withRuby = true` で `ruby` / `gem` / `bundle` / `irb` / `rake` ほか(`rubyEnv/bin` の 15 個)、
`withNodeJs = true` で `node` / `npm` / `npx` / `corepack` が、neovim から起動するすべてのプロセスの
`PATH` 末尾に入る。`--suffix` なのでユーザーの道具は押しのけないが、「何も入っていない環境で
`:terminal` を開いたら `ruby` がある」にはなる。nixpkgs の wrapper と同じ挙動であり、#72 計画 R5 と
同じ性質である。

### R9: `--suffix` なので host の interpreter は `PATH` 次第になり得る

node の host は `node <host>` で起動されるので、ユーザーの `PATH` に別の `node` があればそちらで走る
(nvimx が足す `pkgs.nodejs` は末尾)。`withNodeJs = true` は「host が必ず見つかる」ことは保証するが、
「どの node で走るか」は固定しない。固定したい場合は `extraPackages = [ pkgs.nodejs ]`(`--prefix`)を
併用する(計画作成時に実測: `PATH` の先頭に偽の `node` を置いて起動すると、`withNodeJs = true` だけでは
`exepath("node")` が偽物を指し、`extraPackages = [ pkgs.nodejs ]` を足すと store の `nodejs-24.18.0` を指す)。
README の Node.js の項、`withNodeJs` の description、`docs/architecture.md` の edge case 表は、この点を
そのとおりに書く(`true` でも node の interpreter だけは `PATH` 次第である)。nixpkgs と同じ挙動なので揃えたが、nvimx の再現性の観点では `--prefix` にする余地がある。
`--prefix` にするとユーザーの `node` を neovim の中でだけ押しのけることになり、M11 の assert
(`extraPackages` が先頭)も書き直しになる。

### U1(未決): `withPerl` を入れるか

本計画は入れない(§3.6)。入れる場合の差分は小さい: option 1 つ、`providers.nix` の `lines` に
`line "perl" withPerl "${perlEnv}/bin/perl"`(`perlEnv = pkgs.perl.withPackages (p: [ p.NeovimExt
p.Appcpanminus ])`、`wrapper.nix:235-238`)、check の `on` / `off` に perl を足す。ただし perl の host は
本計画で一度も動かしておらず、nixpkgs 自身が problematic と書いている。issue の範囲(3 つ)に留めた。

### U2(未決): `hm-module-providers` を本当に足すか

`providers` の `moduleWrapped` が module の型と pass-through を既に見ている。`hm-module-providers` が
足すのは「3 つの host を含む wrapper が、実 lock の farm と一緒に activation package まで組める」ことだけで、
assert は無い。#72 計画の U2 と同じ問いであり、#72 は足した(`hm-module-wrapper-args`)。前例に合わせて
足す案としたが、削っても G1〜G12 は成立する。

### U3(未決): `unusedPython3Packages` を `makeEnv` の出力にするか

`makeEnv` の返り値(10 個目)にした。理由は 2 つである: (1) 前例 —— 「黙った no-op を報告する」ものは
`unknownPluginNames` / `treesitterWithoutPlugin` / `unknownDevPluginNames` のどれも `makeEnv` が報告し、
module が warning に変えている。(2) `lib.makeEnv` を直接使う人(`programs.nvimx.env` を自分で渡す人)も
同じ報告を受け取れる。代案は module の中だけで
`cfg.withPython3 != true && cfg.extraPython3Packages pkgs.python3.pkgs != [ ]` を書くことで、
`makeEnv` の表面は増えないが、上の 2 つを失う。
なお「どの python の package set か」(`pkgs.python3.pkgs`)という知識は、どちらの案でも 2 か所に
分かれる(採用案では `make-env.nix` の `unusedPython3Packages` と `providers.nix` の `python3Env`)。
これは案を選ぶ理由にはならない。1 か所にまとめたければ `providers.nix` に判定を持たせて返り値を
`{ rc, wrapperArgs, unusedPython3Packages }` にする手があるが、`wrapper.nix` 経由でしか呼ばれない
ファイルの値を `make-env.nix` まで持ち上げる配線が増えるので採っていない。

### U4(未決): README の `### Providers` の置き場所

`### Wrapper arguments` の後に置いた(wrapper の環境の話が並ぶ)。`programs.neovim` から移行する人が
最初に探す、という issue の指摘を重く見るなら、`## Options` の表の直後(`### Escape hatches` の前)の方が
目に入る。

## 8. 検証手順(実装完了時に必ず全部通す)

```bash
cd /home/myuron/ghq/github.com/myuron/nvimx

# 0. 新規ファイルを追跡させる。これを忘れると以降の nix コマンドがすべて
#    "path '…/nix/lib/providers.nix' does not exist" で落ちる。
git add nix/lib/providers.nix

# 1. 整形 + lint(treefmt: nixfmt / stylua / luacheck)。lua は 1 行も変えていないので実質 nixfmt。
#    §5 / §6 のスニペットは nixfmt 正規形を逐語で貼ったものなので、書き写せばそのまま通る。
#    stylua.toml / .luacheckrc は触らないので --clear-cache は不要。
nix fmt -- --ci

# 2. 新 check だけを先に回す(速いループ用)
nix build .#checks.x86_64-linux.providers -L
nix build .#checks.x86_64-linux.hm-module-providers -L
#    隣の wrapper 系 check も。本件では再ビルドされないはずである(§6.5)
nix build .#checks.x86_64-linux.extra-wrapper-args -L
nix build .#checks.x86_64-linux.extra-lua-packages -L
nix build .#checks.x86_64-linux.wrapper-aliases -L
nix build .#checks.x86_64-linux.hm-module -L

# 3. フルチェック(linux)。check は 39 件(既存 37 + 新設 2)
nix flake check
nix eval .#checks.x86_64-linux --apply 'c: builtins.length (builtins.attrNames c)'   # → 39

# 4. darwin 評価。ローカル linux の flake check は darwin を omit する(CLAUDE.md)。
#    本件は pkgs.python3 / bundlerEnv / nodejs という system 依存のものを足すので省略不可。
nix eval .#checks.aarch64-darwin.providers.drvPath
nix eval .#checks.aarch64-darwin.hm-module-providers.drvPath
nix eval .#checks.aarch64-darwin.extra-wrapper-args.drvPath
nix eval .#checks.aarch64-darwin.extra-lua-packages.drvPath
nix eval .#checks.aarch64-darwin.wrapper-aliases.drvPath
nix eval .#checks.aarch64-darwin.hm-module.drvPath

# 4b. IFD を足していないこと(G12)
nix eval --raw --option allow-import-from-derivation false .#checks.x86_64-linux.providers.drvPath
nix eval --raw --option allow-import-from-derivation false .#checks.x86_64-linux.hm-module-providers.drvPath

# 5. G5: provider を設定しない wrapper の drv が 1 つも変わっていないこと(§3.7 / §6.5)。
#    main のコミット済みツリーと作業ツリーを比べる。stash は要らない。
#    G5 を常時守る check は無い(§6.4)ので、この手順で確かめる。評価の失敗は握り潰さず、
#    失敗と空文字は same と区別して報告し、最後の 1 行で合否を言う。
#    bash で実行すること(ユーザーのシェルは fish)。
#    手順 2 で新 check が緑になった**後**に走らせること —— 実装前のツリーは main と同じなので、
#    そこで走らせると当然全部 same になり、何も証明しない。
#    stderr に混ざって正常な評価警告は 3 種類ある: degraded mode の trace
#    ("lock files … not found in lockDir")、nixfmt-rfc-style の evaluation warning、そして本件が足す
#    "trace: warning: programs.nvimx: extraPython3Packages names packages, but withPython3 is not
#    true, …"。最後のものは checks.providers の `forgotten`(警告が出ることを確かめるための評価)が
#    出しており、checks.providers を評価するたびに —— 手順 2〜4 でも、以後すべての nix flake check と
#    CI のログでも —— 1 回出る。失敗ではない。
fail=0
for a in checks.x86_64-linux.wrapper-aliases checks.x86_64-linux.extra-lua-packages \
         checks.x86_64-linux.extra-wrapper-args checks.x86_64-linux.hm-module \
         checks.x86_64-linux.hm-module-wrapper-args packages.x86_64-linux.demo; do
  b=$(nix eval --raw "git+file://$PWD?ref=main#$a.drvPath") || { echo "EVAL FAILED (main)  $a"; fail=1; continue; }
  n=$(nix eval --raw ".#$a.drvPath")                        || { echo "EVAL FAILED (tree)  $a"; fail=1; continue; }
  if [ -n "$b" ] && [ "$b" = "$n" ]; then echo "same  $a  ${b#/nix/store/}"
  else echo "DIFF  $a  $b  $n"; fail=1; fi
done
[ "$fail" = 0 ] && echo "G5 holds: 6/6 same" || echo "G5 NOT PROVEN"
#    合格の表示(計画作成時に実測。flake.lock を動かしていなければハッシュもこのとおり):
#      same  checks.x86_64-linux.wrapper-aliases  w1pcxdnry45zip6kjsl89za16vz8dhfk-wrapper-aliases.drv
#      same  checks.x86_64-linux.extra-lua-packages  5wk75zbpsv72gcmvrw4fiw1la31rw1p2-extra-lua-packages.drv
#      same  checks.x86_64-linux.extra-wrapper-args  7v0vkcqkcgs33f7ds8fk7zyr3cpgj4iv-extra-wrapper-args.drv
#      same  checks.x86_64-linux.hm-module  wxaln15f5wzalwh897zkgf909ppw8nnx-home-manager-generation.drv
#      same  checks.x86_64-linux.hm-module-wrapper-args  46dcap8zqa4yhj93mbkn5d3cwr0r74n2-home-manager-generation.drv
#      same  packages.x86_64-linux.demo  3ip2dq1cchgrkfxizfqn48mnh5djcrlr-nvim.drv
#      G5 holds: 6/6 same
#    1 本でも DIFF なら、既定で wrapper か module の出力が変わっている。まず §5.1 の注意点 3 つ目
#    (rc を null にせず空ファイルを作った)と、§5.2 の lib.filter の並びを疑うこと。
#    main が動いていて ref=main が実装前のツリーを指さない場合は、ref= を実装の親コミットに置き換える。

# 6. smoke test(CLAUDE.md)。:Lazy で全プラグインが local、git 操作なし、を目で確認する。
#    demo の drv は変わっていないので(手順 5)、これは「壊していない」の確認である。
nix build .#demo && ./result/bin/nvim

# 7. 手で 1 度だけ: 3 つの host が sandbox の外でも動くこと、:checkhealth が読めること。
#    (check は sandbox の中で同じことをしているが、:checkhealth の表示は check が見ていない。§6.4)
out=$(nix build --no-link --print-out-paths --impure --expr '
  let f = builtins.getFlake (toString ./.); p = import f.inputs.nixpkgs { system = "x86_64-linux"; };
  in (f.lib.x86_64-linux.makeEnv {
    package = p.neovim-unwrapped;
    lockDir = ./tests/fixtures/basic-config/no-such-lock;
    withPython3 = true; withRuby = true; withNodeJs = true;
  }).wrapped')
cat "$out/bin/nvim"        # --cmd 'luafile …-nvimx-providers.lua' が bootstrap の後に 1 本、
                           # PATH の suffix ブロックが ruby env と nodejs の 2 つ、GEM_HOME は無い
"$out/bin/nvim" --clean --headless -c 'lua print(vim.fn.py3eval("1 + 1"), vim.fn.rubyeval("1 + 1"), vim.fn["remote#host#Require"]("node") > 0)' +qa
                           # → 2 2 true
"$out/bin/nvim" --clean --headless -c 'checkhealth vim.provider' -c 'w! /tmp/nvimx-health.txt' +qa
grep -A4 '^Ruby provider\|^Node.js provider\|^Python 3 provider' /tmp/nvimx-health.txt
                           # → 3 つとも host のパスが store path。Ruby は "OK Latest "neovim" gem is installed"

# 7b. 手で 1 度だけ: wrapNeovimUnstable の返り値から rubyEnv を借りられない形で、親切な throw に
#     なること(§6.4。check には無い)。属性が null の形と、属性が無い形の両方。どちらも合成した
#     pkgs であり、実在する nixpkgs を模したものではない: 今ある nixpkgs でこの throw に届くものは
#     無い(24.05 以前は呼び出しが packpathDirs のエラーで先に落ちる。§3.3 / R3)。確かめているのは
#     「返り値の形が将来変わっても素の型エラーにならない」ことである。
for fake in '_: _: { rubyEnv = null; }' '_: _: { }'; do
  nix eval --impure --expr "
    let f = builtins.getFlake (toString ./.); p = import f.inputs.nixpkgs { system = \"x86_64-linux\"; };
    in (import ./nix/lib/providers.nix { pkgs = p // { wrapNeovimUnstable = $fake; }; }
         { package = p.hello; withRuby = true; }).rc.drvPath" 2>&1 | grep -m1 'nvimx: withRuby'
done
#     → 2 回とも "error: nvimx: withRuby = true, but this nixpkgs' wrapNeovimUnstable exposes no rubyEnv, so nvimx"
#       (計画作成時に実測)。"cannot coerce null to a string" が出たら or null / != null の 2 段が崩れている。

# 8. §6.3 の mutation を実装ツリーで再現する(確認後は必ず戻すこと)。
#    check が「何も検知していない」状態で緑なのが本件最大の失敗モードである。最低限この 6 つ:
#      M4  nix/home-manager/default.nix の inherit (cfg) から withNodeJs を消す
#            → providers が module.lua:4 "did not pass withNodeJs through" で赤
#      M6  nix/lib/providers.nix の runtimeDeps から pkgs.nodejs を消す
#            → providers が on.lua の remote#host#Require("node") で赤
#      M7  nix/lib/providers.nix の line の最初の 2 分岐
#          (`if enabled == null then [ ] else if enabled then`)を `if enabled == true then` に置き換える
#          (消すだけだと "expected a Boolean but found null" という別の赤になる)
#            → providers が "with every provider left at null the wrapper must not mention providers" で赤
#      M8  nix/lib/wrapper.nix の trailingWrapperArgs で providerWrapperArgs を最後に回す
#            → providers が ordered.lua "extraWrapperArgs must come after the provider arguments" で赤
#      M9  nix/home-manager/default.nix の withRuby の default を false にする
#            → providers が "withRuby must be declared with default = null" で赤
#      M19 nix/lib/providers.nix の line "python3" の第 3 引数を "${python3Env.interpreter}" にする
#            → providers が pythonpath.lua:3 "PYTHONPATH leaked into the python3 host" で赤
#    戻し忘れの検知は #72 計画 §8 手順 8 と同じ(git diff --stat は要約行が変わらないので使えない)。
#    mutation の前に差分全体をリポジトリ外へ退避し、戻した後に一致を見る。
snap=$(mktemp)                 # リポジトリの外。mutation を始める前に 1 度だけ取る
git diff HEAD > "$snap"        # HEAD と比べる: 手順 0 の git add 済みの新規ファイルも入る
#    … ここで M4 / M6 / M7 / M8 / M9 / M19 を 1 つずつ当て、赤を確認し、戻す …
if git diff HEAD | diff -q - "$snap" >/dev/null; then echo "mutations reverted"
else echo "MUTATION LEFT BEHIND:"; git diff HEAD | diff - "$snap"; fi
rm -f "$snap"

# 9. 変更が想定のファイルに閉じていること
git status --short
git diff --name-only main
#    → README.md / docs/architecture.md / docs/plans/73-provider-options.md / flake.nix /
#      nix/home-manager/default.nix / nix/lib/make-env.nix / nix/lib/providers.nix /
#      nix/lib/wrapper.nix の 8 件だけ。計画ファイルは §5 冒頭のとおり先に単独で commit してあるので
#      git diff --name-only main の側に出る。未 commit の新規ファイル(nix/lib/providers.nix)は
#      git add 済みなら両方に、していなければ git status の側にだけ出る。
#      lua/ tests/ templates/ .github/ nix/lib/bootstrap.nix nix/lib/default.nix が出たら範囲外に触っている。

# 10. ドキュメント。件数はすべて、§5.6 / §5.7 を scratch に当てて計画作成時に実測した値である。
grep -c '(#providers)' README.md                              # → 4(Options 表の 4 行)
grep -n '^### Providers' README.md                            # → 1 件、### Wrapper arguments と ## How it works のあいだ
grep -c 'unusedPython3Packages' README.md                     # → 1(env の行)
grep -c 'the first four built' README.md                      # → 1(適用順の列挙を直した)
grep -c 'withPython3' README.md                               # → 6
grep -c 'withPython3' docs/architecture.md                    # → 4(設計原則 4 / モジュール例の 2 行 = withPython3 の行と
                                                              #      extraPython3Packages の行のコメント / edge case 表)
grep -c 'nvimx-providers.lua' docs/architecture.md            # → 1(データフロー [5])
grep -c "the Node.js host no longer starts without its" README.md   # → 1(--set PATH の半文)
grep -c 'providers.nix' docs/architecture.md                  # → 1(Repository layout)
grep -c 'hm-module-providers' docs/architecture.md            # → 1(checks の列挙)
```

手順 1〜5 と 8 は、CLAUDE.md の Commands 節および `/nvimx-change` の step 4 が要求するもの
(`nix fmt -- --ci`、check ごとの `nix build`、`nix flake check`、darwin の `nix eval … .drvPath`)を
すべて含む。本件は system 依存のパッケージを足すので、darwin の評価(手順 4)は省略できない。
