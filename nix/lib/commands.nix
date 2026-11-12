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
  # The absolute paths of the project root, of its deno-purifier lockfile
  # and of the deno.lock the build reads.
  root,
  lockFile,
  denoLockFile,
  # The store paths of the wrapper's Deno and its runtime for compiled
  # programs.
  deno,
  denort,
  nativeTools ? ../../src,
}:
let
  pkgs = import nixpkgs { inherit system; };
  purifier = import (purifierSource + "/nix/lib") { inherit (pkgs) lib; };
  lib = pkgs.lib // {
    inherit purifier;
  };
  src = /. + root;
  lockPath = /. + lockFile;
  denoLockPath = /. + denoLockFile;
  selectedSdk = {
    outPath = builtins.storePath deno;
    name = "selected-deno";
  }
  // pkgs.lib.optionalAttrs (denort != "") { denort = builtins.storePath denort; };
in
{
  environment = import ./environment.nix {
    inherit pkgs lib src;
    nativeTools = /. + nativeTools;
    lockFile = lockPath;
    denoLock = denoLockPath;
    keep = {
      deno = builtins.storePath deno;
      purifier = builtins.storePath purifierSource;
    }
    // pkgs.lib.optionalAttrs (denort != "") { denort = builtins.storePath denort; };
  };

  release =
    (pkgs.callPackage ./build-deno-project.nix
      {
        inherit purifier;
        nativeTools = /. + nativeTools;
        readLock = import ./lock.nix { inherit lib; };
      }
      {
        inherit src;
        denoPackage = selectedSdk;
        lockFile = lockPath;
        denoLock = denoLockPath;
      }
    ).release;
}
