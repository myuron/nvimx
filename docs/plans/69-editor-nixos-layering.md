# #69 対応計画: NixOS の `EDITOR` 既定値と `defaultEditor` の層関係を書き残す

対象 issue: [#69 docs(hm): record how NixOS's EDITOR default interacts with defaultEditor](https://github.com/myuron/nvimx/issues/69)

直前の #67 (PR #68, `74aa086`) で `programs.nvimx.defaultEditor` が入った。本件はその**後始末の
ドキュメント変更**であり、**コードは 1 行も変えない。新しい check も作らない。**
触るのは `docs/architecture.md` / `README.md` / `nix/home-manager/default.nix` の 3 ファイル、
合計 4 箇所(表の 1 行、表の直後の段落 1 つ、README の文 1 つ、description の 1 段落)である。

本計画の `file:line` は**現在の作業ツリー(`74aa086`、ブランチ `docs/hm-default-editor-nixos`)基準で
全件を実ファイルで再検証済み**である。nixpkgs / home-manager 側の行番号は `flake.lock` が固定している
input の実ファイルからの引用であり、**ストアパスと rev を以下で確認した**:

```
$ nix eval --raw --impure --expr '(builtins.getFlake (toString ./.)).inputs.nixpkgs.outPath'
/nix/store/5ljrgyqskjl8g5kxm88a8gl8251m801x-source
$ nix eval --raw --impure --expr '(builtins.getFlake (toString ./.)).inputs.nixpkgs.rev'
7525d999cd850b9a488817abc89c75dc733acf17          # nixpkgs-unstable, 26.11
$ nix eval --raw --impure --expr '(builtins.getFlake (toString ./.)).inputs.home-manager.outPath'
/nix/store/fm93mv69y0ify036r6zgnhqy1chw3vd0-source
$ nix eval --raw --impure --expr '(builtins.getFlake (toString ./.)).inputs.home-manager.rev'
079a3b5d1aa6a719920a51316253b7d6dd22738d
```

**`flake.lock` のノード名を直接読まないこと。** ルートの nixpkgs / home-manager は
**`nixpkgs_2` / `home-manager_2`** である。素の `nixpkgs` ノード
(`d407951447dcd00442e97087bf374aad70c04cea`、`nixos-unstable`)は **`agent-skills` の input** であり
本件とは無関係で、間違えると R1 の唯一の緩和策が別のツリーを指すことになる。
上の `--raw` 4 本で取れば間違えようがない。以下 `$NIXPKGS` / `$HM` はこのストアパスを指す。

**本計画は出荷文の事実誤りをレビュー 17 回で 29 個潰している。**
1-6 は同じ種類 ——「どのシェル / どのセッションに効くか」の範囲を広く言いすぎる —— で、
**7-28 は種類が違い、「読者が取る行動そのものを誤らせる」誤り**だった。
**見つけ方で 3 つに割れる(14 + 14 + 1)。**
**番号列にはもう 1 つ、誤り 30 がある** —— これは**出荷文ではなく本計画の記録の側**の誤りで、
上の 29 には数えない(round-17。詳細は決定 21)。**出荷文を壊す向き**の誤りなので同じ列で番号を振った。
**(i) §1 の再導出で 14 個**(§6.1(b))—— **1-7**(§1 を pinned tree から引き直す。
誤り 7 は §1.4 の `nix eval`)、**8-11**(実際にシェルを起動する。§1.7)、
**12**(§1.3(d))、**14 と 27**(§1.7 結論 2 との突き合わせ)。
**(ii) 出荷文を構文として読んで 14 個(13 / 15 / 16-26 / 28)** —— 再導出では原理的に出ない
(同格句・関係節・VP 省略・代名詞の掛かり先。§8 手順 5b がその読み方である)。
**(iii) 出荷文を本計画自身の決定と突き合わせて 1 個(29)**(**同じ突き合わせが round-17 に
誤り 30 —— 記録の側の 6 箇所 —— も出している**)—— round-16 で見つかった
**決定 10 が命じた不定冠詞が、表の行と description の両方で `the` のまま出荷されていた**もの。
数値も構文も正しく、**決定と出荷文だけが食い違っていた**ので (i) でも (ii) でも出ない。
**§8 手順 6a に「決定と出荷文の突き合わせ」を 1 つ足したのはこれが理由である**(決定 21)。
**その §1.7 自体が、2 度壊れた状態でこの計画に載った** —— 7 回目のレビューが 20 値中 7 値の
再現失敗を、8 回目が更に 2 つの黙った嘘を見つけている。**装置も検証対象である。**
8 回目の結論として、**§1.7 は「手順」から「§1.5 の表をどう測ったかの記録」に降格した**
(§8 手順 5 はその再実行を要求しない)。その自己診断は**関門ではない** ——
pty 経路の汚染も `/run` の bind 忘れも検出できないことが実測されている(§1.7)。

1. **「GUI セッションは NixOS の `EDITOR` を一度も見ない」は X11 では偽**(§1.3(e))。NixOS の
   ディスプレイマネージャが使う `xsessionWrapper` は `. /etc/profile` から始まる。
   issue 本文にもこの誤りが入っていた。**出荷文から削除済み。**
   (ただし `xsessionWrapper` は主に X11 の経路であり、gdm / sddm の Wayland セッションは
   通らない —— **正しく書くと DM ごとに 3 分岐する**。それが「GUI の話は 1 文字も書かない」
   という決定 3 の本当の根拠である。§1.3(e) 参照。)
2. **`/etc/profile` は bash だけのファイルである**(§1.3(d))。zsh は `/etc/zshenv`、
   fish は `nixos-env-preinit.fish` から `/etc/set-environment` を読む。
   3 つのシェルを名指す文のなかで `/etc/profile` を共通の経路のように書くと、zsh ユーザが
   自分のシェルが読まないファイルを見に行く。**出荷文は `/etc/set-environment` に寄せた。**
3. **「every shell's system-wide init」という全称は偽**(§1.3(d))。`setEnvironment` を source する
   NixOS モジュールは bash / zsh / fish / xonsh の **4 つだけ**である。
4. **3 を直した「`/etc/zshenv` for zsh ... and so on」もまだ偽だった**(§1.3(d) の存在測定)。
   zsh / fish / xonsh は `enable` 既定 `false` で、**素の NixOS にそのファイル自体が無い**。
   出荷文はファイル名を必ず `enable` 条件とセットでしか出さず、行と description は
   **不定冠詞 "a system-wide shell init that NixOS generates"** で受ける(§3.2 決定 10)。
5. **「home-manager が管理していれば `defaultEditor` が勝つ」は bash で偽**(§1.5)。
   home-manager は bash の session vars を `~/.profile` にしか置かず、NixOS の `/etc/bashrc` は
   `/etc/profile` を source するので、**非ログインの対話 bash は `nano` で終わる**。
   段落はこの例外を名指しし、description は "nvim **usually** wins" と弱めた(§3.2 決定 13)。
6. **5 を直した「except in a non-login bash」も、条件を 2 つ落としていた**(§1.5)。
   **非対話**の非ログイン bash は `/etc/bashrc` も `/etc/profile` も読まない(`nano` ですらなく
   未設定)し、**環境を継承している**非ログイン対話 bash は `nvim` のままである
   (X11 セッション配下がまさにそれ)。出荷文は
   **"a non-login interactive bash started from a clean environment"** と両方を書く。
7. **「`environment.variables.EDITOR = lib.mkForce null;` が直す」は偽**(§1.4 の remedy 実測)。
   この 1 行は `nano` を**消す**だけで `nvim` を**一度も生まない** —— 行が説明しているまさに
   その場面で、当てても `defaultEditor` は効かないままである。
   **ここから種類が変わる** —— 範囲の誇張ではなく、**告知した効果が無い remedy** を
   ドキュメントが指示していた。取り消し側は「not a fix」と明記した上で
   段落と description にだけ残す(§3.2 決定 14)。
8. **7 を直した「効く 2 つ」も等価ではなかった**(§1.7 の実シェル実測)。
   round-5 の案は home-manager 側を先に無条件で並べていたが、
   **その段落が 2 文前に除外している bash 非ログインのセルで、home-manager に管理させても
   `nvim` にはならない** —— `environment.variables.EDITOR = "nvim";` だけが出す。
   表の行に至っては例外を 1 文字も持たないまま**弱い方を先頭**に置いており、
   「端末を開くと非ログイン対話 bash が立つ」という最も普通のデスクトップ構成の読者を
   効かない remedy に誘導していた。**強い方を先に、弱い方には例外付きで**(§3.2 決定 15)。
9. **「except in a non-login *interactive* bash」も 1 セル足りなかった**(§1.7)。
   非ログイン**非対話**の bash でも `defaultEditor` は効かない(stdin 次第で未設定か `nano`)。主語を
   **"a bash started from a clean environment that is not a login shell"** に広げ、
   2 セルを 1 語で覆う。
10. **9 を直した「`nano` where a NixOS shell module is enabled, nothing at all where none is」も
    まだ偽だった**(§1.7 の表)。**モジュールが enable されていて**なお `nano` でも `nothing` でも
    ないセルがある —— hm 管理外・非ログイン・非対話 bash は stdin 次第である。
    しかも同じ段落が 2 文前にその bash を*管理している*側で除外しながら、*管理外*側では
    無条件に言い直しており、**決定 16 を片側にしか適用していなかった**。
    最終形は数え上げをやめ、4 つの出荷文すべてを同じ強さに揃える ——
    段落 **"usually `nano`, sometimes nothing at all"**、
    description **"can still come out nano"**、表の行と README は既に "usually"(決定 16)。
11. **8 を直した description の「is what reaches both」も、まだ条件が抜けていた**(§1.7 の表)。
    "both" が指すのは「hm 管理外のシェル」と「ログインシェルでない bash」だが、
    §1.7 の `bash non-login non-interactive`(stdin 非ソケット)は**その両方に属し、
    そこでは `environment.variables.EDITOR = "nvim";` も届かない**(実測 `<unset>`)。
    round-6 の「the fix that covers both」を round-7 で「is what reaches both」に言い換えただけで、
    **主張の強さは変わっていなかった**。表の行と段落には最初から条件が付いていたので、
    **4 つのうち description だけが無条件** —— §3.4 決定 1 が「architecture.md より一段厳しく」と
    言っている場所で、逆に一番強い主張をしていた。
    **"wherever anything is read at all" を足して 4 文を揃える**(決定 15)。
    **この句は round-15 の誤り 27 で "wherever any definition is read at all" に制限された。**
12. **決定 15 は 2 つの remedy の「限界」は揃えたが、「スコープ」を揃えていなかった**(§1.3(d))。
    表の行の「letting home-manager manage the shell reaches **every one** but a non-login bash」の
    "every one" は、直前に置いた「every shell that reads a definition at all」を受ける ——
    その集合には **xonsh** が入る(`xonsh.nix:89` が `setEnvironment` を読む。§1.3(d) の 4 モジュール)。
    そして **home-manager には xonsh モジュールが存在しない** —— §1.5 のとおり
    `hm-session-vars` を読むのは **5 箇所**で、そのうちシェルのモジュールは
    `programs/bash.nix:269` / `programs/zsh/default.nix:424` / `programs/fish.nix:411` の
    **3 つだけ**である。残る 2 つは `xsession.nix:210` と
    `targets/generic-linux.nix:80` で、シェルのモジュールではない。
    (`ls $HM/modules/programs/` に xonsh は無い。`nushell.nix` と `ion.nix` はあるが読まない。)
    **つまり xonsh は「home-manager に管理させる」では届かず、届けようもない。**
    誤り 5/6/9/10/11 と同じ形(例外が実測より狭い)である。
    **4 つのうち表の行だけが remedy を無スコープで出していた** —— 段落は 1 文前に
    「bash, zsh and fish are the three shells it can set session variables for」と枠を置いており
    (**round-10 当時の文面。`it` は誤り 20 で `home-manager` に置き換わっている** ——
    **これは時系列の記録であって決定ではない**。現在の文面は §3.2 の枠内と 6a / 6e が持つ)、
    description は hm 管理を remedy として提示せず、README は remedy を名指ししない。
    あわせて 1 つ目の動詞も **"reaches" → "gets you `nvim` in"** に落とす ——
    NixOS 側で `programs.zsh.enable = false`、home-manager が zsh を管理している構成では
    「定義は読まれる(home-manager の)が、NixOS の行は届いていない」ので、
    "reaches" は 4 文のうち唯一の literal な過剰主張だった(結果は同じなので害は無いが、揃える)。
    > **`fish.nix:760` の読み先はオプション名が違う。** そこが読むのは
    > `cfg.sessionVariablesPackage`(= `programs.fish.sessionVariablesPackage`。`:642` で
    > `sessionVarsPkg` を代入している)であって `home.sessionVariablesPackage` ではない。
    > また `xsession.nix:210` と `targets/generic-linux.nix:80` が読むのは
    > `config.home.profileDirectory` であって、このオプションではない。
    > **「`home.sessionVariablesPackage` を読む箇所」で数えると取りこぼす** ——
    > §1.5 の「`hm-session-vars` を読む箇所」で数えること。結論は変わらない。
13. **12 を直した「`-- bash, zsh or fish --`」は、挿す位置が間違っていた**(round-10)。
    同格句は直前の名詞 **the shell**(手段)に掛かり、**every one**(被覆範囲)には掛からない ——
    つまり "every one" は依然として前の連言の「every shell that reads a definition at all」を
    先行詞に取れてしまい、**誤り 12 の偽読みがそのまま残っていた**。
    **列挙は数量詞のところに置く**: 「reaches **bash, zsh and fish -- every one but ...**」。
    **あわせて表の行の例外に "started from a clean environment" を戻す**(決定 9 / 13)——
    セッションを継承した非ログイン bash は `__ETC_PROFILE_DONE` も継承するので
    `/etc/bashrc:190-192` が `/etc/profile` を飛ばし、**`nvim` のままである**(X11 端末の形)。
    round-9 までの行だけがこの限定を落としており、**決定 15 が掲げた「4 文を同じ強さに」に
    反していた**。description の弱め(「can still come out nano」)は決定 13 が
    「行数の都合」として明示的に記録している。
    **(13 の修正は round-11 で丸ごと不要になった —— 決定 18 で表の行から
    home-manager 側の remedy ごと落としたので、列挙も例外も掛かり先も無くなった。)**
14. **強い方の remedy に付けた数量詞は、粒度が違っていた**(round-11)。
    「gets you `nvim` in **every shell that reads a definition at all**」の "shell" は、
    同じ行の他の 3 箇所と同じく**シェルのプログラム**を指す読みが強制される。
    ところが §1.7 結論 2 が真なのは**起動のしかた**についてであって、プログラムについてではない ——
    bash は「定義を読むシェル」に決まっている(ログイン bash は `/etc/profile` を読む)のに、
    §1.7 の 3 行目は `="nvim"` の両列とも `<unset>` である。
    他の 2 文(段落と description)が使う **"wherever any definition is read at all"**
    (状況の量化。当時の文面は "anything" で、それ自体が誤り 27 だった)とは別物で、
    **誤り 11 の鏡像**である —— round-8 は「条件が付いている」ことだけを見て
    **粒度を確かめていなかった**。決定 18 でこの節ごと削除した。
15. **段落の非制限 `, which` が間違った先行詞を取り、事実の逆を述べていた**(round-11)。
    「except in a bash started from a clean environment **that is not a login shell, which**
    never reaches the `~/.profile`…」—— `, which` は直前の NP **`a login shell`** に掛かるのが
    標準的な読みで、そうすると「ログインシェルは `~/.profile` に到達しない」となる。
    **これは正反対である**(`bash/5.nix:74` の `-DNON_INTERACTIVE_LOGIN_SHELLS` により、
    ログイン bash こそ到達する側である。§1.5)。さらに `that is not a login shell` も、
    意味が再解析を強いるまでは近い方の `a clean environment` に掛かる。
    **誤り 13 と同じ失敗が、2 回のレビューが通した本文で起きていた。**
    修正は表の行と同じ**前置修飾**に揃えること —— 「except in a **non-login bash started from
    a clean environment, which** never reaches the `~/.profile`…」。
    **「1 箇所で両方直る」と書いたのは言い過ぎだった**(誤り 18)—— 前置修飾が直したのは
    `that is not a login shell` の方だけで、**`, which` は `a clean environment` に残っていた**。
    最終的には決定 19 が文を割って掛かり先ごと消している。
    あわせて段落と description の「after that」を "after the NixOS init does" にしたが、
    **これは round-12 の誤り 16 で覆っている**(VP 省略がどちらの解でも偽になった)。
    最終形は決定 19 の「順序を主節にする」側である。元の指摘は:
    `that` に対応する NP が前文に無く、`after that` は `sources` にも `generates` にも掛かりうる。

16-24. **段落と description が「文として」壊れていた 9 件**(round-12。**手順 5b で出た** ——
    7 件はレビューの 5b、**23 / 24 は本計画自身が書き換えた草稿に 5b を当てて出したもの**)。
    数値・引用・測定はすべて正しいまま、**掛かり先と省略だけが誤っていた**。
    構造的な原因は 1 つ —— **2 つの文が仕事を持ちすぎて、指示対象を代名詞に押し込んでいた**。
    対処も 1 つ: **指示対象を名前で書き、順序関係を主節にする**(下の 16 / 17 がその 2 本)。
    - **16. `after the NixOS init does` は VP 省略がどちらの解でも偽**。`does` が同定できる VP は
      「sources the hm-session-vars file it generates」か「generates」しかなく、
      どちらも「NixOS の init が hm-session-vars を source / 生成する」となって偽である。
      意図した「NixOS の init が**自分の値を先に export し終えたあと**」を指す VP が文中に無い。
      **round-11 の修正が、真の読みが 1 つあった `after that` を「両方偽」に悪化させていた。**
      → **順序を主節にする**: 「The NixOS init runs first; a shell home-manager manages then
      sources the `hm-session-vars` file home-manager generates, ...」。
    - **17. `the two are separate module systems` に先行詞の対が無い**。その時点で
      **home-manager は一度も出てきていない**(初出は 2 文あと)。最近の複数名詞は
      `programs.zsh` と `programs.fish` で、その読みは**まさにこの文が否定したい命題**になる。
      → 「NixOS and home-manager are separate module systems ...」と両方を名前で書く。
      description は元から `The two module systems` と型付き NP で正しかったが、
      **誤り 22 を直した拍子に home-manager の初出が消えたので**、
      冒頭を「On NixOS, home-manager is not the outermost layer.」に変えて両者を先に名指した。
    - **18. 誤り 15 の修正は `, which` の掛かり先を直しきれていなかった**。`non-login` を
      前置修飾にしたのは**除外を担う名詞**を直しただけで、非制限関係節は依然として
      直近 NP(`a clean environment`)を取る。型の衝突で読み直しは起きるが**同じ類が残っていた**
      —— 記録の「1 箇所で両方直る」は言い過ぎだった(決定 19 に是正を記録)。
      → 誤り 16 の文分割で**掛かり先そのものが消えた**。
    - **19. FAQ の括弧内で `it` が 2 つ、別の指示対象を取っていた**。どちらも
      `session-variables.md` に束縛され、1 つ目(「it can set session variables」)は偽、
      2 つ目は真 —— 等位接続は同一指示を要求するので、**どの読みでも一方が必ず誤る**。
      `the file` も同様に `session-variables.md` を取り、意図した `hm-session-vars` と食い違う。
      → 主語を 1 つにして省略でつなぎ、ファイルを名前で書く。
    - **20. 「A shell it does not manage ... unless you source it yourself」の `it` 2 つ**。
      1 つ目は左に 9 個の NP を遡らないと `home-manager` に届かない。
      → 主語を名前に(`A shell home-manager does not manage ...`)。**`source it yourself` の `it` は
      残してある** —— 直近が `hm-session-vars` で正しく束縛されるからで、「両方とも名前にした」と
      書くのは主張が広すぎた(round-15 の指摘。本計画が狩っている形そのものである)。
    - **21. `what exports it` が `/etc/pam/environment` を取る**(段落) ——
      **定義が「落ちない」と明言した直後のファイル**である。description では
      `programs.nano.enable` を取り、「programs.nano.enable を export する」は整形式で偽。
      → 目的語を名前で書く(`What exports `EDITOR` from `/etc/set-environment` is ...`)。
    - **22. description の `a layer above home-manager that this option cannot reach`** ——
      制限関係節が `home-manager` に掛かる。→ 17 と同時に書き換えた。
    - **23.(本計画自身の 5b で発見)段落の `so it lands in /etc/set-environment and never in
      /etc/pam/environment` の `it` が `environment.sessionVariables` を取る** ——
      **整形式で、かつ偽**である(`sessionVariables` は `/etc/pam/environment` に落ちる。§1.3(b))。
      round-12 の草稿で作り込んでしまった新規の誤りで、**名詞を繰り返して**直した
      (`so the definition lands in ...`)。
    - **24.(同上)description の末尾 `mkForce null is not.` の省略が壊れていた** ——
      「is not」が同定すべき述語が文中に無い。→ `mkForce null is not a fix; see nvimx's
      docs/architecture.md.`(96 桁に収めるため文を入れ替えた)。
    **あわせて微修正を同じ書き換えで畳み込んだ**: `the option's apply` →
    `the apply on environment.variables`(`apply` は `.EDITOR` ではなく `environment.variables` に付く)、
    `so it drops NixOS's export` → `so that line drops ...`、
    表の行と README の `that is usually the only definition left` → `NixOS's is usually ...`、
    そして 3 文すべてにあった `NixOS generates exports` の N-V-N garden path →
    `the system-wide shell init **that** NixOS generates exports ...`。

25. **`theirs` が「NixOS and home-manager」を先行詞に取り、整形式で偽になっていた**
    (round-13。**手順 5b**)。「NixOS and home-manager are separate module systems ...,
    so no priority of **ours** is ever compared against **theirs**」——
    `theirs` を読む時点で使える複数の先行詞は直前の **「NixOS and home-manager」だけ**で、
    その読みは「nvimx の優先度は NixOS のものとも **home-manager のものとも**比較されない」となる。
    **これは偽である** —— nvimx の `home.sessionVariables.EDITOR` の優先度は
    home-manager の他の定義と**現に比較される**(`nix/home-manager/default.nix:102-111` が
    そのために 10 行を費やし、`flake.nix:393-396` がそれを守る check のコメントである)。
    意図した単数の指示対象は、`theirs` より**後ろ**の `our side` からしか復元できない。
    **決定 19 の「主体は毎回名前で書く」を、この文にだけ当て忘れていた。**
    → 「so no priority nvimx sets is ever compared against NixOS's, and a `mkForce` in nvimx
    would change nothing」。
    **同時に register も直っている** —— `our` / `ours` / `we` / `us` は
    `docs/architecture.md` / `README.md` / `nix/home-manager/default.nix` のいずれにも
    **1 語も無い**(実測)。round-12 の書き換えが一人称複数をこの 3 ファイルに持ち込むところだった。

26. **description の `it` が `nano` を先行詞に取り、整形式で偽になっていた**(round-14。**手順 5b**)。
    「NixOS sets EDITOR **to nano** with no enable option behind **it**」——
    直近の NP は **`nano`** で、「nano には enable オプションが無い」は整形式かつ**偽**である
    (`programs.nano.enable` は実在し既定 `true`。`nixos/modules/programs/nano.nix:15-17`)。
    **しかも同じ文の 11 語あとの括弧が、まさにその `programs.nano.enable` を名指している** ——
    文が自分自身と矛盾しており、NixOS の読者は「このドキュメントは
    `programs.nano.enable` の存在を否定している」と受け取りうる。
    **表の行と README は無傷である** —— どちらも `` `EDITOR=nano` `` を**1 つの span**で書くので
    `it` は代入全体に束縛される。description だけがこの保護を失っていたのは、
    §3.4 決定 3 がバッククォートを剥がした結果 `EDITOR to nano` と綴り直され、
    **1 つの NP が 2 つに割れた**からである。
    → 他の 2 文に合わせて **`NixOS sets EDITOR=nano with no enable option behind it`**。
    語順で直す(手順 5b 手順 3)。1 行目は 92 → **89 桁**、折り返しも行数も変わらず、
    §8 の期待値は 1 つも動かない(`nano` は 2 / 1 / 3 のまま、ブロックは `:88-124` 最長 96)。

27. **「wherever anything is read at all」は制限が外れていた**(round-15。**誤り 7-14 の族**)。
    §1.7 結論 2 が言っているのは「覆えないのは**どの定義も読まれないセル**だけ」であって、
    **「何かが読まれる」ではなく「何か *の定義* が読まれる」**が制限子である。
    反例は本計画自身が §1.7 の末尾で測っている —— **`programs.zsh.enable` を立てていない NixOS で、
    home-manager も zsh を管理しておらず、ユーザが自前の `~/.zshrc` を持っている**構成では
    「何か」は読まれるのに `environment.variables.EDITOR = "nvim"` は届かず `EDITOR` は未設定になる。
    **表の行が読者を誘導するまさにその構成で、文が literal に偽だった。**
    → 段落と description の両方を **"wherever any definition is read at all"** にする
    (description は 3 桁ぶん `is not a fix` → `is no fix` で相殺した)。
28. **代用形の機械的な掃き出し**(round-15。**手順 5b の網羅適用。誤り 16-26 の族の「閉じ」**)。
    round-14 で「形」の規則(裸の代名詞 = 9 件中 9 件、指示詞 + 主要部名詞 = 14 回で 0 件)を
    立てたので、**残りを標本ではなく網羅で潰す**。4 文の束縛点は、代名詞・指示詞・省略主要部・
    VP 省略・明示の関係詞を数えて **42**(round-15 は 41 と数えたが、加算の `too` が 2 箇所ある。
    round-24 に訂正)。**round-15 の掃き出しはここで止まっており、
    ゼロ関係詞(関係詞を省いた目的格関係節)12 箇所を勘定に入れていなかった** ——
    全体では **54** である(その取りこぼしが round-16 で効いた。決定 21)。
    **全部を格上げはしない** —— `looks like it does nothing` の `it` は外すと文が壊れるし、
    命題を指す `this`、`too`、`its /etc/profile`、`its own`、`nvimx cannot resolve it` の 2 箇所は
    偽の読みが存在しない(型が合わない)。
    **格上げしたのは 8 本の編集 = 10 箇所**(下の 8 本のうち末尾 2 本は表の行と README の
    2 文に同時に当たる。**「編集の本数」と「束縛点の個数」を混ぜて数えないこと** —— round-16 の指摘):
    - **表の行 `exports it` → `` exports `EDITOR` ``** —— 直近の先行詞は
      介在する関係節の主語 **`NixOS`** で、型の衝突だけが救っていた。
      **誤り 21 の修正が届いていなかった 3 文目**である(段落と description は既に
      `EDITOR` を名前で書いていた)。「標本であって閉じていない」ことの最も明確な実例。
    - **段落 `you enable them` → ファイル名を条件の前に出して `those modules`** ——
      直近の複数は **2 つのファイル名**であって 2 つのモジュールではなかった。
    - **段落の関係節を PP の内側へ** —— `-- a plain definition, which at priority 100 beats ...`。
      **4 文で唯一、関係節が PP をまたいでいた箇所**で、これは**誤り 18 の配置そのもの**である
      (手順 5b 手順 3 が名指しで警告している形)。今日は偽の読みが無いので、欠陥ではなく格上げ。
    - **description `reaches both` → `reaches both shells`** —— 同じ 10 行の 3 文前に
      **`The two module systems` という数詞付きの双数**があり、`both` の先行詞としては最強である。
      「both module systems に届く」は整形式で**偽**。今日は線形距離だけが救っていた。
    - **description `nothing here` → `nothing nvimx sets`**(`only shell export order` →
      `only export order` で桁を相殺)—— **誤り 25 の規則を段落にだけ当てて description に
      当て忘れていた**。誤り 10 / 12 と同じ「片側だけ適用」の形である。
    - **README `and what does` → `, and what resolves it.`** ——
      **4 文に残る最後の VP 省略**で、VP 省略は誤り 16 と 24 の住処である。
    - **表の行と README `NixOS sets ... itself` → `NixOS itself sets ...`** ——
      目的語の後ろの強調辞は目的語に掛かりうる。
    - **表の行と README `NixOS's is usually the only definition left` →
      `NixOS's default is ...`** —— **round-12 がここを `that is ...` から書き換えたとき、
      主要部を省いた所有格、つまり 9 件中 9 件の側へ移してしまっていた**。主要部名詞を戻す。

**もう 1 つ、skeleton の想定が覆っている。** 「home-manager モジュールから NixOS の `config` は
見えないので、警告すら出しようがない」は**誤りである** —— home-manager は `osConfig` を module 引数で
渡しており(NixOS モジュール経由なら NixOS の `config` そのもの、standalone なら `null`)、
`osConfig.environment.variables.EDITOR` は**実際に読める**(§3.1 で実測)。却下の根拠は
「できない」ではなく「**やらない**」でなければならず、§3.5(A) にそう書いてある。
出荷文が言うのは「nvimx には**直せない**」であって「見えない」ではなく、`osConfig` は
読み取り専用なので「直せない」は変わらない。**ただし「見えない」とは 1 文字も書かないこと。**

---

## 1. 背景 / 現状

### 1.1 nvimx 側の現状 —— 上の層について**一言も書いていない**

#67 が入れたものは 4 ファイル 5 箇所に現れる: `nix/home-manager/default.nix:358`
(`home.sessionVariables = lib.mkIf cfg.defaultEditor { EDITOR = "nvim"; };`)、
同 `:88-113`(オプション宣言。**26 行**、description は `:91-112`)、`README.md:210`(Options 表)、
`docs/architecture.md:175`(`[6] hm deployment:` の列挙)、
`templates/default/flake.nix:48`(`# defaultEditor = true;  # export EDITOR=nvim`)。

**ドキュメント 2 ファイル**に限れば `EDITOR` の出現は 2 箇所だけである:

```
$ grep -n 'EDITOR' docs/architecture.md README.md
README.md:210:| `defaultEditor` | `bool` | `false` | Set `EDITOR` to `nvim` in `home.sessionVariables`. ...
docs/architecture.md:175:      home.sessionVariables.EDITOR = "nvim"        (when defaultEditor = true)
```

description は **home-manager の内部**での衝突(`programs.vim` / `programs.helix` /
`programs.neovim` / 手書きの `home.sessionVariables.EDITOR`)を 10 行(`:102-111`)かけて
書いているのに、**その 1 つ上の層(NixOS)には触れていない**。issue はそこを埋めるものである。

### 1.2 NixOS は `EDITOR` を `nano` にする(pinned nixpkgs で実読)

`$NIXPKGS/nixos/modules/programs/environment.nix:17-23` を逐語で引く
(この attrset が `:15` の `config = {` の直下にあり、外側に `lib.mkIf` は無い):

```nix
    environment.variables = {
      NIXPKGS_CONFIG = "/etc/nix/nixpkgs-config.nix";
      # note: many programs exec() this directly, so default options for less must not
      # be specified here; do so in the default value of programs.less.envVariables instead
      PAGER = lib.mkDefault "less";
      EDITOR = lib.mkDefault "nano";
    };
```

読み取れる事実は 4 つ:

1. `EDITOR = lib.mkDefault "nano";` は **`:22`**。
2. **`config` の直下**にあり、`lib.mkIf` も enable オプションも無い。`mkDefault` なので
   **上書きは可能**だが、上書きしない限り必ず定義される。
3. モジュールは `nixos/modules/module-list.nix:210` に無条件で載っており、`module-list.nix` は
   `nixosSystem` が常に読む。**NixOS である限り必ず評価される。**
4. **`programs.nano.enable` とは無関係。** `nixos/modules/programs/nano.nix` には `EDITOR` も
   `environment.variables` も出てこない(`grep -c 'EDITOR\|environment.variables' .../nano.nix` → `0`)。
   既定は `true`(`nano.nix:15-17`)だが `false` にしても `EDITOR` は `nano` のままである(§1.4)。

### 1.3 どこに落ち、誰が export するか

**`environment.sessionVariables` ではない**ことが本件の核である。

**(a) 落ちる先は `/etc/set-environment`.**
`$NIXPKGS/nixos/modules/config/shells-environment.nix:14-32` の `exportedEnvVars` が
`cfg.variables`(`:16`)を `export NAME="..."` に畳み、`:250-268` の `setEnvironment`(`writeText`)の
`:256` に埋め込まれ、`:248` で `/etc/set-environment` になる。

**(b) `/etc/pam/environment` には落ちない.**
`nixos/modules/config/system-environment.nix:19-29` の `combinedSessionVars` は
`security.wrapperDir` の `PATH`、**`cfg.sessionVariables`**(`:27`)、`suffixedVariables`(`:28`)の
3 つだけを zip する。**`cfg.variables` は入っていない。** `:96-110` の
`environment.etc."pam/environment".text` はその `combinedSessionVars` だけから作られる。

**(c) 片方向にしか流れない** —— `shells-environment.nix:227-231`:

```nix
    # Set session variables in the shell as well. This is usually
    # unnecessary, but it allows changes to session variables to take
    # effect without restarting the session (e.g. by opening a new
    # terminal instead of logging out of X11).
    environment.variables = config.environment.sessionVariables;
```

**`sessionVariables` ⊆ `variables`** であって逆ではない。`environment.variables` に書いた
`EDITOR = "nano"` は `sessionVariables` には**決して入らない**。

**(d) export するモジュールは 4 つしか無い。`/etc/profile` は bash だけのものである。**

`grep -rn 'system.build.setEnvironment' "$NIXPKGS/nixos/modules/"` の**全 8 件**のうち、
定義側の `config/shells-environment.nix:248` / `:250` と、シェルではない
`services/editors/emacs.nix:74`(emacs daemon の `ExecStart`)を除いた**残り 5 行 = 4 シェル**が
以下である。**nushell / tcsh / ksh / elvish には NixOS モジュールが無い**:

| シェル | NixOS が書くファイル | `setEnvironment` を source する行 | `enable` 既定 |
|---|---|---|---|
| bash | `/etc/profile`(`programs/bash/bash.nix:156-178`) | `:135`(`programs.bash.shellInit` 経由。`:167` で展開) | **`true`**(`:31-42`) |
| zsh | `/etc/zshenv`(`programs/zsh/zsh.nix:186-214`) | `:195`。**zsh は `/etc/profile` を読まない**(`/etc/zprofile` は `:216` の別ファイル) | `false`(`:50-51`) |
| fish | `/etc/fish/nixos-env-preinit.fish`(`programs/fish.nix:192-213`) | babelfish 版は `:177-178` が `/etc/fish/setEnvironment.fish` を生成し `:197` が source、非 babelfish 版は `:208` が `fenv source` | `false`(`:56-57`) |
| xonsh | `programs/xonsh.nix` の `xonshrc` | `:89` の `source-bash "${config.system.build.setEnvironment}"` | `false`(`:23-24`) |

**`nixos-env-preinit.fish` を読み込むのは fish の *パッケージ* であって `nixos/modules/` ではない。**
`pkgs/by-name/fi/fish/package.nix:103-104` が埋め込み config に
`and test -f /etc/fish/nixos-env-preinit.fish` / `and source /etc/fish/nixos-env-preinit.fish` を
持っている。`/etc/fish/config.fish`(`fish.nix:217-259`)は preinit の**読み手ではなく兄弟**である。

**しかも `enable` は「そのモジュールが設定を書くかどうか」であって、既定 `false` の 3 つは
ファイルそのものが存在しない。** §1.4 の `mk` で `environment.etc` の有無を直接測った:

```
$ nix eval --impure --json --expr '
let
  flake = builtins.getFlake (toString ./.);
  nixpkgs = flake.inputs.nixpkgs;
  mk = extra: (nixpkgs.lib.nixosSystem {
    system = "x86_64-linux";
    modules = [
      { boot.loader.grub.enable = false; fileSystems."/" = { device = "none"; fsType = "tmpfs"; }; system.stateVersion = "25.05"; nixpkgs.hostPlatform = "x86_64-linux"; }
      extra
    ];
  }).config;
  probe = c: {
    profile     = c.environment.etc ? "profile";
    zshenv      = c.environment.etc ? "zshenv";
    fishPreinit = c.environment.etc ? "fish/nixos-env-preinit.fish";
    bashrc      = c.environment.etc ? "bashrc";
    setEnv      = c.environment.etc ? "set-environment";
  };
in {
  baseline = probe (mk { });
  zshOn    = probe (mk { programs.zsh.enable = true; });
  fishOn   = probe (mk { programs.fish.enable = true; });
}'
{"baseline":{"bashrc":true,"fishPreinit":false,"profile":true,"setEnv":true,"zshenv":false},
 "fishOn"  :{"bashrc":true,"fishPreinit":true, "profile":true,"setEnv":true,"zshenv":false},
 "zshOn"   :{"bashrc":true,"fishPreinit":false,"profile":true,"setEnv":true,"zshenv":true}}
```

**素の NixOS に `/etc/zshenv` も `/etc/fish/nixos-env-preinit.fish` も無い。**
`environment.etc.zshenv` は `zsh.nix` の `mkIf cfg.enable`(`:182`)の中、fish の preinit は
`fish.nix` の同じ位置にあるからである。あるのは `/etc/profile` / `/etc/bashrc` /
`/etc/set-environment` の 3 つで、実際に効いているのは bash の `/etc/profile` である。

**したがって出荷文に書けるのは 2 つの条件付きの形だけである**(§3.2 決定 10):
「**every shell's** system-wide init」のような全称も、
「`/etc/zshenv` for zsh」のような**存在を前提にした断定**も書けない。
段落は「whichever shell module NixOS has enabled -- `programs.bash` by default ... ;
`programs.zsh` and `programs.fish` write ..., **but only once you enable those modules**」とし、
行と description は「**a** system-wide shell init **that** NixOS generates」と不定冠詞で受ける
(round-16 まで両方とも `the` のまま出荷文に残っていた —— 決定 21)。

**`/etc/set-environment` について —— 出荷文は正しいが、1 つだけ注意がある**(round-22)。
3 文とも「exports `EDITOR` **from** `/etc/set-environment`」と書いているが、
**シェルの init が literal に source しているのはストアパスの方**である:

```
$NIXPKGS/nixos/modules/programs/bash/bash.nix:133-135
      shellInit = ''
        if [ -z "$__NIXOS_SET_ENVIRONMENT_DONE" ]; then
            . ${config.system.build.setEnvironment}
```

`zsh.nix:195` も `fish.nix:208` も同じ形である。`/etc/set-environment` は
**同じファイルへの別の入口**で、`shells-environment.nix:246-248` が
`environment.etc` として張っている:

```
$NIXPKGS/nixos/modules/config/shells-environment.nix:246-248
    # For resetting environment with `. /etc/set-environment` when needed
    # and discoverability (see motivation of #30418).
    environment.etc.set-environment.source = config.system.build.setEnvironment;
```

**中身はバイト単位で同一**(`source` が同じ derivation を指している)であり、
実機では `cat /etc/set-environment` に `export EDITOR="nano"` がそのまま出る(R5)。
**したがって「定義が `/etc/set-environment` に landsする」も「そこから export される」も
文として正しく、出荷文は 1 文字も変えない。**
**ここに書いておくのは、これが唯一「名指ししたパスとシェルが literal に source するパスが
別」な箇所だから**である —— 将来のレビューがこれを「誤り」として発見し直し、
`${config.system.build.setEnvironment}` のようなストアパスを出荷文に書き込むことがないように。
**読者に渡すべきは `cat` できる方のパスである。**

**(e) GUI セッションも見る —— issue 本文と skeleton の想定は誤りだった。**
`nixos/modules/services/x11/display-managers/default.nix:63-139` の `xsessionWrapper`(引用は先頭の `:63-71`)
(自身のコメントが "Shared environment setup for graphical sessions")は、最初の実行文が
**`. /etc/profile`**(`:68`)で、続けて `~/.profile`(`:69-71`)を読む:

```bash
  xsessionWrapper = pkgs.writeScript "xsession-wrapper" ''
    #! ${pkgs.bash}/bin/bash

    # Shared environment setup for graphical sessions.

    . /etc/profile
    if test -f ~/.profile; then
        source ~/.profile
    fi
```

`:236` で `services.displayManager.sessionData.wrapper` に配線され、それを使うのは
gdm(`services/display-managers/gdm.nix:381`)/ sddm(`sddm.nix:101`)/ ly(`ly.nix:49`)/
lemurs(`lemurs.nix:96`)/ lightdm(`services/x11/display-managers/lightdm.nix:56`)である
(`grep -rn 'sessionData.wrapper' "$NIXPKGS/nixos/modules/"` の全 7 件 = DM 5 種 + 定義 `:236` + コメント `:62`)。
**したがって X11 セッションは `/etc/profile` を読み、`EDITOR=nano` を見る。**

**ただし「DM 経由の GUI セッションは必ず読む」とは言えない —— wrapper は主に X11 の経路である。**
実読すると:

- **gdm** —— `:381` は `environment.etc."gdm/Xsession"`。**X セッション専用**である。
- **sddm** —— `:101` の `SessionCommand = toString dmcfg.sessionData.wrapper;` は
  `// optionalAttrs xcfg.enable { X11 = { ... } }`(`:97-108`。`X11` の attrset は `:98-107`)の中。Wayland 側(`:90-94`)は
  `EnableHiDPI` / `SessionDir` / `CompositorCommand` の 3 つで、**wrapper を持たない**。
- **lightdm** —— こちらは逆で、`:56` の `session-wrapper` は `[Seat:*]` に効き、
  `sessions-directory`(`:51`)に `xsessions` と `wayland-sessions` の**両方**が並んでいる。
  lightdm の Wayland セッションは wrapper を通りうる。ly / lemurs は未確認。

**つまり DM ごとにばらばらである。** gdm / sddm の Wayland セッション —— 今日の GNOME / KDE の
既定 —— は `xsessionWrapper` を走らせず、`/etc/pam/environment` にも `EDITOR` は無い(§1.4)ので、
**そこでは NixOS の `EDITOR` はどこからも来ない**。issue 本文の「GUI は見ない」は
**X11 では偽、gdm / sddm の Wayland では真**である。

systemd user unit 側は `importedVariables` の既定(`:240-248`)が
`DBUS_SESSION_BUS_ADDRESS` / `DISPLAY` / `XAUTHORITY` / `XDG_SESSION_ID` の 4 つ
—— ただしセッション環境を継承する unit はその限りではない。

**この場当たりな分岐そのものが、GUI の話を出荷文に 1 文字も書かない根拠である**(§3.2 決定 3)。
正しく書こうとすると「X11 なら / gdm・sddm の Wayland なら / lightdm なら」と 3 分岐し、
どれも DM の実装詳細に依存する。読者の行動は 1 つも変わらない。

### 1.4 実測(pinned nixpkgs、最小 `nixosSystem`)

issue 本文の表をそのまま再現した。**出力は逐語**である:

```
$ nix eval --impure --json --expr '
let
  flake = builtins.getFlake (toString ./.);
  nixpkgs = flake.inputs.nixpkgs;
  mk = extra: (nixpkgs.lib.nixosSystem {
    system = "x86_64-linux";
    modules = [
      { boot.loader.grub.enable = false; fileSystems."/" = { device = "none"; fsType = "tmpfs"; }; system.stateVersion = "25.05"; nixpkgs.hostPlatform = "x86_64-linux"; }
      extra
    ];
  }).config.environment.variables;
in {
  baseline      = (mk {}).EDITOR or null;
  forcedNull    = (mk { environment.variables.EDITOR = nixpkgs.lib.mkForce null; }) ? EDITOR;
  plainOverride = (mk { environment.variables.EDITOR = "nvim"; }).EDITOR or null;
  nanoDisabled  = (mk { programs.nano.enable = false; }).EDITOR or null;
}'
{"baseline":"nano","forcedNull":false,"nanoDisabled":"nano","plainOverride":"nvim"}
```

| config | `config.environment.variables.EDITOR` |
|---|---|
| baseline | `"nano"` |
| `programs.nano.enable = false` | `"nano"`(§1.2 の 4) |
| `environment.variables.EDITOR = "nvim"` | `"nvim"`(素の定義は priority 100、`mkDefault` は 1000) |
| `environment.variables.EDITOR = lib.mkForce null` | **属性そのものが消える** |

**issue 本文より一段先まで測った。** 上は option の値しか見ていないので、生成されるファイルの
**中身**も見た。これが §3.2 の段落の「定義は `/etc/set-environment` に落ちて
`/etc/pam/environment` には落ちない」を支える実測なので、**式も逐語で残す**:

```
$ nix eval --impure --json --expr '
let
  flake = builtins.getFlake (toString ./.);
  nixpkgs = flake.inputs.nixpkgs;
  mk = extra: (nixpkgs.lib.nixosSystem {
    system = "x86_64-linux";
    modules = [
      { boot.loader.grub.enable = false; fileSystems."/" = { device = "none"; fsType = "tmpfs"; }; system.stateVersion = "25.05"; nixpkgs.hostPlatform = "x86_64-linux"; }
      extra
    ];
  }).config;
  grepEDITOR = text: builtins.filter (s: builtins.isString s && builtins.match ".*EDITOR.*" s != null) (builtins.split "\n" text);
  base   = mk { };
  forced = mk { environment.variables.EDITOR = nixpkgs.lib.mkForce null; };
in {
  baseSetEnvEDITOR   = grepEDITOR base.system.build.setEnvironment.text;
  forcedSetEnvEDITOR = grepEDITOR forced.system.build.setEnvironment.text;
  basePamEDITOR      = grepEDITOR base.environment.etc."pam/environment".text;
  baseSessionVars    = builtins.attrNames base.environment.sessionVariables;
}'
{"basePamEDITOR":[],
 "baseSessionVars":["GTK_A11Y","LANG","LOCALE_ARCHIVE","NIX_PATH","NO_AT_BRIDGE","TZDIR","XCURSOR_PATH","XDG_CONFIG_DIRS"],
 "baseSetEnvEDITOR":["export EDITOR=\"nano\""],
 "forcedSetEnvEDITOR":[]}
```

`/etc/set-environment` に **`export EDITOR="nano"` の 1 行が実在**し、`mkForce null` で**その行ごと消える**。
`/etc/pam/environment` に `EDITOR` は**現れない**し、`environment.sessionVariables` にも**無い**
(§1.3(b) の裏取り)。

**なぜ `mkForce null` で消えるのか**は `environment.variables` の `apply`(`shells-environment.nix:88-95`):

```nix
      apply =
        let
          toStr = v: if lib.isPath v then "${v}" else toString v;
        in
        attrs:
        lib.mapAttrs (n: v: if lib.isList v then lib.concatMapStringsSep ":" toStr v else toStr v) (
          lib.filterAttrs (n: v: v != null) attrs
        );
```

`:94` の `lib.filterAttrs (n: v: v != null)` が null を落とす。型も `nullOr` を許しており(`:74-87`)、
description(`:71-72`)も「Setting a variable to `null` does nothing. You can override a variable set
by another module to `null` to unset it.」と明言している。**設計された取り消し口である。**

**ただし「取り消し」は「修正」ではない。これが round-5 で潰した 7 つ目の誤りである**(§3.2 決定 14)。
4 つの NixOS 設定で、生成されるファイルの中身を直接比べた:

```
$ nix eval --impure --json --expr '
let
  flake = builtins.getFlake (toString ./.);
  nixpkgs = flake.inputs.nixpkgs;
  mk = extra: (nixpkgs.lib.nixosSystem {
    system = "x86_64-linux";
    modules = [
      { boot.loader.grub.enable = false; fileSystems."/" = { device = "none"; fsType = "tmpfs"; }; system.stateVersion = "25.05"; nixpkgs.hostPlatform = "x86_64-linux"; }
      extra
    ];
  }).config;
  g = text: builtins.filter (s: builtins.isString s && builtins.match ".*EDITOR.*" s != null) (builtins.split "\n" text);
  shot = c: { setEnv = g c.system.build.setEnvironment.text; pam = g c.environment.etc."pam/environment".text; opt = c.environment.variables.EDITOR or "<absent>"; };
in {
  baseline    = shot (mk { });
  forcedNull  = shot (mk { environment.variables.EDITOR = nixpkgs.lib.mkForce null; });
  setToNvim   = shot (mk { environment.variables.EDITOR = "nvim"; });
  sessionNvim = shot (mk { environment.sessionVariables.EDITOR = "nvim"; });
}'
{"baseline"   :{"opt":"nano",     "pam":[],                        "setEnv":["export EDITOR=\"nano\""]},
 "forcedNull" :{"opt":"<absent>", "pam":[],                        "setEnv":[]},
 "setToNvim"  :{"opt":"nvim",     "pam":[],                        "setEnv":["export EDITOR=\"nvim\""]},
 "sessionNvim":{"opt":"nvim",     "pam":["EDITOR   DEFAULT=\"nvim\""],"setEnv":["export EDITOR=\"nvim\""]}}
```

| NixOS 側に書く 1 行 | `/etc/set-environment` | `/etc/pam/environment` | 管理外シェルでの `EDITOR` |
|---|---|---|---|
| (何も書かない) | `export EDITOR="nano"` | —— | `nano` |
| `environment.variables.EDITOR = lib.mkForce null;` | **行ごと消える** | —— | **未設定**(`nvim` にはならない) |
| `environment.variables.EDITOR = "nvim";` | `export EDITOR="nvim"` | —— | `nvim` |
| `environment.sessionVariables.EDITOR = "nvim";` | `export EDITOR="nvim"` | `EDITOR DEFAULT="nvim"` | `nvim`(**PAM 経由なので Wayland にも届く**) |

**`mkForce null` は `nvim` を一度も生まない。** `nano` だった場所が**未設定**になるだけである。
つまり round-4 までの表の行が言っていた「one line on the NixOS side **does** [resolve it]」は
**偽**だった —— 名指していたのが取り消し側の 1 行だったからである。
`nvim` を得る手段は **(a) home-manager にそのシェルを管理させる**(`defaultEditor` が効くようになる)か、
**(b) `environment.variables.EDITOR = "nvim";`** の 2 つである。

**4 行目は出荷文に書かない。** `sessionVariables` は PAM にも届くので §1.3(e) の Wayland の穴まで
塞げる唯一の手段だが、それを書くと決定 3 が閉じた GUI の話を開け直すことになる。ここに記録する。

### 1.5 home-manager 側 —— 通るのは「home-manager が管理するシェル」だけ

`hm-session-vars.sh` の生成は `$HM/modules/home-environment.nix:660-677`。読ませる側は
`programs.bash` / `programs.zsh` / `programs.fish` の 3 つ —— FAQ が名指しするのも
この 3 つである(**`modules/` 全体で `hm-session-vars` を読む箇所は 5 件** —— これに
`xsession.nix:210` と `targets/generic-linux.nix:80` が加わる。R3)。**経路もファイル名も**
**シェルごとに違う** ——
`modules/programs/bash.nix:268-274`(`~/.profile` を書き、その 1 行目が `hm-session-vars.sh`)、
`modules/programs/zsh/default.nix:422-424`、そして
**fish は `hm-session-vars.fish`**(`modules/programs/fish.nix:406-414` が babelfish で `.sh` から
生成し、`:760` で配る)。**「`hm-session-vars.sh` をすべての管理シェルが source する」は正確ではない**
(§3.2 決定 11)。

**`~/.profile` も bash だけのものである。** 実測:

```
$ grep -rn 'home.file.".profile"' "$HM/modules/"
modules/programs/bash.nix:268:      home.file.".profile".source = writeBashScript "profile" ''
```

**1 件しか無い。** 出荷文に `~/.profile` と書くと zsh / fish のユーザが home-manager の書いていない
ファイルを探しに行く(§3.2 決定 5。**NixOS 側の `/etc/profile` にも同じ話が当てはまる** —— §1.3(d))。

そして **home-manager の `programs.bash.enable` は `lib.mkEnableOption`(`bash.nix:43`)= 既定 `false`**
である。NixOS 側の `programs.bash.enable` が既定 `true`(§1.3(d))なのと**非対称**であり、
これが本件の症状そのものを作る。

home-manager 自身がこれを FAQ に書いている。`docs/manual/faq/session-variables.md:1-6` を逐語で
(続く `:8-27` は「管理させないなら自分で source しろ」という手順で、`.profile` / `.zshrc` /
fenv / babelfish の具体例まで載っている。その中にコードフェンスが入るため引用はここで切るが、
**`:8-27` の存在は §3.2 決定 6 と §3.5(A2) の両方で効く**):

```
# Why are the session variables not set? {#_why_are_the_session_variables_not_set}

Home Manager is only able to set session variables automatically if it
manages your Bash, Z shell, or fish shell configuration. To enable such
management you use [programs.bash.enable](#opt-programs.bash.enable),
[programs.zsh.enable](#opt-programs.zsh.enable), or [programs.fish.enable](#opt-programs.fish.enable).
```

**順序**: NixOS 側の init(bash なら `/etc/profile`、zsh なら `/etc/zshenv`、fish なら preinit)は
どれもユーザのファイルより先に走る。home-manager がそのシェルを管理していれば `EDITOR=nano` の
**後**に `EDITOR=nvim` が export され、**`nvim` が勝つ**。管理していなければ home-manager の行が
どこにも無く、`nano` が唯一の定義として残る。

**ただし bash にだけ穴がある。これは pinned tree から測れるので出荷文に反映する**(§3.2 決定 13)。
**home-manager が session vars を書き込むファイルはシェルごとに違い、bash だけがログイン鎖の中にある**:

| シェル | home-manager が書く場所 | 非ログインの対話シェルで読まれるか |
|---|---|---|
| bash | `~/.profile` だけ(`bash.nix:268-274`。`sessionVarsStr` は `:271` の 1 箇所のみで、`~/.bashrc`(`:276-289`)には**入らない**) | **読まれない** |
| zsh | `.zshenv`(`zsh/default.nix:563-567`。`if [[ ! -o login ]]` で非ログイン時に)と `.zprofile`(`:569-570`。ログイン時に) | 読まれる |
| fish | `~/.config/fish/config.fish`(`fish.nix:752`、source は `:760`) | 読まれる |

一方 NixOS 側は非ログインの bash も拾う —— `/etc/bashrc`(`programs/bash/bash.nix:180-203`)が
`:190-192` で `if [ -z "$__ETC_PROFILE_DONE" ]; then . /etc/profile; fi` を持ち、nixpkgs の bash は
`-DSYS_BASHRC="/etc/bashrc"`(`pkgs/shells/bash/5.nix:65`)でビルドされている。
**`:190-192` は `:195` の `if [ -n "$PS1" ]` ガードの外にある** —— 対話性の条件は
ファイル側ではなく bash 側にあり、bash が `SYS_BASHRC` を読むのは
**非ログインかつ対話**のときだけである。

**帰結**: home-manager が管理している bash であっても、**クリーンな環境から起動した非ログイン bash は
`~/.profile` に到達せず、`defaultEditor` が効かない。** ここで「そのシェルは home-manager に
管理されていないはずだ」と読ませるのは**誤診断**である。

**§1.7 で実シェルを走らせて確認した**。穴があるのは**非ログイン**の 2 セルだけである:

- **ログイン(対話・非対話とも)** —— 穴は無い。**`nixpkgs` の bash は
  `-DNON_INTERACTIVE_LOGIN_SHELLS` 付きでビルドされている**
  (`pkgs/shells/bash/5.nix:74`。既出の `-DSSH_SOURCE_BASHRC` `:75` の 1 行上)ので、
  **非対話のログインシェルも `/etc/profile` を読む** —— §1.7 のグリッドが
  `login × non-interactive` の行を持たないのはこのためで、`login × interactive` に潰れる。
  実測: `env -i bash -lc` は `__ETC_PROFILE_DONE=1` かつ hm 管理下で `EDITOR=nvim`、
  対照の `bash -c </dev/null` は両方とも未設定。
  出荷文の「ログインシェルでない bash」という主語はこの事実に乗っている。
- **非ログイン・対話** —— `/etc/bashrc`(`SYS_BASHRC`)→ `/etc/profile` → **`nano`**。
- **非ログイン・非対話** —— **stdin 次第**である。パイプや `/dev/null` なら何も読まれず
  **未設定**、**ソケットなら `/etc/bashrc` が読まれて `nano`** になる。
  bash の `run_startup_files()` が `run_by_ssh || isnetconn(fileno(stdin))` を見るためである。
  nixpkgs の bash は `-DSSH_SOURCE_BASHRC` 付き(`pkgs/shells/bash/5.nix:75`)なので
  **実 ssh は `SSH_CLIENT` だけで前者が真になり、stdin を問わず `/etc/bashrc` を読む**。
  §1.7 の 10 セル目は `socat` のソケットで前者を偽・後者を真にして測ったもので、
  **実 ssh は両方が真になるので、その行より弱くはならない**(§1.7 の 10 セル目の注記)。

**どちらにせよ `defaultEditor` は効かない。したがって「except in a non-login *interactive* bash」
では 1 セル足りない。** round-5 までの出荷文は対話の側しか除外していなかった。
**主語を「ログインシェルでない bash」に広げるのが正しい** —— 2 セルの両方を、
しかも stdin がどちらでも、1 語で覆える:

出荷文は **"except in a bash started from a clean environment that is not a login shell"**。
**"started from a clean environment" は落とせない** —— 親から `EDITOR` を継承していればそれが残る。
**その実測は §1.7 の「対照(`env -i` を外した場合)」のブロックである** —— 2 セルだけを
測っており、どちらも呼び出し元の値(`CALLER-LEAK`)になる。全セルを測ったわけではないし、
継承そのものを本表の 1 セルとして持っているわけでもないので、そう引用すること。
典型例は §1.3(e) の X11 セッションで、`xsessionWrapper` が既に `~/.profile` を読んでいる。
**機構(`/etc/bashrc` / `/etc/profile`)は出荷文に書かない** —— 2 セルで機構が違ううえ
非対話側は stdin にも依存するので、書けば必ずどこかで偽になる。
「`~/.profile` に到達しない」だけが全部に当てはまる。

> **もう 1 つの bash の穴**(こちらは測っていないので出荷文に書かない。R5):
> bash はログインシェルで `/etc/profile` を読んだあと、`~/.bash_profile` / `~/.bash_login` /
> `~/.profile` のうち**最初に存在したものだけ**を読む。home-manager が bash を管理していれば
> `~/.bash_profile` を自分で書き(`bash.nix:249-255`)、その `:251` が
> `[[ -f ~/.profile ]] && . ~/.profile` なので鎖がつながる。
> **ユーザが自前の `~/.bash_profile` を持っていて home-manager の生成物で上書きしていない場合**、
> `~/.profile` は読まれず、home-manager が bash を管理していても `nano` が残りうる。

### 1.6 home-manager はこの衝突について**何も書いていない**(grep で確認)

pinned home-manager の `modules/` / `docs/` / `nixos/` を横断して:

| 探したもの | 結果 |
|---|---|
| `nano` | **0 件**(`grep -rni 'nano' "$HM/modules/" "$HM/docs/" "$HM/nixos/" \| wc -l` → `0`) |
| `environment\.variables`(**エスケープして** option 名として探す) | **0 件**。エスケープしない `environment.variables` だと 53 件(`modules/` 50、`docs/` 3)出るが、`.` が任意 1 文字なのでヒットはすべて「environment variables」という英語の散文である |
| `/etc/profile` | `hm-session-vars.sh` / `vte.sh` / `nix.sh` などの sourcing だけ。NixOS の `/etc/profile` との関係を書いたものは 0 件 |

`assertion` も `warning` も無い。FAQ は 6 本(`ca-desrt-dconf` / `change-package-module` /
`collision` / `multiple-users-machines` / `session-variables` / `unstable`)で、NixOS との変数衝突を
扱うものは無い(`collision.md` は Nix profile の**ファイル**衝突の話)。

そして **`defaultEditor` を宣言している 7 モジュールは全部同じ形**である
(`grep -rln 'defaultEditor' "$HM/modules/" | grep -v '/news/' | wc -l` → `7`。
news エントリ `modules/misc/news/2025/12/2025-12-11_13-04-30.nix` を除いた数):

| モジュール | 宣言 | `home.sessionVariables` への書き込み | 優先度 |
|---|---|---|---|
| `modules/programs/vim.nix` | `:158` | `:215` `lib.mkIf cfg.defaultEditor` | 素 |
| `modules/programs/helix.nix` | `:51` | `:250` `mkIf cfg.defaultEditor` | 素 |
| `modules/programs/kakoune.nix` | `:667` | `:723` `mkIf cfg.defaultEditor` | 素 |
| `modules/programs/neovim/default.nix` | `:97` | `:569` `mkIf cfg.defaultEditor` | 素 |
| `modules/programs/fresh-editor.nix` | `:31` | `:76` `mkIf cfg.defaultEditor` | 素 |
| `modules/programs/zed-editor.nix` | `:261` | `:373` `mkIf cfg.defaultEditor editorEnv` | 素 |
| `modules/services/emacs.nix` | `:110` | `:129` `mkIf cfg.defaultEditor` | 素 |

**`mkDefault` も `mkForce` も 1 つも無い**
(`grep -rn 'defaultEditor' "$HM/modules/" | grep -c 'mkDefault\|mkForce'` → `0`)。
nvimx の `:358` も同じ形である(#67 §3.2)。つまり「NixOS の `mkDefault "nano"` に対抗するために
優先度を付ける」という発想は**上流のどこにも存在しない** —— 優先度で解ける問題ではないからである(§3.1)。

> 表を 1 行ずつ当たる grep を書くときの注意:
> `grep -rn 'sessionVariables = \(lib\.\)\?mkIf cfg.defaultEditor' "$HM/modules/"` は
> **6 件しか返さない**。`modules/services/emacs.nix:129` だけ `mkIf cfg.defaultEditor {` が
> 別行に置かれているためである(`:125-132` を目で見ること)。**件数は上の 7 が正しい。**

---

### 1.7 §1.5 の表をどう測ったか —— **記録であって手順ではない**

§1.2-§1.6 はすべて **option の値か生成されるファイルの中身**しか見ていない。
「そのファイルをどのシェルがどの順で読むか」はそこには現れず、**remedy に関する誤り
(冒頭の 8-11)は全部そこにあった**。本節はそれを測った装置と結果の**記録**である。

> **§8 はこれの再実行を要求しない。意図的にそうしてある。**
> 実装者がするのは「3 つの文面を貼って `nix fmt` / `nix flake check` を通す」ことであり、
> この装置を再現する必要はない。そのうえ:
> - **装置自身が 2 度壊れた状態で計画に載った。** 7 回目のレビューが 20 値中 7 値の
>   再現失敗を見つけ、8 回目が更に 2 つ見つけている(下の「黙って嘘をつくもの」)。
> - **`ssh` 越しに流すと 4 セルが正当な理由で変わる**(stdin、下記)。
>   それを「前提が崩れた」と読ませる手順にしてはいけない。
> - このリポジトリの他の計画はシェルハーネスを 1 つも持っていない。
>
> **出荷文が主張することはすべて下の表が裏付けている。表には取得条件が併記してある** ——
> stdin、`env -i` の位置、`/run` の bind、`--setenv SHELL`。
> **条件を変えて測り直したなら、まずその 4 つを疑うこと。**

#### 材料(リポジトリの外で作業する)

```bash
W=$(mktemp -d); cd "$W"; NVIMX=/home/myuron/ghq/github.com/myuron/nvimx
etc () { nix build --no-link --print-out-paths --impure --expr '
  let flake = builtins.getFlake (toString '"$NVIMX"'); nixpkgs = flake.inputs.nixpkgs;
  in (nixpkgs.lib.nixosSystem { system = "x86_64-linux"; modules = [
       { boot.loader.grub.enable = false; fileSystems."/" = { device = "none"; fsType = "tmpfs"; };
         system.stateVersion = "25.05"; nixpkgs.hostPlatform = "x86_64-linux";
         programs.zsh.enable = true; programs.fish.enable = true; }
       '"$1"' ]; }).config.system.build.etc'; }
ETC0=$(etc '{ }'); ETC1=$(etc '{ environment.variables.EDITOR = "nvim"; }')
grep -n EDITOR $ETC0/etc/set-environment $ETC1/etc/set-environment   # → :6 nano / :6 nvim
hmf () { nix build --no-link --print-out-paths --impure --expr '
  let flake = builtins.getFlake (toString '"$NVIMX"');
      pkgs = import flake.inputs.nixpkgs { system = "x86_64-linux"; };
  in (flake.inputs.home-manager.lib.homeManagerConfiguration { inherit pkgs; modules = [ {
       home.username = "alice"; home.homeDirectory = "/home/alice"; home.stateVersion = "25.05";
       home.sessionVariables.EDITOR = "nvim"; } '"$1"' ]; }).config.home-files'; }
HMY=$(hmf '{ programs.bash.enable = true; programs.zsh.enable = true; programs.fish.enable = true; }')
HMN=$(hmf '{ }')
SH=$(nix build --no-link --print-out-paths --impure --expr '
  let flake = builtins.getFlake (toString '"$NVIMX"');
      pkgs = import flake.inputs.nixpkgs { system = "x86_64-linux"; };
  in pkgs.buildEnv { name = "shells"; paths = with pkgs;
       [ bashInteractive zsh fish coreutils util-linux ]; }')
```

#### 1 セルを測るスクリプト(`cell.sh`)

```bash
cat > cell.sh <<'EOS'
#!/usr/bin/env bash
# cell.sh <etc> <homeFiles> <shellsEnv> <bash|zsh|fish> <login|nonlogin> <int|noint> [null|keep]
set -u
BW=$(command -v bwrap); ETC=$1; HOME_D=$2; SH=$3; shell=$4; login=$5; inter=$6; sin=${7:-null}
flags=""; [ "$login" = login ] && flags="$flags -l"; [ "$inter" = int ] && flags="$flags -i"
if [ "$shell" = fish ]; then
  body='if set -q EDITOR; echo "EDITOR=[$EDITOR]"; else; echo "EDITOR=[<unset>]"; end'
else body='echo "EDITOR=[${EDITOR-<unset>}]"'; fi
run=$(mktemp); printf '#!%s/bin/bash\nexec %s %s -c %s\n' "$SH" "$shell" "$flags" "'$body'" > "$run"
chmod +x "$run"
if [ "$inter" = int ]; then outer="script -qec /run.sh /dev/null"; else outer="/run.sh"; fi
box=("$BW" --ro-bind /nix/store /nix/store --ro-bind "$ETC/etc" /etc \
     --ro-bind "$HOME_D" /home/alice --ro-bind "$run" /run.sh \
     --dev /dev --proc /proc --tmpfs /tmp \
     --tmpfs /run --ro-bind "$SH" /run/current-system/sw \
     --setenv HOME /home/alice --setenv USER alice --setenv TERM dumb \
     --setenv SHELL "$SH/bin/bash" --setenv PATH "$SH/bin" \
     --unshare-all --die-with-parent -- "$SH/bin/bash" --noprofile --norc -c "$outer")
case "$sin" in
  null) out=$(env -i "${box[@]}" </dev/null 2>&1) ;;
  keep) out=$(      "${box[@]}" </dev/null 2>&1) ;;   # env -i を外した対照
esac
hit=$(printf '%s' "$out" | tr -d '\r' | grep -o 'EDITOR=\[[^]]*\]' | head -1)
# 1 つも取れなかったら空セルにせず全出力を出す。空セルは「未設定」と区別がつかない。
[ -n "$hit" ] && printf '%s\n' "$hit" || { echo "NO-MATCH:"; printf '%s\n' "$out"; }
rm -f "$run"
EOS
chmod +x cell.sh
```

#### 無いと黙って嘘をつくもの(4 つ。すべて実際に踏んだ)

1. **`</dev/null`** —— nixpkgs の bash は `-DSYS_BASHRC` 付きで、`run_startup_files()` は
   **非ログイン非対話の `bash -c` でも** `run_by_ssh || isnetconn(fileno(stdin))` なら
   `/etc/bashrc` を読む。**stdin がソケットかどうかで 4 セルが変わる**(10 セル目)。
2. **`--tmpfs /run --ro-bind "$SH" /run/current-system/sw`** ——
   `/etc/set-environment` は `PATH` に `/run/current-system/sw/bin` を**再 export する**。
   無いと fish の `nixos-env-preinit.fish` が呼ぶ `fenv` が `env: command not found` で死に、
   **fish は NixOS の `EDITOR` を一度も拾わない**。6 回目までの表はこの状態で fish の 6 セルが
   空欄のまま載り、しかも**そのうち 1 つに測っていない `nvim` が書かれていた**。
3. **`--setenv SHELL "$SH/bin/bash"`** —— 落とすと名前空間の中の `script` が
   `$SHELL` も `/etc/passwd` も持たず、自己診断の環境が 8 行ではなく **7 行**になる(実測)。
4. **`env -i` を `bwrap` の**直前**に置くこと** —— 下の枠。

> **pty を外に出すこと自体は原因ではない。原因は `env -i` と `bwrap` のあいだに
> 環境を作り直すものを挟むことである。** `script -c CMD` は **`$SHELL`**(未設定なら
> `/etc/passwd` の login shell)経由で `CMD` を exec する。`env -i` は **`$SHELL` を消す**ので、
> `env -i script ...` と書くと passwd 側の shell(この機械では fish)に落ち、
> それが設定を読んで環境を作り直し、**`bwrap` がそれをそのまま子に渡す**
> (`bwrap` は既定で環境を消さず、`--setenv` は**足す**だけである)。実測、子プロセスの環境変数の数:
>
> | 書き方 | 子の環境 |
> |---|---|
> | pty 内側、`env -i bwrap ...` | **8**(clean) |
> | pty 外側、`env -i script -qec "bwrap ..."` | **46** —— `EDITOR=nvim` / `__HM_SESS_VARS_SOURCED=1` / `__NIXOS_SET_ENVIRONMENT_DONE=1` 込み |
> | pty 外側、`script -qec "env -i bwrap ..."` | **8**(clean) |
> | pty 外側、`env -i SHELL=$SH/bin/bash script -qec "bwrap ..."` | **8**(clean) |
>
> **ホスト依存ではない。同じ 1 台で、書き方だけで決まる。**
> 6 回目のレビューは 2 行目を、7 回目は 3 行目を測っており、どちらも正しかった。
> `__ETC_PROFILE_DONE` が入ると `/etc/bashrc:190` が `/etc/profile` を読み飛ばすので、
> **食い違うはずのセルが一様になる**。ただし後述のとおり、**その一様性も自動では検出できない。**

#### 自己診断 —— **これは guard ではない**

```bash
probe=$(mktemp); printf '#!%s/bin/bash\nexec env\n' "$SH" > $probe; chmod +x $probe
env -i $(command -v bwrap) --ro-bind /nix/store /nix/store --ro-bind "$ETC0/etc" /etc \
  --ro-bind "$HMY" /home/alice --ro-bind "$probe" /run.sh --dev /dev --proc /proc \
  --tmpfs /tmp --tmpfs /run --ro-bind "$SH" /run/current-system/sw \
  --setenv HOME /home/alice --setenv USER alice --setenv TERM dumb \
  --setenv SHELL "$SH/bin/bash" --setenv PATH "$SH/bin" --unshare-all --die-with-parent \
  -- "$SH/bin/bash" --noprofile --norc -c /run.sh </dev/null | sort
```

HOME / PATH / PWD / SHELL / SHLVL / TERM / USER / `_` の **8 行**が出れば、
**`env -i` を含まない経路**については汚染が無いと言える。**それ以上は言えない** ——
8 回目のレビューが実測したとおり:

- **pty を外に出して `env -i` を外側に置いた壊れ方は、この診断では検出できない。**
  診断自体は pty を通らないので 8 行のまま通り、その裏で**対話 12 セルのうち 7 つが捏造される**。
- **`/run` の bind 忘れも検出できない**(fish の 3 セルが黙って狂い、診断は 8 行)。
- 理由は単純で、**この診断は `box` から導出されておらず、同じ引数を手で書き写したもの**だからである。

**だからこれを「通せば安全」の関門として使わないこと。**
本節を再実行するなら、**表の 40 値を丸ごと突き合わせるのが唯一の検証である**。

#### 実測(逐語。取得条件: stdin = `/dev/null`、`env -i` は `bwrap` の直前、`/run` bind あり、`--setenv SHELL` あり)

| セル | baseline + hm 管理 | baseline + hm 管理外 | `="nvim"` + hm 管理 | `="nvim"` + hm 管理外 |
|---|---|---|---|---|
| bash login interactive | `nvim` | `nano` | `nvim` | `nvim` |
| **bash non-login interactive** | **`nano`** | `nano` | **`nvim`** | `nvim` |
| **bash non-login non-interactive** | **`<unset>`** | **`<unset>`** | **`<unset>`** | **`<unset>`** |
| zsh login interactive | `nvim` | `nano` | `nvim` | `nvim` |
| zsh non-login interactive | `nvim` | `nano` | `nvim` | `nvim` |
| zsh non-login non-interactive | `nvim` | `nano` | `nvim` | `nvim` |
| fish login interactive | `nvim` | `nano` | `nvim` | `nvim` |
| fish non-login interactive | `nvim` | `nano` | `nvim` | `nvim` |
| fish non-login non-interactive | `nvim` | `nano` | `nvim` | `nvim` |

**10 セル目: stdin がソケットのとき。** 上の表で唯一 stdin に依存する
`bash non-login non-interactive` を、stdin をソケットにして測り直したもの。
**`socat -u /dev/null 'EXEC:<runner>,socktype=1'` で取っており、実際の `ssh` では測っていない。
出自はそう書くこと。** そのうえで、**実 ssh がこのセルより弱くなることはない**:

- bash が見る条件は `run_by_ssh || isnetconn(fileno(stdin))` の**論理和**である。
  socat のハーネスが起こしているのは `isnetconn` の側だけで、しかも
  **`env -i` が `SSH_CLIENT` を消すので `run_by_ssh` は常に偽**になっている
  —— つまり非 socket 側で出た `<unset>` は「ssh ではないクリーンな呼び出し」のセルとして正しい。
- **nixpkgs の bash は `-DSSH_SOURCE_BASHRC` 付きでビルドされている**
  (`pkgs/shells/bash/5.nix:75`。既出の `-DSYS_BASHRC` は `:65` で、その 10 行下)。
  よって実 ssh では `run_by_ssh` が `SSH_CLIENT` だけで真になり、stdin の種類を問わず
  `/etc/bashrc` が読まれる。**両方が真になるので、実 ssh はこの行と同じか、より強い。**
- なお OpenSSH の `do_exec_no_pty` は Linux で `socketpair(AF_UNIX, SOCK_STREAM)` を使う ——
  `socktype=1` が再現しているのはまさにそれである。
- **出荷文は `ssh` という語を 1 度も使っていない**ので、この行がどちらに転んでも動かない。

| セル | baseline + hm 管理 | baseline + hm 管理外 | `="nvim"` + hm 管理 | `="nvim"` + hm 管理外 |
|---|---|---|---|---|
| bash non-login non-interactive, **stdin = socket** | `nano` | `nano` | `nvim` | `nvim` |

**そして素の NixOS の `/etc`**(`programs.zsh.enable` を立てない。§1.3(d) の `baseline`)で
home-manager も管理していない zsh は **`EDITOR` 未設定** —— `/etc/zshenv` が無いからである。

**対照(`env -i` を外した場合)。呼び出し元の値をそのまま拾うので、
呼び出し元に依存しない値を入れて測る:**

```bash
EDITOR=CALLER-LEAK ./cell.sh $ETC1 $HMY $SH zsh nonlogin noint keep   # → EDITOR=[CALLER-LEAK]
EDITOR=CALLER-LEAK ./cell.sh $ETC1 $HMY $SH bash login    int  keep   # → EDITOR=[CALLER-LEAK]
```

正しくはどちらも `nvim` である。**「食い違うはずのセルが一様に呼び出し元の値になる」のが徴候**だが、
**呼び出し元の `EDITOR` がたまたま期待値と一致していると、この徴候も出ない** ——
R5 が言う「ログインの fish が `nvim`」の機械では、`nvim` になるべきセルの漏洩は見分けがつかない。
だから上のように**外部から見分けのつく値を入れて**測る。

#### 結論(どれも `nix eval` からは見えなかった)

1. **`defaultEditor`(= home-manager に管理させる)は「ログインシェルでない bash」を覆わない。**
   対話では `nano`、非対話では stdin 次第で未設定か `nano` になる。zsh / fish は 3 セルとも覆う。
2. **`environment.variables.EDITOR = "nvim";` は「何かが読まれるセル」を覆う。**
   覆えないのは**どの定義も読まれないセル**(bash 非ログイン非対話・stdin が非ソケット)だけで、
   そこは親からの継承がすべてである。
   **セル数を固定して書かないこと** —— stdin で変わる。出荷文が
   "wherever **any definition** is read at all" と条件で書いてあるのはこのためである。
   **round-15 まで "wherever anything is read at all" と書いていた** —— 制限子が落ちており、
   この結論 2 自身の「どの**定義**も読まれないセル」と食い違っていた(誤り 27)。
   **そのセルは「hm 管理外」でもあるので、description の "reaches both shells" にも
   同じ条件が要る**(決定 15。`both` → `both shells` は誤り 28)。
3. したがって **2 つの remedy は等価ではない。** 出荷文は (2) を先に、(1) を例外付きで後に置く
   (§3.2 決定 15)。
---

## 2. ゴール

1. **3 ファイルに書かれている。** `grep -c 'nano' docs/architecture.md README.md nix/home-manager/default.nix`
   → `2` / `1` / `3`(grep は**行数**を数える。§8 手順 6c と同じ値)。
2. **効く remedy が名指しされている。** `environment.variables.EDITOR = "nvim";` が
   `docs/architecture.md` の表の行と段落に、description に 1 回載る ——
   「**どれかの定義が**読まれるセル」を覆う 1 行である
   (**セル数は stdin で変わるので書かない**。§1.7 結論 2。
   「何かが読まれる」では広すぎて偽になる —— 誤り 27)。
   **「唯一の」とは書かない** —— §1.4 の実測の 4 行目のとおり
   `environment.sessionVariables.EDITOR = "nvim";` は `shells-environment.nix:231` 経由で
   `environment.variables` にも priority 100 で入るので、**同じセルを全部覆ったうえに PAM にも届く**
   (§1.4 はそれを Wayland の穴を塞ぐ「唯一の手段」と呼んでおり、2 つの「唯一」は両立しない)。
   出荷しないのは決定 3 が GUI の話を閉じたからであって、効かないからではない。
   **`lib.mkForce null` は「fix ではない」と明記した上で
   段落と description にだけ残り、表の行と README には出ない**(§3.2 決定 14)。
   なお goal で引く `environment.variables.EDITOR = "nvim";` の末尾のセミコロンは
   **architecture.md 側の表記**である —— description はバッククォート無しの散文なので
   `environment.variables.EDITOR = "nvim"` とセミコロン無しで書く(§3.4 決定 3)。
3. **「nvimx には直せない」と理由がセットで書かれている**(別のモジュールシステム、定義はマージされず、
   決めるのはシェルの export 順だけ)。
4. **誤ったことを書いていない。** 冒頭に挙げた 29 個 —— (1) GUI、(2) `/etc/profile`、
   (3)「every shell」、(4) 存在しない `/etc/zshenv`、(5) 非ログイン bash、(6) その条件落ち、
   (7) **効かない remedy**、(8) **2 つの remedy を等価に並べたこと**、
   (9) **非ログイン非対話 bash の取りこぼし**、(10) **`nano`/未設定 の数え上げ**、
   (11) **description の無条件な "reaches both"**、
   (12) **表の行の無スコープな「home-manager に管理させる」**、
   (13) **その列挙を同格句に置いたこと(掛かり先が手段側になる)**、
   (14) **強い remedy の数量詞の粒度(プログラム量化 vs 状況量化)**、
   (15) **段落の非制限 `, which` が `a login shell` を先行詞に取って事実の逆を述べたこと**、
   (16-24) **段落と description の掛かり先・VP 省略・代名詞の 9 件**(手順 5b。決定 19)、
   (25) **`theirs` が「NixOS and home-manager」を取って整形式で偽になったこと**(同)、
   (26) **description の `it` が `nano` を取って整形式で偽になったこと**(同)、
   (27) **"wherever anything is read at all" の制限子落ち**(§1.7 結論 2)、
   (28) **代用形の網羅掃き出しで見つかった 10 の束縛点**(手順 5b。決定 20)、
   (29) **決定 10 が命じた不定冠詞が表の行と description の両方で `the` のままだったこと**
   (誤り 30 は出荷文ではなく決定の側の誤りなので、この一覧には入らない)
   (決定 21) —— が出荷文に 1 つも無い(13 / 14 は決定 18 で節ごと削除、15 / 16-26 は決定 19 の
   組み直しで、27 / 28 は決定 20 の掃き出しで、29 は決定 21 で解消)。
   **この達成を grep で確認しきれるとは考えないこと**(§6.1(b))—— §8 手順 6a は既知の
   文字列しか見ず、14 個は §1 の再導出で、**14 個(13 / 15 / 16-26 / 28)は構文として読んだときにだけ**、
   **29 は決定との突き合わせでだけ**出ている。
   特に 7-14(remedy 系)は**文字列としては何も禁止されていない** —— 正しい remedy と
   誤った remedy は同じ語彙で書かれるので、`grep` で区別する方法が原理的に無い。
5. **コードもテストも増えない。** `git diff --stat` が 3 ファイルのみ。`flake.nix` は**差分ゼロ**。
6. **derivation が 1 つも動かない。** 34 件の drvPath が変更前とバイト一致(§4.2 で実測済み)。
7. **CI が通る。** `nix fmt -- --ci` と `nix flake check` がグリーン。

---

## 3. 設計

### 3.1 なぜ「nvimx 側の修正」が存在しないのか(出荷文すべての論旨の土台)

NixOS の `environment.variables.EDITOR` と home-manager の `home.sessionVariables.EDITOR` は
**別々の module system で評価される別々のオプション**である。path が違うどころか
**評価される fixpoint が違う**。したがって:

- **`mkForce` にしても勝てない。** 相手の定義は nvimx の fixpoint に存在しないので、優先度の比較が
  **一度も起きない**。§1.6 の 7 モジュールが全部素の `mkIf` なのはこのためである。
- **書き換えることもできない。** home-manager モジュールが出せるのは `home.*` / `xdg.*` などの
  home-manager 側の option だけで、`environment.variables` に定義を足す手段は**存在しない**。
- **唯一の接点は「シェルがどの順に export するか」**であり、それは NixOS 側の system-wide init と
  home-manager がそのシェルに source させるものの関係 —— つまり
  **home-manager がそのシェルを管理しているかどうか**に完全に還元される(§1.5)。

**ただし「NixOS の `config` が見えない」は事実ではない。** home-manager は `osConfig` / `nixosConfig` を
module 引数として渡しており、`$HM/modules/misc/submodule-support.nix:39-43` が standalone のときの
既定を `null` に置いている(直前の `:32-38` にその理由のコメントがある):

```nix
    _module.args = {
      osConfig = lib.mkDefault null;
      nixosConfig = lib.mkDefault null;
      darwinConfig = lib.mkDefault null;
    };
```

NixOS モジュール経由なら `$HM/nixos/common.nix:30` の `osConfig = config;` が上書きする。
**両方を 1 本の式で実測した**(ついでに §3.5(A2) が使う 3 つの `enable` も読んでいる。
standalone 側だけ `programs.zsh.enable = true;` を立ててある):

```
$ nix eval --impure --json --expr '
let
  flake = builtins.getFlake (toString ./.);
  nixpkgs = flake.inputs.nixpkgs; hm = flake.inputs.home-manager;
  pkgs = import nixpkgs { system = "x86_64-linux"; };
  probe = { osConfig, config, ... }: {
    home.stateVersion = "25.05";
    home.file."probe".text = builtins.toJSON {
      editor = if osConfig == null then "<osConfig is null>" else osConfig.environment.variables.EDITOR or "<none>";
      submoduleSupport = config.submoduleSupport.enable;
      hmShells = [ config.programs.bash.enable config.programs.zsh.enable config.programs.fish.enable ];
    };
  };
  viaNixos = (nixpkgs.lib.nixosSystem {
    system = "x86_64-linux";
    modules = [
      { boot.loader.grub.enable = false; fileSystems."/" = { device = "none"; fsType = "tmpfs"; }; system.stateVersion = "25.05"; nixpkgs.hostPlatform = "x86_64-linux"; users.users.alice = { isNormalUser = true; home = "/home/alice"; }; }
      hm.nixosModules.home-manager
      { home-manager.users.alice = probe; }
    ];
  }).config.home-manager.users.alice;
  standalone = (hm.lib.homeManagerConfiguration {
    inherit pkgs;
    modules = [ probe { home.username = "alice"; home.homeDirectory = "/home/alice"; programs.zsh.enable = true; } ];
  }).config;
in {
  viaNixosModule = builtins.fromJSON viaNixos.home.file."probe".text;
  standaloneHm   = builtins.fromJSON standalone.home.file."probe".text;
}'
{"standaloneHm":{"editor":"<osConfig is null>","hmShells":[false,true,false],"submoduleSupport":false},
 "viaNixosModule":{"editor":"nano","hmShells":[false,false,false],"submoduleSupport":true}}
```

前例も上流にある —— `modules/misc/xdg/portal.nix:138-155` は `osConfig.environment.pathsToLink` を
読んで **assertion** を出しており、`modules/misc/fontconfig.nix:188-191` は `nixosConfig != null` で、
`modules/misc/nix/default.nix:370` は `osConfig.nix or { enable = false; }` の形で守った上で読んでいる。

**つまり「警告は出せる」。** それでも出さない —— 根拠は §3.5(A) / (A2)。
**「直せない」という主張は変わらない**(`osConfig` は読み取り専用で、そこから NixOS 側の定義を
消す手段は無い)ので、出荷文は「cannot fix / cannot resolve」のままでよい。
**「見えない」とは書かないこと。**

### 3.2 `docs/architecture.md` —— **短い表の行 + 表の直後の段落**

**置き場所が `## Edge cases and explicit limitations`(`:522`)であることは issue が指定している。**
この節が正しいのは、「nvimx の外の理由で効かない」という形の行を**既に 2 つ抱えている**からである ——
`:536`(`Local plugin development`: lazy.nvim の都合で `devPath` が効かない)と
`:538`(treesitter の known limitation)。

**ただし全文を 1 つのセルに入れない。** issue が言うのは「a row in **Edge cases and explicit
limitations**」、すなわち**表**ではなく**節**である。そして表は**眺めて当たりを付ける**ためにあり、
`:526-539` の 14 行はどれもその粒度(実測で最長が `:529` の **919 字**、以下 712 / 565 / 549)。
一方この節の散文は 1 段落 = 折り返さない 1 行で書く流儀で、`:287` の **2,506 字**を筆頭に
2,312 / 1,422 / 965 がある。したがって**因果の鎖は散文側に置く**:

- **表の行**: 症状 + 1 行の直し方 + 下へのポインタ。**590 字**で、表では **3 番目**の長さ
  (919 / 712 の次。565 を 25 字上回る)。
- **表の直後の段落**(`## Implementation phases` の直前): **2,419 字**で、散文としては **2 番目**
  (2,506 の次。ただし **`:287` の 2,506 は箇条書きであって note ではない** ——
  **太字の見出しで始まる note だけで数えるとこれがファイル最長**である(既存は `:262` 2,312 /
  `:271` 965 / `:275` 879 / `:273` 649 / `:246` 543 / `:435` 112)。round-12 の言い換えで 160 字増えた。
  `**Source URL validation** (#28): ...`(`:262`)に倣い
  **太字の見出し + コロン**で始め、**折り返さず 1 行**で書く。
- README のアンカー `#edge-cases-and-explicit-limitations` は**見出し**を指すので壊れない。

**追加する表の行(逐語。`:539` の直後)**:

```
| `defaultEditor` vs. NixOS's own `EDITOR` default | NixOS itself sets `EDITOR=nano`, with no enable option behind it, and a system-wide shell init that NixOS generates exports `EDITOR` from `/etc/set-environment`. In a shell home-manager does not manage, NixOS's default is usually the only definition left, so `defaultEditor` looks like it does nothing. nvimx cannot resolve it; on the NixOS side `environment.variables.EDITOR = "nvim";` gets you `nvim`. The note right below this table has the full chain, the limits, and when letting home-manager manage the shell is enough on its own |
```

**追加する段落(逐語。表の直後に空行を挟んで 1 行。後ろにも空行を 1 行置き、
`## Implementation phases` との間隔を既存と揃える)**:

```
**NixOS's own `EDITOR` default vs. `programs.nvimx.defaultEditor`**: NixOS sets `EDITOR = lib.mkDefault "nano"` in `nixos/modules/programs/environment.nix` -- directly under `config`, with no `mkIf` and no enable option, and unrelated to `programs.nano.enable`. That definition goes through `environment.variables` rather than `environment.sessionVariables`, so the definition lands in `/etc/set-environment` and never in `/etc/pam/environment`. What exports `EDITOR` from `/etc/set-environment` is whichever shell module NixOS has enabled -- `programs.bash` by default, through its `/etc/profile`; `programs.zsh` and `programs.fish` write `/etc/zshenv` and `/etc/fish/nixos-env-preinit.fish`, but only once you enable those modules. nvimx cannot fix this: NixOS and home-manager are separate module systems whose definitions never merge, so no priority nvimx sets is ever compared against NixOS's, and a `mkForce` in nvimx would change nothing. The only relationship is export order. The NixOS init runs first; a shell home-manager manages then sources the `hm-session-vars` file home-manager generates, and `defaultEditor` wins -- except in a non-login bash started from a clean environment. That bash never reaches the `~/.profile` home-manager puts bash's copy in, while home-manager's zsh and fish copies sit in files non-login sessions read too. A shell home-manager does not manage does not source `hm-session-vars` unless you source it yourself, and what is left is whatever NixOS exported -- usually `nano`, sometimes nothing at all. home-manager documents this itself: its `docs/manual/faq/session-variables.md` says bash, zsh and fish are the three shells home-manager can set session variables for, and gives recipes for sourcing `hm-session-vars` by hand anywhere else. The same split is why one machine can answer `nvim` in one shell and `nano` in another. What gets you `nvim` wherever any definition is read at all is `environment.variables.EDITOR = "nvim";` on the NixOS side -- a plain definition, which at priority 100 beats NixOS's `mkDefault`. Letting home-manager manage the shell works too, outside the non-login bash above. `environment.variables.EDITOR = lib.mkForce null;` is not a fix: the `apply` on `environment.variables` filters null attributes out (`nixos/modules/config/shells-environment.nix`), so that line drops NixOS's export and leaves `EDITOR` unset wherever nothing else sets it.
```

**決定事項:**

1. **上流の行番号を書かない。** 出荷文にはファイル名だけ —— nixpkgs の bump のたびに腐るのは
   割に合わない。同じファイル内の `lua/lazy/core/meta.lua:229-231`(`:181`)が行番号付きなのは
   **行の意味が正確に必要な**引用だからである。
2. **`programs.nano.enable` との無関係を明記する。** issue の測定表が 4 行のうち 1 行を割いているのは、
   これが**最初に試されて外れる推測**だからである。**削減候補ではない。**
3. **GUI セッション / systemd user unit の話は書かない。** round-1 の案は
   「a GUI session or a systemd user unit never sees it at all」と書いていたが、**GUI について偽である**
   (§1.3(e))。正しく書き直すと「DM 経由の X セッションは見る / セッション環境を継承しない
   systemd user unit は見ない」という条件分岐になり、(a) 読者の行動を 1 つも変えず、
   (b) display-manager の実装という**腐りやすい面**を出荷文に持ち込む。**節ごと落とす。**
4. **`mkForce` が無効であることを理由ごと名指しする。** 「cannot fix」だけでは「`mkForce` を付ければ」
   という次の提案を呼ぶ。#67 §3.2 が `mkDefault` / `mkForce` を却下したのは **home-manager 内部の衝突**
   についてであり、本件は**そもそも比較が起きない**という別の理由である。
5. **`/etc/profile` も `~/.profile` も「共通の経路」としては書かない。** §1.3(d) / §1.5 の実測のとおり
   どちらも **bash 専用**である。配分は **表の行が `/etc/set-environment` だけを言い、
   README はファイル名を 1 つも出さず、段落だけがシェル別の内訳を挙げる**(§3.3 決定 3)。
6. **「never sources that file at all」と書かない。** §1.5 の FAQ `:8-27` が**正規の手順として**
   手動 source を案内しており、それに従っている人は壊れていない(§3.5(A2) の却下根拠そのもの)。
   段落は **"does not source `hm-session-vars` unless you source it yourself"**、
   **表の行と README は "NixOS's default is usually the only definition left"** と、
   3 箇所すべてに効かせる。
   (**round-17 まで段落を "does not source that file ..." と引いていた** ——
   決定 19 が `that file` を名前に置き換えたのを写していなかった。誤り 30 の 7 件目で、
   **round-17 のレビューが挙げた 6 件には入っていない**。本計画の掃き出しで出した。)
7. **「seven modules」も「home-manager documents none of this」も出荷文に入れない。** どちらも §1.6 で
   検証済みだが、(a) **上流モジュールの実数**を pin より長生きする前提の文書に固定することになり
   ずれても誰も気づかない、(b) **読者の行動を 1 つも変えない**。事実は §1.6 に残る。
8. **表の行に因果の説明を入れない。** 「別のモジュールシステムだから」は段落の仕事である。
   行の仕事は症状・直し方・ポインタの 3 つだけ。
9. **FAQ への参照には "its" を付ける**(`docs/architecture.md` の中で裸の `docs/...` は nvimx 自身の
   `docs/` と読めてしまう)。**素の `environment.variables.EDITOR = "nvim";` も書く** ——
   実測で効き(§1.4)、`mkForce null` と並ぶ「NixOS 側の 1 行」である。
10. **全称量化子も、存在を前提にした断定も書かない。** これは 2 段階で直っている。
    round-2 の案は description に「**every shell's** system-wide init exports from
    /etc/set-environment」と書いていた —— §1.3(d) のとおり `setEnvironment` を読む NixOS モジュールは
    **4 つしか無い**。round-3 の案はそれを「the system-wide init NixOS writes for your shell --
    `/etc/profile` for bash, `/etc/zshenv` for zsh, ... **and so on**」に直したが、
    **これもまだ偽だった** —— 既定 `false` の 3 つは**ファイルが存在しない**(§1.3(d) の実測:
    素の NixOS に `/etc/zshenv` は無い)ので、zsh ユーザに存在しないファイルを名指すことになる。
    round-1 が `~/.profile` で、round-2 が `/etc/profile` で踏んだのと**同じ穴**である。
    最終形は:
    - **段落**は「whichever shell module NixOS has enabled -- `programs.bash` by default, through its
      `/etc/profile`; `programs.zsh` and `programs.fish` write `/etc/zshenv` and
      `/etc/fish/nixos-env-preinit.fish`, **but only once you enable those modules**」。
      **どのファイルも `enable` 条件とセットでしか出さない。**
      (`them` → `those modules` は誤り 28。**直近の複数は 2 つのファイル名**だった。)
    - **行と description** は **"a system-wide shell init that NixOS generates"** ——
      **不定冠詞**で受け、個数にも存在にも踏み込まない。所有格の "NixOS's system-wide shell init" では
      「1 つ決まったものがある」と読めてしまうので、round-3 の案から更に弱めてある。
      **`that` は落とせない**(決定 21)—— 落とすと `init NixOS generates exports` が
      N-V-N の garden path になる。**§8 手順 6a はこの句を逐語で assert する**ので、
      **この 2 行はその assert の期待値そのものである。ここを古い案のまま残さないこと。**
11. **`hm-session-vars.sh` を全シェル共通のファイル名として書かない。** fish は
    `hm-session-vars.fish`(§1.5)である。**拡張子を書かない**のが本決定の恒久的な中身で、
    最終形は段落・description とも **"the hm-session-vars file home-manager generates"**
    (段落はバッククォート付き、description は §3.4 決定 3 により裸)。
    **round-16 まで段落 "the ... file it generates" / description "its generated hm-session-vars
    file" と書いていたが、どちらも出荷文には無い** —— 裸の `it` / `its` は決定 19 が
    「主体は毎回名前で書く」で潰した形(誤り 20 の住処)で、**ここに残すと 6a の突き合わせが
    誤り 20 を「決定どおり」として復活させる**。
12. **`never in /etc/pam/environment` は段落にだけ残す。** §3.4 が description からこれを落とす
    理由(「PAM に落ちないことだけを言っても読者の行動を変えない」)は、段落には当てはまらない ——
    段落は `environment.variables` と `environment.sessionVariables` を**対比した直後**にこれを言い、
    その 3 文あとで **`environment.variables` の方**に `mkForce null` を書けと言う。
    対比が無いと「なぜ `sessionVariables` ではないのか」が未回答のまま残り、
    NixOS ユーザは日常的に `sessionVariables` に手を伸ばす。**対比を具体にするのがこの節の仕事である。**
    description にはその対比自体が無い(オプションを 1 つしか挙げない)ので、落として一貫する。
13. **「home-manager が管理していれば勝つ」を無条件に書かない。** §1.5 の実測のとおり
    **bash にだけ穴がある** —— home-manager は bash の session vars を `~/.profile` にしか置かず
    (`bash.nix:271`)、NixOS の `/etc/bashrc` は `/etc/profile` を source する(`:190-192`、
    `SYS_BASHRC` は `pkgs/shells/bash/5.nix:65`)ので、**クリーンな環境から起動した非ログインの
    対話 bash は `nano` で終わる**。zsh(`.zshenv` / `.zprofile` 両方)と fish(`config.fish`)には
    この穴が無い。無条件に書くと、その読者に「あなたのシェルは管理されていない」という
    **誤診断**を与え、しかも `mkForce null` を当てると `EDITOR` が未設定になる。
    **この文面は決定 9 で更に直っている(下記)。ここに round-5 当時の引用は置かない** ——
    当時の案は `/etc/bashrc` / `/etc/profile` という**機構を名指していた**が、
    §1.5 のとおり 2 セルで機構が違い、非対話側は stdin にも依存するので、
    書けば必ずどこかで偽になる。**出荷される最終形は決定 9 の側を見ること。**
    description は行数の都合で **"and nvim usually wins"** と弱めて architecture.md に送る。
    **"started from a clean environment" は落とせない** —— 環境を継承していれば `nvim` のままである。
    **`~/.profile` をここで名指すのは決定 5 の例外である** —— 決定 5 が禁じたのは
    「3 シェル共通の経路」としての用法で、ここは **bash 固有の話だと文が明示している**。
    §8 手順 6a はこの 1 箇所だけを許し、他の 2 ファイルでは 0 件であることを確かめる。
14. **「取り消す 1 行」を「直す 1 行」として出さない。** round-4 までの表の行は
    「nvimx cannot resolve it; **one line on the NixOS side does** --
    `environment.variables.EDITOR = lib.mkForce null;`」だったが、§1.4 の実測のとおり
    **`mkForce null` は `nvim` を一度も生まない** —— `nano` を消して**未設定**にするだけである。
    行が説明しているまさにその場面(home-manager が管理していないシェル)で、
    この行を当てても `defaultEditor` は依然として効かない。**告知していた効果が無い remedy** であり、
    本計画で最初の「読者が取る行動そのものを誤らせる」誤りだった。
    **`mkForce null` を表の行から外す**という部分が本決定の恒久的な中身である。
    **表の行と description の文面は決定 15 / 17 が最終形を持つ** —— ここに当時の案を残さない
    (決定 13 / §3.4 決定 2 と同じ扱い。当時の案は「効く順」を誤っており、まさに誤り 8 だった)。
    **残る 2 つも round-15 で動いている**(round-17 の指摘。「動いていない」と書いていたが
    **両方とも動いていた**)。**以下は現在の出荷文の逐語であって、当時の案ではない:**
    - **段落**: 「What gets you `nvim` ... **`environment.variables.EDITOR = lib.mkForce null;`
      is not a fix**: the `apply` on `environment.variables` filters null attributes out
      (`nixos/modules/config/shells-environment.nix`), so **that line** drops NixOS's export and
      leaves `EDITOR` unset wherever nothing else sets it」。
      **取り消し側も残すが、「fix ではない」と明示する。**
      `mkForce null` は NixOS の慣用句なので、黙って消すと読者が自力で再発明して同じ穴に落ちる。
      (`so it drops` → `so that line drops` は誤り 28。**裸の `it` は誤り 23 / 24 の形**である。)
    - **README**: 「for why nvimx cannot resolve it**, and what resolves it**」。
      round-4 の「the one line to add on the NixOS side」は、存在しない 1 行を指していた。
      (`and what does` → `and what resolves it` は誤り 28 —— **4 文に残る最後の VP 省略**だった。)
15. **2 つの remedy を等価に並べない。効く方を先に置く。** round-5 の案は
    「What gets you `nvim` is **letting home-manager manage that shell**, or
    `environment.variables.EDITOR = "nvim";`」と、home-manager 側を先に、無条件に並べていた。
    **§1.7 の実シェル実測でこれは偽である** —— まさにその段落が 2 文前に除外している
    bash 非ログインのセルで、home-manager に管理させても `nano`(対話)か未設定(非対話)にしかならず、
    `environment.variables.EDITOR = "nvim";` だけが `nvim` を出す。
    **段落が自分の例外と 2 文で矛盾していた。** しかも表の行は例外を 1 文字も持たないまま
    弱い方を**先頭**に置いており、「端末を開くと非ログイン対話 bash が立つ」という
    **デスクトップで最も普通の構成**の読者を、効かない remedy に誘導していた。最終形:
    **round-6 の案はこれを半分しか直していなかった**(4 箇所が 3 通りの強さで同じ事実を言い、
    表の行の「with one bash exception」は文法上**隣の節 = home-manager 側だけ**に掛かって
    見えるのに、実際は**両方**に掛かる)。**4 つの文の強さを揃えるのが最終形である:**
    - **表の行**: **文面は決定 18 が持つ。ここに当時の案を置かない**(決定 13 / 14 と同じ扱い)。
      本決定がここに残す恒久的な中身は **「強い方を先に置く」** だけで、
      それは決定 18 が remedy を 1 つに絞ったことで自動的に満たされている
      —— round-9 から round-10 にかけてこの行に付けたスコープ・掛かり先・例外の修正
      (決定 12 / 13)は、**決定 18 がその節ごと削除したので出荷文には残っていない**。
    - **段落**(出荷文の逐語。2 文である): 「What gets you `nvim` **wherever any definition is
      read at all** is `environment.variables.EDITOR = "nvim";` on the NixOS side -- a plain
      definition, which at priority 100 beats NixOS's `mkDefault`**.** **L**etting home-manager
      manage the shell works too, **outside the non-login bash above**.」
      この句は §1.7 の結論 2 を 1 句で言ったもので、
      **数(8/9 か 9/9 か)は stdin で変わるので書かない**。
      **round-15 まで "anything" だった**(誤り 27)—— 決定を書いた節も出荷文の一部として掃くこと。
      **round-18 まで 2 文目を `;` で繋いで引いていた**(誤り 30 の 9 件目)——
      **出荷文に `;` は無い。句点と大文字である。** 繋ぎ戻すと、独立節が
      `-- a plain definition, which ...` の同格句を抱えた文の中に入り、
      **決定 19 が「順序・例外は主節にする」でわざわざ切り離した掛かり先が復活する**
      (誤り 15 / 18 の形)。しかも**§8 は見えない** —— note は 1 行なので、
      長さも `^|` 38 も shortstat も note 位置も逐語 assert も 1 つも動かない
      (round-19 が実際に繋ぎ戻して rc=0 / FAIL 0 を確認している)。
      → 6a の逐語ループに 2 文目を足した。
    - **description**: §3.4 決定 1 は「`= "nvim"` は architecture.md にあるから落とす」としていたが、
      **それが唯一の完全な remedy だと分かった以上その根拠は消えた**ので、description に戻す。
      「Setting environment.variables.EDITOR = "nvim" on the NixOS side **is what reaches both
      shells, wherever any definition is read at all**」
      (`both` → `both shells` は誤り 28、`anything` → `any definition` は誤り 27)。
      **後半の条件節は 8 回目のレビューで足した。落とすと偽である** —— round-6 の
      「the fix that covers both」を round-7 で「is what reaches both」に直したが、
      **これは同じ主張の言い換えにすぎなかった**。§1.7 の表の
      `bash non-login non-interactive`(stdin 非ソケット)は「hm 管理外のシェル」でも
      「ログインシェルでない bash」でもある —— つまり **"both" の両方に属するセル**で、
      そこでは `environment.variables.EDITOR = "nvim";` も**届かない**(実測 `<unset>`)。
      表の行と段落には最初から条件が付いていたので、**description だけが 4 つのうち唯一
      無条件だった** —— §3.4 決定 1 が「architecture.md より一段厳しく絞る」と言っている場所で、
      逆に一番強い主張をしていたことになる。
      `lib.mkForce null` が fix でないことは architecture.md に送る(行数の都合)。
16. **「nano is the only definition left」も条件付きにする。これは 2 段階で直っている。**
    round-5 の案は無条件だった。round-6 でそれを
    **「`nano` where a NixOS shell module is enabled, nothing at all where none is」**に直したが、
    **これもまだ偽だった** —— §1.7 の表には**モジュールが enable されていて**なお
    `nano` でも `nothing` でもないセルがある(hm 管理外 / 非ログイン / 非対話 bash は
    stdin 次第で未設定か `nano`)。しかも同じ段落が 2 文前にその bash を
    *管理している* 側で除外しておきながら、*管理外* 側では無条件に言い直していた ——
    **決定 16 を片側にしか適用していなかった**。最終形は数え上げをやめる:
    段落 **"what is left is whatever NixOS exported -- usually `nano`, sometimes nothing at all"**、
    description **"can still come out nano"**。表の行と README は既に "usually" で受けている。
    **4 つの文がこれで同じ強さになる。**
17. **description の末尾は `nvimx's docs/architecture.md`。** description は**ユーザ側が生成する
    option ドキュメント**に出るので、裸の相対パスにはリポジトリの文脈が無い
    (`nix/home-manager/default.nix` の description は全部で 19 個。`defaultEditor` 自身を除く
    **18 個**のどれもドキュメントのパスを参照していない)。
    決定 9 が architecture.md の中の `docs/...` に "its" を付けたのと同じ理由である。
18. **表の行は remedy を 1 つだけ載せる。数量詞は載せない**(round-11。**誤り 8/12/13/14 の決着**)。
    **表の行で 6 回壊れたのは、いつも「被覆範囲」の節であって remedy の名前ではなかった** ——
    誤り 8(どちらを先に)、12(シェルのスコープ = xonsh)、13(同格句の掛かり先)、
    14(数量詞の粒度)。**数量詞を消せば誤りの置き場所ごと消える。**
    - **落とすのは home-manager 側**。弱い方であり、**列挙と例外の両方を必要とする唯一の remedy**
      であり、しかも**行の 2 文目(「In a shell home-manager does not manage」)が
      その経路の存在を既に読者に伝えている**。
    - **残すのは `environment.variables.EDITOR = "nvim";` で、数量詞を付けない。**
      全称が無いので間違えようがなく、**当てて害になる場面が無い**(効かないセルでは
      他の何も効かない)。
    - 3 文目は「nvimx cannot resolve it; on the NixOS side `environment.variables.EDITOR =
      "nvim";` gets you `nvim`. The note right below this table has the full chain, the limits,
      and when letting home-manager manage the shell is enough on its own」。
      **現在 590 字** —— 決定 18 が 670 から 578 まで落とし、その後 round-15 の誤り 28 と
      round-16 の誤り 29(決定 21)で 590 になった。**ここの数字は出荷文を差し替えるたびに測り直すこと**。
    **「ポインタだけにする」は採らない** —— `README.md:224` が既にポインタだけの設計(決定 2)なので、
    表の行までそうすると**同じ文の 2 つ目のコピー**になり、決定 8 が定めた行の 3 つの仕事
    (症状・直し方・ポインタ)のうち 1 つが消える。
    **表の他の行と照らしても整合する**: §3.2 が先例に挙げた 2 行(`:536` devPath、`:538` treesitter)は
    **remedy を 1 つも持たない**し、remedy を持つ唯一の行(`:534` luarocks)は
    **nvimx のオプションを 1 つ、スコープも例外も無しで**名指すだけである。
    round-10 までの案は、**この表で唯一「スコープ付きの設定変更を 2 つ」処方する行**だった。

19. **段落と description は「指示対象を名前で書き、順序関係を主節にする」形に組み直す**
    (round-12。**誤り 16-24 の決着**。round-13 の誤り 25、round-14 の誤り 26 も同じ規則で直した)。
    決定 18 が表の行で採った手(**構造を単純にして誤りの置き場所を消す**)を、残る 2 文にも当てる。
    round-11 までは代名詞と省略で圧縮していたので、**測定が全部正しいまま文だけが偽になる**
    という状態が 9 件同時に成立していた。規則は 3 つ:
    - **順序関係は主節にする。** 「after that」も「after the NixOS init does」も、
      対応する VP / NP が文中に無いか、あっても偽になる。→ 「The NixOS init runs first;
      a shell home-manager manages then sources ...」と**独立した節**にする。
      **これで `, which` の掛かり先(誤り 18)も同時に消えた** —— 例外が独立文になったからである。
    - **主体は毎回名前で書く。** `the two` → `NixOS and home-manager`、
      `it does not manage` → `home-manager does not manage`、
      `source it yourself` → `source hm-session-vars`、
      `what exports it` → ``what exports `EDITOR` from `/etc/set-environment` ``、
      そして round-13 で `no priority of ours ... against theirs` →
      `no priority nvimx sets ... against NixOS's`(誤り 25)。
      **繰り返しは冗長ではなく、掛かり先の曖昧さを消す唯一の手段である。**
    - **等位接続に別指示の代名詞を置かない。** FAQ の括弧内は主語を 1 つにして省略でつなぐ
      (誤り 19)。
    代償は長さで、段落は **2,239 → 2,419 字**(散文で 3 番目 → **2 番目**。`:287` の 2,506 は
    箇条書きなので、**太字見出しの note に限ればファイル最長**である)。
    **これは受け入れる** —— 表の行で学んだのは「短さ」ではなく
    「**1 文が担う仕事を減らすこと**」であり、名前の繰り返しはその方向の変更である。
    description は 10 行・ブロック 96 桁を維持したまま同じ書き換えが収まった(**新しい 10 行自体の
    最長は round-16 以降 **96 桁**で、`:110` と同値である)
    (末尾は 96 桁に収めるため `mkForce null is no fix; see nvimx's docs/architecture.md.` の
    語順にした。誤り 24。**`is not a fix` → `is no fix` は誤り 27 の 3 桁の相殺**で、
    **round-17 までこの行だけがその変更を取り込んでいなかった** —— 誤り 30 の 8 件目である。)
    **段落と description で綴りが違うのは意図的である** —— 段落は `is not a fix`、
    description だけが `is no fix` で、**桁の制約があるのは description だけ**だからである。
    **揃えないこと。**§8 手順 6a は 2 つを別々に逐語 assert している。
    **この 1 件は §8 が原理的に捕まえられなかった** —— `is not a fix` に戻しても
    その行は 65 → 68 桁にしかならず、ブロック最長 96 も 10 行も `mkForce null` の 1 件も動かない。
    **だから 6a の逐語ループに description 末尾を足した。**
    **この決定は本計画自身の 5b でも 2 件(誤り 23 / 24)を出している** ——
    書き換えた草稿にも手順 5b を当てること。

20. **代用形は標本ではなく網羅で掃く。ただし全部を格上げはしない**(round-15。誤り 27 / 28)。
    決定 19 が「指示対象を名前で書く」を立て、round-14 が**形**の規則を測った ——
    **裸の代名詞・省略主要部**に誤り 16/19/20/21/22/23/24/25/26 の 9 件全部、
    **指示詞 + 主要部名詞**には 15 回で 0 件。そこで残りを網羅で潰した。
    **束縛点は 42**(round-24 に `too` を 1 つ数え落としていたのを訂正。ゼロ関係詞 12 を除く。
    **その除外は明示されていなかった** ——
    含めれば 54。決定 21)、**格上げ 10 箇所 / 据え置き 10 箇所**
    (**編集は 8 本。箇所と本数は別に数える** —— round-16 の指摘):
    - **据え置き 10 箇所**: `looks like it does nothing`(外すと文が壊れる)、命題を指す `this`、
      **加算の `too` の 2 箇所**(`files non-login sessions read too` と
      `Letting home-manager manage the shell works too`。**round-23 まで 1 箇所としか
      書いていなかった** —— 裁定はどちらも同じで無害だが、5b の手順 1 を網羅で回した人は
      必ずここで数が合わなくなる。round-24 に訂正。束縛点の総数も 41 → **42**、
      ゼロ関係詞を含めると 53 → **54**)、`its /etc/profile`、`its own`、
      `nvimx cannot resolve it` の 2 箇所、
      そして round-15 が裁定を書き落としていた 2 箇所 ——
      段落の **`home-manager documents this itself`**(`this` は直前の命題を指し、
      `itself` は同じ節の主語 `home-manager` に束縛される強調辞。どちらも他の先行詞を取れない)と、
      段落の **`compared against NixOS's`**(省略主要部。`priority` / `definition` / `default` の
      どれを補っても**同じ真な読みになる**ので手順 2b で止まる —— ただし
      **形の規則が旗を立てる側の形である**から、格上げしないことを明示的に記録しておく)。
      **どれも最も近い読みが型の衝突か、あるいは候補がすべて同値で、偽の読みが存在しない**(手順 2b)。
      **「全部を格上げ」は買うより高くつく** —— 決定 19 自身の修正
      (`That definition` / `That bash` / `The two module systems`)まで巻き戻しかねない。
    - **格上げ**: 誤り 28 の 8 箇所(表の行の `exports it` / `itself` の位置 / `NixOS's` の主要部、
      段落の `them` と PP をまたぐ関係節、description の `both` と `nothing here`、
      README の VP 省略)。
    **この決定の要点は「網羅性」である。** 誤り 15 / 18 / 23 / 25 / 26 はどれも
    「直した節の隣が代用形のまま残った」形で出ており、**標本抽出では閉じない**ことを
    5 回にわたって実証してしまった。代償は長さ(表の行 578 → **590**、段落 2,399 → **2,419**)で、
    description は 10 行のまま。**新しい 10 行の最長は 96 桁**で、ブロックの 96(`:110`)と同値になった
    —— round-16 で `system-wide` と `that` を戻した結果である(決定 21)。

21. **出荷文は「決定」とも突き合わせる。ゼロ関係詞も掃く**(round-16。誤り 29)。
    round-16 は新しい**事実**誤りを 1 つも出さなかった。出たのは
    **決定と出荷文が食い違っている箇所**と、**掃き出しの網羅性の穴**である。
    - **誤り 29 —— 決定 10 が命じた不定冠詞が、表の行と description の両方で `the` のままだった。**
      §1.3(d) の実測は「素の NixOS に `/etc/zshenv` も `/etc/fish/nixos-env-preinit.fish` も無い」で、
      だから決定 10 は「**a** system-wide shell init that NixOS generates」と不定冠詞を命じている。
      定冠詞は「NixOS が生成するシェル init は 1 つに決まっている」を含意し、
      **決定 10 が名指しで禁じた全称を、冠詞だけで復活させていた**。→ 両方 `a` に戻す。
      **これは §1 の再導出でも手順 5b でも出ない** —— 数値も引用も構文も正しく、
      **本計画自身の決定とだけ食い違っていた**。だから §8 手順 6a に
      **「決定が逐語で命じた語が出荷文に実在すること」**を 1 本足した(§8)。
    - **`system-wide` と `that` を落とす案は却下した。**description を 10 行に収めるために
      提案したものだが、(a) `that` を落とすと `a shell init NixOS generates exports EDITOR` が
      **N-V-N の garden path** になり、これは決定 19 が一度直した形の退行である。
      (b) `system-wide` は表の行・段落・description の 3 文で同じ語を使うと決めた語で、
      **片方だけ落とすのは誤り 10 / 12 / 26 と同じ「片側だけ適用」**である。
      (c) **そもそも桁が足りている** —— `fold -s` が 11 行を返したのは
      `fold` が貪欲ではないからで、貪欲に詰め直すと **10 行・最長 96 桁**に収まる
      (§8 で使う awk はこの貪欲版である)。
      **「入らない」と報告する前に、詰め方の側を疑うこと。**
    - **`directly under config` → `under config` は description だけで採る。**
      note は 「-- directly under `config`, with no `mkIf` and no enable option」と
      **対比**を持っているので
      `directly` が仕事をしているが、description は §3.4 決定 1 で `mkIf` の対比ごと落としている ——
      **対比の無い場所に残った副詞**なので削る。**3 文で語を揃える規則の例外はこれ 1 つ**で、
      理由は「揃える相手がもう無い」である(上の (b) と衝突しない)。
    - **ゼロ関係詞を掃き出しに入れる。** 4 文のゼロ関係詞は **12 箇所**
      (表の行 1 / 段落 7 / README 1 / description 3)。決定 20 の 41 はこれを数えておらず、
      **`that` を落とす案が素通りしたのはこの穴である**。残る 11 箇所は据え置き ——
      最も近いのは段落の `A shell home-manager does not manage does not source hm-session-vars` だが、
      **同じ助動詞 `does not` が 2 度続くので境界が聞こえる**。
      退けた案の `init NixOS generates exports` は**語彙の違う動詞が 2 つ並ぶ**形で、そこが分かれ目である。
    - **誤り 30 —— 決定 10 / 11 / 14 に古い文面が逐語で残っていた**(round-17)。
      **誤り 29 の裏返し**である。29 は「出荷文が決定から外れた」形だったが、30 は
      **決定の側が出荷文から外れたまま「最終形」「…とする」「残る 2 つは動いていない」と
      名乗っていた**形で、6 箇所あった(決定 10 の `them` と `that` 落ち、決定 11 の
      `it generates` / `its generated ...`、決定 14 の `so it drops` と `and what does`、
      および §1.3(d) の `them`)。**本計画の掃き出しで 7 件目**も出た ——
      決定 6 の段落引用 `does not source that file ...`(決定 19 が名前に置き換えた形を
      写していなかった)。**レビューが 6 件を挙げた時点で「6 件で閉じた」と思わないこと** ——
      誤り 15 / 18 / 23 / 25 / 26 と同じ「標本では閉じない」形である。
      **そして round-18 に 8 件目が出た** —— 決定 19 の
      `mkForce null is not a fix; ...`(出荷文は `is no fix`。誤り 27 の 3 桁の相殺が
      この行にだけ伝播していなかった)。**この 8 件目は掃き出しの機械が出していたのに、
      私が「誤り N」を含む行を除外するフィルタを掛けて落としていた** ——
      **掃き出しにフィルタを掛けた瞬間、それは網羅ではなく標本に戻る**(決定 20 が
      「標本では閉じない」と書いたその手順を、掃き出しの読み方で破っていた)。
      **規則: 掃き出しの出力は 1 行ずつ裁定する。grep -v で減らさない。**
      8 件目はさらに悪く、**§8 が原理的に捕まえられない**位置にあった
      (`is not a fix` に戻しても 65 → 68 桁で、ブロック最長も行数も件数も動かない)。
      → 6a の逐語 assert に description 末尾と note の `mkIf` 対比を足した。
      **round-19 に 9 件目** —— 決定 15 の段落 bullet が 2 文目を `;` で繋いでいた
      (出荷文は句点 + 大文字。**`;` は省略部分の中にはいない**ので ellipsis の artifact ではない)。
      戻すと決定 19 が切り離した独立節が同格句の内側に戻り、**§8 は 1 行も動かないまま通る**。
      **決定に逐語で貼る英文は、6a が assert している句と 1 対 1 にすること。**
      **そして、この「1 対 1」を人手で保つのは 9 回失敗した。** round-19 で**機械化した** ——
      §8 手順 6e が §3.2-§3.4 の決定から英文断片を全部取り出し、出荷文 4 本に**存在しない**ものを
      集めて**その集合のダイジェスト**を突き合わせる。**追加・削除・すり替えのどれでも落ちる。**
      - **fail-closed である。** 期待値は「0 件」ではなく「この 39 件ちょうど」なので、
        新しい未注記の引用が入れば落ち、注記済みの引用が消えても落ちる。
      - **2 つの盲点を承知で入れている。**(1) 見るのは §3.2-§3.4 だけ(§1.3(d) の 1 件は
        6a の逐語 assert が別に見ている)。(2) **「何かが変わった」しか言わない** ——
        落ちたら印字される差分を 1 行ずつ裁定すること(決定 20 の「標本にしない」がここにも効く)。
      - **正規化は空白と `` ` `` / `*` の除去だけ**にしてある。**句読点と大小文字は残す** ——
        9 件目(`;` 対 `.`)も 8 件目(`is not a fix` 対 `is no fix`)も、
        **句読点を潰す正規化では両方とも素通りする**(round-19 に実測で確認した。
        最初に書いた版がまさにそれで、**自分の guard の陽性対照で落とした**)。
      さらに **2 件の同類(現在形で出荷文を語っている記述)**も直した ——
      決定 21 自身の note 引用(ダッシュの位置が違っていた)と、
      §3.3 決定 2 の「決定 15 が表の行に付けた『bash, zsh or fish』」
      (**決定 15 のものでも、その綴りでもなく、決定 18 が表の行から削除済み**)。
      **危険は 29 より大きい** —— 6a の突き合わせを素直に実行した実装者が、
      **出荷文を決定の側へ「直し」、誤り 20 / 23 / 24 / 28 と決定 21 の `that` を
      まとめて再発させる**。しかも全部「決定どおりに直した」という形になる。
      → 10 箇所(逐語 8 + 現在形の記述 2)を出荷文に合わせ、決定 14 の「残る 2 つは動いていない」を訂正し、
      **出荷文の側を固定する assert を §8 手順 6a に足した**。
      **規則**: 決定に英文を逐語で貼るなら、それは**出荷文と同一でなければならない**。
      同一にできない(当時の案・却下案)なら、決定 13 / 14 / 15 / §3.4 決定 2 が既にやっている
      **「ここに当時の案を残さない」と明記する**方を選ぶこと。中間は無い。
    - **本計画の記録そのものが 4 箇所で壊れていた**(round-16 の指摘 3 / 4 / 5 / 7)——
      誤りの分割が 27 にしかならない、§1.7 結論 2 と goal 2 が**誤り 27 が反証した言い回しを
      抱えたまま**だった、§3.3 の README 実測が 16 字ぶん古い、
      決定 20 の「8 / 6」が編集の本数と箇所の個数の混同。
      **出荷文を差し替えたら、その出荷文を数えている箇所と引用している決定を同時に掃くこと。**
      §8 手順 6d の README 算術と、手順 6a の決定突き合わせがその機械化である。

### 3.3 `README.md` —— Options 表の直後の段落に 1 文、**段落ごと折り返す**


**追記先は `:224`**(現在は「`lockDir` は既定が無い / `manageConfig = true` なら `configDir` が要る」の
2 文が 1 行 200 字で入っている)。ここは既に「表のセルに収まらないオプションの注意書き」の置き場である。

**折り返す。** round-2 の案は「1 行 1 段落」と書いて末尾に追記する形だったが、**それは README の
流儀ではない**。実測(`awk 'length($0)>0 && $0 !~ /^\|/ {print length($0)}' README.md`、表を除いた
**359 行**): **中央値 85 字 / p90 99 字**(`floor(n/2)` ではなく順位で数えた値。
`LC_ALL=C` だと p90 は 100)。150 字を超えるのはバッジの HTML(`:10-11`)と
冒頭の箇条書き **2 本**(`:22` が 189、`:23` が 246。`:21` は 130 で超えない)と
この `:224`(200)だけである。追記すると **582 字**(7 行の合計 576 + 継ぎ目の空白 6。**文字数**であって
バイト数ではない —— `LC_ALL=C` だと 578 / 584)になり、
ファイル現最長 246 の **2.37 倍**になる(round-12 以降で 16 字増えている ——
`that` → `NixOS's` の 3 字、round-15 の誤り 28(VP 省略の格上げ)、round-16 の不定冠詞復帰。
**round-15 の時点で更新し忘れていた** —— 出荷文を差し替えたら、それを数えている箇所を
必ず測り直すこと。測り直しは §8 手順 6d に入れた)。
(コードフェンス行も除く別の数え方だと 347 行 / 中央値 89 になるが、**判断に効く p90 = 99 は
どの母集団でも変わらない**。以下の折り返しは**全行 54-98 字**で、そこに収まっている
(最短は最終行の 54)。)
**段落全体を 7 行に折り返す**(既存 2 文も含めて。git 上は 1 行削除 + 7 行追加になる)。

**差し替え後の `:224` 段落(逐語。既存 2 文は文字を 1 つも変えず、折り返し位置だけを入れている)**:

```
`lockDir` is the only option without a default, so it must always be set. `configDir` is also
required whenever `manageConfig` is `true` (the default), which is enforced by an assertion in the
module. On NixOS, `defaultEditor` can also look like it does nothing: NixOS itself sets
`EDITOR=nano`, with no enable option behind it, and in a shell home-manager does not manage,
NixOS's default is usually the only definition left — see
[Edge cases and explicit limitations](docs/architecture.md#edge-cases-and-explicit-limitations)
for why nvimx cannot resolve it, and what resolves it.
```

各行 54-98 字で、README の p90(99)に収まる(§8 手順 6d が `54 / 98` を assert する ——
**round-20 までこの文は偽だった。6d は印字するだけで、112 桁に折り直しても §8 は通った**)。
**この折り返しで diffstat が
`README.md | 8 +++++++-` になる**(§4.2 / §8 手順 1 の期待値はこれに合わせてある)。

**決定事項:**

1. **「no matter what」と書かない。** 素の `environment.variables.EDITOR = "nvim";` は勝つ(§1.4)ので
   「何をしても `nano` が出る」は**端的に偽**である。正しい主張は「**enable オプションが後ろに無い**」。
2. **README は remedy を 1 つも名指ししない。** round-3 の案は「the one line to add on the NixOS
   side」と書いていたが、決定 14 のとおりそれが指していた 1 行(`mkForce null`)は
   **remedy ではなかった**。かといって正しい remedy を 1 文に押し込むと、
   §1.7 の条件("wherever any definition is read at all")と、
   **表の行が round-10 まで背負っていたシェルのスコープ**まで背負うことになる。
   (**「決定 15 が表の行に付けた「bash, zsh or fish」」と書いていたのは誤りだった** ——
   列挙は決定 12 / 13 のもので、綴りも `bash, zsh and fish` であり、そして
   **決定 18 が home-manager 側の remedy ごと表の行から削除している**(§3.2 決定 13 の括弧、
   誤り 12 / 13 の記述)。**現在の出荷文のどこにも存在しない句である。**
   結論(README は remedy を 1 つも名指ししない)は変わらないが、
   引用したままだと誤り 12 / 13 / 14 が直した数量詞を呼び戻す。round-18。)
   **architecture.md に送る** —— 文面は "and what resolves it" である
   ("and what does" は VP 省略で、誤り 28 が格上げした)。
   README の役目は「これは nvimx のバグではない」と「続きはここ」の 2 つだけである。
   `grep -c 'mkForce\|environment.variables'` が README の当該段落で **0** であることを
   §8 手順 6a が確かめる。
3. **ファイル名を 1 つも出さない**(§3.2 決定 5)。README は 1 文しかなく、`/etc/profile` を出せば
   bash 限定の嘘になり、内訳を書く場所は無い。「どこから export されるか」は architecture.md が持つ。
4. **`:210` の `defaultEditor` のセルは触らない**(既に 4 つの節を詰め込んだ長いセルで、5 つ目を
   足すと表として読めなくなる)。**散文の節も作らない** —— `### Escape hatches`(`:226`)以下の節は
   どれも **nvimx が提供する機能**の説明であり、本件は「他所の既定値との関係」なので、
   節にすると目次で対等に見えてしまう。
5. **リンクは `:472` の前例(アンカー付き)に倣い、テキストは見出し名にする**(飛び先が予測できる)。
   **em dash は `—`(U+2014)** —— README の散文で**優勢な形**であり、
   `docs/architecture.md` の散文では ` -- ` が優勢である。**どちらのファイルも混在しており**
   (README にも散文の ` -- ` が `:177` / `:191` / `:192` の 3 件ある)、「統一されている」ではない。
   **数え方で値がぶれるので件数は書かない** —— 生の `grep -c` と「散文行に限る」とで
   どちらのファイルも数字が変わる。**判断は向きだけで足り、向きはどの数え方でも同じである。**
   既存の逆向きのダッシュを見つけても欠陥として直さないこと。新規に書くときだけ優勢な方に倣う。

### 3.4 `nix/home-manager/default.nix` —— description に 1 段落

**追記先は `:111` の直後**(description の最後の行の後)、空行 1 行を挟んで。

**追加する段落(逐語。インデントは既存と同じ半角 8 個)**:

```
        On NixOS, home-manager is not the outermost layer. NixOS sets EDITOR=nano with no enable
        option behind it (nixos/modules/programs/environment.nix, a plain lib.mkDefault under
        config, unrelated to programs.nano.enable), and a system-wide shell init that NixOS
        generates exports EDITOR from /etc/set-environment. The two module systems never merge,
        so nothing nvimx sets outranks NixOS's value; only export order decides. The NixOS init
        runs first; a shell home-manager manages then sources the hm-session-vars file
        home-manager generates, and nvim usually wins. A shell home-manager does not manage, and
        a non-login bash, can still come out nano. Setting environment.variables.EDITOR = "nvim"
        on the NixOS side is what reaches both shells, wherever any definition is read at all.
        mkForce null is no fix; see nvimx's docs/architecture.md.
```

**行数**: 追加は **空行 1 行 + 本文 10 行 = 11 行**。オプションブロックは
**`:88-113` の 26 行 → `:88-124` の 37 行**(description 本体は `:91-112` → `:91-123`)。
以降の行番号はすべて **+11** ずれる(`extraPackages` `:115` → `:126`、
`home.sessionVariables` の配線 `:358` → `:369`)。**§5 は下から当てるので実害は無い**。

**§3.2 の決定 2 / 3 / 5 / 6 / 7 / 10 / 11 はここにもそのまま効く。** description 固有なのは:

1. **さらに削る。** `homeModules.nvimx` の一部としてユーザの option ドキュメントに**恒久的に出る**
   ので、architecture.md より一段厳しく絞る。ここで落としたのは **シェル別の内訳**、
   **`programs.bash.enable` の既定の非対称**、**素の `= "nvim";` と FAQ への言及**、そして
   **`never in /etc/pam/environment`** —— §3.2 決定 12 のとおり、対比を持たない description で
   PAM に落ちないことだけを言っても読者の行動を変えない。いずれも architecture.md にある。
2. **語の選択。**「unconditionally」ではなく **"with no enable option behind it"**(`lib.mkDefault`
   である以上「無条件」は誤解を招く)。**remedy の言い回しは決定 15 が最終形を持つ** ——
   "Setting environment.variables.EDITOR = \"nvim\" on the NixOS side is what reaches both shells,
   wherever any definition is read at all"(**誤り 27 で `anything` → `any definition`、
   誤り 28 で `both` → `both shells` になった最終形**)。ここに古い言い回しを置かない。
   **この決定自身が round-15 まで古い言い回しを抱えていた** ——
   出荷文を直したら、その出荷文を引用している決定も掃くこと(決定 21)。
3. **記法は既存に揃える。** `` ` `` も `{option}` / `{env}` role も使わない ——
   **これは `defaultEditor` の description 内の話であって、モジュール全体の規約ではない**
   (`:79` / `:85` / `:131` / `:138` / `:160-183` / `:206-210` / `:249` / `:274-275` の
   description には `` ` `` がある)。`defaultEditor` の description だけが `:92` の
   `` `nvim` `` を唯一の例外に**裸の識別子**で通しており、新しい段落もそれに合わせる。
   `{option}` / `{env}` の MyST role の方は**モジュール全体で 0 件**である(#67 §3.1 決定 2)。
   **em dash は `--`**(既存では `:105` と `:109` の 2 箇所)—— ただし**決定 19 で組み直した
   段落にはダッシュが 1 つも無い**ので、この規則は現状では空振りである。新たに足すときだけ効く。
   **インデントは半角 8 個を厳守** —— ずれると nixfmt が**ブロック全体の共通インデント**を
   付け直して既存行まで動く。最長行は 96 桁で変更前と同じ、`nix fmt -- --ci` は 0 changed(§4.2 で実測)。
4. **`docs/architecture.md` を名指しして終える。** description の役目は「この現象があること」と
   「直し方が 1 行あること」までで、背景は architecture.md が持つ。

### 3.5 却下した案

**(A) `osConfig` を読んで `warnings` を足す。** §3.1 の実測のとおり **技術的には書ける**
(`cfg.defaultEditor && osConfig != null && (osConfig.environment.variables.EDITOR or null) != null`)。
**却下の理由は 4 つあり、いずれも単独で十分である:**

1. **本 issue の範囲外。** #69 は `docs(hm)` であり、本文が「So: write it down. No code change.」で
   締められている。コードを足すなら別 issue である。
2. **一番効かせたい場面で黙る。** `osConfig` が `null` になるのは standalone home-manager、すなわち
   **NixOS 上で home-manager を standalone で使っている構成**であり実在する一般的な形である。
   そこでは警告が一切出ない。**「出るときと出ないときがある警告」は、出なかったときに
   「NixOS は EDITOR を設定していない」という誤った安心を与える。**
3. **誤検知する。** `osConfig.environment.variables.EDITOR` はユーザが自分で `"nvim"` に設定していても
   非 null である(§1.4 の `plainOverride`)。値で分岐すると、今度は `nvim` 以外の妥当な値
   (ラッパースクリプトのパス等)を誤検知する。
4. **nvimx の warnings の既存方針と合わない。** 現在の warnings は
   `nix/home-manager/default.nix:314-338` の 4 本(degraded mode / 未知の overrides・nixpkgsFallback 名 /
   nvim-treesitter 不在 / 未知の devPlugins 名)で、すべて
   **nvimx 自身の入力が誤っている / lock が足りない**ことを指す。種類が違う。

**(A2) `osConfig` を使わず `config.programs.{bash,zsh,fish}.enable` を見て警告する。**
(A) の 2 と 3 を回避する変種で、**実装も容易なので明示的に潰しておく**
(そうしないと実装レビューと PR レビューで必ず再提案される):

```nix
  warnings = lib.optional (cfg.defaultEditor && !(config.programs.bash.enable
    || config.programs.zsh.enable || config.programs.fish.enable)) "...";
```

3 つの `enable` は nvimx のモジュールから素直に読める —— §3.1 の実測の `hmShells` が
**standalone でも NixOS モジュール経由でも同じように読めている**ことがその裏取りである。
よって (A) の 2 は消え、`EDITOR` の値を見ないので (A) の 3 も消える。**それでも却下する:**

- **(A) の 1 と 4 はそのまま効く。**
- **この変種に固有の誤検知がある。** home-manager の FAQ(`docs/manual/faq/session-variables.md:8-27`)が
  **正規の手順として**「home-manager に管理させないなら `hm-session-vars.sh` を自分で source しろ」と
  書いており、`.profile` / `.zshrc` / fenv / babelfish の具体例まで載せている。その手順に従っている人
  —— つまり**何も壊れていない人**全員に警告が出る。3 つの `enable` はその source を検知できない。

**(B)-(F) 一言で足りるもの。** **`home.sessionVariables.EDITOR` を `lib.mkForce "nvim"` にする**:
比較が起きないので効果ゼロ、#67 §3.2 が却下した「手書き行を黙って潰す」副作用だけが残る。
**`assertions` で評価を落とす**: NixOS 側が `EDITOR` を設定しているだけで switch が失敗する。
**`builtins.pathExists /etc/NIXOS` で嗅ぐ**: 評価時の impurity で、nvimx の「完全に pure」という
土台(CLAUDE.md)を壊す(`osConfig` があるので不要でもある)。
**`programs.nvimx` に NixOS 用サブモジュールを足す**: 配布形態そのものを変える設計判断で、範囲外。
**README に専用の節を作る**: §3.3 決定 4。

**(G) `docs/architecture.md` の `[6] hm deployment:`(`:173-178`)に足す。** あそこは
**ビルド時フローで nvimx が deploy するものの列挙**であり、`:175` が既に
`home.sessionVariables.EDITOR = "nvim"` を載せている。NixOS の既定値は nvimx が deploy するもの
ではないので主語が変わる。#67 §5.4 が mermaid への追加を却下したのと同じ判断。

---

## 4. 既存機能との関係

### 4.1 挙動は 1 ビットも変わらない

`nix/home-manager/default.nix` で触るのは **`description` の文字列だけ**で、`type` / `default` /
`config` 側の配線(`:358`)には指一本触れない。`docs/architecture.md` / `README.md` は評価されない。
**`flake.nix` は差分ゼロ** —— 新しい check が無いので、`docs/architecture.md:517` の checks 列挙も
動かない(現在 **34 件**)。

**`flake.nix:393-396` のコメントは有効なまま**である:

```
                # A conflict has to stay a conflict. Silently picking a winner is worse either way:
                # mkDefault makes an option the user just enabled do nothing, and mkForce swallows a
                # line they meant to keep. The cure for the collision is deleting the other
                # definition, which is what the option's description says.
```

ここが言う「the collision」は **`home.sessionVariables.EDITOR` の衝突**、「the other definition」は
**home-manager 内部の定義**である。新段落が書く「on the NixOS side」の remedy は**別の層の別の話**であり、
description の該当段落(`:102-111`)は 1 文字も変わらないので、このコメントは腐らない。
**`flake.nix` を触る理由は無い。**

### 4.2 derivation が動かないことを実測で確認済み

作業ツリーのコピーをスクラッチに取り、§3.2 / §3.3 / §3.4 の**3 編集すべて**を当てて比較した
(baseline は変更前の commit を flake ref で固定して取った。理由は §8 手順 4):

```
$ git diff --stat
 README.md                    |  8 +++++++-
 docs/architecture.md         |  3 +++
 nix/home-manager/default.nix | 11 +++++++++++
 3 files changed, 21 insertions(+), 1 deletion(-)

$ nix fmt -- --ci
traversed 171 files
emitted 51 files for processing
formatted 51 files (0 changed) in 1.093s

$ nix eval .#checks.x86_64-linux.hm-module-default-editor.drvPath
"/nix/store/68zdik9q855yd4j54p4dpb2ingmmd7vy-hm-module-default-editor.drv"   # 変更前と同一

$ diff before.json after.json && echo "34 checks IDENTICAL"
34 checks IDENTICAL
```

**なぜ動かないのか**: `description` は `options` にしか現れず `config` には出ない。
`hm-module-default-editor` が `options` を読むのは **`flake.nix:377` の
`offEval.options.programs.nvimx.defaultEditor.default != false` 1 箇所だけ**(#67 §3.4 で 13 回目に
足した assert)であり、`description` は読まない。`:306` のコメント
「Only .config and .options are read; nothing is built.」も同じことを言っている。

README や option ドキュメントをレンダリングする check も無い。
`grep -n 'README\|architecture.md' flake.nix` の**全 5 件**は
`:907`(プラグイン fixture の `README.md` を `cp`)、`:946`(その fixture を `test -f` する対)、
`:2672` / `:2694` / `:3393`(いずれもコメント)である。

**`traversed 171 files` について**: この数は**本計画書を含む**(置く前は 170)。
`emitted 51` / `0 changed` は markdown が treefmt の対象外なので変わらない。

**この不変性は §8 で必ず測り直すこと。** 動いたら `description` を読む経路がどこかに増えており、
それ自体が設計の前提を壊している。

### 4.3 `docs/plans/67-hm-default-editor.md` は**更新しない**(意図的な drift)

`67` の §3.1 は `defaultEditor` の description を**逐語で**貼っているので、本件が段落を足すと
**そのスニペットは古くなる。それでよい。** 計画書は**自分の issue の記録**であり、後続の変更で
書き換えるものではない —— `for f in docs/plans/*.md; do echo "$f $(git log --oneline -- $f | wc -l)"; done`
は 17 行を出すが、17 本目は**本計画書自身**(未コミットなので `0`)である。残る 16 本のうち
15 本がコミット 1 本、唯一の 3 本(`67`)もすべて PR #68 のマージ(`74aa086`)より前、
つまり自分の PR 内のレビュー往復である。
**別の issue が既存の計画書を書き換えた例は 1 件も無い。** `67` §5.6 が「触らないもの」に
`docs/plans/` の既存ファイルを挙げているのも同じ趣旨である。**本節がその drift を宣言している**
ことをもって記録とする。

### 4.4 templates / `packages.demo` / lock パイプラインは無関係

- **templates**: `:48` に `# defaultEditor = true;` が #67 §5.5 で入っているが、本件が足すとしたら
  `environment.variables.EDITOR = lib.mkForce null;` であり、これは**NixOS モジュール側**の設定である。
  `templates/default` は **home-manager の dotfiles テンプレート**(`flake.nix:83`:
  "home-manager dotfiles template with nvimx integrated")なので置き場所が無い。
- **`packages.demo`**: `nvimxLib.makeEnv` を直接呼び `homeModules.nvimx` を通らない(#67 §4.4)。
- **`lua/**` / `nix/lib/**` / `nix/build-registry/**` / `tests/**`**: 一切触らない。

---

## 5. 実装手順

**ファイルは独立しているので順序の制約は無い**が、同一ファイル内は
**行番号の大きい方から当てるか、シンボルで位置決めすること**。

### 5.1 `docs/architecture.md`(2 箇所、下から当てる)

**編集 2(先に当てる): 表の直後の段落。** `:540`(空行)と `:541`(`## Implementation phases`)の
あいだに §3.2 の段落 1 行を入れ、その後ろにも空行を 1 行置く。
**編集 1: 表の行。** `:539`(`| lazy-lock.json entry with no matching plugin | ... |`)の
**直後の行として** §3.2 の表の行を挿入する。結果:

```
539  | lazy-lock.json entry with no matching plugin | ... |
540  | `defaultEditor` vs. NixOS's own `EDITOR` default | ... |     ← 編集 1
541  (空行)
542  **NixOS's own `EDITOR` default vs. ...**: ...                   ← 編集 2
543  (空行)
544  ## Implementation phases
```

合計 **+3 行**(表の行 1、空行 1、段落 1)。**実測済み**(§4.2 の diffstat `3 +++`)。

**他の architecture.md 編集はしない**: `:173-178` の `[6] hm deployment:`(§3.5(G))、
`:517` の checks 列挙(check が増えない)、`:551` の `7. **Finishing touches**`
(#67 §5.4 と同じ理由で、予告リストに後から名前を足さない)、mermaid(`:108-109`)、
設計原則(`:112-122`)。

### 5.2 `README.md`(1 箇所)

`:224` の 1 行を **§3.3 の 7 行で置き換える**(既存 2 文の文字は 1 つも変えず、折り返しだけを入れる)。
diffstat は `README.md | 8 +++++++-` になる。
**`:210` のセルは 1 文字も触らない**(§3.3 決定 4)。Options 表にも
`## Installation` のサンプル(`:53-64`)にも足さない。

### 5.3 `nix/home-manager/default.nix`(1 箇所)

`:111`(`nvimx and a hand-written line inside a flake it names neither.`)の直後に
**空行 1 行 + §3.4 の 10 行**を挿入する。`:112` の `'';` との間に余分な空行を作らないこと。
**インデントは半角 8 個**(§3.4 決定 3)。`:358` の `home.sessionVariables`、`type` / `default`、
`env` の description(`:293` 以降)はいずれも触らない。

### 5.4 触らないもの

**`flake.nix`**(§4.1。差分ゼロを `git diff --stat` で確認)、
**`nix/lib/**` / `nix/build-registry/**` / `lua/**` / `tests/**`**、
**`templates/default/flake.nix`**(§4.4)、
**`docs/plans/67-hm-default-editor.md`**(§4.3。**意図的に古くする**)、
**`.github/workflows/**`**(check が増えないのでステップも増えない)、
**`stylua.toml` / `.luacheckrc`**(lua を 1 行も触らないので `nix fmt -- --clear-cache` も不要)、
**`CLAUDE.md`**。

---

## 6. テスト

### 6.1 新しい check は作らない —— その判断の根拠

**本件には「固定すべき挙動」が 1 つも無い。** check が守れるのは評価結果であり、本件の成果物は
**散文**である。作れそうに見える 3 つを個別に潰しておく:

**(a)「NixOS の既定が `nano` であること」を check にする。** ——却下。`nvimx` の `checks` は
**nvimx の挙動**を固定する場所であり、これは **nixpkgs の挙動**である。さらに実害が 2 つ ——
`nixosSystem` を 1 つ評価するので**評価時間が跳ね上がる**; **nixpkgs が `nano` をやめた日に
nvimx の CI が赤くなる**が、そのとき壊れているのは nvimx ではなく本ドキュメントであり
直し方は docs の書き換えである(CI を止めるコストと釣り合わない)。
(「darwin で評価できない」は理由にならない —— `nixosSystem` の評価は host platform に依存せず、
check 自体は `runCommand` でどこでもビルドできる。上の 2 つで十分である。)

**(b)「`docs/architecture.md` に `nano` の行があること」を grep で check にする。** ——却下。
文書の**存在**しか守れず**内容が正しいこと**は守れない —— そして本計画で **29 度**覆ったのは
**まさに内容**である(冒頭の 29 点)。リポジトリに同種の前例も 1 件も無い(§4.2 の全 5 ヒットのとおり、
ドキュメントを読む check はゼロ)。ここで前例を作るなら全ドキュメントに同じ基準を適用する話になる。

**§8 手順 6a はこれの代わりにはならない。それを期待しないこと。** 6a は
**「既に誤りと判明した言い回し」に対する lint** であって、新しい誤りは 1 つも捕まえられない ——
実際、**29 個の誤りのうち 6a が捕まえられたものは 1 つも無い**。どれも既知の禁止文字列ではない。
**内訳は 3 つに割れる** —— **14 個は §1 を pinned tree から手で引き直したレビューが**、
**14 個(13 / 15 / 16-26 / 28)は出荷文を構文として読む §8 手順 5b が**、
**1 個(29)は出荷文を本計画の決定と突き合わせたレビューが**見つけている
(同じ突き合わせが誤り 30 も出しているが、あれは記録の側なのでここには数えない)。
後者は再導出では原理的に出ない(数値も引用も正しいまま、掛かり先だけが誤っている)。
6a 自身も両方向に壊れていた実績がある(round-4 の指摘: 存在しないパターンを含む一方、
README を折り返した瞬間に行単位の連言が無効化されていた)。
**本件で守りの中心になるのは §8 手順 5 の「目で読んで確かめること」であって、grep ではない。**

**(c)「description の drv が動かないこと」を check にする。** ——却下。**check 自身の drvPath が
その対象**なので自己言及になる。これは §8 手順 4 が外から測る種類の検証である。

### 6.2 代わりに守られているもの / 既存 check への影響

既存の `checks.hm-module-default-editor`(#67)は **7 本の assert** で `defaultEditor` の挙動を
固定しており、本件はその**どれにも触れない**。そして 34 件すべての drvPath が一致する(§4.2)ので
`nix flake check` は 1 件も再ビルドせず、`nix fmt -- --ci` は `0 changed` である。
**「挙動を変えていない」ことの機械的な証明はこの drvPath 一致であり、§8 手順 4 がそれを実測する。**

---

## 7. リスク / 未決事項

**R1: 上流が変わると記述が腐る。** 残るリスクであり、緩和はするが消えない。
**緩和**は出荷文に**上流の行番号を書かない**こと(§3.2 決定 1)、**数と全称量化子を書かない**こと
(決定 7 / 10)、そして **display-manager の実装に踏み込まない**こと(決定 3)である。
**残る**のは、nixpkgs が `EDITOR` の既定値をやめる / `sessionVariables` 側に移す /
zsh・fish・xonsh の init の形を変える、home-manager が FAQ を書き直す、といった変更を
検知できないこと。§6.1(a) のとおり **check で捕まえるべきではない**と判断したので、
これは**明示的に引き受ける**。本計画 §1.2-§1.6 が**行番号と rev 込みで**当時の事実を記録して
いるので、将来ずれたときに「何がどう変わったか」は追える —— rev は冒頭の 4 本で確認した nixpkgs
`7525d999cd850b9a488817abc89c75dc733acf17` / home-manager `079a3b5d1aa6a719920a51316253b7d6dd22738d`。

**R2: `mkForce null` の副作用(実測)。** `shells-environment.nix:231` が `sessionVariables` を
`variables` にマージするので、**`environment.sessionVariables.EDITOR` を自分で設定しているユーザ**が
`variables` 側を `mkForce null` にすると、その定義の shell init からの export も消える(PAM 側は残る)。
§1.4 の `mk`(`.config` を返す版)を使った実測:

```
$ nix eval --impure --json --expr '
let
  flake = builtins.getFlake (toString ./.);
  nixpkgs = flake.inputs.nixpkgs;
  mk = extra: (nixpkgs.lib.nixosSystem {
    system = "x86_64-linux";
    modules = [
      { boot.loader.grub.enable = false; fileSystems."/" = { device = "none"; fsType = "tmpfs"; }; system.stateVersion = "25.05"; nixpkgs.hostPlatform = "x86_64-linux"; }
      extra
    ];
  }).config;
  ev = e: let c = mk e; in {
    vars = c.environment.variables.EDITOR or null;
    sess = c.environment.sessionVariables.EDITOR or null;
    pam  = builtins.match ".*EDITOR.*" (builtins.replaceStrings ["\n"] [" "] c.environment.etc."pam/environment".text) != null;
  };
in {
  sessionSet               = ev { environment.sessionVariables.EDITOR = "nvim"; };
  sessionSetPlusForcedNull = builtins.tryEval (ev {
    environment.sessionVariables.EDITOR = "nvim";
    environment.variables.EDITOR = nixpkgs.lib.mkForce null;
  });
}'
{"sessionSet":{"pam":true,"sess":"nvim","vars":"nvim"},
 "sessionSetPlusForcedNull":{"success":true,"value":{"pam":true,"sess":"nvim","vars":null}}}
```

**ドキュメントには書かない** —— そのユーザは**そもそも `nano` を見ない**ので、この文が説明している
状況に到達しない。到達しない読者向けの注意書きで最長の記述を伸ばさない。ここに記録する。

**R3: 「home-manager が管理するシェル」の範囲。** FAQ(§1.5)が名指しするのは bash / zsh / fish の
3 つだが、`hm-session-vars` を読む箇所は `modules/` 全体では 3 つ + `xsession.nix:210` +
`targets/generic-linux.nix:80` である。**出荷文は FAQ の言う 3 つをそのまま引用する** ——
自前で数え直すと上流が増やしたときに腐るし、FAQ を引用している限り
「上流がそう言っている」以上の主張はしていないことになる。

**R4: description は恒久的に出荷される。** `homeModules.nvimx` の一部であり、ユーザ側の
home-manager が生成する option ドキュメントに出る。**後から削るのは足すより難しい**ので、
§3.4 決定 1 で「確実なことだけ」に削り 10 行(既存 22 行の半分以下)に収めた。なお、この repo に
`home-manager-options` という **flake output は存在しない**(`outputs` は `lib` / `homeModules` /
`packages` / `formatter` / `checks` / `apps` / `templates`)。恒久性は「モジュールを取り込む限り出る」
ことから来るので主張自体は成り立つが、**出力名を根拠にしないこと。**

**R5: それでも「報告された」とは書かない。** 計画レビューの過程で、issue の症状は
**実機で再現している**(ログインの fish が `nvim`、ログインの bash が `nano`、`nano` は PATH に無く、
`/etc/set-environment:6` に `export EDITOR="nano"` が実在)。§1.5 の表と §3.2 の remedy の主張は
**§1.7 の装置で実シェルを起動して**確認済みである(10 セル / 40 値。誤り 10 は 10 セル目 =
socket 行で出た)。
**それでも出荷文には「報告された」とは書かず「起こりうる」形で書く**(§3.2 の段落:
"why one machine can answer `nvim` in one shell and `nano` in another") —— 測ったのは 1 台であり、
ドキュメントはその 1 台の構成を主語にする場所ではない。
なお §1.5 の補足が挙げる「自前の `~/.bash_profile` があると鎖が切れる」形は**まだ測っていない**ので、
そちらは引き続き出荷文に書かない。
測っていないことを測ったように書かない。

**R6: 因果の鎖を 2 つの表の行に割らないこと。** §3.2 は**表の行(590 字、表で 3 番目)と
散文の段落(2,419 字、散文で 2 番目)**に分ける構成を採ったが、**鎖そのものを割るのは別の話で、
それは採らない** ——「NixOS が設定していること」「どこから export されるか」「シェルによって
結果が割れること」「直し方」は**一続きの因果**であり、割ると片方だけ読んだ人が
「nvimx のバグだ」または「`mkForce` を付ければ直る」という誤った結論に届く。段落にすれば
鎖は 1 つのまま、表は眺められる粒度に戻る。**同じ長さで 3 箇所に書くのも最悪の選択である** ——
README(§3.3)と description(§3.4)はこの段落を指すための短い導線として設計してある。

---

## 8. 検証手順(実装完了時に必ず全部通す)

**計画レビューで一部が実行済みであっても、実装後に全手順を改めて通すこと。**
§1 / §3.1 / §4.2 の実測はスクラッチのコピーで行ったものであり、実装ツリーの上で
**実際に走らせた結果**をもって完了とする。

**下のブロックは「対話シェルに貼る」ものではなく、ファイルに落として `bash <file>` で走らせるもの。**
round-16 まで、失敗ガードは `... || { echo "FAIL: ..."; false; }` と書かれていた ——
**`false` は何も止めない。** 終了コードも残らず、`FAIL` の 1 行がスクロールで流れれば
**残り全部が「通った」ように見える**。これが本計画 14 個目の fail-open で、
**しかも他の 13 個の修正を全部「助言」に格下げしていた**(round-16 の指摘)。
→ **すべての FAIL ガードを `exit 1` に変えた**(**49 箇所**。内訳は
手順 1 が 3、手順 2 が 1、手順 3 が 1、手順 4 が 3、**6a が 15**、**6b が 3**、**6c が 11**、
**6d が 8**、**6e が 2**、**手順 7 が 2** —— 3+1+1+3+15+3+11+8+2+2 = 49。
**ほかに 6e の `perl` 呼び出しに裸の `|| exit 1` が 1 本**あり、
これは `exit 1; }` を数える grep には出ない。**手順 5 と 5b は 0 本** —— 下に理由を書く)。

**手順 5 / 5b にガードが 0 本なのは意図的である。**(round-24。**書いていなかったので明記する。**)
手順 5 のコメントには期待値が 9 つ並んでいる(`→ 8 件`、`→ :65 / :74 / :75`、`→ 7 件`、
`→ :103-104`、`→ bash.nix:268 の 1 件のみ`、`→ :221 / :271 の 2 件のみ`、`→ lib.optional が 5 回`、
pinned rev 2 本)—— **形だけ見れば「コメントに期待値、コードは印字」そのもの**で、
21 回潰してきた fail-open と同じ形に見える。**それでも guard にしない。理由は 3 つある**:
- **検査対象が違う。** 手順 6 が見るのは**このリポジトリの 3 ファイル**で、実装が壊しうる。
  手順 5 が見るのは **pinned な上流ツリー**(`$NIXPKGS` / `$HM`)で、**本件の実装では動かない** ——
  動くとすれば `flake.lock` を更新したときで、それは本件の範囲外である(R1)。
- **guard にすると意味が変わる。** 手順 5 の仕事は「値が一致すること」ではなく
  **「引いた根拠を人が読み直すこと」**である(§6.1(b))。上流の行番号が動いたときに
  **止めるのではなく、読み直して §1 を書き換える**のが正しい振る舞いで、
  `exit 1` はその判断を機械に肩代わりさせてしまう。
- **`:2136` が既にそう書いている** —— 手順 5 は「コマンドを流すだけでなく目で読んで確かめること」。
**したがって手順 5 / 5b は「値を読む」ではなく「根拠を読み直す」手順であり、
内訳には 0 として載せる。**9 つの期待値は round-24 に全部再現することを確認済み。
**内訳は必ず数えてから書くこと。3 回続けて数え違えている**:
- round-20 に「30 箇所、6a が 13」—— **足すと 31 で、6a は 12 だった**(round-21 の指摘)。
- round-22 に「43 箇所」の**節ごとの内訳は正しかった**のに、
  **round ごとの内訳が 45 になっていた**(round-23 の指摘。round-22 分を 8 と書いたが 6 だった)。
- round-23 に節ごとに数え直したら **50 と出た** —— 差の 1 本は**説明文の中に引用した guard の形**で、
  コメント行を除いていなかった。**正しくは 49。**
**数え方を固定する。スコープを書かない数え方は数え方ではない** —— 「行頭が `#` でない行のうち
`exit 1; }` を含むもの」だけでは**計画書の散文まで数えてしまう**(round-24 の実測では §8 の
散文に 3 行、うち 1 行は**数え方を述べた文自身**だった —— round-23 の 3 度目の数え違いと
同じ自己参照である。**この注記を足したことで散文側の件数は更に増えている。だから総数ではなく
スコープを固定する**)。
**scope は「§8 の ```bash フェンスの内側」**で、そこを取り出してから数える。**逐語で貼る**:

```
P=docs/plans/69-editor-nixos-layering.md
awk '/^## 8\./{s=1} s&&/^```bash$/{f=1;next} f&&/^```$/{exit} f' "$P" > /tmp/s8.sh
grep -v '^#' /tmp/s8.sh | grep -c 'exit 1; }'                      # → 49
awk '/^# \(6[a-e]\)/{sec=substr($0,3,4)} /^# --- [0-9]/{sec="step"substr($0,7,2)} \
     !/^#/ && /exit 1; }/{n[sec]++} END{for(x in n) printf "%3d %s\n", n[x], x}' /tmp/s8.sh | sort -k2
#   → 3 step1 / 1 step2 / 1 step3 / 3 step4 / 15 (6a) / 3 (6b) / 11 (6c) / 8 (6d) / 2 (6e) / 2 step7
```

**この 2 本が数える範囲の外に、ガードが 1 本ある** —— 6e の `perl … || exit 1` は
`exit 1; }` の形をしていないので文字列では出ない。**49 + 1 = 50 が実数**である。
**数が合わない内訳は、次に数える人に「ガードが 1 本消えたのか」を調べさせる。**
**この 49 本のうち、最初から在ったのは 0 本である。** 全部が
「印字して目で見る」を fail-open として指摘されて足したもので、
**fail-open の通し番号で 14 から 21 まで**(下の箇条書きは 11 本 —— **通し番号でない項目が 3 つ**
あるため。「21 回に分かれている」と書いていたのは誤りで、**21 は回数ではなく通し番号**である):
- **14(round-16)**: `... || { echo "FAIL"; false; }` の `false` が何も止めていなかった。**7 本**。
- **15(round-17)**: 手順 4 の `diff … && echo`(drvPath が動いても exit 0。ハッシュ 1 つで実証)、
  手順 4 のリテラルハッシュ、手順 2 / 3、6a の `$FORBID` **陽性対照**。**5 本**。
- **16(round-18)**: `$FORBID` の**本体**(陽性対照だけ guard にして本体を残した)。**1 本**。
- **17(round-19)**: 6d の note 位置と空行(「数値で assert すること」と太字で書いた直下)。**2 本**。
- **18(round-20)**: 6d の**幅と行範囲** —— `96` / `246` / `54 / 98` / `block 88-124` /
  段落の行数 / 算術が全部印字だけで、**§8 に幅のガードが 1 本も無かった**。
  README を 12 桁と 112 桁を含む 7 行に折り直しても §8 は通り、description は 147 桁まで通った。**6 本**。
- **19(round-21)**: **6a に残っていた印字 3 本** —— `## Options` の陽性対照、
  README の remedy 名 0 件(§3.3 決定 2 が「6a が確かめる」と書いている)、
  `~/.profile` の 3 件。note の末尾に 1 行足すだけで `docs/architecture.md: 2` を**印字して
  exit 0 した**(1 行なので shortstat も 6e も動かない)。**3 本**
  —— うち陽性対照の 1 本は、**round-17 が `$FORBID` について出した指摘を同じ 6a の中で
  適用し忘れていたもの**である。
- **README のアンカー slug**(round-21。fail-open ではなく**被覆の穴**)——
  **本件で唯一のファイル間不変量**なのに、長さを変えないタイポで静かに壊れた。**2 本**。
- **20(round-22)**: **6b / 6c に残していた「対になる不変量の片側」** —— `/etc/profile` の 3 ファイル、
  `mkForce null` の 3 ファイル、表の行の `mkForce`。**どれも片割れだけが guard だった**
  (`~/.profile` と README の remedy 名は round-21 で guard、対になる側は印字のまま)。
  表の行に `` Or `mkForce null`. `` を足しても —— **表の行自身が挿入行なので shortstat は
  `21/1` のまま**、`^|` も 38、`$FORBID` に `mkForce` は無く、行の幅は無ガード、
  6e は純粋な追加なので不動 —— §8 は exit 0 した。**再入するのは誤り 7 の類である。**
  description に ` See /etc/profile.` を足しても同じく通った。**6 本**。
- **手順 7 の darwin 2 本**(round-22)—— 裸で並んでいたので、1 本目が落ちて 2 本目が通れば
  exit 0 で終わる。`CLAUDE.md` の言う「ローカルで darwin の評価エラーを捕まえる唯一の手段」である。**2 本**。
- **21(round-23)**: **6c に残っていた 5 本** —— `nano` の 2/1/3、remedy の 2、表の行が 1 本、
  その行の remedy が 1、`^|` が 38。**このうち前の 2 つは §2 の goal 1 / goal 2 そのもの**で、
  **§8 で唯一 guard でない検査が、計画の 2 つの到達目標だった**。
  しかも 4 本は「未編集ツリーで落ちる」一覧に**編集が入った証拠として名前が載っていた**。
  description の末尾に ` Try nano.` を足すと(75 桁)—— 幅も 10 行も `21/1` も 0 changed も
  drvPath も 6e も動かず、**6a の逐語 assert は部分一致なので当たり続け** —— `4` を印字して
  手順 6 は exit 0 した。**round-22 が表の行に当てた手口を、同じブロックの隣の行に当てただけ。**
  `[ -f ]` を含めて **6 本**。
- 残り **9 本**は誤り 29 / 30 に対する 6a の逐語 assert と、`[ -f ]` / 6e の 2 本である。
  —— 合計 7+5+1+2+6+3+2+6+2+6+9 = **49**。
**同じ形で 5 回やった。共通するのは 2 つだけ**:
- **「assert する」「〜であること」と書いた文の下は、コードが `exit 1` に解決するか毎回確かめること。**
  §8 の 12 個の「assert」のうち、round-19 まで 2 個が、round-20 まで 1 個が印字だった。
- **ガードを 1 本足したら、同じブロックの残りを同じ目で見ること。**
  21 件のうち **8 件(14-21)は「ガードを足した round に、その隣で再演した」形**だった。
  **21 は、20 を直した次の round に、同じブロックの隣の行で同じ手口が通った。**
  **「この節はもう閉じた」と書いた文が、4 回とも次の round に反証されている** ——
  round-20 / 21 / 22 / 23。**閉じたと書くなら、閉じたことを確かめるコマンドを一緒に書くこと。**
  **19 は枠を「名指しせよ」と書き直したその文が、数えずに書いたので偽だった。**
  **20 は、数えて書き直した枠が、今度は「対になる不変量の片側」を覆っていた。**
  **ガードを 1 本足したら、その不変量に対になる側が無いかを必ず見ること** ——
  `~/.profile` / `/etc/profile`、README の remedy 名 / 表の行の `mkForce`。
  **どちらも決定が 1 組として書いているのに、guard は片側にしか付いていなかった。**
**「印字して目で見る」は guard ではない、が本計画で 3 度繰り返した誤りである**
(round-16 の `false`、round-17 の `&& echo` と陽性対照)。
**コメントに期待値を書いたら、その場で `[ … ] || { echo FAIL…; exit 1; }` にすること。**
**貼り付けて走らせないこと** —— `exit 1` は対話シェルそのものを閉じる。
`set -e` を足す手も検討したが採らない: 期待値が `0` の `grep -c` が何本かあり
(6c の `grep -c 'mkForce'` など)、**成功しているのに exit 1 を返して途中で止まる**。
ガード側を `exit 1` にするのが、期待値 0 の行を巻き込まない唯一の形である。

```bash
cd /home/myuron/ghq/github.com/myuron/nvimx

# --- 1. 触ったファイルが 3 つだけであること ---------------------------------
# **`:!docs/plans/` を外さないこと。** 本計画書は git 管理下にある(.claude/skills/nvimx-change/
# SKILL.md:14)ので、コミット後は 4 つ目のファイルとして本計画書まるごとの差分を持ち込み、
# 下の期待値と一致しなくなる。
# **空の出力を成功と取り違えないこと。** `git diff --stat <base>..HEAD` は HEAD == base でも
# 「まだコミットしていない」でも「base を間違えた」でも**何も出さず exit 0** する ——
# 手順 4 の git stash と同じ穴なので、行数を数えて明示的に落とす:
BASE=74aa086b98d349a718c6a8d70f192804d617b319
if git rev-parse --verify -q HEAD >/dev/null && [ "$(git rev-parse HEAD)" != "$BASE" ]
then RANGE="$BASE..HEAD"; else RANGE="HEAD"; fi     # コミット済みなら範囲、未コミットなら HEAD 比較
# **`RANGE=""` にしないこと** —— 裸の `git diff` は index と比較するので、`git add -A` 済みだと
# n=0 で FAIL し、下の porcelain は 3 を返して**両者が食い違う**(実測)。`HEAD` なら両方 3 になる。
n=$(git diff --stat $RANGE -- ':!docs/plans/' | tee /dev/stderr | grep -c '|')
[ "$n" = 3 ] || { echo "FAIL: 3 ファイルのはずが $n"; exit 1; }
# **件数も assert すること**(round-15)—— ファイル数だけでは、§5.1 が要求する
# 「note の後ろの空行」の落ちを拾えない(6d の空行ガードと 2 重に塞ぐ):
git diff --shortstat $RANGE -- ':!docs/plans/' \
  | grep -q '21 insertions(+), 1 deletion(-)' \
  || { echo "FAIL: 21 insertions / 1 deletion でない"; exit 1; }
#   → README.md 8 +++++++- / docs/architecture.md 3 +++ / nix/home-manager/default.nix 11 +++++++++++
#     (3 files changed, 21 insertions(+), 1 deletion(-)。§4.2 の実測値と一致すること)
#   flake.nix / templates/ / lua/ / tests/ が出たら間違い(§5.4)
# **untracked も見ること** —— `git diff` は見ないので、§1.7 の作業ファイルを
# リポジトリ内に置いてしまうと goal 5 が通ったまま `git add -A` 一発で PR に入る
# (だから §1.7 は `mktemp -d` の中で作業する)。**期待値は上の分岐と連動する** ——
# 未コミットなら 3 行(` M README.md` / ` M docs/...` / ` M nix/...`)、
# **コミット済みならツリーは clean なので 0 行**が正しい:
git status --porcelain -- ':!docs/plans/'
[ "$RANGE" = HEAD ] && exp=3 || exp=0   # 未コミットなら 3 行、コミット済みならツリーは clean で 0
a=$(git status --porcelain -- ':!docs/plans/' | grep -c .)
[ "$a" = "$exp" ] || { echo "FAIL: untracked/modified が $exp 行のはずが $a"; exit 1; }

# --- 2. 整形 + lint(treefmt は nix と lua だけ。markdown は対象外)----------
# **`&& echo` でも裸でもなく、落ちたら止めること**(round-17。下の手順 4 と同じ 15 個目の
# fail-open の族)。`nix fmt -- --ci` は 0 changed なら exit 0、変更があれば非 0 を返す:
nix fmt -- --ci || { echo "FAIL: nix fmt -- --ci が 0 changed でない"; exit 1; }
#   → traversed 171 files / emitted 51 / formatted 51 files (0 changed)

# --- 3. フルチェック(linux)-------------------------------------------------
nix flake check || { echo "FAIL: nix flake check"; exit 1; }

# --- 4. derivation が 1 つも動いていないこと(本件の要)-----------------------
# **リテラルのハッシュも目視でなく assert すること**(round-17)——
# 「文字列まで一致すること」とコメントに書いてあるだけでは、動いた値がそのまま印字されて通る:
d=$(nix eval --raw .#checks.x86_64-linux.hm-module-default-editor.drvPath)
[ "$d" = /nix/store/68zdik9q855yd4j54p4dpb2ingmmd7vy-hm-module-default-editor.drv ] \
  || { echo "FAIL: hm-module-default-editor の drvPath が $d"; exit 1; }
#   → 1 文字でも違えば description を読む経路が増えている(§4.2)
#
# baseline は **変更前の commit を flake ref で固定して**取る。rev は省略形では通らないので
# フル 40 桁で書くこと。git stash を使わないこと —— **コミット済みだと stash が空振りし、
# before と after が同じツリーから取られて diff が無条件に通る**(実測: "No local changes to
# save" で exit 0。しかも古い stash があるとそれを pop してしまう)。
BASE=74aa086b98d349a718c6a8d70f192804d617b319
nix eval --json --apply 'cs: builtins.mapAttrs (n: c: c.drvPath) cs' \
    "git+file://$PWD?rev=$BASE#checks.x86_64-linux" > /tmp/before.json
nix eval --json --apply 'cs: builtins.mapAttrs (n: c: c.drvPath) cs' \
    .#checks.x86_64-linux > /tmp/after.json
# **件数は assert すること。**空ファイル 2 つは diff が通って成功を印字する ——
# 手順 1 と同じ fail-open で、コメントに「→ 34」と書くだけでは防げない:
for f in /tmp/before.json /tmp/after.json; do
  n=$(grep -o '"[a-z0-9-]*":' "$f" | wc -l)
  [ "$n" = 34 ] || { echo "FAIL: $f のキーが 34 でなく $n"; exit 1; }
done
# **`&& echo` を guard の代わりにしないこと —— これが 15 個目の fail-open だった**(round-17)。
# drvPath が 1 つでも動くと `diff` は `1c1` と 3 KB の JSON を 2 行吐くが、**`FAIL` の行は
# 出ず、スクリプトも止まらない**。§8 の最終 exit コードは最後の `nix eval` のものになるので、
# **不変量が壊れたまま §8 全体が exit 0 する**(round-17 がハッシュを 1 つ書き換えて実証)。
# 前提(キー 34 件)の側だけが `exit 1` guard で、**本体の比較が素通しだった** ——
# 「前提を守って本体を守らない」形は §8 手順 1 の n=3 / shortstat と同じ組である:
diff /tmp/before.json /tmp/after.json \
  || { echo "FAIL: drvPath が動いた(上の diff がどの check か示している)"; exit 1; }
echo "34 checks: drvPath identical"

# --- 5. 事実の再検証(★本件で唯一、この種の誤りを捕まえた実績のある手順)-------
# **本計画の §1.2-§1.6 / §3.1 / R2 に貼ったコマンドと式を、実装ツリーで 1 つ残らず通し直すこと。**
# そこが、引用したすべての file:line と実測値の出どころである。ここに重複して並べない。
# 出荷文の事実誤りは 29 個見つかっており、**そのうち 14 個はこの再導出の族で見つかっている**
# (§6.1(b))。特に §1.3(d)(e) —— 4 シェルの内訳、既定 false の 3 つはファイルごと無いこと、
# xsessionWrapper の DM ごとのばらつき。誤り 1-4 の出どころである(誤り 7 も §1.4 の `nix eval` から出ている)。
# **コマンドを流すだけでなく目で読んで確かめること。**
#
# **§1.7 は意図的にこの一覧から外してある。再実行は要求しない。**
#   誤り 8-11 と 14 / 27 の出どころではあるが(12 は §1.3(d) から)、(a) 装置自身が 2 度壊れて載った、
#   (b) `ssh` 越しに流すと 4 セルが**正当な理由で**変わる(stdin)、
#   (c) その自己診断は pty 経路の汚染も `/run` の bind 忘れも検出できない(§1.7 で実測)。
#   実装者は 3 つの文面を貼って手順 1-4 / 6-7 を通すだけでよい。
#   **出荷文の remedy の主張を書き換えるときだけ** §1.7 の 40 値に立ち返ること ——
#   そのときは表全体を突き合わせるのが唯一の検証で、自己診断を関門にしないこと。
#
# --- 5b. 出荷文を「構文として」読む(★再導出では出ない誤りがここで出る)-------
# **先に「裁定済み」の 3 箇所を挙げておく。ここを誤りとして再発見しないこと**(round-23)——
# **どれも手順 2b で止まる読みであり、直すと別の誤りが入る。**
#   (1) 段落の **「a `mkForce` in nvimx would change nothing」** ——
#       直前の **「nvimx cannot fix this:」のコロンが話題を固定している**ので、
#       「この問題については」が読みの既定であり、真である。
#       **話題を外した読みなら偽になる** —— nvimx 内部では `mkForce` は結果を変える
#       (`nix/home-manager/default.nix:102-111` の hm 内部の衝突がそれである)——
#       が、その読みは**文自身の話題を無視しないと取れない**。2b の停止規則に当たる。
#   (2) 段落が名指しするシェルモジュールは **3 つ**で、`programs.xonsh` が入っていない
#       (`xonsh.nix:89` は 4 つ目の `setEnvironment` 消費者である。§1.3(d))。
#       **量化を担っているのは「whichever shell module NixOS has enabled」の方**で、
#       3 つは決定 7 / 10 が選んだ**例示**である。**網羅リストとして読まないこと** ——
#       網羅にすると決定 7(上流モジュールの実数を固定しない)に反する。
#   (3) **表の行と README は症状を「hm 管理外のシェル」だけに絞り**、段落と description は
#       **非ログイン bash も名指ししている**。**これは意図した要約である**(決定 8 / §3.3 決定 2)——
#       短い 2 文はどちらも続きへ渡している(行の「…the full chain, **the limits**」、
#       README のアンカーリンク)。**4 文の強さを揃えるのは remedy の限界についてであって
#       (決定 15)、症状の列挙についてではない。**
# **誤り 13 と 15 は、どちらも数値・引用・測定がすべて正しいまま起きている。**
# 13 は同格句が手段側に掛かっていたこと、15 は非制限 `, which` が `a login shell` を
# 先行詞に取って事実の逆を述べていたこと —— **どちらも §1 を何度再導出しても出ない。**
# 4 つの出荷文(表の行 / 段落 / README の 1 文 / description)を、意図ではなく**文法**で読む:
#
#   1. **4 つの出荷文すべての代用形を、1 つ残らず表に起こす。**(★ round-14 で追加)
#      拾う対象: `it` / `its` / `itself` / `them` / `they` / `this` / `that` / `those` /
#      `both` / `one` / `another` / **主要部を省いた所有格** / **指示詞 + 主要部名詞** /
#      関係代名詞 / **VP 省略**(`does` / `is not`)/ **主語省略** / 加算の `too` / 照応の `same`。
#      表は 4 列(代用形 | 文法上いちばん近い先行詞 | 意図した先行詞 | 判定)。
#      **編集した節だけでなく 4 文すべてを覆うまでレビューを終えないこと** ——
#      round-13 までの誤り 15 / 18 / 23 / 25 / 26 は、どれも
#      「直した節の隣が代名詞のまま残った」形で出ている。**網羅性がこの手順の要である。**
#
#      **「同一文内に名前の先行詞があること」を不変条件にしてはならない。** round-14 が実測:
#      4 文で束縛点は **34**、うち同一文内条件に違反するのは **11**、そのうち欠陥は **1** のみ
#      (真陽性率 9%)。しかも **11 のうち 6 つは決定 19 自身の修正**
#      (`That definition` / `That bash` / `The two module systems` /
#      `the non-login bash above` / 命題を指す `this` / `both`)——
#      **この条件を強制すると決定 19 を巻き戻すことになり、それは誤り 16-24 の作り方そのものである。**
#
#      **実際に効いている区別は「距離」ではなく「代用形の形」である**(14 回で例外なし):
#      - **裸の代名詞と省略された主要部**(`it` / `its` / `them` / `theirs` / `both` / `does`)——
#        誤り 16 / 19 / 20 / 21 / 22 / 23 / 24 / 25 / 26 は**全部ここ**にある。
#      - **指示詞 + 主要部名詞、あるいは定名詞句**(`that line` / `That bash` /
#        `The two module systems`)—— **14 回で欠陥ゼロ**。主要部名詞が型選択をするので、
#        裸の代名詞にできないことができる。
#      したがって規則は: **裸の代名詞と省略主要部は、最も近い先行詞が意図した先行詞でなければならない。
#      そうでなければ「指示詞 + 主要部名詞」に格上げする(注釈で救わない)。
#      主要部名詞さえ在れば文をまたいでよい。** これは手順 2 / 2b / 3 がすでに言っていることで、
#      欠けていたのは**網羅性だけ**だった。
#   2. それぞれについて、**文法上いちばん近い先行詞**(VP 省略なら同定できる VP)を当てる。
#   2b. **停止規則。**「最も近い読みで文が**意味の通る偽**になるもの」だけを欠陥として挙げる。
#      型が合わずに読者が即座に読み直すもの(ファイルが export する、環境がファイルに到達する、
#      「オプションを resolve する」など)は**記録に留め、語順を変えない**。
#      これが無いと、同じ段落で人によって 10 件にも 5 件にもなる(round-12 の parse は
#      26 の束縛点を数え、偽の整形式読みは 5 件だった)。
#   3. その読みで文が偽になるなら、**語順を変えて直す**(注釈を足して救わない)。
#      前置修飾(「a non-login bash started ...」)は関係節や同格句より先行詞が動かない ——
#      **ただし前置修飾に直しても、後続の PP / 分詞をまたぐ関係節には手順 2 をもう一度当てること**
#      (誤り 15 の修正が `, which` を `a clean environment` に残した実例。誤り 18)。
#      **またげないなら文を割って主節にするのが唯一確実な直し方である**(誤り 16 / 17 の直し方)。
#   4. 数量詞があれば**量化の領域**を確かめる —— シェルの「プログラム」か「起動のしかた」か。
#      **数量詞を持つ文どうしが同じ語を使っていること**(現在は段落と description の 2 文だけ。
#      表の行は決定 18 で、README は決定 2 で数量詞そのものを持たない —— **「無い」を欠陥として
#      直さないこと**。直すと誤り 12/13/14 が再発する)。
#
# **手順 4 には現在のツリー上の題材が無い。** **誤り 14 の出どころは §1.7 の 40 値との突き合わせ**
# であって 5b ではない(だから再導出側の 14 個に数えてある。冒頭 / goal 4 / §6.1(b) と同じ。
# **誤り 27 も同じ理由で再導出側である** —— §1.7 結論 2 との突き合わせで出ている)——
# **手順 4 はその判定を一般化して手順にしたもの**である。そして決定 18 がその節ごと削除したので、
# いま 5b を回しても再浮上しない —— **正しい挙動である**。
# 手順 1-3 の方は誤り 13 / 15 / 16-26 / 28 がそのまま題材になる。
# **これをやったのは round-10 以降のレビューと、round-12 で本計画自身が 1 度だけで、
# それまで手順としては存在していなかった。**(本計画自身の 5b が誤り 23 / 24 を出している ——
# **自分の草稿にも当てること。**)**30 番目**があるとすれば、まずここで出る(29 までは閉じている)。
NIXPKGS=$(nix eval --raw --impure --expr '(builtins.getFlake (toString ./.)).inputs.nixpkgs.outPath')
HM=$(nix eval --raw --impure --expr '(builtins.getFlake (toString ./.)).inputs.home-manager.outPath')
nix eval --raw --impure --expr '(builtins.getFlake (toString ./.)).inputs.nixpkgs.rev'       # → 7525d999...
nix eval --raw --impure --expr '(builtins.getFlake (toString ./.)).inputs.home-manager.rev'  # → 079a3b5d...
#   flake.lock のノード名を直に読まないこと。ルートは nixpkgs_2 / home-manager_2 であり、
#   素の nixpkgs ノード(d407951...)は agent-skills の input である(冒頭の注意)。
grep -rn 'system.build.setEnvironment' "$NIXPKGS/nixos/modules/"   # → 8 件 = 定義 2 + シェル 5 行(fish が :178 と :208 の 2 行)+ emacs 1
grep -n 'SYS_BASHRC\|SSH_SOURCE_BASHRC\|NON_INTERACTIVE_LOGIN_SHELLS' "$NIXPKGS/pkgs/shells/bash/5.nix"
#   → :65 / :74 / :75。3 つとも §1.5 の主語(「ログインシェルでない bash」)と 10 セル目が依存する
sed -n '63,71p' "$NIXPKGS/nixos/modules/services/x11/display-managers/default.nix"  # → :68 が . /etc/profile
grep -rn 'sessionData.wrapper' "$NIXPKGS/nixos/modules/"                            # → 7 件 = DM 5 種 + 定義 1 行(:236)+ コメント 1 行(:62)
grep -rn 'nixos-env-preinit' "$NIXPKGS/pkgs/by-name/fi/fish/package.nix"            # → :103-104(読み手は fish 本体)
grep -rn 'home.file.".profile"' "$HM/modules/"   # → bash.nix:268 の 1 件のみ(§3.2 決定 5 の根拠)
grep -n 'sessionVarsStr' "$HM/modules/programs/bash.nix"   # → :221 定義 / :271 使用の 2 件のみ
#   = home-manager は bash の session vars を ~/.profile にしか置かない(§3.2 決定 13 の根拠)
sed -n '180,203p' "$NIXPKGS/nixos/modules/programs/bash/bash.nix"
#   → ブロック全体。:190-192 が /etc/profile を source し、**:195 の if [ -n "$PS1" ] ガードの
#     *外側* にある**こと(対話性の条件は bash 側の SYS_BASHRC にある。§1.5)
# warnings は **編集後の行番号で :325-349**(§3.4 の +11)。行番号をベタ書きすると
# 編集前の値で書いてしまう罠があるので、シンボルで範囲を取る:
sed -n '/^    warnings =/,/^    home\.packages/p' nix/home-manager/default.nix
#   → lib.optional が 5 回出る(warnings 4 本 + home.packages 行の 1 つ)。§3.5(A) の 4

# --- 6. 書いたものの整合 -----------------------------------------------------
# (6a) **既に誤りと判明した言い回しに対する lint。**新しい誤りは捕まえない(§6.1(b))。
#      2 つの落とし穴を踏まないこと:
#      (1) **行単位で grep しない。** README も description も折り返されているので、禁止語句は
#          改行をまたぎうる。3 ファイルとも空白を正規化してから走らせる。
#          (round-4 の実測: README を 7 行に折り返した瞬間、行単位の `instead` ガードは
#           7 行中 5 行が両方のトークンを持たなくなり、事実上無効化されていた。)
#      (2) **パターンは実在の文言に合わせる。** 過去の混入文字列は
#          "all seven of its modules" / "home-manager documents none of this" なので、
#          `seven ` と `documents none` の両方を入れる(`seven of its` だけでは後者を逃す)。
# **パターンは 1 度だけ書いて変数に入れ、陽性対照を先に通すこと。**
# `[ -f ]` はファイルの存在しか証明しない —— **alternation が生きていることは証明しない**。
# `'every shell'"'"'s'` の引用は壊れやすく、1 文字ずれると 0 件になって**合格に見える**
# (実測: 2 箇所を壊すと合成文字列でのヒットが 7 → 5 に落ちる)。§8 が 2 ブロック先で
# 自分に課している「ゼロを信じる前に陽性側で確かめる」を、ここにも当てる:
FORBID='no matter what\|seven \|documents none\|never sees it\|GUI session\|systemd user unit\|every shell'"'"'s'
# **陽性対照こそ assert にすること**(round-17)—— **この 3 行上で「1 文字ずれると 0 件になって
# 合格に見える」と自分で書いておきながら、対照の側が印字だけだった**。7 が 5 でも通っていた:
n=$(printf "no matter what seven documents none never sees it GUI session systemd user unit every shell's\n" \
      | grep -o -- "$FORBID" | wc -l)
[ "$n" = 7 ] || { echo "FAIL: \$FORBID が壊れている($n 件。7 のはず)"; exit 1; }
# **本体も guard にすること —— これが 16 個目の fail-open だった**(round-18)。
# round-17 で**陽性対照だけ**を `exit 1` にして、**lint 本体は印字のままにしていた** ——
# 手順 4 で自分が名指しした「前提を守って本体を守らない」形を、**その同じ round に 6a で再演した**。
# 実証(round-18): 段落に `; a GUI session never sees it.` を混ぜると `FORBIDDEN` が 2 行出るのに、
# **`exit 1` guard は 17 本すべて通り**(冠詞 1/1、逐語 4 句とも 1、`nano` 2、`^|` 38、
# note 位置 1、空行 1、shortstat も `21 insertions(+), 1 deletion(-)` のまま)、**§8 は exit 0 した**。
# 誤り 1 / 3 の族を出荷文に抱えたまま「全部通った」になる。
# **「合否条件を持つ検査は 6a-6e に 1 つ残らず guard である」—— この文を書くのは 3 度目で、
# 前の 2 回はどちらも偽だった。** 今回は**数えて確かめた**:
#   節ごとに guard を数えるときは **コメント行を必ず除くこと** —— §8 の散文には
#   guard の形をそのまま引用している行が複数あり、素朴に数えると水増しになる
#   (round-23 に実際に踏んだ: 50 と出たが本当は 49 で、差の 1 本はこの説明文自身だった)。
#   **数え方**: 行頭が `#` でない行だけを対象にし、節の見出し行で区切って集計する。
#   **そのうえで、合否条件を持つ行が全部 guard であること**を別に確かめる。
#   **この確認自体に 3 つの穴があることを承知して使うこと**(round-24 に明示):
#     (a) **列を 1 桁目で切ると `for … do … done` の中が丸ごと落ちる** ——
#         49 本のうち **13 本**(手順 4 を入れると 14 本)はループの中にあり、
#         **生き残っている `printf` 4 本も全部ループの中**である。ループの中も見ること。
#     (b) **行単位なので、既存の guard 行に `;` で足した検査や、既存パイプラインに足した段は
#         「新しい行」にならない。** round-22 / 23 が突いたのはまさにその形である。
#     (c) **6e の `perl … || exit 1` は `exit 1; }` の形をしていないので文字列では出ない。**
#   **言えない行があれば、それが次の fail-open である。5 回ともそうだった。**
# **印字だけが残っている行は 6 行、種類では 3 つ**(**「種類」と「行数」を混ぜないこと** ——
# round-16 で一度名指しした取り違えである)—— 6a / 6b / 6c の `printf` が **4 行**、
# 6d の `cut -c1-60` が 1 行、6d の `echo "$a"` が 1 行。
# **どれも合否条件を持たない** —— `printf` と `echo "$a"` は**隣の行が既に assert している値**を
# そのまま表示しているだけで、`cut -c1-60` は目視の補助である
# (**この 1 行だけはコマンドから始まる裸の `grep` でもある** —— 行頭は
# `grep -A3 -E "$ROW" …` で、末尾の `cut` で呼んでいるにすぎない。
# **「裸の grep は 1 本も無い」と書くとこの行で偽になる**ので、そうは書かない。
# 見ている中身 —— 表の行 / 空行 / note / 空行の並び —— は 6d の note 位置ガードと
# 空行ガードが別に assert している)。
# **この枠は 4 度、「自分で assert すると書いた行」を覆い隠す向きに働いた** ——
# round-19(6d の note 位置・空行)、round-20(6d の幅・行範囲)、
# round-21(6a の陽性対照・remedy 名 0 件・`~/.profile` の 3 件)、
# **round-22(6b の `/etc/profile`、6c の `mkForce null` と表の行の `mkForce`)**。
# **3 度目は、この枠を「名指しする」よう書き直したその文自体が偽だった**
# (「6b / 6c だけ」と書いた時点で 6a に印字が 3 本残っていた)。
# **4 度目は、枠の中身を数えて書き直した文が、今度は「覆ってよい」と言った側で偽だった** ——
# 6b / 6c に残した件数のうち 3 つは、**片割れだけが guard になっている不変量**だった
# (`~/.profile` は guard で `/etc/profile` は印字、README の remedy 名は guard で
#  表の行の `mkForce` は印字)。**誤り 10 / 12 / 26 と同じ「片側だけ適用」である。**
# **枠を書くなら、枠の中身を数えるだけでなく、覆う側の各項目に「対になる不変量」が
# 無いかを見ること。** 枠は 4 回とも、数えた範囲の外側で嘘になった。
# → round-22 で枠そのものを畳んだ。**覆う対象がもう無い。**
# **`$FORBID` だけが「0 行であること」という合否条件つきの lint として書かれている。**
for f in docs/architecture.md README.md nix/home-manager/default.nix; do
  [ -f "$f" ] || { echo "FAIL: $f がない"; exit 1; }   # 読めないと空出力 = 合格の signature になる
  hits=$(tr '\n' ' ' < "$f" | tr -s ' ' | grep -o -- "$FORBID" | sed "s|^|FORBIDDEN $f: |")
  [ -z "$hits" ] || { printf '%s\n' "$hits"; echo "FAIL: $f に禁止語句"; exit 1; }
done     # → 1 行も出ないこと(出たら止まる)
#      **`instead` のガードは廃止した。** 決定 2 で README から remedy の名指しごと消えたので、
#      禁止語が入りうる文そのものが無く、ガードは常に 0 を返す(=何も検査しない)。
#      代わりに **決定 2 そのもの**を見る —— README の当該段落に remedy 名が 1 つも無いこと。
#      **行範囲をベタ書きしないこと**(折り返しが 6 行や 8 行になるとガードが段落から外れる。
#      round-4 で 1 度直したのと同じ穴):段落の範囲は見出しの間から求める。
#      **`awk` の join も空白 1 個で繋ぐので、折り返しをまたいだ `environment.` / `variables` を
#      逃す。**(1) と同じ理由で、切り出したあと `tr` で正規化してから見ること:
#      **ゼロを信じる前に、切り出しが当たっていることを陽性側で確かめること** —— 見出しを
#      改名しても README を読めなくしても、remedy 名がこの節の外にあっても、このガードは 0 を返す
#      (実測)。6c が `mkForce` の 0 を `grep -cE "$ROW"` の 1 と対にしているのと同じ形にする:
# **この 2 本も guard にすること —— 19 個目の fail-open**(round-21)。
# **3 行上で「ゼロを信じる前に、切り出しが当たっていることを陽性側で確かめること」と書いておきながら、
# その陽性対照が印字だけだった** —— round-17 が `$FORBID` について出した指摘
# (「陽性対照こそ assert にすること」)を、**同じ 6a の中で適用し忘れていた**。
n=$(sed -n '/^## Options$/,/^### /p' README.md | tr '\n' ' ' | tr -s ' ' \
      | grep -c 'can also look like it does nothing')
[ "$n" = 1 ] || { echo "FAIL: ## Options の切り出しが外れている($n。1 のはず)"; exit 1; }
n=$(sed -n '/^## Options$/,/^### /p' README.md | tr '\n' ' ' | tr -s ' ' \
      | grep -o 'mkForce\|environment\.variables' | wc -l)
[ "$n" = 0 ] || { echo "FAIL: README の当該段落に remedy 名が $n 件(0 のはず。§3.3 決定 2)"; exit 1; }
#      `~/.profile` は **architecture.md の段落に 1 回だけ**許す(§3.2 決定 13 の bash 例外)。
#      他の 2 ファイルでは 0 件であること:
# **`~/.profile` の 3 件も guard にすること**(round-21。上と同じ 19 個目)。
# 実証: note の末尾に 1 行 `` Every shell reads `~/.profile` here. `` を足すと ——
# 1 行なので shortstat は `21/1` のまま、6a の逐語 span の外なので 6e も 39 のまま ——
# `docs/architecture.md: 2` と**印字して、§8 は exit 0 した**。
for f in docs/architecture.md README.md nix/home-manager/default.nix; do
  [ -f "$f" ] || { echo "FAIL: $f がない"; exit 1; }   # 読めないと空出力 = 合格の signature になる
  case "$f" in docs/architecture.md) e=1 ;; *) e=0 ;; esac
  n=$(tr '\n' ' ' < "$f" | tr -s ' ' | grep -o -- '~/\.profile' | wc -l)
  printf "%s: %s\n" "$f" "$n"
  [ "$n" = "$e" ] || { echo "FAIL: $f の ~/.profile が $n 件($e のはず。§3.2 決定 13)"; exit 1; }
done     # → docs/architecture.md: 1 / README.md: 0 / nix/home-manager/default.nix: 0
#      (`every shell` を裸で禁止しないこと —— #67 が書いた既存の description
#       「in every shell still running」に当たってしまう。禁止するのは `every shell's` である。)
# **決定が逐語で命じた語が、出荷文に実在することも見ること**(round-16。誤り 29)。
# `$FORBID` は「入ってはいけない語」しか見ない。誤り 29 は**逆向き** ——
# 決定 10 が命じた**不定冠詞**が表の行と description の両方で `the` になっていた、という形で、
# **禁止語の 0 件ガードでは原理的に出ない**。数値も構文も正しく、決定とだけ食い違う:
# **ここは目視ではなく assert にすること。** 誤り 29 は「16 回のレビューが目で読んで素通りした」
# 種類の食い違いで、**値を印字するだけのガードは 16 回ぶん役に立たなかった実績がある**
# (実測: 表の行の `a` を `the` に戻しても、印字だけの形では §8 全体が exit 0 のまま通った):
a=$(grep -c 'a system-wide shell init that NixOS generates' docs/architecture.md)     # 表の行
b=$(tr '\n' ' ' < nix/home-manager/default.nix | tr -s ' ' \
      | grep -c 'a system-wide shell init that NixOS generates')                      # description(折り返しをまたぐ)
[ "$a/$b" = "1/1" ] || { echo "FAIL: 決定 10 の不定冠詞が $a/$b(どちらも 1 のはず)"; exit 1; }
for f in docs/architecture.md nix/home-manager/default.nix; do
  n=$(tr '\n' ' ' < "$f" | tr -s ' ' | grep -c 'the system-wide shell init')
  [ "$n" = 0 ] || { echo "FAIL: $f に定冠詞が戻っている($n 件)。決定 10 / 21"; exit 1; }
done
# **決定が逐語で引いている他の句も同じように assert する**(round-17。誤り 30)。
# round-17 が見つけたのは**逆向きの危険**である —— 決定 10 / 11 / 14 に**古い文面**が
# 逐語で残っており、上の突き合わせを素直にやった実装者が**出荷文を決定の側へ「直して」しまう**。
# 戻る先は誤り 20(`it generates`)・誤り 23/24(`so it drops`)・誤り 28(`and what does` /
# `them`)・決定 21 が名指しで拒否した `that` 落としで、**全部が既に潰した形**である。
# 決定側は round-17 で最終形に直したので、ここでは**出荷文の側を固定する**:
for q in "but only once you enable those modules" \
         "the hm-session-vars file home-manager generates" \
         "so that line drops NixOS's export" \
         "does not source hm-session-vars unless you source it yourself" \
         "mkForce null; is not a fix" \
         "Letting home-manager manage the shell works too, outside the non-login bash above."; do
  n=$(tr '\n' ' ' < docs/architecture.md | tr -d '`' | tr -s ' ' | grep -c -- "$q")
  [ "$n" = 1 ] || { echo "FAIL: 段落の「$q」が $n 件(1 のはず)"; exit 1; }
done
n=$(tr '\n' ' ' < nix/home-manager/default.nix | tr -d '`' | tr -s ' ' \
      | grep -c -- 'the hm-session-vars file home-manager generates')
[ "$n" = 1 ] || { echo "FAIL: description の hm-session-vars 句が $n 件(1 のはず)"; exit 1; }
# **description の末尾**(round-18。誤り 30 の 8 件目)。`is not a fix` に戻しても
# 68 桁にしかならず、ブロック最長 96 も 10 行も `mkForce null` の 1 件も動かない ——
# **§8 の他のどのガードも見ていない唯一の句**なので、逐語で固定する:
n=$(tr '\n' ' ' < nix/home-manager/default.nix | tr -d '`' | tr -s ' ' \
      | grep -c -- "mkForce null is no fix; see nvimx's docs/architecture.md.")
[ "$n" = 1 ] || { echo "FAIL: description 末尾が $n 件(1 のはず。is not a fix に戻っていないか)"; exit 1; }
# **note の mkIf 対比**(round-18。決定 21 がこれを逐語で引いている):
n=$(tr '\n' ' ' < docs/architecture.md | tr -s ' ' \
      | grep -c -- '-- directly under `config`, with no `mkIf` and no enable option')
[ "$n" = 1 ] || { echo "FAIL: 段落の mkIf 対比が $n 件(1 のはず)"; exit 1; }
n=$(tr '\n' ' ' < README.md | tr -s ' ' | grep -c -- 'and what resolves it')
[ "$n" = 1 ] || { echo "FAIL: README の「and what resolves it」が $n 件(1 のはず)"; exit 1; }
# **まず 3 ファイルが在ることを assert する(手順 6 全体の前提)。** 6a のループには round-11 で
# `[ -f ]` を足したが、6b / 6c の裸の複数ファイル `grep -c` には無かった —— **README.md を
# 消して実測したところ、残る 2 行が文書どおりの値を出し、欠けた 1 行の期待値がちょうど `0` で、
# 「無い」と「0 件」が見分けられなかった**(`grep` の exit 2 は誰も見ていない)。
# しかも 2 行下の「値だけを見ること」がその気づきを潰す。
for f in docs/architecture.md README.md nix/home-manager/default.nix; do
  [ -f "$f" ] || { echo "FAIL: $f がない"; exit 1; }
done
# (6b) /etc/profile は architecture.md の段落 1 行にしか現れず、そこでは必ず /etc/zshenv と同居する。
# **`~/.profile` と同じ per-file loop にすること —— 20 個目の fail-open**(round-21 / round-22)。
# 決定 5 はこの 2 つを**1 組**として扱っているのに、**round-21 は `~/.profile` だけを guard にした**
# —— 誤り 10 / 12 / 26 と同じ「片側だけ適用」である。
# 実証(round-22): description の末尾に ` See /etc/profile.` を足すと 6b が `1` を印字するのに、
# 幅は 96 のまま、10 行のまま、shortstat も `21/1` のまま、
# **6a の description 末尾の逐語 assert も `grep -c` が行単位なので当たり続け**、§8 は exit 0 した。
for f in docs/architecture.md README.md nix/home-manager/default.nix; do
  [ -f "$f" ] || { echo "FAIL: $f がない"; exit 1; }
  case "$f" in docs/architecture.md) e=1 ;; *) e=0 ;; esac
  n=$(grep -c '/etc/profile' "$f")
  printf "%s: %s\n" "$f" "$n"
  [ "$n" = "$e" ] || { echo "FAIL: $f の /etc/profile が $n 件($e のはず。§3.2 決定 5)"; exit 1; }
