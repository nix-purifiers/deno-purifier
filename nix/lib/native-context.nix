# SPDX-License-Identifier: MIT
{ lib }:
native: toolLock:
let
  exact = keys: v: builtins.isAttrs v && builtins.attrNames v == lib.sort builtins.lessThan keys;
  scalar = v: builtins.isString v && v != "" && builtins.stringLength v <= 8192;
  store = v: scalar v && builtins.match "/nix/store/[a-z0-9]{32}-[^/]+" v != null;
  sri = v: scalar v && builtins.match "sha256-[A-Za-z0-9+/]{42}[AEIMQUYcgkosw048]=" v != null;
  version = v: scalar v && builtins.match "[0-9]+[.][0-9]+[.][0-9]+([-+][0-9A-Za-z.-]+)?" v != null;
  remote = if native.lockVersion == "flat" then toolLock else toolLock.remote or { };
  mapping =
    url: path:
    let
      parts = builtins.match "(http|https)://([A-Za-z0-9.-]+)(:([0-9]+))?([^#]*)" url;
      scheme = builtins.elemAt parts 0;
      host = builtins.elemAt parts 1;
      port = builtins.elemAt parts 3;
      rest = builtins.elemAt parts 4;
      query = if rest == "" then "/" else rest;
      standard = {
        http = "80";
        https = "443";
      };
      hosts =
        if port == null || port == standard.${scheme} then
          [ host ]
        else
          [
            "${host}_PORT${port}"
            "${host}_port_${port}"
          ];
      paths =
        lib.concatMap
          (prefix: map (h: "${prefix}/${scheme}/${h}/${builtins.hashString "sha256" query}") hosts)
          [
            "deps"
            "remote"
          ];
    in
    scalar path && parts != null && builtins.elem path paths;
  terminal =
    seen: url:
    if builtins.elem url seen || builtins.length seen >= 256 then
      false
    else if native.cachePaths ? ${url} then
      true
    else if
      native.redirects ? ${url}
      && builtins.isAttrs native.redirects.${url}
      && builtins.isString (native.redirects.${url}.target or null)
    then
      terminal (seen ++ [ url ]) native.redirects.${url}.target
    else
      false;
  row = v: exact [ "path" "narHash" ] v && store v.path && sri v.narHash;
  capabilities =
    v:
    exact [
      "install"
      "frozen"
      "check"
      "compile"
      "publish"
      "task"
      "update"
    ] v
    && lib.all builtins.isBool (builtins.attrValues v);
in
native == null
|| (
  exact [
    "schemaVersion"
    "sdk"
    "executable"
    "executableHash"
    "version"
    "closure"
    "capabilities"
    "cachePaths"
    "redirects"
    "lockVersion"
    "modules"
  ] native
  && native.schemaVersion == 1
  && store native.sdk
  && sri native.executableHash
  && version native.version
  && builtins.isList native.closure
  && native.closure != [ ]
  && builtins.length native.closure <= 4096
  && lib.all row native.closure
  && builtins.length (lib.unique (map (v: v.path) native.closure)) == builtins.length native.closure
  && lib.any (v: v.path == native.sdk) native.closure
  && scalar native.executable
  && lib.any (v: lib.hasPrefix (v.path + "/") native.executable) native.closure
  && capabilities native.capabilities
  && builtins.elem native.lockVersion [
    "flat"
    "2"
    "3"
    "4"
    "5"
  ]
  && (
    if native.lockVersion == "flat" then
      !(toolLock ? version)
    else
      (toolLock.version or null) == native.lockVersion
  )
  && builtins.isAttrs remote
  && lib.all (v: scalar v && builtins.match "[0-9a-f]{64}" v != null) (builtins.attrValues remote)
  && (toolLock.npm or { }) == { }
  && (toolLock.jsr or { }) == { }
  && builtins.isList native.modules
  && native.modules != [ ]
  && builtins.length native.modules <= 100000
  && builtins.length (lib.unique native.modules) == builtins.length native.modules
  && lib.all (
    p:
    scalar p
    && !lib.hasPrefix "/" p
    && builtins.match ".*[\\\\\n\r].*" p == null
    && lib.all (part: part != "" && part != "." && part != "..") (lib.splitString "/" p)
  ) native.modules
  && builtins.isAttrs native.cachePaths
  && builtins.length (builtins.attrNames native.cachePaths) <= 100000
  && lib.all (url: remote ? ${url} && mapping url native.cachePaths.${url}) (
    builtins.attrNames native.cachePaths
  )
  && builtins.isAttrs native.redirects
  && builtins.length (builtins.attrNames native.redirects) <= 100000
  && lib.all (
    url:
    let
      r = native.redirects.${url};
    in
    exact [ "path" "location" "target" ] r
    && mapping url r.path
    && scalar r.location
    && scalar r.target
    && !(native.cachePaths ? ${url})
    && terminal [ ] url
    && (native.cachePaths ? ${r.target} || native.redirects ? ${r.target})
    && (native.lockVersion == "flat" || (toolLock.redirects.${url} or null) == r.target)
  ) (builtins.attrNames native.redirects)
  &&
    builtins.length (
      lib.unique (
        (builtins.attrValues native.cachePaths) ++ (map (r: r.path) (builtins.attrValues native.redirects))
      )
    ) == builtins.length (builtins.attrNames native.cachePaths)
    + builtins.length (builtins.attrNames native.redirects)
  &&
    builtins.length (lib.unique (builtins.attrValues native.cachePaths))
    == builtins.length (builtins.attrNames native.cachePaths)
)
