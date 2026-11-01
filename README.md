# deno-purifier

deno-purifier builds Deno projects in the Nix sandbox from their
`deno.lock` and a small second lockfile, `deno-purifier.lock.json`, which
it records beside it. The second lockfile holds only what `deno.lock`
cannot tell Nix. The project needs no generated Nix files.

deno-purifier meets the
[purifier contract](https://github.com/nix-purifiers/purifier/blob/main/CONTRACT.md)
of the nix-purifiers: the builder, the commands, the checks and this
README follow the same shape in every purifier.

Deno's maintainers have announced that the runtime gets one more year of
bug-fix and security releases, after which its development ends. JSR keeps
running on Cloudflare. deno-purifier builds with the Deno of its package
set, and keeps working for as long as nixpkgs packages a Deno.

## Quickstart

Record the lockfile at the project root and commit it with `deno.lock`:

```zsh
nix run github:nix-purifiers/deno-purifier -- lock
```

A project without a `deno.lock` needs one first: run `deno install`. A
project whose configuration sets `"lock": false` needs that setting removed,
since Deno then neither writes nor reads `deno.lock`. When the lock run
reports that `deno.lock` is out of date, run
`nix run github:nix-purifiers/deno-purifier -- update`.

Build the project with the builder in the flake's library:

```nix
{
  inputs.deno-purifier.url = "github:nix-purifiers/deno-purifier";
  inputs.nixpkgs.follows = "deno-purifier/nixpkgs";

  outputs = { nixpkgs, deno-purifier, ... }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
      project = deno-purifier.lib.deno-purifier.buildDenoProject {
        inherit pkgs;
        src = ./.;
        buildTasks = [ "build" ];
      };
    in
    {
      packages.${system}.default = project.packages.my-app;
      checks.${system}.tests = project.tests;
    };
}
```

### What the builder returns

- `packages.<program>`: for each `deno compile` command in the tasks of the
  project or of a workspace member, the compiled binary in
  `bin/<program>`. `<program>` is the command's `--output`, or the
  entrypoint's name without its extension.
- `packages.<package>`: for each package with a `name` in its `deno.json`,
  such as `packages."@scope/name"`, the files of its directory after the
  build tasks, once `deno publish --dry-run` accepts them.
- `packages."task:<task>"`: for each task, the project after the task ran.
  A task of a workspace member is `packages."task:<member dir>:<task>"`.
- `tests`: the project after the build tasks and `deno test`.
- `release`: what `deno-purifier publish` uploads to JSR, the project
  after the build tasks, once `deno publish --dry-run` accepts every
  package.
- `fetches`: the download entries of the
  [purifier library](https://github.com/nix-purifiers/purifier) that the
  build fetches, for SBOM, license and vulnerability tools.

The names come from the lockfile, so they are known at evaluation time.

### The lock in memory

`lib.deno-purifier.readLock { src, lockFile, denoLock }` reads both
lockfiles into the shape every purifier shares:
`{ purifier = "deno-purifier"; entries; outputs; problems; }`. `entries`
are the download entries of every system, and an npm package with
platform filters carries `systems`, the systems it installs on. `outputs`
names each attribute of `packages`. `problems` holds a message for a
stale, edited, malformed or missing lockfile, and each message names the
command that fixes it. The builder passes the lock to the purifier
library's `checkLock`, takes the downloads of its system from
`entriesFor`, and returns the entries as `fetches`. A tool that reads
every purifier, such as an SBOM generator, can call `readLock` alone.

### The builder's arguments

`nix/lib/build-deno-project.nix` documents each of them:

- `pkgs` and `src` are the package set and the project root.
- `lockFile` is `deno-purifier.lock.json`, and `denoLock` is `deno.lock`.
  Either may live outside `src`, such as in a packaging flake for a
  project whose author does not use deno-purifier. A `deno.lock` given
  outside `src` replaces the one in `src` during the build.
- `fetchers` replaces the fetchers of the purifier library, such as a
  `fetchurl` that goes through a company mirror or sends credentials.
- `buildTasks` lists the tasks that build the project, run at the root
  before the other outputs are taken.
- `testArgs` gives `deno test` its flags, such as permissions.
- `installArgs` gives `deno install` its flags, such as
  `--allow-scripts=npm:<package>` for npm packages whose install scripts
  must run, as Deno requires outside Nix too.
- `publishArgs` gives the `deno publish --dry-run` that checks the packages
  and the release its flags, such as `--no-check` for a package that does
  not type-check with this Deno.
- `denoPackage` is the Deno that builds. Its `denort` output is the
  runtime of compiled programs.
- `nativeBuildInputs` and `buildInputs` give tasks and native npm addons
  their tools and libraries.
- `srcFilter` replaces the filter that leaves `node_modules`, `.git`,
  `.deno-purifier` and `result` links out of the source.

### The lockfile

Deno keeps its downloads in one directory, `DENO_DIR`. Each remote module
and each JSR file is a file there, named by the SHA-256 of its URL path,
with the response headers appended. Each npm package lies unpacked under
`npm/<registry host>/<name>/<version>`.

Nix reads most of what it fetches from `deno.lock` at evaluation time:

- each npm package, with its integrity hash and its platform filters;
- each remote module outside JSR, with its SHA-256;
- each JSR version's `<version>_meta.json`, whose SHA-256 is the version's
  `integrity`;
- the version list (`meta.json`) of each JSR package, which Nix writes
  with the locked versions;
- the redirects, which Deno reads from `deno.lock` itself.

`deno-purifier.lock.json` records the rest:

| Field | What it holds | Why `deno.lock` cannot supply it |
|---|---|---|
| `jsrFiles` | The SHA-256 of each JSR module file the project loads. | `deno.lock` pins a JSR version by the hash of its `_meta.json` alone. Its manifest holds the file hashes, and Nix would have to download it during evaluation to read them. `deno.lock` also does not say which files the project loads. |
| `headers` | The response headers of the modules whose headers Deno reads differently from their extension, such as an `x-typescript-types` header or a module without an extension. | `deno.lock` records bodies, not headers. Every other module is written with no headers, and Deno goes by its extension. |
| `jsrRegistry`, `npmRegistries` | The JSR registry and the npm registry of each scope. | `deno.lock` names packages without their registries. |
| `members`, `programs` | The project's packages and tasks, and each `deno compile` command. | They are not downloads. `deno.json` may be JSON with comments, which Nix cannot parse, and a task is a shell command. |
| `configs`, `denoLock` | Hashes of every `deno.json` and of `deno.lock`. | They tell Nix that the lockfile is stale. |
| `version`, `contentHash` | The format, and the SHA-256 of the file's text with that value empty. | They make an edited or truncated lockfile fail. |

`deno-purifier lock` copies the project to a temporary directory and runs
`deno install` there with an empty `DENO_DIR` and the network, once
plainly and once on every module of the project, then runs `deno check`.
The project's modules are its source files, without what the root
configuration's `exclude` lists and without nested projects: directories
with a `deno.json`, `deno.jsonc` or `package.json` of their own that are
not workspace members, such as an example with its own import map. It
then rebuilds a `DENO_DIR` the way Nix does, from `deno.lock` and what it
recorded alone, runs `deno install --cached-only` against it, and writes
the lockfile only when that succeeds.

The installs run with `--frozen`, so `lock` keeps the resolution
`deno.lock` holds. A `deno.lock` that does not cover every module stops it
with the change Deno wants to make. Locking a project again with the same
`deno.lock` writes the same lockfile, byte for byte.

`deno-purifier update [--latest] [<package>...]` updates both lockfiles in
one run. It runs `deno update --recursive` on the project, for every
dependency or the named ones, within the version requirements of
`deno.json` or, with `--latest`, to the latest versions. Deno writes the
new requirements and resolution to `deno.json` and `deno.lock`. The lock
run that follows lets a first pass add to `deno.lock` what the code
imports, writes it back to the project, and records the downloads from a
frozen pass, so the lockfile it writes is the same as the one a plain lock
run then writes.

`--lockfile <path>` writes the lockfile outside the project, and `update`,
`prefetch` and `publish` take it too, matching the builder's `lockFile`.

## Everyday loop

```zsh
nix develop github:nix-purifiers/deno-purifier
```

The shell has `deno-purifier` and a `deno` wrapper. The everyday loop is
Deno's own commands, `deno run`, `deno test`, `deno task` and the rest,
through the wrapper. In a project with both lockfiles, the wrapper reads
the locked downloads and nothing from the network: it passes
`--cached-only` to the commands that load modules (`run`, `test`, `check`,
`install`, `cache`, `bench`, `compile`, `info`, `doc`, `serve`, `eval` and
`repl`).

Adding a dependency goes `deno add jsr:@std/fmt`, which the wrapper lets
reach the network, then `deno-purifier lock`. Until the lock run, the
wrapper stops the commands that load modules and says to run
`deno-purifier lock`. The commands that change dependencies (`add`,
`remove`, `outdated`, `update`, `upgrade`, and `install` with a package or
`--global`) always run as Deno runs without the wrapper.
`DENO_PURIFIER=0` turns the wrapper off.

`deno-purifier publish` builds the `release` with Nix and runs
`deno publish` on it, with the arguments that follow, such as `--dry-run`
or `--token`.

## Offline work

```zsh
deno-purifier prefetch
```

`prefetch` realizes everything the everyday loop and the editor read: the
locked downloads, the wrapper's Deno and `denort`, the runtime that
`deno compile` embeds. It links them into the project as
`.deno-purifier/environment`, a garbage-collector root, so `nix-collect-garbage`
keeps them. The directory holds a `.gitignore` of its own, so it stays out
of version control. After a prefetch, `deno run`, `deno test`, `deno task`
and `deno compile` work with the network cut off, and so does the editor.

The wrapper prefetches by itself when the environment is missing or older
than the lockfiles, so `prefetch` matters before going offline. The
wrapper's `DENO_DIR` lives under `$XDG_CACHE_HOME/deno-purifier`, made from
the environment without Nix or the network, so deleting it costs nothing.

## Editor

An editor that starts `deno lsp` from the `PATH` of the development shell
gets the wrapper, so the language server reads the locked downloads. An
import the lock covers resolves, and one it does not is reported as an
uncached URL, as Deno reports any module missing from its cache. The
language server needs nothing beyond what `prefetch` realizes. The
`conformance-offline` check starts it with no network and opens two files
of a test project, which show no diagnostics.

## Errors and fixes

| What you see | What it means | What to run |
|---|---|---|
| `deno.lock changed since deno-purifier.lock.json was written` | The project's dependencies changed since the lock run. | `deno-purifier lock` |
| `deno.json changed since deno-purifier.lock.json was written` | A task or a workspace member may have changed. | `deno-purifier lock` |
| `does not match its contentHash` or `has no contentHash` | `deno-purifier.lock.json` was edited or cut short. | `deno-purifier lock` |
| `lacks … or has a value of the wrong type`, `has format` | The lockfile is malformed or from another deno-purifier version. | `deno-purifier lock` |
| `Deno needs a module that deno-purifier.lock.json does not record` | The code imports a module the lock run did not see, such as one added since. | `deno-purifier lock` |
| `deno.lock does not cover every module the project imports` (lock run) | An import in the code is missing from `deno.lock`. | `deno-purifier update` |
| `sets "lock": false` (lock run) | Deno ignores `deno.lock` for this project. | Remove the setting, `deno install`, `deno-purifier lock` |
| `hash mismatch in fixed-output derivation` (build) | A server now serves different bytes at a locked URL. | `deno-purifier lock`, then review the change |

## Sources supported and refused

Supported:

- npm packages from the npm registry and from the registries `.npmrc`
  names per scope, with the per-platform packages of the build's system;
- `package.json` dependencies, which Deno installs into `node_modules`;
- JSR packages, from `jsr.io` or the registry `JSR_URL` names;
- remote modules over HTTPS or HTTP, including redirected URLs;
- `data:` URLs, which need no download;
- workspaces, with packages and compiled programs in any member.

The lock run keeps the headers of a remote module when they change how
Deno reads it, as for a module without an extension. The unit tests cover
that rule, and no test project has such a module yet.

Refused or left out:

- A module a program imports at run time from a URL it computes is not
  among the modules the lock run installs and type-checks. Pass the
  command that imports it after `--` to record its downloads too, as in
  `deno-purifier lock -- task build`.
- A `--target` flag in a `deno compile` command is left out. Nix builds
  each program for each system on that system.
- A project that sets `"lock": false` is refused until it keeps a
  `deno.lock`.
- A `deno` command inside a task runs as Deno runs it, without
  `--cached-only`, so it tries to refresh the metadata of npm packages. In
  the sandbox and offline it falls back to the cached packages and
  downloads nothing.

## Real-world projects

- [deployctl](https://github.com/denoland/deployctl) at `87e43e5`, the
  command-line tool of Deno Deploy: a `deno.jsonc` with comments, a JSR
  package with many pinned `@std` versions, an npm dependency, a nested
  Node.js GitHub Action and a nested Fresh example. Its `deno.lock` at that
  commit is out of date for Deno 2.9.8, and its code does not type-check
  with Deno 2.9.8's TypeScript library. CI builds it from the lockfiles in
  `tests/real/deployctl`, kept outside its source: its JSR package passes
  `deno publish --dry-run --no-check`, its release task runs, and its
  command-line tool prints its version. A lock run of it takes about three
  seconds. Through the `deno` wrapper, its test suite (`deno test -A
  --unstable --no-check tests/ src/`) passes all 31 tests with only the
  locked downloads.

  Working through it led to the pass of `update` that lets Deno update
  `deno.lock`, to leaving nested projects and `exclude`d paths out of the
  lock run, to `publishArgs`, to the `denoLock` argument, and to the error
  messages above.
- [oak](https://github.com/oakserver/oak), the web framework, sets
  `"lock": false`, which led to the lock run's message for that case.

`nix flake check` runs every check in the sandbox on x86_64-linux and
aarch64-linux: the unit tests of the lock run (`src/lib_test.ts`), the
builds of the fixtures in `tests/fixtures` and of deployctl, the contract's
`conformance-stale`, `conformance-tampered`, `conformance-missing`,
`conformance-malformed`, `conformance-rebuild`, `conformance-offline` and
`conformance-external`, and checks of `publish` and of the wrapper. CI
also runs `conformance-relock`, which locks every test project again with
the network (`tests/relock.sh`) and fails when a lockfile changes, and
`conformance-update`, which runs `update` on a fixture whose `deno.lock`
pins an old `@std/path` and checks that Nix accepts both new lockfiles
(`tests/update.sh`).

## Credits

deno-purifier follows the design of
[sbt-purifier](https://github.com/nix-purifiers/sbt-purifier): the build
tool records its downloads in a lockfile, and Nix builds from it. The
purifier idea was inspired by nixcloud's
[cargo (libnix)](https://github.com/nixcloud/cargo). Compiled programs
embed `denort`, which nixpkgs builds from source as an output of its Deno
package.
