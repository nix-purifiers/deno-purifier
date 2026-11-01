# SPDX-License-Identifier: MIT
#
# The flake's checks. Every one builds in the sandbox; the only network
# access is the fixed-output fetches of locked downloads.
{
  pkgs,
  # The flake's default package overlay, which adds buildDenoProject.
  overlay,
}:
let
  inherit (pkgs) lib;

  # The fixture builds the way a consumer's package does: through
  # buildDenoProject of a package set the overlay applies to.
  withOverlay = pkgs.extend overlay;
  inherit (withOverlay) buildDenoProject;

  # A workspace: a root with a build task that runs esbuild (whose native
  # binary comes from a per-platform npm package), a package published to
  # JSR that depends on an npm package, and a command-line member that
  # imports the package, a JSR package and a remote module, and whose task
  # compiles it.
  app = buildDenoProject {
    src = ./fixtures/app;
    buildTasks = [ "build" ];
    doCheck = true;
  };

  # A project whose npm dependencies come from package.json, which Deno
  # installs into node_modules, with a task that compiles it.
  nodeModules = buildDenoProject { src = ./fixtures/node-modules; };

  # Evaluates the lockfile reader on lockfiles written inline. The purifier
  # lockfile records the hash of the deno.lock it goes with.
  readLock =
    platform: denoLock: purifier:
    let
      text = builtins.toJSON denoLock;
    in
    import ../nix/lib/lock.nix {
      inherit lib platform;
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
          // purifier
        )
      );
    };
  host = pkgs.stdenv.hostPlatform;

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
in
{
  # The compiled program runs: it finds the workspace package, the npm
  # package it depends on, the JSR package and the remote module.
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
  # keeps them under the host of that registry.
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

  # A deno.lock that changed since the lock run stops evaluation.
  stale-lock =
    let
      result = builtins.tryEval (
        builtins.deepSeq
          (import ../nix/lib/lock.nix {
            inherit lib;
            platform = host;
            src = ./fixtures/app;
            lockFile = builtins.toFile "deno.lock" (builtins.toJSON esbuildLock);
            purifierLockFile = ./fixtures/app/deno-purifier.lock.json;
          }).downloads
          true
      );
    in
    evalCheck "stale-lock" (!result.success) "a deno.lock that changed since the lock run evaluated";

  # The wrapper evaluates nix/lib/interactive.nix for a project; the tree
  # it builds is the one the sandboxed build of the project uses.
  interactive =
    let
      tree = import ../nix/lib/interactive.nix {
        inherit pkgs;
        src = ./fixtures/app;
      };
    in
    evalCheck "interactive" (
      tree.outPath == app.cache.outPath
    ) "the tree the wrapper builds differs from the tree the build uses";

  # The commands build.
  deno-purifier = withOverlay.deno-purifier.deno-purifier;
}
