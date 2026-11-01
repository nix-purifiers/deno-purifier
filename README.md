# deno-purifier

deno-purifier builds Deno projects in the Nix sandbox from their
`deno.lock` and a second lockfile, `deno-purifier.lock.json`, which it
records beside it. The project needs no generated Nix files: the two
lockfiles name every download, every package of the project and every
program its tasks compile.

- **Sandboxed builds.** `buildDenoProject`, which the flake's overlay adds
  to a package set, reads both lockfiles at evaluation time. Nix fetches
  each download by its hash and lays them out as Deno's cache directory,
  and Deno runs offline against it: `deno install`, the project's tasks,
  `deno test` and `deno compile`.
- **One attribute per output.** Each package of the project that has a
  `name` becomes `packages.<name>`, checked with `deno publish --dry-run`.
  Each `deno compile` command in the tasks becomes `programs.<name>`, the
  compiled binary. Each task becomes `tasks.<name>`, the project after the
  task ran.
- **Deno on the locked downloads.** The flake's `deno` wrapper builds a
  project's downloads through Nix and runs Deno against them, so
  `deno run`, `deno test` and `deno task` read only what the lockfiles
  name.

Deno's maintainers have announced that the runtime gets one more year of
bug-fix and security releases, after which its development ends. JSR keeps
running on Cloudflare. deno-purifier builds with the Deno of its package
set, and keeps working for as long as nixpkgs packages a Deno.

## How it works

Deno keeps its downloads in one directory, `DENO_DIR`. Each remote module
and each JSR file is a file there, named by the SHA-256 of its URL path,
with the response headers appended. Each npm package lies unpacked under
`npm/<registry host>/<name>/<version>`.

`deno.lock` already names every npm package with its integrity hash and
its platform filters, so Nix takes the npm packages from it directly, for
every platform. It does not name the files of JSR packages, and a JSR
package also needs its version list, `meta.json`, which changes whenever
the package publishes. `deno-purifier lock` records those:

1. It copies the project to a temporary directory and runs `deno install`
   there with an empty `DENO_DIR` and the network, once plainly and once
   on every module of the project, then runs `deno check`. The project's
   modules are its source files, without what the root configuration's
   `exclude` lists and without nested projects: directories with a
   `deno.json`, `deno.jsonc` or `package.json` of their own that are not
   workspace members, such as an example with its own import map.
