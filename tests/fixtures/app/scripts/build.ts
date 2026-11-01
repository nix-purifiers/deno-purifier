// Transpiles the greeting package with esbuild, whose native binary comes
// from a per-platform npm package.
import * as esbuild from "esbuild";

const source = await Deno.readTextFile("greeting/mod.ts");
const out = await esbuild.transform(source, { loader: "ts", format: "esm" });
await Deno.mkdir("dist", { recursive: true });
await Deno.writeTextFile("dist/greeting.js", out.code);
await esbuild.stop();
