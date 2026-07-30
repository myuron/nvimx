# Saghen/blink.cmp: the completion plugin whose fuzzy matcher is a Rust cdylib.
#
# Neither way upstream offers to obtain that library works under nvimx:
#
#   - `build = "cargo build --release"` is rejected at evaluation time, because `cargo` resolves
#     its dependencies over the network (nix/lib/build-network.nix). Without this entry the
#     user's whole configuration stops evaluating.
#   - `version = "1.*"` with no build at all downloads a prebuilt binary *at runtime*, into the
#     plugin directory -- which here is a read-only store path. The download fails and blink
#     silently falls back to its pure-lua matcher, which is the thing the rust one exists to
#     replace.
#
# So the library is built here, from the locked src, with nothing configured on the user's side.
#
# ## Why a separate derivation for the library
#
# Not tidiness: it is what keeps blink from trying to download at every startup.
# lua/blink/cmp/fuzzy/download/init.lua treats "no target/release/version file, and the shared
# library loads" as "the user placed the .so there by hand" and skips its version check
# entirely. Any other combination makes it compare that file against the git sha of the plugin
# directory -- which a store path cannot supply, having no .git -- and notify the user that
# their locally built library is out of date. `build.rs` writes exactly that version file, so
# the crate is built on its own and only the resulting library is linked into the tree that
# reaches the farm. nixpkgs' own package is shaped this way for the same reason.
#
# ## Why cargoLock rather than cargoHash
#
# A registry entry has to hold for whatever rev the user pinned, and a `cargoHash` is a promise
# about one specific rev's dependency set. Reading the plugin's own Cargo.lock takes the hashes
# from the crates.io checksums recorded in it, so there is nothing here to keep in sync with a
# rev nvimx does not control. (nixpkgs can pin a cargoHash because it pins the rev too.)
#
# ## Oddities worth not rediscovering
#
#   - `git` is a build input. build.rs runs `git rev-parse HEAD` and unwraps the result: it
#     copes with the missing .git (non-zero exit, empty stdout) but panics if git is absent.
#   - RUSTC_BOOTSTRAP is needed while the crate uses nightly features, and darwin needs the
#     undefined symbols left to be resolved by neovim's LuaJIT at load time. Both mirror
#     nixpkgs' blink-cmp.
{
  pkgs,
  name,
  src,
  mkPluginDrv,
  ...
}:
let
  inherit (pkgs) lib stdenv;

  ext = stdenv.hostPlatform.extensions.sharedLibrary;
  libName = "libblink_cmp_fuzzy${ext}";

  cargoLockPath = "${src}/Cargo.lock";
  # Parsed rather than grepped: this file has to survive whatever rev the user pinned, and
  # nix/build-registry/default.nix warns off recipes that read upstream text by shape.
  # importCargoLock parses the same file anyway, so this costs nothing new.
  cargoLockPackages = (builtins.fromTOML (builtins.readFile cargoLockPath)).package or [ ];

  # Both hatches, quoted the way a user would write them. A recipe that cannot cope with the
  # rev in front of it should say what to do about it rather than fail as an nvimx bug.
  hatches = ''
    Take nixpkgs' package instead:

      programs.nvimx.plugins.nixpkgsFallback = [ "${name}" ];

    or build it yourself from the locked source:

      programs.nvimx.plugins.overrides."${name}" =
        { pkgs, src, ... }: pkgs.rustPlatform.buildRustPackage { inherit src; /* ... */ };
  '';

  fuzzy = pkgs.rustPlatform.buildRustPackage {
    pname = "nvimx-blink-cmp-fuzzy";
    # Which rev this is, is the lock's business; this only names the derivation.
    version = "0";
    inherit src;

    cargoLock.lockFile = cargoLockPath;

    nativeBuildInputs = [ pkgs.gitMinimal ];

    # The user's lock picks the rev, so a test upstream happened to break on some rev must not
    # make the plugin unbuildable. What nvimx ships is the library, and checks.build-registry
    # proves neovim can load it.
    doCheck = false;

    env = {
      # TODO: drop once the crate stops needing nightly rust
      RUSTC_BOOTSTRAP = true;
    }
    # Left out entirely off darwin rather than set to "": cargo treats a present-but-empty
    # RUSTFLAGS as authoritative and drops whatever build.rustflags would have applied.
    // lib.optionalAttrs stdenv.hostPlatform.isDarwin {
      # The undefined symbols are provided by neovim's LuaJIT at load time
      RUSTFLAGS = "-C link-arg=-undefined -C link-arg=dynamic_lookup";
    };
  };

  plugin =
    (mkPluginDrv {
      inherit name src;
      build = {
        kind = "none";
      };
    }).overrideAttrs
      (o: {
        postInstall = (o.postInstall or "") + ''
          # This file's own path is what decides where the library has to go: it appends
          # ../../../../../target/release/ to package.cpath, relative to itself. If upstream
          # moves it, fail here rather than shipping a library nothing will ever load.
          if [ ! -f $out/lua/blink/cmp/fuzzy/rust/init.lua ]; then
            echo "nvimx: the plugin locked as \"${name}\" does not look like Saghen/blink.cmp" >&2
            echo "nvimx: (no lua/blink/cmp/fuzzy/rust/init.lua to load the fuzzy library from)." >&2
            exit 1
          fi
          mkdir -p $out/target/release
          ln -s ${fuzzy}/lib/${libName} $out/target/release/${libName}
          # Deliberately no target/release/version -- see the header.
        '';
      });
in
if !builtins.pathExists cargoLockPath then
  throw ''
    nvimx: the plugin locked as "${name}" has no Cargo.lock, so nvimx cannot build its fuzzy
    matching library (nix/build-registry/blink.cmp.nix).

    ${hatches}
  ''
else if lib.any (p: lib.hasPrefix "git+" (p.source or "")) cargoLockPackages then
  # Early revs vendored frizbee straight from git. importCargoLock would fail asking for
  # `outputHashes`, which reads as an nvimx bug rather than as a property of the pinned rev.
  throw ''
    nvimx: the revision of "${name}" in your lock has a git dependency in its Cargo.lock, which
    nvimx's shipped recipe cannot hash for you (nix/build-registry/blink.cmp.nix).

    ${hatches}
  ''
else
  plugin