done
#   → docs/architecture.md:1  README.md:0  nix/home-manager/default.nix:0
n=$(grep -n '/etc/profile' docs/architecture.md | grep -c '/etc/zshenv')
[ "$n" = 1 ] || { echo "FAIL: /etc/profile と /etc/zshenv の同居が $n 件(1 のはず。決定 10)"; exit 1; }
# **手順 6 の性格について正直に書いておく。**(round-14 に `74aa086` で実測し直した値である。)
# **未編集のツリーでも通るもの**は 3 種類ある(round-16 で (iii) を足した)。**(i) 退行ガード** —— 4 つ:
#   6a のループ(0 件)、`## Edge cases` 見出しの存在、
#   `awk` のブロック最長 96(編集前のブロックが既に 96)、README のファイル最長 246(`:23` が既に 246)。
# **(ii) ハーネスの自己診断** —— `$FORBID` の陽性対照、3 ファイルの `[ -f ]` ブロック、
#   6a の 2 つのループ内 `[ -f ]`。**どのツリーでも通るのが正しい** —— 検査対象は文面ではなく
#   ガード自身だからである(round-15 の指摘。退行ガードと混ぜて数えない)。
# **(iii) 期待値が `0` のもの** —— これは**編集が入ったことを示せない**。未編集ツリーでも 0 だからである:
#   6c の `grep -E "$ROW" | grep -c 'mkForce'`、README 段落の
#   `grep -o 'mkForce\|environment\.variables' | wc -l`、そして
#   `/etc/profile` / `~/.profile` / `mkForce null` の **README.md と default.nix の側のセル**。
#   **どれも陽性対照か非ゼロのセルと対にしてあり、単独では読まないこと**
#   (`grep -cE "$ROW"` が 1、`## Options` の陽性対照が 1、同じ行の architecture.md 側が 1)。
#   **round-15 まで「残りはすべて編集が入ったことを実際に示す」と書いていたが、それは偽だった**
#   (round-16 の指摘)。
# **残り —— つまり期待値が非ゼロのものは、すべて未編集ツリーで落ちることを実測してある**
#   (round-16 に `74aa086` の素のツリーで全部流した。値は「未編集 → 期待値」):
#   `nano` 0/0/0 → 2/1/3、`environment.variables.EDITOR = "nvim"` 0 → 2、
#   `grep -cE "$ROW"` 0 → 1、`mkForce null` の architecture.md / default.nix 側 0/0 → 1/1、
#   `^|` 37 → 38、README のアンカー 0 → 1、note の位置ガード 0 → 1、note の後ろの空行 0 → 1、
#   option ブロック `88-113` → `88-124`、README 段落の行数 1 → 7、その最長 200 → 98、
#   6b の `/etc/profile`(0 対 1)と `/etc/zshenv` の同居(0 対 1)、
#   architecture.md の `~/.profile`(0 対 1)、`## Options` の陽性対照(0 対 1)。
#   **6b を「未編集でも通る」側に数えていたのは誤りだった**(round-14 の指摘)。
# **`grep -c` を複数ファイルに掛けたときの出力順は引数順とは限らない**(並列 grep では
#  変わる)。値だけを見ること —— 順序を検査にしないこと。
# (6c) 本体が入っていること。**6a 自身が禁じているとおり、行番号はベタ書きしない** ——
#      どれも内容で位置決めする(round-4 の教訓を 6c / 6d にも適用したのが round-7)。
ROW='^\| `defaultEditor` vs\. NixOS'
# **この 5 本も guard にすること —— 21 個目の fail-open**(round-23)。
# **§2 の goal 1 と goal 2 がここにある** —— `nano` の 2/1/3 と remedy の 2 は、
# goal の本文が逐語で引いている値そのものである。**それが §8 で唯一 guard でない検査だった。**
# **しかも 4 本は「未編集ツリーで落ちる」一覧に「編集が入った証拠」として名前が載っている。**
# 実証(round-23): description の末尾に ` Try nano.` を足すと(75 桁、96 以下)——
# 幅も 10 行も shortstat `21/1` も `nix fmt` の 0 changed も drvPath も全部そのまま、
# 6e は純粋な追加なので不動、**6a の逐語 assert も部分一致 `grep -c` なので当たり続ける** ——
# 6c が `3` ではなく `4` を**印字して、手順 6 は exit 0 した**。
# **round-22 が表の行に当てた手口を、同じブロックの隣の行に当てただけである。**
for f in docs/architecture.md README.md nix/home-manager/default.nix; do
  [ -f "$f" ] || { echo "FAIL: $f がない"; exit 1; }
  case "$f" in docs/architecture.md) e=2 ;; README.md) e=1 ;; *) e=3 ;; esac
  n=$(grep -c 'nano' "$f")
  printf "%s: %s\n" "$f" "$n"
  [ "$n" = "$e" ] || { echo "FAIL: $f の nano が $n 件($e のはず。§2 goal 1)"; exit 1; }
