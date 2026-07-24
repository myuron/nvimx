# lockDir/flake.lock を単なる pin DB として読み、
# inputName → builtins.fetchTree による store path の関数を返す。
# flake として評価しないため、eval は完全 pure (narHash 固定済み)。
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
