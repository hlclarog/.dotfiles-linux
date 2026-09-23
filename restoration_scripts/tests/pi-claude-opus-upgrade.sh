#!/usr/bin/env bash
# Exercise the manual Opus migration only against disposable HOME directories.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
export UPGRADE_SCRIPT="$ROOT/scripts/upgrade-pi-claude-opus"
PYTHONDONTWRITEBYTECODE=1 python3 - <<'PY'
import json
import os
from pathlib import Path
import stat
import subprocess
import tempfile
import unittest

SCRIPT = Path(os.environ["UPGRADE_SCRIPT"])
OLD = "claude-bridge/claude-opus-5"
NEW = "claude-bridge/claude-opus-5-5"


class UpgradeTests(unittest.TestCase):
    def setUp(self):
        self.sandbox = tempfile.TemporaryDirectory(prefix="pi-opus-upgrade-test-")
        self.addCleanup(self.sandbox.cleanup)
        self.root = Path(self.sandbox.name)
        self.home = self.root / "home"
        self.home.mkdir()
        self.target = self.home / ".pi/gentle-ai/profiles.json"

    def run_upgrade(self, *args):
        return subprocess.run(
            ["python3", str(SCRIPT), *args], cwd=self.root,
            env={**os.environ, "HOME": str(self.home), "PYTHONDONTWRITEBYTECODE": "1"},
            text=True, capture_output=True,
        )

    def registry(self, **overrides):
        return {"kind": "gentle-pi.agent_model_profiles", "version": 1,
                "profiles": {}, "active": "current", **overrides}

    def seed(self, registry):
        self.target.parent.mkdir(parents=True, exist_ok=True)
        self.target.write_bytes((json.dumps(registry, indent=2) + "\n").encode())
        return self.target.read_bytes()

    def backups(self):
        return list(self.target.parent.glob("profiles.json.backup-*"))

    def assert_no_leak(self, result):
        output = result.stdout + result.stderr
        for secret in (OLD, NEW, "private-registry-value"):
            self.assertNotIn(secret, output)

    def test_all_49_exact_references_change_and_everything_else_survives(self):
        profiles = {}
        for name, count in (("current", 22), ("claude-full", 22), ("claude-full.autogen", 5)):
            profiles[name] = {
                f"role-{index}": {"model": OLD, "thinking": "max", "extra": [1, True]}
                for index in range(count)
            }
            profiles[name]["other-provider"] = {"model": "anthropic/claude-opus-5", "thinking": "low"}
            profiles[name]["similar-suffix"] = {"model": OLD + "-preview", "thinking": "off"}
        profiles["open-ai-full.autogen"] = {"orchestrator": {"model": "openai-codex/gpt-5", "thinking": "high"}}
        original = self.registry(profiles=profiles, active="claude-full.autogen",
                                 credential="private-registry-value", unrelated={"nested": [3, 2]})
        before = self.seed(original)
        result = self.run_upgrade()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("49", result.stdout)
        self.assert_no_leak(result)
        expected = json.loads(before)
        for profile in expected["profiles"].values():
            for role in profile.values():
                if role.get("model") == OLD:
                    role["model"] = NEW
        self.assertEqual(json.loads(self.target.read_bytes()), expected)
        self.assertEqual(stat.S_IMODE(self.target.stat().st_mode), 0o600)
        backups = self.backups()
        self.assertEqual(len(backups), 1)
        self.assertEqual(backups[0].read_bytes(), before)
        self.assertEqual(stat.S_IMODE(backups[0].stat().st_mode), 0o600)

        inode = self.target.stat().st_ino
        updated = self.target.read_bytes()
        again = self.run_upgrade()
        self.assertEqual(again.returncode, 0, again.stderr)
        self.assertIn("0", again.stdout)
        self.assertEqual((self.target.stat().st_ino, self.target.read_bytes()), (inode, updated))
        self.assertEqual(self.backups(), backups)
        self.assert_no_leak(again)

    def test_no_old_reference_is_no_op_without_backup_or_reformat(self):
        before = self.seed(self.registry(profiles={"current": {"role": {
            "model": NEW, "thinking": "high"}}}))
        inode = self.target.stat().st_ino
        result = self.run_upgrade()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("0", result.stdout)
        self.assertEqual((self.target.stat().st_ino, self.target.read_bytes()), (inode, before))
        self.assertEqual(self.backups(), [])
        self.assert_no_leak(result)

    def test_cli_is_executable(self):
        self.assertTrue(SCRIPT.stat().st_mode & stat.S_IXUSR)

    def test_missing_registry_refused_without_creating_it(self):
        result = self.run_upgrade()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.target.exists())
        self.assert_no_leak(result)

    def test_malformed_or_unsupported_registry_refused_without_backup(self):
        self.target.parent.mkdir(parents=True)
        invalid = [b"{broken", b'{"kind":"gentle-pi.agent_model_profiles","kind":"bad","version":1,"profiles":{},"active":"current"}',
                   b'{"kind":"gentle-pi.agent_model_profiles","version":1,"profiles":{},"active":"current","other":1e400}',
                   b'{"kind":"gentle-pi.agent_model_profiles","version":1,"profiles":{},"active":"current","other":NaN}',
                   json.dumps(self.registry(version=2)).encode(),
                   json.dumps(self.registry(version=True)).encode(),
                   json.dumps(self.registry(kind="wrong")).encode(),
                   json.dumps(self.registry(active=None)).encode(),
                   json.dumps(self.registry(profiles=[])).encode(),
                   json.dumps(self.registry(profiles={"current": []})).encode(),
                   json.dumps(self.registry(profiles={"current": {"role": "invalid"}})).encode(),
                   json.dumps(self.registry(profiles={"current": {"role": {"model": 5}}})).encode()]
        for before in invalid:
            with self.subTest(before=before[:70]):
                self.target.write_bytes(before)
                result = self.run_upgrade()
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(self.target.read_bytes(), before)
                self.assertEqual(self.backups(), [])
                self.assert_no_leak(result)

    def test_symlink_registry_refused_and_link_destination_untouched(self):
        self.target.parent.mkdir(parents=True)
        destination = self.root / "unrelated.json"
        before = (json.dumps(self.registry(profiles={"current": {
            "role": {"model": OLD, "thinking": "max"}}})) + "\n").encode()
        destination.write_bytes(before)
        self.target.symlink_to(destination)
        result = self.run_upgrade()
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(self.target.is_symlink())
        self.assertEqual(destination.read_bytes(), before)
        self.assertEqual(self.backups(), [])
        self.assert_no_leak(result)

    def test_reject_every_argument_before_touching_registry(self):
        before = self.seed(self.registry(profiles={"current": {
            "role": {"model": OLD, "thinking": "max"}}}))
        for args in (("--help",), ("--force",), (str(self.root / "other"),), ("--",)):
            with self.subTest(args=args):
                result = self.run_upgrade(*args)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(self.target.read_bytes(), before)
                self.assertEqual(self.backups(), [])
                self.assert_no_leak(result)


unittest.main(verbosity=2)
PY
