# lockDir/flake.lock -> store path of the lazy.nvim it pins (the `lazy-nvim` root input), or ""
# when it pins none. nvimx-lock evaluates this before extracting (#32): make-env.nix loads exactly
# this input at runtime, so extracting against anything else can derive different names. `sources`
# is passed in rather than imported relatively: lock-app.nix copies this file to the store alone.
{ lockDir, sources }:
let
  lock = builtins.fromJSON (builtins.readFile (lockDir + "/flake.lock"));
  rootInputs = lock.nodes.${lock.root}.inputs or { };
in
if rootInputs ? "lazy-nvim" then (import sources { inherit lockDir; } "lazy-nvim").outPath else ""
