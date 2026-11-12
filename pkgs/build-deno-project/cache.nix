# SPDX-License-Identifier: MIT
#
# A DENO_DIR made of the locked downloads of one system: the content Deno
# reads with --cached-only, and nothing it derives (transpiled modules,
# analysis databases), which Deno writes beside it at run time.
#
# The shared purifier library lays the download entries out as a tree:
# npm packages lie unpacked as Deno unpacks them, and inline entries hold
# the whole cache file. Deno keeps a remote module as one file: the body,
# then a line `// denoCacheMetadata=` and a JSON object with the response
# headers, the URL and the time of the fetch. A file entry fetches the body
# alone, so this tree appends the line, with the headers of the entry and a
# time of 0.
{
  lib,
  runCommand,
  fetchurl,
  unzip,
  zstd,
  python3,
  writeText,
  # The `purifier` namespace of the shared purifier library.
  purifier,
  # The download entries of the system, from the library's entriesFor.
  entries,
  # The fetchers that replace nixpkgs' own, which go to the library's
  # fetchEntry unchanged, such as a fetchurl that sends credentials.
  fetchers ? { },
  verification ? null,
}:
let
  dependencies = purifier.tree (
    {
      inherit
        runCommand
        fetchurl
        unzip
        zstd
        python3
        writeText
        entries
        ;
      name = "deno-purifier-dependencies";
    }
    // fetchers
  );
  modules = builtins.filter (e: e ? url && lib.hasPrefix "remote/" e.path) entries;
in
runCommand "deno-purifier-cache"
  {
    preferLocalBuild = true;
    allowSubstitutes = false;
    passAsFile = [ "modules" ];
    nativeSdkVerified = if verification == null then "" else verification;
    # One line per module: its path and its metadata line. Nix writes JSON
    # without newlines or tabs, so each line holds one module.
    modules = lib.concatMapStrings (
      e:
      "${e.path}\t${
        builtins.toJSON {
          inherit (e) url;
          headers = e.headers or { };
          time = 0;
        }
      }\n"
    ) modules;
    passthru = {
      inherit dependencies;
    };
  }
  ''
    # A tree of links to the dependencies, in which the remote modules
    # become files of their own.
    mkdir -p "$out"
    cp -rs --no-preserve=mode ${dependencies}/. "$out"
    while IFS=$'\t' read -r path meta; do
      rm "$out/$path"
      {
        cat ${dependencies}/"$path"
        printf '\n// denoCacheMetadata=%s' "$meta"
      } > "$out/$path"
    done < "$modulesPath"
  ''