done
#   → docs/architecture.md:2  README.md:1  nix/home-manager/default.nix:3
# **効く remedy が名指しされていること**(§3.2 決定 14/15)。表の行と段落の両方に入る:
n=$(grep -c 'environment.variables.EDITOR = "nvim"' docs/architecture.md)
[ "$n" = 2 ] || { echo "FAIL: remedy の名指しが $n 件(2 のはず。§2 goal 2)"; exit 1; }
n=$(grep -cE "$ROW" docs/architecture.md)
[ "$n" = 1 ] || { echo "FAIL: 表の行が $n 本(1 のはず)"; exit 1; }
n=$(grep -E "$ROW" docs/architecture.md | grep -c 'environment.variables.EDITOR = "nvim"')
[ "$n" = 1 ] || { echo "FAIL: 表の行に remedy が $n 件(1 のはず)"; exit 1; }
# 取り消し側は段落と description に 1 件ずつ。**表の行にも README にも出てはいけない**:
# **これも guard にすること —— 20 個目の fail-open**(round-22)。
# **同じ不変量の README 側だけが round-21 で guard になっていた**(`grep -o 'mkForce\|...'`)——
# また「片側だけ適用」である。しかも**再入するのは誤り 7 の類** ——
# `mkForce null` を表の行に remedy として載せる形で、本計画が最初に潰した誤りそのものである。
# 実証(round-22): 表の行の末尾に `` Or `mkForce null`. `` を足すと `2` と `1` を印字するのに、
# **shortstat は `21/1` のまま**(表の行自身が挿入行なので行数が変わらない)、`^|` も 38 のまま、
# `$FORBID` は `mkForce` を持たず、行の幅は無ガード、
# **6e も見えない**(最後の引用 span より後ろへの純粋な追加 —— 6e 自身の記録済みの盲点)。
for f in docs/architecture.md README.md nix/home-manager/default.nix; do
  [ -f "$f" ] || { echo "FAIL: $f がない"; exit 1; }
  case "$f" in README.md) e=0 ;; *) e=1 ;; esac
  n=$(grep -c 'mkForce null' "$f")
  printf "%s: %s\n" "$f" "$n"
  [ "$n" = "$e" ] || { echo "FAIL: $f の mkForce null が $n 件($e のはず。§3.2 決定 14 / goal 2)"; exit 1; }
