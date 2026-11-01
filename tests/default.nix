# SPDX-License-Identifier: MIT
#
# The flake's checks. Every one builds in the sandbox; the only network
# access is the fixed-output fetches of locked downloads. The
# `conformance-*` checks are those of the purifier contract; the relock
# check needs the network, so CI runs it as the job `conformance-relock`
# (tests/relock.sh).
{
  pkgs,
  # The flake's composed library, which has `lib.deno-purifier` and the
  # shared purifier library as `lib.purifier`.
  lib,
  # The flake's default package overlay, which adds the builder and the
  # commands.
  overlay,
  # The source of deployctl at the commit tests/dependencies pins.
  deployctl,
}:
let
  inherit (lib) purifier;
  withOverlay = pkgs.extend overlay;
  inherit (withOverlay) buildDenoProject;

  commands = withOverlay.deno-purifier.deno-purifier;

  # A workspace: a root with a build task that runs esbuild (whose native
  # binary comes from a per-platform npm package), a package published to
  # JSR that depends on an npm package, and a command-line member that
  # imports the package, a JSR package, a remote module, a remote URL that
  # redirects and a data: URL, and whose task compiles it.
  app = buildDenoProject {
    src = ./fixtures/app;
    buildTasks = [ "build" ];
  };

  # A project whose npm dependencies come from package.json, which Deno
  # installs into node_modules, with a task that compiles it.
  nodeModules = buildDenoProject {
    src = ./fixtures/node-modules;
  };

  # deployctl, a real-world project: a deno.jsonc with comments, a JSR
  # package with many pinned @std versions and an npm dependency. Its own
  # deno.lock at that commit is out of date for this Deno, so
  # tests/real/deployctl holds the deno.lock `deno-purifier update`
  # wrote, and the lockfile for it, outside deployctl's source. Its code
  # does not type-check with the TypeScript library of this Deno, so the
  # publish check skips type checking.
  real = buildDenoProject {
    src = deployctl;
    lockFile = ./real/deployctl/deno-purifier.lock.json;
    denoLock = ./real/deployctl/deno.lock;
    publishArgs = [ "--no-check" ];
  };

  # The text of a lockfile with its contentHash, as `deno-purifier lock`
  # computes it: the SHA-256 of the text with the empty value.
  seal =
    recorded:
    let
      text = builtins.toJSON (recorded // { contentHash = ""; });
    in
    builtins.replaceStrings
      [ ''"contentHash":""'' ]
      [
        ''"contentHash":"${builtins.hashString "sha256" text}"''
      ]
      text;

  # Reads lockfiles with readLock, into the lock in memory.
  readLockFiles =
    {
      src ? ./fixtures/app,
      denoLock ? ./fixtures/app/deno.lock,
      lockText,
    }:
    lib.deno-purifier.readLock {
      inherit src denoLock;
      lockFile = builtins.toFile "deno-purifier.lock.json" lockText;
    };

  # Evaluates readLock on a deno.lock written inline and a lockfile that
  # records its hash.
  readLock =
    denoLock: recorded:
    let
      text = builtins.toJSON denoLock;
    in
    readLockFiles {
      denoLock = builtins.toFile "deno.lock" text;
      lockText = seal (
        {
          version = 3;
          denoLock = builtins.hashString "sha256" text;
          configs = { };
          jsrRegistry = "https://jsr.io/";
          npmRegistries."" = "https://registry.npmjs.org/";
          members = [ ];
          programs = [ ];
          jsrFiles = { };
          headers = { };
        }
        // recorded
      );
    };

  # A check passes when `assertion` holds; it fails with `message`
  # otherwise.
  evalCheck =
    name: assertion: message:
    if assertion then
      pkgs.runCommand name { } "touch $out"
    else
      throw "deno-purifier check ${name}: ${message}";

  # Whether a lock in memory has a problem that says `what` and names the
  # command to run, and whether the library's checkLock refuses it.
  refusesWith =
    what: lock:
    builtins.any (p: lib.hasInfix what p && lib.hasInfix "run `deno-purifier lock`" p) lock.problems
    && !(builtins.tryEval (builtins.deepSeq (purifier.checkLock lock) true)).success;

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

  appLockText = builtins.readFile ./fixtures/app/deno-purifier.lock.json;
  appLock = builtins.fromJSON appLockText;
  # The app fixture's lockfile, changed by f and sealed again.
  appLockWith = f: seal (removeAttrs (f appLock) [ "contentHash" ]);
  # A JSR module file that the command-line member imports, which only the
  # lockfile records, and its hash.
  pathMod = "https://jsr.io/@std/path/1.1.6/mod.ts";
  pathModHash = appLock.jsrFiles.${pathMod};
  # Another file's hash, a valid SHA-256 that is not that of mod.ts.
  otherHash = lib.findFirst (hash: hash != pathModHash) null (builtins.attrValues appLock.jsrFiles);

  # Links the environment of a project the way `deno-purifier prefetch`
  # does, for the checks that run the commands: a `nix` that answers
  # `nix build --out-link` with the environment and `nix build
  # --print-out-paths` with the release, both built by this flake. It
  # counts its calls in $NIX_CALLS.
  fakeNix =
    { environment, release }:
    pkgs.writeShellScriptBin "nix" ''
      echo call >> "$NIX_CALLS"
      while [ $# -gt 0 ]; do
        case "$1" in
          --out-link)
            ln -sfn ${environment} "$2"
            exit 0
            ;;
          --print-out-paths)
            echo ${release}
            exit 0
            ;;
        esac
        shift
      done
      echo "fake nix: unexpected call" >&2
      exit 1
    '';

  appEnvironment = import ../nix/lib/environment.nix {
    inherit pkgs lib;
    src = ./fixtures/app;
    keep = {
      inherit (pkgs) deno;
      denort = pkgs.deno.denort;
    };
  };

  # A copy of the app fixture in $TMPDIR/project with the commands on PATH,
  # a `nix` that links the environment this flake built, and no network.
  withCommands = ''
    export HOME="$TMPDIR/home" XDG_CACHE_HOME="$TMPDIR/cache" NO_COLOR=1
    export NIX_CALLS="$TMPDIR/nix-calls"
    mkdir -p "$HOME"
    touch "$NIX_CALLS"
    cp -r ${./fixtures/app} "$TMPDIR/project"
    chmod -R u+w "$TMPDIR/project"
    cd "$TMPDIR/project"
  '';
