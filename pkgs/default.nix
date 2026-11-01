# SPDX-License-Identifier: MIT
{ callPackage, ... }:
{
  # `deno-purifier lock`, and `deno` wrapped so that in a project with a
  # deno-purifier.lock.json it reads the locked downloads from the Nix
  # store, offline.
  deno-purifier = callPackage ./deno-purifier { };
}
