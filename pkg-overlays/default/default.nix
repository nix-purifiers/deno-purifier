# SPDX-License-Identifier: MIT
#
# The default package overlay. It adds the packages of pkgs/ under
# `pkgs.deno-purifier` (`.deno-purifier`), and the builder
# `pkgs.buildDenoProject` (nix/lib/build-deno-project.nix) beside them,
# where nixpkgs keeps its own builders, so a package written for
# callPackage takes it by name. A consumer that lists this flake in
# `projects` holds it as `deno-purifier/default`, which its package sets
# apply by default.
{ closure-lib, ... }:
let
  packages = closure-lib.caisson.nixpkgs.mkPackagesOverlay ../../pkgs "deno-purifier";
in
{
  overlay =
    final: prev:
    packages final prev
    // {
      buildDenoProject = final.callPackage ../../nix/lib/build-deno-project.nix { };
    };
}
