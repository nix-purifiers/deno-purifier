# SPDX-License-Identifier: MIT
#
# buildDenoProject: sandboxed builds of a Deno project, from its deno.lock
# and the deno-purifier.lock.json that `deno-purifier lock` writes beside
# it. The project needs no Nix files of its own: the two lockfiles name
# every download, every package of the project and every program its tasks
# compile.
#
# The flake's library has it as `lib.deno-purifier.buildDenoProject`:
#
#   (lib.deno-purifier.buildDenoProject { inherit pkgs; src = ./.; })
#     .packages.my-app
#
# The builder returns
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
# `lib` is the composed library, which has the shared purifier library as
# `lib.purifier`.
{ lib }:
{
  pkgs,
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
  denoPackage ? pkgs.deno,
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
  inherit (pkgs) stdenv;

  lock = import ./lock.nix {
    inherit
      lib
      src
      lockFile
      denoLock
      ;
    inherit (lib) purifier;
    platform = stdenv.hostPlatform;
  };

  cache = import ./cache.nix {
    inherit pkgs lock fetchers;
    inherit (lib) purifier;
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
    export DENORT_BIN=${denoPackage.denort}/bin/denort
    mkdir -p "$HOME" "$DENO_DIR"
    if [ -d ${cache}/remote ]; then
      cp -rs --no-preserve=mode ${cache}/remote "$DENO_DIR/remote"
    fi
    if [ -d ${cache}/npm ]; then
      cp -rL ${cache}/npm "$DENO_DIR/npm"
      chmod -R u+w "$DENO_DIR/npm"
    fi
    # Deno's error for a module missing from the locked downloads names the
    # module only; the build adds what to run.
    deno() {
      local status=0
      command deno "$@" 2> >(tee -a "$TMPDIR/deno-errors" >&2) || status=$?
      wait
      if [ "$status" != 0 ] && grep -q 'not found in cache' "$TMPDIR/deno-errors"; then
        echo "deno-purifier: Deno needs a module that deno-purifier.lock.json does not record; run \`deno-purifier lock\` at the project root and commit the result." >&2
      fi
      return "$status"
    }
    deno install --frozen --cached-only ${lib.escapeShellArgs installArgs}
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

  named = builtins.filter (m: m.name != null) lock.members;

  versionOf =
    dir:
    let
      member = lib.findFirst (m: m.dir == dir) null lock.members;
    in
    if member != null && member.version != null then member.version else "0.0.0";

  mkPackage =
    member:
    stdenv.mkDerivation (
      common
      // {
        pname = storeSafe member.name;
        version = versionOf member.dir;
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
    program:
    stdenv.mkDerivation (
      common
      // {
        pname = program.name;
        version = versionOf program.member;
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
    member: task:
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
        deno test --frozen --cached-only ${lib.escapeShellArgs testArgs}
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
    if named == [ ] then
      throw "deno-purifier: the project has no package with a `name` in its deno.json, so it has no release to publish"
    else
      stdenv.mkDerivation (
        common
        // {
          pname = "deno-release";
          version = versionOf "";
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

  programs = map (p: lib.nameValuePair p.name (mkProgram p)) lock.programs;
  jsrPackages = map (m: lib.nameValuePair m.name (mkPackage m)) named;
  taskOutputs = lib.concatMap (
    m:
    map (
      t: lib.nameValuePair (if m.dir == "" then "task:${t}" else "task:${m.dir}:${t}") (mkTask m t)
    ) m.tasks
  ) lock.members;
  all = programs ++ jsrPackages ++ taskOutputs;
  names = map (p: p.name) all;
  clash = lib.findFirst (n: lib.count (m: m == n) names > 1) null names;
in
{
  packages =
    if clash != null then
      throw "deno-purifier: more than one output of the project is named ${builtins.toJSON clash}"
    else
      builtins.listToAttrs all;
  inherit tests release;
  fetches = lock.downloads;
}
