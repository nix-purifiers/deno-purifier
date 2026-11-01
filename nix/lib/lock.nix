# SPDX-License-Identifier: MIT
#
# Reads a Deno project's deno.lock and deno-purifier.lock.json at evaluation
# time. It returns
#
#   problem     null, or the message of what is wrong with the lockfiles;
#               every other attribute fails evaluation with it
#   downloads   the download entries of the purifier library that make up
#               the project's DENO_DIR, each at its `path` in DENO_DIR:
#               - one archive entry per npm package of deno.lock, unpacked
#                 at npm/<registry host>/<name>/<version>, where Deno keeps
#                 npm packages; `hash` is the lock's integrity
#               - the file and inline entries of the remote module cache
#                 (remote/...), from deno-purifier.lock.json
#   headers     for each file entry of the remote module cache, by path, the
#               URL and the response headers Deno keeps beside the body
#   members     the project's packages, as the lock run recorded them:
#               { name, version, dir, config, tasks }
#   programs    the `deno compile` commands of the tasks:
#               { name, member, task, entrypoint, flags, args }
#
# deno.lock names every npm package with its integrity and its os and cpu
# filters, so the npm packages for every platform come from it. The remote
# modules and the JSR files are recorded by `deno-purifier lock`.
#
# deno-purifier.lock.json holds `contentHash`: the SHA-256 of the file's
# text with that value replaced by the empty string. The reader checks it
# on the text before parsing it, so a lockfile edited by hand or cut short
# fails with a request to lock again. The lockfile also holds hashes of
# deno.lock and of every deno.json the lock run read; when one of them
# changed since, evaluation stops with a request to lock again.
{
  lib,
  # The project root.
  src,
  denoLock,
  lockFile,
  # The platform the build runs for, as a nixpkgs platform. npm packages for
  # other operating systems or CPUs (such as the per-platform binaries of
  # esbuild) are left out of `downloads`, as Deno leaves them out.
  platform,
  # The `purifier` namespace of the shared purifier library.
  purifier,
}:
let
  format = 2;

  relock = what: "deno-purifier: ${what}; run `deno-purifier lock` at the project root.";
  name = "deno-purifier.lock.json";

  exists = builtins.pathExists lockFile;
  text = builtins.readFile lockFile;

  # The value of `contentHash` in the text, or null.
  contentHash =
    let
      found = builtins.filter builtins.isList (
        builtins.split "\"contentHash\": *\"([0-9a-f]{64})\"" text
      );
    in
    if builtins.length found == 1 then builtins.head (builtins.head found) else null;
  hashOk =
    builtins.hashString "sha256" (builtins.replaceStrings [ "\"${contentHash}\"" ] [ "\"\"" ] text)
    == contentHash;

  recorded = builtins.fromJSON text;

  # The fields of the format and their types. A lockfile whose contentHash
  # was forged after an edit still fails here, with the field it lacks,
  # rather than deep in a build.
  fields = {
    version = builtins.isInt;
    denoLock = builtins.isString;
    configs = builtins.isAttrs;
    npmRegistries = builtins.isAttrs;
    members = builtins.isList;
    programs = builtins.isList;
    remote = builtins.isList;
  };
  malformed = lib.filterAttrs (
    field: valid: !(recorded ? ${field}) || !valid recorded.${field}
  ) fields;
  entryShape =
    e:
    builtins.isAttrs e
    && e ? path
    && (
      (e ? contents && builtins.isString e.contents)
      || (
        e ? url
        && e ? mirrors
        && e ? headers
        && e ? hash
        # The lock run records SHA-256 hashes in SRI form.
        && builtins.isString e.hash
        && builtins.match "sha256-[A-Za-z0-9+/]{43}=" e.hash != null
      )
    );
  badEntries = builtins.filter (e: !entryShape e) recorded.remote;

  staleConfigs = lib.filterAttrs (
    path: hash: builtins.hashFile "sha256" (src + "/${path}") != hash
  ) recorded.configs;

  problem =
    if !exists then
      relock "${name} does not exist"
    else if contentHash == null then
      relock "${name} has no contentHash, so it is not one the lock run wrote"
    else if !hashOk then
      relock "${name} does not match its contentHash, so it changed after the lock run wrote it"
    else if !builtins.isAttrs recorded then
      relock "${name} is not a JSON object"
    else if (recorded.version or null) != format then
      relock "${name} has format ${
        builtins.toJSON (recorded.version or null)
      }, and this deno-purifier reads format ${toString format}"
    else if malformed != { } then
      relock "${name} lacks ${lib.concatStringsSep ", " (builtins.attrNames malformed)} or has a value of the wrong type there"
    else if badEntries != [ ] then
      relock "${name} has a remote entry that is neither { path, url, mirrors, hash, headers } nor { path, contents }: ${builtins.toJSON (builtins.head badEntries)}"
    else if builtins.hashFile "sha256" denoLock != recorded.denoLock then
      relock "deno.lock changed since ${name} was written"
    else if staleConfigs != { } then
      relock "${lib.concatStringsSep ", " (builtins.attrNames staleConfigs)} changed since ${name} was written"
    else
      null;

  parsedDenoLock = lib.importJSON denoLock;

  # npm's rule for the os and cpu fields, which Deno follows, from the
  # purifier library. deno.lock records no libc filter.
  admits =
    entry:
    purifier.admits {
      os = entry.os or null;
      cpu = entry.cpu or null;
      libc = null;
    } platform.system;

  # A deno.lock npm key is <name>@<version>, followed by "_" and the peer
  # dependencies when they shaped the resolution. The name of a scoped
  # package starts with "@", so the version starts at the first "@" after
  # the first character.
  parseKey =
    key:
    let
      rest = builtins.substring 1 (-1) key;
      at = 1 + builtins.stringLength (builtins.head (lib.splitString "@" rest));
      name = builtins.substring 0 at key;
      version = builtins.head (lib.splitString "_" (builtins.substring (at + 1) (-1) key));
    in
    {
      inherit name version;
    };

  registryFor =
    name:
    let
      scope = if lib.hasPrefix "@" name then builtins.head (lib.splitString "/" name) else "";
    in
    recorded.npmRegistries.${scope} or recorded.npmRegistries."";

  # Deno keeps npm packages under the host of their registry.
  hostOf = url: builtins.head (lib.splitString "/" (lib.last (lib.splitString "://" url)));

  npmEntry =
    key: entry:
    let
      inherit (parseKey key) name version;
      registry = registryFor name;
      unscoped = lib.last (lib.splitString "/" name);
      tarball = entry.tarball or "${registry}${name}/-/${unscoped}-${version}.tgz";
    in
    if !(entry ? integrity) then
      throw "deno-purifier: npm package ${key} has no integrity in deno.lock; run `deno-purifier lock --update` to record one."
    else
      {
        path = "npm/${hostOf registry}/${name}/${version}";
        archive = {
          url = tarball;
          mirrors = [ ];
          stripTop = true;
        };
        hash = builtins.head (lib.splitString " " entry.integrity);
      }
      // lib.getAttrs (builtins.filter (f: entry ? ${f}) [
        "os"
        "cpu"
      ]) entry;

  # A package resolved with different peer dependencies appears once per
  # resolution; Deno's cache holds it once.
  npm = builtins.filter admits (
    builtins.attrValues (
      lib.listToAttrs (
        lib.mapAttrsToList (
          key: entry:
          let
            e = npmEntry key entry;
          in
          lib.nameValuePair e.path e
        ) (parsedDenoLock.npm or { })
      )
    )
  );

  remote = map (
    e:
    if e ? contents then
      { inherit (e) path contents; }
    else
      {
        inherit (e)
          path
          url
          mirrors
          hash
          ;
      }
  ) recorded.remote;

  # Every attribute but `problem` fails with the problem, when there is one.
  checked = value: if problem != null then throw problem else value;
in
{
  inherit problem;
  downloads = checked (npm ++ remote);
  headers = checked (
    lib.listToAttrs (
      map (e: lib.nameValuePair e.path { inherit (e) url headers; }) (
        builtins.filter (e: e ? url) recorded.remote
      )
    )
  );
  members = checked recorded.members;
  programs = checked recorded.programs;
}
