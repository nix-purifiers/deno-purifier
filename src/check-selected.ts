// SPDX-License-Identifier: MIT
// A prepared environment never permits a different selected project SDK.
import {
  command,
  hash,
  type NativeContext,
  origin,
  validate,
} from "./native.ts";
const [file, sdk, defaultSdk, verb] = Deno.args;
const text = Deno.readTextFileSync(file);
if (text.length > 16777216) throw new Error("native lock exceeds size limit");
const value = JSON.parse(text);
if (value.native === undefined) {
  if (sdk !== defaultSdk) {
    throw new Error("selected Deno SDK needs a lock captured with that SDK");
  }
} else {
  const record = value.native as NativeContext;
  validate(record);
  const found = [...text.matchAll(/"contentHash": *"([0-9a-f]{64})"/g)];
  if (found.length !== 1) {
    throw new Error("native lock content hash is missing or ambiguous");
  }
  const clean = text.replace('"' + found[0][1] + '"', '""');
  const bytes = new Uint8Array(
    await crypto.subtle.digest("SHA-256", new TextEncoder().encode(clean)),
  );
  const digest = Array.from(bytes, (x) => x.toString(16).padStart(2, "0")).join(
    "",
  );
  if (digest !== found[0][1]) {
    throw new Error("native lock content hash differs");
  }
  const actual = await origin(sdk);
  const executable = Deno.realPathSync(actual.executable);
  if (actual.version !== record.version) {
    throw new Error("actual selected runtime version differs");
  }
  if (
    record.sdk !== sdk || record.executable !== executable ||
    await hash(Deno.readFileSync(executable)) !== record.executableHash
  ) throw new Error("selected Deno runtime differs from the captured SDK");
  if (verb) {
    const result = await command(sdk + "/bin/deno", [verb, "--help"]);
    const help = new TextDecoder().decode(result.stdout);
    if (!result.success) {
      throw new Error("selected native SDK has no " + verb + " capability");
    }
    if (
      [
        "run",
        "test",
        "check",
        "cache",
        "info",
        "compile",
        "doc",
        "serve",
        "eval",
        "repl",
        "bench",
      ].includes(verb) &&
      (!help.includes("--cached-only") || !help.includes("--lock"))
    ) {
      throw new Error(
        "selected native SDK has no cache-only locked " + verb +
          " interface; use deno-purifier prefetch for cache construction",
      );
    }
  }
}
