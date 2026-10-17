# Reads lockDir/flake.lock as nothing more than a pin DB and returns a function
# from inputName to a store path via builtins.fetchTree (or, for a relative `path:` node,
# builtins.path).
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
if locked.type == "path" && !(locked ? narHash) && builtins.substring 0 1 locked.path != "/" then
  # A relative path: input, which nix locks as `parent = []` with no narHash: resolve it the way
  # nix does, against the lock flake's own directory. builtins.path copies just that directory,
  # so the plugin's src does not change with every unrelated file in lockDir's source tree.
  builtins.path {
    path = lockDir + "/${locked.path}";
    name = "source";
  }
else
  builtins.fetchTree {
    inherit (locked) type narHash;
    ${if locked ? owner then "owner" else null} = locked.owner or null;
    ${if locked ? repo then "repo" else null} = locked.repo or null;
    ${if locked ? url then "url" else null} = locked.url or null;
    ${if locked ? rev then "rev" else null} = locked.rev or null;
    ${if locked ? ref then "ref" else null} = locked.ref or null;
  }