done
#   → docs/architecture.md:1  README.md:0  nix/home-manager/default.nix:1
n=$(grep -E "$ROW" docs/architecture.md | grep -c 'mkForce')
[ "$n" = 0 ] || { echo "FAIL: 表の行に mkForce が $n 件(0 のはず。決定 14)"; exit 1; }
#   (0 が「行が無い」でないことは **`grep -cE "$ROW"` の guard**(上の `[ "$n" = 1 ]`)が
#    保証している。付けないと 0 が二義的になる。**round-22 まではその `grep -cE` 自身が印字で、
#    この文が根拠として挙げていたものが何も強制していなかった**——round-23 で guard にした。
#    なお行が丸ごと消えた場合は 6d の note 位置ガードも落ちるが、**この文が引くべきなのは
#    同じ不変量を見ている上の guard の方である。**)
# **アンカーは 2 つとも guard にすること**(round-21)。**本件で唯一のファイル間の不変量**で、
# **他に 1 つも覆いが無い** —— slug の**長さを変えないタイポ**(`limitations` → `limitatioms`)は
# 幅も `54/98` も算術も shortstat も 6a の逐語 assert も動かさず、**6e にも見えない**
# (6e の断片正規表現は `#` / `[` / `]` を含まず、空白 4 つ以上を要求するので slug は候補にならない)。
# 実測: それでも **§8 は exit 0 した** —— README の唯一の仕事(architecture.md への誘導)が
# 壊れたまま全部通る。
n=$(grep -c 'edge-cases-and-explicit-limitations' README.md)
[ "$n" = 1 ] || { echo "FAIL: README のアンカー slug が $n 件(1 のはず)"; exit 1; }
n=$(grep -c '^## Edge cases and explicit limitations' docs/architecture.md)
[ "$n" = 1 ] || { echo "FAIL: architecture.md の見出しが $n 件(1 のはず)"; exit 1; }
# **2 本で 1 組である** —— slug は見出しから GitHub が生成する形(小文字化・空白をハイフン)
# でなければリンクが死ぬ。**片方だけを直さないこと。**
n=$(grep -c '^|' docs/architecture.md)
[ "$n" = 38 ] || { echo "FAIL: architecture.md の表の行が $n 本(38 のはず。変更前 37)"; exit 1; }
# (6d) 形が壊れていないこと。**ここも内容で位置決めする。**
grep -A3 -E "$ROW" docs/architecture.md | cut -c1-60
#   → 表の行 / 空行 / 段落(**NixOS's own ... で始まる)/ 空行
# **note の「位置」を数値で assert すること。** 表の行は
# 「**The note right below this table** has the full chain」と出荷しているのに、
# **段落をファイルのどこへ動かしても数値ガードは全部通る**(実測: note を `:300` 付近へ移しても
# `nano` 2/1/3・`/etc/profile` 1/0/0・`~/.profile` 1/0/0・`mkForce null` 1/0/1・remedy 2・
# `$ROW` 1・`^|` 38 がすべて不変)。目視の `cut -c1-60` だけが頼りだったので、1 行足す:
# **round-19 まで、この行も次の空行の行も「印字するだけ」だった** —— **17 個目の fail-open**。
# 見出しに「数値で assert すること」と太字で書いておきながら、**コードは数を印字しただけ**で、
# 上の「目視の `cut -c1-60` だけが頼りだった」を**目視 2 本に増やして終わっていた**。
# 実証(round-19): note を表の上へ移すと —— 表の行の「The note right below this table」が
# **偽になる構成** —— 2 本とも 1 ではなく 0 を印字するのに、**§8 は FAIL 無しで exit 0 した**。
n=$(grep -A2 -E "$ROW" docs/architecture.md | tail -1 \
      | grep -c "^\*\*NixOS's own \`EDITOR\` default vs\.")
