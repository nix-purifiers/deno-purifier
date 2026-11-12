# SPDX-License-Identifier: MIT
# Uses this repository's locked package set, independently of the caller's SDK.
{
  system ? builtins.currentSystem,
}:
let
  locked = builtins.fromJSON (builtins.readFile ../flake.lock);
  nixpkgs = builtins.fetchTree locked.nodes.nixpkgs.locked;
  pkgs = import nixpkgs { inherit system; };
  original = version: import ./toolchains/deno-native-sdk.nix { inherit pkgs version; };
  localImports = sdk: import ./toolchains/deno-local-import-sdk.nix { inherit pkgs sdk; };
  cli = deno: pkgs.callPackage ../pkgs/deno-purifier/default.nix { inherit deno; };
in
{
  deno100 = cli (original "1.0.0");
  deno1463 = cli (original "1.46.3");
  deno206 = cli (localImports (original "2.0.6"));
  current = cli (localImports pkgs.deno);
  currentVersion = pkgs.deno.version;
}
