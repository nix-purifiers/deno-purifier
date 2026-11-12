# SPDX-License-Identifier: MIT
import hashlib
import json
import os
from pathlib import Path
import tempfile
import sys
import time
import unittest
from bounded_command import run, run_recorded

class BoundedCommandTests(unittest.TestCase):
    def command(self, code, **options):
        return run([sys.executable, "-u", "-c", code], **options)

    def test_exit_and_raw_streams(self):
        result = self.command('import sys;print("out");print("err",file=sys.stderr);sys.exit(7)', timeout=2)
        self.assertEqual((result.returncode, result.stdout, result.stderr), (7, b"out\n", b"err\n"))

    def test_timeout_preserves_partial_output(self):
        with self.assertRaises(TimeoutError) as caught:
            self.command('import time;print("before");time.sleep(5)', timeout=.3)
        self.assertEqual(caught.exception.stdout, b"before\n")

    def test_orphan_holding_pipe(self):
        start = time.monotonic()
        with self.assertRaises(TimeoutError) as caught:
            self.command('import subprocess,sys;print("parent");subprocess.Popen([sys.executable,"-c","import time;time.sleep(5)"])', timeout=.3)
        self.assertIn(b"parent\n", caught.exception.stdout)
        self.assertLess(time.monotonic() - start, 2)

    def test_closed_pipes_live_parent(self):
        start = time.monotonic()
        with self.assertRaises(TimeoutError):
            self.command('import os,time;os.close(1);os.close(2);time.sleep(5)', timeout=.3)
        self.assertLess(time.monotonic() - start, 2)

    def test_output_limit_preserves_raw_bytes(self):
        with self.assertRaises(ValueError) as caught:
            self.command('import sys,time;sys.stdout.write("x"*10000);sys.stdout.flush();time.sleep(5)', timeout=2, output_limit=100)
        self.assertGreater(len(caught.exception.stdout), 100)
        self.assertEqual(caught.exception.stdout.strip(b"x"), b"")

    def test_recorded_failure_and_nonzero_retention(self):
        with tempfile.TemporaryDirectory() as directory:
            logs = Path(directory)
            for label, code, options, failure in [
                ("timeout", 'import time;print("retained");time.sleep(5)', {"timeout": .3}, TimeoutError),
                ("limit", 'print("x"*10000)', {"timeout": 2,"output_limit": 100}, ValueError),
                ("nonzero", 'import sys;print("retained");sys.exit(9)', {"timeout": 2}, None),
            ]:
                record = {"label": label}
                argv = [sys.executable, "-u", "-c", code]
                save = lambda: (logs / "receipt.json").write_text(json.dumps(record))
                if failure:
                    with self.assertRaises(failure):
                        run_recorded(argv, record=record, logs=logs, save=save, **options)
                else:
                    self.assertEqual(run_recorded(argv, record=record, logs=logs, save=save, **options).returncode, 9)
                persisted = json.loads((logs / "receipt.json").read_text())
                self.assertEqual(persisted["argv"], argv)
                self.assertEqual(persisted["exit"], None if failure else 9)
                if failure:
                    self.assertEqual(persisted["boundedFailure"]["type"], failure.__name__)
                for stream in ("stdout", "stderr"):
                    raw = (logs / (label + "." + stream)).read_bytes()
                    self.assertEqual(hashlib.sha256(raw).hexdigest(), persisted[stream + "Sha256"])
                self.assertTrue((logs / (label + ".stdout")).read_bytes())

    def test_success_cleans_owned_orphan(self):
        with tempfile.TemporaryDirectory() as directory:
            heartbeat = Path(directory) / "heartbeat"
            child = 'import time;f=open(' + repr(str(heartbeat)) + ',"ab",buffering=0)\nwhile True:f.write(b"x");time.sleep(.02)'
            parent = 'import subprocess,sys,time,os;subprocess.Popen([sys.executable,"-u","-c",' + repr(child) + '],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)\nwhile not os.path.exists(' + repr(str(heartbeat)) + '):time.sleep(.01)'
            self.assertEqual(self.command(parent, timeout=2).returncode, 0)
            size = heartbeat.stat().st_size
            time.sleep(.15)
            self.assertEqual(heartbeat.stat().st_size, size)
