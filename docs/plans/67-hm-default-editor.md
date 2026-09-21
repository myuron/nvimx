# #67 対応計画: `defaultEditor` オプション

対象 issue: [#67 feat(hm): add defaultEditor option](https://github.com/myuron/nvimx/issues/67)

本計画の `file:line` は**現在の作業ツリー(`12ff0e0`)基準で全件を実ファイルで再検証済み**である
(レビュー 2 回目で `nix/home-manager/default.nix` の `env` オプション範囲、`flake.nix` の
`dev-plugins` の assert 範囲、および §5.1 の行ずれ量を、3 回目で `mkHmCheck` の開始行と
§1.5 の `:3546` を是正した。以下の番号はすべて是正後のものである)。

**レビュー 3 回目で設計上の主張が 1 つ覆っている。** 2 回目まで本計画は
「`on ? VISUAL` の assert は網羅 assert に包含される重複である」と書いており、
`flake.nix` に残すコメントにまでそう書こうとしていた。**これは誤りである** ——
`VISUAL` を**無条件に**設定する退行は `on` と `off` の両方に現れて差分が相殺するので、
`on ? VISUAL` が唯一の守り手になる(§6.2(b) の改変 (d)、§6.2(c) の削除実験)。
本 issue の主題そのものである narrowing の唯一の守り手に「消してよい」と書き残すところだった。
§3.4 / §6.1 / §6.2 / §5.2 のコメントはすべて是正済みである。
(その後 assert が 2 本増えている。レビュー 5 回目で `lib.mkDefault` / `lib.mkForce` を捕まえる
`contested` を §3.2 の決定の守り手として、8 回目でその control を足した ——
`builtins.tryEval` は理由を問わず例外を `success = false` にするので、`contested` 単独では
**衝突とは無関係な例外**でも満たされてしまい、check が緑のまま何も検査しない状態になりうる(実測)。
control の形は 9 回目に**4 つ目の評価から、モジュールそのものを見る probe に差し替えた** ——
評価が 1 回少なく重複も 1 本少ない —— ただし等価になるのは 10 回目で `onArgs` を共有してからで、
probe 単独版には穴が残っていた(§3.4 の比較表、却下側は §3.5(E))。
現在は **7 本中 6 本が代替不能**、残る 1 本(`off ? EDITOR`)はメッセージのために残す重複である。
13 回目に 3 本目 —— 宣言された `default` を `options` から読む assert —— を足し、
`off` の引数についての規約を構造に置き換えた(§3.4)。評価回数も drv ハッシュも変わっていない。)
home-manager 側の行番号は、`flake.lock` が固定している input の実ファイルからの引用である
(`/nix/store/fm93mv69y0ify036r6zgnhqy1chw3vd0-source`。
`nix eval --raw --impure --expr '(builtins.getFlake (toString ./.)).inputs.home-manager.outPath'` で確認済み)。

本計画の設計は事前に承認済みであり、以下の 2 点は**再検討しない**:

1. **`EDITOR` だけを設定する。** home-manager 自身の `programs.neovim.defaultEditor` は `VISUAL` も
   設定する(`modules/programs/neovim/default.nix:97` と `:569-572`)。nvimx は意図的にそうしない。
2. **値は裸の文字列 `"nvim"`** であって `"${cfg.env.wrapped}/bin/nvim"` ではない。PATH 経由で解決し、
   その PATH は `home.packages`(`nix/home-manager/default.nix:330`)が既に賄っている。
   store path を環境変数に置かない。

**本計画の中核は §3.4 と §6 である。** この変更のコード本体は 2 箇所(26 行のオプション宣言ブロックと
`home.sessionVariables` の 1 行)しかなく、うち実質的なコードは 5 行である(残りは `description`)。
難所はすべて「その 1 行が消えたことを誰が検知するのか」に
集約される。既存の `hm-module-*` check は**1 つもそれを検知できない**ことを実測で確認済みなので(§1.4)、
実装者は §3.4 と §6.2 を必ず読むこと。

## 1. 背景 / 現状

### 1.1 今日のモジュールが deploy するもの(`nix/home-manager/default.nix:330-337`)

`config` は全体が `lib.mkIf cfg.enable`(`:279`)の中にある。その末尾は以下の 3 つだけである:

```nix
330    home.packages = [ cfg.env.wrapped ] ++ lib.optional cfg.lock.installCommand lockCommand;
331
332    xdg.configFile = lib.mkIf cfg.manageConfig {
333      nvim.source = cfg.configDir;
334    };
335
336    # Make the fs_stat in the standard bootstrap snippet succeed, neutralizing its git clone
337    xdg.dataFile."nvim/lazy/lazy.nvim".source = "${cfg.env.farm}/lazy.nvim";
```

**`home.sessionVariables` / `EDITOR` / `defaultEditor` はコードにもドキュメントにも 1 回も出てこない。**
計画作成時の実測(`docs/plans/` はこの計画書自身が該当してしまうので、`#27` が
`grep -rn extraLuaPackages nix/ README.md` と書いたのと同じ流儀でパスを絞ってある。
**この形なら本計画がコミットされたあとも空のままである**):

```
$ grep -rn 'sessionVariables\|EDITOR\|defaultEditor' nix/ lua/ flake.nix README.md docs/architecture.md templates/
$ echo $?
1
```

つまり本件は既存機能の拡張ではなく、**モジュールにとって 4 つ目の deploy 面を新設する**変更である。
この非対称性が §3.4(check の設計)と §4.1(`makeEnv` を通らないこと)の前提になる。

### 1.2 home-manager 側の前例(pinned input で実読)

`defaultEditor` は home-manager のエディタモジュール 3 つが揃って持っている。**3 つとも `VISUAL` も
設定する**:

| モジュール | 場所 | 設定する値 |
|---|---|---|
| `programs.neovim` | `modules/programs/neovim/default.nix:569-572` | `EDITOR = "nvim"` / `VISUAL = "nvim"` |
| `programs.vim` | `modules/programs/vim.nix:215-218` | `EDITOR = "vim"` / `VISUAL = "vim"` |
| `programs.helix` | `modules/programs/helix.nix:250-253` | `EDITOR = "hx"` / `VISUAL = "hx"` |

オプション宣言の形(`modules/programs/neovim/default.nix:97-105`、逐語):

```nix
 97      defaultEditor = mkOption {
 98        type = types.bool;
 99        default = false;
100        description = ''
101          Whether to configure {command}`nvim` as the default
102          editor using the {env}`EDITOR` and {env}`VISUAL`
103          environment variables.
104        '';
105      };
```

配線の形(`同:566-574`、逐語):

```nix
566      home = {
567        packages = [ cfg.finalPackage ];
568
569        sessionVariables = mkIf cfg.defaultEditor {
570          EDITOR = "nvim";
571          VISUAL = "nvim";
572        };
573
574        shellAliases = mkIf cfg.vimdiffAlias { vimdiff = "nvim -d"; };
```

**`{command}` / `{env}` という markdown role は upstream(nixpkgs / home-manager)固有の記法であり、
nvimx のモジュールは 1 箇所も使っていない。**本件の description でも使わない(§3.1)。
`mkOption` / `mkIf` を**`let` の `inherit (lib) …` で引き込んで裸書きしている**点も同様である
(`modules/programs/neovim/default.nix:10-18` / `vim.nix:8-13` / `helix.nix:9-14`。
3 ファイルとも `lib` 全体を開く `with lib;` はどこにも無い —— `with types;`(`vim.nix:100`、
`helix.nix:31` / `:91`)や `with lib.maintainers;`(`neovim/default.nix:50`)、
`with pkgs.…`(`neovim/default.nix:348`、`helix.nix:98`)はあるが、いずれも局所的である)。
nvimx 側は `lib.mkIf` / `lib.mkOption` と
**その場で書き切る**規約である(`nix/home-manager/default.nix:332` の
`xdg.configFile = lib.mkIf cfg.manageConfig`)。
**ただしこの対比は upstream 側でも一様ではない** —— `vim.nix` は `mkIf` を `inherit` していないので、
`:215` の `home.sessionVariables` は `lib.mkIf cfg.defaultEditor` と nvimx と同じ形で書かれている。
違うのは「`let` に引き込むかどうか」であって、修飾の善悪ではない。

### 1.3 オプション宣言順と README 表の連動

**トップレベルのオプション宣言順**(15 件)。これを出すコマンドは以下である ——
宣言は 3 種類(`lib.mkEnableOption` が 1 件、`lib.mkOption` が 11 件、素の attrset が 3 件)あり、
`lib.mkOption` だけを見る grep では `enable` / `plugins` / `treesitter` / `lock` が落ち、
逆に入れ子の `lib.mkOption` 7 件(`overrides` `:164` など)が混ざる:

```
$ grep -n '^    [a-zA-Z]* = lib.mk\|^    [a-zA-Z]* = {' nix/home-manager/default.nix
 36:    enable           38:    package          48:    configDir        58:    lockDir
 67:    manageConfig     76:    vimAlias         82:    viAlias          88:    extraPackages
 95:    extraLuaPackages 121:   devPlugins       142:   devPath          163:   plugins
210:    treesitter       235:   lock             266:   env
```

(出力は 1 行 1 件なので、上では 4 列に畳んで名前だけを残してある。
`plugins` / `treesitter` / `lock` が素の attrset であることは §3.1 決定 1 でも触れている。)

README の `## Options` 表(`:203-221`)は**この順を行単位でそのまま写したもの**である。
`viAlias` はモジュール `:82-86` / README `:209`、その次の `extraPackages` はモジュール `:88-93` /
README `:210` で一致している。したがって**モジュールの挿入位置が README の行順を決める**。
`#26` / `#27` の計画が同じ制約を明記しており(`docs/plans/26-dev-plugins.md:723` 付近、
`docs/plans/27-extra-lua-packages.md` §4.6(a))、本件もそれに従う。

### 1.4 既存の `hm-module-*` check は本件の退行を 1 つも検知できない(実測)

`mkHmCheck`(`flake.nix:198-214`。`:197` はその直前のコメント)は
**activation package を返すだけで、その中身について何も assert しない**:

```nix
198          mkHmCheck =
199            nvimxConfig:
200            (home-manager.lib.homeManagerConfiguration {
   ...
214            }).activationPackage;
```

`hm-module-*` ファミリは `flake.nix:217-275` に 6 件が連続している
(`hm-module` `:218`、`hm-module-degrade` `:227`、`hm-module-plugins` `:235`、
`hm-module-treesitter` `:249`、`hm-module-dev` `:260`、`hm-module-lua-packages` `:270`。
`:275` の `};` が最後で、`:276` から `wrapper-aliases` のコメントが始まる)。
**6 件すべてが `mkHmCheck` を呼ぶだけの定義である**(中身はフィクスチャとオプションの指定に尽きる。
行数は 4〜12 行 —— `hm-module-plugins` の `:235-246` が最長で、`overrides` に
`overrideAttrs` の関数を書いているためである)。

したがって `home.sessionVariables` の 1 行を消しても、オプションは型検査を通り、黙って無視され、
activation package はそのままビルドできる。**計画作成時に実測済み** ——
シミュレート用のクローン(`git clone --local`)に本計画の実装をそのまま当て、そこから
`home.sessionVariables = lib.mkIf cfg.defaultEditor { EDITOR = "nvim"; };` の 1 行だけを削除した状態で:

```
$ nix build --no-link .#checks.x86_64-linux.hm-module .#checks.x86_64-linux.hm-module-degrade
[... trace ...]
$ echo $?
0
```

(`[... trace ...]` は degraded モードの warning trace 4 行と
`evaluation warning: nixfmt-rfc-style is now the same as pkgs.nixfmt ...` の省略である。R4 参照。
以下の transcript も同じ規則で省略してある。)

**緑のまま通る。** これが「新しい check が要る」という issue の主張の実体であり、§3.4 の出発点である。

**`home.sessionVariables` だけが無防備なのではない。** 同じ削除実験を他の 3 面でも行ったところ、
`home.packages` の行を消しても、`xdg.configFile` のブロックを消しても、`xdg.dataFile` の行を消しても
**どちらの check も exit 0 のまま**だった。`grep -n 'home\.packages\|sessionVariables' flake.nix` も
(本件の新 check を入れる前は)空である。つまり**モジュールの deploy 4 面はどれ 1 つ assert されていない**。
本件の check はその最初の 1 つを塞ぐのであって、最後の 1 つを塞ぐのではない —— この区別は
`flake.nix` に残すコメント(§5.2)でも書き分ける。取り違えると、他の 3 面について
同じ assert を書こうとした人が「もう守られている」と読んで手を止めてしまう。

### 1.5 同じ問題を既に解いている 2 つの前例

`flake.nix` には「モジュールを評価して `.config` を読み返す」assert が既に 2 つある。どちらも
まったく同じ理由で書かれており、コメントもそう書いてある:

- `checks.extra-lua-packages` の `moduleWrapped`(`flake.nix:344-363`)——
  `.config.programs.nvimx.env.wrapped` を読む。`:329-343` のコメントが
  「`mkHmCheck` returns only an activationPackage and asserts nothing about it, so dropping
  `extraLuaPackages` from makeEnv's argument list ... leaves it green」と明言している。
- `checks.dev-plugins` の `moduleDevDirs`(`flake.nix:3560-3580`)——
  `.config.programs.nvimx.env.devDirs` を読む。`:3549-3559` のコメントが同じことを書いている。

**本件はこの 2 つと同型だが、読む先が `programs.nvimx.env` ではなく `home.sessionVariables` である。**
`defaultEditor` は `makeEnv` を一切通らないので(§4.1)、`env` 経由では観測できない。

**モジュールを評価して読み返す 2 つの前例のうち、degraded な lockDir を使っているのは
`moduleWrapped` だけ**である(`:358` の `lockDir = ./tests/fixtures/basic-config/no-such-lock`)。
**`moduleDevDirs` は実 lock を使う**(`:3574` の `.../nvimx-lock`)。
**`no-such-lock` 自体はもっと広く使われている** —— `flake.nix` に全 6 箇所あり、
`hm-module-degrade`(`:229`)、`extra-lua-packages` の `mkEnv`(`:304`)と `moduleWrapped`(`:358`)、
`dev-plugins` の `degraded` / `devEnv` / `plainEnv`(`:3546` / `:3588` / `:3598`)である。
このうちモジュールを評価するのは `:229` と `:358` だけで、残りは `makeEnv` を直接呼ぶ env か
activation package である。本件が degraded を選ぶ根拠は、そのうち
**`moduleWrapped` だけ**である(`:343` の「Degraded lockDir again, to stay offline」。
`mkEnv`(`:304`)も同じ理由 —— check 全体のコメント `:293-295` —— だが、
そちらはモジュールを評価しないので「読み返す前例」には入らない。§3.4 も同じ区別で書いてある)。
`hm-module-degrade`(`:225-230`)は**同じフィクスチャを使う前例ではあるが、理由が違う** ——
`:225-226` のとおり degraded モードそのものが主題である。`moduleDevDirs` はどちらでもない(§3.4)。

## 2. ゴール

issue 本文の要求 —— 2 つの narrowing(`EDITOR` のみ / 裸の `"nvim"`)と
「専用の check が要る」—— を検証可能な形に落とす。
(**issue #67 に `Done when` 節は無い。** 見出しが 1 つも無く、本文は散文 4 段落・`nix` の
フェンス 1 つ(`home.sessionVariables = lib.mkIf cfg.defaultEditor { EDITOR = "nvim"; };`)・
2 項目の箇条書き(2 つの narrowing)からなる。`#26` / `#27` の issue には
`Done when` 節があるので両計画は「issue の "Done when" を…」で始まるが、無い `#56` の計画は
その書き出しを使っていない。本計画も使わない。)

- **G1(true の場合)**: `programs.nvimx.defaultEditor = true` のとき
  `config.home.sessionVariables.EDITOR == "nvim"` になる。
- **G2(false / 既定の場合)**: `defaultEditor` を設定しないとき、`config.home.sessionVariables` に
  **`EDITOR` キーが 1 つも存在しない**。「無害な値が入る」ではなく「不在」である。
- **G3(`EDITOR` だけ)**: true にしても `VISUAL` は設定されない。より強く、
  `removeAttrs on [ "EDITOR" ] == off` —— つまり **`home.sessionVariables` の中で**
  このオプションが足すのは `EDITOR` ただ 1 つで、他の何も変えない。
  **この限定は本物である** —— 比較対象は `home.sessionVariables` だけなので、
  たとえば `home.sessionVariablesExtra` に `export VISUAL=nvim` を足す 1 行は
  この check を通り抜ける(実測)。assert のメッセージも
  `... and change nothing else in home.sessionVariables` と限定して書いてある。R1 参照。
- **G4(退行が検知される)**: `home.sessionVariables` の 1 行に対する **7 通り**の改変が
  すべて `checks.hm-module-default-editor` を赤にする —— 行を消す / `lib.mkIf` を外して `EDITOR` を
  無条件にする / `mkIf` の中に `VISUAL` を足す / **`VISUAL` だけを無条件に足す** /
  **`lib.mkDefault` にする** / **`lib.mkForce` にする** / **値を store path にする**。
  §6.2(b) に実測結果を置く。**(d)(e)(f)(g) はそれぞれ assert を 1 本しか赤にしない**(当たる先は
  (d) → `on ? VISUAL`、(e)(f) → どちらも `contested`、(g) → `on.EDITOR` の 3 本)。
  **5 本目**の `removeAttrs` が代替不能であることは、この 7 通りではなく §6.2(c) の `PAGER` probe が、
  **7 本目**の `competingModule` probe が代替不能であることは §6.2(c) の
  「競合モジュールの打ち間違い」行が、**3 本目**の宣言 assert が代替不能であることは
  §6.2(c) の `off` の引数の行が示す ——
  どれもモジュールの 1 行を書き換えるだけでは再現できない種類の退行だからである
  (§5.2 の並び順で 1 `on.EDITOR` / 2 `off ? EDITOR` / 3 `offEval.options…default` /
  4 `on ? VISUAL` / 5 `removeAttrs` / 6 `contested` / 7 `competingModule` probe。
  本計画の序数はすべてこの順である)。
  合わせて**7 本のうち 6 本が代替不能**になる(§6.1 / §6.2(c) が実測で示す)。
- **G5(オフライン・新規 fetch ゼロ)**: 新 check は degraded な lockDir を使い、
  `env.wrapped` も `env.farm` も強制しないので `fetchTree` が 1 回も起きない。
  ビルドするのは `touch $out` の `runCommand` 1 つだけである。
- **G6(ドキュメント)**: README の `## Options` 表に `viAlias` の直後の行が入り、
  `docs/architecture.md` の checks 列挙と hm deployment の列挙が新しい事実を反映し、
  `templates/default/flake.nix` に `# vimAlias = true;` と並ぶコメント行が入る。
  **本件が触るファイルは `nix/home-manager/default.nix` / `flake.nix` / `README.md` /
  `docs/architecture.md` / `templates/default/flake.nix` の 5 つで確定である** ——
  §5 の節立てと §8 手順 7 の `grep` もこの 5 つを数える。

## 3. 設計

### 3.1 オプション

```nix
    defaultEditor = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Set EDITOR to `nvim` in home.sessionVariables.

        EDITOR only. home-manager's own programs.neovim.defaultEditor sets VISUAL as well;
        nvimx does not, so a VISUAL you set yourself stays yours.

        The value is the bare command name rather than a path into the Nix store. It resolves
        through PATH, which home.packages already covers, and hm-session-vars.sh exports it
        into the session, where a store path would outlive the generation that set it in every
        shell still running.

        Anything else that sets home.sessionVariables.EDITOR meets this the way home-manager
        merges any two definitions: the same value merges in silence, a different one fails the
        evaluation, and nvimx neither yields to it nor overrides it. programs.neovim, enabled
        and with its own defaultEditor on, is the silent case -- the same bare "nvim", plus a
        VISUAL of its own. programs.vim / programs.helix, likewise enabled with theirs on, are
        the failing one (any of those modules with defaultEditor off, or not enabled at all,
        contributes nothing here), and so is a hand-written EDITOR line whose value is anything
        but "nvim" -- delete that line rather than keep both, since replacing it is what this
        option is for. The error names home-manager's module file but never nvimx's, and between
        nvimx and a hand-written line inside a flake it names neither.
      '';
    };
```

決定事項:

1. **`lib.mkOption` / `lib.types.*` を書き切る。`with lib;` は使わない。** リポジトリの規約であり、
   このファイルの既存の `lib.mkOption` 18 件すべてがそうなっている
   (`grep -c 'lib.mkOption' nix/home-manager/default.nix` → `18`。
   トップレベルの名前は `enable` が `lib.mkEnableOption`(`:36`)、
   `plugins` / `treesitter` / `lock` が素の attrset なので、名前の数とは一致しない)。
2. **upstream の `{command}` / `{env}` role は使わない**(§1.2)。nvimx のどの description にも無い。
3. **`defaultText` は不要。** `default` が関数ではなく `false` なので、`extraLuaPackages`
   (`:95-119`、`default = _: [ ]` に `defaultText` が付いている)のような必須事情が無い。
4. **`example` も付けない。** `bool` かつ既定が `false` なので、`vimAlias`(`:76-80`)/
   `viAlias`(`:82-86`)/ `manageConfig`(`:67-74`)と同じく example 無しが既存の形である。
   `example = true;` は情報量がゼロである。
5. **挿入位置は `viAlias`(`:82-86`)の直後、`extraPackages`(`:88`)の直前。**
   `vimAlias` / `viAlias` と同じ「wrapper の外側に 1 個だけ何かを足す bool」の並びに入る。
   README の表の行順もこれで決まる(§1.3、§5.3)。

### 3.2 `config` 側の配線

```nix
    home.sessionVariables = lib.mkIf cfg.defaultEditor { EDITOR = "nvim"; };
```

- **置き場所は `home.packages`(`:330`)の直後**、`xdg.configFile`(`:332`)の直前。
  `home.*` の 2 つを隣に置く形であり、home-manager 自身の
  `home = { packages = ...; sessionVariables = ...; }`(`neovim/default.nix:566-572`)と同じ並びになる。
  既存の `home.packages` の行は 1 文字も触らない。
- **`lib.mkIf` を使う**(`lib.optionalAttrs` ではない)。`:332` の
  `xdg.configFile = lib.mkIf cfg.manageConfig { ... }` と同じ形であり、home-manager の 3 モジュールも
  `mkIf` である(§1.2)。`config` 全体が既に `lib.mkIf cfg.enable`(`:279`)の中なので mkIf の入れ子に
  なるが、これは module system が普通に扱う形である(実測済み: §6 の check が両ケースとも通る)。
- **`enable = false` のときは何も起きない。** `defaultEditor = true` と書いてあっても、
  `config` 全体が `mkIf cfg.enable` の中なので `EDITOR` は設定されない。
  `home.sessionVariables.EDITOR` を手書きするのとの実質的な違いはここであり、
  「nvimx を切ったら EDITOR も一緒に消える」のは望ましい挙動である。

  **この保証は位置によるものであって、assert は 1 本も無い。** この行が
  `config = lib.mkIf cfg.enable { ... }`(`:279`)の中に他の 3 つの deploy 面と並んでいる、
  という事実がすべてである。**check は `enable = false` を一度も評価しない** ——
  `on` / `off` / `competing` の 3 つはどれも `enable = true` を渡す(§3.4)ので、
  この保証は観測範囲の外にある。**実測**: `config` を
  `lib.mkMerge [ { home.sessionVariables = lib.mkIf cfg.defaultEditor { ... }; } (lib.mkIf cfg.enable { ... }) ]`
  に組み替えると **check は 7 本とも緑のまま**で、`enable = false; defaultEditor = true;` が
  `EDITOR = "nvim"` を吐くようになる。**8 本目の assert は足さない** ——
  観測するには `enable = false` の 4 つ目の評価が要り、それは §3.5(E) が値付けして却下したコストである。
  **R6 に同じ退行の帰結を記録してある**(R7 と同じ扱い: 固定されていない主張は、
  固定されていないと書く)。
- **`lib.mkDefault "nvim"` にはしない。** 衝突(§4.3 / R1)を評価エラーにせず済ませられる唯一の
  手段だが、**負ける側の挙動が最悪である**。計画作成時に `EDITOR = lib.mkDefault "nvim"` で実測:

  | 併用 | `mkDefault` にしたときの結果 |
  |---|---|
  | 手書きの `home.sessionVariables.EDITOR = "vim";` | `"vim"`。**`defaultEditor = true` が黙って無効になる** |
  | `programs.vim = { enable = true; defaultEditor = true; };` | `"vim"`。同じく黙って無効(`enable` が要る理由は §4.3) |
  | 併用なし | `"nvim"`(意図どおり) |

  「有効にしたオプションが、古い手書きの行に負けて何も言わない」のは、評価エラーより悪い。
  **ユーザは `defaultEditor = true` を書いた時点で意思表示しており、それを既定値扱いしてはならない。**
  upstream 3 モジュール(§1.2)もすべて素の `mkIf` であり、`mkDefault` は使っていない。
  **`lib.mkForce` も同じ理由で採らない** —— こちらは逆に他方を黙って潰す。
  衝突は衝突として出すのが正しい。
  **この判断は check が守る。** `on` / `off` の 2 つだけでは見えない(どちらにも競合する定義が無く、
  優先度が観測されない)ので、**競合する定義を置いた 3 つ目の評価**を `builtins.tryEval` で包み、
  **例外になること**を assert する(§3.4 の 6 本目、§6.1)。`mkDefault` にすると相手が勝って
  `success = true` に、`mkForce` にすると nvimx が勝ってやはり `success = true` になるので、
  どちらも赤になる。**計画作成時に 3 通りとも実測済み**(§6.2(b) の (e)(f)、§6.2(c) の 7 行目)。
  当初はここを「check では守られない、レビューで目視」と書いていたが、
  **安く塞げる穴を申し送りにする理由が無い**ので assert を 1 本足す側に倒した。

### 3.3 `EDITOR` のみ / 裸の `"nvim"`(承認済み・再検討しない)

決定の根拠だけ記録しておく:

- **`VISUAL` を設定しない。** `VISUAL` は「フルスクリーン端末エディタ」を指す変数であり、
  `EDITOR` と別に持ちたいユーザが実在する。upstream 3 モジュールが両方を設定しているのは
  「エディタを丸ごと乗り換える」モジュールだからで、nvimx は neovim の配り方を変える道具である。
  **narrowing であることを check が固定する**(§6.1 の `on ? VISUAL` assert)。
- **値は `"nvim"`。** store path を書くと (a) その store path が**セッション全体に**行き渡り、
  (b) generation を切り替えても古いシェルセッションの `EDITOR` が古い store path を
  指し続ける、という 2 点が生じる。PATH 経由なら `home.packages`(`:330`)が常に最新の
  generation を指す。**(b) の方が鋭いので、description に書いているのはそちらである。**

  **伝播経路を `extraLuaPackages` と取り違えないこと。** あちらの description
  (`nix/home-manager/default.nix:115-117`)が「anything neovim launches ... inherits them」と
  書けるのは、`LUA_PATH` / `LUA_CPATH` を**wrapper が**設定していて、スコープが
  neovim の子プロセスに限られるからである。`EDITOR` はそうではない ——
  `home.sessionVariables` → `hm-session-vars.sh`(`modules/home-environment.nix:663-676`)→
  ログインシェルが export、という経路で**セッション内の全プロセス**が継承する。
  そもそも `EDITOR` を読むのは `git` / `crontab` / `sudoedit` であって、
  neovim が起動するものではない。**そこが本オプションの存在理由そのものである。**

### 3.4 新 check `hm-module-default-editor` —— 本計画の要

**必要性**: §1.4 で実測したとおり、`home.sessionVariables` の 1 行を消しても既存の
`hm-module-*` 6 件は全部緑のままである。`mkHmCheck` を 7 件目として足しても状況は変わらない ——
返るのは activation package だけで、その中身を誰も見ないからである。

**形**: `.config.home.sessionVariables` を**評価レベルで読み返す**。`checks.dev-plugins` の
`moduleDevDirs`(`flake.nix:3560-3580`)/ `checks.extra-lua-packages` の `moduleWrapped`
(`flake.nix:344-363`)とまったく同じ shape である。違いは読む先が `programs.nvimx.env` ではなく
`home.sessionVariables` である点だけで、これは `defaultEditor` が `makeEnv` を通らない(§4.1)ことの
直接の帰結である。

**モジュールを 3 回評価する。** `on` / `off` の 2 つでは「頼まれたら `EDITOR` を設定する」と
「常に `EDITOR` を設定する」を区別できない —— `off` をまったく評価しなければ、
`lib.mkIf` を外した実装がそのまま通る。issue が「with both the true and the false case」と
明記しているのはこの非対称性のためである。**3 つ目(`contested`)はそれとは別の軸である** ——
`on` / `off` はどちらも競合する定義が無い世界なので、**nvimx がどちらに譲るか**が観測できない。
**外から同じ変数を別の値で定義したうえで**評価して初めて、`lib.mkDefault`(相手が勝つ)と
`lib.mkForce`(nvimx が勝つ)が素の `mkIf`(衝突のまま落ちる)から区別できる(§3.2)。
`tryEval` は `checks.plugins-escape-hatch` が既に使っているイディオムである。

**`contested` には control が要る。ここが本 check で最初に見つかった
「緑なのに何も検査していない」状態である**(**のちに 2 つ見つかる** —— `onArgs` を共有しない形と
`off` に明示の値を渡す形。§6.2(c) の守り手表)。`builtins.tryEval` は**理由を問わず例外を
`success = false` にする**ので、外から渡すモジュールが衝突とは無関係な理由で落ちても ——
たとえばオプション名を打ち間違えて `home.sessionVariablesTypo.EDITOR` になっていても ——
assert は満たされてしまう。
**実測**: そのオプション名を 1 つ打ち間違えるだけで、`mkDefault` を入れた実装ですら check が緑になる。
§6.2(b) の改変表も §6.2(c) の削除実験も**この腐敗は原理的に見えない**(前者はモジュールの 1 行しか、
後者は assert しか動かさないため)。

**control は 4 つ目の評価ではなく、2 つの措置の組み合わせにする。** どちらも評価を増やさない:

1. **外部モジュールを括り出し、モジュール全体を probe する。**
   `competingModule = value: { home.sessionVariables.EDITOR = value; };` と名前を付け、
   **評価を一切せずに** `competingModule "vim" == { home.sessionVariables.EDITOR = "vim"; }` を
   assert する。**「その 1 パスの値」ではなく「モジュール全体」を比べるのが要点である** ——
   パスを打ち間違える腐敗だけでなく、**属性を足して別の理由で throw させる**腐敗も同時に塞がる。
   レビュー 11 回目までは `(competingModule "vim").home.sessionVariables.EDITOR == "vim"` という
   1 パスだけの形で、**`home.stateVersion = "24.11";` を足すと `mkDefault` 退行込みで緑になった**
   (実測。`bogusOptionNobodyDeclared = 1;` のような未宣言オプションでも同じ)。
   全体比較にすると 3 種とも赤になる(§6.2(c))。
2. **`competing` に渡す nvimx 側の引数を `on` と共有する。**
   `onArgs = { nvimx.defaultEditor = true; };` を `on = sessionVariables onArgs;` と
   `competing = value: … (onArgs // { modules = [ (competingModule value) ]; }) …` の**両方**で使う。

**2 が要るのは、probe だけでは穴が残るからである。** probe が見るのは `competingModule` だけで、
`competing` の**呼び出しの残り**は見ない —— そして `competing` は自分で
`nvimx.defaultEditor = true;` を渡していた。**実測**: その 1 行を `nvimx.defaultEditorTypo` に変えると、
`tryEval` が「オプションが存在しない」例外を掴んで `success = false` になり、
**正しい実装でも `mkDefault` に退行した実装でも check が緑になる** ——
§8 手順 5 が「本件最大の失敗モード」と呼ぶ状態そのものである。
`onArgs` を共有すると同じ打ち間違いは **`on` の側で instantiation ごと落ちる**ので
(`error: The option 'programs.nvimx.defaultEditorTypo' does not exist`)、assert で覆い隠しようがない。
**実測で両方を確認済み**(§6.2(c) の `onArgs` の 3 行)。

**4 つ目の評価(`agreeing = competing "nvim"`、同値ならマージされることを見る)も実装して計測し、
そのうえで probe + `onArgs` を採った。** 両者の実測比較:

| | 4 評価版(`agreeing`) | 3 評価版(probe + `onArgs`) |
|---|---|---|
| `competingModule` の打ち間違い | 赤 | 赤 |
| 同上 + `mkDefault` | 赤 | 赤 |
| **`competing` の nvimx 引数の打ち間違い** | 赤 | **赤**(`onArgs` 共有が無ければ緑だった) |
| 同上 + `mkDefault` | 赤 | **赤**(同上) |
| `mkDefault` / `mkForce` 単体 | 赤 | 赤 |
| (g) store path | `on.EDITOR` と control の **2 本**が赤 | `on.EDITOR` の **1 本だけ**が赤 |
| `on.EDITOR` を消して (g) | **赤のまま**(control が拾う)= `on.EDITOR` が重複になる | **緑** = `on.EDITOR` は代替不能のまま |
| 代替不能な assert | 7 本中 **5 本** | 7 本中 **6 本** |
| この check 自身の trace | **4 本** | **3 本** |
| `nix flake check` 全体の trace | **6 本** | **5 本** |
| drv ハッシュ | 同一 | 同一 |

**3 評価版が安く、しかも重複を 1 本減らす。塞ぐ穴は同じである** —— ただしそれは
`onArgs` 共有まで入れた場合であって、**probe 単独では上の 3・4 行目が緑になる**。
失うのは `agreeing` の副産物だった「同値なら黙ってマージされる」の pin
(§3.1 の description・§4.3 の 4 行目・R1 が約束している挙動)だけであり、
**それは home-manager 側のマージ規則であって nvimx の挙動ではない** ——
下の (b) が「固定してしまうこと」を**コストとして**挙げているものでもある。
§3.5(E) に却下として、pin が無いことを R7 に記録した。

**3 つ目の評価と probe は「足すか否か」を検討したうえで足している。** コストは
(a) モジュール評価が 1 回増え、**この check 自身の** degraded warning trace が 2 本から **3 本**に
なること(`nix flake check` 全体の**本数**は **2 → 5**、**増分は 3 本**で、それを数えているのが R4 である
—— 今日の 2 本は `moduleWrapped` と `hm-module-degrade`。いずれの数も実測)、
(b) `contested` が **home-manager 側のマージ規則**(`types.str` は値の違う 2 定義を拒む)を
固定してしまうこと、の 2 点である。それでも足すのは、
**`contested` が無いと §3.2 の決定(`mkDefault` / `mkForce` を採らない)を守るものが 1 つも無く**
(実際 `mkDefault` を足しても他は全部緑。§6.2(c))、
**probe が無いと `contested` 自身が黙って死にうる**からである。
「安く塞げる穴を申し送りにしない」——(b) のリスクは R2 と同じ性質であり、
壊れたら赤くなるのは黙って通るより望ましい。

**`on` / `off` の 2 回を評価することが要るのであって、`off ? EDITOR` という assert が要るのではない。**
`off ? EDITOR` は後述の `removeAttrs` の assert **単独に**厳密に包含される —— `off` が `EDITOR` を
持てば、定義上 `EDITOR` を持たない `removeAttrs on [ "EDITOR" ]` とは必ず食い違うからである
(`on.EDITOR` の assert は関与しない)。実測済み: `off ? EDITOR` の `lib.optional` を削ってから
`lib.mkIf` を外す改変を当てても、`removeAttrs` の assert が拾って赤になる(§6.2(c))。
**それでも残すのはメッセージのためである。**

**この assert を消すことと、2 回目の評価を消すことは別である。** `removeAttrs` の比較が `off` を
要求するので、`off = sessionVariables { }` の束縛は `off ? EDITOR` が無くなっても残る。
§5.2 のコメントでもこの 2 つを別の場所に書き分けてある(「評価を分ける理由」は束縛の側、
「この assert は重複」は assert の側)—— 同じコメントに並べると、重複だからと
束縛ごと消されて網羅 assert が静かに壊れる。

**さらに、束縛が残るだけでは足りなかった —— `off` に渡す引数が `{ }` であること自体が
`default = false`(§3.1)の唯一の守り手になっていた。** それは規約であって assert ではないので、
**3 本目の assert を足して構造に置き換えた**(序数は §2 G4 が定めた source order。末尾の probe ではない)。実測:

| `flake.nix` | モジュール | 3 本目**なし** | 3 本目**あり**(現行) |
|---|---|---|---|
| `off` の引数が `{ }`(現行) | `default = true;` に変える | 赤(2 本) | **赤(3 本)** |
| `off` の引数を `{ nvimx.defaultEditor = false; }` にする | `default = true;` に変える | **緑になってしまう** | **赤(1 本)** |
| 基底 attrset に `defaultEditor = false;` を足す | `default = true;` に変える | **緑になってしまう** | **赤(1 本)** |

**2 行目の書き方は「きれいに見える」方である** —— `on = sessionVariables onArgs;` と
対称になり、`off` が何を意味するかが一目で分かるように見える。3 本目が無ければ、
その整形が G2 を丸ごと無効化していた。

**3 本目は宣言そのものを読む。**
`offEval.options.programs.nvimx.defaultEditor.default != false` —— `homeManagerConfiguration` は
`config` と `options` を**同じ固定点から**返すので、`off` の評価を
`offEval = evalHm { };` として束縛し直し、そこから両方を射影すれば**評価は 1 回も増えない**。
実測で確認済み: 評価回数 3、この check の trace 3 本、`nix flake check` 全体 5 本、
**drv ハッシュも同一**(`68zdik9q…`)。`sessionVariables` は
`args: (evalHm args).config.home.sessionVariables` の 1 行の射影になる。

**これで `off` の引数はどちらでも等価になった** —— 挙動側(`off ? EDITOR` / `removeAttrs`)は
引数が何であれ成り立ち、宣言側は 3 本目が見る。§5.2 のコメントと注意点 5 本目
(`off` の束縛)は**「なぜ `{ }` の方を選んでいるか」**を残すが、
**もはや規約ではなく読みやすさの選択である**。§6.2(c) が 3 通りの書き方すべてを実測し、
§8 手順 5 の probe (k) がその 3 通りを踏む。

**重複は 1 本、代替不能が 6 本である。すべて実測で確かめた**
(§6.2(c) が 7 本すべてについて削除実験の結果を表にしてある):

| assert | それだけが捕まえる退行 |
|---|---|
| `on.EDITOR` | **値が `"nvim"` でなくなる。** 典型は `"${cfg.env.wrapped}/bin/nvim"` —— §3.3 の承認済み narrowing 2 がまさに禁じている形であり、これを見ているのはこの 1 本だけである(他は「`EDITOR` が在るか」しか見ない) |
| `off ? EDITOR` | **無し(重複)。** `removeAttrs` が拾う。残すのはメッセージのためだけである |
| `offEval.options…default` | **宣言された既定値が `false` でなくなる。** 挙動側の assert は `off` の引数が `{ }` である限りでしか既定値を見ていないので、引数を書き換えられると全部すり抜ける(上表)。宣言を直接読むのはこの 1 本だけである |
| `on ? VISUAL` | **`VISUAL` が無条件に設定される。** `on` と `off` の両方に現れるので `removeAttrs` の差分から**相殺され**、他のどの assert にも見えない |
| `removeAttrs` | `VISUAL` 以外の**未知の**変数が足される(実測は `PAGER` で行った)。名指しの assert が原理的に書けない相手を拾う |
| `contested.success` | **`lib.mkDefault` / `lib.mkForce`。** 競合の無い `on` / `off` では優先度が観測できないので、他は全部緑のままになる |
| `competingModule` の probe | **この check 自身の腐敗。** 外部モジュールが衝突以外の理由で落ちるようになると `contested` は黙って無効化されるが、それを見るのはこの 1 本だけである。**モジュール全体を比較する**ので、パスの打ち間違いにも余計な属性の追加にも反応する。モジュール側の改変では**原理的に再現できない**種類の退行なので、§6.2(b) の 7 通りには現れず、§6.2(c) の専用行だけが示す |

**`on ? VISUAL` を「`removeAttrs` に包含されるから消せる」と読んではならない。** 包含が成り立つのは
「`on` にだけ現れる」場合であって、無条件に設定された `VISUAL` はその条件を満たさない。
本計画はレビュー 2 回目までこれを取り違えており、`flake.nix` に残すコメントにまで
「包含されている」と書きかけた —— **本 issue が narrowing そのものを主題にしている以上、
その唯一の守り手に「消してよい」と書き残すのは最悪の誤りである**。
実測(§6.2(b) の改変 (d) と §6.2(c))でそれを是正した。

**`off == { }` と書いてはならない。** `home.sessionVariables` は home-manager 自身が勝手に埋める。
計画作成時の実測(本件のオプションを入れていない素のモジュールで `.config.home.sessionVariables` を評価):

| system | 既定で入っているキー |
|---|---|
| `x86_64-linux` | `LOCALE_ARCHIVE_2_27 = "/nix/store/...-glibc-locales-2.42-67/lib/locale/locale-archive"` |
| `aarch64-darwin` | `TERMINFO_DIRS = "/home/nvimx-test/.nix-profile/share/terminfo:$TERMINFO_DIRS${TERMINFO_DIRS:+:}/usr/share/terminfo"`(逐語・省略なし) |

(linux 行の `...` は store のハッシュを略したものである。darwin 行は値の末尾まで逐語で載せてある ——
途中で切ると「`$TERMINFO_DIRS` で終わる短い値」に見えてしまい、§1.4 が立てた省略の規約にも反する。)

**両システムとも空ではなく、しかも中身が違う。** したがって否定側の assert は
**キー単位で `off ? EDITOR` と書く**。これを `off == { }` にすると、nvimx とは無関係な理由で
両システムとも赤くなる。

**`removeAttrs` による網羅 assert を 1 本足す。** `builtins.removeAttrs on [ "EDITOR" ] == off` は
「このオプションが足すのは `EDITOR` ただ 1 つで、他の何も変えない」を変数名を挙げずに言い切る形であり、
system 非依存でもある(上の表の差はどちらの辺にも等しく現れるので打ち消し合う)。
**この assert が包含するのは `off ? EDITOR` だけであり、`on ? VISUAL` は包含しない。**
無条件に設定された `VISUAL` は `on` と `off` の両方に現れて差分から**相殺される**ので、
その退行を見られるのは `on ? VISUAL` だけである(上表、実測は §6.2(c) の **5 行目**。
その直前の 4 行目は**条件付きの** `VISUAL` の場合で、そちらは `removeAttrs` が拾うので赤のままである
—— 2 つを取り違えると「包含されている」という誤読に戻る)。
副次的な理由として、網羅 assert のメッセージは「何かが増えた」としか言わず、
`VISUAL` という具体的な narrowing が壊れたことは読み取れない —— **仮に包含が成り立っていたとしても**
名指しの assert を残す理由にはなる。
`checks.dev-plugins` がキー名を挙げた assert(`flake.nix:3628-3635`。per-key のものは `:3601-3606` と `:3617-3619`)と
「全 value が `devPath` 始まり」の網羅 assert(`:3638-3640`)を併置しているのと同じ判断である。

**失敗の運び方は `failures` リスト + `pkgs.runCommand`。** `dev-plugins` / `extra-lua-packages` /
`treesitter-grammars` と同じイディオムで、`failures == [ ]` なら `"touch $out"`、
さもなくば全件を stderr に出して `exit 1` する。

**lockDir は `./tests/fixtures/basic-config/no-such-lock`。** `defaultEditor` は lock に一切依存しないので
degraded で十分である。**モジュールを評価して `.config` を読み返す前例のうち、同じ理由で
同じフィクスチャを使っているのは `moduleWrapped`(`:358`)だけ**である —— `:343` の
「Degraded lockDir again, to stay offline」がその理由で、本件と同じ「オフラインでいるため」である。
(**`extra-lua-packages` は同じフィクスチャを `mkEnv`(`:304`)でも使っており、理由も同じである**
—— check 全体のコメント `:293-295` の「Deliberately built in degraded mode: … not one plugin
source is fetchTree'd」はそちらを指している。ただし `mkEnv` は `makeEnv` を直接呼ぶので
モジュールを評価しない。上の「だけ」はその限定つきである。§1.5 も同じ区別で書いてある。)
**`hm-module-degrade`(`:225-230`)は前例だがそれは「フィクスチャの」前例にすぎない** ——
`:225-226` の自己申告は「Without a lock: evaluation must still succeed via the degraded build
(verifies the chicken-and-egg problem is solved)」であり、あちらは degraded モードが**主題**であって、
オフラインでいるための手段ではない。この 2 つを取り違えないこと。

本件の check は `env.wrapped` も `env.farm` も強制しないので、`hasLock` の真偽に
関わらず `fetchTree` は起きない。**代償は `nix flake check` の出力に degraded 警告の trace が
3 本増えること**である(モジュールを 3 回評価するため)。`moduleWrapped` が既に 1 本出しているので
新種のノイズではない。実 lock(`basic-config/nvimx-lock`)に替えれば黙らせられるが、
lock と無関係な機能の check を lock に結び付ける取引になるので採らない。

**挿入位置は `hm-module-lua-packages` の終端 `};`(`flake.nix:275`)の直後、
`# vimAlias / viAlias` のコメント(`:276`)の直前** —— すなわち `hm-module-*` ファミリの末尾。根拠:

- 名前が `hm-module-*` である。このファミリの命名規則は「モジュールのこのオプション面を通す」であり
  (`hm-module-plugins` / `hm-module-treesitter` / `hm-module-dev` / `hm-module-lua-packages`)、
  本件はまさにそれである。**lib レベルの面が存在しない**ので、`extra-lua-packages` のような
  ファミリ外の名前にする余地が無い。
- `docs/architecture.md:516` の checks 列挙は `hm-module-*` が連続する形になっており、
  ファミリ末尾に置けばその並びが保たれる(§5.4)。
- **`mkHmCheck` を呼ぶだけの定義ではない**(ファミリで唯一)という不揃いは、コメントで理由を明記して
  引き受ける。`mkHmCheck` では検知できないことこそがこの check の存在理由なので、
  不揃いであること自体が情報になる。

### 3.5 却下する代替案

**(A) `hm-module`(`:218`)に `defaultEditor = true;` を足して済ませる。**
`mkHmCheck` は何も assert しないので(§1.4 の実測)、1 バイトも守られない。加えて
false ケースを同じフィクスチャから観測できない。

**(B) activation package をビルドして `hm-session-vars.sh` を `grep` する。**
「ユーザが実際に見るファイル」を見る点は魅力的だが、両システムの CI ごとに
home-manager の generation を丸ごと 1 つビルドする。得られる事実は評価レベルの読み返しと同じもの
(`home.sessionVariables` から生成される)を 1 段下流で見ているだけである。
なお**false ケースの「ビルドが通ること」は `hm-module`(`:218`)が既に賄っている** ——
同じ `basic-config` フィクスチャで、`defaultEditor` が既定値のまま activation package を作っている。
費用対効果で却下する。

**(C) `makeEnv` に `defaultEditor` を通し、`env` の出力に足す。**
`makeEnv` は wrapper を作る関数であり、`home.sessionVariables` は wrapper の外側である。
通しても使い道が無く、`programs.nvimx.env` を直接与えるエスケープハッチ利用者
(`nix/home-manager/default.nix:266-276`)にとっては**むしろ有害**になる ——
`env` を自前で組んだ人が `defaultEditor` を失う(§4.2)。`makeEnv` の formals と出力は変更しない。

**(D) `programs.neovim` との衝突を assertion で禁止する。**
§4.3 のとおり、実際に起きることは home-manager の module system が決めており、
`programs.vim` / `programs.helix` とは**衝突したオプション名と相手のモジュールファイルを挙げた
評価エラー**が出る。足さない。

**この却下の根拠は当初の想定より弱いことを記録しておく。** エラーが名指しするのは
`home.sessionVariables.EDITOR` と相手のファイルだけで、**nvimx 側は `<unknown-file>` としか出ない**
(§4.3 で実測、実装済みの `homeModules.nvimx` でも同じ)。つまりユーザには
「どのオプションで衝突したか」は伝わるが「もう一方が nvimx である」ことは伝わらない。
それでも assertion を足さないのは、(a) 同じことが任意の 2 つのエディタモジュールのあいだで起き、
nvimx だけが特別扱いされる理由が無い、(b) `programs.neovim` との併用は**そもそもエラーにならない**
ので、assertion が救いたい本当のケースは衝突しない方である —— そちらを禁止するには
「他のエディタモジュールが有効かどうか」をモジュール横断で覗く必要があり、
`programs.nvimx` が持つべき知識ではない、の 2 点による。

**(E) `contested` の control を 4 つ目のモジュール評価(`agreeing = competing "nvim"`)にする。**
「同値の定義はマージされること」を見る形で、打ち間違い穴は確かに塞がる。**実装して計測したうえで
却下した** —— §3.4 の比較表のとおり、probe + `onArgs` 共有と比べて
(a) 評価が 1 回多く degraded trace が 1 本増え、
(b) (g) store path を `on.EDITOR` と二重に拾うので **`on.EDITOR` が重複に変わり、代替不能な assert が
6 本から 5 本に減る**、という 2 点で劣る。

**「塞ぐ穴は同じ」と言えるのは `onArgs` 共有まで入れた場合だけである。** レビュー 9 回目の
probe 単独版には穴が残っていた —— probe が見るのは `competingModule` だけで、
`competing` が自分で渡していた `nvimx.defaultEditor = true;` は見ないので、
**そこを打ち間違えると正しい実装でも `mkDefault` 退行版でも緑になった**(実測)。
`agreeing` 版はその状態でも赤くなる。10 回目でその引数を `on` と共有し(§3.4 の 2)、
同じ打ち間違いが `on` の instantiation ごと落ちるようにして初めて等価になった。
**穴を残したまま「同じ」と書きかけた**ので、経緯ごとここに残す。

**失うのは「同値なら黙ってマージされる」の pin だけ**である —— §3.1 の description・
§4.3 の 4 行目・R1 が約束している挙動だが、それは **home-manager 側のマージ規則**であって
nvimx の挙動ではなく、§3.4 の (b) が「固定してしまうこと」をコストとして挙げているものでもある。
**その pin が無いことは R7 にリスクとして記録した。**

## 4. 既存機能との関係

### 4.1 `makeEnv` / `wrapper.nix` を一切通らない —— 本件だけの性質

`programs.nvimx` の他のオプションは、`enable` / `configDir` / `manageConfig` / `lock.*` / `env` を除き
**全部 `makeEnv` の引数になる**(`nix/home-manager/default.nix:313-328` の `inherit (cfg) ...`)。
`defaultEditor` はそこに入らない。帰結:

- `nix/lib/make-env.nix` と `nix/lib/wrapper.nix` は**1 バイトも変わらない**。
- したがって #26 / #27 が繰り返し警告した罠 ——
  「`makeEnv` の formals は既定値付きなので、`inherit (cfg)` から落としても黙って既定値になる」
  (`docs/plans/26-dev-plugins.md` §3.4、`docs/plans/27-extra-lua-packages.md` §4.2)——
  は**本件には当てはまらない**。落としようのある引数が無い。
- 代わりに固有の罠がある: **`config` の 1 行は消しても誰も文句を言わない**(§1.4)。
  監視対象が `makeEnv` の引数リストから `config` の attribute に移っただけで、
  「評価器が守ってくれない」という構図そのものは同じである。
- `env.wrapped` のハッシュは変わらない。**wrapper を含む既存 check の再ビルドは 1 件も起きない**
  (#27 が `postBuild` の文字列を変えたため全再ビルドになったのとは対照的である)。

### 4.2 `programs.nvimx.env` エスケープハッチとの関係

`env`(`:266-276`)を直接与えるユーザは `makeEnv` を迂回するが、`defaultEditor` は `env` から
導出されないので**そのまま効く**。§3.5(C) を却下した実質的な理由でもある。

### 4.3 `EDITOR` を設定する他の定義との衝突(実測)

**節名が「他のエディタモジュール」でないのは意図的である** —— 5 行のうち 2 行、しかも本節自身が
「いちばん起こりやすい」と呼ぶケースは、モジュールではなく**手書きの
`home.sessionVariables.EDITOR` 行**だからである。§7 R1 も同じ理由で同じ名前にしてある。

`home.sessionVariables` の型は `lazyAttrsOf (nullOr (oneOf [ str path int float bool ]))`
(`modules/home-environment.nix:289-301`)。キーごとに `str` としてマージされるので、
**同じキーに同じ値なら通り、違う値なら評価エラーになる**。計画作成時に実測:

| 併用 | 結果 |
|---|---|
| `programs.vim = { enable = true; defaultEditor = true; };`(`EDITOR = "vim"`) | **評価エラー**(本体は下に逐語)。`VISUAL = "vim"` の方は nvimx と競合しないので普通に入る |
| `programs.helix = { enable = true; defaultEditor = true; };`(`EDITOR = "hx"`) | **評価エラー。実測済み。** 文面は同一で、末尾が `.../modules/programs/helix.nix': "hx"` になるだけ。`VISUAL = "hx"` は入る |
| `programs.neovim = { enable = true; defaultEditor = true; };`(`EDITOR = "nvim"`) | **通る。** 結果は `{ EDITOR = "nvim"; VISUAL = "nvim"; LOCALE_ARCHIVE_2_27 = ...; }` —— `EDITOR` は同値なのでマージされ、`VISUAL` は `programs.neovim` 側から入る |
| **手書きの `home.sessionVariables.EDITOR = "nvim";`** | **通る。** 同値なのでマージされ、結果は `{ EDITOR = "nvim"; LOCALE_ARCHIVE_2_27 = ...; }` |
| **手書きの `home.sessionVariables.EDITOR = "vim";`**(値が何であれ `"nvim"` 以外) | **評価エラー。** しかも**両辺とも `<unknown-file>`** になり、**ファイルが 1 つも名指しされない**(下に逐語) |

**上 3 行の `enable = true;` は省略できない。** 3 モジュールとも `home.sessionVariables` を
`config = mkIf cfg.enable { ... }` の中に置いている(`vim.nix:189` の `lib.mkIf cfg.enable`
→ `:215`、`helix.nix:208` → `:250`、`neovim/default.nix:451` → `:569`)ので、
**`defaultEditor = true` だけを書いても何も起きない**。実測: `programs.vim.defaultEditor = true;`
のみを足すと衝突は起きず `EDITOR = "nvim"` のまま通る(helix / neovim も同じ)。
3 行とも `enable` 込みで測り直してある —— **§6.5 の手動確認手順もこの形で書くこと**、
さもないと「エラーが出ないこと」を確認して通してしまう。

**最後の行が本件でいちばん起こりやすい衝突である。** issue 本文の出発点そのもの ——
「nvimx に移ってきた人は `home.sessionVariables.EDITOR` を手書きしている」—— なので、
`defaultEditor = true` を足した瞬間に踏むのはエディタモジュールの併用ではなくこちらである。
実測(`programs.nvimx.defaultEditor = true` + 同じ flake の inline module に手書き行):

```
[... stack trace ...]
error: The option `home.sessionVariables.EDITOR' has conflicting definition values:
- In `<unknown-file>': "vim"
- In `<unknown-file>': "nvim"
Use `lib.mkForce value` or `lib.mkDefault value` to change the priority on any of these definitions.
```

`programs.vim` の場合(下)は少なくとも相手のファイルが出るが、**手書き行が flake の
`modules = [ ... ]` に直接書かれている**(最も普通の形)と、その定義にもファイルが無いので
**両辺が `<unknown-file>` になる**。§3.5(D) が「当初想定より悪い側の事実」と呼んだものの、さらに悪い版である。
対処は「手書き行を消す」であり、それをオプションの `description`(§3.1)に明記してある。

評価エラーの**メッセージ本体**(`programs.vim` の場合。**実装済みのモジュールを当てた状態で実測したもの**
であり、テスト用の素の `{ home.sessionVariables.EDITOR = ...; }` で代用した結果ではない)。
実際の stderr はこの前に degraded モードの warning trace と、`lib/modules.nix:1312` /
`lib/types.nix:1685` を指す 15 行ほどのスタックトレースが出る —— それを `[... stack trace ...]` で
省略してある。以下の 4 行は逐語である:

```
[... stack trace ...]
error: The option `home.sessionVariables.EDITOR' has conflicting definition values:
- In `<unknown-file>': "nvim"
- In `/nix/store/fm93mv69y0ify036r6zgnhqy1chw3vd0-source/modules/programs/vim.nix': "vim"
Use `lib.mkForce value` or `lib.mkDefault value` to change the priority on any of these definitions.
```

**パスが付くのは home-manager 側だけで、nvimx 側は `<unknown-file>` である。**
これはテスト環境の都合ではない —— `homeModules.nvimx`(`flake.nix:77`)は
`import ./nix/home-manager { lazyNvimSeed = lazy-nvim; }` すなわち**部分適用された関数**であり、
module system が受け取るのはパスではなく関数値なので `_file` が付かない。実ユーザも同じ文面を見る。
この事実が §3.5(D) の却下根拠を弱める(そちらに記録済み)。

**skeleton 段階の想定(「`programs.neovim.defaultEditor` と併用すると `EDITOR` で衝突して評価が落ちる」)は
誤りである。**落ちるのは値が食い違う `programs.vim` / `programs.helix` の方で、`programs.neovim` とは
黙って共存する。§7 R1 にリスクとして記録する。

いずれにせよ **assertion は足さない**(§3.5(D))。

### 4.4 `packages.demo` は無関係

`demo`(`flake.nix:93-114`)は `nvimxLib.makeEnv` を直接呼んでおり(`:95-98`)、
`homeModules.nvimx` を経由しない。`defaultEditor` は demo に到達しようがない。
§8 で `nix build .#demo` を回さない根拠である。

## 5. 実装手順

行番号は現在の作業ツリー基準。**行番号の大きい順に当てるか、シンボルで位置決めすること。**

### 5.1 `nix/home-manager/default.nix`(2 箇所)

**下から当てること。** §3.1 のブロックは **26 行**で、そこに本節が要求する後続の空行 1 行を足すと
**編集 1 は 27 行増やす**。したがって編集 2 以降の行番号はすべて **+27** ずれる
(逐語で当てた場合、`home.packages` は `:330` → `:357` に動く。実測で確認済み)。

**編集 1: オプション宣言。** `viAlias` の終端 `};`(`:86`)の直後、空行(`:87`)を挟んで
`extraPackages = lib.mkOption {`(`:88`)の直前に、§3.1 のブロックをそのまま挿入する
(ブロックの後にも空行を 1 行入れ、`extraPackages` との間隔を既存と揃えること)。

**編集 2: `config` 側の配線。** `home.packages` の行(**編集前の `:330`**)の**直後の行として**挿入する
—— 既存の空行(編集前の `:331`)はそのまま `xdg.configFile`(編集前の `:332`)との境として残す。
§3.2 が言う「`home.*` の 2 つを隣に置く」形はこちらである:

```nix
    home.sessionVariables = lib.mkIf cfg.defaultEditor { EDITOR = "nvim"; };
```

**`env` の description(`:269-275`)は変更しない。** `makeEnv` の出力は増えない(§4.1)。
**warnings(`:287-311`)も増やさない。** `bool` なので誤字も未知の名前も存在しない。
**`makeEnv` への `inherit (cfg)`(`:315-326`)にも足さない**(§3.5(C))。

### 5.2 `flake.nix`(新 check 1 件)

`hm-module-lua-packages` の終端 `};`(`:275`)の直後、`# vimAlias / viAlias` のコメント(`:276`)の
直前に挿入する(§3.4)。

以下は **nixfmt 正規形をそのまま貼ったもの**である —— 実際に `flake.nix:275` の直後へ挿入して
pinned nixpkgs の `nixfmt` を掛け、差分ゼロになることを確認済みなので、逐語で書き写せば
§8 手順 1 の `nix fmt -- --ci` がそのまま通る。特に `failures` の各 `lib.optional` は
条件を `(\n … \n)` に収める形が正規形であり、短くまとめ直すと nixfmt に戻される。
**例外は 2 本目の `off ? EDITOR` と 6 本目の `contested.success` の 2 つだけ**で、
こちらは条件が短いため 1 行に収まるのが正規形である —— 揃えようとして展開しないこと。
**逆向きの拘束もある**: `competing` の束縛は `value:` と本体を **3 行**に割る形が正規形で、
**1 行にまとめると nixfmt に戻される**(実測)。
`onArgs` も `{ nvimx.defaultEditor = true; }` を **3 行**に開いた形が正規形である。
一方 **`competingModule` には拘束が無い** —— 1 行のままでも、
`value: {\n  home.sessionVariables.EDITOR = value;\n};` と開いても
**どちらも nixfmt の不動点であり `nix fmt -- --ci` は通る**(実測)。
下のスニペットが 1 行にしてあるのは読みやすさの選択であって、nixfmt の要求ではない。

```nix
          # defaultEditor (#67) deploys through home.sessionVariables -- a fourth surface next to
          # home.packages, xdg.configFile and xdg.dataFile. None of the four has ever had a check
          # read it back, so this is the first one guarded, not the last one still missing
          # (measured: deleting home.packages, the xdg.configFile block or the xdg.dataFile line
          # leaves hm-module and hm-module-degrade green too). defaultEditor is not a makeEnv
          # argument either, so neither nix/lib/make-env.nix nor nix/lib/wrapper.nix can carry a
          # regression for it, and mkHmCheck is no use: it returns an activationPackage and asserts
          # nothing about it, so deleting the home.sessionVariables line from
          # nix/home-manager/default.nix leaves every hm-module-* check above green. This one reads
          # .config.home.sessionVariables back at evaluation level instead, the shape
          # checks.dev-plugins' moduleDevDirs and checks.extra-lua-packages' moduleWrapped already
          # use. Degraded lockDir on purpose -- but not to avoid a fetch: nothing is fetchTree'd
          # either way here, since neither env.wrapped nor env.farm is forced. The point is that a
          # check of a lock-independent option has no business reading basic-config's real lock.
          # The three extra degraded-mode traces in nix flake check output are the price.
          hm-module-default-editor =
            let
              inherit (pkgs) lib;
              # args.nvimx goes into programs.nvimx; args.modules are extra home-manager modules,
              # which only `competing` below needs. Bound as the whole evaluation rather than as
              # .config directly, so that the off case can also read .options out of the same fixed
              # point -- projecting both costs no extra evaluation.
              evalHm =
                args:
                home-manager.lib.homeManagerConfiguration {
                  inherit pkgs;
                  modules = [
                    self.homeModules.nvimx
                    {
                      # The three home.* settings homeManagerConfiguration requires, same values
                      # mkHmCheck uses. Only .config and .options are read; nothing is built.
                      home.username = "nvimx-test";
                      home.homeDirectory = "/home/nvimx-test";
                      home.stateVersion = "25.05";
                      programs.nvimx = {
                        enable = true;
                        configDir = ./tests/fixtures/basic-config;
                        lockDir = ./tests/fixtures/basic-config/no-such-lock;
                      }
                      // (args.nvimx or { });
                    }
                  ]
                  ++ (args.modules or [ ]);
                };
              sessionVariables = args: (evalHm args).config.home.sessionVariables;
              # The module is evaluated three times. `on` / `off` are the pair: one evaluation
              # cannot tell "sets EDITOR when asked" from "sets EDITOR always". Both halves outlive
              # the assertions that name them -- the exhaustive assertion below compares one against
              # the other, so `off` is still required even though the assertion that mentions it by
              # name is not. onArgs is shared with `competing` below rather than repeated, so that a
              # typo in it cannot leave `competing` silently evaluating something else: it makes
              # `on` itself fail to instantiate, which no assertion could paper over.
              onArgs = {
                nvimx.defaultEditor = true;
              };
              on = sessionVariables onArgs;
              offEval = evalHm { };
              off = offEval.config.home.sessionVariables;
              # The outside module, hoisted into a named function so that the assertion below can
              # look at it directly rather than only through an evaluation.
              competingModule = value: { home.sessionVariables.EDITOR = value; };
              # One more evaluation, with somebody else defining the same variable -- the shape a
              # user moving to nvimx is actually in, since the hand-written
              # home.sessionVariables.EDITOR line is what this option replaces.
              competing =
                value:
                builtins.tryEval (sessionVariables (onArgs // { modules = [ (competingModule value) ]; })).EDITOR;
              # An unequal definition. The module system refuses two unequal definitions of the
              # variable, so the correct implementation makes this throw. It is the only thing here
              # that can see which way nvimx yields: lib.mkDefault would let the other definition
              # win and lib.mkForce would silently beat it, and neither shows up in `on` or `off`,
              # where nothing competes. tryEval the way checks.plugins-escape-hatch does.
              contested = competing "vim";
              # Six of these seven are load-bearing, each against a regression none of the others
              # sees -- established by deleting each in turn against that regression, not by
              # reading the expressions. In source order: the first is the only one that notices
              # the value ceasing to be the bare "nvim" (a store path, say); the third the only one
              # that notices the declared default ceasing to be false, which every behavioural
              # assertion here misses once `off` is handed an explicit value; the fourth the only
              # one that notices a VISUAL set unconditionally, which cancels out of the fifth's
              # difference; the fifth the only one that notices some other variable being added;
              # the sixth the only one that notices mkDefault or mkForce; and the seventh the only
              # one that notices this check quietly ceasing to test anything. Only `off ? EDITOR`
              # is a duplicate, and it is kept for the sake of its message.
              failures =
                lib.optional (
                  (on.EDITOR or null) != "nvim"
                ) "defaultEditor = true must set home.sessionVariables.EDITOR to nvim"
                # The negative half. `off ? EDITOR` rather than `off == { }`: home-manager puts
                # things in this attrset on its own (LOCALE_ARCHIVE_2_27 on linux, TERMINFO_DIRS on
                # darwin), so an empty comparison would fail on both systems for reasons unrelated
                # to nvimx. This is the one assertion here that another subsumes; it stays so the
                # failure names what broke. Removing it would not remove the `off` evaluation.
                ++ lib.optional (off ? EDITOR) "the default must leave home.sessionVariables.EDITOR alone"
                # The declared default, read out of the same evaluation `off` comes from. Everything
                # else here observes behaviour, which only tells the truth about the default while
                # `off`'s argument stays empty: hand it `{ nvimx.defaultEditor = false; }` -- a
                # tempting symmetry with `on` -- and a module shipping `default = true` passes them
                # all (measured). This one reads the declaration instead, so the two arguments are
                # equivalent and the invariant is structural rather than a comment nobody reads.
                ++ lib.optional (
                  offEval.options.programs.nvimx.defaultEditor.default != false
                ) "defaultEditor must be declared with default = false"
                # EDITOR only. home-manager's own programs.neovim.defaultEditor sets VISUAL too
                # (modules/programs/neovim/default.nix:569-572). This looks redundant next to the
                # next assertion and is not: a VISUAL set unconditionally lands in off as well, so
                # it cancels out of the removeAttrs difference and nothing else here sees it.
                # Deleting this line lets exactly that regression build green (measured).
                ++ lib.optional (
                  on ? VISUAL
                ) "defaultEditor must set EDITOR only -- VISUAL is deliberately left alone"
                # The same statement without naming a variable, so that a variable nobody thought
                # to assert on is caught too, and so it keeps holding whatever home-manager starts
                # putting in this attrset. It subsumes `off ? EDITOR` above -- and only that one.
                ++ lib.optional (
                  builtins.removeAttrs on [ "EDITOR" ] != off
                ) "defaultEditor must add EDITOR and change nothing else in home.sessionVariables"
                # A conflict has to stay a conflict. Silently picking a winner is worse either way:
                # mkDefault makes an option the user just enabled do nothing, and mkForce swallows a
                # line they meant to keep. The cure for the collision is deleting the other
                # definition, which is what the option's description says.
                ++ lib.optional contested.success "a competing home.sessionVariables.EDITOR must stay a conflict -- neither mkDefault nor mkForce"
                # And the control. tryEval reports *any* exception as success = false, so the
                # assertion above is satisfied by a competing module that throws for an unrelated
                # reason -- a typo in the option path, or an extra attribute that throws before the
                # conflict does -- and would then pass while testing nothing. Looking at the module
                # itself, with no evaluation at all, is what makes this a control. Comparing the
                # *whole* module rather than one path inside it is what makes it complete: a path
                # typo fails either way, but an extra attribute that throws for its own reason
                # passes a one-path comparison (measured).
                ++ lib.optional (
                  competingModule "vim" != { home.sessionVariables.EDITOR = "vim"; }
                ) "the competing module must define home.sessionVariables.EDITOR and nothing else";
            in
            pkgs.runCommand "hm-module-default-editor" { } (
              if failures == [ ] then
                "touch $out"
              else
                ''
                  ${lib.concatMapStringsSep "\n" (f: "echo ${lib.escapeShellArg f} >&2") failures}
                  exit 1
                ''
            );
```

**注意点 8 つ:**

- `sessionVariables` は **`args:` を 1 つ取る関数**である(分配パターンではない)。
  `args.nvimx`(省略時 `{ }`)が `programs.nvimx` に `//` され、
  `args.modules`(省略時 `[ ]`)が `modules` リストに `++` される。
  **`modules` を使うのは `competing` だけ** —— 外から競合する定義を置くためである。
  `on` / `off` は渡さないので、その 2 つは今までどおりモジュール 2 つだけで評価される。
- **外部モジュールは `competingModule` として括り出し、`competing` からも 7 本目の assert からも
  それを参照すること。** インラインに書くと、assert が見るモジュールと評価が使うモジュールが
  別物になり、**control が control でなくなる** —— 実測で確認済み: 別々に書いた版では、
  評価側だけを `home.sessionVariablesTypo` に変えても check は緑のままだった。
  共有にすると 7 本目が赤くなる(§3.4 / §6.2(c))。
- **7 本目はモジュール全体を比較すること** ——
  `competingModule "vim" != { home.sessionVariables.EDITOR = "vim"; }` である。
  `(competingModule "vim").home.sessionVariables.EDITOR != "vim"` のように**1 パスだけ**を見る形に
  「簡単にする」と、**属性を足して別の理由で throw させる腐敗が素通りする** ——
  実測: `home.stateVersion = "24.11";` を足すと `mkDefault` 退行込みで check が緑になった
  (未宣言オプションでも同じ)。全体比較なら 3 種とも赤になる(§6.2(c))。
- **`nvimx` 側の引数も `onArgs` として括り出し、`on` と `competing` で共有すること。**
  これも冗長に見えて control の一部である —— `competing` に引数を直接書くと、
  そこを打ち間違えたときに `tryEval` が「オプションが存在しない」例外を掴み、
  **`mkDefault` に退行した実装でも check が緑になる**(実測)。
  共有していれば同じ打ち間違いは `on` の instantiation ごと落ちるので、覆い隠しようがない。
  **「同じ値を 2 度書いているだけ」と見て解かないこと**(§3.4 の 2、§6.2(c) の最終行、R7)。
- **`off` は `offEval` 経由で束縛し、`options` も同じ評価から読むこと。**
  `offEval = evalHm { };` / `off = offEval.config.home.sessionVariables;` の 2 行である。
  3 本目の assert が `offEval.options.programs.nvimx.defaultEditor.default` を読むので、
  `off` だけを `sessionVariables { }` で取り直すと**その assert が書けなくなる**。
  `homeManagerConfiguration` は `config` と `options` を同じ固定点から返すので、
  こう束ねても**評価は増えない**(実測: 3 回のまま、drv ハッシュも同一)。
  引数を `{ }` にしてあるのは読みやすさの選択であって、もはや規約ではない ——
  明示の `false` を書いても 3 本目が宣言側を見ている(§3.4、§6.2(c)、§8 手順 5 の (k))。
- `competing` は `builtins.tryEval (...).EDITOR` である。**`.EDITOR` を落とすと assert が空振りする**
  —— attrset 自体は WHNF まで評価しても衝突に到達しないので `success = true` になり、
  `contested` の assert が常に赤になる(= 正しい実装で落ちる)。文字列まで強制することが要点である。
  `checks.plugins-escape-hatch` が `builtins.seq ... null` で同じことをしている。
- **`nativeBuildInputs` は空でよい。** ビルドフェーズは `touch $out` だけである。
- `inherit (pkgs) lib;` はこの check のローカルな `let` に置く。`extra-lua-packages`(`:298`)と
  `dev-plugins`(`:3502`)が同じことをしている。

### 5.3 `README.md`

`## Options` 表の `viAlias` の行(`:209`)と `extraPackages` の行(`:210`)の**あいだ**に 1 行。
**位置は §5.1 編集 1 のモジュール側と必ず揃えること**(§1.3):

```
| `defaultEditor` | `bool` | `false` | Set `EDITOR` to `nvim` in `home.sessionVariables`. `EDITOR` only — unlike home-manager's own `programs.neovim.defaultEditor`, `VISUAL` is left alone — and the value is the bare command name, resolved through the `PATH` that `home.packages` already provides. |
```

**他の README 編集はしない。判断の記録:**

- **散文の節は作らない。** `### Local plugin development` / `### Lua rocks` / `### Tree-sitter grammars`
  (`:374` / `:416` / `:337`)が節を持っているのは、どれも「意図的な trade-off」や
  「lazy.nvim の挙動との関係」を説明する必要があるからである。本件にはそれが無い ——
  bool 1 個で、効果は変数 1 個である。表のセルで言い切れる分量を節に膨らませない。
- **`## Installation` のサンプル(`:53-64`)には足さない。** あのブロックは
  `enable` / `configDir` / `lockDir` / `lock.*` だけの最小形で、`vimAlias` すら無い。
- **他のエディタモジュールとの衝突は README に書かない**(§4.3 / §7 R1)。これは
  「**書かなくても十分伝わる**」からではない —— 実際のエラーは
  `home.sessionVariables.EDITOR` と**相手のモジュールファイルだけ**を名指しし、
  nvimx 側は `<unknown-file>` としか出ない(§4.3 の実測)。書かない理由は、
  (a) 起きるのは 3 モジュールのどの 2 つを組み合わせても同じことで README が nvimx 固有の話として
  書ける内容が無い、(b) 本当に注意が要る `programs.neovim` との併用は**エラーにすらならない**ので
  「衝突する」という書き方自体が誤りになる、の 2 点である。
  **オプションの `description`(§3.1)には 1 段落だけ残す** —— そちらは
  「このオプションを引こうとしている人」が読む場所であり、2 つのケースを書き分けられる。

### 5.4 `docs/architecture.md`(2 箇所)

**下から当てること。** 編集 1 が 1 行足すので、編集 2 の行番号は +1 ずれる。

**編集 1: `:174` の直後。** build 時フローの `[6] hm deployment:`(`:173-177`)は
**モジュールが deploy するものを列挙している唯一の箇所**であり、本件はそこに 4 つ目を足す変更である
(§1.1)。列挙している以上は正しく列挙する —— `#27` が `:171` の wrapper 行に環境変数を足したのと
同じ判断である。`:175` の括弧書きが 52 桁目から始まっているので、それに揃える(空白 8 個):

before(`:174-175`):
```
      home.packages = [ wrapped-nvim, nvimx-lock ]
      xdg.configFile."nvim" = configDir            (when manageConfig = true)
```
after:
```
      home.packages = [ wrapped-nvim, nvimx-lock ]
      home.sessionVariables.EDITOR = "nvim"        (when defaultEditor = true)
      xdg.configFile."nvim" = configDir            (when manageConfig = true)
```

**編集 2: `:516` の checks 列挙。** `hm-module-lua-packages,` の直後に `hm-module-default-editor,` を
挿入する。`hm-module-*` が連続している並びを保つためであり、`flake.nix` 側の挿入位置(§5.2)と一致する:

before(該当部分):
```
..., hm-module-dev, hm-module-lua-packages, plugins-overrides, ...
```
after:
```
..., hm-module-dev, hm-module-lua-packages, hm-module-default-editor, plugins-overrides, ...
```

**他の architecture.md 編集はしない。判断の記録:**

- **`programs.nvimx = { ... }` のサンプル(`:400-432`)には足さない。** あのブロックは
  representative であって exhaustive ではなく、**`vimAlias` / `viAlias` を既に省いている** ——
  本件と完全に同型の「wrapper の外側に 1 個足す bool」2 件である。
  `defaultEditor` だけを載せると、省かれている隣人 2 つとの対比で
  「この一覧は全オプションだ」という誤った印象を与える。網羅的な一覧は README の表(§5.3)であり、
  そちらには入る。
- **mermaid の `:108-109` には足さない。** 該当は 2 行 2 辺である(`K` のラベル内だけ `...` で省略):

  ```
  108     J --> K["wrapProgram neovim<br/>--cmd luafile<br/>PATH / ..."]
  109     K --> M["deployed via home.packages"]
  ```

  これは**wrapper derivation が利用者に届くまでの経路**を描いた図である。
  `home.sessionVariables` は wrapper が通る経路ではないので、ノードを足すと図の主語が変わる。
  `#27` が `:108` を編集したのは wrapper 自身が環境変数を持つようになったからで、本件は違う。
- **設計原則(`:112-122`)** —— `4.` は runtime injection(`--cmd luafile` / `package.preload`)の話で、
  `EDITOR` は neovim の中に何も注入しない。無変更。
- **edge cases 表(`:521-538`)** —— 制限でも edge case でもない。無変更。
- **Implementation phases の `:550`** —— `7. **Finishing touches**: devPlugins (#26),
  extraLuaPackages (#27), non-GitHub validation, `checks.e2e-offline`, README` の行。
  `#26` と `#27` はどちらもこの行を編集したが(自分の名前が**既に予告として載っていた**ので
  issue 番号を付けて実装済みに変えた)、**`defaultEditor` はこの行に最初から載っていない**。
  phase 7 の予告リストは当時の見込みであって網羅リストではないので、**後から名前を足さない** ——
  足すと「予告されていた項目の消化」と「後から出た issue」の区別が消える。無変更。

### 5.5 `templates/default/flake.nix`

`# vimAlias = true;` の行(`:47`)の直後に 1 行:

```nix
              # defaultEditor = true;  # export EDITOR=nvim
```

**足すという判断の根拠。これは前例の 2 件のうち片方からの意識的な逸脱である。**
先行する 2 件はどちらもテンプレートを触らなかったが、**書いてある理由は同じではない**:

- `docs/plans/26-dev-plugins.md` §5.10 —— 「dev 開発は『テンプレートから始めた直後』の話題ではない」。
  **話題の時期**を基準にしている。
- `docs/plans/27-extra-lua-packages.md:953`(§4.8)—— 「コメントに `extraPackages` の例があるが、
  **テンプレートは最小構成に保つ方針なので** rock の例は足さない」。
  こちらは**内容によらない方針**であり、文字どおり適用すれば `defaultEditor` も除外される。

したがって本件は `#26` の基準を踏襲し、`#27` の書いた方針からは外れる。**外れる根拠**:

- **`vimAlias` との隣接。** テンプレートに既に載っている `# vimAlias = true;`(`:47`)と
  `defaultEditor` は同じカテゴリである —— どちらも 1 行の bool で、
  「この neovim を普段使いにする」ための配線であり、どちらも初日に効く。
  `#27` の「最小構成」を厳密に適用するなら `vimAlias` の行も無いはずで、**現に在る**以上、
  この方針は「1 行 bool の常用設定」までは除外していないと読むのが実態に合う。
- **issue の動機そのもの。** issue 本文は「anyone moving to nvimx has to write the
  `home.sessionVariables.EDITOR` line by hand」を出発点にしている。その手書きを省かせるのが本件なのに、
  ユーザが最初に手を入れるファイルで黙っているのは一貫しない。
- `devPlugins` / `extraLuaPackages` にこの議論が当てはまらないのは、どちらも
  「使っていて必要になったら調べる」設定だからである。**2 件の前例を否定するものではない。**

コメントのスタイルは `:45` の `# extraPackages = [ pkgs.ripgrep ];` / `:47` の
`# vimAlias = true;  # if you also want to launch it with \`vim\`` に揃える。

### 5.6 触らないもの

- **`nix/lib/**` 一式(11 ファイル全部)**(`default.nix` / `make-env.nix` / `wrapper.nix` /
  `bootstrap.nix` / `farm.nix` / `sources.nix` / `plugin-drv.nix` / `resolve-plugin.nix` /
  `treesitter.nix` / `build-network.nix` / `lock-app.nix`。`ls nix/lib/` と件数が一致する)——
  `defaultEditor` は `makeEnv` を通らない(§4.1)。**`lib.makeEnv` の formals も出力も 1 バイトも変えない。**
- **`nix/build-registry/` 一式** —— プラグインのビルド手順の登録簿であり、
  `home.sessionVariables` とは一切交わらない。`#27` §4.8 も同じ理由でここに挙げている。
- **`lua/**` 一式** —— lock 生成には何の関係も無い。`nvimx-lock` の出力は不変。
- **`tests/fixtures/**`** —— **新規フィクスチャは 1 つも要らない。** 既存の `basic-config` と、
  その存在しない `no-such-lock` だけで足りる。
- **`.github/workflows/**`** —— `nix flake check` の中身が 1 件増えるだけ。CLAUDE.md の規約により、
  仮にステップ追加が必要になっても編集は `check.yml` のみ。
- **`stylua.toml` / `.luacheckrc`** —— lua ファイルを 1 つも触らないので、
  `nix fmt -- --clear-cache` も不要(§8)。
- **`CLAUDE.md`**、`docs/plans/` の既存ファイル。

## 6. テスト

新設は `checks.hm-module-default-editor` 1 件のみ。

### 6.1 assert 一覧(何を守るか)

**7 本のうち 6 本が代替不能である。** 重複は `off ? EDITOR` の 1 本だけで、
メッセージのために残してある。**この内訳は式を読んで導いたものではなく、
7 本すべてについて「1 本削って、それが守るはずの改変を当てる」実験をした結果である**(§6.2(c))。
`flake.nix` のコメントにも同じ内訳を書く(§5.2)—— 特に `on ? VISUAL` については
「網羅 assert に包含されているから消してよい」と読ませないことが重要である(§3.4)。

| assert | 荷 | それだけが捕まえる退行 | メッセージ |
|---|---|---|---|
| `(on.EDITOR or null) != "nvim"` | **本体** | G1。**値が `"nvim"` でなくなる**改変。`"${cfg.env.wrapped}/bin/nvim"` に変えても他の 6 本は全部緑なので、§3.3 の narrowing 2 を守っているのはこの 1 本だけである | `defaultEditor = true must set home.sessionVariables.EDITOR to nvim` |
| `off ? EDITOR` | 重複 | **無し。** `lib.mkIf` を外した実装は `removeAttrs` が拾う。残す理由は「何が起きたか」を名指しで言うことだけ。`off == { }` ではなくキー単位で見る理由は §3.4 | `the default must leave home.sessionVariables.EDITOR alone` |
| `offEval.options.programs.nvimx.defaultEditor.default != false` | **本体** | G2 の宣言面。**宣言された既定値が `false` でなくなる**改変。挙動側の 2 本は `off` の引数が `{ }` である限りでしか既定値を見ていないので、引数に明示の `false` を書かれると両方すり抜ける(§3.4 の表)。`config` と同じ固定点の `options` を読むだけなので**評価は増えない** | `defaultEditor must be declared with default = false` |
| `on ? VISUAL` | **本体** | G3。**`VISUAL` が無条件に設定される**改変。`on` と `off` の両方に現れるので `removeAttrs` の差分から相殺され、他のどの assert にも見えない。`mkIf` の中に足された `VISUAL` の方は `removeAttrs` も拾うが、それは 2 通りあるうちの片方でしかない | `defaultEditor must set EDITOR only -- VISUAL is deliberately left alone` |
| `removeAttrs on [ "EDITOR" ] != off` | **本体** | G3 の網羅面(**`home.sessionVariables` の中に限る** —— R1)。**`VISUAL` 以外の、名指しの assert を書きようがない変数**が足される改変(実測は `PAGER` で行った)。`off ? EDITOR` を包含するが、包含するのはそれだけである | `defaultEditor must add EDITOR and change nothing else in home.sessionVariables` |
| `contested.success` | **本体** | §3.2。**`lib.mkDefault` / `lib.mkForce`。** `on` / `off` には競合する定義が無く優先度が観測できないので、**どちらの改変でも他は全部緑のままである** | `a competing home.sessionVariables.EDITOR must stay a conflict -- neither mkDefault nor mkForce` |
| `competingModule` の probe | **本体** | **この check 自身の腐敗。** 外部モジュールが衝突以外の理由で落ちるようになると `contested` は黙って無効化される —— `tryEval` は理由を問わず `success = false` にするからである。**モジュール全体を期待値と比較する**ので、パスの打ち間違いでも、余計な属性の追加(`home.stateVersion` を足して衝突させる等)でも赤くなる。それを見るのはこの 1 本だけで、モジュール側の改変では原理的に再現できない(§3.4)。**評価を 1 回も足さずに**それを見るのがこの形の眼目である(§3.5(E)) | `the competing module must define home.sessionVariables.EDITOR and nothing else` |

### 6.2 計画作成時の実測(実装者への根拠)

リポジトリを `git clone --local` でスクラッチに複製し、§5.1 と §5.2 をそのまま当てた状態で計測した。
**実装後に `checks.hm-module-default-editor` が再現する内容と同じである。**

**(a) 正しい実装では通る**

(degraded モードの warning trace を `[... trace ...]` で省略してある。R4 参照。)

```
$ nix build --no-link .#checks.x86_64-linux.hm-module-default-editor -L
[... trace ...]
building '/nix/store/68zdik9q855yd4j54p4dpb2ingmmd7vy-hm-module-default-editor.drv'...
$ echo $?
0
```

**(b) 7 通りの改変がすべて捕まる(mutation testing)**

改変はすべて §5.1 編集 2 の 1 行に対するものである。

| # | 改変 | 出る失敗メッセージ |
|---|---|---|
| (a) | 行を**削除** | `defaultEditor = true must set ... EDITOR to nvim` / `a competing ... must stay a conflict ...` |
| (b) | `lib.mkIf` を外して `home.sessionVariables = { EDITOR = "nvim"; };` | `the default must leave ... EDITOR alone` / `defaultEditor must add EDITOR and change nothing else ...` |
| (c) | `mkIf` の**中に** `VISUAL = "nvim";` を追加 | `defaultEditor must set EDITOR only -- VISUAL ...` / `defaultEditor must add EDITOR and change nothing else ...` |
| (d) | **`VISUAL` だけ無条件**:<br>`{ VISUAL = "nvim"; } // lib.optionalAttrs cfg.defaultEditor { EDITOR = "nvim"; }` | `defaultEditor must set EDITOR only -- VISUAL ...` の**1 本だけ** |
| (e) | **`EDITOR = lib.mkDefault "nvim";`** | `a competing ... must stay a conflict ...` の**1 本だけ** |
| (f) | **`EDITOR = lib.mkForce "nvim";`** | `a competing ... must stay a conflict ...` の**1 本だけ** |
| (g) | **`EDITOR = "${cfg.env.wrapped}/bin/nvim";`**(§3.3 の narrowing 2 違反) | `defaultEditor = true must set ... EDITOR to nvim` の**1 本だけ** |

**「1 本だけ」の 4 行がこの表の要点である。** (d)(e)(f)(g) はそれぞれ assert を 1 本しか赤にしない。
**当たる先は 3 本である** —— (d) → `on ? VISUAL`、**(e) と (f) はどちらも `contested`**、
(g) → `on.EDITOR`。メッセージが (e) と (f) で同一なのはそのためである。

**この 7 通りだけでは示せないものが 3 つある。** `removeAttrs`(5 本目)の代替不能性は §6.2(c) の
`PAGER` probe が、`competingModule` probe(7 本目)の代替不能性は §6.2(c) の
「競合モジュールの打ち間違い」行が、**宣言 assert(3 本目)の代替不能性は §6.2(c) の
`off` の引数の行**が示す —— **(a)-(g) はどれもオプション宣言に触れない**ので、
`default = true` という退行はこの 7 通りからは原理的に届かない。
§6.1 の「荷」列は 7 通り + この 3 つの probe から来ている。

**drv ハッシュはコメントを書き換えても動かない** —— `runCommand` の derivation が依存するのは
`name` と `buildCommand`(`touch $out`)だけで、Nix 式中のコメントは入力に入らない。
したがって**§6.2(a) の transcript に出ている** `68zdik9q…` は、§5.2 のコメント文を推敲しても、
**assert を足しても**同じ値のままである(実測: assert 4 本 / 5 本 / 6 本 / **出荷形の 7 本**のいずれでも、
また 4 評価版・3 評価版のどちらでも同一)。

**(c) 7 本の assert すべてについての削除実験 + 腐敗 probe**(§3.4 / §6.1 の「荷」列の根拠)

各行は「その assert だけを `failures` から削り、それが守るはずの改変を当てた」結果である。

| 削った assert | 当てた改変 | 結果 |
|---|---|---|
| `(on.EDITOR or null) != "nvim"` | (g) store path | **緑になってしまう** → **代替不能** |
| `(on.EDITOR or null) != "nvim"` | (a) 行を削除 | **赤のまま**(`contested` が拾う)—— (a) についてはこの assert は唯一の守り手ではない |
| `off ? EDITOR` | (b) 無条件 `EDITOR` | **赤のまま**(`removeAttrs` が拾う)→ **重複** |
| `on ? VISUAL` | (c) `mkIf` の中の `VISUAL` | **赤のまま**(`removeAttrs` が拾う) |
| `on ? VISUAL` | **(d) 無条件 `VISUAL`** | **緑になってしまう** → **代替不能** |
| `removeAttrs on [ "EDITOR" ] != off` | `mkIf` の中に `PAGER = "less";` を追加 | **緑になってしまう** → **代替不能** |
| `contested.success` | **(e) `mkDefault`** | **緑になってしまう** → **代替不能** |
| `competingModule` probe | **競合モジュールのオプション名を 1 つ打ち間違える**(`home.sessionVariables` → `home.sessionVariablesTypo`) | **緑になってしまう** → **代替不能** |
| (削らない) | 同じ打ち間違い | **赤**(`the competing module must define ... and nothing else`)—— 穴が塞がっていることの確認 |
| (削らない) | 同じ打ち間違い + `mkDefault` | **赤**(同上) |
| (削らない) | **`competingModule` に `home.stateVersion = "24.11";` を足す** + `mkDefault` | **赤**(同上)—— 1 パスだけを見る旧形では**緑だった**(§3.4 の 1) |
| (削らない) | **未宣言オプション(`bogusOptionNobodyDeclared = 1;`)を足す** + `mkDefault` | **赤**(同上)—— 同じく旧形では緑 |
| (削らない) | `competingModule` の値を `"nvim"` に固定する | **赤 2 本**(`contested` と probe)—— 競合しなくなるので両方が気づく |
| (削らない) | `modules = [ ]`(競合モジュールを渡し忘れる) | **赤**(`a competing ... must stay a conflict ...`)—— 配線の腐敗は `contested` 側が拾う |
| (削らない) | **`onArgs` の `nvimx.defaultEditor` を打ち間違える**(`defaultEditorTypo`) | **評価ごとエラー**(`The option 'programs.nvimx.defaultEditorTypo' does not exist`)—— `on` が instantiation で落ちるので assert では覆い隠せない |
| (削らない) | 同上 + `mkDefault` | **同じ評価エラー** |
| **`onArgs` の共有をやめ、`competing` 側に引数を書き直す** | 同じ打ち間違い(`competing` 側だけ) | **緑になってしまう** —— `tryEval` が「オプションが無い」例外を掴み、`mkDefault` 退行込みで通る。§3.4 の 2 が塞いでいるのはこれである |
| `offEval.options…default` | **`off` に明示の `false` を渡す** + `default` を `true` に変える | **緑になってしまう** → **代替不能**(この assert を消すと、`off` の引数を書き換える整形がそのまま既定値の検査を殺す) |
| (削らない) | **`off` に明示の `false` を渡す**(`off = (evalHm { nvimx.defaultEditor = false; }).config…`)+ `default` を `true` に変える | **赤 1 本**(`defaultEditor must be declared with default = false`)—— 挙動側の 2 本はすり抜ける |
| (削らない) | 現行のまま `default` を `true` に変える | **赤 3 本**(`the default must leave ...` / `defaultEditor must be declared ...` / `defaultEditor must add EDITOR and change nothing else ...`) |
| (削らない) | **基底 attrset に `defaultEditor = false;` を足す** + `default` を `true` に変える | **赤 1 本**(同じく宣言 assert のみ)—— 上と同じ穴の別の開け方 |

**4 行目と 5 行目が対になっているのが本節の要点である。** `on ? VISUAL` は
**`VISUAL` 退行のうち片方(条件付き)については確かに重複しているが、もう片方(無条件)については
唯一の守り手である**。片方だけを見て「重複」と結論したのが本計画のレビュー 2 回目までの誤りであり、
危うく `flake.nix` のコメントに「消してよい」と書き残すところだった(§3.4)。
**1 行目と 2 行目も同じ形をしている** —— `on.EDITOR` は (a) については代替可能だが、
(g) については唯一である。
(レビュー 8 回目の 4 評価版では `agreeing` が (g) も拾ったため 1 行目が「赤のまま」になり、
`on.EDITOR` は重複に落ちていた。probe に差し替えて代替不能に戻っている —— §3.5(E)。)

**下 14 行が、本 check で最も重要な実測である。前半 10 行は `tryEval` の control、
後半 4 行は `off` の引数が既定値の唯一の守り手だった件**(3 本目の assert を足す前の状態)
**であり、由来は別である。** `tryEval` は理由を問わず例外を
`success = false` にするので、control が無いと **check は緑のまま `contested` だけが死ぬ** ——
実測では、その状態で `mkDefault` を入れた実装すら緑で通った。§8 手順 5 が
「何も検知していない状態で緑」を最大の失敗モードと呼んでいるのは、まさにこの形である。

**評価と assert に関わる腐りどころは 3 つあり、守り手も 3 つある。いずれも規約ではない。**

| 腐る場所 | 守り手 | 種別 |
|---|---|---|
| 外部モジュール `competingModule` | 7 本目の assert(**モジュール全体を比較**するので、パスの打ち間違いでも属性の追加でも形を問わない) | assert |
| `competing` に渡す nvimx 引数 | **`onArgs` の共有**(同じ打ち間違いが `on` の instantiation ごと落ちる) | 構造 |
| `off` に渡す引数 | **3 本目の assert**(`options` から宣言された `default` を直接読む) | assert |
| (参考)`failures` / `runCommand` の配線 | **無し** —— `failures = [ ];` に置き換えると check は緑のまま全 assert が死ぬ(正しい木でも `mkDefault` 退行込みでも緑。実測) | **規約のみ** |

**`if failures == [ ]` の反転は、この行に含めていない。** 実測すると**そちらは黙らない** ——
`failures` が空のまま `else` 枝に入り、空リストへの `concatMapStringsSep` のあとに `exit 1` が走るので、
**健全な木で即座に赤になる**(`builder failed with exit code 1`、メッセージ無し)。
緑になるのは退行が既に入っているときだけである。**無防備なのは `failures` を握り潰す方だけ**で、
分岐の反転は初回のビルドで自己申告する。

**「3 つ」は評価と assert の腐りどころの数であって、網羅ではない。** 最終行のとおり、
`failures` を `runCommand` に渡す配線そのものは無防備である —— ただしこれは
`dev-plugins` / `extra-lua-packages` / `treesitter-grammars` が共有する**リポジトリ共通のイディオム**で、
そちらでも同じく無防備である。本 check だけが自前の守り手を持つ理由が無いので
**assert は足さない**。足すとすればリポジトリ横断の話になる。

**3 つ目はレビュー 12 回目まで「規約のみ」だった** —— `off` の引数が `{ }` であることを
コメントと注意点で守っているだけで、`on` と対称に書き直す整形がそのまま穴になった。
13 回目に 3 本目の assert を足して構造に置き換えてある(§3.4)。表の該当 4 行がその実測であり、
`onArgs` の行と合わせて **assert と構造の両方が要ることの実測**でもある。

`PAGER` / `competingModule` の各種腐敗 / `modules = [ ]` / `onArgs` / `off` の引数、の 5 系統は
実装者が書く改変ではなく、**それぞれの守り手の担当範囲を見せるための probe** である ——
どれも「モジュールの 1 行を書き換える」形では起こらない。§6.2(b) の 7 通りには含めない。

**(d) 同じ削除で既存 check は緑のまま**(この check を足す理由そのもの)

```
$ # home.sessionVariables の行を削除した状態で
$ nix build --no-link .#checks.x86_64-linux.hm-module .#checks.x86_64-linux.hm-module-degrade
[... trace ...]
$ echo $?
0
```

`home.packages` / `xdg.configFile` / `xdg.dataFile` を消した場合も同じく exit 0 である(§1.4)。

**(e) darwin でも assert が成立する**

`failures` が非空でも `runCommand` の本文が差し替わるだけなので、**`.drvPath` の評価は常に成功する** ——
`nix eval .#checks.aarch64-darwin.<name>.drvPath` は「darwin で eval が壊れていない」ことしか言わない
(`docs/plans/26-dev-plugins.md` §6.8 が同じ注意を書いている)。
`failures` リスト方式の check については **`buildCommand` を見るのが正しい**:

```
$ nix eval --raw .#checks.aarch64-darwin.hm-module-default-editor.buildCommand
[... trace ...]
touch $out
$ nix eval --raw .#checks.x86_64-linux.hm-module-default-editor.buildCommand
[... trace ...]
touch $out
```

(ここの `[... trace ...]` は degraded モードの warning trace **3 本ぶん**(計 12 行)である ——
モジュールを 3 回評価するので 3 本出る。R4 が数えているのもこれである。)

`touch $out` が返るということは `failures == [ ]` である。**darwin でも 7 本の assert がすべて通る**
—— `home.sessionVariables` の既定内容が linux と違う(§3.4 の表)にもかかわらず通るのは、
assert がキー単位と `removeAttrs` の差分で書かれているからである。§8 手順 4 に反映する。

### 6.3 既存 checks への影響

| check | 影響 |
|---|---|
| `hm-module` / `hm-module-degrade` / `hm-module-plugins` / `hm-module-treesitter` / `hm-module-dev` / `hm-module-lua-packages`(`flake.nix:218-275`) | **無し。** `defaultEditor` の既定は `false` なので `mkIf` が発火せず、activation package は今日と同一である |
| `wrapper-aliases` / `build-shell` / `plugin-drv-phases` / `build-registry` / `build-network-detect` / `plugins-*` / `treesitter-grammars` / `dev-plugins` / `extra-lua-packages` | **無し。** `makeEnv` も `wrapper.nix` も変わらない(§4.1)ので、wrapper の drv ハッシュが動かない |
| `extractor-*` / `semver-*` / `source-parse` / `resolve-*` / `update-*` / `genflake-golden` | **無し。** lua を 1 行も触らない |
| `packages.demo` | **無し**(§4.4) |

**この 3 行で既存 33 件を網羅している。** 数は `docs/architecture.md:516` の列挙と一致する
(`flake.nix` の `checks` 直下の束縛を数えても 33 件)。`source-parse` と `build-network-detect` は
どのワイルドカードにも当たらないので個別に挙げてある —— §5.4 編集 2 でその列挙を触る以上、
こちらの表だけ 2 件足りない状態にはしない。

**#27 と違って「wrapper を含む check が一度だけ再ビルドされる」現象は起きない。**
あちらは `postBuild` の文字列を変えたので drv が動いた(`docs/plans/27-extra-lua-packages.md` §5.5)。
本件は wrapper に触らない。

### 6.4 CI / darwin

- CI は `.github/workflows/check.yml` が `nix flake check` と `nix fmt -- --ci` を回すだけなので、
  **ワークフローの変更は不要**である(CLAUDE.md の規約により、仮に必要でも編集は `check.yml` のみ)。
- 新 check のビルドコストは `touch $out` の `runCommand` 1 つ分で、
  実質すべてが評価時間である(モジュールを 3 回評価する)。`hm-module-*` ファミリの他の 6 件が
  home-manager の generation を丸ごとビルドしているのと比べれば無視できる。
- ローカル(linux)の `nix flake check` は darwin を omit するので、§8 手順 4 で別途確認する。

### 6.5 手動確認(実 dotfiles の switch が要るので check にできない)

1. 自分の dotfiles で `programs.nvimx.defaultEditor = true;` を設定して `home-manager switch`。
2. 新しいシェルを開いて `echo $EDITOR` —— `nvim` が出ること(store path ではないこと)。
3. `echo $VISUAL` —— **空である**こと(nvimx が設定していないこと)。
4. `which nvim` が nvimx の wrapper を指していること(`git commit` などが nvimx の neovim を開くこと)。
5. `defaultEditor` を外して switch —— `EDITOR` が元に戻ること。
6. `programs.vim = { enable = true; defaultEditor = true; };` を併記して switch ——
   **`home.sessionVariables.EDITOR` の conflicting definition で評価エラーになる**こと。
   **`enable = true;` を落とさないこと** —— `defaultEditor` だけでは `programs.vim` の `config` が
   `mkIf cfg.enable` で丸ごと無効なので衝突が起きず、**この手順が何も確認しないまま通る**(§4.3)。
   確認するのは**文字列の一致ではなく形**である
   (§4.3 / §7 R1):衝突しているオプションが `home.sessionVariables.EDITOR` であること、
   nvimx 側が `<unknown-file>: "nvim"` と出ること、相手側が
   `<home-manager>/modules/programs/vim.nix': "vim"` と出ること。
   **store path のハッシュは §4.3 と一致しない** —— あちらはこのリポジトリが pin している
   home-manager、手元で見るのは自分の dotfiles が pin している home-manager だからである。
7. 手書きの `home.sessionVariables.EDITOR` が残っている状態で `defaultEditor = true` にしてみる ——
   値が `"nvim"` でなければ評価エラーになり、**両辺が `<unknown-file>` でファイルが 1 つも出ない**こと
   (§4.3 / R1)。手書き行を消せば通ること。**これが実ユーザがいちばん踏みやすい形である。**

## 7. リスク / 未決事項

### R1: `EDITOR` を設定する他の定義との併用

§4.3 で実測したとおり、起きることは相手によって 3 通りに分かれる:

- **手書きの `home.sessionVariables.EDITOR`(いちばん起こりやすい)** —— issue 本文の出発点が
  「移ってきた人はこの行を手書きしている」である以上、`defaultEditor = true` を足した人が
  最初に踏むのはこれである。値が `"nvim"` なら黙ってマージされ、**それ以外なら評価エラー**になる。
  しかもその行が flake の `modules = [ ... ]` に直接書かれていると
  **両辺が `<unknown-file>` になり、ファイルが 1 つも名指しされない**(§4.3 に逐語)。
  対処は「手書き行を消す」であり、オプションの `description`(§3.1)がそう言っている。
- **`programs.vim` / `programs.helix` を `enable = true;` で有効にした場合(どちらも実測)** ——
  `EDITOR` の値が食い違うので**評価エラー**になる。**`defaultEditor = true` だけでは何も起きない** ——
  両モジュールとも `home.sessionVariables` が `config = mkIf cfg.enable` の中にあるからで、
  実際に衝突するのは「そのエディタも使っている」構成に限られる(§4.3 で実測)。
  ただし**メッセージが名指しするのは、衝突したオプション名と相手のモジュールファイルだけである**。
  nvimx 側は `<unknown-file>` としか出ない —— `homeModules.nvimx`(`flake.nix:77`)が
  部分適用された関数で、module system がパスを知らないためであり、実ユーザも同じ文面を見る
  (§4.3 にメッセージ本体。その手前にスタックトレースが 15 行ほど付く)。
  **原因が「何と何の衝突か」まで自明にはならない**というのが、当初想定より悪い側の事実である。
- **`programs.neovim` を `enable = true;` で有効にした場合** —— 値が同じ `"nvim"` なので
  **黙ってマージされる**。加えて `VISUAL = "nvim"` が `programs.neovim` 側から入る
  (こちらも `enable` が要る。`defaultEditor` だけでは `VISUAL` すら入らない —— 実測)。
  この構成は `home.packages` に **2 つの異なる neovim** を載せている状態であり、
  `EDITOR` / `VISUAL` のどちらがどの neovim に解決されるかは PATH 次第になる。

**それでも assertion は足さない**(§3.5(D) に根拠を書いた)。3 つは向きが揃っておらず、
「エラーは出るが nvimx の名前が出ない」ものと「そもそもエラーが出ない」ものが混ざっている。
前者を assertion で補うのは、任意の 2 定義のあいだで起きることを nvimx だけが肩代わりすることになり、
後者を捕まえるには他モジュールの `enable` や `home.sessionVariables` の他の定義を覗く必要がある。
**`lib.mkDefault` / `lib.mkForce` で衝突自体を回避するのも採らない** —— どちらも黙ってどちらかを
潰すことになり、評価エラーより悪い(§3.2 に実測付きで記録)。
**オプションの `description` に 1 段落だけ残し、3 つのケースを書き分ける**(§3.1)。

**未検証の点を明記しておく**: `programs.neovim` と併用したとき、
`home.packages` の 2 つの neovim がプロファイルのビルド時に衝突するかどうかは**確かめていない**。
確かめるには home-manager 自身の neovim(この pin では `withPython3` が有効)を丸ごとビルドする必要があり、
本件と無関係なコストが大きい。**本計画は `home.sessionVariables` のレベルまでしか主張しない。**

**この限定は check の主張範囲でもある。** `removeAttrs` の網羅 assert が比べているのは
`home.sessionVariables` だけなので、**同じ `lib.mkIf cfg.defaultEditor` の中に 1 行足すだけで
その外側に出られる**。実測(どちらも check は緑のまま):

| 足した 1 行 | 効果 |
|---|---|
| `home.shellAliases = lib.mkIf cfg.defaultEditor { e = "nvim"; };` | エイリアスが増える |
| `home.sessionVariablesExtra = lib.mkIf cfg.defaultEditor "export VISUAL=nvim";` | **`VISUAL=nvim` が実際に export される** |

2 行目は `modules/home-environment.nix:392` の実在のオプション(`internal = true`)で、
`:676` で `hm-session-vars.sh` に逐語で連結される —— **本 issue の看板である narrowing 1 を
真正面から破りながら、`on ? VISUAL` にも `removeAttrs` にも見えない。**

**それでも assert は足さない。** `sessionVariablesExtra` / `shellAliases` /
`programs.*.sessionVariables` と追いかけ始めると、モジュールが触りうる面をすべて列挙することになり、
この check の主題(1 つのオプションが 1 つの変数をどう置くか)から外れる。
§1.4 が実測したとおり **deploy 4 面はどれも assert されていない**のが今日のリポジトリの状態であり、
本件はそのうち 1 面の 1 変数を塞ぐ最初の check である。
**主張を限定して書き、限定を明示するのが正しい姿勢**であり、G3 と §6.1 の該当行も
`home.sessionVariables` の中に限る、と書いてある。

### R2: 否定側 assert が home-manager 側の既定に依存する

`off ? EDITOR` は「素のモジュールでは誰も `EDITOR` を設定しない」ことに乗っている。
計画作成時の実測では両システムとも `EDITOR` は不在で、入っているのは
`LOCALE_ARCHIVE_2_27`(linux)/ `TERMINFO_DIRS`(darwin)だけである(§3.4 の表)。
home-manager が将来どこかの既定モジュールで `EDITOR` を入れ始めると、この assert は
**偽陽性として赤くなる**。それは黙って通るより望ましい —— nvimx の「既定は no-op」という主張が
実際に成り立たなくなっているからである。`on ? VISUAL` も同じ性質を持つ。

### R3: `removeAttrs` の比較が attrset 全体を forcing する

`home.sessionVariables` は `lazyAttrsOf`(`modules/home-environment.nix:293`)なので、
`==` による比較は**全 value を forcing する**。今日そこに入っているのは
store path 文字列 1 個(linux の locale archive)または profile パス 1 個(darwin の terminfo。
store path は含まない)だけであり(§3.4 の表)、コストは無視できる。
将来 home-manager がここに評価の重い値を置くようになると、`nix flake check` の評価時間に
そのぶんが乗る。**現時点では計測上の問題なし**(check 全体が `touch $out` で完了する)。

### R4: `nix flake check` の出力に degraded 警告の trace が 3 本増える

degraded な lockDir を使い、モジュールを 3 回評価するため(§3.4)。
`checks.extra-lua-packages` の `moduleWrapped`(`flake.nix:344-363`)が既に 1 本出しているので
新種のノイズではない。実 lock に替えれば消せるが、lock と無関係な機能の check を lock に
結び付ける取引になるので採らない。

### R5: 検知対象が「引数の渡し忘れ」から「`config` の 1 行の消失」に変わった

#26 / #27 が繰り返し警告した「`makeEnv` の formals は既定値付きなので渡し忘れが黙る」という罠は
本件には無い(§4.1)。代わりに `config` の attribute そのものが消せる、という別の罠がある。
**症状は同じ(評価は通り、既存 check は緑)なので、対処も同じ ——
モジュールを評価して読み返す assert を 1 本置く**。`flake.nix` の当該コメントにその旨を書き残す(§5.2)。

### R6: `EDITOR` が PATH 経由で解決することへの依存

裸の `"nvim"` は PATH 上に nvimx の wrapper があることを前提にする。`defaultEditor` は
`config`(= `lib.mkIf cfg.enable`)の中にあり、`home.packages = [ cfg.env.wrapped ]`(`:330`)も
同じ `mkIf` の中で無条件なので、**「`EDITOR` は設定されているが nvim が PATH に無い」という状態は
モジュール単体では作れない**。ユーザが別経路で PATH を壊した場合は救えないが、
それは `home.packages` を使うすべてのモジュールに共通する話である。

**ただしこの「作れない」は位置によるものであり、check は固定していない**(§3.2)。
`home.sessionVariables` の行を `lib.mkMerge` で `mkIf cfg.enable` の外に出すと、
**check は 7 本とも緑のまま `enable = false; defaultEditor = true;` が `EDITOR = "nvim"` を吐く**
—— つまり `home.packages` は空で `EDITOR` だけが立つ、この R6 がまさに「作れない」と言った状態になる
(両方とも実測済み)。**8 本目の assert は足さない** —— 観測には `enable = false` の
4 つ目の評価が要り、§3.5(E) が却下したコストそのものである。
**固定されていない主張は固定されていないと書く**、という R7 と同じ扱いにする。
実装時とレビューで見るべきは「この 1 行が他の 3 面と同じ `mkIf` の中にあること」であり、
§5.1 編集 2 が `home.packages` の直後を指定しているのはそのためでもある。

### R7: 「同値ならマージされる」を固定する assert が無い

§3.1 の description・§4.3 の 4 行目・R1 はいずれも「外の定義が `"nvim"` なら黙ってマージされる」と
書いているが、**それを固定する assert は check に無い**(§3.5(E) でそう決めた)。
理由は 2 つ: それは **home-manager 側のマージ規則**であって nvimx の挙動ではないこと、
そして固定しようとすると `on.EDITOR` が重複に変わり、代替不能な assert が 1 本減ること。
計画作成時の実測は §4.3 の 4 行目に残してある。

home-manager が `types.str` のマージ規則を変えれば(同値でも衝突させる方向に振れば)、
この 3 箇所の記述は黙って古くなる。ただしそのときは `contested` 側 —— すなわち
`types.str` が**値の違う 2 定義を拒む**という、より根本的な性質 —— が先に赤くなる公算が高い。
**完全な無防備ではないが、直接の守り手が無いことは記録しておく。**

**これが `agreeing` を落として失ったものの全部である。** レビュー 9 回目の probe 単独版では
それ以外にも穴が残っていた(`competing` が自分で渡す nvimx 引数を打ち間違えると、
`mkDefault` 退行込みで check が緑になる)が、10 回目で `onArgs` を `on` と共有して塞いだ
(§3.4 の 2、実測は §6.2(c))。**「失ったのは pin だけ」と書けるのはその措置が入っているからであり、
`onArgs` の共有を後から「冗長だ」と解いてはならない。**

## 8. 検証手順(実装完了時に必ず全部通す)

**計画レビューで一部が実行済みであっても、実装後に全手順を改めて通すこと。**
§6.2 の実測はスクラッチのクローンで行ったものであり、実装ツリーの上で**実際に走らせた結果**を
もって完了とする。

```bash
cd /home/myuron/ghq/github.com/myuron/nvimx

# 1. 整形 + lint(treefmt: nixfmt / stylua / luacheck)。lua は 1 行も変えていないので実質 nixfmt。
#    §5.2 のスニペットは nixfmt 正規形を逐語で貼ったものなので、書き写せばそのまま通る。
nix fmt -- --ci

# 2. 新 check だけを先に回す(速いループ用)
nix build .#checks.x86_64-linux.hm-module-default-editor -L

# 3. フルチェック(linux)
nix flake check

# 4. darwin。ローカル linux の flake check は darwin を omit する(CLAUDE.md)。
#    drvPath は failures が非空でも評価できてしまうので、buildCommand も見る(§6.2(e))。
nix eval .#checks.aarch64-darwin.hm-module-default-editor.drvPath
nix eval --raw .#checks.aarch64-darwin.hm-module-default-editor.buildCommand   # → touch $out

# 5. §6.2(b) の mutation を実装ツリーで 1 度ずつ再現し、7 通りとも赤になることを確認する。
#    確認後は必ず戻すこと。check が「何も検知していない」状態で緑なのが本件最大の失敗モードである。
#    (a)-(g) の改変対象はすべて nix/home-manager/default.nix の home.sessionVariables の 1 行。
#    (d)(e)(f)(g) はそれぞれ assert 1 本しか拾わないので、そこを飛ばすと
#    「代替不能」という §6.1 の主張が未検証のまま残る。
#      (a) 行ごと削除                                                      → 2 本が赤
#      (b) lib.mkIf を外す                                                 → 2 本が赤
#      (c) mkIf の中に VISUAL = "nvim"; を足す                              → 2 本が赤
#      (d) VISUAL だけ無条件にする。on ? VISUAL だけが拾う:
#          home.sessionVariables =
#            { VISUAL = "nvim"; } // lib.optionalAttrs cfg.defaultEditor { EDITOR = "nvim"; };
#                                                                          → 1 本だけ赤
#      (e) EDITOR = lib.mkDefault "nvim";   contested だけが拾う            → 1 本だけ赤
#      (f) EDITOR = lib.mkForce "nvim";     contested だけが拾う            → 1 本だけ赤
#      (g) EDITOR = "${cfg.env.wrapped}/bin/nvim";(§3.3 の narrowing 2)     → 1 本だけ赤
#    さらに flake.nix 側を 1 箇所ずつ壊す probe も通すこと(§6.2(c) の下 14 行)。
#    これだけが「check が緑のまま何も検査しない」状態を検知する:
#      (h) competingModule を壊す。どう壊してもよい —— 3 通りとも通すこと:
#            (1) 別のパスにする: home.sessionVariables.EDITOR
#                             → home.sessionVariablesTypo.EDITOR   → 7 本目が赤
#            (2) 属性を足す:   home.stateVersion = "24.11"; を追加  → 7 本目が赤
#            (3) 競合をやめる: value を使わず "nvim" に固定        → 6 本目と 7 本目の 2 本が赤
#          (7 本目を消すと (1)(2) は緑になる = contested が黙って死んでいる。
#           (2) は、1 パスだけを見る旧形の assert では緑だった —— §3.4 の 1。
#           (3) だけ 2 本赤なのは、競合しなくなると contested 側も気づくからである)
#      (i) onArgs の nvimx.defaultEditor を nvimx.defaultEditorTypo にする
#                                          → 評価ごとエラー(assert では覆えない)
#          onArgs の共有をやめて competing 側に書き直すと、同じ打ち間違いが
#          mkDefault 退行込みで緑になる —— それが共有の存在理由である(§3.4 の 2)
#      (j) competing の modules = [ (competingModule value) ] を modules = [ ] にする
#                                          → 6 本目(contested)が赤
#          配線が腐る経路はこちらが受け持つ(probe は competingModule しか見ない)
#      (k) 既定値の守りが構造になっていること。モジュールの default = false を true にして:
#            (1) そのまま                                   → 3 本赤
#            (2) off の引数を { nvimx.defaultEditor = false; } に書き換える
#                                                           → 3 本目だけ赤
#            (3) 基底 attrset に defaultEditor = false; を足す
#                                                           → 3 本目だけ赤
#          (3 本目を消すと (2)(3) は緑になる。12 回目まではその「緑」が現行形であり、
#           off の引数が { } であることだけが既定値を守っていた —— §3.4)

# 6. 既存 hm 系が無影響であること(§6.3)。defaultEditor は既定 false なので中身は今日と同一。
#    §6.3 の 1 行目が挙げる 6 件を全部回す(2 件だけ手順 3 に任せると、
#    その 2 件が赤くなったとき原因の切り分けが 1 手増える)。
nix build .#checks.x86_64-linux.hm-module \
          .#checks.x86_64-linux.hm-module-degrade \
          .#checks.x86_64-linux.hm-module-plugins \
          .#checks.x86_64-linux.hm-module-treesitter \
          .#checks.x86_64-linux.hm-module-dev \
          .#checks.x86_64-linux.hm-module-lua-packages -L

# 7. ドキュメントの整合
grep -n 'defaultEditor' nix/home-manager/default.nix flake.nix README.md \
                        docs/architecture.md templates/default/flake.nix
grep -c 'defaultEditor' docs/architecture.md              # → 1(hm deployment の列挙)
grep -c 'hm-module-default-editor' docs/architecture.md   # → 1(checks の列挙)
# README の表とモジュールの宣言順が揃っていること(§1.3)。どちらも viAlias の直後であること。
grep -n 'viAlias\|defaultEditor\|extraPackages' README.md | head -5
grep -n 'viAlias = lib.mkOption\|defaultEditor = lib.mkOption\|extraPackages = lib.mkOption' \
     nix/home-manager/default.nix
```

**CLAUDE.md の Commands のうち、本件で回さないものと理由:**

- `nix fmt -- --clear-cache` —— `stylua.toml` / `.luacheckrc` を触らないので不要。
- `nix build .#demo && ./result/bin/nvim` —— `packages.demo`(`flake.nix:93-114`)は
  `nvimxLib.makeEnv` を直接呼んでおり `homeModules.nvimx` を通らない(§4.4)。
  `defaultEditor` は demo に到達しないので、スモークテストの対象にならない。
- `nix run .#lock -- ...` —— lua も lock パイプラインも 1 行も変わらない。
- `nix run .#skills-install` —— `agent-skills` input に変更なし。

手動確認は §6.5。実 dotfiles の `home-manager switch` が必要なので `checks` にはできない。
