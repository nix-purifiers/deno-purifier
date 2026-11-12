# SPDX-License-Identifier: MIT
#
# readLock: a Deno project's deno.lock and deno-purifier.lock.json read
# into the lock in memory of the purifier contract, at evaluation time:
#
#   purifier   "deno-purifier"
#   entries    the download entries of the purifier library that make up
#              the project's DENO_DIR, each at its `path` in DENO_DIR:
#              - one archive entry per npm package of deno.lock, unpacked
#                at npm/<registry host>/<name>/<version>, where Deno keeps
#                npm packages; `hash` is the lock's integrity, and
#                `systems` lists the systems a package with os or cpu
#                filters installs on
#              - one file entry per remote module outside JSR, with the
#                hash deno.lock pins
#              - one file entry per JSR version's <version>_meta.json, with
#                the hash deno.lock pins as its integrity
#              - one inline entry per JSR package: its version list
#                (meta.json), naming the locked versions
#              - one file entry per JSR module file, with the hash
#                deno-purifier.lock.json records
#              A file entry also carries `headers`: the response headers
#              Deno keeps beside the body, which deno-purifier.lock.json
#              records for the modules that need them.
#   outputs    the names of the builder's `packages`, each with what the
#              builder needs to build it:
#                <program>    { kind = "program"; program; version; }
#                <package>    { kind = "package"; member; version; }
#                task:<task>  { kind = "task"; member; task; }
#   problems   what is wrong with the lockfiles, each naming the command
#              that fixes it; `entries` and `outputs` are empty then
#
# Deno keeps a remote module at remote/<scheme>/<host>/<SHA-256 of the
# path and query>. The selected SDK records its observed cache layout,
# including legacy sidecars and redirects absent from early native locks.
#
# deno-purifier.lock.json holds `contentHash`: the SHA-256 of the file's
# text with that value replaced by the empty string. The reader checks it
# on the text before parsing it, so a lockfile edited by hand or cut short
# fails with a request to lock again. The lockfile also holds hashes of
# deno.lock and of every deno.json the lock run read; when one of them
# changed since, the lock has a problem that asks to lock again.
#
# `lib` is the composed library, which has the shared purifier library as
# `lib.purifier`.
{ lib }:
{
  # The project root.
  src,
  lockFile ? src + "/deno-purifier.lock.json",
  denoLock ? src + "/deno.lock",
}:
let
  format = 3;

  # The systems of the nix-purifiers family.
  systems = [
    "x86_64-linux"
    "aarch64-linux"
    "aarch64-darwin"
  ];

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
    else if
      !(import ./native-context.nix { inherit lib; } (recorded.native or null) parsedDenoLock)
    then
      relock "selected native SDK/cache context is malformed or conflicts with deno.lock"
    else if badFiles != { } then
      relock "${name} records a hash that is not a SHA-256 in SRI form for ${builtins.head (builtins.attrNames badFiles)}"
    else if builtins.hashFile "sha256" denoLock != recorded.denoLock then
      relock "deno.lock changed since ${name} was written"
    else if staleConfigs != { } then
      relock "${lib.concatStringsSep ", " (builtins.attrNames staleConfigs)} changed since ${name} was written"
    else if clash != null then
      "deno-purifier: more than one output of the project is named ${builtins.toJSON clash}; rename a program, a package or a task."
    else
      null;

  parsedDenoLock = lib.importJSON denoLock;

  # npm's rule for the os and cpu fields, which Deno follows, from the
  # purifier library: the systems a package installs on, or null for every
  # one. deno.lock records no libc filter.
  systemsOf =
    entry:
    if !(entry ? os || entry ? cpu) then
      null
    else
      builtins.filter (lib.purifier.admits {
        os = entry.os or null;
        cpu = entry.cpu or null;
        libc = null;
      }) systems;

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
      packageSystems = systemsOf entry;
    in
    if !(entry ? integrity) then
      throw "deno-purifier: npm package ${key} has no integrity in deno.lock; run `deno-purifier lock` to record one."
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
      // lib.optionalAttrs (packageSystems != null) { systems = packageSystems; };

  # A package resolved with different peer dependencies appears once per
  # resolution; Deno's cache holds it once.
  npm = builtins.attrValues (
    lib.listToAttrs (
      lib.mapAttrsToList (
        key: entry:
        let
          e = npmEntry key entry;
        in
        lib.nameValuePair e.path e
      ) (parsedDenoLock.npm or { })
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
          "${builtins.elemAt hostPort 0}_port_${builtins.elemAt hostPort 1}";
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
    path = if recorded ? native then recorded.native.cachePaths.${url} else cachePath url;
    inherit url hash;
    mirrors = [ ];
    headers = recorded.headers.${url} or { };
  };

  # The remote modules outside JSR, which deno.lock pins by URL.
  nativeRemote =
    if (recorded.native.lockVersion or null) == "flat" then
      parsedDenoLock
    else
      parsedDenoLock.remote or { };
  remoteFiles = lib.mapAttrsToList (url: hex: fileEntry url (sriOf hex)) (
    if recorded ? native then
      lib.filterAttrs (url: _: recorded.native.cachePaths ? ${url}) nativeRemote
    else
      nativeRemote
  );
  sidecars = map (entry: {
    path = entry.path + ".metadata.json";
    contents = builtins.toJSON {
      inherit (entry) url headers;
      now = {
        secs_since_epoch = 0;
        nanos_since_epoch = 0;
      };
    };
  }) (builtins.filter (entry: lib.hasPrefix "deps/" entry.path) remoteFiles);

  redirectEntries = lib.concatLists (
    lib.mapAttrsToList (
      url: row:
      let
        headers = {
          location = row.location;
        };
        metadata = {
          inherit url headers;
          time = 0;
        };
      in
      if lib.hasPrefix "deps/" row.path then
        [
          {
            path = row.path;
            contents = "";
          }
          {
            path = row.path + ".metadata.json";
            contents = builtins.toJSON {
              inherit url headers;
              now = {
                secs_since_epoch = 0;
                nanos_since_epoch = 0;
              };
            };
          }
        ]
      else
        [
          {
            path = row.path;
            contents = "\n// denoCacheMetadata=${builtins.toJSON metadata}";
          }
        ]
    ) (recorded.native.redirects or { })
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

  versionOf =
    dir:
    let
      member = lib.findFirst (m: m.dir == dir) null recorded.members;
    in
    if member != null && member.version != null then member.version else "0.0.0";

  # The outputs, in a list so that a name given twice is found.
  outputList =
    map (p: {
      name = p.name;
      value = {
        kind = "program";
        program = p;
        version = versionOf p.member;
      };
    }) recorded.programs
    ++ map (m: {
      inherit (m) name;
      value = {
        kind = "package";
        member = m;
        version = versionOf m.dir;
      };
    }) (builtins.filter (m: m.name != null) recorded.members)
    ++ lib.concatMap (
      m:
      map (t: {
        name = if m.dir == "" then "task:${t}" else "task:${m.dir}:${t}";
        value = {
          kind = "task";
          member = m;
          task = t;
        };
      }) m.tasks
    ) recorded.members;
  names = map (o: o.name) outputList;
  clash = lib.findFirst (n: lib.count (m: m == n) names > 1) null names;
in
{
  purifier = "deno-purifier";
  problems = lib.optional (problem != null) problem;
  entries =
    if problem != null then
      [ ]
    else
      npm ++ remoteFiles ++ sidecars ++ redirectEntries ++ versionMetas ++ jsrFiles ++ versionLists;
  outputs = if problem != null then { } else builtins.listToAttrs outputList;
}
