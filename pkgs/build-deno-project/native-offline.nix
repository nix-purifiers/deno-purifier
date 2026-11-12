# SPDX-License-Identifier: MIT
# Deno 1.0 has no non-executing cache-only CLI flag. Its genuine cache command
# verifies the rebuilt inputs in an ordinary network-isolated Nix derivation.
{
  nixpkgs,
  system,
  sdk,
  src,
  cache,
  modulesJSON,
  frozen,
}:
let
  pkgs = import nixpkgs { inherit system; };
  modules = builtins.fromJSON modulesJSON;
  source = builtins.path {
    path = /. + src;
    name = "deno-native-verify-source";
  };
  downloads = builtins.path {
    path = /. + cache;
    name = "deno-native-verify-cache";
  };
in
pkgs.runCommand "deno-native-offline-cache-check"
  {
    nativeBuildInputs = [ (builtins.storePath sdk) ];
  }
  ''
    export HOME="$TMPDIR/home" DENO_DIR="$TMPDIR/deno-dir" DENO_NO_UPDATE_CHECK=1 NO_COLOR=1
    mkdir -p "$HOME" "$DENO_DIR" project
    cp -r --no-preserve=mode ${source}/. project/
    cp -r --no-preserve=mode ${downloads}/. "$DENO_DIR/"
    cd project
    before=$(sha256sum deno.lock)
    ${builtins.storePath sdk}/bin/deno cache --lock=deno.lock ${pkgs.lib.optionalString frozen "--frozen"} ${pkgs.lib.escapeShellArgs modules}
    test "$before" = "$(sha256sum deno.lock)"
    touch "$out"
  ''
