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
{
  pkgs,
  self,
  home-manager,
  ...
}:
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
            configDir = ../fixtures/basic-config;
            lockDir = ../fixtures/basic-config/no-such-lock;
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
  # difference; the fifth the only one that notices some other variable being added
  # conditionally; the sixth the only one that notices mkDefault or mkForce; and the
  # seventh the only one that notices this check quietly ceasing to test anything.
  # Only `off ? EDITOR` is a duplicate, and it is kept for the sake of its message.
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
)
