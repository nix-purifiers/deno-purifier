# SPDX-License-Identifier: MIT
"""Actual selected SDK, cold capture, offline runtime/tests and moved project."""
import argparse
from bounded_command import run as bounded_run
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import shutil
import threading

parser = argparse.ArgumentParser()
parser.add_argument("--cli", required=True, type=Path)
parser.add_argument("--version", required=True)
parser.add_argument("--work", required=True, type=Path)
parser.add_argument("--default-sdk", action="store_true")
parser.add_argument("--allow-import", action="store_true")
parser.add_argument("--seed-source", action="store_true", help="Local agent/daemon namespace qualification; CI leaves unset")
parser.add_argument("--redirect", action="store_true")
parser.add_argument("--empty-module", action="store_true")
parser.add_argument("--negative-cache", action="store_true")
args = parser.parse_args()
args.work.mkdir()
project = args.work / "project"
project.mkdir()
logs = args.work / "logs"
logs.mkdir()
home = args.work / "home"
home.mkdir()
cache = args.work / "cache"
cache.mkdir()
body = b"" if args.empty_module else b"export const answer=42;\n"
module_path = "/sdk-" + args.version + "/leaf.js"
requests = []

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *values):
        pass

    def do_GET(self):
        requests.append(self.path)
        if args.redirect and self.path == "/entry.js":
            self.send_response(302)
            self.send_header("Location", module_path)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        if self.path != module_path:
            self.send_error(404)
            return
        self.send_response(200)
        self.send_header("Content-Type", "application/javascript")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
thread = threading.Thread(target=server.serve_forever, daemon=True)
thread.start()
url = "http://127.0.0.1:" + str(server.server_port) + module_path
import_url = url.rsplit("/sdk-", 1)[0] + "/entry.js" if args.redirect else url
prefix = ("import " + json.dumps(import_url) + ";const answer=42;" if args.empty_module else "import {answer} from " + json.dumps(import_url) + ";")
(project / "main.js").write_text(prefix + 'if(answer!==42)throw new Error("wrong answer");console.log("ANSWER|42|"+Deno.version.deno);\n')
(project / "main_test.js").write_text(prefix + 'Deno.test("native answer",()=>{if(answer!==42)throw new Error("wrong answer")});\n')
if args.default_sdk:
    (project / "deno.json").write_text("{}\n")
base = dict(os.environ, HOME=str(home), XDG_CACHE_HOME=str(cache), TMPDIR=str(args.work.parent / "tmp"), NO_COLOR="1")
Path(base["TMPDIR"]).mkdir(exist_ok=True)
clean = {key: value for key, value in base.items() if "proxy" not in key.lower()}
receipt = dict(complete=False, scope="Actual native Deno client URL-module lifecycle; exact tested point only", version=args.version,
               sourceBodySha256=hashlib.sha256(body).hexdigest(), cli=str(args.cli), cliSha256=hashlib.sha256(args.cli.read_bytes()).hexdigest(), requests=requests, commands=[],
               nixSourceSeeded=args.seed_source, explicitImportPermission=args.allow_import, redirect=args.redirect, emptyModule=args.empty_module)

