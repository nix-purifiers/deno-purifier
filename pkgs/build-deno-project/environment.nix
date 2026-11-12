# SPDX-License-Identifier: MIT
#
# What `deno-purifier prefetch` realizes for a project: one store path that
# holds everything the everyday loop and the editor read, so that one
# garbage-collector root keeps it all alive:
#
#   cache/      the DENO_DIR content of the locked downloads, the same tree
#               a sandboxed build of the project uses
#   deno        the Deno of the `deno` wrapper, which also serves the editor
#               as `deno lsp`
#   denort      the runtime `deno compile` embeds
#   purifier    the source of the shared purifier library, which the
#               commands evaluate
#
# The commands evaluate this file through pkgs/build-deno-project/commands.nix; the checks
# evaluate it directly.
{
  pkgs,
  # A library with the shared purifier library as `lib.purifier`.
  lib,
  # The project root.
  src,
  lockFile ? src + "/deno-purifier.lock.json",
  denoLock ? src + "/deno.lock",
  # The store paths the environment keeps alive besides the cache, by name:
  # the toolchain and the library source.
  keep ? { },
  nativeTools ? ../../src,
}:
let
  lock = lib.purifier.checkLock (
    import ../../lib-overlays/default/lock.nix { inherit lib; } {
      inherit src lockFile denoLock;
    }
  );
  native = (lib.importJSON lockFile).native or null;
  verification = import ./native-sdk-check.nix {
    inherit pkgs native nativeTools;
    denoPackage = keep.deno or (throw "selected native SDK is missing from the environment");
  };
  cache = import ./cache.nix {
    inherit (pkgs)
      lib
      runCommand
      fetchurl
      unzip
      zstd
      python3
      writeText
      ;
    inherit (lib) purifier;
    inherit verification;
    entries = lib.purifier.entriesFor pkgs.stdenv.hostPlatform.system lock;
  };
in
pkgs.runCommand "deno-purifier-environment"
  {
    preferLocalBuild = true;
    allowSubstitutes = false;
    passthru = {
      inherit cache;
    };
  }
  ''
    mkdir -p "$out"
    ln -s ${cache} "$out/cache"
    ${lib.concatStrings (
      lib.mapAttrsToList (name: path: ''
        ln -s ${path} "$out"/${lib.escapeShellArg name}
      '') keep
    )}
  ''
