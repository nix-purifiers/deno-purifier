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
#               - one file entry per remote module outside JSR, with the
#                 hash deno.lock pins
#               - one file entry per JSR version's <version>_meta.json, with
#                 the hash deno.lock pins as its integrity
#               - one inline entry per JSR package: its version list
#                 (meta.json), naming the locked versions
#               - one file entry per JSR module file, with the hash
#                 deno-purifier.lock.json records
#   headers     for each file entry of the remote module cache, by path, the
#               URL and the response headers Deno keeps beside the body: the
#               ones deno-purifier.lock.json records for the module, or none
#   members     the project's packages, as the lock run recorded them:
#               { name, version, dir, config, tasks }
#   programs    the `deno compile` commands of the tasks:
#               { name, member, task, entrypoint, flags, args }
#
# Deno keeps a remote module at remote/<scheme>/<host>/<SHA-256 of the
# path and query>, with a port written as <host>_PORT<port>. Deno reads
# redirects from deno.lock, so they need no entry.
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
  format = 3;

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
    jsrRegistry = builtins.isString;
    npmRegistries = builtins.isAttrs;
    members = builtins.isList;
    programs = builtins.isList;
    jsrFiles = builtins.isAttrs;
    headers = builtins.isAttrs;
  };
  malformed = lib.filterAttrs (
    field: valid: !(recorded ? ${field}) || !valid recorded.${field}
  ) fields;
  # The lock run records SHA-256 hashes in SRI form.
  isSri = hash: builtins.isString hash && builtins.match "sha256-[A-Za-z0-9+/]{43}=" hash != null;
  badFiles = lib.filterAttrs (_: hash: !isSri hash) recorded.jsrFiles;

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
    else if badFiles != { } then
      relock "${name} records a hash that is not a SHA-256 in SRI form for ${builtins.head (builtins.attrNames badFiles)}"
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

  # Where Deno caches the remote module at `url`, relative to DENO_DIR.
  cachePath =
    url:
    let
      parts = builtins.match "([a-z]+)://([^/?#]+)([^#]*).*" url;
      scheme = builtins.elemAt parts 0;
      authority = builtins.elemAt parts 1;
      rest = builtins.elemAt parts 2;
      pathQuery = if lib.hasPrefix "/" rest then rest else "/${rest}";
      hostPort = builtins.match "([^:]+):([0-9]+)" authority;
      defaultPort = {
        http = "80";
        https = "443";
      };
      host =
        if hostPort == null || builtins.elemAt hostPort 1 == defaultPort.${scheme} or null then
          builtins.head (lib.splitString ":" authority)
        else
          "${builtins.elemAt hostPort 0}_PORT${builtins.elemAt hostPort 1}";
    in
    if parts == null then
      throw "deno-purifier: cannot read the URL ${url}"
    else
      "remote/${scheme}/${host}/${builtins.hashString "sha256" pathQuery}";

  sriOf =
    hex:
    builtins.convertHash {
      hash = hex;
      hashAlgo = "sha256";
      toHashFormat = "sri";
    };

  fileEntry = url: hash: {
    path = cachePath url;
    inherit url hash;
    mirrors = [ ];
  };

  # The remote modules outside JSR, which deno.lock pins by URL.
  remoteFiles = lib.mapAttrsToList (url: hex: fileEntry url (sriOf hex)) (
    parsedDenoLock.remote or { }
  );

  # The JSR versions of deno.lock, keyed "@scope/name@version".
  jsrVersions = lib.mapAttrsToList (
    key: entry:
    let
      parts = builtins.match "(@[^/]+/[^@]+)@(.+)" key;
    in
    {
      package = builtins.elemAt parts 0;
      version = builtins.elemAt parts 1;
      inherit (entry) integrity;
    }
  ) (parsedDenoLock.jsr or { });

  versionMetas = map (
    v: fileEntry "${recorded.jsrRegistry}${v.package}/${v.version}_meta.json" (sriOf v.integrity)
  ) jsrVersions;

  # The version list of each JSR package, naming the locked versions. The
  # lock run writes the same list when it checks the lockfile.
  versionLists = lib.mapAttrsToList (
    package: versions:
    let
      url = "${recorded.jsrRegistry}${package}/meta.json";
      scopeName = builtins.match "@([^/]+)/(.+)" package;
      body = builtins.toJSON {
        scope = builtins.elemAt scopeName 0;
        name = builtins.elemAt scopeName 1;
        versions = lib.genAttrs (map (v: v.version) versions) (_: { });
      };
    in
    {
      path = cachePath url;
      contents = "${body}\n// denoCacheMetadata=${
        builtins.toJSON {
          headers = { };
          inherit url;
          time = 0;
        }
      }";
    }
  ) (builtins.groupBy (v: v.package) jsrVersions);

  jsrFiles = lib.mapAttrsToList fileEntry recorded.jsrFiles;

  files = remoteFiles ++ versionMetas ++ jsrFiles;

  # Every attribute but `problem` fails with the problem, when there is one.
  checked = value: if problem != null then throw problem else value;
in
{
  inherit problem;
  downloads = checked (npm ++ files ++ versionLists);
  headers = checked (
    lib.listToAttrs (
      map (
        e:
        lib.nameValuePair e.path {
          inherit (e) url;
          headers = recorded.headers.${e.url} or { };
        }
      ) files
    )
  );
  members = checked recorded.members;
  programs = checked recorded.programs;
}
