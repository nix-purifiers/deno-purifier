# SPDX-License-Identifier: MIT
#
# The `deno-purifier` library namespace: `lib.deno-purifier.readLock`
# (nix/lib/lock.nix), which reads a project's lockfiles into the lock in
# memory of the purifier contract. It reads the shared purifier library from
# the composed library, which has it because this flake lists `purifier` in
# its projects. The builder `buildDenoProject` needs a package set, so the
# default package overlay adds it.
{ ... }:
{

  overlay = final: prev: {
    deno-purifier = {
      readLock = import ../../nix/lib/lock.nix { lib = final; };
    };
  };

}
