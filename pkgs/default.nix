# SPDX-License-Identifier: MIT
#
# The deno-purifier scope of a package set, `pkgs.deno-purifier`. `lib` is
# the composed library of this flake, which has the shared purifier library
# as `lib.purifier` and `readLock` as `lib.deno-purifier.readLock`.
{ callPackage, lib, ... }:
{
  # `deno-purifier lock`, and `deno` wrapped so that in a project with a
  # deno-purifier.lock.json it reads the locked downloads from the Nix
  # store, offline.
  deno-purifier = callPackage ./deno-purifier { };

  # The builder (nix/lib/build-deno-project.nix). It is a package for
  # callPackage in this scope, so `buildDenoProject.override` replaces the
  # packages it takes by name.
  buildDenoProject = callPackage ../nix/lib/build-deno-project.nix {
    inherit (lib) purifier;
    inherit (lib.deno-purifier) readLock;
  };
}
