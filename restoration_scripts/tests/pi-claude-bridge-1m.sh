#!/usr/bin/env bash
# Exercise the pi-claude-bridge 1M patch only against disposable HOME directories.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
export PATCH_SCRIPT="$ROOT/scripts/patch-pi-claude-bridge-1m"
PYTHONDONTWRITEBYTECODE=1 python3 - <<'PY'
import os
from pathlib import Path
import stat
import subprocess
import tempfile
import unittest

SCRIPT = Path(os.environ["PATCH_SCRIPT"])
UPSTREAM = '''// header
const MEASURED_ONE_M = new Set([
\t"claude-fable-5",
\t"claude-opus-5-5",
\t"claude-sonnet-5",
]);

const PLAN_GATED_ONE_M = {};
'''


class PatchTests(unittest.TestCase):
    def setUp(self):
        self.sandbox = tempfile.TemporaryDirectory(prefix="pi-bridge-1m-test-")
        self.addCleanup(self.sandbox.cleanup)
        self.home = Path(self.sandbox.name) / "home"
        self.home.mkdir()
        self.target = self.home / ".pi/agent/npm/node_modules/pi-claude-bridge/src/models.ts"

    def run_patch(self, *args):
        return subprocess.run(
            ["python3", str(SCRIPT), *args], cwd=self.sandbox.name,
            env={**os.environ, "HOME": str(self.home), "PYTHONDONTWRITEBYTECODE": "1"},
            text=True, capture_output=True,
        )

    def seed(self, text=UPSTREAM, mode=0o644):
        self.target.parent.mkdir(parents=True, exist_ok=True)
        self.target.write_text(text)
        self.target.chmod(mode)
        return self.target.read_bytes()

    def test_missing_id_is_added_once_and_everything_else_survives(self):
        self.seed()
        result = self.run_patch()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("claude-sonnet-5-5", result.stdout)
        expected = UPSTREAM.replace('\t"claude-sonnet-5",\n', '\t"claude-sonnet-5",\n\t"claude-sonnet-5-5",\n')
        self.assertEqual(self.target.read_text(), expected)
        self.assertEqual(stat.S_IMODE(self.target.stat().st_mode), 0o644)

        inode, patched = self.target.stat().st_ino, self.target.read_bytes()
        again = self.run_patch()
        self.assertEqual(again.returncode, 0, again.stderr)
        self.assertIn("already", again.stdout)
        self.assertEqual((self.target.stat().st_ino, self.target.read_bytes()), (inode, patched))

    def test_upstream_that_already_measures_the_id_is_left_untouched(self):
        before = self.seed(UPSTREAM.replace('"claude-fable-5",', '"claude-sonnet-5-5",'))
        inode = self.target.stat().st_ino
        result = self.run_patch()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.target.stat().st_ino, self.target.read_bytes()), (inode, before))

    def test_missing_bridge_is_skipped_without_creating_anything(self):
        result = self.run_patch()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("not installed", result.stdout)
        self.assertFalse((self.home / ".pi").exists())

    def test_unrecognized_layout_is_refused_and_left_untouched(self):
        for text in ("export const nothing = 1;\n",
                     UPSTREAM + UPSTREAM,
                     UPSTREAM.replace("]);", "])")):
            with self.subTest(text=text[:40]):
                before = self.seed(text)
                result = self.run_patch()
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(self.target.read_bytes(), before)

    def test_symlinked_models_file_is_refused(self):
        self.target.parent.mkdir(parents=True)
        destination = Path(self.sandbox.name) / "elsewhere.ts"
        destination.write_text(UPSTREAM)
        self.target.symlink_to(destination)
        result = self.run_patch()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(destination.read_text(), UPSTREAM)

    def test_every_argument_is_rejected_before_touching_the_file(self):
        before = self.seed()
        for args in (("--help",), ("--force",), ("claude-sonnet-5-5",)):
            with self.subTest(args=args):
                result = self.run_patch(*args)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(self.target.read_bytes(), before)

    def test_cli_is_executable(self):
        self.assertTrue(SCRIPT.stat().st_mode & stat.S_IXUSR)


unittest.main(verbosity=2)
PY
