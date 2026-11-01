# SPDX-License-Identifier: MIT
#
# The flake's checks. Every one builds in the sandbox; the only network
# access is the fixed-output fetches of locked downloads.
{
  pkgs,
  # The flake's default package overlay, which adds buildDenoProject.
  overlay,
  # The source of deployctl at the commit tests/dependencies pins.
  deployctl,
  # The `purifier` namespace of the shared purifier library.
  purifier,
}:
let
  inherit (pkgs) lib;

  # The fixtures build the way a consumer's package does: through
  # buildDenoProject of a package set the overlay applies to.
  withOverlay = pkgs.extend overlay;
  inherit (withOverlay) buildDenoProject;

  # A workspace: a root with a build task that runs esbuild (whose native
  # binary comes from a per-platform npm package), a package published to
  # JSR that depends on an npm package, and a command-line member that
  # imports the package, a JSR package, a remote module, a remote URL that
  # redirects and a data: URL, and whose task compiles it.
  app = buildDenoProject {
    src = ./fixtures/app;
    buildTasks = [ "build" ];
    doCheck = true;
  };

  # A project whose npm dependencies come from package.json, which Deno
  # installs into node_modules, with a task that compiles it.
  nodeModules = buildDenoProject { src = ./fixtures/node-modules; };

  # deployctl, a real-world project: a deno.jsonc with comments, a JSR
  # package with many pinned @std versions and an npm dependency. Its own
  # deno.lock at that commit is out of date for this Deno, so
  # tests/real/deployctl holds the deno.lock `deno-purifier lock --update`
  # wrote, and the lockfile for it. Its code does not type-check with the
  # TypeScript library of this Deno, so the publish check skips type
  # checking.
  real = buildDenoProject {
    src = deployctl;
    lockFile = ./real/deployctl/deno.lock;
    purifierLockFile = ./real/deployctl/deno-purifier.lock.json;
    publishArgs = [ "--no-check" ];
  };

  # Evaluates the lockfile reader on lockfiles written inline. The purifier
  # lockfile records the hash of the deno.lock it goes with.
  readLock =
    platform: denoLock: recorded:
    let
      text = builtins.toJSON denoLock;
    in
    import ../nix/lib/lock.nix {
      inherit lib platform purifier;
      src = ./fixtures/app;
      lockFile = builtins.toFile "deno.lock" text;
      purifierLockFile = builtins.toFile "deno-purifier.lock.json" (
        builtins.toJSON (
          {
            version = 1;
            denoLock = builtins.hashString "sha256" text;
            configs = { };
            npmRegistries."" = "https://registry.npmjs.org/";
            members = [ ];
            programs = [ ];
            remote = [ ];
          }
          // recorded
        )
      );
    };
  host = pkgs.stdenv.hostPlatform;

  # Whether evaluating the downloads of a lock fails, as a check of the
  # lockfile reader's refusals.
  refuses = lockOf: !(builtins.tryEval (builtins.deepSeq (lockOf null).downloads true)).success;

  # A check of the lockfile reader passes when `assertion` holds; it fails
  # with `message` otherwise.
  evalCheck =
    name: assertion: message:
    if assertion then
      pkgs.runCommand name { } "touch $out"
    else
      throw "deno-purifier check ${name}: ${message}";

  esbuildLock = {
    version = "5";
    npm = {
      "@esbuild/linux-x64@0.25.0" = {
        integrity = "sha512-9yl91rHw/cpwMCNytUDxwj2XjFpxML0y9HAOH9pNVQDpQrBxHy01Dx+vaMu0N1CKa/RzBD2hB4u//nfc+Sd3Cw==";
        os = [ "linux" ];
        cpu = [ "x64" ];
      };
      "@esbuild/linux-arm64@0.25.0" = {
        integrity = "sha512-9QAQjTWNDM/Vk2bgBl17yWuZxZNQIF0OUUuPZRKoDtqF2k4EtYbpyiG5/Dk7nqeK6kIJWPYldkOcBqjXjrUlmg==";
        os = [ "linux" ];
        cpu = [ "arm64" ];
      };
    };
  };

  appLock = lib.importJSON ./fixtures/app/deno-purifier.lock.json;
  # The app fixture's purifier lockfile, changed by f.
  appLockWith = f: builtins.toFile "deno-purifier.lock.json" (builtins.toJSON (f appLock));
  # A module of the app fixture that the command-line member imports.
  colors = lib.findFirst (
    e: (e.url or "") == "https://deno.land/std@0.224.0/fmt/colors.ts"
  ) (throw "the app fixture records no colors.ts") appLock.remote;
