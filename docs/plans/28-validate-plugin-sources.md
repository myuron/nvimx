# #28 対応計画: non-GitHub / 明示 URL のプラグインソースを lock 時に検証する

対象 issue: [#28 feat(lock): validate non-GitHub plugin sources](https://github.com/myuron/nvimx/issues/28)

Phase 7(`docs/architecture.md:526` の "Finishing touches" に `non-GitHub validation` として挙がっている)の一件。
依存する機能(#18 / #23 / #24 / #25 / #26 / #27)はすべて main にマージ済みで、本計画の `file:line` は
現在の main(`3fa8861`)の実ファイルで全件確認している。

同じく open な **#47(`dir` はあるが `dev` が無いプラグインが remote 扱いになる)とは衝突しない**。
根拠は §3.6 と §4.4 に置く。本件で #47 を直すことはしない。

## 1. 背景 / 現状

### 1.1 `url` がどこから来るか(lazy 側の実測)

`lua/nvimx/extract.lua:113` が `url = p.url` で dump しているのは、lazy が正規化したあとの URL である。
lazy の正規化は `lua/lazy/core/fragments.lua:108-121`(pin 済み seed
`/nix/store/d9jq3s81p4i9q6g8gaa6f2pn51p8za9l-source`)の 1 箇所だけで、実装はこうなっている:

```lua
  if plugin[1] then
    local slash = plugin[1]:find("/", 1, true)
    if slash then
      local prefix = plugin[1]:sub(1, 4)
      if prefix == "http" or prefix == "git@" then
        fragment.url = fragment.url or plugin[1]
      else
        fragment.name = fragment.name or plugin[1]:sub(slash + 1)
        fragment.url = fragment.url or Config.options.git.url_format:format(plugin[1])
      end
    else
      fragment.name = fragment.name or plugin[1]
    end
  end
```

`git.url_format` の既定値は `"https://github.com/%s.git"`(`lua/lazy/core/config.lua:32`)。
つまり **short 形式が特別扱いするのは `http` 始まりと `git@` 始まりの 2 つだけ**で、それ以外はすべて
`https://github.com/<書いたもの>.git` に押し込まれる。`url = ...` を明示した場合は無条件に素通しである。

実測(本計画の執筆時に、seed を使って `extract.lua` を実際に走らせた結果):

| spec | raw-spec の `url` | raw-spec の plugin 名 |
|---|---|---|
| `{ "folke/tokyonight.nvim" }` | `https://github.com/folke/tokyonight.nvim.git` | `tokyonight.nvim` |
| `{ "https://gitlab.com/o/gl.nvim.git" }` | `https://gitlab.com/o/gl.nvim.git` | `gl.nvim` |
| `{ "git@example.com:o/scpshort.nvim.git" }` | `git@example.com:o/scpshort.nvim.git` | `scpshort.nvim` |
| `{ url = "git@example.com:o/scpurl.nvim.git" }` | `git@example.com:o/scpurl.nvim.git` | `scpurl.nvim` |
| `{ url = "https://git.sr.ht/~user/srht.nvim" }` | `https://git.sr.ht/~user/srht.nvim` | `srht.nvim` |
| `{ url = "file:///home/me/fileurl.nvim" }` | `file:///home/me/fileurl.nvim` | `fileurl.nvim` |
| **`{ "ssh://git@example.com/o/sshshort.nvim" }`** | **`https://github.com/ssh://git@example.com/o/sshshort.nvim.git`** | **`/git@example.com/o/sshshort.nvim`** |
| **`{ "file:///home/me/fileshort.nvim" }`** | **`https://github.com/file:///home/me/fileshort.nvim.git`** | **`//home/me/fileshort.nvim`** |
| `{ "o/localdir.nvim", dir = "/home/me/localdir.nvim" }` | `https://github.com/o/localdir.nvim.git`(`dir` は **null**) | `localdir.nvim` |
| `{ "o/devplug.nvim", dev = true }` | `https://github.com/o/devplug.nvim.git`(`dir` は dev.path 由来) | `devplug.nvim` |

最後の 2 行が #47。`extract.lua:114` の `dir = p.dev and p.dir or nil` により、`dev` の無い `dir` は
raw-spec に残らない。**本件はこの挙動を変えない**(§3.6)。

太字の 2 行が「short 形式にフル URL を書いた」ケースで、URL もプラグイン名も壊れる。
現状これは何のエラーにもならない。

### 1.2 nvimx 側の現状(検証は 1 つも無い)

`lua/nvimx/resolve.lua:272-283` が唯一の分岐点である:

```lua
-- Convert the git URL normalized by lazy into a source struct (github gets its own type)
local function parse_source(name, url)
  if type(url) ~= "string" then
    fail(("plugin %q has no url. lazy derives one from the spec, so a raw spec without it is malformed"):format(name))
  end
  local owner, repo = url:match("^https://github%.com/([^/]+)/(.+)$")
  if owner then
    repo = repo:gsub("%.git$", "")
    return { type = "github", owner = owner, repo = repo }
  end
  return { type = "git", url = url }
end
```

- 呼び出しは `resolve.lua:677` の `source = parse_source(name, p.url),` 1 箇所のみで、`fail_plugin` の宣言(`:379`)より後ろにある(本件はこの事実に乗って関数を移設する。§3.9)。
- `type(url) ~= "string"` 以外に検査は無く、**マッチしなかった文字列はすべて無条件に `{ type = "git", url = <そのまま> }`** になる。
- github 判定の repo 側が `(.+)` なので、**`/` を含んだ残りをそのまま repo として受け入れる**。

`lua/nvimx/genflake.lua:41-68` は git type をこう組み立てる:

```lua
  -- explicit git URL. Unlike the github type, ref and rev are separate query parameters rather
  -- than one path component, so a pinned rev can be carried alongside the branch it lives on.
  local url = "git+" .. src.url
```

`"git+" .. src.url` はソース URL の中身を一切見ない。`?ref=` / `?rev=` は `:58-67` でこの後ろに足される。

`docs/architecture.md:504` の edge-case 表は
`| Non-GitHub / explicit git URL | normalized to a `git+https://` / `git+ssh://` input |`
と書いているが、**`git+ssh://` へ正規化するコードは存在しない**。issue 本文の「正規化はあるが検証は無い」は
より正確には「`git+https://` 相当の素通しはあるが、`git+ssh://` への正規化も検証も無い」である。

### 1.3 実際にどう壊れるか(すべて実測)

手書き raw-spec を `resolve.lua` → `genflake.lua` に通した実測結果:

| プラグイン | spec の `url` | 生成された flake input URL | 実害 |
|---|---|---|---|
| `scp.nvim` | `git@git.example.com:owner/scp.nvim.git` | `git+git@git.example.com:owner/scp.nvim.git` | flake ref として不正 |
| `tree.nvim` | `https://github.com/owner/tree.nvim/tree/main` | `github:owner/tree.nvim/tree/main` | **黙って別物を指す** |
| `bare.nvim` | `/home/me/repos/bare.nvim` | `git+/home/me/repos/bare.nvim` | flake ref として不正 |
| `query.nvim` | `https://git.example.com/o/query.nvim.git?ref=main` | `git+https://...?ref=main` | `branch` 併用で `?ref=` が二重化 |

`builtins.parseFlakeRef` に食わせた結果:

```console
$ nix eval --raw --expr 'builtins.toJSON (builtins.parseFlakeRef "git+git@h:o/r.git")'
error: flake reference 'git+git@h:o/r.git' is not an absolute path

$ nix eval --raw --expr 'builtins.toJSON (builtins.parseFlakeRef "github:o/r/tree/main")'
{"owner":"o","ref":"tree/main","repo":"r","type":"github"}

$ nix eval --raw --expr 'builtins.toJSON (builtins.parseFlakeRef "git+https://h/o/r.git?ref=main?ref=refs/tags/v1")'
error: ... (parse 失敗)
```

**issue 本文が想定するより悪い**のが scp 形式である。`nix flake lock` は**エラーにならず成功する**:

```console
$ cat flake.nix
{ inputs = { scp-nvim = { url = "git+git@git.example.com:owner/scp.nvim.git"; flake = false; }; };
  outputs = _: { }; }
$ nix flake lock
warning: creating lock file "…/flake.lock":
• Added input 'scp-nvim':
    'path:git%2Bgit@git.example.com:owner/scp.nvim.git'
```

flake の input として解釈できない URL は **相対 path input にフォールバック**され、`flake.lock` には
`rev` も `narHash` も無いノードが書かれる:

```json
    "scp-nvim": {
      "flake": false,
      "locked": { "path": "git+git@git.example.com:owner/scp.nvim.git", "type": "path" },
      "original": { "path": "git+git@git.example.com:owner/scp.nvim.git", "type": "path" }
    }
```

これを `nix/lib/sources.nix` が読むと、lock 時ではなく**ユーザのビルド時**に、ソース URL を 1 文字も含まない
このエラーになる:

```console
error: attribute 'narHash' missing
       at …/nix/lib/sources.nix:15:25:
           14| builtins.fetchTree {
           15|   inherit (locked) type narHash;
```

issue 本文の「an opaque `nix flake lock` error far from its cause」は、実際には
**`nix flake lock` すら通ってしまい、home-manager の switch 時に `sources.nix:15` で落ちる**という、
原因からさらに遠い失敗である。これが本件の第一の動機になる。

### 1.4 既存 fixture が依存している形(受理必須)

新しい検証が既存 check を壊さないために、いま fixture に実在する URL を棚卸しした
(`grep -rho '"url": "[^"]*"' tests/`):

| 形 | 実例 | 使っている check |
|---|---|---|
| `https://github.com/<o>/<r>.git` | `https://github.com/folke/tokyonight.nvim.git` | ほぼ全部 |
| `https://<host>/<単一セグメント>.git` | `https://git.example.com/custom.nvim.git` | `resolve-merge` |
| `file:///<絶対パス>` | `file:///nvimx-nonexistent/tag.nvim` | `resolve-semver` / `resolve-import-lazy-lock` / `update-summary` |
| `file://$sb/tagged`(check が sed/jq で埋める) | `flake.nix:1420-1422`, `:1883`, `:1983`, `:2043`, `:2227` | `extractor-defaults-version`(`:1420-1422`)/ `resolve-semver`(`:1883` / `:1983` / `:2043`)/ `resolve-update`(`:2227`) |

特に `file://` は **`checks.resolve-semver` がローカル git repo を remote に見立てる唯一の手段**であり
(`flake.nix:176-180` のコメントが「`git+file://`(bare path ではなく)が nix の flake ref parser が
受け付ける形だ」と明記している)、**受理しなければ既存 check が丸ごと落ちる**。
また `https://git.example.com/custom.nvim.git` は host + **1 セグメント**の path なので、
「path は `<owner>/<repo>` の 2 セグメントでなければならない」という規則を汎用 git 側に課してはならない。

## 2. ゴール

issue の "Done when" を検証可能な形に落とすと:

1. **受理側**: §3.2 のマトリクスの各形が、期待どおりの flake input へ lock される。判定は「golden の
   `plugins.json` と golden の `flake.nix` に一致すること」で行う。
2. **拒否側**: §3.3 のマトリクスの各形が、**lock の前に**、プラグイン名と問題の URL を含む固定文言で
   fatal になる。`plugins.json` は 1 バイトも書かれない。
3. **flake ref としての妥当性を nix 自身に確認させる**: golden の `flake.nix` が持つ全 input URL に
   `builtins.parseFlakeRef` が通り、**かつ結果の `type` が `github` か `git` のいずれかである**ことを、
   **評価時**に(IFD 無しで)assert する。type まで見るのは、`parseFlakeRef` が
   `github:o/r/tree/main` も `just-a-name`(`indirect`)も受理してしまい、それだけでは §1.3 の
   「黙って `path:` / 別物に降格する」失敗モードを塞げないからである(§5.6(b))。
4. **後方互換**: 現状すでに *意図どおりの* リポジトリを指す lock は、scp 形式を除いて 1 つも動かない。
   不変条件と、そこから外れる形の**完全な列挙**は §3.4 に置く。判定は 2 段で行う:
   (a) `tests/fixtures/*/nvimx-lock/plugins.json` と `.../flake.nix` の再生成差分が空(§8-5)、
   (b) **(a) が回す既存 4 fixture(basic-config / build-plugins / registry-plugins / treesitter-config)に
   実在しない** 3 形(`http://github.com/…` / 大文字ホスト / 末尾 `/`)を、`tests/source-parse-test.lua`
   と本件の新規 fixture `tests/fixtures/source-urls/raw-spec-ok.json` の双方に明示ケースとして置き、
   現行分類が保たれることを直接固定する(§8-6)。**(a) だけでは足りない** — 既存 fixture の URL を
   全件洗い出したが、この 3 形は 1 件も無いので、分類を変えても (a) の差分は空のままになる。
5. **`nix flake check` / `nix fmt -- --ci` がグリーン**、`nix eval .#checks.aarch64-darwin.<新 check>.drvPath` が通る。
6. **ドキュメント**: `docs/architecture.md` の URL マッピング表と edge-case 表が、実装と一致する
   (いまは `git+ssh://` を約束しているのに実装が無い、という乖離がある)。

## 3. 設計

### 3.1 検証をどこに置くか — 新モジュール `lua/nvimx/source.lua`

**採用**: `lua/nvimx/source.lua` を新設し、`M.parse(url) -> source | nil, err` を公開する。
`resolve.lua` は `:103-104` に倣って `dofile` する:

```lua
local json = dofile(arg[0]:gsub("resolve%.lua$", "json.lua"))
local ver = dofile(arg[0]:gsub("resolve%.lua$", "version.lua"))
local source = dofile(arg[0]:gsub("resolve%.lua$", "source.lua"))
```

理由:

1. **`lua/nvimx/version.lua` + `checks.semver-select` という前例がそのまま当てはまる**。`version.lua` の
   ヘッダは「この層はネットワークにもファイルシステムにも触れないので、固定入力の unit test から
   簡単に駆動できる(checks.semver-select)」と書いている。URL 正規化はまさに純関数であり、
   fixture も nvim の起動もネットワークも要らないテストが書ける。#28 は「受理/拒否のマトリクス」が
   成果物なので、マトリクスを表として直接書ける unit test の価値が特に高い。
2. **`resolve.lua` は既に 1289 行**で、`flake.nix` と並ぶ本リポジトリで最も重いファイルである。
   パターンマッチだけで 90 行前後になるものをここに足す積極的な理由が無い。
3. **エラーを「返す」設計にできる**。`version.lua:select_tag` が
   「失敗は raise ではなく `nil, detail` で返す。重大度の判断は呼び出し側の仕事だから」
   と書いているのと同じ理屈で、`source.parse` も `nil, err` を返す。`resolve.lua` はそれを
   `fail_plugin` に流すだけになり、**1 回の lock で全部のプラグインの問題をまとめて報告できる**
   (§3.8)。ここで `error()` を投げる設計にすると最初の 1 件で死に、この性質が失われる。

**却下: `parse_source` の中に直接書く**。上記 1-3 をすべて失う。特に「pcall で受ける unit test」を
書く羽目になるが、そもそも raise しない設計にできるのだから raise させる理由が無い。

**却下: `genflake.lua` 側に置く**。genflake は「lock 時の最後の 1 ステップ」であり、そこで落としても
「flake を生成する前に落とす」という issue の要求(`Fail early ... instead of deferring`)は満たすが、
プラグイン名と URL を持っているのは resolve であり、`fail_plugin` の集約報告も
`report_resolve_errors` の決定的ソートも resolve 側にしかない。genflake の扱いは §3.7。

### 3.2 受理マトリクス

`source.parse` は「lazy が `p.url` に入れうる文字列」を入力に取り、`source` 構造体を返す。
`genflake.lua` の出力まで含めた対応は次のとおり(`<ref>` は `?ref=` / `?rev=` の付与で、
これは既存の `genflake.lua:41-68` がそのまま担当する。§3.5)。

| # | spec の書き方 | `p.url`(lazy 正規化後) | `source` | 生成される flake input URL |
|---|---|---|---|---|
| 1 | `{ "o/r" }` short | `https://github.com/o/r.git` | `{ type = "github", owner = "o", repo = "r" }` | `github:o/r` |
| 2 | `url = "https://github.com/o/r"` | 同左 | 同上 | `github:o/r` |
| 3 | `url = "https://github.com/o/r/"` | 同左 | `{ type = "github", owner = "o", repo = "r/" }`(**末尾 `/` は保存**) | `github:o/r/` |
| 4 | `url = "http://github.com/o/r.git"` | 同左 | `{ type = "git", url = <そのまま> }` | `git+http://github.com/o/r.git` |
| 5 | `url = "https://GitHub.com/o/r"`(大文字ホスト) | 同左 | `{ type = "git", url = <そのまま> }` | `git+https://GitHub.com/o/r` |
| 6 | `url = "https://github.example.com/o/r.git"`(GHE) | 同左 | `{ type = "git", url = <そのまま> }` | `git+https://github.example.com/o/r.git` |
| 7 | `url = "https://gitlab.com/g/sub/r.git"`(入れ子 group) | 同左 | `{ type = "git", url = <そのまま> }` | `git+https://gitlab.com/g/sub/r.git` |
| 8 | `url = "https://git.sr.ht/~user/r"` | 同左 | `{ type = "git", url = <そのまま> }` | `git+https://git.sr.ht/~user/r` |
| 9 | `url = "https://git.example.com/r.git"`(1 セグメント) | 同左 | `{ type = "git", url = <そのまま> }` | `git+https://git.example.com/r.git` |
| 10 | `url = "http://git.example.com/o/r.git"` | 同左 | `{ type = "git", url = <そのまま> }` | `git+http://git.example.com/o/r.git` |
| 11 | `{ "git@h:o/r.git" }` short / `url = "git@h:o/r.git"` | `git@h:o/r.git` | `{ type = "git", url = "ssh://git@h/o/r.git" }` | `git+ssh://git@h/o/r.git` |
| 12 | `url = "git@github.com:o/r.git"` | 同左 | `{ type = "git", url = "ssh://git@github.com/o/r.git" }` | `git+ssh://git@github.com/o/r.git` |
| 13 | `url = "forgejo@h:o/r.git"`(git 以外のユーザ) | 同左 | `{ type = "git", url = "ssh://forgejo@h/o/r.git" }` | `git+ssh://forgejo@h/o/r.git` |
| 14 | `url = "ssh://git@h/o/r.git"` | 同左 | `{ type = "git", url = <そのまま> }` | `git+ssh://git@h/o/r.git` |
| 15 | `url = "ssh://git@h:2222/o/r.git"`(ポート付き) | 同左 | `{ type = "git", url = <そのまま> }` | `git+ssh://git@h:2222/o/r.git` |
| 16 | `url = "git://h/o/r.git"` | 同左 | `{ type = "git", url = <そのまま> }` | `git+git://h/o/r.git` |
| 17 | `url = "file:///abs/path"` | 同左 | `{ type = "git", url = <そのまま> }` | `git+file:///abs/path` |
| 18 | `dev = true` / `dir = ...` | (`source.parse` に届かない) | — | flake input を持たない(`localPlugins`) |

**#3 / #4 / #5 は「現行の分類をそのまま素通しする」ための行である。** この 3 形は今日すでに有効な
lock を生んでおり、github type に寄せる(= `source` を `{type,url}` から `{type,owner,repo}` に変える、
`repo` から末尾 `/` を削る)と `same_identity` が false になって `resolvedRef` が捨てられ、
flake input URL も変わって再 fetch が起きる。**それは「検証を足す」本 issue の範囲外の破壊的変更**なので、
分類拡張は §7 の follow-up に切り出す。現状が有効であることの実測:

```console
$ nix eval --raw --expr 'builtins.toJSON (builtins.parseFlakeRef "git+http://github.com/o/r.git")'
{"type":"git","url":"http://github.com/o/r.git"}
$ nix eval --raw --expr 'builtins.toJSON (builtins.parseFlakeRef "git+https://GitHub.com/o/r")'
{"type":"git","url":"https://GitHub.com/o/r"}
$ nix eval --raw --expr 'builtins.toJSON (builtins.parseFlakeRef "github:o/r/")'
{"owner":"o","repo":"r","type":"github"}
```

残りの形も `builtins.parseFlakeRef` で実測確認済み(`?ref=` / `?rev=` を足した形も含む):

```console
$ nix eval --raw --expr 'builtins.toJSON (builtins.parseFlakeRef
    "git+ssh://git@git.example.com/owner/scp.nvim.git?ref=refs/tags/v1.0.0&rev=1111…1111")'
{"ref":"refs/tags/v1.0.0","rev":"1111…1111","type":"git","url":"ssh://git@git.example.com/owner/scp.nvim.git"}
$ nix eval --raw --expr 'builtins.toJSON (builtins.parseFlakeRef "git+ssh://git@h:2222/o/r.git")'
{"type":"git","url":"ssh://git@h:2222/o/r.git"}
$ nix eval --raw --expr 'builtins.toJSON (builtins.parseFlakeRef "git+git://h/o/r?ref=main")'
{"ref":"main","type":"git","url":"git://h/o/r"}
```

**判定アルゴリズム**(この順序で評価する):

> **2026-08-24 追記(PR #60 レビュー)**: 当初案は 1-6 のみだったが、レビューで「4 の generic scheme
> 分岐が nix の flake-ref 文法より広い」「5 の `user@` が任意になっていて全コロン文字列を巻き込む」
> という 2 件の should-fix が見つかり、4 に L/M、5 に「`user@` 必須」を追加した。issue #28 自身の
> "Done when: assert the normalized URL is a valid flake input reference" に対する穴だったため、
> 「検証を足す」本件のスコープ内として扱う(§7 の follow-up には切り出さない)。

1. `type(url) ~= "string"` → 拒否(A)。`url == ""` → 拒否(B)。
2. `url:find("%s")` → 拒否(C)。`url:find("[?#]")` → 拒否(D)。`url:find("${", 1, true)` → 拒否(D2)。
   **`?` と `#` は genflake が所有する**(`genflake.lua:65-67` が `url .. "?" .. table.concat(params,
   "&")` を組む)ので、ソース URL 側にあってはならない。ここで弾かないと `?ref=main?ref=refs/tags/v1`
   のような二重クエリが生まれる。**`${` は genflake が `%q`(Lua の `string.format`)で書き出す**ため
   で、`%q` は `${` をエスケープしないので、通すと生成した `flake.nix` の中で生きた Nix 文字列補間に
   化け、このプラグインとも URL とも無関係な「undefined variable」で死ぬ(D2)。
3. **github 判定は現行の正規表現をそのまま使う**: `url:match("^https://github%.com/([^/]+)/(.+)$")`。
   `https` 限定・ホストは大小文字を区別、という現行の性質を **1 ミリも広げない**(これが §3.4 の
   不変条件を構造的に成立させる)。マッチした場合、repo 側の末尾 `.git` を現行どおり落としてから:
   - `repo:match("^[^/]+/?$")` に合えば `{ type = "github", owner = owner, repo = repo }`。
     **末尾 `/` は落とさない** — 落とすと `source.repo` の値が `"r/"` から `"r"` に変わり、
     いま動いている lock の `resolvedRef` を捨てることになる(§3.4)。
   - 合わなければ拒否(J)。**汎用 git へフォールバックしない**(理由は §3.3)。
   - **正規表現がそもそもマッチしない場合**(`https://github.com/<owner>` のように 2 セグメント目が
     無い)は 4 に落ち、host + path を持つ generic git として受理される — これは今日と同じ挙動で、
     本件は分類を広げないので変えない(§3.4 のとおり)。
4. `url:match("^(%a[%w+.-]*)://")` でスキームを取る。取れた場合:
   - スキームを小文字化して `{ https, http, ssh, git, file }` に無ければ拒否(F)。
   - `file` → 残りが `/` で始まらなければ拒否(G。**文言は「authority が空でない」ことを言う** —
     `file://home/me/repo.git` の authority は `"home"` であって、原因は相対パスではなく非空
     authority である。§3.3 の G の項を参照)。始まればそのまま git type。
   - それ以外 → `authority` と `path` に分解し、authority が空なら拒否(H)、**`path` が空、または
     `"/"` 1 文字だけなら拒否(I)** — `https://git.example.com` と `https://git.example.com/` は
     どちらも「host はあるが repo が無い」ので同じ扱いにする(1 バイト長い方だけ通っていたのは
     レビューで見つかった抜け)。
   - **authority の `@` 以降(`@` が無ければ authority 全体)を host[:port] として扱い、`:` の
     後ろが数字だけでなければ拒否(L)**。`ssh://git@github.com:o/r.git`(scp 形式に機械的に
     `ssh://` を足す典型的な間違い)は authority `"git@github.com:o"` になり、
     `builtins.parseFlakeRef "git+ssh://git@github.com:o/r.git"` は `"o"` がポートとして不正なため
     `is not an absolute path` で失敗する — この失敗を lock 時に、プラグイン名と理由付きで先取りする。
   - **authority と path の連結に nix の flake-ref 文法が受理しない文字(`builtins.parseFlakeRef` で
     実測確認済み: `<> [] {} ^ \` \ "` `|` など)が含まれていれば拒否(M)**。
   - 以上に該当しなければ `{ type = "git", url = <入力そのまま> }`。**値は 1 バイトも変えない**
     (`.git` を削らない、末尾 `/` を削らない、小文字化しない)。3 で github 判定に落ちなかった
     `http://github.com/...` や `https://GitHub.com/...` はここに来る。
5. スキームが無い場合、scp 形式 `^([^/@:]+@)([^/:]+):(.+)$` を試す(**`user@` は必須**。当初案の
   `^([^/@:]*@?)([^/:]+):(.+)$` は `user@` が完全に任意で、コロンを含むだけの文字列 —
   `"myplugin:main"` → `"ssh://myplugin/main"` — まで巻き込んでいた。§3.2 のこの節、モジュールの
   ヘッダコメント、`docs/architecture.md`、拒否記号 K の文言、いずれも `user@host:path` としか
   書いていない以上、実装をそちらに合わせるのが正しいと判断した。`user@` を欠くコロン文字列は
   今日どのみち `path:` 降格で壊れているので、6 の K に落として拒否しても既存の lock は 1 つも
   壊れない)。マッチし、かつ path 部が `/` で始まらなければ
   `{ type = "git", url = "ssh://" .. user .. host .. "/" .. path }`。
   **本件で `source` の値が変わるのはこの経路だけである**(§3.4 / §7)。
6. `^[/~.]` で始まる → 拒否(E、ローカルパス専用の文言)。それ以外 → 拒否(K)。

`git = { url_format = "git@github.com:%s.git" }`(lazy でよく使われるイディオム)を書いた config は、
short 形式が #11-#13 の scp 経路に乗る。現状これは `git+git@github.com:o/r.git` = §1.3 の `path:`
降格コースで **必ず壊れる**ので、本件で初めて lock できるようになる。ただし**受益の中身は限定的**である:
全プラグインが `git+ssh://git@github.com/...` になり、公開リポジトリの fetch にも ssh 鍵が要求され、
nix が `github:` input で使う軽い tarball 経路を全部失う。`url_format` を書く人の意図は push の
利便であって fetch transport ではないので、これは「壊れているよりはまし」以上のものではない。

**却下: github.com の ssh/scp も github type に寄せる**。上の代償(公開 repo でも ssh 鍵が要る、
tarball 経路の喪失、`url_format` ユーザの全 input が git type になる)は消える。しかし
**private repo を ssh 鍵で引いているユーザの fetch を壊す**: `github:` input は tarball API 越しなので、
鍵ではなくトークンが要る。transport を明示的に書いたユーザからそれを取り上げるのは、「検証を足す」
issue でやってよい変更ではない。したがって **ssh/scp の github.com は git type のまま**とし、
この判断(と代償)を §4.5 で `docs/architecture.md` に明文化する。follow-up 候補は §7。

### 3.3 拒否マトリクスと文言

`fail_plugin(name, msg)` は `resolve.lua:379-381` で `("plugin %q: %s"):format(name, msg)` を作り、
`report_resolve_errors`(`:388-402`)が `[nvimx] resolve failed: ` を前置して名前昇順に出す。
したがって 1 行の完成形は:

```
[nvimx] resolve failed: plugin "<name>": <msg>
```

`<msg>` は `source.lua` が返す文字列で、A/B 以外はすべて `unsupported source URL %q: ` で始める
(`%q` は `resolve.lua` の既存慣習)。したがって issue の
「fail with the plugin name and the offending URL」は **C-K の全ケースで行の形として保証される**。

**A/B は意図的な例外**である。A は `url` が文字列ですらない(URL が存在しない)、B は空文字列で、
「問題の URL」を引用しようにも引けるものが無い / `""` しか無い。原因が「URL がそもそも無い」こと
自体なので、URL を含めないのが正しい文言である。§5.6(b) の統合 check は、この 2 件を除いた行に
ついて URL の存在を assert する(全行をまとめて数える形にすると、この穴が検出できない)。

| 記号 | 条件 | `<msg>` |
|---|---|---|
| A | `url` が文字列でない | `has no url. lazy derives one from the spec, so a raw spec without it is malformed` |
| B | `url == ""` | `has an empty url. lazy derives one from the spec, so a raw spec with an empty one is malformed` |
| C | 空白を含む | `unsupported source URL %q: it contains whitespace` |
| D | `?` か `#` を含む | `unsupported source URL %q: it carries a query string or fragment. nvimx builds ?ref= and ?rev= itself from branch/tag/commit, so the source URL must not have one` |
| D2 | `${` を含む(2026-08-24 追記、PR #60 レビュー) | `unsupported source URL %q: it contains "${", which genflake.lua writes into flake.nix with %q -- %q does not escape "${", so it would land in the generated Nix source as a live string interpolation instead of literal text` |
| E | `/` `~` `.` で始まる(スキーム無し) | `unsupported source URL %q: it is a local path, not a git URL. Use dir = "..." with dev = true for a plugin you keep on disk, or file:///... for a local git remote` |
| F | 未知スキーム | `unsupported source URL %q: scheme %q is not a git transport nvimx can pin. Use one of https, http, ssh, git, file` |
| G | `file://` の authority が空でない(2026-08-24 訂正: 当初の文言は「相対パス」と言っていたが、原因は authority で、`file://home/me/repo.git` の authority は `"home"`) | `unsupported source URL %q: a file:// URL needs an empty authority, but %q comes right after file:// -- write file:///... (three slashes) for an absolute path` |
| H | host が空 | `unsupported source URL %q: it has no host` |
| I | path が空、または `"/"` 1 文字だけ(2026-08-24 追記: 後者はレビューで見つかった抜けで、`schemePath == ""` だけでは `https://git.example.com/` を弾けていなかった) | `unsupported source URL %q: it names a host but no repository path` |
| J | `^https://github%.com/` にマッチしたが、repo 側に**内側の** `/` がある(末尾 1 個の `/` は §3.4 の互換のため許す) | `unsupported source URL %q: a github.com URL must be exactly https://github.com/<owner>/<repo>, but its path is %q` |
| J' | J かつ path に `://` を含む | J の文言 + `. A full URL written in the short spec form is expanded by lazy's git.url_format -- write it as url = "..." instead` |
| K | 上記いずれでもない(`user@` を欠くコロン文字列もここに含む。2026-08-24 追記: §3.2 のとおり `user@` は scp 形式の必須要件になった) | `unsupported source URL %q: it has no scheme and is not the scp-style user@host:path form` |
| L | (generic scheme 分岐、2026-08-24 追記、PR #60 レビュー)authority の `@` 以降が host[:port] で、`:` の後ろが数字だけでない | `unsupported source URL %q: its authority %q has a non-numeric port %q -- nix's flake ref grammar requires everything after the last ":" in the authority to be all digits` |
| M | (generic scheme 分岐、2026-08-24 追記、PR #60 レビュー)authority + path に nix の flake-ref 文法が受理しない文字がある | `unsupported source URL %q: it contains %q, which is not valid in a nix flake ref URL` |

**J / J' の `path` の定義**: `https://github.com/` を取り除いた**生の残り**(`.git` 除去前)とする。
§3.2 の判定 3 は捕獲した repo 側から末尾 `.git` を落としてから形を検査するので、`owner .. "/" .. repo` を
組み直すと `.git` が消えた文字列になる。実測で
`https://github.com/ssh://git@example.com/o/shortform.nvim.git` は
`owner = "ssh:"` / `repo = "/git@example.com/o/shortform.nvim"`(`.git` 除去済み)になり、再結合値は
`ssh://git@example.com/o/shortform.nvim` = **ユーザが書いた文字列と 4 文字(`.git`)違う**。エラーは
入力と一字一句一致するほうが直しやすいので、`path` には `url:match("^https://github%.com/(.+)$")` で
別に取った生の残りを使う。**J' の判定「path に `://` を含む」も同じ生の残りに対して行う**
(再結合値で判定しても条件自体は成立するが、その場合は文言に載る `path` が入力とずれる)。

A の文言は `resolve.lua:275` の現行文をそのまま流用する(`plugin %q has no url.` → `fail_plugin` が
`plugin %q: ` を作るので `has no url.` から始める)。**現行文言を grep しているコードは無い**
(`grep -rn "has no url" . --include=*.nix --include=*.lua --include=*.md` のヒットは
`resolve.lua:275` の 1 件のみ)ので、prefix が `plugin "x" has no url` から `plugin "x": has no url` に
変わることによる回帰は無い。

J をフォールバックさせず拒否にする理由: `https://github.com/o/r/tree/main` のようなブラウザからの
コピペは、汎用 git として `git+https://github.com/o/r/tree/main` にしても **clone できない**。
現状これは `github:o/r/tree/main` = 「repo `r` の ref `tree/main`」と解釈され(§1.3 の実測)、
**エラーにならずに別物を指す**。ここは黙って別解釈するより落とすのが正しい。

J が拒否するのは **github 判定に落ちた URL だけ**である点に注意。`http://github.com/o/r/tree/main` や
`https://GitHub.com/o/r/tree/main` は §3.2 の判定 3 で github 判定に落ちないので、汎用 git として
そのまま受理される(現行と同じ扱い)。分類を広げないという §3.4 の方針の当然の帰結であり、
「github.com のブラウザ URL を全部捕まえる」ことは本件の目的ではない — 目的は
**現に黙って別物を指している経路を塞ぐ**ことである。

### 3.4 正規化の不変条件 — 「いま動いている lock は 1 つも動かない」

`source` は spec 恒等性の一部である(`resolve.lua:291` の
`local source_fields = { "type", "owner", "repo", "url" }`)。したがって正規化でどれか 1 フィールドでも
値が変われば `same_identity`(`:293-`)が false になり、`resolvedRef` が捨てられて再解決される
= flake input URL も変わって再 fetch が起きる。これを避けるため、次を設計上の不変条件とする:

> **`source.parse` は、現状すでに *意図どおりのリポジトリを指す* lock を生む URL については、
> `parse_source` と 1 バイト違わぬ `source` を返す。**

成立の根拠は §3.2 の判定アルゴリズムの構造そのものである:

- **github type**: 判定に使う正規表現を現行のまま(`^https://github%.com/([^/]+)/(.+)$`、`https` 限定・
  ホストは大小文字を区別)据え置き、末尾 `.git` 除去も現行のまま。**受理範囲を広げない**ので、
  `http://` も大文字ホストも今までどおり github 判定に落ちず、末尾 `/` は今までどおり
  `repo = "r/"` の github type になる。
- **git type**: 受理した URL は**入力そのまま**を格納する(`.git` を削らない、末尾 `/` を削らない、
  小文字化しない)。
- **ローカル**(`dev`/`dir`): `resolve.lua:653-655` で `parse_source` に到達しないので無関係。

**不変条件から外れる形は、次の 3 つだけである**(これが完全な列挙):

| 形 | 現状 | 本件後 | 判断 |
|---|---|---|---|
| scp(§3.2 #11-#13) | `{ type = "git", url = "git@h:o/r.git" }` → `git+git@h:o/r.git` | `url` が `ssh://git@h/o/r.git` に変わる | issue が明示的に要求する正規化。`source.url` が変わるので既存の `resolvedRef` は捨てられる(下記 + §7) |
| J(github.com の path が 2 セグメント超) | `github:o/r/tree/main` = **別の物を指す**(§1.3 の実測) | 拒否 | 「意図どおりのリポジトリを指す lock」ではないので保護対象外。本 issue の第一動機そのもの |
| D(ソース URL がクエリ / フラグメントを含む) | github type なら `github:o/r.git?ref=main` として parse は通る。さらに **`branch`/`tag`/`commit` を併用していない git type、例えば `url = "https://gitlab.com/o/r.git?ref=main"` は、`genflake.lua:58-67` が `params` を空のまま `?` を足さないので今日そのまま有効な lock を生む**(実測は下記) | 拒否 | `branch`/`tag` を併用した瞬間に二重クエリで壊れる(§3.5)。併用していない形は今日有効だが、`?ref=` は `branch`/`tag`/`commit` の二重表現であり、許すと genflake が組むクエリと衝突しないことを構造的に保証できない。**影響は scp より重い**(scp は `resolvedRef` を失うだけだが、D は lock 自体が fatal で止まり、設定を書き換えるまで復旧しない)ので、移行注意は §7 に scp と同格で置く |

D が「使っている人はいない」で済まない点に注意する。**nvimx はプラグインを nix input から取り、
lazy に clone させない**(`docs/architecture.md:531` が「`:Lazy` で全プラグインが local、git 操作ゼロ」を
スモークテストの受け入れ条件にしている)ので、「lazy 自身では clone できない URL だから誰も
書いていないはずだ」という反論は nvimx では効かない。`branch`/`tag`/`commit` を併用していない
git type の `?ref=` は実際に有効である:

```console
$ nix eval --raw --expr 'builtins.toJSON (builtins.parseFlakeRef "git+git://h/o/r?ref=main")'
{"ref":"main","type":"git","url":"git://h/o/r"}
$ nix eval --raw --expr 'builtins.toJSON (builtins.parseFlakeRef "git+https://gitlab.com/o/r.git?ref=main")'
{"ref":"main","type":"git","url":"https://gitlab.com/o/r.git"}
```

F/G/H/I/K/E で拒否する形の中には `builtins.parseFlakeRef` を通るものが混じる — 実測で
`git+ftp://h/o/r.git`・`git+https:///o/r.git`・`git+https://git.example.com` は通る。ただし
**「fetch もできない」と断定はしない**: git 自身は curl 経由で `ftp://` / `ftps://` をサポートするので、
`git+ftp://h/o/r.git` は実際に fetch できる可能性がある。それでもいずれも host か path を欠くか、
**本リポジトリの fixture にも docs にも前例が無い**形であり、「parse が通る」と「nvimx が pin できる
transport として支える」も別である。これらは不変条件の保護対象に数えないが、**理屈のうえでは今日
lock が通っていたものを落としうる**ことは認め、緩める余地は §7 の留保に残す。

**scp の `resolvedRef` が失われることの実害**は、「`flake.lock` 側は元々 `path:` ノードで壊れている」
だけでは説明しきれない。`plugins.json` の `resolvedRef` のほうは **scp 形式でも正しい値を持ち得る**:
semver 解決は `resolve.lua:778` の `url = p.url`(生の scp URL)を `git ls-remote`(`:883`)に渡し、
git は scp 形式を素で受け付けるので `refs/tags/vX.Y.Z` が正しく書かれる。`--import-lazy-lock` は
40hex を直接 `resolvedRef` に書く。`ssh://` 正規化でこれらは全部捨てられる。semver 由来は再解決で
同値に戻ることが多いが、**import 由来の 40hex は戻らない**(再解決の対象ではない)。§7 の移行注意
および PR 本文に書く。

なお **spec 恒等性の定義はリポジトリ内に 2 箇所ある**: `resolve.lua:291` と
`lua/nvimx/update-summary.lua:86`(`:83-84` のコメントが「resolve.lua の `identity_fields` /
`source_fields` と同じもの」と明言している)。本件は `source` のフィールド構成を変えないので
**どちらも無変更**だが(§5.8)、将来 `source` にフィールドを足すときは 2 箇所を揃える必要がある。

検証は §8-5(全 fixture の再生成 diff)と §8-6(`tests/source-parse-test.lua` の明示ケース)の
2 段で行う。前者だけでは足りない理由はゴール 4 に書いたとおり。

### 3.5 `?ref=` / `branch` / `tag` / `commit` との関係

**直交させる。** 責務分割は次のとおりで、本件はソース URL 側だけを触る:

- `source.lua`: 「どこから取るか」= transport + host + path。クエリ文字列は **禁止**(§3.3 D)。
- `genflake.lua:26-69`: 「どの ref を取るか」= github type なら path の 1 セグメント
  (`github:o/r/refs/tags/v1`)、git type なら `?ref=` / `?rev=`。ここは無変更。

D で `?` を禁じるので、`genflake.lua:65-67` が付ける `?` は常に URL 中で最初の `?` になり、
二重クエリは構造的に発生しない。scp 形式が `ssh://` に正規化されたあとも、
`git+ssh://git@h/o/r.git?ref=refs/tags/v1.0.0&rev=<40hex>` が問題なく parse されることは §3.2 で実測済み。

**`branch` / `tag` の値そのものの検証は本件の範囲外**とする(§7)。git は refname に `&` を許すため
`branch = "a&b"` は `?ref=a&b` になって nix が `b` を未知パラメータとして拒否するが、これは
「ソース URL の検証」ではなく「ref の検証」であり、別 issue に切るのが筋である。

### 3.6 `dev` / `dir` ローカルプラグインと #47

`resolve.lua:652-655`:

```lua
for name, p in pairs(raw.plugins or {}) do
  if p.dev or p.dir then
    local_plugins[name] = { dir = p.dir }
  else
```

`parse_source` は `else` 側でしか呼ばれない。**この分岐には一切手を入れない**。よって:

- `dev = true` のプラグイン: 今も本件後も `source.parse` に届かない。URL 検証と無関係。
- `dir` はあるが `dev` が無いプラグイン(#47): `extract.lua:114` により raw-spec の `dir` が null に
  なるため remote 扱いのまま `source.parse` に届くが、その URL は `p[1]` から作られた
  `https://github.com/o/r.git`(§1.1 の実測)なので **受理される**。
  すなわち #47 の挙動は本件の前後で同一である。
- ただし `{ dir = "~/src/bar" }` のように `[1]` も `url` も無い spec は、今も本件後も
  「url が無い」で fatal になる(A)。**重大度も終了コードも変わらない**。
- #47 が入ると `p.dev or p.dir` の `p.dir` が実際に埋まるようになり、これらは `local_plugins` 側に
  分岐して `source.parse` に届かなくなる。**本計画は #47 の修正方向を塞がない**し、
  §3.3 E の文言(`Use dir = "..." with dev = true ...`)も #47 後にそのまま正しいままである。

### 3.7 `genflake.lua` は「コメントのみ」

issue の Files には `genflake.lua` が挙がっているが、**コード変更は入れない**。理由:

1. `genflake.lua` が壊れた URL を作れるのは、入力の `plugins.json` に §3.3 で拒否される
   `source` が入っている場合だけである。`nix/lib/lock-app.nix:216` → `:235` は
   **常に resolve → genflake の順**で走り、resolve は失敗時に出力を書かない
   (`resolve.lua:1236-1238` の「a failed resolve must not overwrite plugins.json with a partial
   result」)ので、パイプライン経由でその状態には到達できない。
2. 二重に検証を置くと、文言の同期という保守負債が生まれる。本リポジトリに
   「同じ規則を 2 箇所に実装する」前例は無い。
3. 一方で `genflake.lua:28-40` の github 分岐が `("github:%s/%s"):format(src.owner, src.repo)` を
   無検査で組めるのは、`source.lua` が owner/repo に**内部の** `/` を含ませないと保証しているから
   である(repo 末尾の 1 個の `/` は §3.4 の互換性不変条件のために残るので、この保証の対象外)。
   **この依存は明示されるべき**なので、`:26` の `-- lazy spec → flake input URL mapping` コメントに
   「owner/repo に内部の `/` が無いこと(repo 末尾の 1 個の `/` は §3.4 の互換性不変条件のために
   残る)、`?` が無いこと、`src.url` にクエリが無いことは `lua/nvimx/source.lua` が保証する(#28)」
   の文を足す。

却下案「genflake でも `?` の二重化を assert する」: 1 により到達不能なコードになる。
到達不能な assert を足すより、なぜ不要かをコメントに残すほうが本リポジトリの流儀に合う。

### 3.8 エラー報告のタイミング — 既存のまま(本件では前倒ししない)

`report_resolve_errors()` の既存の呼び出しは 2 箇所:

- `resolve.lua:641` — `--update` の名前検証直後。コメント(`:603-607`)が理由を書いている:
  「an unknown name must not survive long enough to spend a `git ls-remote` on it」。
- `resolve.lua:1239` — 最後。semver 解決の失敗を集約する。**ここは出力書き込みより前**である
  (`:1235-1238` のコメント「No output file is written past this point (#18 §3.4's ordering
  requirement: a failed resolve must not overwrite plugins.json with a partial result)」)。

**採用: URL エラーは `:1239` の既存 flush に相乗りさせ、新しい flush 地点は足さない。**

- issue の "Done when" は前倒しを一切要求していない。要求は「lock の前に、プラグイン名と URL を
  挙げて落ちる」ことであり、`:1239` は `plugins.json` の書き込みより前なのでこれを満たす。
- 代償は「不正 URL のプラグインに `git ls-remote` を 1 回費やす」こと(`version` を持つ場合のみ。
  `resolve.lua:774` のゲートを通り `:883` が走る)。どのみち落ちる run で高々数秒の無駄であり、
  検証が入ったあとでも許容範囲である。クラッシュもしない(§4.1)。
- 前倒しには**失うものがある**: `plugin_warnings` の emit ループは `resolve.lua:1009-1011` にあるので
  (`:1003-1008` は決定的順序のための `table.sort`)、
  メインループ直後で flush すると build 警告が**丸ごと出ないまま**終わる。それを固定する check を
  新設するのは、issue が要求していない挙動変更のために compensating machinery を足すことになる。

**follow-up に切り出す**(§7)。切り出しても `source.parse` の「raise せず `nil, err` を返す」設計
(§3.1-3)は変わらないので、あとから `:793` 付近に 1 行足すだけで実現できる。

**却下**: `pending` / `versioned` への push を「source が不正なら skip」する。ネットワークは
避けられるが、条件を 2 箇所に増やすうえ、`:1239` まで走らせても最終的に落ちることに変わりはない。

### 3.9 `resolve.lua` 側の `parse_source` の姿(**定義位置を含む**)

#### 3.9-1 位置の制約 — 先に決めておく

`fail_plugin` は `resolve.lua:379` の `local function fail_plugin` で宣言される **local** である。
lua のレキシカルスコープでは local は宣言より後ろのコードからしか見えないので、`fail_plugin` を呼ぶ
関数を現行 `parse_source` の位置(`:272-283`)に置くと、その `fail_plugin` は
**宣言前の名前 = グローバル参照(nil)**になる。壊れ方は 2 つあり、どちらも致命的である:

- **実行時**: 拒否対象の URL が 1 件でもあると
  `attempt to call a nil value (global 'fail_plugin')` でトレースバック死する。
  §3.1-3 / §3.8 が設計の柱にしている「全プラグインの URL エラーを `:1239` でまとめて報告する」も、
  §5.6(b) の行数・並び順の assert も一切成立しない(拒否側の check がそもそも赤くなる)。
- **`nix fmt -- --ci`**: `.luacheckrc` は `std = "luajit"`(`:2`)と `globals = { "vim" }`(`:6`)だけで、
  luacheck が `accessing undefined variable fail_plugin` を出して非ゼロ終了する。
  `flake.nix:146-149` の `settings.formatter.luacheck.includes = [ "*.lua" ]` は `*.lua` を除外なしで
  拾う(§5.8)ので、`resolve.lua` は必ずこの検査の対象になる。**§8-1 が落ちる。**

既存の `fail_plugin` 呼び出しがすべて `:604` 以降にあるのは偶然ではなく、この制約の帰結である
(`:630` / `:632` / `:838` / `:845` / `:896`-`:946`)。

#### 3.9-2 採用 (A): `parse_source` を `warn_plugin` の直後へ移設する

**`parse_source` を `:272-283` から削除し、`warn_plugin` の定義(`:436-438`)の直後へ移設する。**
`fail_plugin`(`:379`)と `report_resolve_errors`(`:388-402`)より後ろ、唯一の呼び出し元
`:677` より前という条件を満たす。**呼び出し側(`:675-686` の `entry` テーブルリテラル)は 1 文字も
変えない。**

理由(実コードに対して):

1. **却下案 B にすると `parse_source` が存在理由を失う**。`source.parse(url)` は §3.3 の A/B
   (非文字列 / 空文字列)まで含めて `nil, err` で返すので、`parse_source(url) -> src, err` は
   `return source.parse(url)` そのものになる。つまり B は実質「`parse_source` を消して呼び出し元で
   `source.parse` を直接呼ぶ」であり、issue が要求していない理由で A より大きな変更を入れることになる。
2. **A は呼び出し側を無変更に保てる**。`:677` は `entry` テーブルリテラル(`:675-686`)の中の
   `source = parse_source(name, p.url),` という 1 式である。B ではこれを分解してリテラルの前に
   5 行のエラー処理を置くことになり、フォールバック値(`{ type = "git", url = ... }`)と
   「なぜフォールバックが要るか」のコメントがメインループ(`:652-`)の中に散る。
   A はそれを 1 つの関数の中に閉じ込めたままにする。
3. **移設先が意味的に正しい**。`warn_plugin`(`:436-438`)は「プラグイン単位の診断を集める」ヘルパで、
   本件後の `parse_source` はまさに同じ役目を持つ。両者が `fail_plugin` / `report_resolve_errors` の
   後ろに並ぶのは、このファイルが既に守っている順序そのものである。
4. **移設で壊れる参照は無い**。`grep -n 'parse_source' lua/nvimx/resolve.lua` のヒットは定義
   (`:273`)と呼び出し(`:677`)の 2 件だけで、`:272-283` の跡地に残る `to_input_name`(`:268-270`)/
   `identity_fields` `source_fields`(`:290-291`)との隣接には意味が無い(後者は source を**比較**する
   側であって、**作る**側ではない)。

```lua
-- Convert the git URL normalized by lazy into a source struct (#28). The rules live in
-- source.lua so they can be unit-tested against the whole accept/reject matrix without a
-- fixture (checks.source-parse), the same split lua/nvimx/version.lua has with
-- checks.semver-select. Failures are collected rather than raised so that one lock run
-- reports every bad URL at once -- report_resolve_errors() near the end of this file prints
-- them, sorted, and exits before plugins.json is ever written.
-- This has to stay *below* fail_plugin's declaration, which is why it lives here rather than
-- next to to_input_name where it used to: fail_plugin is a local, so a call placed above it
-- would silently resolve to a nil global and blow up on the first bad URL (luacheck flags it
-- as an undefined variable, so `nix fmt -- --ci` catches the mistake too).
local function parse_source(name, url)
  local src, err = source.parse(url)
  if err then
    fail_plugin(name, err)
    -- Only ever reached on a run that is already doomed: report_resolve_errors() exits before
    -- anything is written. It exists so the loop can keep collecting the *other* plugins'
    -- errors instead of dying on whichever one pairs() happened to visit first.
    return { type = "git", url = tostring(url) }
  end
  return src
end
```

`schemaVersion` は **1 のまま**。`plugins.json` のスキーマは 1 フィールドも増減しない
(`source` の中身の値が正規化されるだけ)。

#### 3.9-3 却下 (B): `parse_source(url) -> src, err` にして呼び出し元で `fail_plugin` を呼ぶ

`parse_source` を `:272-283` に残したまま純関数化する案。上記 1-2 のとおり `parse_source` が
`return source.parse(url)` の別名に退化するうえ、`:675-677` はテーブルリテラルの中なので
呼び出し元をこう組み直す必要がある(参考のために具体形を残す):

```lua
    -- rejected shape: the `if` and the fallback value have to sit in the main loop
    local src, src_err = source.parse(p.url)
    if src_err then
      fail_plugin(name, src_err)
      src = { type = "git", url = tostring(p.url) }
    end

    local entry = {
      inputName = input_name,
      source = src,
      branch = p.branch or vim.NIL,
      -- ... 以下 :678-686 は無変更
    }
```

## 4. 既存機能との関係

### 4.1 #23(semver 解決)

- `resolve.lua:778` の `url = p.url` は **raw の URL のまま**にする(変更しない)。
  git は scp 形式も `ssh://` 形式も等価に扱うので `git ls-remote` はどちらでも通り、
  一方で正規化後の値に変えると github type には `source.url` が無いため
  `https://github.com/<owner>/<repo>.git` を組み直す必要が生じ、既存 fixture
  (`file://$sb/tagged` を jq で `url` に注入している `flake.nix:1883` など)にも影響が及ぶ。
- §3.8 のとおり本件は flush を前倒ししないので、**不正 URL のプラグインでも `version` があれば
  `git ls-remote` が 1 回飛ぶ**。クラッシュはしない: `:875-876` が `type(item.url) ~= "string"` と
  `item.url == ""` を既に弾いており(A/B に相当)、それ以外の不正 URL は git 側のエラーになって
  `resolve_errors` の隣に並ぶだけである。この無駄を消すのは §7 の follow-up。
- `file://` 受理は #23 の check の前提そのものである(§1.4)。

### 4.2 #24(`--update`)

`--update` の名前検証は `:608-641`(理由を書いたコメント込みなら `:603-641`)で本ループより前に走り、
`report_resolve_errors()`(`:641`)を自分で呼んで exit する。本件は新しい flush 地点を足さないので
(§3.8)、報告順序は現行のまま「不正な `--update` 名 →(`:1239` で)URL エラー + semver エラー」で
あり、`--update` 側の早期 exit も無変更である。

### 4.3 #25(`--import-lazy-lock`)

import の seed は `resolvedRef` にしか書かず、`source` には触らない。ただし
`docs/architecture.md:251` の caveat「git type のプラグインに `tag` があると
`?ref=refs/tags/<t>&rev=<sha>` の両方が付く」は、scp 形式が `ssh://` に正規化された
プラグインにもそのまま当てはまる(実測で parse は通る)。文言の修正は不要。

### 4.4 #47(`dir` without `dev`)

§3.6 のとおり、本件は #47 が変えたい分岐(`resolve.lua:653` と `extract.lua:114`)に触らない。
#47 を先に入れても後に入れても、本件の受理/拒否マトリクスは変わらない。

### 4.5 `docs/architecture.md`

| 行 | 作業 |
|---|---|
| `:245` | URL マッピング表の `explicit git URL` 行を書き換える。現行の `(github.com is normalized to the github type)` は不正確なので、(1) `git+https://` / `git+http://` / `git+ssh://` / `git+git://` / `git+file://` を受理すること、(2) scp 形式 `git@host:owner/repo` が `git+ssh://` に正規化されること、(3) **github type に落ちるのは `https://github.com/<owner>/<repo>` だけ**で、`http://`・大文字ホスト・ssh/scp の github.com は git type のまま透過されること、が読める形にする |
| `:245` の直後 | `**Source URL validation** (#28)` の段落を新設。受理する形の一覧、拒否は lock 前に fatal でプラグイン名と URL を挙げること、`?` / `#` は genflake が所有するので禁止であること、**移行注意 2 件**(scp → `ssh://` 正規化の caveat = ホーム相対性 + 既存 `resolvedRef` の破棄、および `?ref=` / `?rev=` を持つソース URL は `branch` / `tag` / `commit` へ書き換える必要があること。どちらも §7)、そして **github.com の ssh/scp をあえて github type に寄せない理由**(§3.2 の却下案: 寄せると公開 repo の fetch が軽くなる代わりに、private repo を ssh 鍵で引いているユーザの fetch が壊れる)を書く |
| `:478` 付近 | `lua/nvimx/` のレイアウト一覧(`:475-481` が全モジュールを 1 行ずつ挙げている)に `source.lua  # pure: plugin source URL の分類・正規化・検証(#28)` の 1 行を、`version.lua`(`:478`)の隣に足す。新規モジュールを足してここを更新しないと、一覧が実体と食い違う |
| `:483` | fixtures 一覧に `source-urls` を追加 |
| `:492` | checks 一覧に `resolve-sources` と `source-parse` を追加 |
| `:493` | `planned, not yet implemented: genflake-golden (#29)` の行は **そのまま残す**。理由は §4.6 |
| `:504` | edge-case 表の `Non-GitHub / explicit git URL` 行を「受理する形を列挙し、それ以外は lock 時にプラグイン名と URL を挙げて fatal」に書き換える |
| `:526` | Phase 7 の `non-GitHub validation` はそのまま(完了して初めて消せる項目なので、ここは触らない) |

`README.md` は **`:177-180` の caveat リストに足す**(§5.7)。URL 形式そのものの話は
`docs/architecture.md` が唯一の出典であり、README の Usage / Options に URL の記述は無いので
それ以外は変更しない。例外を作る理由は、`:177-180` が既に「non-GitHub git URL のプラグイン」向けの
`--import-lazy-lock` 移行 caveat を置いている場所で、scp 形式の `resolvedRef` 破棄(§7)は
そこに並ぶ同じ粒度の移行注意だからである。**2026-08-24 追記(PR #60 レビュー)**: 当初案は
「1 行だけ」の予定だったが、PR 本文の記述を事実に合わせるため `?ref=` / `?rev=` クエリ拒否の
caveat も並べて足すことになった(§5.7 の追記を参照) — 都合 2 行になる。

### 4.6 #29(`genflake-golden` と richer fixtures)との関係

`docs/architecture.md:493` は `planned, not yet implemented: genflake-golden (#29)` を挙げている。
#29 の本文は「fixture を plain github / `branch` / `tag` / `commit` / `version` / `dev` / shell build /
excmd build / dependencies / non-GitHub git URL のマトリクスに拡張し、`resolve-golden`(raw-spec →
`plugins.json`)と `genflake-golden`(`plugins.json` → 生成 flake)の 2 つの golden check を足す」である。
本件の `checks.resolve-sources` は**形として同型**(raw-spec → resolve → genflake → golden diff)なので、
重ならないことを明示しておく。

- `resolve-sources` の fixture は **URL 形式のマトリクスに限定する**。`version` は 1 つも置かない
  (実 remote が要りオフラインでなくなる)、`dev` / `dir` も置かない(§3.6 のとおり `source.parse` に
  届かないので、この check で守るものが無い)、build 分類も dependencies も置かない。
- したがって #29 が扱う build 分類 / dependencies / `dev` / `version` のマトリクスは
  `resolve-sources` では **1 つも代替されない**。#29 は独立した open issue のまま残し、
  `docs/architecture.md:493` の行も消さない(#29 が入ったときに消す)。
- 重なるのは「#29 の fixture に non-GitHub git URL を 1 件入れる」という部分だけで、これは #29 側の
  マトリクスに 1 行あるかどうかの話であり、本件が持つ 18 行の受理マトリクスを置き換えない。
- **本件で #29 を吸収して close することはしない**。マトリクスの軸(URL 形式 / spec フィールド)が
  違うので 1 つの golden に混ぜると fixture が読めなくなり、落ちたときにどちらの回帰か分からなくなる。

## 5. 実装手順

### 5.1 `lua/nvimx/source.lua`(新規)

ヘッダコメントは `version.lua:1-12` の流儀に合わせ、(a) この層が純関数であること、
(b) 失敗は raise ではなく `nil, err` で返すこと、(c) 受理マトリクスの出典が
`docs/architecture.md` の URL マッピング表であること、(d) `?` / `#` を禁じるのは
`genflake.lua` がクエリを所有するからであること、を書く。

公開 API は `M.parse(url)` の 1 つだけ。§3.2 のアルゴリズムをそのまま実装する。
内部ヘルパ(`split_scheme` / `parse_scp` / `github_owner_repo`)はローカル関数にする。

### 5.2 `lua/nvimx/resolve.lua`

| 行 | 作業 |
|---|---|
| `:105`(`:104` の直後) | `local source = dofile(arg[0]:gsub("resolve%.lua$", "source.lua"))` を追加 |
| `:272-283` | `parse_source`(コメント 1 行 + 関数 11 行)を**まるごと削除**する。跡地には何も残さない(§3.9-2) |
| `:436-438`(`warn_plugin` の定義)の直後 | §3.9-2 の `parse_source` を**新規に挿入**する。`fail_plugin`(`:379`)より後ろに置くこと自体が要件である(§3.9-1)。この表の行番号はすべて編集前のものなので、挿入位置は行番号ではなく **`warn_plugin` の `end` を目印にする** |
| `:675-686`(`entry` テーブルリテラル) | **無変更**。`:677` の `source = parse_source(name, p.url),` はそのまま(移設方式を採ったのはこれを保つためでもある。§3.9-2) |
| `:1235-1239` | **無変更**。URL エラーはここの既存 flush に相乗りする(§3.8)。コメントの「No output file is written past this point」もそのまま正しい |

**`fail`(`:22-25`)は残す**。`read_json` など他の呼び出し元がある。
**新しい `report_resolve_errors()` 呼び出しは足さない**(§3.8。前倒しは §7 の follow-up)。

**本件が `resolve.lua` に足すコードは上表の 2 つ(`:105` の `dofile` と移設後の `parse_source`)だけ**で、
他に「宣言前の local を呼ぶ」箇所は無い。`:105` の `dofile` は local を 1 つも呼ばない
(`arg` は luacheck の標準グローバルで宣言不要。`.luacheckrc:8-9` に明記されている)。
`warn_plugin` / `fail_plugin` / `report_resolve_errors` を呼ぶ新規コードは §3.9-2 の `parse_source` のみ
であり、その配置が §3.9-1 の制約を満たしていることは上表の 3 行目が担保する。
仮にこの制約を将来壊しても、`nix fmt -- --ci` の luacheck(`flake.nix:146-149`)が
undefined variable として非ゼロで落とす(§3.9-1 / §8-1)。

### 5.3 `lua/nvimx/genflake.lua`

`:26` の `-- lazy spec → flake input URL mapping (see docs/architecture.md)` に、§3.7-3 の
1 文を足すだけ。コードは無変更。

### 5.4 fixture(新規 `tests/fixtures/source-urls/`)

```
tests/fixtures/source-urls/
  raw-spec-ok.json         # 受理マトリクス(§3.2)。手書き
  raw-spec-bad.json        # 拒否マトリクス(§3.3)。手書き
  golden/
    ok.plugins.json        # resolve の出力
    ok.flake.nix           # genflake の出力(= 受理マトリクスの最終形)
```

**`golden/bad.log` は置かない。** 拒否文言の全文固定は `tests/source-parse-test.lua` に一本化し、
統合側(`checks.resolve-sources`)は「行数・名前昇順の並び・`plugin "<name>"` と URL が載っていること」
だけを守る(§5.6(b) / §6.1)。既存の同型 check もそうしている: `resolve-merge` は生成 flake の URL を `flake.nix:1703-1704` の
2 本の `grep -q` でしか見ておらず(`:1701-1702` はその 2 本の理由を書いたコメント)、`:1805` も
`grep -q 'schemaVersion 2'` で済ませている。19 件の文言を golden と unit の 2 箇所で全文固定するのは
issue の "**a** failure case" に対して過剰で、文言を 1 語直すたびに 2 ファイルを直す二重管理を生む。

`merge/` と同じく **手書きの raw-spec** にする。理由も同じで、
「lazy が spec をどう正規化するかとは独立に、テストが意図した形ちょうどを並べたい」から。
`raw-spec-ok.json` の `_comment` に、(a) 手書きである理由、(b) `version` を 1 つも置かない理由
(制約解決には実 remote が必要になり、このテストがオフラインでなくなる。`merge/raw-spec-base.json:6-11`
と同じ断り書き)、(c) この表が `docs/architecture.md` の URL マッピング表と対になっていること、を書く。

`raw-spec-ok.json` のプラグイン(§3.2 の #1-#17 に、`?ref=` / `?rev=` 合成の確認 3 件を足した 20 件):

| plugin 名 | `url` | 追加フィールド | 期待 input URL |
|---|---|---|---|
| `short.nvim` | `https://github.com/o/short.nvim.git` | — | `github:o/short.nvim` |
| `nodotgit.nvim` | `https://github.com/o/nodotgit.nvim` | — | `github:o/nodotgit.nvim` |
| `trailing.nvim` | `https://github.com/o/trailing.nvim/` | — | `github:o/trailing.nvim/`(**現行分類の据え置き**、§3.4) |
| `httpgh.nvim` | `http://github.com/o/httpgh.nvim.git` | — | `git+http://github.com/o/httpgh.nvim.git`(同上。github type に**しない**) |
| `upperhost.nvim` | `https://GitHub.com/o/upperhost.nvim` | — | `git+https://GitHub.com/o/upperhost.nvim`(同上) |
| `ghtag.nvim` | `https://github.com/o/ghtag.nvim.git` | `tag = "v1.0.0"` | `github:o/ghtag.nvim/refs/tags/v1.0.0` |
| `ghe.nvim` | `https://github.example.com/o/ghe.nvim.git` | — | `git+https://github.example.com/o/ghe.nvim.git` |
| `nested.nvim` | `https://gitlab.com/g/sub/nested.nvim.git` | — | `git+https://gitlab.com/g/sub/nested.nvim.git` |
| `tildeuser.nvim` | `https://git.sr.ht/~user/tildeuser.nvim` | — | `git+https://git.sr.ht/~user/tildeuser.nvim` |
| `single.nvim` | `https://git.example.com/single.nvim.git` | — | `git+https://git.example.com/single.nvim.git` |
| `http.nvim` | `http://git.example.com/o/http.nvim.git` | — | `git+http://git.example.com/o/http.nvim.git` |
| `scp.nvim` | `git@git.example.com:o/scp.nvim.git` | — | `git+ssh://git@git.example.com/o/scp.nvim.git` |
| `scpgh.nvim` | `git@github.com:o/scpgh.nvim.git` | — | `git+ssh://git@github.com/o/scpgh.nvim.git` |
| `scpuser.nvim` | `forgejo@git.example.com:o/scpuser.nvim.git` | — | `git+ssh://forgejo@git.example.com/o/scpuser.nvim.git` |
| `scpbranch.nvim` | `git@git.example.com:o/scpbranch.nvim.git` | `branch = "trunk"` | `git+ssh://git@git.example.com/o/scpbranch.nvim.git?ref=trunk` |
| `scpcommit.nvim` | `git@git.example.com:o/scpcommit.nvim.git` | `commit = "cccc…"`(40 hex) | `git+ssh://git@git.example.com/o/scpcommit.nvim.git?rev=cccc…` |
| `ssh.nvim` | `ssh://git@git.example.com/o/ssh.nvim.git` | — | `git+ssh://git@git.example.com/o/ssh.nvim.git` |
| `sshport.nvim` | `ssh://git@git.example.com:2222/o/sshport.nvim.git` | — | `git+ssh://git@git.example.com:2222/o/sshport.nvim.git` |
| `gitproto.nvim` | `git://git.example.com/o/gitproto.nvim.git` | — | `git+git://git.example.com/o/gitproto.nvim.git` |
| `file.nvim` | `file:///nvimx-nonexistent/file.nvim` | — | `git+file:///nvimx-nonexistent/file.nvim` |

`file:///nvimx-nonexistent/...` は既存 fixture(`tests/fixtures/semver/`、`update/`)と同じ
「絶対に存在しないが形は正しい」慣習に合わせる。

`raw-spec-bad.json` のプラグイン(§3.3 の各記号を 1 件ずつ、19 件。D/E/I/K は同じ記号に至る 2 通りの
形を確認するため 2 件ずつ置く。**PR #60 のレビュー(2026-08-24)で D2/L/M と、I/K の 2 件目を追加**した):

| plugin 名 | `url` | 期待する記号 |
|---|---|---|
| `nourl.nvim` | (キー自体を書かない) | A |
| `emptyurl.nvim` | `""` | B |
| `space.nvim` | `https://git.example.com/o/space nvim.git` | C |
| `query.nvim` | `https://git.example.com/o/query.nvim.git?ref=main` | D |
| `frag.nvim` | `https://git.example.com/o/frag.nvim.git#main` | D |
| `antiquote.nvim` | `https://git.example.com/o/antiquote.${var}.nvim.git` | D2 |
| `barepath.nvim` | `/home/me/repos/barepath.nvim` | E |
| `homepath.nvim` | `~/repos/homepath.nvim` | E |
| `ftp.nvim`(`version = "^1.0"` も持つ) | `ftp://git.example.com/o/ftp.nvim.git` | F。バージョン制約付きでも `pending` に積まれず `git ls-remote` を一切呼ばないことの回帰確認を兼ねる(§7 の #24 前例、resolve.lua の該当コメント参照) |
| `relfile.nvim` | `file://relative/relfile.nvim` | G |
| `nohost.nvim` | `https:///o/nohost.nvim.git` | H |
| `nopath.nvim` | `https://git.example.com` | I |
| `trailingslash.nvim` | `https://git.example.com/` | I(末尾 `/` だけの一byte長い形。`schemePath == ""` だけでは弾けなかった) |
| `browser.nvim` | `https://github.com/o/browser.nvim/tree/main` | J |
| `shortform.nvim` | `https://github.com/ssh://git@example.com/o/shortform.nvim.git` | J' |
| `plain.nvim` | `just-a-name` | K |
| `usercolon.nvim` | `gitea.internal:8080` | K(`user@` を欠く scp もどき。以前は `ssh://` へ誤って正規化されていた) |
| `sshportmistake.nvim` | `ssh://git@github.com:o/sshportmistake.nvim.git` | L(authority のポート部が非数字) |
| `badchar.nvim` | `https://h\|x/o/badchar.nvim.git` | M(nix の flake-ref 文法が受理しない文字) |

`nourl.nvim` と `emptyurl.nvim`(A/B)だけは出力行に URL が載らない。§3.3 のとおり意図的な例外で、
§5.6(b) の URL 存在 assert はこの 2 件を除外して書く。

### 5.5 `tests/source-parse-test.lua`(新規)

`tests/semver-select-test.lua` と同型の unit driver。`arg[1]` に `source.lua` のパスを取り、
`dofile` して受理/拒否のテーブルを回す。ヘッダコメントに
「Failure is a plain Lua error from `assert()`」を書くのも同じ。

**このファイルが拒否文言の唯一の出典である**(§5.4 のとおり `golden/bad.log` は置かない)。
ヘッダコメントにそれを明記し、統合側の `checks.resolve-sources` は行の形しか見ないことも書く。

**`pcall` は使わない**。`source.parse` は §3.1-3 のとおり raise せず `nil, err` を返す設計なので、
失敗ケースも成功ケースと同じ `eq()` で書ける。この点はヘッダコメントに明記する
(`version.lua` の `select_tag` が `nil, detail` を返すのと同じ理由で、
「重大度と文言の決定は呼び出し側の仕事」だから raise しない)。

```lua
-- 受理
for _, c in ipairs(accept_cases) do
  local src, err = src_mod.parse(c.url)
  assert(err == nil, ("parse(%q) unexpectedly failed: %s"):format(c.url, tostring(err)))
  eq(src.type, c.type, ("parse(%q).type"):format(c.url))
  eq(src.owner, c.owner, ...)
  eq(src.repo, c.repo, ...)
  eq(src.url, c.url_out, ...)   -- git type のみ。github type では nil であることを確認する
end

-- 拒否: err の中身まで固定する(文言の出典はここだけ)
for _, c in ipairs(reject_cases) do
  local src, err = src_mod.parse(c.url)
  assert(src == nil, ("parse(%q) should have been rejected"):format(tostring(c.url)))
  eq(err, c.err, ("parse(%q) message"):format(tostring(c.url)))
end
```

`accept_cases` には **§3.4 の不変条件を直接固定する 3 ケースを必ず置く**。**§8-5 が回す既存 4 fixture
(basic-config / build-plugins / registry-plugins / treesitter-config)には 1 件も存在しない形**なので、
§8-5 の再生成 diff ではこの回帰を検出できない(ゴール 4)。3 形は本件で新設する `raw-spec-ok.json` には
`trailing.nvim` / `httpgh.nvim` / `upperhost.nvim` として実在し(§5.4)、`checks.resolve-sources` の
`jq -e` 3 本(§5.6(b))が end-to-end 側を固定する — ここはその純関数半分である。コメントで
その理由を書く:

| 入力 | 期待する `source` | 何を守るか |
|---|---|---|
| `http://github.com/o/r.git` | `{ type = "git", url = "http://github.com/o/r.git" }` | github 判定を `https` 限定から広げていないこと |
| `https://GitHub.com/o/r` | `{ type = "git", url = "https://GitHub.com/o/r" }` | github 判定を大小文字非依存にしていないこと |
| `https://github.com/o/r/` | `{ type = "github", owner = "o", repo = "r/" }` | 末尾 `/` を削っていないこと |

拒否ケースには `nil` / `42` / `{}`(非文字列)も入れる。これは fixture 経由では作りにくく、
unit test 側にしか置けない(A の分岐を実際に踏む唯一の手段が `nil` のみだと弱いため)。

### 5.6 `flake.nix`

#### (a) `checks.source-parse`(新規、`semver-select` の直後 = `flake.nix:1346` の `'';` の次の行)

```nix
          # Pure unit test of lua/nvimx/source.lua (#28): the whole accept/reject matrix of plugin
          # source URLs, with no fixture, no jq, no git and no network. This is the *only* place a
          # rejection's exact wording is pinned -- the integration side (checks.resolve-sources)
          # deliberately checks the shape of the failure output, not its text, so a reworded message
          # never has to be edited in two files. Same split checks.semver-select has with
          # checks.resolve-semver.
          source-parse =
            pkgs.runCommand "source-parse"
              {
                nativeBuildInputs = [ pkgs.neovim-unwrapped ];
              }
              ''
                nvim -l ${./tests/source-parse-test.lua} ${./lua/nvimx/source.lua}
                touch $out
              '';
```

#### (b) `checks.resolve-sources`(新規、`resolve-import-lazy-lock` の直後 = `flake.nix:2730`)

挿入位置に注意: `resolve-import-lazy-lock` は `flake.nix:2729` の `'';` で終わり、`:2730-2736` は
`dev-plugins` の説明コメント、`:2737` が `dev-plugins =` である。したがって「直後」は `:2730`。

要点は 3 つ。

1. **受理側は 2 つの golden で固定する**。`plugins.json`(正規化結果)と `flake.nix`(最終成果物)。
   後者が issue の "Each supported URL form locks to the expected flake input" そのものである。
2. **flake ref としての妥当性は nix 自身に判定させる**。golden の `flake.nix` を評価時に `import` し、
   `builtins.parseFlakeRef` を全 input URL に適用した結果を derivation の env に渡して**強制**する。
   golden は *source* ファイルなので `import` は素の `readFile` であり、**IFD にはならない**
   (IFD になるのは derivation の *出力* を読む場合)。生成 flake は `outputs = _: { };` を持つ素の
   attrset なので `import` も妥当。「生成物 == golden」は derivation 側の `diff` が保証するので、
   2 つを合わせて「生成物の全 URL が flake ref として妥当」が IFD 無しで言える。
   ただし **parse が通るだけでは §1.3 のガードにならない**: `parseFlakeRef` は
   `github:o/r/tree/main`(`ref = "tree/main"` の github ref)も `just-a-name`(`indirect`)も受理する。
   そこで **各 ref の `type` が `github` か `git` のいずれかであること**まで assert する。
   `indirect` / `path` が 1 つでも混じっていれば §1.3 の降格が再発している。
3. **拒否側は exit code + 出力の *形* を見る**。文言の全文一致はやらない(§5.4)。
   `resolve-merge` が `prev-broken` / `prev-future` で使う `rc=0; ... || rc=$?` をそのまま踏襲する。

```nix
          # Every URL form a lazy spec can put on a plugin, end to end: raw-spec -> resolve ->
          # genflake, against a golden plugins.json and a golden flake.nix (#28). Fully offline --
          # no fixture here names a reachable remote, and nothing in raw-spec-ok.json carries a
          # `version`, so git ls-remote is never reached (constraint resolution is
          # checks.resolve-semver's job). URL shapes only: build classification, dependencies, dev
          # and version are the matrix #29's genflake-golden is for, not this check's.
          resolve-sources =
            let
              # The golden flake *is* the accept matrix, so every URL in it has to be something
              # nix's own flake ref parser accepts -- asserted here at evaluation time rather than
              # with a hand-rolled regex in bash. No IFD: the golden is a source file, so importing
              # it is a plain readFile, and the derivation below is what proves the generated flake
              # still equals it. Only the accept side is guarded here; what a *rejected* URL prints
              # is checks.source-parse's job.
              goldenFlake = import ./tests/fixtures/source-urls/golden/ok.flake.nix;
              refTypes = builtins.mapAttrs (_: i: (builtins.parseFlakeRef i.url).type) goldenFlake.inputs;
              # parseFlakeRef succeeding is too weak to mean "nvimx can pin this": it accepts
              # `github:o/r/tree/main` (a github ref whose *ref* is "tree/main" -- a different tree
              # than the user asked for) and bare `just-a-name` (an `indirect` registry lookup).
              # And an input nix cannot parse at all does not fail the lock either: it degrades to a
              # `path:` node with no narHash that only dies later, in nix/lib/sources.nix. Every
              # input this repo emits has to be a github or a git ref, nothing else.
              badTypes = pkgs.lib.filterAttrs (_: t: t != "github" && t != "git") refTypes;
              checkedRefTypes =
                if badTypes == { } then
                  refTypes
                else
                  throw "generated flake inputs are not github/git refs: ${builtins.toJSON badTypes}";
            in
            pkgs.runCommand "resolve-sources"
              {
                nativeBuildInputs = [
                  pkgs.neovim-unwrapped
                  pkgs.jq
                ];
                # Forced while the derivation is instantiated, so
                # `nix eval .#checks.aarch64-darwin.resolve-sources.drvPath` is enough to catch an
                # unparseable or degraded URL on a system this machine cannot build for.
                refTypes = builtins.toJSON checkedRefTypes;
              }
              ''
                export HOME=$TMPDIR
                lua=${./lua/nvimx}
                fx=${./tests/fixtures/source-urls}
                lazy=${lazy-nvim}

                # (1) accept matrix: normalization, then the flake it produces.
                nvim -l $lua/resolve.lua $fx/raw-spec-ok.json ok.json --lazy $lazy 2> ok.log
                diff -u $fx/golden/ok.plugins.json ok.json
                nvim -l $lua/genflake.lua ok.json ok-flake.nix
                diff -u $fx/golden/ok.flake.nix ok-flake.nix
                # a matrix of valid URLs has nothing to say
                if [ -s ok.log ]; then
                  echo "a valid source URL must not warn, got:" >&2
                  cat ok.log >&2
                  exit 1
                fi
                # the two transports github.com can be reached over must not collapse into one:
                # https becomes a github: input, ssh stays a git one so the user's keys still apply
                jq -e '.plugins["short.nvim"].source.type == "github"' ok.json > /dev/null
                jq -e '.plugins["scpgh.nvim"].source
                       == { type: "git", url: "ssh://git@github.com/o/scpgh.nvim.git" }' ok.json > /dev/null
                # #28 validates, it does not reclassify. A URL that already locks today keeps the
                # exact source struct it has now, or everyone using that form silently loses their
                # resolvedRef to a spec-identity change. None of these three appears in any other
                # fixture, so nothing else in the tree would catch it (checks.source-parse carries
                # the same three as unit cases; this is the end-to-end half).
                jq -e '.plugins["httpgh.nvim"].source.type == "git"' ok.json > /dev/null
                jq -e '.plugins["upperhost.nvim"].source.type == "git"' ok.json > /dev/null
                jq -e '.plugins["trailing.nvim"].source.repo == "trailing.nvim/"' ok.json > /dev/null

                # (2) reject matrix. One run reports every bad URL at once (fail_plugin +
                # report_resolve_errors), so the whole matrix comes out of a single invocation.
                # Only the *shape* of the output is pinned here; the wording lives in
                # checks.source-parse, so a reworded message is a one-file change.
                rc=0
                nvim -l $lua/resolve.lua $fx/raw-spec-bad.json bad.json --lazy $lazy 2> bad.log || rc=$?
                cat bad.log >&2
                if [ "$rc" -eq 0 ]; then
                  echo "resolve.lua accepted a source URL it cannot turn into a flake input" >&2
                  exit 1
                fi
                # a failed resolve must not leave a partial plugins.json behind
                if [ -e bad.json ]; then
                  echo "resolve.lua wrote plugins.json for a failed run" >&2
                  exit 1
                fi
                # one line per bad plugin, so adding a case to raw-spec-bad.json without teaching
                # source.lua to reject it cannot pass by accident. Derived once into `total` (and
                # `with_url`, its two deliberate exceptions subtracted) and reused below, rather
                # than repeating `jq '.plugins | length'` and hardcoding what it comes out to --
                # adding a case to raw-spec-bad.json without this would otherwise fail two of the
                # three counts below with an opaque mismatch instead of one clear one.
                # (2026-08-24 追記、PR #60 レビュー: 当初案は `jq '.plugins | length'` の呼び出しを
                # 1 回だけにする一方で、その下の 2 行に `12` を直書きしていた -- fixture にケースを
                # 1 件足すと後者 2 本だけが謎の数不一致で落ちる状態だったので、変数に一本化した)
                total="$(jq '.plugins | length' $fx/raw-spec-bad.json)"
                grep '^\[nvimx\] resolve failed: plugin ' bad.log > failed.log
                [ "$(wc -l < failed.log)" -eq "$total" ]
                # report_resolve_errors sorts by plugin name, and that ordering is the only reason
                # this output is reproducible at all -- the main loop walks the spec with pairs()
                LC_ALL=C sort -c failed.log
                # every line names its plugin *and* the offending URL: the point of the whole issue.
                # nourl/emptyurl are the two deliberate exceptions (§3.3) -- there is no URL to
                # quote when the spec has none -- so they are excluded by name rather than by
                # weakening the rule for the rest.
                grep -v -e '"nourl\.nvim"' -e '"emptyurl\.nvim"' failed.log > withurl.log
                with_url=$((total - 2))
                [ "$(wc -l < withurl.log)" -eq "$with_url" ]
                [ "$(grep -c 'unsupported source URL "[^"]' withurl.log)" -eq "$with_url" ]
                touch $out
              '';
```

#### (c) 既存 check への追記

`checks.resolve-merge`(`flake.nix:1629-`)の `custom.nvim` は
`https://git.example.com/custom.nvim.git`(host + 1 セグメント)で、
§3.2 #9 の代表例そのものである。ここは**無変更**で通る想定だが、
`:1704` の生成 flake の grep(`git+https://git.example.com/custom.nvim.git?ref=trunk&rev=bbbb…`)が
そのまま「1 セグメント path を正規化で壊していない」ことの回帰ガードになるので、
その旨をコメント 1 行で書き足す。

### 5.7 ドキュメント

**実装のチェックリストから docs を落とさないための項**である(作業の全量は §4.5 の表)。

- `docs/architecture.md`: `:245` の URL マッピング表の書き換え、`:245` 直後の
  `**Source URL validation** (#28)` 段落の新設、`:478` 付近のモジュール一覧への `source.lua` の 1 行、
  `:483` の fixtures 一覧、`:492` の checks 一覧、`:504` の edge-case 表。
  `:493`(`genflake-golden (#29)`、§4.6)と `:526`(Phase 7)は**触らない**。
- `README.md`: `:177-180` の「non-GitHub git URL のプラグインで `--import-lazy-lock` した commit が
  `?rev=` だけになる」caveat の直後に、**scp 形式(`git@host:owner/repo.git`)のプラグインは本件の
  `ssh://` 正規化で `plugins.json` の `resolvedRef` が 1 度だけ捨てられ、import 由来の 40hex は
  再解決で戻らない**(§7)ことを書く。同じ caveat リストの同じ話題(import 済みユーザが次の lock で
  何を失うか)なので、ここだけは `docs/architecture.md` 単独では届かない。
  **2026-08-24 追記(PR #60 レビュー)**: 当初案はここで「`?ref=` / `?rev=` を持つソース URL の
  書き換えは README に書かない」としていた(lock が明示的なメッセージで止まるので自分で気付ける、
  scp の `resolvedRef` 破棄は黙って起きるのとは違う、という理由)。しかし実装した PR の本文が
  「Two shapes do change, both documented in `README.md` and `docs/architecture.md`」と書いてしまい、
  クエリ拒否の方は実際には `docs/architecture.md:252` にしか無くて本文が不正確だった。レビューは
  「対称性のために README にも 1 行足して本文を事実に合わせる」方を選んだので、この決定を上書きし、
  scp の直後にクエリ拒否の 1 段落も足す(2 行になる)。
- 検証は §8-9(docs と実装の突き合わせ)。

### 5.8 触らないもの

- `.github/workflows/*` — check の追加は `nix flake check` の中身が増えるだけで、
  `check.yml` は `nix flake check` と `nix fmt -- --ci` しか実行していない。ステップの追加は不要。
- `stylua.toml` / `.luacheckrc` — **どちらも編集しないので `nix fmt -- --clear-cache` は不要**(§8)。
  treefmt 側の設定はディレクトリを限定していない: luacheck は `flake.nix:146-149` の
  `settings.formatter.luacheck.includes = [ "*.lua" ]`、stylua と nixfmt は treefmt-nix の
  `programs.stylua` / `programs.nixfmt` の既定パターンで、いずれも `lua/` 以下に限定されていない。
  よって `tests/source-parse-test.lua` も `tests/fixtures/source-urls/golden/ok.flake.nix` も
  最初から整形・lint の対象に入る(§6.4 の golden 冪等性の話はこれが前提)。
- `lua/nvimx/update-summary.lua` — `:86` に `local source_fields = { "type", "owner", "repo", "url" }`
  という **spec 恒等性定義の 2 つ目のコピー**がある(`:83-84` のコメントが `resolve.lua` と同じ定義で
  あることを明言している)。本件は `source` のフィールド構成を変えないので**無変更**。§3.4 のとおり、
  将来 `source` にフィールドを足すときは 2 箇所を揃えること。
- `nix/lib/lock-app.nix` — `luaDir = ../../lua/nvimx`(`:5`)はディレクトリごと store に入るので、
  `source.lua` は自動的に同梱される。`resolve.lua` の `dofile` は `arg[0]` からの相対解決なので、
  `${luaDir}/resolve.lua` 起動でも `${./lua/nvimx}/resolve.lua` 起動でも隣が見える。
- `nix/lib/sources.nix` / `make-env.nix` / `plugin-drv.nix` — `source` を読まない
  (`source.type` の消費者は全ファイル走査で `lua/nvimx/genflake.lua:28` の 1 箇所のみ。
  `sources.nix` が読むのは `flake.lock` のノード)。
- `templates/`、`docs/plans/` の既存ファイル(`README.md` は §5.7 の 1 行だけ足す)。

## 6. テスト

### 6.1 何を、どの層で守るか

| 層 | 手段 | 守るもの |
|---|---|---|
| unit | `checks.source-parse` | 受理/拒否の全分岐と**エラー文言の一字一句**(文言の唯一の出典)。非文字列入力(fixture では作れない)。§3.4 の不変条件 3 ケース |
| 統合(受理) | `checks.resolve-sources` の `golden/ok.plugins.json` | 正規化結果(`source.type` / `owner` / `repo` / `url`) |
| 統合(受理) | 同 `golden/ok.flake.nix` | **最終成果物**。`?ref=` / `?rev=` の合成まで含む |
| 評価時 | `builtins.parseFlakeRef` を golden の全 input に適用し、`type` が `github`/`git` であることを assert | 「正規化後 URL が flake input reference として妥当で、`path:` / `indirect` に降格していない」を nix 自身に確認させる |
| 統合(拒否) | 同 check の exit code + 行数 + 名前昇順 + `plugin "<name>"` と URL の存在 + `bad.json` 不在 | 失敗が lock の前に、全件まとめて、名前と URL 付きで起きる。**文言は見ない**(unit の担当) |
| 回帰 | 既存 check 全部 + §8-5 | 現行の有効な URL の挙動が 1 バイトも動かない(§3.4) |

**文言を 2 層で固定しない**のが本件の方針である(§5.4)。`golden/bad.log` を置いて `diff -u` すると
19 件の文言が unit と golden の 2 箇所に焼き付き、1 語直すたびに 2 ファイルを更新することになる。
issue が求めているのは "Golden tests cover the matrix" と "**a** failure case" であって、
拒否理由 19 件 × 2 層の全文固定ではない。既存の同型 check(`flake.nix:1703-1704` の 2 本の `grep -q` で
済ませている `resolve-merge`、`:1805`)も部分一致に留めている。

### 6.2 失敗ケースをどう assert するか(明示)

2 系統ある。**どちらも `pcall` を使わない**。

1. **lua 側(`tests/source-parse-test.lua`)**: `source.parse` は失敗を戻り値
   `nil, err` で返す(§3.1-3 / §5.5)。したがって `pcall` は不要で、
   `assert(src == nil, ...)` と `eq(err, expected, ...)` の 2 行で足りる。
   `pcall` が要るのは「raise する API」を試すときだけであり、ここでそう設計しない理由は
   「重大度と報告のタイミングを決めるのは `resolve.lua` の仕事」だから(`version.lua:34-40` と同じ)。
   万一 `source.parse` が将来 raise するようになったら、この `assert` は
   `nvim -l` を非ゼロで落とすので check は赤くなる — つまり回帰は検知される。
2. **プロセス側(`checks.resolve-sources`)**: `resolve.lua` は `os.exit(1)` で落ちるので、
   lua の `pcall` では捕まえられない。`resolve-merge` の `prev-broken` / `prev-future` と同じく
   `rc=0; nvim -l … || rc=$?` で終了コードを拾い、`[ "$rc" -eq 0 ]` なら
   「accepted a source URL it cannot turn into a flake input」で明示的に落とす。
   出力は `2> bad.log` に落とし、**行数 / 並び順 / 名前と URL の存在**だけを見る。
   `resolve-merge` の `grep -q` と同程度の粒度で、文言そのものは 1 で固定済みである。

### 6.3 既存 `checks` への影響

| check | 影響 |
|---|---|
| `resolve-merge`(`:1629`) | `custom.nvim` = `https://git.example.com/custom.nvim.git` が §3.2 #9 で受理される。`:1704` の生成 flake grep が回帰ガードになる。**期待差分ゼロ** |
| `resolve-semver`(`:1856`) | `file://$sb/tagged` 等を jq で注入する。§3.2 #17 で受理。**期待差分ゼロ**(受理しなければ全滅するので、実質この check が `file://` 受理の主たる根拠) |
| `resolve-update`(`:2086`) / `update-summary`(`:2246`) | `file:///nvimx-nonexistent/...` を使う。同上 |
| `resolve-import-lazy-lock`(`:2401`) | `:2463-2469` が `git+file:///nvimx-nonexistent/...?ref=…&rev=…` を grep する。正規化は `file://` を素通しするので**期待差分ゼロ** |
| `resolve-build-warnings`(`:1462`) / `extractor-*` | `https://github.com/...` のみ。**期待差分ゼロ** |
| `hm-module-*` / `build-*` / `plugins-*` / `treesitter-grammars` / `dev-plugins` | `plugins.json` を lockDir として読むだけで `source` を読まない。無影響 |

### 6.4 手元での事前確認(実装時)

fixture の golden は手書きせず、必ず実物から生成する:

```bash
lua=lua/nvimx; fx=tests/fixtures/source-urls
nvim -l $lua/resolve.lua $fx/raw-spec-ok.json $fx/golden/ok.plugins.json
nvim -l $lua/genflake.lua $fx/golden/ok.plugins.json $fx/golden/ok.flake.nix
# 拒否側は golden を持たないので、目視確認のみ(文言の固定は tests/source-parse-test.lua)
nvim -l $lua/resolve.lua $fx/raw-spec-bad.json /tmp/should-not-exist.json || true
```

`golden/ok.flake.nix` は `nix fmt` の対象(nixfmt は `*.nix` を除外なしで拾う。§5.8)になるが、
**genflake の出力はすでに nixfmt 冪等である**ことを実測で確認済み
(生成した `flake.nix` に `nixfmt` をかけて `diff` が空)。よって golden をそのままコミットしてよい。

## 7. リスク / 未決事項

- **scp 形式 → `ssh://` の正規化は既存の `resolvedRef` を捨てる**。`source.url` の値が変わるので
  `same_identity`(`resolve.lua:293-`)が false になり、その行の `resolvedRef` は null に戻る。
  §1.3 は「scp のプラグインは `flake.lock` 側が元々 `path:` ノードで壊れている」と書いたが、
  **`plugins.json` の `resolvedRef` のほうは正しい値を持ち得る**: semver 解決は `resolve.lua:778` の
  生の scp URL を `git ls-remote`(`:883`)に渡し、git は scp 形式を素で受け付けるので
  `refs/tags/vX.Y.Z` が正しく書かれる。`--import-lazy-lock` は 40hex を直接そこに書く。
  semver 由来は再解決で同値に戻ることが多いが、**import 由来の 40hex は戻らない**(再解決の対象では
  ないため、次の lock で単に消える)。この移行は PR 本文と `docs/architecture.md`(§4.5)の両方に書く。
- **scp 形式 → `ssh://` の正規化はホーム相対性を落とす**。git の scp 形式 `git@host:path` の `path` は
  ssh ユーザのホーム相対で、`ssh://host/path` は絶対パスである。GitHub / GitLab / Gitea / Forgejo /
  sourcehut はいずれも両者を同一に扱うので実害は無いが、**リポジトリをユーザのホーム直下に置いた
  自前サーバ**(`git@myhost:repos/x.git` = `~/repos/x.git`)では指す先が変わる。
  回避策は `url = "ssh://git@myhost/~/repos/x.git"` と明示することで、この形は
  `builtins.parseFlakeRef` が受理することを実測済み。**§4.5 で `docs/architecture.md` に明記する**。
- **大文字スキーム / 大文字ホストは素通しになる**。`Https://h/o/r` も `https://GitHub.com/o/r` も
  git type の `url` は入力そのままなので `git+Https://...` / `git+https://GitHub.com/...` になる。
  `builtins.parseFlakeRef` はどちらも受理する(実測)が、実 fetch が通るかは nix / libgit2 側の
  挙動次第。小文字へ書き換えると §3.4 の不変条件を破るので、**書き換えない**。実害の報告も無い。
- **拒否する形の一部は `parseFlakeRef` を通る**。実測で `git+ftp://h/o/r.git`・
  `git+https:///o/r.git`・`git+https://git.example.com` は parse を通るので、理屈のうえでは
  「今日 lock が通っていたものを本件が落とす」可能性がある。特に `ftp://` は git 自身が curl 経由で
  サポートしているので、**fetch できないとは言い切れない**(`git+https:///o/r.git` と
  `git+https://git.example.com` は host か path を欠く)。いずれも fixture にも docs にも前例が
  無いので拒否に倒す。判断は §3.4 に書いた。報告があれば F/H/I の条件を緩める余地はある。
- **ソース URL の `?ref=` / `?rev=` は書き換えが要る**(§3.4 の D)。`branch`/`tag`/`commit` を
  併用していない git type の `url = "https://gitlab.com/o/r.git?ref=main"` は、`genflake.lua` が
  `?` を足さないので**今日そのまま有効な lock を生んでいる**(実測は §3.4)。本件はこれを fatal に
  するので、該当ユーザは `?ref=<x>` を `branch = "<x>"` / `tag = "<x>"` に、`?rev=<sha>` を
  `commit = "<sha>"` に移す必要がある。scp の `resolvedRef` 破棄より重い(scp は次の lock が
  黙って進むが、D は設定を直すまで lock が止まる)ので、**scp と同格で PR 本文と
  `docs/architecture.md`(§4.5)の両方に書く**。
- **`branch` / `tag` の値は検証しない**(§3.5)。`branch = "a&b"` は `?ref=a&b` になり、
  nix が `b` を未知パラメータとして拒否する。git の refname は `&` を許すので理論上は起こりうる。
  「ref の検証」は別 issue に切るのが筋で、本件では扱わない。
- **`git://` を受理するか**。平文・無認証で GitHub は既に無効化しているが、git 自身は今もサポートし
  `builtins.parseFlakeRef` も受理する。動く transport を nvimx の判断で塞ぐのは行き過ぎと考え、
  受理する。警告を出すべきかは未決(出すなら `warnings` に入るので `plugins.json` が汚れる)。
- **`file://` を受理することでロックが機械依存になる**。`git+file:///home/me/x` を含む `plugins.json`
  は別マシンで再現しない。ただし `checks.resolve-semver` がこの形に依存しており(§1.4)、
  受理しない選択肢は無い。警告を出すかどうかは未決。出す場合は `warnings` 配列に入るため、
  `warnings == []` を assert している既存 check への影響を確認してから決める。
- **`golden/ok.flake.nix` は `nix fmt` の対象である**。いまは genflake の出力が nixfmt 冪等なので
  問題無いが、将来 genflake の整形が nixfmt と食い違うと、`nix fmt` が golden を書き換えて
  `checks.resolve-sources` の `diff` が落ちる。これは**乖離を可視化する機能**として受け入れる
  (lock-app は `nix/lib/lock-app.nix:236` で生成直後に `nixfmt` をかけているので、
  ユーザの lockDir 側では既に nixfmt 済みの内容が正となる)。
- **#47 との順序**。どちらが先でも本件のマトリクスは変わらない(§4.4)。ただし #47 が
  `resolve.lua:653` の分岐や `extract.lua:114` を書き換えるので、後に入るほうが
  §3.6 の記述と `source-urls` fixture の前提を読み直すこと。
- **#29 とは重ならない**(§4.6)。`resolve-sources` は URL 形式のマトリクス専用で、#29 の
  build 分類 / dependencies / `dev` / `version` のマトリクスは 1 つも代替しない。#29 は open のまま残し、
  `docs/architecture.md:493` の `genflake-golden (#29)` 行も消さない。

### 本件から意図的に外した follow-up(別 issue に切る)

いずれも issue #28 の "Done when" が要求していない。スコープを膨らませるより、切り出す。

- **github type への寄せ方を広げる**。`http://github.com/o/r`、大文字ホスト、末尾 `/` を github type に
  正規化すれば、input が軽い tarball 経路になり `repo = "r/"` のような不格好な値も消える。だが
  `source` の形が `{type,url}` → `{type,owner,repo}` に変わる / `repo` の値が変わるため、
  **今日動いているユーザの `resolvedRef` が捨てられて再 fetch が起きる**(§3.4)。移行注意を伴う
  破壊的変更であり、「検証を足す」本 issue に混ぜてはならない。
- **github.com の ssh/scp を github type に寄せる**。却下理由と代償は §3.2 のとおり
  (private repo を ssh 鍵で引いているユーザの fetch を壊す)。ここも独立して議論すべき論点。
- **`report_resolve_errors()` の前倒し**(§3.8)。不正 URL のプラグインに `git ls-remote` を
  費やさなくなるが、`plugin_warnings` の emit ループ(`resolve.lua:1009-1011`)を飛ばす副作用がある。
  「前倒し + 失われる警告を守る check」で 1 つの issue にする。実装は `:793` 付近に 1 行足すだけ。

## 8. 検証手順(実装完了時に必ず全部通す)

```bash
# 0. 作業ツリーのルートで
cd /home/myuron/.cache/nvimx-worktrees/issue-28

# 1. CI と同一の 2 本(CLAUDE.md の Commands より)
nix flake check
nix fmt -- --ci

# 2. 新規 check 単体(失敗時の切り分け用)
nix build .#checks.x86_64-linux.source-parse
nix build .#checks.x86_64-linux.resolve-sources

# 3. 影響を受けうる既存 check 単体
nix build .#checks.x86_64-linux.resolve-merge
nix build .#checks.x86_64-linux.resolve-semver
nix build .#checks.x86_64-linux.resolve-update
nix build .#checks.x86_64-linux.resolve-import-lazy-lock
nix build .#checks.x86_64-linux.update-summary

# 4. darwin 評価(linux の nix flake check は darwin を omit するため必須)。
#    resolve-sources は parseFlakeRef と type チェックを derivation の instantiation 時に強制するので、
#    ここで URL の妥当性まで darwin 側でも確認される。
nix eval .#checks.aarch64-darwin.source-parse.drvPath
nix eval .#checks.aarch64-darwin.resolve-sources.drvPath
nix eval .#checks.aarch64-darwin.resolve-merge.drvPath
nix eval .#checks.aarch64-darwin.resolve-semver.drvPath

# 5. 後方互換(ゴール 4-a): 全 fixture の lockDir を再生成して差分が空であること。
#    生成物は一時ディレクトリに出し、コミット済みの golden とは diff で突き合わせる。
#    既存 golden を直接上書きする書き方は使わない: 差分が出たときに作業ツリーが汚れるうえ、
#    「全 fixture の resolvedRef がたまたま全部 null」という暗黙の前提に乗ることになる。
seed=$(nix eval --impure --raw --expr '(builtins.getFlake (toString ./.)).inputs.lazy-nvim.outPath')
for fx in basic-config build-plugins registry-plugins treesitter-config; do
  sb=$(mktemp -d)
  mkdir -p "$sb"/config "$sb"/data/nvim/lazy "$sb"/state "$sb"/cache "$sb"/out
  ln -sfn "$PWD/tests/fixtures/$fx" "$sb/config/nvim"
  ln -sfn "$seed" "$sb/data/nvim/lazy/lazy.nvim"
  env HOME="$sb" XDG_CONFIG_HOME="$sb/config" XDG_DATA_HOME="$sb/data" \
      XDG_STATE_HOME="$sb/state" XDG_CACHE_HOME="$sb/cache" \
      NVIMX_LAZY_SEED="$seed" NVIMX_OUT="$sb/raw-spec.json" \
      nvim --headless --cmd "luafile lua/nvimx/extract.lua"
  # --prev で既存の lock を入力として与える。省くと resolvedRef の引き継ぎ経路(§3.4 の
  # spec 恒等性)がそもそも走らず、「差分ゼロ」が何も証明しなくなる。
  nvim -l lua/nvimx/resolve.lua "$sb/raw-spec.json" "$sb/out/plugins.json" \
    --prev "tests/fixtures/$fx/nvimx-lock/plugins.json"
  nvim -l lua/nvimx/genflake.lua "$sb/out/plugins.json" "$sb/out/flake.nix"
  diff -u "tests/fixtures/$fx/nvimx-lock/plugins.json" "$sb/out/plugins.json"
  diff -u "tests/fixtures/$fx/nvimx-lock/flake.nix"    "$sb/out/flake.nix"
  rm -rf "$sb"
done
git status --porcelain -- tests/fixtures   # source-urls の新規追加分だけであること

# 6. 後方互換(ゴール 4-b): 5 が回す既存 4 fixture に 1 件も存在しない 3 形の分類が据え置かれていること。
#    5 の diff はこれを検出できない(既存 fixture に無いので差分が出ない)ので、必ず別途通す。
#    明示ケースは tests/source-parse-test.lua と resolve-sources の jq -e 3 本(§5.5 / §5.6(b))。
nix build .#checks.x86_64-linux.source-parse
nix build .#checks.x86_64-linux.resolve-sources

# 7. 生成した golden の全 input URL が flake ref として妥当で、github/git 以外に降格していないこと
#    (check が評価時にやるのと同じ判定を手元でも)
nix eval --impure --raw --expr \
  "builtins.toJSON (builtins.mapAttrs (_: i: (builtins.parseFlakeRef i.url).type)
     (import $PWD/tests/fixtures/source-urls/golden/ok.flake.nix).inputs)"
  # -> 値はすべて "github" か "git"。"indirect" / "path" が 1 つでもあれば §1.3 の降格が再発している

# 8. スモークテスト
nix build .#demo && ./result/bin/nvim   # :Lazy が全プラグインを local 表示、git 操作ゼロ

# 9. ドキュメント(§4.5 / §5.7)。実装と docs の乖離(`git+ssh://` を約束しているのに実装が無い)は
#    本件の動機の 1 つなので、書いたことが実物と合っているか目視で突き合わせる
grep -n 'source\.lua' docs/architecture.md            # モジュール一覧(:475-481)に 1 行あること
grep -n 'source-urls' docs/architecture.md            # fixtures 一覧(:483)
grep -n 'source-parse\|resolve-sources' docs/architecture.md   # checks 一覧(:492)
grep -n 'Source URL validation' docs/architecture.md  # :245 直後の新設段落
grep -n 'genflake-golden' docs/architecture.md        # :493 が残っていること(§4.6)
grep -n 'scp\|resolvedRef' README.md                  # :177-180 の caveat の直後に 1 行あること
```

**`nix fmt -- --clear-cache` は不要**。本件は `stylua.toml` も `.luacheckrc` も編集しないため
(treefmt のキャッシュ無効化が必要になるのはその 2 ファイルを触ったときだけ。§5.8)。

**`nix run .#skills-install` は不要**(`.claude/skills/` に触らない)。

### 手動確認(ネットワークが要るので check にできない部分)

- 実在する non-GitHub リモート(例: `url = "git@gitlab.com:<自分>/<repo>.git"`)を 1 つ足した config で
  `nix run .#lock -- --config ./nvim --out ./nvim/nvimx-lock` を実行し、
  生成された `flake.nix` の input が `git+ssh://git@gitlab.com/<自分>/<repo>.git` になり、
  `nix flake lock` が `type: "git"` のノード(`rev` と `narHash` を持つ)を書くこと。
  **`path:` ノードにならないこと**が本件の眼目である。
- 同じ config で 2 回目の lock を実行し、`plugins.json` / `flake.lock` に差分が出ないこと(冪等性)。
- わざと `url = "https://github.com/<o>/<r>/tree/main"` を書いて lock し、
  `[nvimx] resolve failed: plugin "<r>": unsupported source URL "https://github.com/<o>/<r>/tree/main": …`
  で非ゼロ終了し、`nvimx-lock` の `$out/plugins.json` が**前回の内容のまま**であること。
