// SPDX-License-Identifier: MIT
//
// deno-purifier: records what a Deno project downloads, for Nix.
//
//   deno-purifier lock [--root DIR] [--lockfile PATH] [-- DENO-ARGS...]
//   deno-purifier update [--root DIR] [--lockfile PATH] [--latest] [PACKAGE...]
//
// The lock run copies the project to a temporary directory and runs
// `deno install` there with an empty DENO_DIR and the network: once plainly,
// which fetches every package in the import map, and once on every module
// of the project, which fetches what the modules import. Deno downloads
// every remote module, every JSR file and every npm package the project
// needs into that DENO_DIR. The lock run then writes deno-purifier.lock.json
// at the project root:
//
// It records only what deno.lock cannot tell Nix:
//
//   jsrFiles       the SHA-256 of each JSR module file the project loads.
//                  deno.lock pins a JSR version only by the hash of its
//                  <version>_meta.json, whose manifest Nix would have to
//                  download during evaluation to read.
//   headers        the response headers of the remote modules whose headers
//                  Deno reads differently from their extension; Nix writes
//                  every other module with none.
//   jsrRegistry,   the registries the downloads came from.
//   npmRegistries
//   members        the project's packages: the root and its workspace
//                  members, with their name, version, directory and tasks.
//   programs       one entry per `deno compile` command in the tasks.
//
// The lockfile also holds its format `version`, `contentHash` (the SHA-256
// of its text with that value empty, which Nix checks), and the hashes of
// deno.lock and of every deno.json, which tell Nix when it is stale.
//
// Nix reads the rest from deno.lock: the npm packages with their integrity
// and platform filters, the remote modules outside JSR with their hashes,
// and each JSR version's <version>_meta.json with its hash. It writes the
// JSR version lists (meta.json) of the locked versions itself, and Deno
// reads redirects from deno.lock.
//
// The lock run then rebuilds a DENO_DIR from what it recorded alone and
// runs `deno install --cached-only` against it, so a recorded lockfile is
// known to serve the project offline.
//
// A first pass lets Deno write deno.lock where it is missing or does not
// cover the project, and Deno keeps every resolution that deno.lock holds.
// The recording installs then run with --frozen. `update` runs
// `deno update` before the lock run, to change the resolution.
//
// DENO-ARGS, when given, are one more Deno command the lock run runs in the
// copy, such as `task build`, for modules a task imports at run time.

import {
  cacheFile,
  explainFailure,
  type Json,
  jsrVersionListOf,
  keptHeaders,
  lockedJsrVersions,
  parseCompile,
  parseNpmrc,
  type Program,
  shellWords,
  splitCacheFile,
  stripJsonc,
  cachePath,
  headersMatter,
  versionListBody,
  withContentHash,
} from "./lib.ts";

const LOCK_FILE = "deno-purifier.lock.json";
const LOCK_VERSION = 3;
const SOURCE_EXTENSIONS = [".ts", ".tsx", ".mts", ".cts", ".js", ".jsx", ".mjs", ".cjs"];
// Directories that hold installed or generated files rather than the
// project's modules.
const SKIPPED_DIRS = new Set(["node_modules", "vendor"]);

// A module of Deno's remote module cache, with the headers Nix writes for
// it.
interface RemoteModule {
  path: string;
  url: string;
  headers: Record<string, string>;
  body: Uint8Array;
}

interface Member {
  name: string | null;
  version: string | null;
  dir: string;
  config: string;
  tasks: string[];
}

function fail(message: string): never {
  console.error(`deno-purifier: ${message}`);
  Deno.exit(1);
}

function log(message: string) {
  console.error(`deno-purifier: ${message}`);
}

