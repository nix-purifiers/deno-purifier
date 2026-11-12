# SPDX-License-Identifier: MIT
{
  pkgs,
  denoPackage,
  native,
  nativeTools ? ../../src,
}:
if native == null then
  null
else
  let
    record = pkgs.writeText "deno-native-context.json" (builtins.toJSON native);
  in
  pkgs.runCommand "deno-native-sdk-physical-check"
    {
      __structuredAttrs = true;
      exportReferencesGraph.projectSdk = [ denoPackage ];
    }
    ''
      out=''${outputs[out]}
      export HOME="$TMPDIR/home" DENO_DIR="$TMPDIR/helper-cache" DENO_NO_UPDATE_CHECK=1
      mkdir -p "$HOME"
      ${pkgs.deno}/bin/deno run --allow-all --no-config --no-lock ${nativeTools}/verify-native.ts \
        ${record} ${denoPackage} ${pkgs.nix}/bin/nix "$NIX_ATTRS_JSON_FILE" > "$out"
    ''