[ "$n" = 1 ] || { echo "FAIL: note が表の直下にない($n。1 のはず)"; exit 1; }
# **note の後ろの空行も数値で assert すること**(round-15)。§5.1 はそれを要求しているのに、
# 落としても `n=3` も `^|` 38 も note-placement 1 も `nano` 2/1/3 も全部通り、
# `## Implementation phases` は空行が無くても見出しとして描画される ——
# **目視の `cut -c1-60` だけが見ていた**。手順 1 の `git diff --shortstat` と合わせて 2 重に塞ぐ:
n=$(grep -A3 -E "$ROW" docs/architecture.md | tail -1 | grep -c '^$')
[ "$n" = 1 ] || { echo "FAIL: note の後ろの空行が $n 件(1 のはず)"; exit 1; }
#   (**shortstat との 2 重は「行を消した」場合しか効かない** —— note ごと動かされると
#    挿入行数は変わらないので、この guard だけが見ている。)
# **幅と行範囲も全部 guard にすること —— これが 18 個目の fail-open だった**(round-20)。
# round-19 まで `96` / `246` / `54 / 98` / `block 88-124` は**全部印字だけ**で、
# **§8 のどこにも幅のガードが 1 本も無かった**。実証(round-20): README の段落を
# **12 桁と 112 桁**(README 自身の p90 = 99 を超える)を含む 7 行に折り直しても、
# **§8 は FAIL 無しで exit 0 した**。description 側も同じで、**147 桁**まで広げても
# `nix fmt -- --ci` は 0 changed、§8 も無言だった。
# **他のガードは原理的に見えない** —— 行数が 7 のままなら shortstat は `21/1` のまま、
# 6a / 6e は空白正規化しているので折り返しは不可視、そして**下の算術ガードは数学的に見えない**:
# 語の並びが同じなら `joined` は折り返しに対して不変で、`sum = joined - (n-1)` は `n` だけで決まる。
# **`n=7 sum=576 joined=582` は 7 行の折り返し同士を 1 組も区別できない。**
r=$(awk '/^    defaultEditor = lib\.mkOption \{/{f=NR} f&&/^    \};$/{print "block "f"-"NR; exit}' \
      nix/home-manager/default.nix)
