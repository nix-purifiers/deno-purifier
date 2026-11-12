# SPDX-License-Identifier: MIT
#
# The command-line side of deno-purifier, two commands in bin/:
#
#   deno-purifier   `lock` records the project's downloads in
#                   deno-purifier.lock.json (src/deno-purifier.ts);
#                   `update` updates the dependencies with `deno update`
#                   and then records the downloads; `prefetch` realizes
#                   what the development loop and the editor read
#                   (nix/lib/environment.nix) and links it into the
#                   project as .deno-purifier/environment, a
#                   garbage-collector root; `publish` builds the release
#                   with Nix and runs `deno publish` on it.
#   deno            Deno, wrapped so that in a project with a
#                   deno-purifier.lock.json it reads the locked downloads
#                   from the Nix store and nothing from the network.
#
# Every command takes the purifier lockfile as `--lockfile PATH` or
# DENO_PURIFIER_LOCKFILE, and deno.lock as `--tool-lockfile PATH` or
# DENO_PURIFIER_TOOL_LOCKFILE, for a project whose lockfiles live outside
# its tree. A prefetch links them as .deno-purifier/lockfile and
# .deno-purifier/tool-lockfile, which the wrapper follows.
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
  nix,
  coreutils,
  gnugrep,
  path,
  stdenv,
}:
let
  helperDeno = (import path { system = stdenv.hostPlatform.system; }).deno;
  denort = if deno ? denort then toString deno.denort else "";
  # The commands evaluate outside this flake, so they fetch the shared
  # purifier library at the revision this flake locks, the one the
  # sandboxed builds use.
  purifierLocked = writeText "purifier-locked.json" (
    builtins.toJSON (lib.importJSON ../../flake.lock).nodes.purifier.locked
  );

  # The Nix expression that the commands evaluate, with the part that
  # selects the result. The paths come from the environment variables
  # DENO_PURIFIER_EVAL_ROOT, DENO_PURIFIER_EVAL_LOCKFILE and
  # DENO_PURIFIER_EVAL_DENO_LOCK.
  evaluation = result: ''
    (import ${../../nix/lib}/commands.nix {
      nixpkgs = ${path};
      system = "${stdenv.hostPlatform.system}";
      purifierSource = (builtins.fetchTree (builtins.fromJSON (builtins.readFile ${purifierLocked}))).outPath;
      root = builtins.getEnv "DENO_PURIFIER_EVAL_ROOT";
      lockFile = builtins.getEnv "DENO_PURIFIER_EVAL_LOCKFILE";
      denoLockFile = builtins.getEnv "DENO_PURIFIER_EVAL_DENO_LOCK";
      deno = "${deno}";
      denort = "${denort}";
      nativeTools = "${../../src}";
    }).${result}
  '';

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

    # Whether the deno.lock $1 is the one the lockfile $2 records.
    denoLockMatches() {
      [ "$(sha256 < "$1")" = "$(lockedDenoLock "$2")" ]
    }

    # What the environment and the DENO_DIR of root $1 with lockfile $2 and
    # deno.lock $3 were made from.
    stampOf() {
      cat "$3" "$2" | sha256
    }

    # The DENO_DIR of root $1.
    denoDirOf() {
      echo "''${XDG_CACHE_HOME:-$HOME/.cache}/deno-purifier/$(printf '%s' "$1" | sha256 | cut -c1-32)"
    }

    # Builds .deno-purifier/environment of root $1 with lockfile $2 and
    # deno.lock $3 through Nix, the garbage-collector root of everything the
    # development loop and the editor read.
    buildEnvironment() {
      local root="$1" lockfile="$2" denolock="$3" state="$1/.deno-purifier"
      echo "deno-purifier: building the environment of $root" >&2
      mkdir -p "$state"
      # The directory holds links into the store and nothing to commit.
      printf '*\n' > "$state/.gitignore"
      DENO_PURIFIER_EVAL_ROOT="$root" DENO_PURIFIER_EVAL_LOCKFILE="$lockfile" \
        DENO_PURIFIER_EVAL_DENO_LOCK="$denolock" \
        nix build --impure --out-link "$state/environment" --expr '
          ${evaluation "environment"}
        ' || fail "building the environment failed; the message above says why."
      # The wrapper follows these links to lockfiles outside the project.
      rm -f "$state/lockfile" "$state/tool-lockfile"
      if [ "$lockfile" != "$root/$LOCK_FILE" ]; then
        ln -sfn "$lockfile" "$state/lockfile"
      fi
      if [ "$denolock" != "$root/deno.lock" ]; then
        ln -sfn "$denolock" "$state/tool-lockfile"
      fi
      stampOf "$root" "$lockfile" "$denolock" > "$state/stamp"
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
      if [ -d "$root/.deno-purifier/environment/cache/deps" ]; then
        cp -rs --no-preserve=mode "$root/.deno-purifier/environment/cache/deps" "$dir/deno-dir/deps"
      fi
      if [ -d "$root/.deno-purifier/environment/cache/npm" ]; then
        cp -rL "$root/.deno-purifier/environment/cache/npm" "$dir/deno-dir/npm"
        chmod -R u+w "$dir/deno-dir/npm"
      fi
      printf '%s\n' "$stamp" > "$dir/stamp"
    }

    # Makes sure root $1 with lockfile $2 and deno.lock $3 has an
    # environment and a DENO_DIR made from its current lockfiles. With the
    # environment in place, this needs neither Nix nor the network.
    prepare() {
      local root="$1" lockfile="$2" denolock="$3" command="''${4:-}" stamp
      ${helperDeno}/bin/deno run --allow-read --allow-env --allow-run=${deno}/bin/deno --no-config --no-lock ${../../src}/check-selected.ts "$lockfile" ${deno} ${helperDeno} "$command" \
        || fail "selected Deno SDK differs from the lock; select the captured SDK or run deno-purifier lock with the intended SDK"
      stamp="$(stampOf "$root" "$lockfile" "$denolock")"
      if [ ! -e "$root/.deno-purifier/environment/cache" ] \
        || [ "$(cat "$root/.deno-purifier/stamp" 2> /dev/null || true)" != "$stamp" ]; then
        buildEnvironment "$root" "$lockfile" "$denolock"
      fi
      if [ "$(cat "$(denoDirOf "$root")/stamp" 2> /dev/null || true)" != "$stamp" ]; then
        makeDenoDir "$root" "$stamp"
      fi
    }

    # The nearest directory upwards from $1 with a deno.lock or a Deno
    # configuration file.
    findRoot() {
      local dir="$1"
      while [ ! -f "$dir/deno.lock" ] && [ ! -f "$dir/deno.json" ] && [ ! -f "$dir/deno.jsonc" ]; do
        [ "$dir" = / ] && fail "no deno.lock or deno.json in $1 or above it."
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
      usage: deno-purifier lock [--root DIR] [--lockfile PATH] [--tool-lockfile PATH] [-- DENO-ARGS...]
             deno-purifier update [--root DIR] [--lockfile PATH] [--tool-lockfile PATH] [--latest] [PACKAGE...]
             deno-purifier prefetch [--root DIR] [--lockfile PATH] [--tool-lockfile PATH]
             deno-purifier publish [--root DIR] [--lockfile PATH] [--tool-lockfile PATH] [DENO-PUBLISH-ARGS...]

        lock      record the project's downloads in deno-purifier.lock.json,
                  with the resolution deno.lock holds
        update    update the dependencies with `deno update`, all of them or
                  each PACKAGE, then record the downloads
        prefetch  realize the locked downloads, Deno and its runtime in the
                  Nix store, with a garbage-collector root in the project,
                  so that the development loop and the editor work offline
        publish   build the release with Nix and run `deno publish` on it

      DIR is the project root, by default the nearest directory upwards with
      a deno.lock or a deno.json. The first PATH is the lockfile, by default
      deno-purifier.lock.json at DIR, and DENO_PURIFIER_LOCKFILE sets it too.
      The second PATH is deno.lock, by default deno.lock at DIR, and
      DENO_PURIFIER_TOOL_LOCKFILE sets it too.
      EOF
        exit 2
      }

      verb="''${1:-}"
      [ $# -gt 0 ] && shift
      case "$verb" in
        lock | update)
          export DENO_NO_UPDATE_CHECK=1
          export DENO_PURIFIER_PROJECT_DENO="$deno"
          export DENO_PURIFIER_PROJECT_SDK=${deno}
          export DENO_PURIFIER_HELPER_SDK=${helperDeno}
          export DENO_PURIFIER_NIX=${nix}/bin/nix
          export DENO_PURIFIER_NIXPKGS=${path}
          export DENO_PURIFIER_SYSTEM=${stdenv.hostPlatform.system}
          export DENO_PURIFIER_OFFLINE_VERIFY=${../../nix/lib/native-offline.nix}
          exec ${helperDeno}/bin/deno run --allow-all --no-config --no-lock \
            ${../../src}/deno-purifier.ts "$verb" "$@"
          ;;
        prefetch | publish) ;;
        *) usage ;;
      esac

      root=
      lockfile="''${DENO_PURIFIER_LOCKFILE:-}"
      denolock="''${DENO_PURIFIER_TOOL_LOCKFILE:-}"
      while [ $# -gt 0 ]; do
        case "$1" in
          --root)
            [ $# -ge 2 ] || usage
            root="$(realpath "$2")"
            shift 2
            ;;
          --lockfile)
            [ $# -ge 2 ] || usage
            lockfile="$2"
            shift 2
            ;;
          --tool-lockfile)
            [ $# -ge 2 ] || usage
            denolock="$2"
            shift 2
            ;;
          *) break ;;
        esac
      done
      [ -n "$root" ] || root="$(findRoot "$PWD")"
      if [ -n "$lockfile" ]; then lockfile="$(realpath "$lockfile")"; else lockfile="$root/$LOCK_FILE"; fi
      if [ -n "$denolock" ]; then denolock="$(realpath "$denolock")"; else denolock="$root/deno.lock"; fi
      [ -f "$lockfile" ] || fail "$lockfile does not exist; run \`deno-purifier lock\` to write it."
      [ -f "$denolock" ] || fail "$denolock does not exist; run \`deno-purifier lock\` to write it."

      case "$verb" in
        prefetch)
          [ $# -eq 0 ] || usage
          buildEnvironment "$root" "$lockfile" "$denolock"
          makeDenoDir "$root" "$(stampOf "$root" "$lockfile" "$denolock")"
          echo "deno-purifier: $root/.deno-purifier/environment holds the locked downloads, Deno and its runtime; the deno wrapper and its language server now work offline." >&2
          ;;
        publish)
          prepare "$root" "$lockfile" "$denolock"
          echo "deno-purifier: building the release of $root" >&2
          release="$(
            DENO_PURIFIER_EVAL_ROOT="$root" DENO_PURIFIER_EVAL_LOCKFILE="$lockfile" \
              DENO_PURIFIER_EVAL_DENO_LOCK="$denolock" \
              nix build --impure --no-link --print-out-paths --expr '
                ${evaluation "release"}
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
      # The project root is the nearest directory upwards with a deno.lock
      # or a Deno configuration file, and with both lockfiles. A lockfile
      # outside the project is the one that DENO_PURIFIER_LOCKFILE or
      # DENO_PURIFIER_TOOL_LOCKFILE names, or else the one that a prefetch
      # linked as .deno-purifier/lockfile or .deno-purifier/tool-lockfile.
      dir="$PWD"
      while :; do
        if [ -f "$dir/deno.lock" ] || [ -f "$dir/deno.json" ] || [ -f "$dir/deno.jsonc" ]; then
          lockfile="$dir/$LOCK_FILE"
          denolock="$dir/deno.lock"
          if [ -n "''${DENO_PURIFIER_LOCKFILE:-}" ]; then
            lockfile="$(realpath "$DENO_PURIFIER_LOCKFILE")"
          elif [ -f "$dir/.deno-purifier/lockfile" ]; then
            lockfile="$(realpath "$dir/.deno-purifier/lockfile")"
          fi
          if [ -n "''${DENO_PURIFIER_TOOL_LOCKFILE:-}" ]; then
            denolock="$(realpath "$DENO_PURIFIER_TOOL_LOCKFILE")"
          elif [ -f "$dir/.deno-purifier/tool-lockfile" ]; then
            denolock="$(realpath "$dir/.deno-purifier/tool-lockfile")"
          fi
          if [ -e "$lockfile" ]; then
            [ -f "$denolock" ] || fail "$denolock is missing beside an existing purifier lock; run deno-purifier lock"
            break
          fi
          echo "deno-purifier: warning: no deno-purifier.lock.json found; running deno impurely. Run \`deno-purifier lock\` to use Nix-resolved dependencies." >&2
          exec "$deno" "$@"
        fi
        if [ "$dir" = / ]; then
          echo "deno-purifier: warning: no deno-purifier.lock.json found; running deno impurely. Run \`deno-purifier lock\` to use Nix-resolved dependencies." >&2
          exec "$deno" "$@"
        fi
        dir="$(dirname "$dir")"
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

      loads=0
      case "$command" in
        run | test | check | install | i | cache | bench | compile | info | doc | serve | eval | repl | task | lsp) loads=1 ;;
      esac

      if ! denoLockMatches "$denolock" "$lockfile"; then
        if [ "$loads" = 1 ]; then
          fail "$denolock changed since $lockfile was written; run \`deno-purifier lock\` at $dir to record the change, or DENO_PURIFIER=0 to run Deno with the network."
        fi
        exec "$deno" "$@"
      fi

      prepare "$dir" "$lockfile" "$denolock" "$command"

      ${lib.optionalString (toString deno != toString helperDeno) "unset LD_LIBRARY_PATH LD_PRELOAD"}
      export DENO_DIR
      DENO_DIR="$(denoDirOf "$dir")/deno-dir"
      ${lib.optionalString (denort != "") "export DENORT_BIN=${denort}/bin/denort"}
      # Deno checks for a newer release over the network; the locked Deno is
      # the one nixpkgs ships.
      export DENO_NO_UPDATE_CHECK=1
      # The options that follow the command: no network, and the deno.lock
      # outside the project when there is one.
      options=(--cached-only)
      ${
        if toString deno != toString helperDeno then
          ''
            options+=(--lock "$denolock")
          ''
        else
          ''
            if [ "$denolock" != "$dir/deno.lock" ]; then
              options+=(--lock "$denolock")
            fi
          ''
      }
      case "$command" in
        run | test | check | install | i | cache | bench | compile | info | doc)
          set -- "''${@:1:$((position + 1))}" "''${options[@]}" "''${@:$((position + 2))}"
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
          set -- "''${@:1:$((position + 1))}" "''${options[@]}" "''${@:$((position + 2))}"
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
