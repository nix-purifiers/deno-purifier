// SPDX-License-Identifier: MIT
//
// The parts of the lock run that read and write text, without files or
// processes, so that src/lib_test.ts tests them directly.

export type Json =
  | null
  | boolean
  | number
  | string
  | Json[]
  | { [k: string]: Json };

export interface Program {
  name: string;
  member: string;
  task: string;
  entrypoint: string;
  flags: string[];
  args: string[];
}

// The line Deno writes between a cached module body and its metadata.
export const MARKER = "\n// denoCacheMetadata=";

// The response headers Deno reads from its cache: the media type, the
// types of a JavaScript module, a redirect target and a warning to print.
export const KEPT_HEADERS = [
  "content-type",
  "location",
  "x-deno-warning",
  "x-typescript-types",
];

// Turns JSON with comments and trailing commas, as Deno accepts it in
// deno.jsonc, into plain JSON. Strings keep their content, including
// slashes.
export function stripJsonc(text: string): string {
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
      const end = text.indexOf("*/", i + 2);
      i = end < 0 ? text.length : end + 2;
    } else {
      out += c;
      i++;
    }
  }
  // A comma before a closing bracket, outside strings. Strings are
  // skipped whole so that a string ending in a comma stays as it is.
  let result = "";
  for (let k = 0; k < out.length; k++) {
    const c = out[k];
    if (c === '"') {
      let j = k + 1;
      while (j < out.length && out[j] !== '"') j += out[j] === "\\" ? 2 : 1;
      result += out.slice(k, j + 1);
      k = j;
    } else if (c === ",") {
      let j = k + 1;
      while (j < out.length && /\s/.test(out[j])) j++;
      if (out[j] !== "}" && out[j] !== "]") result += c;
    } else {
      result += c;
    }
  }
  return result;
}

// Splits shell text into commands and their words, keeping quoted strings
// together. Task commands are shell text that Deno's task runner reads; a
// `deno compile` command in them is plain words.
export function shellWords(text: string): string[][] {
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

// The flags a program leaves out: the output, which the builder chooses,
// the cross-compilation target, and the lockfile and cache flags, which
// the builder sets.
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

function basename(path: string): string {
  return path.slice(path.lastIndexOf("/") + 1);
}

// The program a `deno compile` command builds, or null for any other
// command. `member` is the directory of the workspace member whose task
// holds the command.
export function parseCompile(
  words: string[],
  member: string,
  task: string,
): Program | null {
  if (words[0] !== "deno" || words[1] !== "compile") return null;
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
    const eq = w.indexOf("=");
    const flag = eq < 0 ? w : w.slice(0, eq);
    const inline = eq < 0 ? null : w.slice(eq + 1);
    const value = inline ?? (COMPILE_VALUE_FLAGS.has(flag) ? words[++i] ?? null : null);
    if (flag === "-o" || flag === "--output") output = value;
    if (COMPILE_DROPPED_FLAGS.has(flag)) continue;
    flags.push(value === null ? flag : `${flag}=${value}`);
  }
  if (entrypoint === null) return null;
  const name = output === null ? basename(entrypoint).replace(/\.[^.]*$/, "") : basename(output);
  return { name, member, task, entrypoint, flags, args };
}

// The npm registry of the default scope ("") and of each scope with its
// own, from the texts of .npmrc files in the order Deno reads them: a file
// earlier in the list wins. NPM_CONFIG_REGISTRY, when set, sets the default
// registry. Every registry URL ends with a slash.
export function parseNpmrc(
  texts: string[],
  envRegistry: string | undefined,
): Record<string, string> {
  const registries: Record<string, string> = {};
  for (const text of texts) {
    for (const line of text.split("\n")) {
      const m = line.trim().match(/^(@[^:\s]+:)?registry\s*=\s*(\S+)$/);
      if (!m) continue;
      const scope = m[1] ? m[1].slice(0, -1) : "";
      registries[scope] ??= m[2];
    }
  }
  if (envRegistry) registries[""] = envRegistry;
  registries[""] ??= "https://registry.npmjs.org/";
  for (const k of Object.keys(registries)) {
    if (!registries[k].endsWith("/")) registries[k] += "/";
  }
  return registries;
}