function joinPath(...parts: string[]): string {
  return parts
    .filter((p) => p !== "")
    .join("/")
    .replace(/\/+/g, "/")
    .replace(/\/\.\//g, "/")
    .replace(/\/\.$/, "");
}

function dirname(path: string): string {
  const i = path.lastIndexOf("/");
  return i <= 0 ? (i === 0 ? "/" : ".") : path.slice(0, i);
}

function exists(path: string): boolean {
  try {
    Deno.statSync(path);
    return true;
  } catch {
    return false;
  }
}

// The configuration file of a directory, if it has one.
function configIn(dir: string): string | null {
  for (const name of ["deno.json", "deno.jsonc"]) {
    if (exists(joinPath(dir, name))) return name;
  }
  return null;
}

function readJsonc(path: string): Record<string, Json> {
  try {
    return JSON.parse(stripJsonc(Deno.readTextFileSync(path)));
  } catch (e) {
    fail(`cannot parse ${path}: ${e}`);
  }
}

async function sha256(bytes: Uint8Array): Promise<Uint8Array> {
  return new Uint8Array(await crypto.subtle.digest("SHA-256", new Uint8Array(bytes)));
}

function base64(bytes: Uint8Array): string {
  let s = "";
  for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s);
}

function hex(bytes: Uint8Array): string {
  return Array.from(bytes, (b) => b.toString(16).padStart(2, "0")).join("");
}

async function run(
  args: string[],
  options: { cwd: string; env: Record<string, string> },
): Promise<{ ok: boolean; output: string }> {
  const command = new Deno.Command(Deno.execPath(), {
    args,
    cwd: options.cwd,
    env: options.env,
    stdout: "piped",
    stderr: "piped",
  });
  const result = await command.output();
  const decoder = new TextDecoder();
  return {
    ok: result.success,
    output: decoder.decode(result.stdout) + decoder.decode(result.stderr),
  };
}

// Every file below dir, relative to dir, without the directories that hold
// installed or generated files, version control or Nix result links.
function walk(dir: string, rel = ""): string[] {
  const files: string[] = [];
  for (const entry of Deno.readDirSync(joinPath(dir, rel))) {
    const path = rel === "" ? entry.name : `${rel}/${entry.name}`;
    if (entry.isDirectory) {
      if (
        entry.name.startsWith(".") || SKIPPED_DIRS.has(entry.name) ||
        entry.name.startsWith("result")
      ) continue;
      files.push(...walk(dir, path));
    } else if (entry.isFile) {
      files.push(path);
    }
  }
  return files;
}

// The node_modules directories below dir, relative to dir, outermost
// first, without descending into them.
function walkDirs(dir: string, rel = ""): string[] {
  const dirs: string[] = [];
  for (const entry of Deno.readDirSync(joinPath(dir, rel))) {
    if (!entry.isDirectory || entry.name === ".git") continue;
    const path = rel === "" ? entry.name : `${rel}/${entry.name}`;
    if (entry.name === "node_modules") dirs.push(path);
    else dirs.push(...walkDirs(dir, path));
  }
  return dirs;
}

function copyTree(from: string, to: string) {
  Deno.mkdirSync(to, { recursive: true });
  for (const entry of Deno.readDirSync(from)) {
    if (
      entry.name === ".git" || entry.name === "node_modules" ||
      entry.name.startsWith("result")
    ) continue;
    const source = joinPath(from, entry.name);
    const target = joinPath(to, entry.name);
    if (entry.isDirectory) copyTree(source, target);
    else if (entry.isFile) Deno.copyFileSync(source, target);
    else if (entry.isSymlink) Deno.symlinkSync(Deno.readLinkSync(source), target);
  }
}

// The project root: the nearest directory upwards with a deno.lock. A
// project without one gets told how to write it, at the outermost
// directory with a configuration file.
function findRoot(start: string): string {
  let dir = Deno.realPathSync(start);
  let outermostConfig: string | null = null;
  while (true) {
    if (exists(joinPath(dir, "deno.lock"))) return dir;
    if (configIn(dir) !== null) outermostConfig = dir;
    if (dir === "/") break;
    dir = dirname(dir);
  }
  if (outermostConfig === null) {
    fail("no deno.json, deno.jsonc or deno.lock in this directory or above; run deno-purifier in a Deno project.");
  }
  const config = readJsonc(joinPath(outermostConfig, configIn(outermostConfig)!));
  if (config.lock === false) {
    fail(
      `${outermostConfig}/${configIn(outermostConfig)} sets "lock": false, so Deno writes no deno.lock, ` +
        "and deno-purifier builds from deno.lock. Remove the setting, run `deno install`, then run `deno-purifier lock`.",
    );
  }
  return outermostConfig;
}

