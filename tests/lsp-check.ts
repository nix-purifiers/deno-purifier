// SPDX-License-Identifier: MIT
//
// Starts `deno lsp` (whatever `deno` is on PATH) in a project, opens files
// and prints the diagnostics the server publishes for each, as an editor
// would see them. It exits with 1 when a file has a diagnostic or the
// server publishes none within a minute.
//
//   deno run -A tests/lsp-check.ts <absolute project root> <file>...
const [root, ...files] = Deno.args;
let clean = true;
const child = new Deno.Command("deno", {
  args: ["lsp"],
  cwd: root,
  stdin: "piped",
  stdout: "piped",
  stderr: "null",
}).spawn();
const writer = child.stdin.getWriter();
const encoder = new TextEncoder();
let id = 0;
async function send(method: string, params: unknown, notify = false) {
  const body = JSON.stringify({ jsonrpc: "2.0", ...(notify ? {} : { id: ++id }), method, params });
  await writer.write(encoder.encode(`Content-Length: ${encoder.encode(body).length}\r\n\r\n${body}`));
}

const pending = new Set(files.map((f) => `file://${root}/${f}`));
const reader = child.stdout.getReader();
let buffer = new Uint8Array();
const decoder = new TextDecoder();
async function* messages() {
  while (true) {
    const text = decoder.decode(buffer);
    const header = text.match(/^Content-Length: (\d+)\r\n\r\n/);
    if (header) {
      const start = encoder.encode(header[0]).length;
      const length = Number(header[1]);
      if (buffer.length >= start + length) {
        yield JSON.parse(decoder.decode(buffer.slice(start, start + length)));
        buffer = buffer.slice(start + length);
        continue;
      }
    }
    const { value, done } = await reader.read();
    if (done) return;
    const next = new Uint8Array(buffer.length + value.length);
    next.set(buffer);
    next.set(value, buffer.length);
    buffer = next;
  }
}

await send("initialize", {
  processId: null,
  rootUri: `file://${root}`,
  workspaceFolders: [{ uri: `file://${root}`, name: "project" }],
  capabilities: { workspace: { configuration: true, workspaceFolders: true } },
  initializationOptions: { enable: true, lint: false },
});
const timer = setTimeout(() => {
  console.log(`timed out waiting for ${[...pending].join(", ")}`);
  Deno.exit(1);
}, 60000);
for await (const message of messages()) {
  // The server's own requests, which an editor answers: Deno is enabled for
  // every configuration section it asks about.
  if (message.method !== undefined && message.id !== undefined) {
    const result = message.method === "workspace/configuration"
      ? message.params.items.map(() => ({ enable: true, lint: false }))
      : null;
    const body = JSON.stringify({ jsonrpc: "2.0", id: message.id, result });
    await writer.write(encoder.encode(`Content-Length: ${encoder.encode(body).length}\r\n\r\n${body}`));
    continue;
  }
  if (message.id === 1) {
    await send("initialized", {}, true);
    for (const f of files) {
      await send("textDocument/didOpen", {
        textDocument: {
          uri: `file://${root}/${f}`,
          languageId: "typescript",
          version: 1,
          text: Deno.readTextFileSync(`${root}/${f}`),
        },
      }, true);
    }
  }
  if (message.method === "textDocument/publishDiagnostics" && pending.has(message.params.uri)) {
    const errors = message.params.diagnostics.map((d: { message: string }) => d.message);
    if (errors.length > 0) clean = false;
    console.log(`${message.params.uri.slice(root.length + 8)}: ${errors.length === 0 ? "no diagnostics" : errors.join(" | ")}`);
    pending.delete(message.params.uri);
    if (pending.size === 0) break;
  }
}
clearTimeout(timer);
await send("shutdown", null);
await send("exit", null, true);
await writer.close();
await child.status;
Deno.exit(clean ? 0 : 1);
