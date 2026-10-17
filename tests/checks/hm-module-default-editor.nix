# defaultEditor (#67) deploys through home.sessionVariables, which no other check reads back:
# mkHmCheck only builds the activationPackage, and defaultEditor is not a makeEnv argument, so
# neither make-env.nix nor wrapper.nix checks can see it. This reads
# .config.home.sessionVariables at evaluation level, like checks.dev-plugins' moduleDevDirs.
# Degraded lockDir because a lock-independent option has no business reading a real lock.
{
  pkgs,
  self,
  home-manager,
  ...
}:
let
  inherit (pkgs) lib;
  # args.nvimx goes into programs.nvimx; args.modules are extra home-manager modules (only
  # `competing` needs them). Returns the whole evaluation so `off` can read .options too.
  evalHm =
    args:
    home-manager.lib.homeManagerConfiguration {
      inherit pkgs;
      modules = [
        self.homeModules.nvimx
        {
          # Same values as mkHmCheck. Only .config and .options are read; nothing is built.
          home.username = "nvimx-test";
          home.homeDirectory = "/home/nvimx-test";
          home.stateVersion = "25.05";
          programs.nvimx = {
            enable = true;
            configDir = ../fixtures/basic-config;
            lockDir = ../fixtures/basic-config/no-such-lock;
          }
          // (args.nvimx or { });
        }
      ]
      ++ (args.modules or [ ]);
    };
  sessionVariables = args: (evalHm args).config.home.sessionVariables;
  # `on` / `off` are a pair: one evaluation cannot tell "sets EDITOR when asked" from "sets
  # EDITOR always". onArgs is shared with `competing` so a typo breaks `on` too.
  onArgs = {
    nvimx.defaultEditor = true;
  };
  on = sessionVariables onArgs;
  offEval = evalHm { };
  off = offEval.config.home.sessionVariables;
  # Named so the control assertion can inspect the module itself, not only an evaluation.
  competingModule = value: { home.sessionVariables.EDITOR = value; };
  # Somebody else also defines EDITOR -- the state of a user replacing a hand-written
  # home.sessionVariables.EDITOR line with this option.
  competing =
    value:
    builtins.tryEval (sessionVariables (onArgs // { modules = [ (competingModule value) ]; })).EDITOR;
  # Unequal definitions must throw. The only thing here that sees lib.mkDefault / lib.mkForce,
  # since nothing competes in `on` or `off`. tryEval as in checks.plugins-escape-hatch.
  contested = competing "vim";
  # Each assertion catches a regression the others miss; only `off ? EDITOR` is subsumed (by
  # the removeAttrs one) and is kept for its message.
  failures =
    lib.optional (
      (on.EDITOR or null) != "nvim"
    ) "defaultEditor = true must set home.sessionVariables.EDITOR to nvim"
    # Not `off == { }`: home-manager adds its own entries (LOCALE_ARCHIVE_2_27 on linux,
    # TERMINFO_DIRS on darwin).
    ++ lib.optional (off ? EDITOR) "the default must leave home.sessionVariables.EDITOR alone"
    # The declared default. Behavioural assertions only prove it while `off`'s argument stays
    # empty; this keeps the check honest if someone passes `defaultEditor = false` there.
    ++ lib.optional (
      offEval.options.programs.nvimx.defaultEditor.default != false
    ) "defaultEditor must be declared with default = false"
    # EDITOR only, unlike home-manager's programs.neovim.defaultEditor. Not redundant with the
    # next one: an unconditional VISUAL lands in `off` too and cancels out of the difference.
    ++ lib.optional (
      on ? VISUAL
    ) "defaultEditor must set EDITOR only -- VISUAL is deliberately left alone"
    # The same, for any variable nobody thought to name.
    ++ lib.optional (
      builtins.removeAttrs on [ "EDITOR" ] != off
    ) "defaultEditor must add EDITOR and change nothing else in home.sessionVariables"
    # A conflict has to stay a conflict: mkDefault would make the option do nothing, mkForce
    # would swallow the user's line. The option's description says to delete the other one.
    ++ lib.optional contested.success "a competing home.sessionVariables.EDITOR must stay a conflict -- neither mkDefault nor mkForce"
    # Control: tryEval reports any exception as failure, so a competing module that throws for
    # an unrelated reason would make the assertion above pass vacuously. Compares the whole
    # module, so an extra throwing attribute is caught too.
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
)
