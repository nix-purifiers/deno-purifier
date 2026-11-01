# SPDX-License-Identifier: MIT
#
# What the `deno-purifier` commands build for a project, outside any flake:
# `prefetch` builds `environment` (nix/lib/environment.nix) and `publish`
# builds `release`, the release of buildDenoProject. The commands evaluate
# this file with `nix build --impure`, passing the paths below as strings.
{
  # The nixpkgs the commands were built from, and the system.
  nixpkgs,
  system,
  # The source of the shared purifier library, at the revision the
  # deno-purifier flake locks.
  purifierSource,
  # The absolute paths of the project root and of its deno-purifier
  # lockfile.
  root,
  lockFile,
  # The store paths of the wrapper's Deno and its runtime for compiled
  # programs.
  deno,
  denort,
}:
let
  pkgs = import nixpkgs { inherit system; };
  purifier = import (purifierSource + "/nix/lib") { inherit (pkgs) lib; };
  lib = pkgs.lib // {
    inherit purifier;
  };
  src = /. + root;
  lockPath = /. + lockFile;
in
{
  environment = import ./environment.nix {
    inherit pkgs purifier src;
    lockFile = lockPath;
    keep = {
      deno = builtins.storePath deno;
      denort = builtins.storePath denort;
      purifier = builtins.storePath purifierSource;
    };
  };

  release =
    ((import ./build-deno-project.nix { inherit lib; }) {
      inherit pkgs src;
      lockFile = lockPath;
    }).release;
}
