# SPDX-License-Identifier: MIT
#
# The default package overlay. It adds the packages of pkgs/ under
# `pkgs.deno-purifier` (`.deno-purifier`): the `deno-purifier` command and
# the `deno` wrapper. A consumer that lists this flake in `projects` holds
# the overlay as `deno-purifier/default`, which its package sets apply by
# default.
{ closure-lib, ... }:
{
  overlay = closure-lib.caisson.nixpkgs.mkPackagesOverlay ../../pkgs "deno-purifier";
}
