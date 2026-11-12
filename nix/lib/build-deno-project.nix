# SPDX-License-Identifier: MIT
#
# buildDenoProject: sandboxed builds of a Deno project, from its deno.lock
# and the deno-purifier.lock.json that `deno-purifier lock` writes beside
# it. The project needs no Nix files of its own: the two lockfiles name
# every download, every package of the project and every program its tasks
# compile.
#
# The file is a package for callPackage: the first argument set is what it
# takes from the package set, and the result is the builder. The
# deno-purifier overlay (`overlays.default`) adds it to the package set as
# `buildDenoProject`, so a package written for callPackage takes it like
# any other dependency:
#
#   { buildDenoProject }: (buildDenoProject { src = ./.; }).packages.my-app
#
# and `buildDenoProject.override` replaces what it takes from the set. The
# builder returns
#
#   packages   what the project builds:
#                <program>      each `deno compile` command in the tasks,
#                               compiled; bin/<program> is the binary the
#                               command writes
#                <package>      each package of the project with a `name`
#                               in its deno.json (the root or a workspace
#                               member), such as "@scope/name": the files
#                               of its directory after the build tasks,
#                               once `deno publish --dry-run` accepts them
#                task:<task>    the project after `deno task <task>`; a
#                               task of a workspace member is
#                               "task:<member dir>:<task>"
#   tests      the project after the build tasks and `deno test`
#   release    what `deno-purifier publish` uploads to JSR: the project
#              after the build tasks, once `deno publish --dry-run` at the
#              root accepts every package
#   fetches    the download entries of the purifier library that the build
#              fetches, for SBOM, license and vulnerability tools
#
# The names of `packages` come from the lockfile, so they are known at
# evaluation time.
#
{
  pkgs,
  nativeTools ? ../../src,
  lib,
  stdenv,
  runCommand,
  fetchurl,
  unzip,
  zstd,
  python3,
  writeText,
  deno,
  # The `purifier` namespace of the shared purifier library, and `readLock`
  # of the deno-purifier library namespace, which the overlay passes.
  purifier,
  readLock,
}:
{
  # The root of the Deno project.
  src,
  # deno-purifier.lock.json. A lockfile kept outside `src`, such as in a
  # packaging flake for a project whose author does not use deno-purifier,
  # is the one the build reads.
  lockFile ? src + "/deno-purifier.lock.json",
  # deno.lock. One given outside `src` replaces the one in `src` during the
  # build, such as an updated one for a project whose own deno.lock is out
  # of date.
  denoLock ? src + "/deno.lock",
  # The fetchers that replace nixpkgs' own in the purifier library, such as
  # a fetchurl that goes through a company mirror or sends credentials.
  fetchers ? { },
  # The Deno that installs, builds, tests and compiles the project. Its
  # `denort` output is the runtime of compiled programs.
  denoPackage ? deno,
  # The tasks that build the project, run in order at the root before the
  # packages, the release and the tests are taken.
  buildTasks ? [ ],
  # Arguments of `deno test`, such as permission flags.
  testArgs ? [ ],
  # Arguments of `deno install`, such as `--allow-scripts` for npm packages
  # whose install scripts must run.
  installArgs ? [ ],
  # Arguments of the `deno publish --dry-run` that checks the packages and
  # the release, such as `--no-check` for a package that does not
  # type-check with this Deno.
  publishArgs ? [ ],
  # Tools the tasks and the npm packages' install scripts need.
  nativeBuildInputs ? [ ],
  # Libraries native npm addons link against.
  buildInputs ? [ ],
  # Filters the project root before it is copied into the store, as the
  # `filter` of builtins.path. The default leaves out installed
  # dependencies, version control, the wrapper's garbage-collector roots
  # and Nix result links.
  srcFilter ? null,
}:
let
  # The lock in memory of the purifier contract; checkLock fails evaluation
  # with its problems.
  lock = purifier.checkLock (readLock {
    inherit src lockFile denoLock;
  });

  native = (lib.importJSON lockFile).native or null;
  verification = import ./native-sdk-check.nix {
    inherit
      pkgs
      denoPackage
      native
      nativeTools
      ;
  };
  compileRuntime =
    if builtins.isAttrs denoPackage && denoPackage ? denort then denoPackage.denort else null;

  cache = import ./cache.nix {
    inherit
      lib
      runCommand
      fetchurl
      unzip
      zstd
      python3
      writeText
      purifier
      fetchers
      ;
    inherit verification;
    entries = purifier.entriesFor stdenv.hostPlatform.system lock;
  };

  defaultSrcFilter =
    path: type:
    let
      name = baseNameOf path;
    in
    !(
      (type == "directory" && name == "node_modules")
      || name == ".git"
      || name == ".deno-purifier"
      || lib.hasPrefix "result" name
    );

  filteredSrc = builtins.path {
    path = src;
    name = "deno-source";
    filter = if srcFilter != null then srcFilter else defaultSrcFilter;
  };

  # The setup every build shares. Deno writes its transpiled modules and
  # analysis databases into DENO_DIR, so DENO_DIR is writable. Its remote
  # modules are links to the cache, since Deno looks them up by URL. Its
  # npm packages are copies: Deno tells which package a file belongs to by
  # the real path of the file, which must lie inside DENO_DIR. `deno
  # compile` takes the runtime it embeds from DENORT_BIN rather than
  # downloading one.
  denoSetup = ''
    export HOME="$TMPDIR/home"
    export DENO_DIR="$TMPDIR/deno-dir"
    export DENO_NO_UPDATE_CHECK=1
    export NO_COLOR=1
    ${lib.optionalString (compileRuntime != null) "export DENORT_BIN=${compileRuntime}/bin/denort"}
    mkdir -p "$HOME" "$DENO_DIR"
    if [ -d ${cache}/remote ]; then
      cp -rs --no-preserve=mode ${cache}/remote "$DENO_DIR/remote"
    fi
    if [ -d ${cache}/deps ]; then
      cp -rs --no-preserve=mode ${cache}/deps "$DENO_DIR/deps"
    fi
    if [ -d ${cache}/npm ]; then
      cp -rL ${cache}/npm "$DENO_DIR/npm"
      chmod -R u+w "$DENO_DIR/npm"
    fi
    # Deno's error for a module missing from the locked downloads names the
    # module only; the build adds what to run.
    deno() {
      local status=0
      ${denoPackage}/bin/deno "$@" 2> >(tee -a "$TMPDIR/deno-errors" >&2) || status=$?
      wait
      if [ "$status" != 0 ] && grep -q 'not found in cache' "$TMPDIR/deno-errors"; then
        echo "deno-purifier: Deno needs a module that deno-purifier.lock.json does not record; run \`deno-purifier lock\` at the project root and commit the result." >&2
      fi
      return "$status"
    }
    ${
      if native != null && !native.capabilities.install then
        "${denoPackage}/bin/deno cache --lock=deno.lock ${lib.optionalString native.capabilities.frozen "--frozen"} ${lib.escapeShellArgs native.modules}"
      else
        "deno install --frozen --cached-only ${lib.escapeShellArgs installArgs}"
    }
  '';

  # Runs task $2 of the member in directory $1 ("" for the root).
  runTask = ''
    runTask() {
      (cd "./$1" && deno task "$2")
    }
  '';

  common = {
    src = filteredSrc;
    nativeBuildInputs = [ denoPackage ] ++ nativeBuildInputs;
    inherit buildInputs;
    dontConfigure = true;
    # Deno reads deno.lock from the source, so a deno.lock given apart from
    # the source replaces the one there.
    postPatch = lib.optionalString (denoLock != src + "/deno.lock") ''
      cp ${denoLock} deno.lock
      chmod u+w deno.lock
    '';
    dontFixup = true;
  };

  buildCommands = ''
    ${denoSetup}
    ${runTask}
    for task in ${lib.escapeShellArgs buildTasks}; do
      runTask "" "$task"
    done
  '';

  storeSafe = name: builtins.replaceStrings [ "@" "/" ":" ] [ "" "-" "-" ] name;

  jsrPackages = builtins.filter (o: o.kind == "package") (builtins.attrValues lock.outputs);
  rootPackage = lib.findFirst (o: o.member.dir == "") null jsrPackages;

  mkPackage =
    { member, version, ... }:
    assert
      native == null
      || native.capabilities.publish
      || throw "selected native SDK has no publish capability";
    stdenv.mkDerivation (
      common
      // {
        pname = storeSafe member.name;
        inherit version;
        buildPhase = ''
          runHook preBuild
          ${buildCommands}
          (cd ./${lib.escapeShellArg member.dir} && deno publish --dry-run --allow-dirty --frozen ${lib.escapeShellArgs publishArgs})
          runHook postBuild
        '';
        installPhase = ''
          runHook preInstall
          cp -a ./${lib.escapeShellArg member.dir}/. "$out"
          rm -rf "$out/node_modules"
          runHook postInstall
        '';
        passthru = {
          inherit (member) name dir;
        };
      }
    );

  mkProgram =
    { program, version, ... }:
    assert
      native == null
      || native.capabilities.compile
      || throw "selected native SDK has no compile capability";
    assert compileRuntime != null || throw "selected Deno SDK has no offline compile runtime";
    stdenv.mkDerivation (
      common
      // {
        pname = program.name;
        inherit version;
        buildPhase = ''
          runHook preBuild
          ${buildCommands}
          # deno compile embeds the modification time of every file it
          # packs, and the copies in DENO_DIR and the files the build wrote
          # have the time of the build.
          find . "$DENO_DIR" -exec touch -h -d "@$SOURCE_DATE_EPOCH" {} +
          mkdir -p "$out/bin"
          (cd ./${lib.escapeShellArg program.member} && deno compile --frozen --cached-only \
            ${lib.escapeShellArgs program.flags} \
            --output "$out/bin"/${lib.escapeShellArg program.name} \
            ${lib.escapeShellArg program.entrypoint} ${lib.escapeShellArgs program.args})
          runHook postBuild
        '';
        # A compiled program is denort with the project appended; stripping
        # or patching it would cut the project off.
        dontInstall = true;
        meta.mainProgram = program.name;
      }
    );

  mkTask =
    { member, task, ... }:
    assert
      native == null || native.capabilities.task || throw "selected native SDK has no task capability";
    stdenv.mkDerivation (
      common
      // {
        name = "deno-task-${storeSafe (if member.dir == "" then task else "${member.dir}-${task}")}";
        buildPhase = ''
          runHook preBuild
          ${buildCommands}
          runTask ${lib.escapeShellArg member.dir} ${lib.escapeShellArg task}
          runHook postBuild
        '';
        installPhase = ''
          runHook preInstall
          cp -a . "$out"
          runHook postInstall
        '';
      }
    );

  tests = stdenv.mkDerivation (
    common
    // {
      name = "deno-tests";
      buildPhase = ''
        runHook preBuild
        ${buildCommands}
        ${denoPackage}/bin/deno test ${
          lib.optionalString (native == null || native.capabilities.frozen) "--frozen"
        } --lock=deno.lock --cached-only ${lib.escapeShellArgs testArgs}
        runHook postBuild
      '';
      installPhase = ''
        runHook preInstall
        cp -a . "$out"
        runHook postInstall
      '';
    }
  );

  release =
    assert
      native == null
      || native.capabilities.publish
      || throw "selected native SDK has no publish capability";
    if jsrPackages == [ ] then
      throw "deno-purifier: the project has no package with a `name` in its deno.json, so it has no release to publish"
    else
      stdenv.mkDerivation (
        common
        // {
          pname = "deno-release";
          version = if rootPackage != null then rootPackage.version else "0.0.0";
          buildPhase = ''
            runHook preBuild
            ${buildCommands}
            deno publish --dry-run --allow-dirty --frozen ${lib.escapeShellArgs publishArgs}
            runHook postBuild
          '';
          installPhase = ''
            runHook preInstall
            rm -rf node_modules
            cp -a . "$out"
            runHook postInstall
          '';
        }
      );

  build = {
    program = mkProgram;
    package = mkPackage;
    task = mkTask;
  };
in
assert
  native != null
  || toString denoPackage == toString deno
  || throw "selected Deno SDK needs a lock captured with that SDK";
{
  packages = builtins.mapAttrs (_: output: build.${output.kind} output) lock.outputs;
  inherit tests release;
  fetches = lock.entries;
}