// The root and its workspace members, from their configuration files.
function readMembers(root: string): Member[] {
  const rootConfig = configIn(root);
  if (rootConfig === null) fail(`no deno.json or deno.jsonc in ${root}`);
  const config = readJsonc(joinPath(root, rootConfig));
  if (config.lock === false) {
    fail(
      `${root}/${rootConfig} sets "lock": false, so Deno ignores deno.lock, ` +
        "and deno-purifier builds from deno.lock. Remove the setting, run `deno install`, then run `deno-purifier lock`.",
    );
  }
  const workspace = config.workspace;
  const memberDirs = Array.isArray(workspace)
    ? workspace
    : (workspace && typeof workspace === "object" && Array.isArray(workspace.members))
    ? workspace.members
    : [];
  const dirs = [""];
  for (const m of memberDirs) {
    if (typeof m === "string") dirs.push(m.replace(/^\.\//, "").replace(/\/$/, ""));
  }
  return dirs.map((dir) => {
    const name = configIn(joinPath(root, dir));
    if (name === null) fail(`workspace member ${dir} has no deno.json`);
    const c = readJsonc(joinPath(root, dir, name));
    const tasks = c.tasks && typeof c.tasks === "object" && !Array.isArray(c.tasks)
      ? Object.keys(c.tasks).sort()
      : [];
    return {
      name: typeof c.name === "string" ? c.name : null,
      version: typeof c.version === "string" ? c.version : null,
      dir,
      config: joinPath(dir, name),
      tasks,
    };
  });
}

function taskCommand(root: string, member: Member, task: string): string {
  const c = readJsonc(joinPath(root, member.config));
  const t = (c.tasks as Record<string, Json>)[task];
  if (typeof t === "string") return t;
  if (t && typeof t === "object" && !Array.isArray(t) && typeof t.command === "string") {
    return t.command;
  }
  return "";
}

// The project's modules: the source files below the root, without the
// paths the root configuration excludes and without nested projects. A
// nested project is a directory below the root that holds a deno.json,
// deno.jsonc or package.json of its own and is not a workspace member, such
// as an example with its own import map or a Node.js tool kept beside the
// Deno project.
function projectModules(root: string, members: Member[]): string[] {
  const config = readJsonc(joinPath(root, configIn(root)!));
  const excluded = Array.isArray(config.exclude)
    ? config.exclude.filter((e): e is string => typeof e === "string")
    : [];
  const memberDirs = new Set(members.map((m) => m.dir));
  const nestedProjects = walk(root)
    .filter((f) => /\/(deno\.jsonc?|package\.json)$/.test(f))
    .map((f) => dirname(f))
    .filter((d) => !memberDirs.has(d));
  return walk(root)
    .filter((f) => SOURCE_EXTENSIONS.some((e) => f.endsWith(e)))
    .filter((f) => !nestedProjects.some((d) => f.startsWith(`${d}/`)))
    .filter((f) => !excluded.some((e) => isExcluded(f, e)))
    .sort();
}

// Whether a configuration `exclude` entry covers a file: an entry names a
// file or a directory relative to the root, and may end in `/**` or use
// `*` within one path segment.
export function isExcluded(file: string, entry: string): boolean {
  const pattern = entry.replace(/^\.\//, "").replace(/\/\*\*$/, "").replace(/\/$/, "");
  const regex = new RegExp(
    "^" + pattern.split("*").map((s) => s.replace(/[.+?^${}()|[\]\\]/g, "\\$&")).join("[^/]*") +
      "(/|$)",
  );
  return regex.test(file);
}

function readPrograms(root: string, members: Member[]): Program[] {
  const programs: Program[] = [];
  for (const member of members) {
    for (const task of member.tasks) {
      for (const words of shellWords(taskCommand(root, member, task))) {
        const program = parseCompile(words, member.dir, task);
        if (program !== null) programs.push(program);
      }
    }
  }
  return programs;
}

function readNpmRegistries(root: string): Record<string, string> {
  const texts: string[] = [];
  const home = Deno.env.get("HOME");
  for (const file of [joinPath(root, ".npmrc"), ...(home ? [joinPath(home, ".npmrc")] : [])]) {
    try {
      texts.push(Deno.readTextFileSync(file));
    } catch {
      // A missing .npmrc sets nothing.
    }
  }
  return parseNpmrc(texts, Deno.env.get("NPM_CONFIG_REGISTRY"));
}

function jsrBase(): string {
  const url = Deno.env.get("JSR_URL") ?? "https://jsr.io/";
  return url.endsWith("/") ? url : `${url}/`;
}

// Reads Deno's remote module cache. deno.lock pins the hash of every remote
// module outside JSR and of every JSR version's <version>_meta.json, so
// Nix takes those from deno.lock. The lock run records what deno.lock
// lacks: the hash of each JSR module file the project loads, and the
// response headers of the modules whose headers Deno reads differently
// from their extension. A JSR version list (meta.json) and a redirect need
// no record either: Nix writes the list of the locked versions, and Deno
// reads redirects from deno.lock.
async function readRemote(
  denoDir: string,
  denoLock: Record<string, Json>,
): Promise<{
  modules: RemoteModule[];
  jsrFiles: Record<string, string>;
  headers: Record<string, Record<string, string>>;
}> {
  const modules: RemoteModule[] = [];
  const jsrFiles: Record<string, string> = {};
  const headers: Record<string, Record<string, string>> = {};
  const remoteDir = joinPath(denoDir, "remote");
  if (!exists(remoteDir)) return { modules, jsrFiles, headers };
  const jsr = jsrBase();
  const pinnedRemote = (denoLock.remote ?? {}) as Record<string, Json>;
  const pinnedJsr = (denoLock.jsr ?? {}) as Record<string, Json>;
  for (const rel of walk(remoteDir).sort()) {
    const split = splitCacheFile(Deno.readFileSync(joinPath(remoteDir, rel)));
    if (split === null) {
      fail(`remote/${rel} has no cache metadata; this Deno's cache format is not one deno-purifier reads`);
    }
    const { body, meta } = split;
    const url = meta.url;
    if (jsrVersionListOf(url, jsr) !== null || body.length === 0) continue;
    const kept = keptHeaders(meta.headers);
    const recorded = headersMatter(url, kept) ? kept : {};
    if (Object.keys(recorded).length > 0) headers[url] = recorded;
    modules.push({ path: `remote/${rel}`, url, headers: recorded, body });
    const versionMeta = url.startsWith(jsr) ? url.slice(jsr.length).match(/^(@[^/]+\/[^/]+)\/([^/]+)_meta\.json$/) : null;
    if (versionMeta !== null && `${versionMeta[1]}@${versionMeta[2]}` in pinnedJsr) continue;
    if (url.startsWith(jsr)) {
      jsrFiles[url] = `sha256-${base64(await sha256(body))}`;
    } else if (!(url in pinnedRemote)) {
      fail(
        `Deno cached ${url}, which deno.lock does not pin; ` +
          `this is a deno-purifier bug, please report it with the project's deno.lock.`,
      );
    }
  }
  return { modules, jsrFiles, headers };
}

// Builds a DENO_DIR as Nix does: the remote modules with the headers the
// lockfile records (none for most), the JSR version lists of the locked
// versions, and the npm packages Deno unpacked.
async function rebuild(
  target: string,
  denoDir: string,
  modules: RemoteModule[],
  denoLock: Record<string, Json>,
) {
  const encoder = new TextEncoder();
  for (const m of modules) {
    const path = joinPath(target, m.path);
    Deno.mkdirSync(dirname(path), { recursive: true });
    const trailer = encoder.encode(cacheFile("", m.url, m.headers));
    const bytes = new Uint8Array(m.body.length + trailer.length);
    bytes.set(m.body);
    bytes.set(trailer, m.body.length);
    Deno.writeFileSync(path, bytes);
  }
  for (const [pkg, versions] of lockedJsrVersions(denoLock)) {
    const url = `${jsrBase()}${pkg}/meta.json`;
    const path = joinPath(target, await cachePath(url));
    Deno.mkdirSync(dirname(path), { recursive: true });
    Deno.writeTextFileSync(path, cacheFile(versionListBody(pkg, versions), url, {}));
  }
  const npm = joinPath(denoDir, "npm");
  if (exists(npm)) {
    copyTree(npm, joinPath(target, "npm"));
    for (const rel of walk(joinPath(target, "npm"))) {
      if (rel.endsWith("/registry.json")) Deno.removeSync(joinPath(target, "npm", rel));
    }
  }
}

async function lock(
  rootArg: string | null,
  lockfilePath: string | null,
  toolLockPath: string | null,
  extra: string[],
) {
  const started = Date.now();
  const root = findRoot(rootArg ?? Deno.cwd());
  const members = readMembers(root);
  const programs = readPrograms(root, members);
  const modules = projectModules(root, members);
  const entrypoints = modules.length > 0 ? ["--entrypoint", ...modules] : [];

  const work = Deno.makeTempDirSync({ prefix: "deno-purifier-" });
  try {
    const project = joinPath(work, "project");
    const denoDir = joinPath(work, "deno-dir");
    copyTree(root, project);
    // With a deno.lock outside the project, the lock run starts from that
    // file when it exists, and from the copy in the project otherwise.
    if (toolLockPath !== null && exists(toolLockPath)) {
      Deno.copyFileSync(toolLockPath, joinPath(project, "deno.lock"));
    }
    const env = { DENO_DIR: denoDir, DENO_NO_UPDATE_CHECK: "1", NO_COLOR: "1" };

    // A first pass lets Deno write deno.lock where it is missing or does not
    // cover the project, with a cache of its own. Deno keeps every
    // resolution that deno.lock holds. The downloads are then always
    // recorded from a frozen pass into an empty cache, so the record does
    // not depend on whether deno.lock changed: a frozen install reads
    // redirects from deno.lock and fetches their targets alone, as the
    // sandbox does.
    log("completing deno.lock");
    const completeEnv = { ...env, DENO_DIR: joinPath(work, "complete-deno-dir") };
    for (const args of [["install"], ["install", ...entrypoints]]) {
      const install = await run(args, { cwd: project, env: completeEnv });
      if (!install.ok) fail(explainFailure(args.slice(0, 1).join(" "), install.output));
    }
    // A node_modules the first pass made would let the frozen pass skip the
    // downloads it must record.
    for (const rel of walkDirs(project)) {
      Deno.removeSync(joinPath(project, rel), { recursive: true });
    }

    log(`installing the dependencies and ${modules.length} modules into an empty DENO_DIR`);
    for (const args of [["install", "--frozen"], ["install", "--frozen", ...entrypoints]]) {
      const install = await run(args, { cwd: project, env });
      if (!install.ok) fail(explainFailure(args.slice(0, 2).join(" "), install.output));
    }
    // Type checking fetches type-only dependencies, such as @types/node.
    if (modules.length > 0) {
      const check = await run(["check", "--frozen", ...modules], { cwd: project, env });
      if (!check.ok) {
        log("`deno check` reported type errors; the lock run continues, and a build with doCheck reports them too.");
      }
    }
    if (extra.length > 0) {
      const r = await run(extra, { cwd: project, env });
      if (!r.ok) fail(explainFailure(extra.join(" "), r.output));
    }

    const denoLockText = Deno.readTextFileSync(joinPath(project, "deno.lock"));
    const denoLock = JSON.parse(denoLockText);
    const { modules: cached, jsrFiles, headers } = await readRemote(denoDir, denoLock);

    log("checking that the recorded downloads serve the project offline");
    const verifyDir = joinPath(work, "verify-deno-dir");
    const verifyProject = joinPath(work, "verify-project");
    await rebuild(verifyDir, denoDir, cached, denoLock);
    copyTree(project, verifyProject);
    for (
      const args of [
        ["install", "--frozen", "--cached-only"],
        ["install", "--frozen", "--cached-only", ...entrypoints],
      ]
    ) {
      const verify = await run(args, { cwd: verifyProject, env: { ...env, DENO_DIR: verifyDir } });
      if (!verify.ok) {
        fail(
          `the recorded downloads do not serve \`deno ${args.join(" ")}\`; ` +
            `this is a deno-purifier bug, please report it with this output:\n${verify.output}`,
        );
      }
    }

    // The project keeps its own deno.lock as it is when the lock run writes
    // one outside the project.
    const denoLockTarget = toolLockPath ?? joinPath(root, "deno.lock");
    if (!exists(denoLockTarget) || denoLockText !== Deno.readTextFileSync(denoLockTarget)) {
      Deno.writeTextFileSync(denoLockTarget, denoLockText);
      log(`wrote ${denoLockTarget}`);
    }
    const configs: Record<string, string> = {};
    for (const m of members) {
      configs[m.config] = hex(await sha256(Deno.readFileSync(joinPath(root, m.config))));
    }
    const sorted = <T>(record: Record<string, T>) =>
      Object.fromEntries(Object.entries(record).sort(([a], [b]) => (a < b ? -1 : 1)));
    const lockfile = {
      version: LOCK_VERSION,
      contentHash: "",
      denoLock: hex(await sha256(new TextEncoder().encode(denoLockText))),
      configs,
      jsrRegistry: jsrBase(),
      npmRegistries: readNpmRegistries(root),
      members,
      programs,
      jsrFiles: sorted(jsrFiles),
      headers: sorted(headers),
    };
    const target = lockfilePath ?? joinPath(root, LOCK_FILE);
    Deno.writeTextFileSync(target, await withContentHash(JSON.stringify(lockfile, null, 2) + "\n"));
    const seconds = ((Date.now() - started) / 1000).toFixed(1);
    log(
      `wrote ${target} in ${seconds}s: ${Object.keys(jsrFiles).length} JSR files, ` +
        `${Object.keys(headers).length} modules with headers, ${members.length} packages, ` +
        `${programs.length} programs`,
    );
  } finally {
    Deno.removeSync(work, { recursive: true });
  }
}

// Updates the project's dependencies with `deno update`, all of them or the
// named ones, within their version requirements or, with --latest, to the
// latest versions. Deno writes deno.json and deno.lock; the lock run then
// records the downloads, letting Deno add what the code imports to
// deno.lock.
//
// With a deno.lock outside the project, the update runs in a copy of the
// project and leaves the project as it is. The new deno.lock goes to the
// outside file, and the lock run completes it for the deno.json of the
// project, which an external build cannot change.
async function update(
  rootArg: string | null,
  lockfilePath: string | null,
  toolLockPath: string | null,
  latest: boolean,
  packages: string[],
) {
  const root = findRoot(rootArg ?? Deno.cwd());
  if (toolLockPath !== null && latest) {
    fail(
      "--latest changes the version requirements in deno.json, which a build with a deno.lock " +
        "outside the project cannot change. Update deno.json in the project, or leave out the " +
        "deno.lock outside the project.",
    );
  }
  const work = Deno.makeTempDirSync({ prefix: "deno-purifier-update-" });
  try {
    log(`updating ${packages.length > 0 ? packages.join(", ") : "every dependency"}`);
    const args = ["update", "--recursive", ...(latest ? ["--latest"] : []), ...packages];
    let cwd = root;
    if (toolLockPath !== null) {
      cwd = joinPath(work, "project");
      copyTree(root, cwd);
      if (exists(toolLockPath)) Deno.copyFileSync(toolLockPath, joinPath(cwd, "deno.lock"));
    }
    const result = await run(args, {
      cwd,
      env: { DENO_DIR: joinPath(work, "deno-dir"), DENO_NO_UPDATE_CHECK: "1", NO_COLOR: "1" },
    });
    if (!result.ok) fail(explainFailure(args.join(" "), result.output));
    if (toolLockPath !== null) Deno.copyFileSync(joinPath(cwd, "deno.lock"), toolLockPath);
  } finally {
    Deno.removeSync(work, { recursive: true });
  }
  await lock(root, lockfilePath, toolLockPath, []);
}

function usage(): never {
  console.error(`usage: deno-purifier lock [--root DIR] [--lockfile PATH] [--tool-lockfile PATH] [-- DENO-ARGS...]
       deno-purifier update [--root DIR] [--lockfile PATH] [--tool-lockfile PATH] [--latest] [PACKAGE...]

lock records the downloads of the Deno project at DIR (default: the
nearest directory upwards with a deno.lock) in deno-purifier.lock.json. It
keeps the resolution deno.lock holds, and writes deno.lock only where it is
missing or does not cover the project. update first updates the
dependencies with \`deno update\`, all of them or each PACKAGE, then runs
lock.

  --lockfile PATH       write the lockfile to PATH rather than to
                        deno-purifier.lock.json at DIR; the environment
                        variable DENO_PURIFIER_LOCKFILE does the same
  --tool-lockfile PATH  write deno.lock to PATH and leave the deno.lock at
                        DIR as it is. When PATH does not exist yet, the
                        lock run starts from the deno.lock at DIR. The
                        environment variable DENO_PURIFIER_TOOL_LOCKFILE
                        does the same
  --latest              update to the latest versions, regardless of the
                        version requirements in deno.json
  DENO-ARGS             one more Deno command to run in the lock run, for
                        modules a task imports at run time, such as
                        \`task build\``);
  Deno.exit(2);
}

// A path from a flag or from an environment variable, made absolute so that
// the lock run, which changes directory, finds the same file.
function absolute(path: string | null | undefined): string | null {
  if (path === null || path === undefined || path === "") return null;
  return path.startsWith("/") ? path : joinPath(Deno.cwd(), path);
}

if (import.meta.main) {
  const [verb, ...rest] = Deno.args;
  if (verb !== "lock" && verb !== "update") usage();
  let root: string | null = null;
  let lockfile: string | null = null;
  let toolLockfile: string | null = null;
  let latest = false;
  let extra: string[] = [];
  const packages: string[] = [];
  for (let i = 0; i < rest.length; i++) {
    if (rest[i] === "--root" && i + 1 < rest.length) root = rest[++i];
    else if (rest[i] === "--lockfile" && i + 1 < rest.length) lockfile = rest[++i];
    else if (rest[i] === "--tool-lockfile" && i + 1 < rest.length) toolLockfile = rest[++i];
    else if (verb === "update" && rest[i] === "--latest") latest = true;
    else if (verb === "lock" && rest[i] === "--") {
      extra = rest.slice(i + 1);
      break;
    } else if (verb === "update" && !rest[i].startsWith("-")) packages.push(rest[i]);
    else usage();
  }
  const lockfilePath = absolute(lockfile ?? Deno.env.get("DENO_PURIFIER_LOCKFILE"));
  const toolLockPath = absolute(toolLockfile ?? Deno.env.get("DENO_PURIFIER_TOOL_LOCKFILE"));
  if (verb === "lock") await lock(root, lockfilePath, toolLockPath, extra);
  else await update(root, lockfilePath, toolLockPath, latest, packages);
}
