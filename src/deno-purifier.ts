// SPDX-License-Identifier: MIT
//
// deno-purifier: records what a Deno project downloads, for Nix.
//
//   deno-purifier lock [--root DIR] [-- DENO-ARGS...]
//
// The lock run copies the project to a temporary directory and runs
// `deno install` on every module of the project there, with an empty
// DENO_DIR and the network. Deno downloads every remote module, every JSR
// file and every npm package the project needs into that DENO_DIR. The lock
// run then writes deno-purifier.lock.json at the project root:
//
//   remote    the entries of Deno's remote module cache
//             (DENO_DIR/remote/<scheme>/<host>/<sha256 of path>), as
//             download entries of the purifier library. A module body is a
//             file entry, with the response headers Deno keeps beside it. A
//             JSR version list (meta.json) changes whenever the package
//             publishes, and a redirect has no body, so both are inline
//             entries that hold the whole cache file.
//   members   the project's packages: the root and its workspace members,
//             with their name, version, directory and tasks.
//   programs  one entry per `deno compile` command in the tasks.
//
// npm packages are not recorded: deno.lock names each one with its
// integrity and its platform filters, and Nix reads them from there.
//
// The lock run then rebuilds a DENO_DIR from what it recorded alone and
// runs `deno install --cached-only` against it, so a recorded lockfile is
// known to serve the project offline.
//
// DENO-ARGS, when given, are one more Deno command the lock run runs in the
// copy, such as `task build`, for modules a task imports at run time.

const LOCK_FILE = "deno-purifier.lock.json";
const LOCK_VERSION = 1;
const MARKER = "\n// denoCacheMetadata=";
// The response headers Deno reads from its cache: the media type, the
// types of a JavaScript module, a redirect target and a warning to print.
const KEPT_HEADERS = [
  "content-type",
  "location",
  "x-deno-warning",
  "x-typescript-types",
];
const SOURCE_EXTENSIONS = [
  ".ts",
  ".tsx",
  ".mts",
  ".cts",
  ".js",
  ".jsx",
  ".mjs",
  ".cjs",
];
// Directories that hold installed or generated files rather than the
// project's modules.
const SKIPPED_DIRS = new Set(["node_modules", "vendor"]);

type Json = null | boolean | number | string | Json[] | { [k: string]: Json };

interface FileEntry {
  path: string;
  url: string;
  mirrors: string[];
  hash: string;
  headers: Record<string, string>;
}

interface InlineEntry {
  path: string;
  contents: string;
}

interface Member {
  name: string | null;
  version: string | null;
  dir: string;
  config: string;
  tasks: string[];
}

interface Program {
  name: string;
  member: string;
  task: string;
  entrypoint: string;
  flags: string[];
  args: string[];
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

function basename(path: string): string {
  return path.slice(path.lastIndexOf("/") + 1);
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

// Reads JSON with comments and trailing commas, as Deno accepts them in
// deno.jsonc.
function readJsonc(path: string): Record<string, Json> {
  const text = Deno.readTextFileSync(path);
  let out = "";
  let i = 0;
  while (i < text.length) {
    const c = text[i];
    if (c === '"') {
      let j = i + 1;
      while (j < text.length && text[j] !== '"') j += text[j] === "\\" ? 2 : 1;
      out += text.slice(i, j + 1);
      i = j + 1;
    } else if (c === "/" && text[i + 1] === "/") {
      while (i < text.length && text[i] !== "\n") i++;
    } else if (c === "/" && text[i + 1] === "*") {
      i = text.indexOf("*/", i + 2);
      i = i < 0 ? text.length : i + 2;
    } else {
      out += c;
      i++;
    }
  }
  out = out.replace(/,(\s*[}\]])/g, "$1");
  try {
    return JSON.parse(out);
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
    else if (entry.isSymlink) {
      Deno.symlinkSync(Deno.readLinkSync(source), target);
    }
  }
}

// The project root: the nearest directory upwards with a deno.lock.
function findRoot(start: string): string {
  let dir = Deno.realPathSync(start);
  while (true) {
    if (exists(joinPath(dir, "deno.lock"))) return dir;
    if (dir === "/") {
      fail(
        "no deno.lock in this directory or above; run `deno install` to write one.",
      );
    }
    dir = dirname(dir);
  }
}