in
{
  # The unit tests of the lock run's parsing, cache-file and URL logic.
  unit =
    pkgs.runCommand "unit-check"
      {
        nativeBuildInputs = [ withOverlay.deno ];
      }
      ''
        export HOME="$TMPDIR" DENO_DIR="$TMPDIR/deno-dir" DENO_NO_UPDATE_CHECK=1 NO_COLOR=1
        cp -r ${../src} src
        deno test --no-config --no-lock src/
        touch $out
      '';

  # The compiled program runs: it finds the workspace package, the npm
  # package it depends on, the JSR package, the remote modules and the
  # data: URL.
  program =
    pkgs.runCommand "program-check"
      {
        nativeBuildInputs = [ app.programs.hello ];
      }
      ''
        hello 3 | grep -qx 'hello, odd 3 (a/b)'
        hello 4 | grep -qx 'hello, even 4 (a/b)'
        touch $out
      '';

  # Deno installed the package.json dependency into node_modules, and the
  # compiled program finds it.
  node-modules =
    pkgs.runCommand "node-modules-check"
      {
        nativeBuildInputs = [ nodeModules.programs.odd ];
      }
      ''
        test -e ${nodeModules.project}/node_modules/is-odd/package.json
        odd 7 | grep -qx '7 is odd'
        # The task runs the command of an npm package, a script that starts
        # with `#!/usr/bin/env node`.
        grep -qx '1.3.0' ${nodeModules.tasks.version}/version.txt
        touch $out
      '';

  # The build task ran esbuild, and the tests ran.
  project = pkgs.runCommand "project-check" { } ''
    grep -q 'function greet' ${app.project}/dist/greeting.js
    touch $out
  '';

  # The task output holds what the task wrote.
  task = pkgs.runCommand "task-check" { } ''
    grep -q 'function greet' ${app.tasks.build}/dist/greeting.js
    touch $out
  '';

  # The JSR package holds its module, and `deno publish --dry-run`
  # accepted it.
  package = pkgs.runCommand "package-check" { } ''
    grep -q 'export function greet' ${app.packages."@fixture/greeting"}/mod.ts
    touch $out
  '';

  # Only the members with a name are packages, and only `deno compile`
  # tasks are programs.
  outputs = evalCheck "outputs" (
    builtins.attrNames app.packages == [ "@fixture/greeting" ]
    && builtins.attrNames app.programs == [ "hello" ]
    &&
      builtins.attrNames app.tasks == [
        "build"
        "cli:compile"
      ]
  ) "the packages, programs or tasks differ from those the fixture declares";

  # deployctl's JSR package passes `deno publish --dry-run`.
  deployctl-package = real.packages."@deno/deployctl";

  # deployctl's release task, which compares the version in its source with
  # the release tag, runs offline.
  deployctl-task = real.tasks.version-match.overrideAttrs { RELEASE_TAG = "1.13.1"; };

  # deployctl's command-line tool runs from the built project and the
  # locked downloads, offline.
  deployctl-cli =
    pkgs.runCommand "deployctl-cli-check"
      {
        nativeBuildInputs = [ withOverlay.deno ];
      }
      ''
        export HOME="$TMPDIR" DENO_DIR="$TMPDIR/deno-dir" DENO_NO_UPDATE_CHECK=1 NO_COLOR=1
        mkdir -p "$DENO_DIR"
        cp -rs --no-preserve=mode ${real.cache}/remote "$DENO_DIR/remote"
        cp -rL ${real.cache}/npm "$DENO_DIR/npm"
        chmod -R u+w "$DENO_DIR/npm"
        cd ${real.project}
        deno run --cached-only --frozen --no-check -A deployctl.ts --version | grep -q 1.13.1
        touch $out
      '';

  # Only the npm packages for the platform are fetched.
  platform-filter =
    let
      urls =
        platform:
        map (d: d.archive.url) (readLock (lib.systems.elaborate platform) esbuildLock { }).downloads;
    in
    evalCheck "platform-filter" (
      urls "x86_64-linux" == [
        "https://registry.npmjs.org/@esbuild/linux-x64/-/linux-x64-0.25.0.tgz"
      ]
      &&
        urls "aarch64-linux" == [
          "https://registry.npmjs.org/@esbuild/linux-arm64/-/linux-arm64-0.25.0.tgz"
        ]
    ) "the downloads for x86_64-linux and aarch64-linux are not the matching esbuild package";

  # A scope with its own registry takes its packages from there, and Deno
  # keeps them under the host of that registry. A peer-dependency suffix
  # names the same package.
  scoped-registry =
    let
      downloads =
        (readLock host
          {
            version = "5";
            npm."@acme/widget@1.2.3_react@18.2.0".integrity = "sha512-AAAA";
          }
          {
            npmRegistries = {
              "" = "https://registry.npmjs.org/";
              "@acme" = "https://npm.acme.example/";
            };
          }
        ).downloads;
    in
    evalCheck "scoped-registry" (
      downloads == [
        {
          path = "npm/npm.acme.example/@acme/widget/1.2.3";
          archive = {
            url = "https://npm.acme.example/@acme/widget/-/widget-1.2.3.tgz";
            mirrors = [ ];
            stripTop = true;
          };
          hash = "sha512-AAAA";
        }
      ]
    ) "the scoped package does not come from its registry";

  # A tarball URL that deno.lock records for a package from a registry
  # without the standard layout wins over the computed one.
  tarball-url =
    let
      downloads =
        (readLock host {
          version = "5";
          npm."left-pad@1.3.0" = {
            integrity = "sha512-AAAA";
            tarball = "https://mirror.example/left-pad-1.3.0.tgz";
          };
        } { }).downloads;
    in
    evalCheck "tarball-url" (
      (builtins.head downloads).archive.url == "https://mirror.example/left-pad-1.3.0.tgz"
    ) "the tarball URL of deno.lock was not used";

  # A deno.lock that changed since the lock run stops evaluation.
  stale-lock = evalCheck "stale-lock" (refuses (
    _:
    import ../nix/lib/lock.nix {
      inherit lib purifier;
      platform = host;
      src = ./fixtures/app;
      lockFile = builtins.toFile "deno.lock" (builtins.toJSON esbuildLock);
      purifierLockFile = ./fixtures/app/deno-purifier.lock.json;
    }
  )) "a deno.lock that changed since the lock run evaluated";

  # A deno.json that changed since the lock run stops evaluation.
  stale-config = evalCheck "stale-config" (refuses (
    _:
    import ../nix/lib/lock.nix {
      inherit lib purifier;
      platform = host;
      src = ./fixtures/app;
      lockFile = ./fixtures/app/deno.lock;
      purifierLockFile = appLockWith (
        l:
        l
        // {
          configs = l.configs // {
            "deno.json" = "0";
          };
        }
      );
    }
  )) "a deno.json that changed since the lock run evaluated";

  # A lockfile without one of its fields, and one with an entry of no known
  # shape, stop evaluation.
  malformed-lock = evalCheck "malformed-lock" (
    refuses (
      _:
      import ../nix/lib/lock.nix {
        inherit lib purifier;
        platform = host;
        src = ./fixtures/app;
        lockFile = ./fixtures/app/deno.lock;
        purifierLockFile = appLockWith (l: removeAttrs l [ "remote" ]);
      }
    )
    && refuses (
      _:
      import ../nix/lib/lock.nix {
        inherit lib purifier;
        platform = host;
        src = ./fixtures/app;
        lockFile = ./fixtures/app/deno.lock;
        purifierLockFile = appLockWith (l: l // { remote = l.remote ++ [ { path = "remote/x"; } ]; });
      }
    )
  ) "a malformed deno-purifier.lock.json evaluated";

  # A hash edited into something other than a SHA-256 in SRI form stops
  # evaluation. A hash edited into another valid one is caught by Nix
  # itself, which compares every fixed-output fetch with its hash.
  tampered-hash = evalCheck "tampered-hash" (refuses (
    _:
    import ../nix/lib/lock.nix {
      inherit lib purifier;
      platform = host;
      src = ./fixtures/app;
      lockFile = ./fixtures/app/deno.lock;
      purifierLockFile = appLockWith (
        l:
        l
        // {
          remote = map (e: if e == colors then e // { hash = "sha1-${colors.hash}"; } else e) l.remote;
        }
      );
    }
  )) "a lockfile with a malformed hash evaluated";

  # A build whose lockfile lacks a module the project imports fails, and
  # says to run the lock again.
  missing-entry =
    let
      missing = buildDenoProject {
        src = ./fixtures/app;
        purifierLockFile = appLockWith (l: l // { remote = builtins.filter (e: e != colors) l.remote; });
      };
      failure = pkgs.testers.testBuildFailure missing.programs.hello;
    in
    pkgs.runCommand "missing-entry-check" { } ''
      grep -q 'not found in cache' ${failure}/testBuildFailure.log
      grep -q 'run `deno-purifier lock`' ${failure}/testBuildFailure.log
      touch $out
    '';

  # The wrapper evaluates nix/lib/interactive.nix for a project; the tree
  # it builds is the one the sandboxed build of the project uses.
  interactive =
    let
      tree = import ../nix/lib/interactive.nix {
        inherit pkgs purifier;
        src = ./fixtures/app;
      };
    in
    evalCheck "interactive" (
      tree.outPath == app.cache.outPath
    ) "the tree the wrapper builds differs from the tree the build uses";

  # The commands build.
  deno-purifier = withOverlay.deno-purifier.deno-purifier;
}
