# SPDX-License-Identifier: MIT
#
# What the `deno` wrapper builds for a project: the DENO_DIR of the
# downloads that deno.lock and deno-purifier.lock.json name, the same tree a
# sandboxed build of the project uses. The wrapper evaluates this file with
# the project root's absolute path and keeps the result alive with a GC
# root.
{
  pkgs,
  # The project root.
  src,
  # The `purifier` namespace of the shared purifier library.
  purifier,
}:
pkgs.callPackage ./cache.nix {
  inherit purifier;
  lock = import ./lock.nix {
    inherit (pkgs) lib;
    inherit src purifier;
    lockFile = src + "/deno.lock";
    purifierLockFile = src + "/deno-purifier.lock.json";
    platform = pkgs.stdenv.hostPlatform;
  };
}