[ "$r" = "block 88-124" ] || { echo "FAIL: option ブロックが $r(block 88-124 のはず。37 行。§3.4)"; exit 1; }
w=$(awk '/^    defaultEditor = lib\.mkOption \{/{f=1} f{print length($0)} f&&/^    \};$/{exit}' \
      nix/home-manager/default.nix | sort -n | tail -1)
[ "$w" = 96 ] || { echo "FAIL: option ブロックの最長が $w 桁(96 のはず)"; exit 1; }
w=$(awk 'length($0)>0 && $0 !~ /^\|/ {print length($0)}' README.md | sort -n | tail -1)
[ "$w" = 246 ] || { echo "FAIL: README のファイル最長が $w(246 のはず)"; exit 1; }
# **ファイル全体の最長は退行ガードにすぎない**(`:23` が既に 246 なので、新しい行が 245 桁でも
# 黙って通る)。§3.3 が課した「**54-98 字**」は**書き換えた段落そのもの**で測ること:
# 切り出しが当たっていることを先に確かめる(6a / `## Options` と同じ陽性対照):
n=$(sed -n '/^`lockDir` is the only option/,/^$/p' README.md | grep -v '^$' | wc -l)
[ "$n" = 7 ] || { echo "FAIL: README 段落が $n 行(7 のはず。切り出しが外れていないかも見ること)"; exit 1; }
mm=$(sed -n '/^`lockDir` is the only option/,/^$/p' README.md | grep -v '^$' \
       | awk '{print length($0)}' | sort -n | sed -n '1p;$p' | tr '\n' '/')
