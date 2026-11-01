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
#   { buildDenoProject }: (buildDenoProject { src = ./.; }).programs.my-app
#
# and `buildDenoProject.override` replaces what it takes from the set. The
# builder returns
#
#   cache            the DENO_DIR of the locked downloads
#   project          the project after `deno install`, the build tasks and,
#                    with doCheck, `deno test`
#   packages.<name>  each package of the project with a `name` in its
#                    deno.json (the root or a workspace member): the files
#                    of its directory after the build tasks, once
#                    `deno publish --dry-run` accepts them
#   programs.<name>  each `deno compile` command in the tasks, compiled:
#                    bin/<name> is the binary the command writes
#   tasks.<name>     the project after `deno task <name>`; a task of a
#                    workspace member is tasks."<member dir>:<name>"
{
  lib,
  stdenv,
  callPackage,
  deno,
}:
{
  # The root of the Deno project: the directory of its deno.lock.
  src,
  lockFile ? src + "/deno.lock",
  purifierLockFile ? src + "/deno-purifier.lock.json",
  # The Deno that installs, builds, tests and compiles the project. Its
  # `denort` output is the runtime of compiled programs.
  denoPackage ? deno,
  # The tasks that build the project, run in order at the root before the
  # packages are taken and the tests run.
  buildTasks ? [ ],
  # Runs `deno test` after the build tasks.
  doCheck ? false,
  # Arguments of `deno test`, such as permission flags.
  testArgs ? [ ],
  # Arguments of `deno install`, such as `--allow-scripts` for npm packages
  # whose install scripts must run.
  installArgs ? [ ],
  # Arguments of the `deno publish --dry-run` that checks each package, such
  # as `--no-check` for a package that does not type-check with this Deno.
  publishArgs ? [ ],
  # Tools the tasks and the npm packages' install scripts need.
  nativeBuildInputs ? [ ],
  # Libraries native npm addons link against.
  buildInputs ? [ ],
  # Replaces the fetcher of the locked downloads, such as for a private
  # registry that needs credentials.
  fetchurl ? null,
  # Filters the project root before it is copied into the store, as the
  # `filter` of builtins.path. The default leaves out installed
  # dependencies, version control and Nix result links.
  srcFilter ? null,
}:
let
  lock = import ./lock.nix {
    inherit
      lib
      src
      lockFile
      purifierLockFile
      ;
    platform = stdenv.hostPlatform;
  };

  cache = callPackage ./cache.nix (
    {
      inherit lock;
    }
    // lib.optionalAttrs (fetchurl != null) { inherit fetchurl; }
  );

  defaultSrcFilter =
    path: type:
    let
      name = baseNameOf path;
    in
    !((type == "directory" && name == "node_modules") || name == ".git" || lib.hasPrefix "result" name);

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
    # A deno.lock given apart from the source, such as an updated one for a
    # project whose own deno.lock is out of date, replaces the one in the
    # source, so that Deno reads the lockfile Nix read.
    postPatch = lib.optionalString (lockFile != src + "/deno.lock") ''
      cp ${lockFile} deno.lock
      chmod u+w deno.lock
    '';
  };

  buildCommands = ''
    ${denoSetup}
    ${runTask}
    for task in ${lib.escapeShellArgs buildTasks}; do
      runTask "" "$task"
    done
  '';

  project = stdenv.mkDerivation (
    common
    // {
      name = "deno-project";
      buildPhase = ''
        runHook preBuild
        ${buildCommands}
        ${lib.optionalString doCheck "deno test --frozen --cached-only ${lib.escapeShellArgs testArgs}"}
        runHook postBuild
      '';
      installPhase = ''
        runHook preInstall
        cp -a . "$out"
        runHook postInstall
      '';
      dontFixup = true;
    }
  );

  storeSafe = name: builtins.replaceStrings [ "@" "/" ":" ] [ "" "-" "-" ] name;

  mkPackage =
    member:
    stdenv.mkDerivation (
      common
      // {
        pname = storeSafe member.name;
        version = if member.version != null then member.version else "0.0.0";
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
        dontFixup = true;
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
        version =
          let
            member = lib.findFirst (m: m.dir == program.member) null lock.members;
          in
          if member != null && member.version != null then member.version else "0.0.0";
        buildPhase = ''
          runHook preBuild
          ${buildCommands}
          mkdir -p "$out/bin"
          (cd ./${lib.escapeShellArg program.member} && deno compile --frozen --cached-only \
            ${lib.escapeShellArgs program.flags} \
            --output "$out/bin"/${lib.escapeShellArg program.name} \
            ${lib.escapeShellArg program.entrypoint} ${lib.escapeShellArgs program.args})
          runHook postBuild
        '';
        dontInstall = true;
        # A compiled program is denort with the project appended; stripping
        # or patching it would cut the project off.
        dontFixup = true;
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
        dontFixup = true;
      }
    );

  named = builtins.filter (m: m.name != null) lock.members;
in
{
  inherit cache project;
  packages = lib.listToAttrs (map (m: lib.nameValuePair m.name (mkPackage m)) named);
  programs = lib.listToAttrs (map (p: lib.nameValuePair p.name (mkProgram p)) lock.programs);
  tasks = lib.listToAttrs (
    lib.concatMap (
      m: map (t: lib.nameValuePair (if m.dir == "" then t else "${m.dir}:${t}") (mkTask m t)) m.tasks
    ) lock.members
  );
}
