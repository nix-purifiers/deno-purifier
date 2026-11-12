// SPDX-License-Identifier: MIT
// Standalone physical verification inside an ordinary Nix build. The SDK
// graph is exported by Nix, never supplied as a package passthru list.
import {
  command,
  hash,
  type NativeContext,
  origin,
  validate,
  validateCachePath,
} from "./native.ts";
const [recordFile, sdk, nix, graphFile] = Deno.args;
const record = JSON.parse(Deno.readTextFileSync(recordFile)) as NativeContext;
validate(record);
for (
  const [url, path] of Object.entries({
    ...record.cachePaths,
    ...Object.fromEntries(
      Object.entries(record.redirects).map(([url, row]) => [url, row.path]),
    ),
  })
) {
  await validateCachePath(url, path);
}
if (sdk !== record.sdk) {
  throw new Error("selected SDK differs from the captured native SDK");
}
const graph = JSON.parse(Deno.readTextFileSync(graphFile)).projectSdk as {
  path: string;
}[];
const actualPaths = graph.map((row) => row.path).sort();
if (
  JSON.stringify(actualPaths) !== JSON.stringify(
    record.closure.map((row) => row.path).sort(),
  )
) throw new Error("selected SDK recursive closure differs");
for (const row of record.closure) {
  const result = await command(nix, [
    "--extra-experimental-features",
    "nix-command",
    "hash",
    "path",
    "--type",
    "sha256",
    "--sri",
    row.path,
  ]);
  if (
    !result.success ||
    new TextDecoder().decode(result.stdout).trim() !== row.narHash
  ) throw new Error("physical SDK NAR differs: " + row.path);
}
const actual = await origin(sdk);
const executable = Deno.realPathSync(actual.executable);
if (actual.version !== record.version) {
  throw new Error("actual runtime origin version differs");
}
if (
  executable !== record.executable ||
  await hash(Deno.readFileSync(executable)) !== record.executableHash
) throw new Error("actual native executable differs");
const result = await command(executable, ["--version"]);
if (
  !result.success ||
  new TextDecoder().decode(result.stdout).split(/\s+/)[1] !== record.version
) throw new Error("actual native SDK version differs");
const help = async (name: string) => {
  const r = await command(executable, [name, "--help"]);
  return r.success ? new TextDecoder().decode(r.stdout) : "";
};
const capabilities = {
  install: (await help("install")).includes("--entrypoint"),
  frozen: (await help("cache")).includes("--frozen"),
  check: !!await help("check"),
  compile: !!await help("compile"),
  publish: !!await help("publish"),
  task: !!await help("task"),
  update: !!await help("update"),
};
if (
  !Object.entries(capabilities).every(([key, value]) =>
    record.capabilities[key as keyof typeof capabilities] === value
  )
) throw new Error("actual native SDK capabilities differ");
console.log(
  "VERIFIED|" + record.version + "|" + record.executableHash + "|" +
    actualPaths.length,
);