in
{
  # The unit tests of the lock run's parsing, cache-file and hash logic.
  unit =
    pkgs.runCommand "unit-check"
      {
        nativeBuildInputs = [ pkgs.deno ];
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
        nativeBuildInputs = [ app.packages.hello ];
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
        nativeBuildInputs = [ nodeModules.packages.odd ];
      }
      ''
        test -e ${nodeModules.packages."task:version"}/node_modules/is-odd/package.json
        odd 7 | grep -qx '7 is odd'
        # The task runs the command of an npm package, a script that starts
        # with `#!/usr/bin/env node`.
        grep -qx '1.3.0' ${nodeModules.packages."task:version"}/version.txt
        touch $out
      '';

  # The build task ran esbuild.
  task = pkgs.runCommand "task-check" { } ''
    grep -q 'function greet' ${app.packages."task:build"}/dist/greeting.js
    touch $out
  '';

  # The project's tests pass in the sandbox.
  tests = app.tests;

  # The JSR package holds its module, and `deno publish --dry-run`
  # accepted it.
  package = pkgs.runCommand "package-check" { } ''
    grep -q 'export function greet' ${app.packages."@fixture/greeting"}/mod.ts
    touch $out
  '';

  # The release holds the workspace after the build task, without
  # node_modules.
  release = pkgs.runCommand "release-check" { } ''
    grep -q 'export function greet' ${app.release}/greeting/mod.ts
    grep -q 'function greet' ${app.release}/dist/greeting.js
    test ! -e ${app.release}/node_modules
    touch $out
  '';

  # The packages are the programs, the members with a name and the tasks,
  # the fetches are the entries of the lock in memory, and readLock gives
  # the contract's shape.
  outputs = evalCheck "outputs" (
    (purifier.checkLock (lib.deno-purifier.readLock { src = ./fixtures/app; })).purifier
    == "deno-purifier"
    && app.fetches == (lib.deno-purifier.readLock { src = ./fixtures/app; }).entries
    &&
      builtins.attrNames app.packages == [
        "@fixture/greeting"
        "hello"
        "task:build"
        "task:cli:compile"
      ]
    && builtins.any (e: (e.url or "") == "https://deno.land/std@0.224.0/fmt/colors.ts") app.fetches
    && builtins.any (e: (e.url or "") == "https://jsr.io/@std/path/1.1.6_meta.json") app.fetches
    && builtins.any (e: (e.url or "") == pathMod) app.fetches
    && builtins.any (e: e ? archive) app.fetches
  ) "the packages or the fetches differ from those the fixture declares";

  # deployctl's JSR package passes `deno publish --dry-run`.
  deployctl-package = real.packages."@deno/deployctl";

  # deployctl's release task, which compares the version in its source with
  # the release tag, runs offline.
  deployctl-task = real.packages."task:version-match".overrideAttrs { RELEASE_TAG = "1.13.1"; };

  # deployctl's command-line tool runs from its source and the locked
  # downloads, offline.
  deployctl-cli =
    let
      environment = import ../nix/lib/environment.nix {
        inherit pkgs lib;
        src = deployctl;
        lockFile = ./real/deployctl/deno-purifier.lock.json;
        denoLock = ./real/deployctl/deno.lock;
      };
    in
    pkgs.runCommand "deployctl-cli-check"
      {
        nativeBuildInputs = [ pkgs.deno ];
      }
      ''
        export HOME="$TMPDIR" DENO_DIR="$TMPDIR/deno-dir" DENO_NO_UPDATE_CHECK=1 NO_COLOR=1
        mkdir -p "$DENO_DIR"
        cp -rs --no-preserve=mode ${environment.cache}/remote "$DENO_DIR/remote"
        cp -rL ${environment.cache}/npm "$DENO_DIR/npm"
        chmod -R u+w "$DENO_DIR/npm"
        cp -r ${deployctl} deployctl
        chmod -R u+w deployctl
        cp ${./real/deployctl/deno.lock} deployctl/deno.lock
        cd deployctl
        deno run --cached-only --frozen --no-check -A deployctl.ts --version | grep -q 1.13.1
        touch $out
      '';

  # Only the npm packages for the platform are fetched.
  platform-filter =
    let
      urls = system: map (d: d.archive.url) (purifier.entriesFor system (readLock esbuildLock { }));
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
        (readLock
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
        ).entries;
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
        (readLock {
          version = "5";
          npm."left-pad@1.3.0" = {
            integrity = "sha512-AAAA";
            tarball = "https://mirror.example/left-pad-1.3.0.tgz";
          };
        } { }).entries;
    in
    evalCheck "tarball-url" (
      (builtins.head downloads).archive.url == "https://mirror.example/left-pad-1.3.0.tgz"
    ) "the tarball URL of deno.lock was not used";

  # A deno.lock or a deno.json that changed since the lock run stops
  # evaluation, with the command to run.
  conformance-stale = evalCheck "conformance-stale" (
    refusesWith "deno.lock changed" (readLockFiles {
      denoLock = builtins.toFile "deno.lock" (builtins.toJSON esbuildLock);
      lockText = appLockText;
    })
    && refusesWith "deno.json changed" (readLockFiles {
      lockText = appLockWith (
        l:
        l
        // {
          configs = l.configs // {
            "deno.json" = "0";
          };
        }
      );
    })
  ) "a stale lockfile evaluated, or its message does not name `deno-purifier lock`";

  # A lockfile in which a download's hash was changed stops evaluation,
  # with the command to run.
  conformance-tampered = evalCheck "conformance-tampered" (
    otherHash != null
    && refusesWith "does not match its contentHash" (readLockFiles {
      lockText = builtins.replaceStrings [ pathModHash ] [ otherHash ] appLockText;
    })
  ) "a lockfile with a changed hash evaluated, or its message does not name `deno-purifier lock`";

  # A build whose lockfile lacks a module the project imports fails, and
  # says to run the lock again.
  conformance-missing =
    let
      missing = buildDenoProject {
        src = ./fixtures/app;
        lockFile = builtins.toFile "deno-purifier.lock.json" (
          appLockWith (l: l // { jsrFiles = removeAttrs l.jsrFiles [ pathMod ]; })
        );
      };
      failure = pkgs.testers.testBuildFailure missing.packages.hello;
    in
    pkgs.runCommand "conformance-missing-check" { } ''
      grep -q 'not found in cache' ${failure}/testBuildFailure.log
      grep -q 'run `deno-purifier lock`' ${failure}/testBuildFailure.log
      touch $out
    '';

  # A lockfile that is not JSON, one without one of its fields, one with a
  # hash of the wrong kind, and one of another format stop evaluation, with
  # the command to run.
  conformance-malformed = evalCheck "conformance-malformed" (
    refusesWith "has no contentHash" (readLockFiles {
      lockText = builtins.substring 0 100 appLockText;
    })
    && refusesWith "lacks jsrFiles" (readLockFiles {
      lockText = appLockWith (l: removeAttrs l [ "jsrFiles" ]);
    })
    && refusesWith "not a SHA-256 in SRI form" (readLockFiles {
      lockText = appLockWith (
        l:
        l
        // {
          jsrFiles = l.jsrFiles // {
            ${pathMod} = "sha1-${pathModHash}";
          };
        }
      );
    })
    && refusesWith "has format" (readLockFiles {
      lockText = appLockWith (l: l // { version = 2; });
    })
  ) "a malformed lockfile evaluated, or its message does not name `deno-purifier lock`";

  # A second build of a compiled program and of a package, which Nix sees
  # as a different derivation, gives the same output.
  conformance-rebuild =
    let
      again = drv: drv.overrideAttrs { DENO_PURIFIER_REBUILD = "1"; };
    in
    pkgs.runCommand "conformance-rebuild-check" { } ''
      cmp ${app.packages.hello}/bin/hello ${again app.packages.hello}/bin/hello
      diff -r ${app.packages."@fixture/greeting"} ${again app.packages."@fixture/greeting"}
      diff -r ${app.release} ${again app.release}
      touch $out
    '';

  # A fixture whose source holds no lockfile builds from a lockfile kept
  # outside it.
  conformance-external =
    let
      external = buildDenoProject {
        src = lib.cleanSourceWith {
          src = ./fixtures/app;
          filter = path: _: baseNameOf path != "deno-purifier.lock.json";
        };
        lockFile = ./fixtures/app/deno-purifier.lock.json;
      };
    in
    pkgs.runCommand "conformance-external-check"
      {
        nativeBuildInputs = [ external.packages.hello ];
      }
      ''
        test ! -e ${external.packages."task:build"}/deno-purifier.lock.json
        hello 3 | grep -qx 'hello, odd 3 (a/b)'
        touch $out
      '';

  # After `deno-purifier prefetch`, the everyday loop works with no
  # network (the sandbox has none): the wrapper runs a module, the tests
  # and a task, and the language server resolves every import. The
  # prefetch is the only command that calls Nix.
  conformance-offline =
    pkgs.runCommand "conformance-offline-check"
      {
        nativeBuildInputs = [
          commands
          (fakeNix {
            environment = appEnvironment;
            inherit (app) release;
          })
        ];
      }
      ''
        ${withCommands}
        deno-purifier prefetch
        test "$(readlink .deno-purifier/environment)" = ${appEnvironment}
        test -e ${appEnvironment}/deno -a -e ${appEnvironment}/denort
        deno run cli/main.ts 5 | grep -qx 'hello, odd 5 (a/b)'
        deno test
        deno task build
        grep -q 'function greet' dist/greeting.js
        ${pkgs.deno}/bin/deno run -A --no-config --no-lock ${./lsp-check.ts} "$PWD" cli/main.ts greeting/mod.ts
        test "$(wc -l < "$NIX_CALLS")" = 1
        # The cache directory can go; the environment rebuilds it without
        # Nix.
        rm -rf "$XDG_CACHE_HOME"
        deno run cli/main.ts 6 | grep -qx 'hello, even 6 (a/b)'
        test "$(wc -l < "$NIX_CALLS")" = 1
        touch $out
      '';

  # The wrapper stops a command that loads modules while deno.lock differs
  # from the one the lock run read, and names the command to run.
  stale-wrapper =
    pkgs.runCommand "stale-wrapper-check"
      {
        nativeBuildInputs = [
          commands
          (fakeNix {
            environment = appEnvironment;
            inherit (app) release;
          })
        ];
      }
      ''
        ${withCommands}
        echo ' ' >> deno.lock
        if deno run cli/main.ts 5 2> err; then exit 1; fi
        grep -q 'run `deno-purifier lock`' err
        touch $out
      '';

  # `deno-purifier publish` builds the release through Nix and runs `deno
  # publish` on it.
  publish =
    pkgs.runCommand "publish-check"
      {
        nativeBuildInputs = [
          commands
          (fakeNix {
            environment = appEnvironment;
            inherit (app) release;
          })
        ];
      }
      ''
        ${withCommands}
        deno-purifier prefetch
        deno-purifier publish --dry-run --allow-dirty 2>&1 | tee out
        grep -q '@fixture/greeting' out
        touch $out
      '';
}