[ "$mm" = "54/98/" ] || { echo "FAIL: README 段落の最短/最長が $mm(54/98/ のはず)"; exit 1; }
#   → 54 / 98(§3.3 の折り返しと一致。98 は description 側の 96 に対応する、README 側の実効ガード。
#     **§3.3 本文の「§8 手順 6d が `54 / 98` を assert する」は round-20 まで偽だった。**)
# **§3.3 が本文で数えている算術も、ここで測り直すこと**(round-16)——
# round-15 で出荷文を差し替えたとき、**§3.3 の 4 つの数字が 16 字ぶん古いまま残っていた**。
# **文字数で数えること** —— ロケールを固定しないと em dash 1 つで 2 バイトぶんずれる:
a=$(LC_ALL=C.UTF-8 sed -n '/^`lockDir` is the only option/,/^$/p' README.md | grep -v '^$' \
      | LC_ALL=C.UTF-8 awk '{n++; s+=length($0)} END{printf "n=%d sum=%d joined=%d", n, s, s+n-1}')
[ "$a" = "n=7 sum=576 joined=582" ] || { echo "FAIL: README 算術が $a"; exit 1; }
#   **この 3 つは幅のガードにはならない**(上の注記のとおり `joined` は折り返し不変)——
#   §3.3 の本文と一致していることだけを見る。幅は上の `54/98/` が見ている。
echo "$a"
#   → n=7 sum=576 joined=582(§3.3 の値と一致すること。`LC_ALL=C` だと 578 / 584 で、
#     §3.3 はその両方を書いている。**どちらか一方に合えば合格、にしないこと**)

