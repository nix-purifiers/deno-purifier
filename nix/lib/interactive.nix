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
}:
pkgs.callPackage ./cache.nix {
  lock = import ./lock.nix {
    inherit (pkgs) lib;
    inherit src;
    lockFile = src + "/deno.lock";
    purifierLockFile = src + "/deno-purifier.lock.json";
    platform = pkgs.stdenv.hostPlatform;
  };
}
