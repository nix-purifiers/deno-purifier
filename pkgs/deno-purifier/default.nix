# SPDX-License-Identifier: MIT
#
# The command-line side of deno-purifier, two commands in bin/:
#
#   deno-purifier   `lock` records the project's downloads in
#                   deno-purifier.lock.json (src/deno-purifier.ts);
#                   `update` updates the dependencies with `deno update`
#                   and then records the downloads; `prefetch` realizes what the everyday loop and the
#                   editor read (nix/lib/environment.nix) and links it into
#                   the project as .deno-purifier/environment, a
#                   garbage-collector root; `publish` builds the release
#                   with Nix and runs `deno publish` on it.
#   deno            Deno, wrapped so that in a project with a
#                   deno-purifier.lock.json it reads the locked downloads
#                   from the Nix store and nothing from the network.
#
# The wrapper keeps the project's DENO_DIR under
# $XDG_CACHE_HOME/deno-purifier, made from .deno-purifier/environment. When
# the environment is missing or older than the lockfiles, the wrapper runs
# the prefetch first. It passes --cached-only to the commands that load
# modules, and stops them while deno.lock differs from the one the lock run
# read. The commands that change dependencies (add, remove, outdated,
# update, upgrade, and install with a package or --global) run as Deno runs
# without the wrapper. DENO_PURIFIER=0 turns the wrapper off.
{
  lib,
  writeShellApplication,
  writeText,
  runCommand,
  deno,
  coreutils,
  gnugrep,
  path,
  stdenv,
}:
let
  # The commands evaluate outside this flake, so they fetch the shared
  # purifier library at the revision this flake locks, the one the
  # sandboxed builds use.
  purifierLocked = writeText "purifier-locked.json" (
    builtins.toJSON (lib.importJSON ../../flake.lock).nodes.purifier.locked
  );

  # The shell functions the two commands share.
  common = ''
    deno=${lib.getExe deno}
    LOCK_FILE="deno-purifier.lock.json"

    fail() {
      echo "deno-purifier: $*" >&2
      exit 1
    }

    sha256() {
      sha256sum | cut -d' ' -f1
    }

    # The hash of deno.lock that the lockfile $1 records.
    lockedDenoLock() {
      grep -o '"denoLock": "[0-9a-f]*"' "$1" | grep -o '[0-9a-f]\{64\}' || true
    }

    # Whether the deno.lock of root $1 is the one the lockfile $2 records.
    denoLockMatches() {
      [ "$(sha256 < "$1/deno.lock")" = "$(lockedDenoLock "$2")" ]
    }

    # What the environment and the DENO_DIR of root $1 with lockfile $2
    # were made from.
    stampOf() {
      cat "$1/deno.lock" "$2" | sha256
    }

    # The DENO_DIR of root $1.
    denoDirOf() {
      echo "''${XDG_CACHE_HOME:-$HOME/.cache}/deno-purifier/$(printf '%s' "$1" | sha256 | cut -c1-32)"
    }

    # Builds .deno-purifier/environment of root $1 with lockfile $2 through
    # Nix, the garbage-collector root of everything the everyday loop and
    # the editor read.
    buildEnvironment() {
      local root="$1" lockfile="$2" state="$1/.deno-purifier"
      echo "deno-purifier: building the environment of $root" >&2
      mkdir -p "$state"
      # The directory holds links into the store and nothing to commit.
      printf '*\n' > "$state/.gitignore"
      DENO_PURIFIER_ROOT="$root" DENO_PURIFIER_LOCKFILE="$lockfile" \
        nix build --impure --out-link "$state/environment" --expr '
          (import ${../../nix/lib}/commands.nix {
            nixpkgs = ${path};
            system = "${stdenv.hostPlatform.system}";
            purifierSource = (builtins.fetchTree (builtins.fromJSON (builtins.readFile ${purifierLocked}))).outPath;
            root = builtins.getEnv "DENO_PURIFIER_ROOT";
            lockFile = builtins.getEnv "DENO_PURIFIER_LOCKFILE";
            deno = "${deno}";
            denort = "${deno.denort}";
          }).environment
        ' || fail "building the environment failed; the message above says why."
      if [ "$lockfile" != "$root/$LOCK_FILE" ]; then
        ln -sfn "$lockfile" "$state/lockfile"
      fi
      stampOf "$root" "$lockfile" > "$state/stamp"
    }

    # Makes the DENO_DIR of root $1 from its environment. Deno writes
    # transpiled modules and analysis databases into DENO_DIR, so DENO_DIR
    # is writable. Its remote modules are links into the store, since Deno
    # looks them up by URL. Its npm packages are copies: Deno tells which
    # package a file belongs to by the real path of the file, which must
    # lie inside DENO_DIR.
    makeDenoDir() {
      local root="$1" stamp="$2" dir
      dir="$(denoDirOf "$root")"
      chmod -R u+w "$dir" 2> /dev/null || true
      rm -rf "$dir"
      mkdir -p "$dir/deno-dir"
      if [ -d "$root/.deno-purifier/environment/cache/remote" ]; then
        cp -rs --no-preserve=mode "$root/.deno-purifier/environment/cache/remote" "$dir/deno-dir/remote"
      fi
      if [ -d "$root/.deno-purifier/environment/cache/npm" ]; then
        cp -rL "$root/.deno-purifier/environment/cache/npm" "$dir/deno-dir/npm"
        chmod -R u+w "$dir/deno-dir/npm"
      fi
      printf '%s\n' "$stamp" > "$dir/stamp"
    }

    # Makes sure root $1 with lockfile $2 has an environment and a DENO_DIR
    # made from its current lockfiles. With the environment in place, this
    # needs neither Nix nor the network.
    prepare() {
      local root="$1" lockfile="$2" stamp
      stamp="$(stampOf "$root" "$lockfile")"
      if [ ! -e "$root/.deno-purifier/environment/cache" ] \
        || [ "$(cat "$root/.deno-purifier/stamp" 2> /dev/null || true)" != "$stamp" ]; then
        buildEnvironment "$root" "$lockfile"
      fi
      if [ "$(cat "$(denoDirOf "$root")/stamp" 2> /dev/null || true)" != "$stamp" ]; then
        makeDenoDir "$root" "$stamp"
      fi
    }

    # The nearest directory upwards from $1 with a deno.lock.
    findRoot() {
      local dir="$1"
      while [ ! -f "$dir/deno.lock" ]; do
        [ "$dir" = / ] && fail "no deno.lock in $1 or above it; run \`deno install\` to write one."
        dir="$(dirname "$dir")"
      done
      echo "$dir"
    }
  '';

  commands = writeShellApplication {
    name = "deno-purifier";
    runtimeInputs = [
      coreutils
      gnugrep
    ];
    text = ''
      ${common}

      usage() {
        cat >&2 << 'EOF'
      usage: deno-purifier lock [--root DIR] [--lockfile PATH] [-- DENO-ARGS...]
             deno-purifier update [--root DIR] [--lockfile PATH] [--latest] [PACKAGE...]
             deno-purifier prefetch [--root DIR] [--lockfile PATH]
             deno-purifier publish [--root DIR] [--lockfile PATH] [DENO-PUBLISH-ARGS...]

        lock      record the project's downloads in deno-purifier.lock.json,
                  with the resolution deno.lock holds
        update    update the dependencies with `deno update`, all of them or
                  each PACKAGE, then record the downloads
        prefetch  realize the locked downloads, Deno and its runtime in the
                  Nix store, with a garbage-collector root in the project,
                  so that the everyday loop and the editor work offline
        publish   build the release with Nix and run `deno publish` on it

      DIR is the project root, by default the nearest directory upwards with
      a deno.lock. PATH is the lockfile, by default deno-purifier.lock.json
      at DIR.
      EOF
        exit 2
      }

      verb="''${1:-}"
      [ $# -gt 0 ] && shift
      case "$verb" in
        lock | update)
          export DENO_NO_UPDATE_CHECK=1
          exec "$deno" run --allow-all --no-config --no-lock \
            ${../../src}/deno-purifier.ts "$verb" "$@"
          ;;
        prefetch | publish) ;;
        *) usage ;;
      esac

      root=
      lockfile=
      while [ $# -gt 0 ]; do
        case "$1" in
          --root)
            [ $# -ge 2 ] || usage
            root="$(realpath "$2")"
            shift 2
            ;;
          --lockfile)
            [ $# -ge 2 ] || usage
            lockfile="$(realpath "$2")"
            shift 2
            ;;
          *) break ;;
        esac
      done
      [ -n "$root" ] || root="$(findRoot "$PWD")"
      [ -n "$lockfile" ] || lockfile="$root/$LOCK_FILE"
      [ -f "$lockfile" ] || fail "$lockfile does not exist; run \`deno-purifier lock\` to write it."

      case "$verb" in
        prefetch)
          [ $# -eq 0 ] || usage
          buildEnvironment "$root" "$lockfile"
          makeDenoDir "$root" "$(stampOf "$root" "$lockfile")"
          echo "deno-purifier: $root/.deno-purifier/environment holds the locked downloads, Deno and its runtime; the deno wrapper and its language server now work offline." >&2
          ;;
        publish)
          prepare "$root" "$lockfile"
          echo "deno-purifier: building the release of $root" >&2
          release="$(
            DENO_PURIFIER_ROOT="$root" DENO_PURIFIER_LOCKFILE="$lockfile" \
              nix build --impure --no-link --print-out-paths --expr '
                (import ${../../nix/lib}/commands.nix {
                  nixpkgs = ${path};
                  system = "${stdenv.hostPlatform.system}";
                  purifierSource = (builtins.fetchTree (builtins.fromJSON (builtins.readFile ${purifierLocked}))).outPath;
                  root = builtins.getEnv "DENO_PURIFIER_ROOT";
                  lockFile = builtins.getEnv "DENO_PURIFIER_LOCKFILE";
                  deno = "${deno}";
                  denort = "${deno.denort}";
                }).release
              '
          )" || fail "building the release failed; the message above says why."
          # deno publish reads its configuration from the working directory,
          # which must be writable.
          work="$(mktemp -d)"
          trap 'chmod -R u+w "$work"; rm -rf "$work"' EXIT
          cp -r "$release/." "$work"
          chmod -R u+w "$work"
          cd "$work"
          DENO_DIR="$(denoDirOf "$root")/deno-dir" DENO_NO_UPDATE_CHECK=1 \
            "$deno" publish "$@"
          ;;
      esac
    '';
  };

  wrapper = writeShellApplication {
    name = "deno";
    runtimeInputs = [
      coreutils
      gnugrep
    ];
    text = ''
      ${common}

      if [ "''${DENO_PURIFIER:-1}" = 0 ]; then
        exec "$deno" "$@"
      fi

      # The first argument that is not an option is the command, and its
      # position is where --cached-only goes.
      command=
      position=0
      for arg in "$@"; do
        case "$arg" in
          -*) position=$((position + 1)) ;;
          *)
            command="$arg"
            break
            ;;
        esac
      done
      case "$command" in
        add | remove | outdated | update | upgrade | "")
          exec "$deno" "$@"
          ;;
        install | i)
          # `deno install <package>` adds a dependency and `--global`
          # installs a command; a plain `deno install` installs the locked
          # dependencies.
          seen=0
          for arg in "$@"; do
            if [ "$seen" = 1 ]; then
              case "$arg" in
                -g | --global) exec "$deno" "$@" ;;
                --entrypoint | -e) break ;;
                -*) ;;
                *) exec "$deno" "$@" ;;
              esac
            fi
            [ "$arg" = "$command" ] && seen=1
          done
          ;;
      esac

      # The project root is the nearest directory upwards with a deno.lock
      # and a lockfile: deno-purifier.lock.json, or the lockfile outside the
      # project that a prefetch linked as .deno-purifier/lockfile.
      dir="$PWD"
      while :; do
        if [ -f "$dir/deno.lock" ]; then
          if [ -f "$dir/$LOCK_FILE" ]; then
            lockfile="$dir/$LOCK_FILE"
            break
          elif [ -f "$dir/.deno-purifier/lockfile" ]; then
            lockfile="$(realpath "$dir/.deno-purifier/lockfile")"
            break
          fi
        fi
        [ "$dir" = / ] && exec "$deno" "$@"
        dir="$(dirname "$dir")"
      done

      loads=0
      case "$command" in
        run | test | check | install | i | cache | bench | compile | info | doc | serve | eval | repl | task | lsp) loads=1 ;;
      esac

      if ! denoLockMatches "$dir" "$lockfile"; then
        if [ "$loads" = 1 ]; then
          fail "deno.lock changed since $lockfile was written; run \`deno-purifier lock\` at $dir to record the change, or DENO_PURIFIER=0 to run Deno with the network."
        fi
        exec "$deno" "$@"
      fi

      prepare "$dir" "$lockfile"

      export DENO_DIR
      DENO_DIR="$(denoDirOf "$dir")/deno-dir"
      export DENORT_BIN=${deno.denort}/bin/denort
      # Deno checks for a newer release over the network; the locked Deno is
      # the one nixpkgs ships.
      export DENO_NO_UPDATE_CHECK=1
      case "$command" in
        run | test | check | install | i | cache | bench | compile | info | doc)
          set -- "''${@:1:$((position + 1))}" --cached-only "''${@:$((position + 2))}"
          # Deno's error for a module missing from the locked downloads
          # names the module only; the wrapper adds what to run.
          errors="$(mktemp)"
          trap 'rm -f "$errors"' EXIT
          status=0
          "$deno" "$@" 2> >(tee "$errors" >&2) || status=$?
          wait
          if [ "$status" != 0 ] && grep -q 'not found in cache' "$errors"; then
            echo "deno-purifier: Deno needs a module that $lockfile does not record; run \`deno-purifier lock\` at $dir to record it, or DENO_PURIFIER=0 to run Deno with the network." >&2
          fi
          exit "$status"
          ;;
        serve | eval | repl)
          set -- "''${@:1:$((position + 1))}" --cached-only "''${@:$((position + 2))}"
          ;;
      esac
      exec "$deno" "$@"
    '';
  };
in
runCommand "deno-purifier-${deno.version}"
  {
    meta.mainProgram = "deno-purifier";
  }
  ''
    mkdir -p "$out/bin"
    ln -s ${lib.getExe commands} "$out/bin/deno-purifier"
    ln -s ${lib.getExe wrapper} "$out/bin/deno"
  ''
