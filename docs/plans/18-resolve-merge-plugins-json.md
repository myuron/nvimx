# #18 対応計画: 既存 plugins.json とのマージによる pin 保持

対象 issue: [#18 feat(resolve): merge with the existing plugins.json to preserve pins](https://github.com/myuron/nvimx/issues/18)

この issue は #23 (semver 解決)、#24 (`--update [name...]`)、#25 (`--import-lazy-lock`) の共通土台である。
本計画書の「設計」と「#23 / #24 / #25 への提供物」が後続 3 件の前提契約になる。

## 1. 背景 / 現状

- `lua/nvimx/resolve.lua:6` に TODO「resolve version (semver) via git ls-remote, and merge with an existing plugins.json while preserving pins」がある。現状の resolve.lua は `raw-spec.json` → `plugins.json` を**毎回ゼロから生成**し、既存の `plugins.json` は一切読まない(`resolve.lua:9` の引数は入力 raw-spec と出力先の 2 つだけ)。
- `resolvedRef` は常に `vim.NIL`(`resolve.lua:125`)。`version` 指定があると `resolve.lua:87-89` で「未解決」の暫定 warning を出すのみ。
- `lua/nvimx/extract.lua:55-58` は lazy spec から `pin` / `optional` / `dependencies` を取得して raw-spec.json に含めているが、`resolve.lua:118-127` がプラグインエントリを組むときに全部捨てている。
- `lua/nvimx/genflake.lua:26-48` は `commit` > `resolvedRef` > `tag` > `branch` の優先順で flake input URL を組む。`resolvedRef` が常に null な現状では実質 `commit`/`tag`/`branch` のみが効いている。また git type(非 GitHub)の URL では `resolvedRef` / `commit` が**無視される**(`genflake.lua:41-47` は `?ref=` しか付けない)。
- `nix/lib/lock-app.nix:82` は resolve.lua に `"$sandbox/raw-spec.json"` と `"$out/plugins.json"` の 2 引数しか渡していない。既存 lock を読ませる規約が存在しない。
- `lua/nvimx/json.lua` はキーをソートして決定的に出力するため、同じ入力に対する `plugins.json` は byte-identical になる。この性質は維持必須。
- 現行スキーマ(`schemaVersion: 1`)の実例は `tests/fixtures/basic-config/nvimx-lock/plugins.json`。トップレベルは `schemaVersion` / `lazyNvim` / `plugins` / `localPlugins` / `warnings`、プラグインエントリは `inputName` / `source` / `branch` / `tag` / `commit` / `version` / `resolvedRef` / `build`。
- Nix 側の消費者は追加フィールドに対して安全: `nix/lib/make-env.nix:47` は `p.build or ...` のように必要なキーだけ読み、`nix/lib/sources.nix` は flake.lock しか見ない。
- docs/architecture.md の「Update semantics」(210-213 行付近) と URL マッピング表 (194-206 行付近) には既に意図が書かれている: 通常 lock は「新規追加と削除のみ、既存 pin は不変」、`pin = true` は「現在の lock の rev を凍結 (frozen)」。本 issue はこの意図を実装に落とすものである。

## 2. ゴール

issue の "Done when" を検証可能な形にすると:

1. **冪等性**: 設定変更なしで lock を 2 回実行したとき、`plugins.json` が byte-identical(`cmp` で検証。生成される `flake.nix` も同様)。
2. **pin 保持**: `pin = true` のプラグインは、無関係なプラグインの追加後も `resolvedRef`(凍結された rev)が変化しない。さらに `plugins.json` の URL レベルで rev 凍結されるため、素の `nix flake update` でも動かない。
3. **削除の反映**: spec からプラグインを消すと `plugins.json` と生成 `flake.nix` から該当エントリ・input が消える(`nix flake lock` が stale node を落とす)。
4. **フィールド保存**: `pin` / `optional` / `dependencies` が raw-spec から `plugins.json` まで到達する。
5. **golden test**: 上記 1-4 のマージ挙動が `flake.nix` の `checks` でオフラインに検証される。
6. **決定性の維持**: json.lua のソート出力・warnings 配列のソート(`resolve.lua:134-142`)を壊さない。

## 3. 設計

### 3.1 plugins.json スキーマ変更

プラグインエントリに 3 フィールドを追加する(トップレベル構造は不変):

```jsonc
"telescope.nvim": {
  "inputName": "telescope-nvim",
  "source": { "type": "github", "owner": "nvim-telescope", "repo": "telescope.nvim" },
  "branch": null, "tag": null, "commit": null,
  "version": "^0.1",              // spec の制約そのまま(従来通り)
  "pin": null,                    // 追加: true | null(lazy の pin。null = 未指定)
  "optional": null,               // 追加: true | null(情報保存のみ。ビルド挙動は変えない)
  "dependencies": [],             // 追加: 依存プラグイン名のソート済み配列(常に配列)
  "resolvedRef": null,            // 意味を確定: 「lock 時に確定した ref」(下記 3.2)
  "build": { "kind": "none" }
}
```

- `pin` / `optional` は `branch`/`tag` と同じ「未指定 = null」流儀(`p.pin or vim.NIL`)。lazy が渡すのは `true` か `nil` なので false は現れない。
- `dependencies` は `json.array` で常に出力し、**名前をソート**して決定性を保証する(lazy の並びに依存しない)。順序に意味はない。
- `localPlugins` / `warnings` / `lazyNvim` は不変。warnings は毎回 raw-spec から導出される派生値であり、マージ対象ではない。

**`resolvedRef` の意味論(ここで確定させる)**: 「lock 実行時に nvimx が確定させた ref」であり、次のいずれかを取る。

| 値 | 誰が書くか | 例 |
|---|---|---|
| `null` | 解決不要(branch/default 追従、または `commit` 指定済み) | — |
| 40 桁 SHA | pin 凍結(本 issue)。既存 flake.lock の locked rev | `"a1b2c3..."` |
| `refs/tags/<tag>` | semver 解決(#23) | `"refs/tags/v0.1.8"` |

`genflake.lua:32-34` は既に `commit` > `resolvedRef` を優先するので、GitHub type はこのままで両形式が URL に落ちる(`github:owner/repo/<sha>` / `github:owner/repo/refs/tags/t`)。

**schemaVersion は 1 のまま**とする。

- 採用理由: 追加は純粋に additive で、Nix 側 (`make-env.nix`) は未知キーを読まず、旧 nvimx が新ファイルを読んでも `resolvedRef` は genflake が既に処理する。逆に新 resolve.lua が旧ファイル(フィールド欠落)を prev として読む場合も「欠落 = null / 空配列」として扱えばよい。バージョン bump は読み手が壊れる変更のために取っておく。
- 却下案: v2 に上げる。互換コードは結局書く必要があり(ユーザーの手元には v1 の committed ファイルがある)、bump の利得がない。
- ガード: prev の `schemaVersion` が 1 以外なら**ハードエラー**(将来バージョンのファイルを黙って劣化マージしない)。prev が JSON として壊れている場合もハードエラーとし、「修正するか削除して再 lock せよ」とメッセージで案内する(黙って再生成すると pin が全損するため)。

### 3.2 pin の意味論

- `pin = true` かつ **spec 恒等性(3.3)が不変**のとき: そのプラグインの ref は再計算されない。さらに `commit` 未指定なら、既存 `flake.lock` の locked rev を `resolvedRef` に**実体化**する(凍結)。以後 genflake は rev 直指定 URL を出すので、`nix flake update` のバックドアでも動かない。これが architecture.md の表の「pin = true → freezes the current lock's rev」の実装である。
- **spec の編集は pin に勝つ**: pin されたプラグインの branch/tag/version/source を書き換えたら、ユーザーの明示的意思として再解決する(lazy 本体の pin も `:Lazy update` を止めるだけで、spec 変更には従う)。凍結 rev は破棄され、新しい spec で fetch された rev が次の凍結対象になる。
- `--update` との関係(#24 が実装): pin されたプラグインは名前を明示されない限りスキップ。名前を明示された場合のみ凍結を解いて再解決する。
- 優先順: すでに `resolvedRef` が非 null(prev から引き継いだ SHA、または #23 の解決済み tag ref)ならそれを維持し、flake.lock の rev で上書きしない。`commit` が spec にあるならそもそも凍結不要(スキップ)。

**初回 lock の収束**: 新規の pin プラグインは、初回は flake.lock に node が無く凍結できない。これに対し 2 案:

- 案 A: 2 パス収束を lock-app 内で行う(採用)。`nix flake lock` 後に resolve をもう一度実行し、`plugins.json` が変化した場合のみ genflake + `nix flake lock` をやり直す(最大 1 回のリトライ。3 回目は起き得ない: 2 回目の resolve は同じ flake.lock rev を読むだけで不動点に達する)。1 コマンドで steady state に到達し、「lock 2 回で byte-identical」が初回直後から成立する。
- 案 B: 単一パスで妥協し、「初回は flake.lock 側で凍結、次回 lock 時に plugins.json へ実体化」と文書化する。実装は簡単だが、初回と 2 回目で plugins.json が変わり Done when の冪等性が pin について破れる。却下。

### 3.3 マージアルゴリズム

**spec 恒等性 (spec identity)**: `source`(type/owner/repo/url)、`branch`、`tag`、`commit`、`version` の 5 組。`vim.NIL` と欠落は同一視して比較する。`pin` / `optional` / `dependencies` / `build` は恒等性に**含めない**(ref の決定に影響しないメタデータであり、これらの変更で再解決を起こさない)。

疑似コード(resolve.lua のメインループに入る形):

```lua
-- prev_db: --prev で渡された既存 plugins.json(無ければ nil)
-- locked_rev(input_name): --lock で渡された flake.lock から locked.rev を引く(無ければ nil)
for name, p in pairs(raw.plugins) do
  local entry = build_entry(p)          -- pin/optional/dependencies(ソート済み)を含む新エントリ
  local prev = prev_db and prev_db.plugins[name]
  local unchanged = prev ~= nil and same_identity(prev, entry)

  if unchanged then
    entry.resolvedRef = prev.resolvedRef      -- 前回の決定を無条件で引き継ぐ
  end                                         -- 変更あり/新規: resolvedRef = null(再解決対象)

  if entry.pin and unchanged
     and is_null(entry.resolvedRef) and is_null(entry.commit) then
    entry.resolvedRef = locked_rev(entry.inputName) or vim.NIL   -- pin 凍結の実体化
  end

  if entry.version and is_null(entry.resolvedRef) then
    warn_plugin(name, ...)                    -- 暫定 warning は「マージ後もなお未解決」の時だけ
  end
end
```

**各遷移の扱い**(issue の "Handle the obvious transitions explicitly"):

| 遷移 | 挙動 |
|---|---|
| プラグイン追加 | prev に無い → 新規エントリ、`resolvedRef = null`(#23 実装後は version があればここで解決)。既存エントリは一切触らない |
| プラグイン削除 | ループは raw-spec 側しか走査しないので自然に消える。genflake から input が消え、`nix flake lock` が stale node を除去する |
| source 変更(リポジトリ移転等) | 恒等性が破れる → `resolvedRef` 破棄、再解決。inputName は名前由来なので不変 |
| branch / tag / commit 変更 | 同上 |
| version 制約変更 | 同上(#23 実装後は新制約で再解決。#18 時点では null + warning) |
| `pin` / `optional` / `dependencies` / `build` のみ変更 | 恒等性は保たれ `resolvedRef` 維持。新しい値でフィールドだけ更新 |
| 通常プラグイン ⇄ localPlugins(`dev`/`dir` の付け外し) | prev の参照先は `prev_db.plugins` のみ。localPlugins へ移れば lock 対象から消え、戻れば新規扱い |
| prev にあるが raw-spec に無い localPlugins | localPlugins は lock 状態を持たないためマージ不要。毎回再生成 |

**引き継がない/マージしないもの**: `warnings`(毎回導出)、`lazyNvim`(固定の synthetic エントリ。lazy.nvim 自体の pin は `lock-app.nix:43` の既存 TODO で、本 issue の範囲外)、`build`(spec からの導出値)。

### 3.4 既存 plugins.json / flake.lock の読み込み方法と CLI 契約

resolve.lua の CLI を次に拡張する:

```
nvim -l resolve.lua <raw-spec.json> <out-plugins.json> [--prev <plugins.json>] [--lock <flake.lock>]
```

- 採用: **明示フラグ方式**。lock-app が `$out/plugins.json` / `$out/flake.lock` の存在を確認して条件付きで渡す。
- 却下案: 「出力先と同じパスが存在すれば暗黙に読む」規約。テストで prev と out を自由に組み合わせられない、初回/再実行の分岐が resolve.lua 内に隠れる、#24 の「この名前は prev を無視して再解決」のような制御を載せる場所がない、という理由で却下。状態の有無の判断は lock-app に一元化し、resolve.lua は渡されたものだけを読む。
- 引数パーサは `while i <= #arg` のフラグループにし、#24 の `--update [name]`(繰り返し可)と #25 の `--import-lazy-lock <path>` を同じ面に追加できる形にしておく(本 issue ではパースしない)。
- 同一パス問題: lock-app は `--prev "$out/plugins.json"` と出力先に同じパスを渡す。resolve.lua は冒頭で prev を全読みしてから最後に書くので順序問題はない(現行コードも read → 最後に write の構造。この順序を崩さないことをコメントで明記する)。
- flake.lock の読みは `sources.nix:6-12` と同じ構造を Lua で辿るだけ: `nodes[root].inputs[inputName]` → `nodes[node].locked.rev`。node が無い・rev が無い場合は nil(凍結せず次回に回る。案 A の 2 パス目で埋まる)。

### 3.5 genflake.lua の追随(git type の rev)

pin 凍結で `resolvedRef` に SHA が入るようになると、GitHub type は既存コードで動くが、git type(`genflake.lua:41-47`)は `?ref=` しか出せず凍結が URL に反映されない。`git+<url>?rev=<sha>`(branch があれば `?ref=<branch>&rev=<sha>`)を出すよう拡張する。`sources.nix:19` は locked.rev を fetchTree に渡すため build 側は既に対応済み。なお git type で spec の `commit` が無視される問題は既存の別件であり、ここでは `resolvedRef`(と自然に直せる範囲で `commit`)のみ扱う。

## 4. #23 / #24 / #25 への提供物

後続 3 件はこの節を前提に計画してよい。

**スキーマ最終形(プラグインエントリ)**:
`inputName` / `source` / `branch` / `tag` / `commit` / `version` / `pin` / `optional` / `dependencies` / `resolvedRef` / `build`。トップレベルは `schemaVersion: 1` / `lazyNvim` / `plugins` / `localPlugins` / `warnings`。genflake の URL 優先順は `commit` > `resolvedRef` > `tag` > `branch`(github / git 両 type)。

**永続化の不変条件(マージ契約)**:

1. spec 恒等性(source, branch, tag, commit, version)が不変なら、`resolvedRef` は**そのまま引き継がれる**。恒等性が破れたら `resolvedRef = null` に戻り「要再解決」になる。再解決が起きる条件はこの 1 点だけ(+ #24 の明示指定)。
2. `pin` / `optional` / `dependencies` / `build` の変更は再解決を**起こさない**(毎回 spec から上書きされるだけ)。
3. `warnings` は毎回導出。lock 状態ではない。

**pin の意味論**: `pin = true` ∧ spec 不変 ⇒ ref は再計算されず、`commit` 未指定なら flake.lock の rev が `resolvedRef` に凍結される。spec の編集は pin に勝つ。`--update`(#24)は pin されたプラグインを名前で明示されない限りスキップする。

**#23(semver)へのフック**: 「`version ~= nil` かつマージ後 `resolvedRef == null`」のエントリが解決対象の全集合。resolve.lua:87-89 の暫定 warning はこの条件に既にゲートされているので、#23 はその位置を `git ls-remote` + `lazy.manage.semver` による解決(`resolvedRef = "refs/tags/<tag>"` 書き込み、失敗時ハードエラー)に置き換えるだけでよい。解決済み tag は契約 1 により次回 lock を無条件で生き延びる。

**#24(--update)へのフック**: マージ実装は「強制再解決集合 `force`」を受ける形にしておく(#18 時点では常に空)。`name ∈ force` のエントリは prev が無いものとして扱う(`resolvedRef` 破棄。pin 凍結もスキップして flake.lock の現 rev を読み直す)。CLI は同じフラグループに `--update` / `--update <name>`(繰り返し)を足す。差分サマリ(旧 ref → 新 ref)は、マージ時に prev.resolvedRef と新値の両方が手元にあるので stderr に出せる。lock-app 側は対応する `nix flake update [inputName...]` の発行を担当する。

**#25(--import-lazy-lock)へのフック**: import は「仮想 prev」として実装する。`--import-lazy-lock <path>` の `{ branch, commit }` マップを、**prev に存在しないプラグインに限り** `resolvedRef = <commit>` のシードとして使う(実 prev > import シード)。プラグイン名は lazy 由来の名前(plugins のキー)で照合できる。未マッチエントリの報告は resolve.lua の warn 機構をそのまま使える。

## 5. 実装手順

### 5.1 `lua/nvimx/extract.lua` — 変更なし(確認のみ)

`extract.lua:55-58` で `pin` / `optional` / `dependencies` は既に dump されている。欠落フィールドが無いことを確認するのみ。

### 5.2 `lua/nvimx/resolve.lua` — 本丸

- `:6-7` — TODO コメントのうち merge 部分を落とす(semver は #23 まで残す)。
- `:9-10` — 位置引数 2 個 + `--prev` / `--lock` を受けるフラグループに書き換え(3.4 の契約)。未知フラグはエラー。
- `:21` 直後 — prev のロード(`--prev` 指定時): `read_json` 再利用、`schemaVersion == 1` の検証(違反はハードエラー、メッセージに対処法)。`--lock` 指定時は flake.lock をロードし `locked_rev(input_name)` ヘルパを定義(3.4)。
- `:28-36` 付近 — `same_identity(prev_entry, new_entry)` と `is_null` ヘルパを追加。`vim.NIL` 正規化はここに閉じ込める。
- `:77-129` のメインループ:
  - `:87-89` — warning 条件を「マージ後も `resolvedRef` が null」にゲート(3.3 疑似コード)。マージ処理より後ろに移動。
  - `:118-127` — エントリ構築に `pin = p.pin or vim.NIL`、`optional = p.optional or vim.NIL`、`dependencies = json.array(sorted(p.dependencies or {}))` を追加。構築後に 3.3 のマージ + pin 凍結ブロックを挿入。
- `:155-165` — result 構造は不変(schemaVersion 1 のまま)。

### 5.3 `lua/nvimx/genflake.lua` — git type の rev 対応

- `:41-47` — git type で `resolvedRef` が SHA のとき `?rev=` を付与(branch 併用時は `?ref=...&rev=...`)。github type(`:29-39`)は変更なし。

### 5.4 `nix/lib/lock-app.nix`

- `:1-3` — ヘッダコメントの TODO から本件相当を落とす(`--update` / `--import-lazy-lock` は残す)。
- `:76-88`(resolve ステップ)— 呼び出し前に:
  ```bash
  resolve_args=()
  [ -f "$out/plugins.json" ] && resolve_args+=(--prev "$out/plugins.json")
  [ -f "$out/flake.lock" ] && resolve_args+=(--lock "$out/flake.lock")
  ```
  を組み、`:82` の呼び出しに `''${resolve_args[@]+"''${resolve_args[@]}"}` を追加(`set -u` 対策の空配列ガード。writeShellApplication は `set -u` を敷く)。
- `:95`(`nix flake lock`)直後 — 3.2 案 A の収束パス:
  ```bash
  nvim -l resolve.lua "$sandbox/raw-spec.json" "$sandbox/plugins2.json" \
    --prev "$out/plugins.json" --lock "$out/flake.lock" 2> "$sandbox/resolve.log"
  if ! cmp -s "$sandbox/plugins2.json" "$out/plugins.json"; then
    mv "$sandbox/plugins2.json" "$out/plugins.json"
    genflake + nixfmt + nix flake lock をもう一度
  fi
  ```
  2 回目の resolve の stderr は 1 回目と同内容の warning を出すため、`resolve.log` は**上書き**して重複表示を避ける(#22 の後出し表示・trap との整合は既存の `resolve_log_shown` 機構をそのまま使う)。ここでの resolve 失敗は 1 回目と同様に致命扱い。

### 5.5 テストフィクスチャと flake.nix(§6 で詳述)

- `tests/fixtures/merge/` 一式と `tests/fixtures/merge-config/init.lua` を追加。
- `flake.nix` の checks(`resolve-build-warnings`(`:898-975`)の直後)に `resolve-merge` を追加。
- 既存フィクスチャの `tests/fixtures/*/nvimx-lock/plugins.json` は新フィールド付きで再生成する(resolve.lua をオフラインで回すだけ。flake.lock は不変)。Nix 側は新フィールドを読まないため必須ではないが、リポジトリ内の実例を最新スキーマに揃える。

### 5.6 ドキュメント

- `docs/architecture.md:170-213` — スキーマ例に `pin` / `optional` / `dependencies` を追記し、`resolvedRef` の 3 値意味論(3.1 の表)と「Update semantics」の実装済み範囲を更新。
- `lua/nvimx/resolve.lua` 冒頭コメントの Usage を新 CLI に更新。

## 6. テスト

### 6.1 フィクスチャ

```
tests/fixtures/merge/
  raw-spec-base.json           # 手書き raw-spec: pin=true+branch のもの / 素のもの / version 付きの 3 プラグイン
  raw-spec-added.json          # base + 1 プラグイン追加
  raw-spec-branch-changed.json # pin プラグインの branch を変更
  prev-v1.json                 # 新フィールドの無い schemaVersion 1 の旧形式 prev
  flake.lock                   # 手書きの偽 lock(pin プラグインの inputName に固定 rev)
  golden/
    base.plugins.json          # raw-spec-base + flake.lock の期待出力(steady state。pin は rev 凍結済み)
tests/fixtures/merge-config/
  init.lua                     # 実 spec: pin = true / dependencies / version を含む(extract 経路の検証用)
```

raw-spec を手書きにするのは、マージの場合分けを extract の揺れと切り離して正確に固定するため。extract → resolve の通し(フィールドが落ちないこと)は `merge-config` の 1 ケースだけで担保する。golden にストアパスは含まれないため安定。

### 6.2 `checks.resolve-merge`(新設)

`resolve-build-warnings` と同型の `pkgs.runCommand`(`neovim-unwrapped` + `jq`、完全オフライン)で以下を順に検証する:

1. **golden**: `resolve.lua raw-spec-base out1.json --lock flake.lock` → `diff -u golden/base.plugins.json out1.json`。スキーマ形(新フィールド、pin の rev 凍結)のレビュー可能な固定点。
2. **冪等性(「2 回 lock して byte-identical」の表現)**: `resolve.lua raw-spec-base out2.json --prev out1.json --lock flake.lock` → `cmp out1.json out2.json`。lock アプリ全体を回さずとも、状態を持つのは resolve だけなのでこれが本質(genflake/json.lua の決定性は既存 golden が担保)。
3. **pin 保持**: `raw-spec-added` + `--prev out1.json` + `--lock` → jq で pin プラグインのエントリが out1 と完全一致(`resolvedRef` = 凍結 rev のまま)、かつ追加プラグインが `resolvedRef: null` で存在。
4. **削除の反映**: 3 の出力を prev にして `raw-spec-base` を再 resolve → 追加プラグインが消えている。さらに `genflake.lua` を通し、生成 flake.nix に該当 input が無いことを grep で確認。
5. **spec 変更で再解決**: `raw-spec-branch-changed` + `--prev out1.json` → pin プラグインの `resolvedRef` が null に戻る(spec 編集は pin に勝つ)。
6. **旧形式 prev の互換**: `--prev prev-v1.json` で正常動作し、出力は新フィールドを持つ。
7. **壊れた prev / 未知 schemaVersion**: 非ゼロ終了と案内メッセージを assert。
8. **extract 通し**: `merge-config` を extract → resolve し、jq で `pin == true` / `dependencies` 配列の到達を assert。

`nix flake lock` を要する部分(stale node の除去、収束パス)はネットワークが要るため checks にできない。§7 の手動検証に回す。

### 6.3 既存チェックへの影響

- `resolve-build-warnings`(`flake.nix:898-975`)は resolve.lua を prev なしで叩くため、新フィールドが増えても jq assert は通る見込み。CLI 変更(フラグ追加)は位置引数互換なので呼び出しは不変。
- `extractor-snapshot` の golden(`tests/fixtures/golden/basic-config.raw-spec.json`)は extract.lua 不変なので差分なし。
- 既存フィクスチャ plugins.json の再生成(5.5)は `hm-module` 系・`build-shell` 等の入力になるが、Nix 側は追加キーを読まないため挙動不変。

### 6.4 CI

- `.github/workflows/check.yml` は `nix flake check` を丸ごと実行するため、checks に `resolve-merge` を足すだけで CI に乗る。**ワークフローの編集は不要**。仮にステップ追加が要る場合も、CLAUDE.md の規約により編集は `check.yml` のみ(`ci-linux.yml` / `ci-darwin.yml` は触らない)。
- darwin 側の評価はローカルの `nix flake check` では検出できないので、`nix eval .#checks.aarch64-darwin.resolve-merge.drvPath` で評価だけ通す(CLAUDE.md の規約)。

## 7. リスク / 未決事項

- **`nix flake lock` が stale node を確実に除去するか**: 設計は「input が消えれば node も消える」に依存する。実装時に実バージョンの nix で手動確認する(削除→lock→flake.lock から node 消滅)。消えない場合でも動作上は無害(参照されないだけ)だが、Done when の「removes it from the generated flake」は flake.nix 側で満たされる。
- **収束パスのコスト**: 案 A は resolve を常に 2 回、pin の凍結が動いた回だけ `nix flake lock` を 2 回実行する。resolve はオフラインで軽く、lock の 2 回目は変化した input の再 fetch のみ。リトライは 1 回に固定しており無限ループはない。
- **tag の再ポイント**: pin 凍結は tag 指定のプラグインでも rev を焼き込む(commit 未指定なら)。tag が動いた場合に「spec 不変なのに実体が変わらない」のは pin の意図通りだが、ユーザーが tag を動かして追従させたい場合は spec 変更(tag 名変更)か #24 の `--update <name>` が必要。ドキュメントに明記する。
- **手編集された prev**: `resolvedRef` を手で書いたファイルも契約 1 によりそのまま信じる(恒等性が合う限り)。これは仕様とする(twist 同様のバックドア)が、壊れた値は `nix flake lock` の段階でエラーになる。
- **git type(非 GitHub)の `commit` 無視**: 既存の別バグ。5.3 で `rev` サポートを入れるついでに直せるが、スコープが膨らむなら別 issue に切り出す。
- **lazy のバージョン差による `dependencies` / `optional` の揺れ**: dump は seed(または locked lazy)の正規化結果に依存する。seed は flake input で固定されており、配列ソートで順序も固定するため、同一 seed 下で非決定性はない。seed 更新時に差分が出るのは既知の性質(extractor-snapshot と同じ)。
- **`optional = true` のプラグインを lock すべきか**: 現状は「lazy の `Spec.new` が残したものは全部 lock」(superset 方針、architecture.md:191)。本 issue では変えず、フィールドを保存するだけ。選択的除外をやるなら別 issue。
- **`--import-lazy-lock` の再 import**(実 prev とシードの優先順の詳細、branch 不一致時の扱い)は #25 の計画書で決める。本計画は「実 prev > import シード」の原則だけを契約として置く。
