# SPDX-License-Identifier: MIT
#
# The `deno-purifier` library namespace: the builder
# `lib.deno-purifier.buildDenoProject` (nix/lib/build-deno-project.nix),
# which takes the package set as its `pkgs` argument. It reads the shared
# purifier library from the composed library, which has it because this
# flake lists `purifier` in its projects.
{ ... }:
{

  overlay = final: prev: {
    deno-purifier = {
      buildDenoProject = import ../../nix/lib/build-deno-project.nix { lib = final; };
    };
  };

}
