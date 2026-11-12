# SPDX-License-Identifier: MIT
# Original released x86_64 Deno executables; only ordinary Nix loader packaging.
{ pkgs, version }:
let
  hashes = {
    "1.0.0" = "6158af25218377105ec3538eaed2d0fd73ebbf70be70e543027cb3f293ef762a";
    "1.46.3" = "39bb1d21ad19c16fcb14f9d58fb542c2bccf0cd92c19aee8127ac5112b48bf83";
    "2.0.6" = "946c370617bfc041a353a5fb19b84c209461b1c2bb902908702e699a5276659e";
  };
  src = pkgs.fetchurl {
    name = "deno-${version}-original.zip";
    url = "https://github.com/denoland/deno/releases/download/v${version}/deno-x86_64-unknown-linux-gnu.zip";
    sha256 = hashes.${version};
  };
in
assert pkgs.stdenv.hostPlatform.system == "x86_64-linux";
pkgs.stdenvNoCC.mkDerivation {
  pname = "deno-original-native-sdk";
  inherit version src;
  sourceRoot = ".";
  nativeBuildInputs = [
    pkgs.autoPatchelfHook
    pkgs.unzip
    pkgs.python3
  ];
  buildInputs = [ pkgs.stdenv.cc.cc.lib ];
  dontConfigure = true;
  dontBuild = true;
  dontStrip = true;
  installPhase = ''
    runHook preInstall
    install -Dm755 deno "$out/bin/deno"
    runHook postInstall
  '';
  preFixup = ''
    postFixupHooks+=(verifyDenoSdk)
    verifyDenoSdk() {
    mkdir -p "$out/share/deno-purifier"
    python3 -B ${./elf-payload.py} ${src} "$out/bin/deno" "$out/share/deno-purifier/source-facts.json"
    export HOME="$TMPDIR/home" DENO_DIR="$TMPDIR/cache" DENO_NO_UPDATE_CHECK=1
    mkdir -p "$HOME"
    "$out/bin/deno" --version > "$out/share/deno-purifier/native-version.txt"
    python3 -c 'import pathlib,sys; assert pathlib.Path(sys.argv[1]).read_text().splitlines()[0].split()[:2] == ["deno",sys.argv[2]]' "$out/share/deno-purifier/native-version.txt" ${version}
    }
  '';
  meta.mainProgram = "deno";
}
