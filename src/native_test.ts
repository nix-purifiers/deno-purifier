// SPDX-License-Identifier: MIT
import { type NativeContext, validate } from "./native.ts";
const sdk = "/nix/store/" + "a".repeat(32) + "-sdk";
function context(): NativeContext {
  return {
    schemaVersion: 1,
    sdk,
    executable: sdk + "/bin/deno",
    executableHash: "sha256-" + "A".repeat(43) + "=",
    version: "1.0.0",
    closure: [{ path: sdk, narHash: "sha256-" + "A".repeat(43) + "=" }],
    capabilities: {
      install: false,
      frozen: false,
      check: false,
      compile: false,
      publish: false,
      task: false,
      update: false,
    },
    cachePaths: {
      "https://example.com/leaf.js": "deps/https/example.com/" + "a".repeat(64),
    },
    redirects: {
      "https://example.com/entry.js": {
        path: "deps/https/example.com/" + "b".repeat(64),
        location: "/leaf.js",
        target: "https://example.com/leaf.js",
      },
    },
    lockVersion: "flat",
    modules: ["main.js"],
  };
}
Deno.test("native redirect graph terminates at a captured source", () =>
  validate(context()));
const mutations: [string, (v: NativeContext) => void][] = [
  ["cycle", (v) => {
    v.redirects["https://example.com/entry.js"].target =
      "https://example.com/entry.js";
    v.redirects["https://example.com/entry.js"].location = "/entry.js";
  }],
  ["missing terminal", (v) => {
    v.cachePaths = {};
  }],
  ["rewritten target", (v) => {
    v.redirects["https://example.com/entry.js"].target =
      "https://example.com/other.js";
  }],
  ["path collision", (v) => {
    v.redirects["https://example.com/entry.js"].path =
      Object.values(v.cachePaths)[0];
  }],
  ["credentials", (v) => {
    v.redirects["https://example.com/entry.js"].location =
      "https://user@example.com/leaf.js";
  }],
  ["fragment", (v) => {
    v.redirects["https://example.com/entry.js"].location = "/leaf.js#x";
  }],
];
for (const [name, mutate] of mutations) {
  Deno.test("native redirects reject " + name, () => {
    const v = context();
    mutate(v);
    try {
      validate(v);
    } catch {
      return;
    }
    throw new Error("malformed native redirect accepted");
  });
}
