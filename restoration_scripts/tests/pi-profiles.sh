#!/usr/bin/env bash
# Run the manual Pi profile restore contract entirely in disposable HOME directories.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
export RESTORE_SCRIPT="$ROOT/scripts/restore-pi-profiles"
export RESTORE_SOURCE_DIR="$ROOT/config/pi"
python3 - <<'PY'
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import tempfile
import unittest

SCRIPT = Path(os.environ["RESTORE_SCRIPT"])
SOURCE_DIR = Path(os.environ["RESTORE_SOURCE_DIR"])
NAMES = ("codex-medium", "codex-low", "codex-high", "claude-high")
NAME = NAMES[0]
# Each entry is (source file, prefix required of every model, key inside that
# file -- None means the whole decoded file is the profile).
SOURCE_FILES = {
    "codex-medium": "codex-medium.json",
    "codex-low": "codex-low.json",
    "codex-high": "codex-high.json",
    "claude-high": "claude-profiles.json",
}
SOURCE_KEYS = {"claude-high": "claude-high"}
PREFIXES = {
    "codex-medium": "openai-codex/",
    "codex-low": "openai-codex/",
    "codex-high": "openai-codex/",
    "claude-high": "claude-bridge/",
}
CANONICAL_ORDER = [
    "orchestrator", "sdd-init", "sdd-onboard", "sdd-explore", "sdd-research",
    "sdd-proposal", "sdd-spec", "sdd-design", "sdd-tasks", "sdd-status",
    "sdd-apply", "sdd-verify", "sdd-sync", "sdd-archive", "jd-judge-a",
    "jd-judge-b", "jd-fix-agent", "gentle-ai-explore", "gentle-ai-verify",
    "gentle-ai-worker", "review-readability", "review-reliability",
    "review-resilience", "review-risk", "review-refuter", "review-validator",
]


def wrap(name, profile):
    key = SOURCE_KEYS.get(name)
    return {key: profile} if key else profile


def load_profile(source_dir, name):
    data = json.loads((source_dir / SOURCE_FILES[name]).read_text())
    key = SOURCE_KEYS.get(name)
    return data[key] if key else data