def save():
    (args.work / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")

def run(label, argv, expected=True, environment=None):
    argv = list(map(str, argv))
    result = bounded_run(argv, cwd=project, env=environment or clean, timeout=180, output_limit=16 * 1024 * 1024)
    record = dict(label=label, argv=argv, exit=result.returncode, expectedSuccess=expected)
    for stream in ["stdout", "stderr"]:
        raw = getattr(result, stream)
        (logs / (label + "." + stream)).write_bytes(raw)
        record[stream + "Sha256"] = hashlib.sha256(raw).hexdigest()
    receipt["commands"].append(record)
    save()
    assert (result.returncode == 0) == expected, (label, result.stdout, result.stderr)
    return result

try:
    if args.seed_source:
        seed = args.work / hashlib.sha256(module_path.encode()).hexdigest()
        seed.write_bytes(body)
        result = run("qualified-local-source-seed", ["nix-store", "--add-fixed", "sha256", seed], environment=base)
        receipt["nixSourceSeedPath"] = result.stdout.decode().strip()
    run("capture", [args.cli, "lock", "--root", project])
    original = (project / "deno-purifier.lock.json").read_bytes()
    native_lock = (project / "deno.lock").read_bytes()
    document = json.loads(original)
    assert ("native" in document) != args.default_sdk
    if not args.default_sdk:
        assert document["native"]["version"] == args.version
        assert document["native"]["cachePaths"][url].split("/")[0] == ("deps" if args.version.startswith("1.") else "remote")
    if args.redirect:
        if args.version == "1.0.0":
            assert document["native"]["redirects"][import_url]["target"] == url
        else:
            assert json.loads(native_lock)["redirects"][import_url] == url
    run("capture-noop", [args.cli, "lock", "--root", project])
    assert (project / "deno-purifier.lock.json").read_bytes() == original
    assert (project / "deno.lock").read_bytes() == native_lock
    if args.negative_cache:
        path = document["native"]["cachePaths"][url]
        prefix_js = 'const p=Deno.env.get("DENO_DIR")+"/"+' + json.dumps(path) + ';'
        corruptions = {
            "source-hash": 'Deno.writeTextFileSync(p,"corrupted source");',
            "cache-symlink": 'Deno.removeSync(p);Deno.symlinkSync("/etc/passwd",p);',
        }
        if path.startswith("deps/"):
            corruptions["header-types"] = 'const m=JSON.parse(Deno.readTextFileSync(p+".metadata.json"));m.headers={location:42};Deno.writeTextFileSync(p+".metadata.json",JSON.stringify(m));'
        for name, corrupt in corruptions.items():
            run("reject-" + name, [args.cli, "lock", "--root", project, "--", "eval", prefix_js + corrupt], expected=False)
            assert (project / "deno.lock").read_bytes() == native_lock
            assert (project / "deno-purifier.lock.json").read_bytes() == original
        main = project / "main.js"
        valid_source = main.read_bytes()
        for scheme in ["npm:", "jsr:"]:
            main.write_text('import ' + json.dumps(scheme + "unsupported-scope") + ';\n')
            run("reject-scope-" + scheme[:-1], [args.cli, "lock", "--root", project], expected=False)
            assert (project / "deno.lock").read_bytes() == native_lock
            assert (project / "deno-purifier.lock.json").read_bytes() == original
            main.write_bytes(valid_source)
        if not document["native"]["capabilities"]["update"]:
            run("reject-missing-update", [args.cli, "update", "--root", project], expected=False)
            assert (project / "deno.lock").read_bytes() == native_lock
            assert (project / "deno-purifier.lock.json").read_bytes() == original
    run("prefetch", [args.cli, "prefetch", "--root", project], environment=base)
finally:
    server.shutdown()
    server.server_close()
    thread.join(timeout=5)
# The source-owned fixture SDK already carries this explicit native flag.
# Passing it twice is rejected by genuine Deno 2.0.
permission = []
runtime = args.cli.parent / "deno"
for label in ["original", "relocated"]:
    if label == "relocated":
        previous = project
        project = args.work / "relocated"
        shutil.copytree(previous, project, symlinks=True, ignore=shutil.ignore_patterns(".deno-purifier"))
        shutil.rmtree(previous)
        assert not previous.exists()
        run("relocated-prefetch", [args.cli, "prefetch", "--root", project], environment=base)
    result = run(label + "-runtime", [runtime, "run", *permission, "main.js"])
    assert ("ANSWER|42|" + args.version).encode() in result.stdout
    run(label + "-native-tests", [runtime, "test", *permission])
    assert (project / "deno.lock").read_bytes() == native_lock
receipt.update(complete=True, serverClosedBeforeRuntime=True, originalProjectRemoved=True,
               nativeContext=document.get("native"), sourceLockSha256=hashlib.sha256(native_lock).hexdigest())
save()
