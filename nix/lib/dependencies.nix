# SPDX-License-Identifier: MIT
#
# The fetched downloads of a lock, laid out as a tree: each download lies at
# its `path`. A file entry is a link to its fixed-output fetch. An archive
# entry is the content of the archive, unpacked, with its single top-level
# directory stripped when `stripTop` is set. An inline entry is a file that
# holds its `contents`.
#
# This file knows nothing of Deno: it takes download entries of the purifier
# library's shapes
#
#   { path, url, mirrors, hash }
#   { path, archive = { url, mirrors, stripTop }, hash }
#   { path, contents }
#
# and ignores any other attribute an entry carries.
{
  lib,
  runCommand,
  fetchurl,
  gnutar,
  gzip,
  # The download entries.
  downloads,
  # The name of the tree in the store.
  name ? "deno-purifier-dependencies",
}:
let
  # A store name allows fewer characters than a URL; the last segment of
  # the URL, with the rest replaced, keeps the store listing readable.
  storeName =
    url:
    let
      base = lib.last (lib.splitString "/" (builtins.head (lib.splitString "?" url)));
      clean = builtins.replaceStrings [ "%" "@" "~" "!" ":" ] [ "_" "_" "_" "_" "_" ] base;
    in
    if clean == "" then "download" else clean;

  fetch =
    source: hash:
    fetchurl {
      urls = [ source.url ] ++ source.mirrors;
      inherit hash;
      name = storeName source.url;
    };

  files = builtins.filter (d: d ? url) downloads;
  archives = builtins.filter (d: d ? archive) downloads;
  inline = builtins.filter (d: d ? contents) downloads;
in
runCommand name
  {
    nativeBuildInputs = [
      gnutar
      gzip
    ];
    # The tree holds links and small files; the archives unpack fast.
    preferLocalBuild = true;
    allowSubstitutes = false;
    passAsFile = [
      "links"
      "archives"
      "inline"
    ];
    links = lib.concatMapStrings (d: "${d.path}\t${fetch d d.hash}\n") files;
    archives = lib.concatMapStrings (
      d: "${d.path}\t${fetch d.archive d.hash}\t${if d.archive.stripTop then "1" else "0"}\n"
    ) archives;
    inline = lib.concatMapStrings (d: "${d.path}\t${builtins.toFile "inline" d.contents}\n") inline;
  }
  ''
    shopt -s dotglob nullglob
    mkdir -p "$out"
    while IFS=$'\t' read -r path target; do
      mkdir -p "$out/$(dirname "$path")"
      ln -s "$target" "$out/$path"
    done < "$linksPath"
    while IFS=$'\t' read -r path target; do
      mkdir -p "$out/$(dirname "$path")"
      cp "$target" "$out/$path"
    done < "$inlinePath"
    while IFS=$'\t' read -r path archive stripTop; do
      unpacked="$(mktemp -d)"
      tar -xf "$archive" -C "$unpacked"
      top=("$unpacked"/*)
      mkdir -p "$(dirname "$out/$path")"
      if [ "$stripTop" = 1 ] && [ "''${#top[@]}" = 1 ] && [ -d "''${top[0]}" ]; then
        mv "''${top[0]}" "$out/$path"
        rmdir "$unpacked"
      else
        mv "$unpacked" "$out/$path"
      fi
      chmod -R u+rwX,go+rX "$out/$path"
    done < "$archivesPath"
  ''
