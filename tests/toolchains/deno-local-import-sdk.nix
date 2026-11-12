# SPDX-License-Identifier: MIT
# Explicit fixture-only localhost module import permission. The executable is
# the original released SDK; its public flag remains visible and measured.
{ pkgs, sdk }:
let
  launcher = pkgs.writeShellScriptBin "deno" ''
    verb="''${1:-}"
    case "$verb" in
      install|run|test|check)
        shift
        exec ${sdk}/bin/deno "$verb" --allow-import=127.0.0.1 "$@"
        ;;
      *) exec ${sdk}/bin/deno "$@" ;;
    esac
  '';
in
pkgs.symlinkJoin {
  name = "deno-${sdk.version}-explicit-local-import-fixture-sdk";
  paths = [ launcher ];
  version = sdk.version;
  meta.mainProgram = "deno";
}