class RestoreTests(unittest.TestCase):
    def setUp(self):
        self.sandbox = tempfile.TemporaryDirectory(prefix="pi-profile-test-")
        self.addCleanup(self.sandbox.cleanup)
        self.root = Path(self.sandbox.name)
        self.home = self.root / "home"
        self.home.mkdir()
        self.target = self.home / ".pi/gentle-ai/profiles.json"
        self.profiles = {name: load_profile(SOURCE_DIR, name) for name in NAMES}
        self.profile = self.profiles[NAME]

    def run_restore(self, script=SCRIPT, *args):
        return subprocess.run(
            ["python3", str(script), *args],
            cwd=self.root,
            env={**os.environ, "HOME": str(self.home)},
            text=True,
            capture_output=True,
        )

    def assert_safe_output(self, result):
        for model in (entry["model"] for profile in self.profiles.values() for entry in profile.values()):
            self.assertNotIn(model, result.stdout + result.stderr)

    def registry(self, **kwargs):
        return {
            "kind": "gentle-pi.agent_model_profiles", "version": 1,
            "profiles": {}, "active": "other", **kwargs,
        }

    def seed(self, registry):
        self.target.parent.mkdir(parents=True, exist_ok=True)
        self.target.write_text(json.dumps(registry))
        return self.target.read_bytes()

    def backups(self):
        return list(self.target.parent.glob("profiles.json.backup-*"))

    def test_fresh_registry_private_and_manual(self):
        result = self.run_restore()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(self.target.read_text()), self.registry(
            profiles=self.profiles, active=NAME,
        ))
        self.assertEqual(stat.S_IMODE(self.target.stat().st_mode), 0o600)
        self.assertEqual(stat.S_IMODE(self.target.parent.stat().st_mode), 0o700)
        self.assertEqual(self.backups(), [])
        self.assert_safe_output(result)

    def test_merge_preserves_unrelated_profiles_active_and_extra_fields_with_backup(self):
        original = self.registry(profiles={"other": {"custom": "untouched"}},
                                 api_token="private-live-value")
        before = self.seed(original)
        result = self.run_restore()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(self.target.read_text()), {
            **original, "profiles": {**original["profiles"], **self.profiles},
        })
        self.assertEqual(stat.S_IMODE(self.target.stat().st_mode), 0o600)
        backups = self.backups()
        self.assertEqual(len(backups), 1)
        self.assertEqual(backups[0].read_bytes(), before)
        self.assertEqual(stat.S_IMODE(backups[0].stat().st_mode), 0o600)
        self.assertNotIn("private-live-value", result.stdout + result.stderr)
        self.assert_safe_output(result)

    def test_identical_profile_is_no_op(self):
        self.seed(self.registry(profiles=self.profiles))
        before = self.target.read_bytes()
        inode = self.target.stat().st_ino
        result = self.run_restore()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.target.read_bytes(), self.target.stat().st_ino), (before, inode))
        self.assertEqual(self.backups(), [])

    def test_conflict_refused_without_write_or_backup(self):
        conflicted = {**self.profile, "orchestrator": {"model": PREFIXES[NAME] + "other", "thinking": "high"}}
        before = self.seed(self.registry(profiles={NAME: conflicted}))
        result = self.run_restore()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("inspect", (result.stdout + result.stderr).lower())
        self.assertIn(f"Profile {NAME} conflicts", result.stderr)
        self.assertEqual(self.target.read_bytes(), before)
        self.assertEqual(self.backups(), [])
        self.assert_safe_output(result)

    def test_replace_conflicting_profile_preserves_others_and_backs_up_exact_bytes(self):
        conflicted = {**self.profile, "orchestrator": {"model": "anthropic/claude", "thinking": "high"}}
        original = self.registry(profiles={"other": {"custom": "untouched"}, NAME: conflicted},
                                 active="other", api_token="private-live-value")
        before = self.seed(original)
        result = self.run_restore(SCRIPT, "--replace")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(self.target.read_text()), {
            **original, "profiles": {**original["profiles"], **self.profiles},
        })
        self.assertEqual(stat.S_IMODE(self.target.stat().st_mode), 0o600)
        backups = self.backups()
        self.assertEqual(len(backups), 1)
        self.assertEqual(backups[0].read_bytes(), before)
        self.assertEqual(stat.S_IMODE(backups[0].stat().st_mode), 0o600)
        self.assertNotIn("private-live-value", result.stdout + result.stderr)
        self.assert_safe_output(result)

    def test_replace_identical_profile_is_no_op_without_backup(self):
        before = self.seed(self.registry(profiles=self.profiles, active="other"))
        inode = self.target.stat().st_ino
        result = self.run_restore(SCRIPT, "--replace")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.target.read_bytes(), self.target.stat().st_ino), (before, inode))
        self.assertEqual(self.backups(), [])

    def test_partial_registry_adds_only_missing_profile_with_backup(self):
        original = self.registry(profiles={"other": {"custom": "untouched"}, NAME: self.profile})
        before = self.seed(original)
        result = self.run_restore()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(self.target.read_text()), {
            **original, "profiles": {**original["profiles"], **self.profiles},
        })
        backups = self.backups()
        self.assertEqual(len(backups), 1)
        self.assertEqual(backups[0].read_bytes(), before)
        self.assert_safe_output(result)

    def test_high_profiles_added_to_existing_medium_low_registry(self):
        # An existing registry that already has codex-medium/codex-low but
        # lacks both high profiles gets exactly those two added; active is
        # preserved and a backup of the exact original bytes is written.
        original = self.registry(
            profiles={"codex-medium": self.profiles["codex-medium"],
                      "codex-low": self.profiles["codex-low"]},
            active="codex-medium",
        )
        before = self.seed(original)
        result = self.run_restore()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(self.target.read_text()), {
            **original, "profiles": {**original["profiles"],
                                     "codex-high": self.profiles["codex-high"],
                                     "claude-high": self.profiles["claude-high"]},
        })
        backups = self.backups()
        self.assertEqual(len(backups), 1)
        self.assertEqual(backups[0].read_bytes(), before)
        self.assert_safe_output(result)

    def test_conflict_in_any_profile_refuses_whole_restore(self):
        low = NAMES[1]
        conflicted = {**self.profiles[low], "orchestrator": {"model": PREFIXES[low] + "other", "thinking": "high"}}
        before = self.seed(self.registry(profiles={low: conflicted}))
        result = self.run_restore()
        self.assertNotEqual(result.returncode, 0)
        # Only the conflicting profile is named, not one that is merely missing.
        self.assertIn(f"Profile {low} conflicts", result.stderr)
        self.assertNotIn(NAME, result.stderr)
        self.assertEqual(self.target.read_bytes(), before)
        self.assertNotIn(NAME, json.loads(self.target.read_text())["profiles"])
        self.assertEqual(self.backups(), [])
        self.assert_safe_output(result)

    def test_conflict_in_all_profiles_names_all(self):
        conflicted = {name: {**profile, "orchestrator": {"model": PREFIXES[name] + "other", "thinking": "high"}}
                      for name, profile in self.profiles.items()}
        before = self.seed(self.registry(profiles=conflicted))
        result = self.run_restore()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(f"Profiles {', '.join(NAMES)} conflict with the trusted source", result.stderr)
        self.assertEqual(self.target.read_bytes(), before)
        self.assertEqual(self.backups(), [])
        self.assert_safe_output(result)

    def test_malformed_live_refused_without_write(self):
        self.target.parent.mkdir(parents=True)
        for raw in ("{not json", json.dumps(self.registry(version=2)),
                    json.dumps(self.registry(active=None)),
                    json.dumps(self.registry(extra=float("nan"))),
                    '{"kind":"gentle-pi.agent_model_profiles","kind":"other","version":1,"profiles":{},"active":"other"}'):
            with self.subTest(raw=raw):
                self.target.write_text(raw)
                for args in ((), ("--replace",)):
                    with self.subTest(args=args):
                        result = self.run_restore(SCRIPT, *args)
                        self.assertNotEqual(result.returncode, 0)
                        self.assertEqual(self.target.read_text(), raw)
                        self.assertEqual(self.backups(), [])
                        self.assert_safe_output(result)

    def test_overflowed_unrelated_number_refused_without_write_or_backup(self):
        self.target.parent.mkdir(parents=True)
        for number in ("1e400", "-1e400"):
            with self.subTest(number=number):
                raw = json.dumps(self.registry()).removesuffix("}") + ',"unrelated":' + number + "}"
                before = raw.encode("utf-8")
                self.target.write_bytes(before)
                for args in ((), ("--replace",)):
                    with self.subTest(args=args):
                        result = self.run_restore(SCRIPT, *args)
                        self.assertNotEqual(result.returncode, 0)
                        self.assertEqual(self.target.read_bytes(), before)
                        self.assertEqual(self.backups(), [])
                        self.assertNotIn(number, result.stdout + result.stderr)
                        self.assert_safe_output(result)

    def test_symlink_target_refused(self):
        self.target.parent.mkdir(parents=True)
        original = self.root / "unrelated.json"
        original.write_text("not a registry")
        self.target.symlink_to(original)
        result = self.run_restore()
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(self.target.is_symlink())
        self.assertEqual(original.read_text(), "not a registry")
        self.assertEqual(self.backups(), [])

    def test_invalid_source_refused_without_touching_live(self):
        before = self.seed(self.registry())
        isolated = self.root / "bundle"
        (isolated / "scripts").mkdir(parents=True)
        (isolated / "config/pi").mkdir(parents=True)
        script = isolated / "scripts/restore-pi-profiles"
        shutil.copyfile(SCRIPT, script)
        for filename in set(SOURCE_FILES.values()):
            shutil.copyfile(SOURCE_DIR / filename, isolated / f"config/pi/{filename}")
        for name in NAMES:
            profile = self.profiles[name]
            prefix = PREFIXES[name]
            bad_sources = ["{invalid json",
                           json.dumps(wrap(name, {})),
                           json.dumps(wrap(name, {**profile, "orchestrator": {"model": "other/model", "thinking": "high"}})),
                           json.dumps(wrap(name, {**profile, "orchestrator": {"model": prefix + "model", "thinking": "invalid"}})),
                           json.dumps(wrap(name, {**profile, "orchestrator": {"model": prefix + "model", "thinking": "high", "secret": "not-allowed"}}))]
            source = isolated / f"config/pi/{SOURCE_FILES[name]}"
            valid = source.read_bytes()
            for bad in bad_sources:
                with self.subTest(name=name, bad=bad[:30]):
                    source.write_text(bad)
                    try:
                        for args in ((), ("--replace",)):
                            with self.subTest(args=args):
                                result = self.run_restore(script, *args)
                                self.assertNotEqual(result.returncode, 0)
                                self.assertIn(f"Source profile {name} ", result.stderr)
                                self.assertEqual(self.target.read_bytes(), before)
                                self.assertEqual(self.backups(), [])
                                self.assert_safe_output(result)
                    finally:
                        source.write_bytes(valid)

    def test_claude_high_source_wrong_prefix_refused_nothing_changed(self):
        before = self.seed(self.registry())
        isolated = self.root / "bundle-claude-high"
        (isolated / "scripts").mkdir(parents=True)
        (isolated / "config/pi").mkdir(parents=True)
        script = isolated / "scripts/restore-pi-profiles"
        shutil.copyfile(SCRIPT, script)
        for filename in set(SOURCE_FILES.values()):
            shutil.copyfile(SOURCE_DIR / filename, isolated / f"config/pi/{filename}")
        source = isolated / "config/pi/claude-profiles.json"
        data = json.loads(source.read_text())
        data["claude-high"] = {**data["claude-high"],
                                "orchestrator": {"model": "openai-codex/gpt-6-sol", "thinking": "max"}}
        source.write_text(json.dumps(data))
        result = self.run_restore(script)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Source profile claude-high ", result.stderr)
        self.assertEqual(self.target.read_bytes(), before)
        self.assertEqual(self.backups(), [])
        self.assert_safe_output(result)

    def test_codex_high_source_wrong_prefix_refused_nothing_changed(self):
        before = self.seed(self.registry())
        isolated = self.root / "bundle-codex-high"
        (isolated / "scripts").mkdir(parents=True)
        (isolated / "config/pi").mkdir(parents=True)
        script = isolated / "scripts/restore-pi-profiles"
        shutil.copyfile(SCRIPT, script)
        for filename in set(SOURCE_FILES.values()):
            shutil.copyfile(SOURCE_DIR / filename, isolated / f"config/pi/{filename}")
        source = isolated / "config/pi/codex-high.json"
        data = json.loads(source.read_text())
        data["orchestrator"] = {"model": "claude-bridge/claude-opus-5-5", "thinking": "max"}
        source.write_text(json.dumps(data))
        result = self.run_restore(script)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Source profile codex-high ", result.stderr)
        self.assertEqual(self.target.read_bytes(), before)
        self.assertEqual(self.backups(), [])
        self.assert_safe_output(result)

    def test_high_profiles_exact_contents_and_canonical_order(self):
        fable = "claude-bridge/claude-fable-5-1"
        opus = "claude-bridge/claude-opus-5-5"
        fable_roles = {"sdd-proposal", "sdd-design", "jd-judge-b", "jd-fix-agent"}
        expected_claude_high = {
            role: {"model": fable if role in fable_roles else opus, "thinking": "max"}
            for role in CANONICAL_ORDER
        }
        self.assertEqual(list(self.profiles["claude-high"].keys()), CANONICAL_ORDER)
        self.assertEqual(self.profiles["claude-high"], expected_claude_high)

        astra = "openai-codex/gpt-6-astra"
        sol = "openai-codex/gpt-6-sol"
        astra_roles = {"sdd-proposal", "sdd-spec", "sdd-design", "sdd-apply", "sdd-verify",
                       "jd-judge-a", "jd-judge-b", "review-refuter", "review-validator", "gentle-ai-verify"}
        expected_codex_high = {
            role: {"model": astra if role in astra_roles else sol, "thinking": "max"}
            for role in CANONICAL_ORDER
        }
        self.assertEqual(list(self.profiles["codex-high"].keys()), CANONICAL_ORDER)
        self.assertEqual(self.profiles["codex-high"], expected_codex_high)

    def test_fresh_refuses_public_existing_directory(self):
        self.target.parent.mkdir(parents=True)
        self.target.parent.chmod(0o755)
        result = self.run_restore()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.target.exists())
        self.assertEqual(self.backups(), [])

    def test_no_other_flags_or_path_arguments(self):
        for args in ((str(self.root / "arbitrary-target"),), ("--force",),
                     ("--replace", str(self.root / "arbitrary-target")),
                     ("--replace", "--replace")):
            with self.subTest(args=args):
                result = self.run_restore(SCRIPT, *args)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(self.target.exists())


unittest.main(verbosity=2)
PY