// Splits a file of Deno's remote module cache into the module body and its
// metadata, or returns null when the file has no metadata line.
export function splitCacheFile(
  bytes: Uint8Array,
): { body: Uint8Array; meta: { url: string; headers: Record<string, string> } } | null {
  const marker = new TextEncoder().encode(MARKER);
  for (let i = bytes.length - marker.length; i >= 0; i--) {
    let match = true;
    for (let j = 0; j < marker.length && match; j++) match = bytes[i + j] === marker[j];
    if (match) {
      const meta = JSON.parse(new TextDecoder().decode(bytes.slice(i + marker.length)));
      return { body: bytes.slice(0, i), meta };
    }
  }
  return null;
}

// The headers of a cache entry that Deno reads back.
export function keptHeaders(headers: Record<string, unknown>): Record<string, string> {
  const kept: Record<string, string> = {};
  for (const h of KEPT_HEADERS) {
    if (typeof headers?.[h] === "string") kept[h] = headers[h] as string;
  }
  return kept;
}

// A whole cache file, as Deno writes it, with a fetch time of 0.
export function cacheFile(body: string, url: string, headers: Record<string, string>): string {
  return body + MARKER + JSON.stringify({ headers, url, time: 0 });
}

// The package a JSR version list (<jsr>/<scope>/<name>/meta.json) belongs
// to, as @scope/name, or null for any other URL.
export function jsrVersionListOf(url: string, jsr: string): string | null {
  if (!url.startsWith(jsr)) return null;
  const m = url.slice(jsr.length).match(/^(@[^/]+\/[^/]+)\/meta\.json$/);
  return m ? m[1] : null;
}

// The versions of each JSR package that deno.lock names.
export function lockedJsrVersions(denoLock: Record<string, Json>): Map<string, Set<string>> {
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

// A JSR version list trimmed to the given versions, without the `latest`
// field, so that it stays the same until deno.lock changes.
export function trimVersionList(text: string, keep: Set<string>): string {
  const list = JSON.parse(text);
  const versions: Record<string, Json> = {};
  for (const [v, info] of Object.entries(list.versions ?? {})) {
    if (keep.has(v)) versions[v] = info as Json;
  }
  list.versions = versions;
  delete list.latest;
  return JSON.stringify(list);
}

// The output of a failed Deno command, without the progress lines of its
// downloads, and with what to do next when the cause is known.
export function explainFailure(command: string, output: string): string {
  const lines = output
    .split("\n")
    .filter((l) => !/^(Download|Initialize) /.test(l.replace(/\x1b\[[0-9;]*m/g, "")))
    .join("\n")
    .trim();
  let advice = "";
  if (output.includes("lockfile is out of date")) {
    advice = "\n\ndeno.lock does not cover every module the project imports with this Deno. " +
      "Run `deno-purifier lock --update` to let the lock run update deno.lock too.";
  } else if (output.includes("Integrity check failed")) {
    advice = "\n\nA download no longer matches the hash in deno.lock. " +
      "If the change is expected, run `deno-purifier lock --update` to record the new hash.";
  }
  return `\`deno ${command}\` failed in the lock run:\n${lines}${advice}`;
}

// The text of a lockfile with its contentHash filled in. The text holds the
// field once, empty: `"contentHash": ""`. The hash is the SHA-256, in hex,
// of that text, so Nix checks it by putting the empty value back.
export async function withContentHash(text: string): Promise<string> {
  const empty = '"contentHash": ""';
  if (text.split(empty).length !== 2) {
    throw new Error(`the lockfile text must hold ${empty} once`);
  }
  const digest = new Uint8Array(
    await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text)),
  );
  const hex = Array.from(digest, (b) => b.toString(16).padStart(2, "0")).join("");
  return text.replace(empty, `"contentHash": "${hex}"`);
}