// The root and its workspace members, from their configuration files.
function readMembers(root: string): Member[] {
  const rootConfig = configIn(root);
  if (rootConfig === null) fail(`no deno.json or deno.jsonc in ${root}`);
  const dirs = [""];
  const config = readJsonc(joinPath(root, rootConfig));
  const workspace = config.workspace;
  const memberDirs = Array.isArray(workspace)
    ? workspace
    : (workspace && typeof workspace === "object" && !Array.isArray(workspace) &&
        Array.isArray(workspace.members))
    ? workspace.members
    : [];
  for (const m of memberDirs) {
    if (typeof m !== "string") continue;
    dirs.push(m.replace(/^\.\//, "").replace(/\/$/, ""));
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

// Splits shell text into words, keeping quoted strings together. Task
// commands are shell text that Deno's task runner reads; a `deno compile`
// command in them is plain words.
function shellWords(text: string): string[][] {
  const commands: string[][] = [[]];
  let word: string | null = null;
  let quote: string | null = null;
  const end = () => {
    if (word !== null) commands[commands.length - 1].push(word);
    word = null;
  };
  for (let i = 0; i < text.length; i++) {
    const c = text[i];
    if (quote !== null) {
      if (c === quote) quote = null;
      else if (c === "\\" && quote === '"' && i + 1 < text.length) word += text[++i];
      else word += c;
    } else if (c === "'" || c === '"') {
      quote = c;
      word = word ?? "";
    } else if (c === "\\" && i + 1 < text.length) {
      word = (word ?? "") + text[++i];
    } else if (/\s/.test(c)) {
      end();
    } else if (c === ";" || c === "|" || c === "&") {
      end();
      while (text[i + 1] === c) i++;
      commands.push([]);
    } else {
      word = (word ?? "") + c;
    }
  }
  end();
  return commands.filter((c) => c.length > 0);
}

// The flags of `deno compile` that take a value as the next word. The flags
// whose value is optional (`--lock`, `--reload`, `--env-file`) take it only
// after an equals sign.
const COMPILE_VALUE_FLAGS = new Set([
  "-o",
  "--output",
  "--target",
  "--include",
  "--exclude",
  "--icon",
  "-c",
  "--config",
  "--import-map",
  "--location",
  "--seed",
  "--cert",
]);
// The flags the lock run leaves out of a program: the output, which the
// builder chooses, the cross-compilation target, and the lockfile and cache
// flags, which the builder sets.
const COMPILE_DROPPED_FLAGS = new Set([
  "-o",
  "--output",
  "--target",
  "--lock",
  "--frozen",
  "--no-lock",
  "--cached-only",
  "--reload",
  "-r",
]);

function readPrograms(root: string, members: Member[]): Program[] {
  const programs: Program[] = [];
  for (const member of members) {
    for (const task of member.tasks) {
      for (const words of shellWords(taskCommand(root, member, task))) {
        if (words[0] !== "deno" || words[1] !== "compile") continue;
        const flags: string[] = [];
        let output: string | null = null;
        let entrypoint: string | null = null;
        const args: string[] = [];
        for (let i = 2; i < words.length; i++) {
          const w = words[i];
          if (entrypoint !== null) {
            args.push(w);
            continue;
          }
          if (!w.startsWith("-")) {
            entrypoint = w;
            continue;
          }
          const [flag, inline] = w.includes("=") ? w.split(/=(.*)/s, 2) : [w, null];
          const takesValue = inline === null && COMPILE_VALUE_FLAGS.has(flag);
          const value = inline ?? (takesValue ? words[++i] : null);
          if (flag === "-o" || flag === "--output") output = value;
          if (COMPILE_DROPPED_FLAGS.has(flag)) continue;
          flags.push(value === null ? flag : `${flag}=${value}`);
        }
        if (entrypoint === null) continue;
        const stem = basename(output ?? entrypoint).replace(/\.[^.]*$/, "");
        programs.push({
          name: output === null ? stem : basename(output),
          member: member.dir,
          task,
          entrypoint,
          flags,
          args,
        });
      }
    }
  }
  return programs;
}

// The registry URL of npm packages and of each scope, as Deno reads them.
// NPM_CONFIG_REGISTRY sets the default registry. Otherwise the project's
// .npmrc comes first and ~/.npmrc second.
function readNpmRegistries(root: string): Record<string, string> {
  const registries: Record<string, string> = {};
  const files = [joinPath(root, ".npmrc")];
  const home = Deno.env.get("HOME");
  if (home) files.push(joinPath(home, ".npmrc"));
  for (const file of files) {
    let text: string;
    try {
      text = Deno.readTextFileSync(file);
    } catch {
      continue;
    }
    for (const line of text.split("\n")) {
      const m = line.trim().match(/^(@[^:\s]+:)?registry\s*=\s*(\S+)$/);
      if (!m) continue;
      const scope = m[1] ? m[1].slice(0, -1) : "";
      registries[scope] ??= m[2];
    }
  }
  const env = Deno.env.get("NPM_CONFIG_REGISTRY");
  if (env) registries[""] = env;
  registries[""] ??= "https://registry.npmjs.org/";
  for (const k of Object.keys(registries)) {
    if (!registries[k].endsWith("/")) registries[k] += "/";
  }
  return registries;
}

function jsrBase(): string {
  const url = Deno.env.get("JSR_URL") ?? "https://jsr.io/";
  return url.endsWith("/") ? url : `${url}/`;
}

function lockedJsrVersions(denoLock: Record<string, Json>): Map<string, Set<string>> {
  const versions = new Map<string, Set<string>>();
  const jsr = denoLock.jsr;
  if (jsr && typeof jsr === "object" && !Array.isArray(jsr)) {
    for (const key of Object.keys(jsr)) {
      const at = key.lastIndexOf("@");
      const name = key.slice(0, at);
      if (!versions.has(name)) versions.set(name, new Set());
      versions.get(name)!.add(key.slice(at + 1));
    }
  }
  return versions;
}

function cacheFile(body: string, url: string, headers: Record<string, string>): string {
  return body + MARKER + JSON.stringify({ headers, url, time: 0 });
}

// Reads Deno's remote module cache into download entries.
async function readRemote(
  denoDir: string,
  denoLock: Record<string, Json>,
): Promise<{ files: FileEntry[]; inline: InlineEntry[]; bodies: Map<string, Uint8Array> }> {
  const files: FileEntry[] = [];
  const inline: InlineEntry[] = [];
  const bodies = new Map<string, Uint8Array>();
  const remoteDir = joinPath(denoDir, "remote");
  if (!exists(remoteDir)) return { files, inline, bodies };
  const jsr = jsrBase();
  const jsrVersions = lockedJsrVersions(denoLock);
  const encoder = new TextEncoder();
  const decoder = new TextDecoder();
  const markerBytes = encoder.encode(MARKER);
  for (const rel of walk(remoteDir).sort()) {
    const bytes = Deno.readFileSync(joinPath(remoteDir, rel));
    let at = -1;
    for (let i = bytes.length - markerBytes.length; i >= 0 && at < 0; i--) {
      let match = true;
      for (let j = 0; j < markerBytes.length && match; j++) {
        match = bytes[i + j] === markerBytes[j];
      }
      if (match) at = i;
    }
    if (at < 0) fail(`remote/${rel} has no cache metadata; this Deno's cache format is not known`);
    const body = bytes.slice(0, at);
    const meta = JSON.parse(decoder.decode(bytes.slice(at + markerBytes.length)));
    const url: string = meta.url;
    const headers: Record<string, string> = {};
    for (const h of KEPT_HEADERS) {
      if (meta.headers && typeof meta.headers[h] === "string") headers[h] = meta.headers[h];
    }
    const path = `remote/${rel}`;
    const metaMatch = url.startsWith(jsr) &&
      url.slice(jsr.length).match(/^(@[^/]+\/[^/]+)\/meta\.json$/);
    if (metaMatch) {
      // A JSR version list, trimmed to the versions deno.lock names, so the
      // recorded file stays the same until the lock changes.
      const versionList = JSON.parse(decoder.decode(body));
      const keep = jsrVersions.get(metaMatch[1]) ?? new Set();
      const versions: Record<string, Json> = {};
      for (const [v, info] of Object.entries(versionList.versions ?? {})) {
        if (keep.has(v)) versions[v] = info as Json;
      }
      versionList.versions = versions;
      delete versionList.latest;
      inline.push({ path, contents: cacheFile(JSON.stringify(versionList), url, headers) });
    } else if (body.length === 0) {
      inline.push({ path, contents: cacheFile("", url, headers) });
    } else {
      files.push({
        path,
        url,
        mirrors: [],
        hash: `sha256-${base64(await sha256(body))}`,
        headers,
      });
      bodies.set(path, body);
    }
  }
  return { files, inline, bodies };
}

// Builds a DENO_DIR from recorded entries alone, as Nix does, plus the npm
// packages Deno unpacked.
function rebuild(
  target: string,
  denoDir: string,
  files: FileEntry[],
  inline: InlineEntry[],
  bodies: Map<string, Uint8Array>,
) {
  const encoder = new TextEncoder();
  for (const f of files) {
    const path = joinPath(target, f.path);
    Deno.mkdirSync(dirname(path), { recursive: true });
    const trailer = encoder.encode(cacheFile("", f.url, f.headers));
    const body = bodies.get(f.path)!;
    const bytes = new Uint8Array(body.length + trailer.length);
    bytes.set(body);
    bytes.set(trailer, body.length);
    Deno.writeFileSync(path, bytes);
  }
  for (const e of inline) {
    const path = joinPath(target, e.path);
    Deno.mkdirSync(dirname(path), { recursive: true });
    Deno.writeTextFileSync(path, e.contents);
  }
  const npm = joinPath(denoDir, "npm");
  if (exists(npm)) {
    copyTree(npm, joinPath(target, "npm"));
    for (const rel of walk(joinPath(target, "npm"))) {
      if (basename(rel) === "registry.json") Deno.removeSync(joinPath(target, "npm", rel));
    }
  }
}

async function lock(rootArg: string | null, extra: string[]) {
  const root = findRoot(rootArg ?? Deno.cwd());
  const denoLockText = Deno.readTextFileSync(joinPath(root, "deno.lock"));
  const denoLock = JSON.parse(denoLockText);
  const members = readMembers(root);
  const programs = readPrograms(root, members);
  const modules = walk(root)
    .filter((f) => SOURCE_EXTENSIONS.some((e) => f.endsWith(e)))
    .sort();
  const entrypoints = modules.length > 0 ? ["--entrypoint", ...modules] : [];

  const work = Deno.makeTempDirSync({ prefix: "deno-purifier-" });
  try {
    const project = joinPath(work, "project");
    const denoDir = joinPath(work, "deno-dir");
    copyTree(root, project);
    const env = {
      DENO_DIR: denoDir,
      DENO_NO_UPDATE_CHECK: "1",
      NO_COLOR: "1",
    };

    // A plain `deno install` fetches the whole export graph of every JSR
    // package in the import map, beyond what the project's modules import;
    // `deno install --entrypoint` fetches what the modules import from
    // remote URLs too.
    log(`installing the dependencies and ${modules.length} modules into an empty DENO_DIR`);
    for (const args of [["install", "--frozen"], ["install", "--frozen", ...entrypoints]]) {
      const install = await run(args, { cwd: project, env });
      if (!install.ok) {
        fail(`\`deno ${args.join(" ")}\` failed in the lock run:\n${install.output}`);
      }
    }
    // Type checking fetches type-only dependencies, such as @types/node.
    if (modules.length > 0) {
      const check = await run(["check", "--frozen", ...modules], { cwd: project, env });
      if (!check.ok) {
        log("`deno check` reported errors; the lock run continues, and a build with doCheck reports them too.");
      }
    }
    if (extra.length > 0) {
      const r = await run(extra, { cwd: project, env });
      if (!r.ok) fail(`\`deno ${extra.join(" ")}\` failed in the lock run:\n${r.output}`);
    }

    const { files, inline, bodies } = await readRemote(denoDir, denoLock);

    log("checking that the recorded downloads serve the project offline");
    const verifyDir = joinPath(work, "verify-deno-dir");
    const verifyProject = joinPath(work, "verify-project");
    rebuild(verifyDir, denoDir, files, inline, bodies);
    copyTree(root, verifyProject);
    for (
      const args of [
        ["install", "--frozen", "--cached-only"],
        ["install", "--frozen", "--cached-only", ...entrypoints],
      ]
    ) {
      const verify = await run(args, { cwd: verifyProject, env: { ...env, DENO_DIR: verifyDir } });
      if (!verify.ok) {
        fail(`the recorded downloads do not serve \`deno ${args.join(" ")}\`:\n${verify.output}`);
      }
    }

    const configs: Record<string, string> = {};
    for (const m of members) {
      configs[m.config] = hex(await sha256(Deno.readFileSync(joinPath(root, m.config))));
    }
    const lockfile = {
      version: LOCK_VERSION,
      deno: Deno.version.deno,
      denoLock: hex(await sha256(new TextEncoder().encode(denoLockText))),
      configs,
      jsr: jsrBase(),
      npmRegistries: readNpmRegistries(root),
      members,
      programs,
      remote: [...files, ...inline].sort((a, b) => (a.path < b.path ? -1 : 1)),
    };
    Deno.writeTextFileSync(joinPath(root, LOCK_FILE), JSON.stringify(lockfile, null, 2) + "\n");
    log(
      `wrote ${LOCK_FILE}: ${files.length} module files, ${inline.length} inline cache entries, ${members.length} packages, ${programs.length} programs`,
    );
  } finally {
    Deno.removeSync(work, { recursive: true });
  }
}

function usage(): never {
  console.error(`usage: deno-purifier lock [--root DIR] [-- DENO-ARGS...]

Records the downloads of the Deno project at DIR (default: the nearest
directory upwards with a deno.lock) in deno-purifier.lock.json.`);
  Deno.exit(2);
}

const [verb, ...rest] = Deno.args;
if (verb === "lock") {
  let root: string | null = null;
  let extra: string[] = [];
  for (let i = 0; i < rest.length; i++) {
    if (rest[i] === "--root") root = rest[++i];
    else if (rest[i] === "--") {
      extra = rest.slice(i + 1);
      break;
    } else usage();
  }
  await lock(root, extra);
} else {
  usage();
}
