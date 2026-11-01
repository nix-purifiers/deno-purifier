// SPDX-License-Identifier: MIT
//
// Unit tests of the lock run's text handling. They import nothing beyond
// lib.ts, so they run offline: `deno test --no-config --no-lock src/`.

import {
  cacheFile,
  explainFailure,
  jsrVersionListOf,
  keptHeaders,
  lockedJsrVersions,
  parseCompile,
  parseNpmrc,
  shellWords,
  splitCacheFile,
  stripJsonc,
  versionListBody,
  withContentHash,
  cachePath,
  headersMatter,
} from "./lib.ts";

function assertEquals(actual: unknown, expected: unknown) {
  const a = JSON.stringify(actual);
  const e = JSON.stringify(expected);
  if (a !== e) throw new Error(`expected ${e}\n     got ${a}`);
}

Deno.test("stripJsonc removes comments and trailing commas outside strings", () => {
  const text = `{
    // a comment
    "url": "https://jsr.io/x", /* another */
    "s": "a // not a comment, ",
    "list": [1, 2,],
  }`;
  assertEquals(JSON.parse(stripJsonc(text)), {
    url: "https://jsr.io/x",
    s: "a // not a comment, ",
    list: [1, 2],
  });
});

Deno.test("shellWords splits commands and keeps quoted words", () => {
  assertEquals(
    shellWords(`deno run -A 'a b.ts' && deno compile -o "out dir/x" main.ts; echo \\;done`),
    [
      ["deno", "run", "-A", "a b.ts"],
      ["deno", "compile", "-o", "out dir/x", "main.ts"],
      ["echo", ";done"],
    ],
  );
});

Deno.test("parseCompile reads the entrypoint, flags, output and arguments", () => {
  assertEquals(
    parseCompile(
      ["deno", "compile", "--allow-env", "--output", "bin/hello", "--frozen", "--target", "x", "main.ts", "--flag"],
      "cli",
      "compile",
    ),
    {
      name: "hello",
      member: "cli",
      task: "compile",
      entrypoint: "main.ts",
      flags: ["--allow-env"],
      args: ["--flag"],
    },
  );
});

Deno.test("parseCompile names a program after its entrypoint without an output", () => {
  assertEquals(parseCompile(["deno", "compile", "-A", "src/tool.ts"], "", "build")?.name, "tool");
});

Deno.test("parseCompile keeps flags with an inline value", () => {
  assertEquals(
    parseCompile(["deno", "compile", "--allow-read=.", "-o=x", "m.ts"], "", "t")?.flags,
    ["--allow-read=."],
  );
});

Deno.test("parseCompile ignores other commands", () => {
  assertEquals(parseCompile(["deno", "run", "main.ts"], "", "t"), null);
  assertEquals(parseCompile(["deno", "compile", "-A"], "", "t"), null);
});

Deno.test("parseNpmrc takes the first file's registries and the environment's default", () => {
  assertEquals(
    parseNpmrc(
      [
        "registry=https://project.example\n@acme:registry=https://acme.example/npm/",
        "registry=https://user.example/\n@other:registry=https://other.example",
      ],
      undefined,
    ),
    {
      "": "https://project.example/",
      "@acme": "https://acme.example/npm/",
      "@other": "https://other.example/",
    },
  );
  assertEquals(parseNpmrc([], "https://env.example")[""], "https://env.example/");
  assertEquals(parseNpmrc([], undefined)[""], "https://registry.npmjs.org/");
});

Deno.test("splitCacheFile and cacheFile are inverses", () => {
  const file = cacheFile("export const x = 1;\n// denoCacheMetadata= in a body", "https://e.example/x.ts", {
    "content-type": "application/typescript",
  });
  const split = splitCacheFile(new TextEncoder().encode(file));
  assertEquals(new TextDecoder().decode(split!.body), "export const x = 1;\n// denoCacheMetadata= in a body");
  assertEquals(split!.meta, {
    headers: { "content-type": "application/typescript" },
    url: "https://e.example/x.ts",
    time: 0,
  });
});

Deno.test("splitCacheFile rejects a file without metadata", () => {
  assertEquals(splitCacheFile(new TextEncoder().encode("plain")), null);
});

