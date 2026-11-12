# SPDX-License-Identifier: MIT
# Schema controls only; this synthetic SDK identity is never executed.
{ lib }:
let
  check = import ../nix/lib/native-context.nix { inherit lib; };
  sdk = "/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-schema-control";
  sri = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
  url = "https://example.com/leaf.js";
  alias = "https://example.com/entry.js";
  path = name: "deps/https/example.com/${builtins.hashString "sha256" name}";
  native = {
    schemaVersion = 1;
    inherit sdk;
    executable = sdk + "/bin/deno";
    executableHash = sri;
    version = "1.0.0";
    closure = [
      {
        path = sdk;
        narHash = sri;
      }
    ];
    capabilities = lib.genAttrs [
      "install"
      "frozen"
      "check"
      "compile"
      "publish"
      "task"
      "update"
    ] (_: false);
    cachePaths.${url} = path "/leaf.js";
    redirects.${alias} = {
      path = path "/entry.js";
      location = "/leaf.js";
      target = url;
    };
    lockVersion = "flat";
    modules = [ "main.js" ];
  };
  lock.${url} = builtins.hashString "sha256" "";
  rejects =
    value:
    let
      result = builtins.tryEval (check value lock);
    in
    !result.success || !result.value;
  cases = [
    (native // { schemaVersion = 2; })
    (native // { unexpected = true; })
    (native // { modules = [ "../main.js" ]; })
    (native // { closure = native.closure ++ native.closure; })
    (native // { cachePaths.${url} = "deps/../../escape"; })
    (
      native
      // {
        redirects.${alias} = native.redirects.${alias} // {
          target = alias;
        };
      }
    )
    (
      native
      // {
        redirects.${alias} = native.redirects.${alias} // {
          target = "https://example.com/missing.js";
        };
      }
    )
    (
      native
      // {
        redirects.${alias} = native.redirects.${alias} // {
          path = path "/leaf.js";
        };
      }
    )
  ];
in
check native lock && lib.all rejects cases
