# treesitter.grammars: the parsers are the one thing the generic build cannot produce,
# and the promise is a runtime one -- neovim must find and load them with no install
# step -- so this really starts neovim and parses with them.
{
  pkgs,
  nvimxLib,
  ...
}:
let
  inherit (pkgs) lib;
  mkEnv =
    args:
    nvimxLib.makeEnv (
      {
        package = pkgs.neovim-unwrapped;
        lockDir = ../fixtures/treesitter-config/nvimx-lock;
      }
      // args
    );
  merged = mkEnv {
    treesitter.grammars = [
      "lua"
      "nix"
    ];
  };
  # null is the opt-out: nvim-treesitter stays exactly as it was resolved
  plain = mkEnv { treesitter.grammars = null; };
  # The merge sits on top of resolution, so an override still decides what the
  # plugin itself is -- and grammars land on that.
  overridden = mkEnv {
    treesitter.grammars = [ "lua" ];
    plugins.overrides."nvim-treesitter" =
      _:
      pkgs.runCommand "nvimx-custom-treesitter" { } ''
        mkdir -p $out/lua
        touch $out/nvimx-custom
      '';
  };
  # A grammar that needs another one must pull it in, the way nvim-treesitter's own
  # installer expands `requires`. Checked against stubs so it does not depend on
  # which grammars happen to declare a dependency today.
  mkStub =
    name: requires:
    pkgs.runCommand "nvimx-stub-grammar-${name}" { passthru = { inherit requires; }; } ''
      mkdir -p $out/parser
      touch $out/parser/${name}.so
    '';
  stubGrammars = {
    alpha = mkStub "alpha" [ "beta" ];
    beta = mkStub "beta" [ ];
  };
  stubbed = nvimxLib.mkTreesitter {
    plugin = pkgs.runCommand "nvimx-stub-treesitter" { } "mkdir -p $out/lua";
    grammars = [ "alpha" ];
    grammarPlugins = stubGrammars;
  };
  stubbedAll = nvimxLib.mkTreesitter {
    plugin = pkgs.runCommand "nvimx-stub-treesitter" { } "mkdir -p $out/lua";
    grammars = "all";
    grammarPlugins = stubGrammars;
  };
  evaluates =
    grammars:
    (builtins.tryEval (
      builtins.seq (mkEnv { treesitter.grammars = grammars; }).pluginDrvs."nvim-treesitter".drvPath null
    )).success;
  # Selecting grammars without nvim-treesitter in the lock is a no-op the module warns about
  withoutPlugin =
    (nvimxLib.makeEnv {
      package = pkgs.neovim-unwrapped;
      lockDir = ../fixtures/basic-config/nvimx-lock;
      treesitter.grammars = [ "lua" ];
    }).treesitterWithoutPlugin;
  failures =
    lib.optional (
      !(evaluates "all")
    ) ''treesitter.grammars = "all" should evaluate against the real nixpkgs grammar set''
    ++ lib.optional (evaluates [
      "no-such-language"
    ]) "an unknown grammar name should throw, not build without the parser"
    ++ lib.optional (!withoutPlugin) "grammars without nvim-treesitter in the lock should be reported"
    ++ lib.optional ((mkEnv { }).treesitterWithoutPlugin
    ) "grammars left at null should never be reported as unused";
in
pkgs.runCommand "treesitter-grammars"
  {
    nativeBuildInputs = [ pkgs.neovim-unwrapped ];
  }
  (
    if failures == [ ] then
      ''
        ts=${merged.farm}/nvim-treesitter

        # the plugin tree survives the merge whole
        test -f "$ts/lua/nvim-treesitter/install.lua"
        test -f "$ts/doc/tags"

        # ... and the parsers land where neovim looks for them
        test -e "$ts/parser/lua.so"
        test -e "$ts/parser/nix.so"

        # queries come from the locked plugin. On the `main` layout they sit off the
        # runtimepath under runtime/, linked in per selected language
        test -f "$ts/queries/lua/highlights.scm"

        # null leaves nvim-treesitter parserless, exactly as upstream ships it
        test ! -e ${plain.farm}/nvim-treesitter/parser

        # an override decides the plugin; the grammars still merge onto it
        test -f ${overridden.farm}/nvim-treesitter/nvimx-custom
        test -e ${overridden.farm}/nvim-treesitter/parser/lua.so

        # a grammar's own dependencies come along, both when named and under "all"
        test -e ${stubbed}/parser/alpha.so
        test -e ${stubbed}/parser/beta.so
        test -e ${stubbedAll}/parser/alpha.so
        test -e ${stubbedAll}/parser/beta.so

        # the point of all of the above: a real neovim loads the parsers off the
        # runtimepath and parses with them, with no :TSInstall anywhere
        export HOME=$TMPDIR
        cat > parse.lua <<'EOF'
        local ts = arg[1]
        vim.opt.rtp:prepend(ts)
        -- neovim bundles a parser and queries for lua (but not for nix), so every
        -- lookup below is pinned to the merged plugin rather than merely satisfied
        local function found(pat)
          local hit = vim.api.nvim_get_runtime_file(pat, false)[1]
          if not hit or not vim.startswith(hit, ts) then
            error(pat .. ": not found under " .. ts .. " (got " .. tostring(hit) .. ")")
          end
          return hit
        end
        for _, lang in ipairs({ "lua", "nix" }) do
          -- loads the shared object: fails outright on an ABI mismatch
          vim.treesitter.language.add(lang, { path = found("parser/" .. lang .. ".so") })
          local tree = vim.treesitter.get_string_parser("", lang):parse()[1]
          assert(tree:root(), lang .. ": parsed no tree")
          found("queries/" .. lang .. "/highlights.scm")
          assert(vim.treesitter.query.get(lang, "highlights"), lang .. ": no highlights query")
        end
        EOF
        nvim --clean --headless -l parse.lua "$ts"
        touch $out
      ''
    else
      ''
        ${lib.concatMapStringsSep "\n" (f: "echo ${lib.escapeShellArg f} >&2") failures}
        exit 1
      ''
  )
