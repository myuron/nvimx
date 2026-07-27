# Reads lockDir/flake.lock as nothing more than a pin DB and returns a function
# from inputName to a store path via builtins.fetchTree.
# It is never evaluated as a flake, so evaluation is fully pure (narHash is already fixed).
{ lockDir }:
let
  lock = builtins.fromJSON (builtins.readFile (lockDir + "/flake.lock"));
  rootInputs = lock.nodes.${lock.root}.inputs;
in
inputName:
let
  nodeName = rootInputs.${inputName} or (throw "nvimx: input '${inputName}' not found in flake.lock");
  locked = lock.nodes.${nodeName}.locked;
in
builtins.fetchTree {
  inherit (locked) type narHash;
  ${if locked ? owner then "owner" else null} = locked.owner or null;
  ${if locked ? repo then "repo" else null} = locked.repo or null;
  ${if locked ? url then "url" else null} = locked.url or null;
  ${if locked ? rev then "rev" else null} = locked.rev or null;
  ${if locked ? ref then "ref" else null} = locked.ref or null;
}
