# SPDX-License-Identifier: MIT
#
# A DENO_DIR made of the locked downloads: the content Deno reads with
# --cached-only, and nothing it derives (transpiled modules, analysis
# databases), which Deno writes beside it at run time.
#
# The shared purifier library lays the download entries out as a tree:
# npm packages lie unpacked as Deno unpacks them, and inline entries hold
# the whole cache file. Deno keeps a remote module as one file: the body,
# then a line `// denoCacheMetadata=` and a JSON object with the response
# headers, the URL and the time of the fetch. A file entry fetches the body
# alone, so this tree appends the line, with the headers the lock run
# recorded and a time of 0.
{
  pkgs,
  # The `purifier` namespace of the shared purifier library.
  purifier,
  # The result of nix/lib/lock.nix.
  lock,
  # The fetchers that replace nixpkgs' own, which go to the library's
  # fetchEntry unchanged, such as a fetchurl that sends credentials.
  fetchers ? { },
}:
let
  inherit (pkgs) lib;
  dependencies = purifier.tree (
    {
      inherit pkgs;
      name = "deno-purifier-dependencies";
      entries = lock.downloads;
    }
    // fetchers
  );
in
pkgs.runCommand "deno-purifier-cache"
  {
    preferLocalBuild = true;
    allowSubstitutes = false;
    passAsFile = [ "modules" ];
    # One line per module: its path and its metadata line. Nix writes JSON
    # without newlines or tabs, so each line holds one module.
    modules = lib.concatStrings (
      lib.mapAttrsToList (
        path: meta:
        "${path}\t${
          builtins.toJSON {
            inherit (meta) url headers;
            time = 0;
          }
        }\n"
      ) lock.headers
    );
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
