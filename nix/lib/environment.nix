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
# The commands evaluate this file through nix/lib/commands.nix; the checks
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
}:
let
  lock = lib.purifier.checkLock (
    import ./lock.nix { inherit lib; } {
      inherit src lockFile denoLock;
    }
  );
  cache = import ./cache.nix {
    inherit pkgs;
    inherit (lib) purifier;
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