2. It reads the remote module cache Deno filled. A module body becomes a
   file entry with its URL, hash and the headers Deno keeps. A version
   list, trimmed to the versions `deno.lock` names, becomes an inline
   entry that holds the whole cache file. The entries have the shapes of
   [purifier](https://github.com/nix-purifiers/purifier), the Nix library
   the nix-purifiers share, and a build uses that library to fetch them
   and lay them out as a `DENO_DIR`.
3. It records the project's packages (the root and its workspace members),
   their tasks, and each `deno compile` command in the tasks with its
   entrypoint and flags.
4. It rebuilds a `DENO_DIR` from what it recorded alone, runs
   `deno install --cached-only` against it, and writes
   `deno-purifier.lock.json` only when that succeeds.

The installs run with `--frozen`, so the lock run never changes
`deno.lock` behind your back. A `deno.lock` that does not cover every
module stops it with the change Deno wants to make. `deno-purifier lock
--update` lets a first pass update `deno.lock`, writes it back to the
project, and records the downloads from a frozen pass, so the lockfile it
writes is the same as the one a plain lock run writes. A plain
`deno install` updates `deno.lock` for the import map only, so `--update`
is the way to cover imports written in the code.

Locking a project again with the same `deno.lock` writes the same
lockfile, byte for byte. CI checks that for every test project.

The lockfile also holds hashes of `deno.lock` and of every `deno.json` it
read. When one of them changes, evaluation stops and asks for a new lock
run.

Compiled programs embed `denort`, the Deno runtime. nixpkgs builds `denort`
from source as an output of its Deno package, and the builder points
`deno compile` at it through `DENORT_BIN`, so compiling downloads nothing.

## Use

Record the lockfile at the project root and commit it with `deno.lock`:

```zsh
nix run github:nix-purifiers/deno-purifier -- lock
```

A project without a `deno.lock` needs one first: run `deno install`. A
project whose configuration sets `"lock": false` needs that setting removed,
since Deno then neither writes nor reads `deno.lock`. When the lock run
reports that `deno.lock` is out of date, run
`nix run github:nix-purifiers/deno-purifier -- lock --update`.

The flake's `overlays.default` adds `buildDenoProject` to a package set,
and a package written for `callPackage` takes it by name, like any other
builder:

```nix
# package.nix
{ buildDenoProject }:
(buildDenoProject { src = ./.; }).programs.my-app
```

```nix
{
  inputs.deno-purifier.url = "github:nix-purifiers/deno-purifier";
  inputs.nixpkgs.follows = "deno-purifier/nixpkgs";

  outputs = { nixpkgs, deno-purifier, ... }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs {
        inherit system;
        overlays = [
          deno-purifier.overlays.default
          (final: prev: { my-app = final.callPackage ./package.nix { }; })
        ];
      };
    in
    {
      packages.${system}.default = pkgs.my-app;
    };
}
```

The builder returns

- `programs.<name>`: for each `deno compile` command in the tasks of the
  project or of a workspace member, the compiled binary in `bin/<name>`.
  `<name>` is the command's `--output`, or the entrypoint's name without
  its extension.
- `packages.<name>`: for each package with a `name` in its `deno.json`, the
  files of its directory after the build tasks, once
  `deno publish --dry-run` accepts them.
- `tasks.<name>`: for each task, the project after the task ran. A task of
  a workspace member is `tasks."<member dir>:<name>"`.
- `project`: the project after `deno install`, the build tasks and, with
  `doCheck`, `deno test`.
- `cache`: the `DENO_DIR` of the locked downloads.

`nix/lib/build-deno-project.nix` documents the builder's arguments:

- `buildTasks` lists the tasks that build the project, run at the root
  before the other outputs are taken.
- `doCheck` runs `deno test`, and `testArgs` gives it permission flags.
- `installArgs` gives `deno install` its flags, such as
  `--allow-scripts=npm:<package>` for npm packages whose install scripts
  must run, as Deno requires outside Nix too.
- `publishArgs` gives the `deno publish --dry-run` that checks each package
  its flags, such as `--no-check` for a package that does not type-check
  with this Deno.
- `denoPackage` is the Deno that builds. Its `denort` output is the
  runtime of compiled programs.
- `nativeBuildInputs` and `buildInputs` give tasks and native npm addons
  their tools and libraries.
- `lockFile`, `purifierLockFile`, `fetchurl` and `srcFilter` replace the
  lockfiles, the fetcher of the downloads (for a private registry that
  needs credentials) and the source filter. A `lockFile` given apart from
  the source replaces the `deno.lock` in the source during the build, which
  is how to build a project you do not control whose own `deno.lock` is out
  of date.

To publish a package to JSR, run `deno publish` through the wrapper below.
It reads the modules from the locked downloads and sends the files that
`packages.<name>` checked.

## Interactive use

```zsh
nix run github:nix-purifiers/deno-purifier#deno-purifier -- lock
nix develop github:nix-purifiers/deno-purifier
```

The shell has `deno-purifier` and a `deno` wrapper. In a project with both
lockfiles, the wrapper builds the project's downloads under
`$XDG_CACHE_HOME/deno-purifier` with a GC root there, and runs Deno with
`DENO_DIR` pointing at them. It passes `--cached-only` to the commands that
load modules (`run`, `test`, `check`, `install`, `cache`, `bench`,
`compile`, `info`, `doc`, `serve`, `eval` and `repl`), and rebuilds the
downloads when either lockfile changes.

The commands that change dependencies (`add`, `remove`, `outdated`,
`update`, `upgrade`, and `install` with a package or `--global`) run as
Deno runs without the wrapper. When `deno.lock` changed since the lock run,
every command does, until `deno-purifier lock` records the change.
`DENO_PURIFIER=0` turns the wrapper off.

The everyday loop of adding a dependency is: `deno add jsr:@std/fmt` (the
wrapper lets it reach the network), import it, run
`deno-purifier lock`, and carry on. Until the lock run, the wrapper says
that `deno.lock` changed and runs Deno as usual.

An editor that starts `deno lsp` from the `PATH` of the development shell
gets the wrapper too, so the language server reads the locked downloads:
an import the lock covers resolves, and one it does not is reported as an
uncached URL, as Deno reports any module missing from its cache.

## When something goes wrong

| What you see | What it means | What to run |
|---|---|---|
| `deno.lock changed since deno-purifier.lock.json was written` (evaluation) | The project's dependencies changed since the lock run. | `deno-purifier lock` |
| `deno.json changed since deno-purifier.lock.json was written` (evaluation) | A task or a workspace member may have changed. | `deno-purifier lock` |
| `deno.lock does not cover every module the project imports` (lock run) | An import in the code is missing from `deno.lock`. | `deno-purifier lock --update` |
| `sets "lock": false` (lock run) | Deno ignores `deno.lock` for this project. | Remove the setting, `deno install`, `deno-purifier lock` |
| `Deno needs a module that deno-purifier.lock.json does not record` (build or wrapper) | The code imports a module the lock run did not see, such as one added since. | `deno-purifier lock` |
| `lacks … or has a value of the wrong type` (evaluation) | `deno-purifier.lock.json` was edited or cut short. | `deno-purifier lock` |
| `hash mismatch in fixed-output derivation` (build) | A server now serves different bytes at a locked URL, or a hash in the lockfile was edited. | `deno-purifier lock`, then review the change |

## Tried on

- [deployctl](https://github.com/denoland/deployctl) at `87e43e5`, the
  command-line tool of Deno Deploy: a `deno.jsonc` with comments, a JSR
  package with many pinned `@std` versions, an npm dependency, a nested
  Node.js GitHub Action and a nested Fresh example. Its `deno.lock` at that
  commit is out of date for Deno 2.9.8, and its code does not type-check
  with Deno 2.9.8's TypeScript library. CI builds it from the lockfiles in
  `tests/real/deployctl`: its JSR package passes `deno publish --dry-run
  --no-check`, its release task runs, and its command-line tool prints its
  version. A lock run of it takes about three seconds.

  Working through it led to `--update`, to leaving nested projects and
  `exclude`d paths out of the lock run, to `publishArgs`, to the `lockFile`
  replacement, and to the error messages above.
- [oak](https://github.com/oakserver/oak), the web framework, sets
  `"lock": false`, which led to the lock run's message for that case.

## Limits

- The lock run records what Deno downloads while it installs and
  type-checks the project's modules. A module a program imports at run
  time from a URL it computes is not among them. Pass the command that
  imports it after `--` to record its downloads too, as in
  `deno-purifier lock -- task build`.
- A `deno` command inside a task runs as Deno runs it, without
  `--cached-only`, so it tries to refresh the metadata of npm packages. In
  the sandbox and offline it falls back to the cached packages and
  downloads nothing.
- A compiled program is built for the system Nix builds for, so a
  `--target` flag in a `deno compile` command is left out. Nix builds the
  program for each system on that system.

## Tests

`nix flake check` runs every check in the sandbox on x86_64-linux and
aarch64-linux: unit tests of the lock run's parsing, cache-file and URL
logic (`src/lib_test.ts`); builds of the fixtures in `tests/fixtures`,
which together cover remote modules, a redirected URL, a `data:` URL, JSR
packages, npm packages with per-platform binaries, a scoped registry, a
workspace with a package and a compiled program, and `package.json`
dependencies installed into `node_modules`; the deployctl build; and
negative checks for a changed `deno.lock` or `deno.json`, a malformed or
edited lockfile, and a module missing from the lock.
`tests/relock.sh` locks every test project again with the network and
fails when a lockfile changes.

## Related work

deno-purifier follows the design of
[sbt-purifier](https://github.com/nix-purifiers/sbt-purifier): the build
tool records its downloads in a lockfile, and Nix builds from it. The
purifier idea was inspired by nixcloud's
[cargo (libnix)](https://github.com/nixcloud/cargo).
