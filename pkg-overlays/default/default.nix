# SPDX-License-Identifier: MIT
#
# The default package overlay. It adds one attribute to the package set, the
# scope `pkgs.deno-purifier` made from pkgs/: the `deno-purifier` command
# with its `deno` wrapper (`.deno-purifier`), and the builder
# `buildDenoProject` (nix/lib/build-deno-project.nix). A package written for
# callPackage takes the scope by name: `{ deno-purifier }:`. A consumer that
# lists this flake in `projects` holds the overlay as
# `deno-purifier/default`, which its package sets apply by default.
{ closure-lib, ... }:
{
  overlay = closure-lib.caisson.nixpkgs.mkPackagesOverlay ../../pkgs "deno-purifier";
}
