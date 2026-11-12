// SPDX-License-Identifier: MIT
// The host helper and the project's native SDK have independent roles.
export function projectDeno(): string {
  return Deno.env.get("DENO_PURIFIER_PROJECT_DENO") ?? Deno.execPath();
}
export function cleanEnvironment(
  extra: Record<string, string> = {},
): Record<string, string> {
  const env = { ...Deno.env.toObject(), ...extra };
  delete env.LD_LIBRARY_PATH;
  delete env.LD_PRELOAD;
  return env;
}
export interface Capabilities {
  install: boolean;
  frozen: boolean;
  check: boolean;
  compile: boolean;
  publish: boolean;
  task: boolean;
  update: boolean;
}
export interface NativeContext {
  schemaVersion: 1;
  sdk: string;
  executable: string;
  executableHash: string;
  version: string;
  closure: { path: string; narHash: string }[];
  capabilities: Capabilities;
  cachePaths: Record<string, string>;
  redirects: Record<string, { path: string; location: string; target: string }>;
  lockVersion: string;
  modules: string[];
}
export async function hash(bytes: Uint8Array): Promise<string> {
  const digest = new Uint8Array(
    await crypto.subtle.digest("SHA-256", new Uint8Array(bytes)),
  );
  return "sha256-" + btoa(String.fromCharCode(...digest));
}
export async function command(
  executable: string,
  args: string[],
  options: Deno.CommandOptions = {},
) {
  return await new Deno.Command(executable, {
    ...options,
    clearEnv: true,
    env: cleanEnvironment(options.env),
    args,
    stdout: "piped",
    stderr: "piped",
  }).output();
}
export async function origin(
  sdk: string,
): Promise<{ executable: string; version: string }> {
  const code =
    'console.log("DENO_PURIFIER_NATIVE_ORIGIN|"+JSON.stringify({executable:Deno.execPath(),version:Deno.version.deno}))';
  const result = await command(sdk + "/bin/deno", ["eval", code]);
  const lines = new TextDecoder().decode(result.stdout).split("\n").filter((
    line,
  ) => line.startsWith("DENO_PURIFIER_NATIVE_ORIGIN|"));
  if (!result.success || lines.length !== 1) {
    throw new Error(
      "selected SDK did not expose its actual native runtime origin",
    );
  }
  const value = JSON.parse(
    lines[0].slice("DENO_PURIFIER_NATIVE_ORIGIN|".length),
  );
  if (
    !value || typeof value.executable !== "string" ||
    typeof value.version !== "string"
  ) throw new Error("invalid actual native runtime origin");
  return value;
}
let inspected: Promise<NativeContext | null> | undefined;
export function inspect(): Promise<NativeContext | null> {
  return inspected ??= inspectOnce();
}
async function inspectOnce(): Promise<NativeContext | null> {
  const projectSdk = Deno.env.get("DENO_PURIFIER_PROJECT_SDK");
  const helperSdk = Deno.env.get("DENO_PURIFIER_HELPER_SDK");
  const executablePath = projectDeno();
  if (projectSdk === undefined || projectSdk === helperSdk) return null;
  if (
    !projectSdk || !/^\/nix\/store\/[a-z0-9]{32}-[^/]+$/.test(projectSdk) ||
    executablePath !== projectSdk + "/bin/deno"
  ) {
    throw new Error(
      "selected Deno must be an explicit immutable SDK executable",
    );
  }
  const nix = Deno.env.get("DENO_PURIFIER_NIX");
  if (!nix || !nix.startsWith("/nix/store/")) {
    throw new Error("selected SDK requires its explicit Nix identity helper");
  }
  const version = await command(executablePath, ["--version"]);
  const text = new TextDecoder().decode(version.stdout);
  const match = text.match(
    /^deno ([0-9]+\.[0-9]+\.[0-9]+(?:[-+][0-9A-Za-z.-]+)?)(?:\s|$)/,
  );
  if (!version.success || !match) {
    throw new Error("selected SDK did not report a native Deno version");
  }
  const help = async (name: string) => {
    const r = await command(executablePath, [name, "--help"]);
    return r.success ? new TextDecoder().decode(r.stdout) : "";
  };
  const installHelp = await help("install");
  const cacheHelp = await help("cache");
  if (!cacheHelp) {
    throw new Error("selected SDK has no supported native cache interface");
  }
  const capabilities = {
    install: installHelp.includes("--entrypoint"),
    frozen: cacheHelp.includes("--frozen"),
    check: !!await help("check"),
    compile: !!await help("compile"),
    publish: !!await help("publish"),
    task: !!await help("task"),
    update: !!await help("update"),
  };
  const graph = await command(nix, [
    "path-info",
    "--recursive",
    "--json",
    projectSdk,
  ]);
  if (!graph.success) {
    throw new Error(
      "cannot determine actual selected SDK closure: " +
        new TextDecoder().decode(graph.stderr),
    );
  }
  const raw = JSON.parse(new TextDecoder().decode(graph.stdout));
  const closure = Object.entries(raw).map(([path, entry]) => ({
    path,
    narHash: (entry as { narHash: string }).narHash,
  })).sort((a, b) => a.path < b.path ? -1 : 1);
  const actual = await origin(projectSdk);
  if (actual.version !== match[1]) {
    throw new Error("selected SDK reports conflicting native runtime versions");
  }
  const executable = Deno.realPathSync(actual.executable);
  const value: NativeContext = {
    schemaVersion: 1,
    sdk: projectSdk,
    executable,
    executableHash: await hash(Deno.readFileSync(executable)),
    version: match[1],
    closure,
    capabilities,
    cachePaths: {},
    redirects: {},
    lockVersion: "pending",
    modules: [],
  };
  validate(value, true);
  return value;
}
const pathPattern = /^\/nix\/store\/[a-z0-9]{32}-[^/]+$/;
const sri = /^sha256-[A-Za-z0-9+/]{42}[AEIMQUYcgkosw048]=$/;
function exact(
  value: unknown,
  keys: string[],
): asserts value is Record<string, unknown> {
  if (
    !value || typeof value !== "object" || Array.isArray(value) ||
    Object.keys(value).sort().join("\0") !== keys.sort().join("\0")
  ) throw new Error("invalid native SDK record fields");
}
export function validate(value: NativeContext, pending = false) {
  exact(value, [
    "schemaVersion",
    "sdk",
    "executable",
    "executableHash",
    "version",
    "closure",
    "capabilities",
    "cachePaths",
    "redirects",
    "lockVersion",
    "modules",
  ]);
  if (
    value.schemaVersion !== 1 || !pathPattern.test(value.sdk) ||
    !sri.test(value.executableHash) ||
    !/^[0-9]+\.[0-9]+\.[0-9]+(?:[-+][0-9A-Za-z.-]+)?$/.test(value.version)
  ) throw new Error("invalid selected SDK identity");
  if (
    !Array.isArray(value.closure) || value.closure.length === 0 ||
    value.closure.length > 4096
  ) throw new Error("invalid selected SDK closure");
  const paths = new Set<string>();
  for (const row of value.closure) {
    exact(row, ["path", "narHash"]);
    if (
      !pathPattern.test(row.path) || !sri.test(row.narHash) ||
      paths.has(row.path)
    ) throw new Error("invalid or duplicate selected SDK closure path");
    paths.add(row.path);
  }
  if (
    !paths.has(value.sdk) ||
    !value.closure.some((row) => value.executable.startsWith(row.path + "/"))
  ) throw new Error("native executable is outside the selected SDK closure");
  exact(value.capabilities, [
    "install",
    "frozen",
    "check",
    "compile",
    "publish",
    "task",
    "update",
  ]);
  if (!Object.values(value.capabilities).every((v) => typeof v === "boolean")) {
    throw new Error("invalid native capabilities");
  }
  if (
    !value.cachePaths || typeof value.cachePaths !== "object" ||
    Array.isArray(value.cachePaths) ||
    Object.keys(value.cachePaths).length > 100000
  ) throw new Error("invalid native cache map");
  if (!pending && !["flat", "2", "3", "4", "5"].includes(value.lockVersion)) {
    throw new Error("unsupported native lock schema");
  }
  if (
    !Array.isArray(value.modules) || value.modules.length > 100000 ||
    (!pending && value.modules.length === 0) ||
    new Set(value.modules).size !== value.modules.length ||
    !value.modules.every((path) =>
      typeof path === "string" && !path.startsWith("/") &&
      !/[\\\r\n\0]/.test(path) && path.split("/").every((part) =>
        part !== "" && part !== "." && part !== ".."
      )
    )
  ) throw new Error("invalid native project entrypoint paths");
  const destinations = new Set<string>();
  for (const [url, path] of Object.entries(value.cachePaths)) {
    if (!validCachePath(url, path) || destinations.has(path)) {
      throw new Error("unsafe or duplicate native cache mapping");
    }
    destinations.add(path);
  }
  if (
    !value.redirects || typeof value.redirects !== "object" ||
    Array.isArray(value.redirects) ||
    Object.keys(value.redirects).length > 100000
  ) {
    throw new Error("invalid native redirect map");
  }
  for (const [url, redirect] of Object.entries(value.redirects)) {
    exact(redirect, ["path", "location", "target"]);
    if (
      !validCachePath(url, redirect.path) || destinations.has(redirect.path) ||
      url in value.cachePaths || typeof redirect.location !== "string" ||
      redirect.location.length > 8192 || /[\r\n\0]/.test(redirect.location)
    ) {
      throw new Error("invalid or duplicate native redirect");
    }
    const target = new URL(redirect.location, url);
    if (
      target.href !== redirect.target ||
      !["http:", "https:"].includes(target.protocol) ||
      target.username || target.password || target.hash
    ) {
      throw new Error("invalid native redirect target");
    }
    destinations.add(redirect.path);
    const seen = new Set<string>();
    let next = url;
    while (next in value.redirects) {
      if (seen.has(next) || seen.size >= 256) {
        throw new Error("native redirect cycle");
      }
      seen.add(next);
      next = value.redirects[next].target;
    }
    if (!(next in value.cachePaths)) {
      throw new Error("native redirect has no pinned terminal source");
    }
  }
}
// The digest is checked asynchronously alongside the downloaded source before
// any output is written. This predicate checks the structural path boundary.
export function validCachePath(url: string, path: string): boolean {
  try {
    const u = new URL(url);
    if (
      !["http:", "https:"].includes(u.protocol) || u.username || u.password ||
      u.hash || !/^[A-Za-z0-9.-]+$/.test(u.hostname)
    ) return false;
    const hosts = u.port
      ? [u.hostname + "_PORT" + u.port, u.hostname + "_port_" + u.port]
      : [u.hostname];
    return ["deps", "remote"].some((root) =>
      hosts.some((host) =>
        new RegExp(
          "^" + root + "/" + u.protocol.slice(0, -1) + "/" +
            host.replaceAll(".", "\\.") + "/[0-9a-f]{64}$",
        ).test(path)
      )
    );
  } catch {
    return false;
  }
}
export async function validateCachePath(url: string, path: string) {
  if (!validCachePath(url, path)) {
    throw new Error("unsafe native URL/cache path");
  }
  const u = new URL(url);
  const bytes = new Uint8Array(
    await crypto.subtle.digest(
      "SHA-256",
      new TextEncoder().encode(u.pathname + u.search),
    ),
  );
  const digest = Array.from(bytes, (x) => x.toString(16).padStart(2, "0")).join(
    "",
  );
  if (!path.endsWith("/" + digest)) {
    throw new Error("native cache URL digest differs");
  }
}
export function nativeRemote(
  lock: Record<string, unknown>,
  context: NativeContext | null,
): Record<string, string> {
  if (context && !("version" in lock)) {
    if (
      !Object.entries(lock).every(([url, digest]) => {
        try {
          return ["http:", "https:"].includes(new URL(url).protocol) &&
            typeof digest === "string" && /^[a-f0-9]{64}$/.test(digest);
        } catch {
          return false;
        }
      })
    ) throw new Error("unsupported flat native lock schema");
    return lock as Record<string, string>;
  }
  return (lock.remote ?? {}) as Record<string, string>;
}
