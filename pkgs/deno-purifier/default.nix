# SPDX-License-Identifier: MIT
#
# The command-line side of deno-purifier, two commands in bin/:
#
#   deno-purifier   `deno-purifier lock` records the project's downloads in
#                   deno-purifier.lock.json (src/deno-purifier.ts).
#   deno            Deno, wrapped so that in a project with a
#                   deno-purifier.lock.json it reads the locked downloads
#                   from the Nix store. The wrapper builds the project's
#                   DENO_DIR through Nix (nix/lib/interactive.nix) under
#                   $XDG_CACHE_HOME/deno-purifier, rebuilds it when either
#                   lockfile changes, and passes --cached-only to the
#                   commands that load modules.
#
# The commands that change dependencies (add, remove, outdated, update,
# upgrade, and install with a package or --global) run as Deno runs
# without the wrapper, and so does every command when deno.lock changed
# since the lock run. DENO_PURIFIER=0 turns the wrapper off.
{
  lib,
  runCommand,
  writeShellApplication,
  deno,
  coreutils,
  gnugrep,
  path,
  stdenv,
}:
let
  lockTool = writeShellApplication {
    name = "deno-purifier";
    runtimeInputs = [ deno ];
    text = ''
      export DENO_NO_UPDATE_CHECK=1
      exec ${lib.getExe deno} run --allow-all --no-config --no-lock \
        ${../../src/deno-purifier.ts} "$@"
    '';
  };

  wrapper = writeShellApplication {
    name = "deno";
    runtimeInputs = [
      coreutils
      gnugrep
    ];
    text = ''
      deno=${lib.getExe deno}

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

      # The project root is the nearest directory upwards with both
      # lockfiles.
      dir="$PWD"
      while [ ! -f "$dir/deno.lock" ] || [ ! -f "$dir/deno-purifier.lock.json" ]; do
        if [ "$dir" = / ]; then
          exec "$deno" "$@"
        fi
        dir="$(dirname "$dir")"
      done

      locked="$(grep -o '"denoLock": "[0-9a-f]*"' "$dir/deno-purifier.lock.json" | grep -o '[0-9a-f]\{64\}' || true)"
      if [ "$(sha256sum < "$dir/deno.lock" | cut -d' ' -f1)" != "$locked" ]; then
        echo "deno-purifier: deno.lock changed since the lock run; Deno runs as usual until \`deno-purifier lock\` records it." >&2
        exec "$deno" "$@"
      fi

      cache="''${XDG_CACHE_HOME:-$HOME/.cache}/deno-purifier/$(printf '%s' "$dir" | sha256sum | cut -c1-32)"
      stamp="$(cat "$dir/deno.lock" "$dir/deno-purifier.lock.json" | sha256sum | cut -d' ' -f1)"
      if [ "$(cat "$cache/lock.sha256" 2> /dev/null || true)" != "$stamp" ]; then
        echo "deno-purifier: building the downloads of $dir" >&2
        mkdir -p "$cache"
        DENO_PURIFIER_ROOT="$dir" nix build --impure --out-link "$cache/cache" --expr '
          import ${../../nix/lib}/interactive.nix {
            pkgs = import ${path} { system = "${stdenv.hostPlatform.system}"; };
            src = /. + builtins.getEnv "DENO_PURIFIER_ROOT";
          }
        '
        # Deno writes transpiled modules and analysis databases into
        # DENO_DIR, so DENO_DIR is writable. Its remote modules are links
        # into the store, since Deno looks them up by URL. Its npm packages
        # are copies: Deno tells which package a file belongs to by the real
        # path of the file, which must lie inside DENO_DIR.
        chmod -R u+w "$cache/deno-dir" 2> /dev/null || true
        rm -rf "$cache/deno-dir"
        mkdir -p "$cache/deno-dir"
        if [ -d "$cache/cache/remote" ]; then
          cp -rs --no-preserve=mode "$cache/cache/remote" "$cache/deno-dir/remote"
        fi
        if [ -d "$cache/cache/npm" ]; then
          cp -rL "$cache/cache/npm" "$cache/deno-dir/npm"
          chmod -R u+w "$cache/deno-dir/npm"
        fi
        printf '%s\n' "$stamp" > "$cache/lock.sha256"
      fi

      export DENO_DIR="$cache/deno-dir"
      export DENORT_BIN=${deno.denort}/bin/denort
      case "$command" in
        run | test | check | install | i | cache | bench | compile | info | doc | serve | eval | repl)
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
    ln -s ${lib.getExe lockTool} "$out/bin/deno-purifier"
    ln -s ${lib.getExe wrapper} "$out/bin/deno"
  ''