Deno.test("keptHeaders keeps the headers Deno reads", () => {
  assertEquals(
    keptHeaders({ "content-type": "text/javascript", "etag": "x", "location": "/y", "date": "today" }),
    { "content-type": "text/javascript", "location": "/y" },
  );
});

Deno.test("jsrVersionListOf recognizes version lists only", () => {
  assertEquals(jsrVersionListOf("https://jsr.io/@std/path/meta.json", "https://jsr.io/"), "@std/path");
  assertEquals(jsrVersionListOf("https://jsr.io/@std/path/1.0.0_meta.json", "https://jsr.io/"), null);
  assertEquals(jsrVersionListOf("https://jsr.io/@std/path/1.0.0/meta.json", "https://jsr.io/"), null);
  assertEquals(jsrVersionListOf("https://deno.land/@std/path/meta.json", "https://jsr.io/"), null);
});

Deno.test("versionListBody lists the locked versions of a package, keys sorted", () => {
  const versions = lockedJsrVersions({
    jsr: { "@std/path@1.0.0": {}, "@std/path@0.9.0": {}, "@std/fmt@1.0.0": {} },
  });
  assertEquals(
    versionListBody("@std/path", versions.get("@std/path")!),
    '{"name":"path","scope":"std","versions":{"0.9.0":{},"1.0.0":{}}}',
  );
});

Deno.test("cachePath hashes the path and query, and names a port", async () => {
  // The hash is that of `/std@0.224.0/fmt/colors.ts`, from sha256sum.
  assertEquals(
    await cachePath("https://deno.land/std@0.224.0/fmt/colors.ts"),
    "remote/https/deno.land/cdde2da1e0655f7895b70ff820cf7c731b9cde333c7c62147ebac4b7109705b8",
  );
  const withPort = await cachePath("http://localhost:4545/a.ts?x=1");
  if (!withPort.startsWith("remote/http/localhost_PORT4545/")) throw new Error(withPort);
});

Deno.test("headersMatter keeps the headers Deno reads differently from the extension", () => {
  assertEquals(headersMatter("https://jsr.io/@std/fmt/1.0.0/colors.ts", {}), false);
  assertEquals(
    headersMatter("https://deno.land/x/a.ts", { "content-type": "application/typescript; charset=utf-8" }),
    false,
  );
  assertEquals(headersMatter("https://jsr.io/@x/y/1.0.0/a.js", { "content-type": "text/javascript" }), false);
  assertEquals(headersMatter("https://esm.sh/react@18", { "content-type": "application/javascript" }), true);
  assertEquals(headersMatter("https://example.com/a.ts", { "content-type": "application/javascript" }), true);
  assertEquals(
    headersMatter("https://esm.sh/a.js", { "content-type": "application/javascript", "x-typescript-types": "./a.d.ts" }),
    true,
  );
});

Deno.test("explainFailure drops download progress and advises on a stale deno.lock", () => {
  const text = explainFailure(
    "install --frozen",
    "Download https://jsr.io/x\n\x1b[32mDownload\x1b[0m https://jsr.io/y\nerror: The lockfile is out of date.",
  );
  if (text.includes("Download")) throw new Error(`download lines kept:\n${text}`);
  if (!text.includes("deno-purifier lock --update")) throw new Error(`no advice:\n${text}`);
});

Deno.test("withContentHash fills in the SHA-256 of the text with the empty value", async () => {
  // The hash is that of `{"version": 2, "contentHash": ""}`, from sha256sum.
  assertEquals(
    await withContentHash('{"version": 2, "contentHash": ""}'),
    '{"version": 2, "contentHash": "dfdb024c1bebdf75495d35d952080d6d7791886146a10e430966a956d6fb92b6"}',
  );
});

Deno.test("withContentHash refuses a text without exactly one empty contentHash", async () => {
  for (const text of ['{"version": 2}', '{"contentHash": "", "x": {"contentHash": ""}}']) {
    let refused = false;
    try {
      await withContentHash(text);
    } catch {
      refused = true;
    }
    if (!refused) throw new Error(`accepted ${text}`);
  }
});