# (6e) **決定と出荷文の対応を機械で閉じる**(round-19。誤り 30 —— 9 件まで数えた「決定が
#      古い文面を最終形として名乗る」誤りの、**手作業でない**始末)。
#      6a の逐語ループは**知っている句**しか見ない。9 件のうち 8 件は 6a に載せる前に
#      レビューが見つけたもので、**載せていない句はいくらでもある**。
#      6e は逆から閉じる —— §3.2-§3.4 の決定から英文断片を全部取り出し、
#      **出荷文 4 本に存在しないもの**を集め、その**集合のダイジェスト**を突き合わせる。
#      **期待値は「0 件」ではない**(当時の案・却下案は残す設計なので 0 にはならない)。
#      **「この 39 件ちょうど」**である —— 追加・削除・すり替えのどれでも落ちる。fail-closed。
#      **正規化は空白と `` ` `` / `*` の除去だけ。句読点も大小文字も潰さないこと** ——
#      誤り 30 の 8 件目(`is not a fix` 対 `is no fix`)も 9 件目(`;` 対 `.`)も
#      **句読点の差だけ**なので、潰すと両方素通りする(round-19 に実測。最初に書いた版が
#      まさにそれで、陽性対照で落ちた)。
#      **落ちたときは印字される差分を 1 行ずつ裁定すること** —— 6e が言えるのは
#      「集合が変わった」までで、どちらが正しいかは言わない(決定 20 / 21)。
#      **盲点**: **純粋な追加**は見えない —— 正しい引用を残したまま
#      「4 語以下 / 25 字未満」の短い断片を足すと、件数もダイジェストも動かない
#      (round-20 が `"the system-wide shell init"` を決定 10 に足して実証。
#      6a の冠詞 assert も出荷ファイルしか見ないので同じく見えない)。
#      閾値を下げた掃き出し(2 空白 / 12 字)で 29 断片を追加確認し、**どれも無害**だった。
#      **§3.2-§3.4 の散文を編集したら、裁定したうえで 39 とダイジェストを測り直すこと。**
#      (期待値の更新は「直した」ではなく「裁定し直した」の記録である。)
#      **なお 6e は出荷文の退行ガードとしても効く** —— round-20 の 12 本の変異のうち
#      `wherever any definition is read at all` の削除、`both shells` → `both`、
#      `NixOS itself sets` の語順戻し、`nothing nvimx sets` → `nothing here`、
#      `exports EDITOR` → `exports it`、`NixOS's value` → `NixOS's` の 6 本は
#      **6e だけが捕まえた**(決定が逐語で持っている句だからである)。
cat > /tmp/sweep6e.pl <<'PL'
use strict; use warnings; use utf8; binmode(STDOUT,':utf8');
my ($plan,$arch,$readme,$mod)=@ARGV;
sub slurp { open(my $h,'<:utf8',$_[0]) or die "$_[0]: $!"; local $/; <$h> }
sub norm { my $t=shift; $t =~ s/[`*]//g; $t =~ s/\s+/ /g; $t =~ s/^ | $//g; $t }
my ($A,$R,$M)=(slurp($arch),slurp($readme),slurp($mod));
my $corp='';
$corp .= " $1" while $A =~ /^(\| `defaultEditor` vs\. NixOS.*)$/mg;
$corp .= " $1" while $A =~ /^(\*\*NixOS's own `EDITOR` default vs\..*)$/mg;
$corp .= " $1" if $R =~ /^(`lockDir` is the only option.*?)\n\n/ms;
$corp .= " $1" if $M =~ /^( +On NixOS, home-manager is not the outermost layer.*?)\n\n/ms;
$corp = norm($corp);
die "corpus too small\n" if length($corp) < 3000;
my ($region) = slurp($plan) =~ /(^### 3\.2 .*?)^### 3\.5 /ms or die "region not found\n";
$region =~ s/\n\s+/ /g;
my %h;
for my $l (split /\n/, $region) {
  while ($l =~ /([A-Za-z][A-Za-z0-9`'"\$\{\}\(\)\.\,\;\:\-\_\/=\*\s]{24,})/g) {
    my $f=norm($1); next unless ($f =~ tr/ //) >= 4; next if length($f)<25;
    next if index($corp,$f)>=0;
    $h{$f}=1;
  }
}
print "$_\n" for sort keys %h;
PL
# **corpus/region が取れなかったら die する** —— 空集合は「合格」の signature になる(手順 1 / 6a と同じ穴)。
perl /tmp/sweep6e.pl docs/plans/69-editor-nixos-layering.md \
     docs/architecture.md README.md nix/home-manager/default.nix > /tmp/sweep6e.out || exit 1
n=$(grep -c . /tmp/sweep6e.out)
[ "$n" = 39 ] || { cat /tmp/sweep6e.out; echo "FAIL: 6e の未一致断片が $n 件(39 のはず)"; exit 1; }
d=$(md5sum /tmp/sweep6e.out | cut -d' ' -f1)
[ "$d" = 4d0ed8d1e4d01cd11101f2c66bed3d48 ] \
  || { cat /tmp/sweep6e.out; echo "FAIL: 6e のダイジェストが $d(すり替えが起きている)"; exit 1; }

# --- 7. darwin(CLAUDE.md の規約)-------------------------------------------
# **2 本とも guard にすること**(round-22)。裸で並べると、**1 本目が落ちて 2 本目が通れば
# §8 は exit 0 で終わる** —— しかも最後の手順なので、誰も気づかない。
# `CLAUDE.md` のとおり **darwin の評価エラーをローカルで捕まえる唯一の手段**であり、
# 2 本とも**本件が編集するファイルを評価する**。
nix eval .#checks.aarch64-darwin.hm-module-default-editor.drvPath \
  || { echo "FAIL: darwin hm-module-default-editor の評価に失敗"; exit 1; }
nix eval .#checks.aarch64-darwin.hm-module.drvPath \
  || { echo "FAIL: darwin hm-module の評価に失敗"; exit 1; }
```

**CLAUDE.md の Commands のうち、本件で回さないものと理由:**

- **`nix fmt -- --clear-cache`** —— `stylua.toml` / `.luacheckrc` を触らない。lua を 1 ファイルも
  触らないので、stylua も luacheck も対象ファイルが増えない。
- **`nix build .#demo && ./result/bin/nvim`** —— `demo` は `nvimxLib.makeEnv` を直接呼び
  `homeModules.nvimx` を通らない(§4.4)。`description` が demo に到達する経路が無い。
- **`nix run .#lock -- --config ./nvim --out ./nvim/nvimx-lock`** —— lua も lock パイプラインも
  1 行も変わらない。`plugins.json` / `flake.nix` / `flake.lock` の出力は不変である。
- **`nix run .#skills-install`** —— `agent-skills` input に変更なし。`.claude/skills/` も触らない。
- **`nix build .#checks.x86_64-linux.<name>`(個別 check)** —— 手順 4 で 34 件すべての drvPath が
  変更前と一致することを示すので、個別にビルドし直す意味が無い(再ビルドは 1 件も発生しない)。
  手順 3 の `nix flake check` がキャッシュヒットで即座に終わることがその裏取りになる。

**手動確認は無い。** ドキュメントだけの変更なので `home-manager switch` で観測できるものが無い
(#67 §6.5 が実 dotfiles の switch を要求したのとは違い、本件は挙動を 1 ビットも変えない)。
ただし **手順 5 を飛ばさないこと** —— 本件の成果物は「書いてある内容が正しいこと」そのものであり、
それを担保するものが他に 1 つも無い(§6.1)。
**この計画はレビュー 17 回で出荷文の事実誤りを 29 個潰している**(ほかに記録の側の誤り 30 が 1 件)。
**14 個は §1 の再導出で(1-7 は §1.2-§1.6、8-11 は §1.7、12 は §1.3(d)、14 と 27 は §1.7 結論 2)、
14 個(13 / 15 / 16-26 / 28)は出荷文を構文として読む手順 5b で、
1 個(29)は出荷文を本計画の決定と突き合わせて出た。**
**誤り 30(記録の側)と 21 個の fail-open も、同じ「印字して目で見る」からは 1 つも出ていない。**
**6a の grep が捕まえたものは 1 つも無い** —— 6a は既知の禁止文字列に対する lint であって、
新しい誤りに対する守りではない(§6.1(b))。7-14 に至っては、正しい remedy と誤った remedy が
同じ語彙で書かれるので **grep で区別する方法が原理的に無い**。
**30 番目があるとすれば、まず手順 5b(構文として読む)で出る**(29 までは閉じている)。
**remedy の主張を書き換えるときは、§1.7 の 40 値に立ち返ること。**
