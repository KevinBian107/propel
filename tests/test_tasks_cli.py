"""Tests for `propel tasks`, the terminal view of the task ledger.

Usage: python -m unittest tests/test_tasks_cli.py -v

Each test builds a throwaway project in a temp dir with task-queue.sh copied
to .claude/scripts/ (as `propel init` installs it) and drives the real script;
only the Propel-clone fallback and bash lookup are mocked, and two tests use a
stub script to check exit-code pass-through.
"""

import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "src"))

from click.testing import CliRunner  # noqa: E402

from propel_cli import cli as cli_mod  # noqa: E402

SCRIPT = ROOT / "scripts" / "task-queue.sh"


class TasksCliTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.project = Path(self._tmp.name).resolve()
        self._cwd = os.getcwd()
        os.chdir(self.project)
        self.addCleanup(self._cleanup)

    def _cleanup(self):
        os.chdir(self._cwd)
        self._tmp.cleanup()

    def install_script(self) -> Path:
        dest = self.project / ".claude" / "scripts" / "task-queue.sh"
        dest.parent.mkdir(parents=True)
        shutil.copy2(SCRIPT, dest)
        return dest

    def tq(self, *args: str) -> str:
        env = {**os.environ, "CLAUDE_PROJECT_DIR": str(self.project)}
        env.pop("PROPEL_SESSION", None)
        out = subprocess.run(
            ["bash", str(self.project / ".claude" / "scripts" / "task-queue.sh"), *args],
            cwd=self.project, env=env, capture_output=True, text=True,
        )
        self.assertEqual(out.returncode, 0, out.stderr)
        return out.stdout.strip()

    def invoke(self, *args: str):
        return CliRunner().invoke(cli_mod.cli, ["tasks", *args])

    def seed(self):
        self.install_script()
        self.open_id = self.tq("start", "--session", "S1", "--kind", "impl", "--title", "still open task")
        self.done_id = self.tq("start", "--session", "S1", "--kind", "impl", "--title", "finished task")
        self.tq("done", self.done_id, "--status", "done")

    def test_default_shows_only_open(self):
        self.seed()
        result = self.invoke()
        self.assertEqual(result.exit_code, 0, result.output)
        self.assertIn("| ID | Task |", result.output)
        self.assertIn(self.open_id, result.output)
        self.assertNotIn(self.done_id, result.output)

    def test_all_shows_done_too(self):
        self.seed()
        result = self.invoke("--all")
        self.assertEqual(result.exit_code, 0, result.output)
        self.assertIn(self.open_id, result.output)
        self.assertIn(self.done_id, result.output)

    def test_runs_from_a_subdirectory(self):
        self.seed()
        sub = self.project / "a" / "b"
        sub.mkdir(parents=True)
        os.chdir(sub)
        result = self.invoke()
        self.assertEqual(result.exit_code, 0, result.output)
        self.assertIn(self.open_id, result.output)

    def test_no_open_tasks(self):
        self.install_script()
        result = self.invoke()
        self.assertEqual(result.exit_code, 0, result.output)
        self.assertIn("No open tasks.", result.output)

    def test_sessions_out_of_range_is_a_usage_error(self):
        self.seed()
        for bad in ("0", "1001"):
            result = self.invoke("--sessions", bad)
            self.assertEqual(result.exit_code, 2, result.output)

    def stub_script(self, body: str):
        dest = self.project / ".claude" / "scripts" / "task-queue.sh"
        dest.parent.mkdir(parents=True)
        dest.write_text("#!/usr/bin/env bash\n" + body + "\n")
        (self.project / ".propel").mkdir()

    def test_script_exit_code_passes_through(self):
        self.stub_script('echo "partial row"; echo "task-queue: cannot read x" >&2; exit 5')
        result = self.invoke()
        self.assertEqual(result.exit_code, 5, result.output)
        self.assertIn("partial row", result.output)
        self.assertIn("cannot read x", result.output)

    def test_script_killed_by_signal_maps_to_128_plus_sig(self):
        self.stub_script("kill -TERM $$")
        result = self.invoke()
        self.assertEqual(result.exit_code, 128 + 15, result.output)

    def test_falls_back_to_clone_script(self):
        (self.project / ".propel").mkdir()
        result = self.invoke()
        self.assertEqual(result.exit_code, 0, result.output)
        self.assertIn("No open tasks.", result.output)

    def test_no_ledger_prints_empty_message_without_the_script(self):
        # A child with an installed script but no .propel/ must not show the
        # parent's open task (the script itself would walk up to it).
        self.seed()
        child = self.project / "child"
        (child / ".claude" / "scripts").mkdir(parents=True)
        shutil.copy2(SCRIPT, child / ".claude" / "scripts" / "task-queue.sh")
        os.chdir(child)
        with mock.patch.object(cli_mod.subprocess, "run") as run:
            result = self.invoke()
            self.assertEqual(result.exit_code, 0, result.output)
            self.assertIn("No open tasks.", result.output)
            self.assertEqual(self.invoke("--all").output.strip(), "No tasks recorded.")
        run.assert_not_called()

    def test_nested_project_reads_the_inner_ledger(self):
        self.seed()  # outer project: installed script + an open task
        inner = self.project / "inner"
        inner.mkdir()
        env = {**os.environ, "CLAUDE_PROJECT_DIR": str(inner)}
        env.pop("PROPEL_SESSION", None)
        (inner / ".propel").mkdir()  # inner project: a ledger, no installed script
        out = subprocess.run(
            ["bash", str(SCRIPT), "start", "--session", "S9", "--kind", "impl", "--title", "inner task"],
            cwd=inner, env=env, capture_output=True, text=True,
        )
        self.assertEqual(out.returncode, 0, out.stderr)
        inner_id = out.stdout.strip()
        os.chdir(inner)
        result = self.invoke()
        self.assertEqual(result.exit_code, 0, result.output)
        self.assertIn(inner_id, result.output)
        self.assertNotIn(self.open_id, result.output)

    def test_stale_claude_project_dir_is_ignored(self):
        self.seed()
        with tempfile.TemporaryDirectory() as other_dir:
            other = Path(other_dir).resolve()
            (other / ".propel").mkdir()
            env = {**os.environ, "CLAUDE_PROJECT_DIR": str(other)}
            out = subprocess.run(
                ["bash", str(SCRIPT), "start", "--session", "O1", "--kind", "impl", "--title", "other task"],
                cwd=other, env=env, capture_output=True, text=True,
            )
            self.assertEqual(out.returncode, 0, out.stderr)
            other_id = out.stdout.strip()
            with mock.patch.dict(os.environ, {"CLAUDE_PROJECT_DIR": str(other)}):
                result = self.invoke("--all")
        self.assertEqual(result.exit_code, 0, result.output)
        self.assertIn(self.open_id, result.output)
        self.assertNotIn(other_id, result.output)

    def test_missing_script(self):
        (self.project / ".propel").mkdir()
        with mock.patch.object(cli_mod, "get_propel_root", side_effect=FileNotFoundError("gone")):
            result = self.invoke()
        self.assertEqual(result.exit_code, 1, result.output)
        self.assertIn("task-queue.sh not found", result.output)

    def test_missing_bash(self):
        self.seed()
        with mock.patch.object(cli_mod.shutil, "which", return_value=None):
            result = self.invoke()
        self.assertEqual(result.exit_code, 1, result.output)
        self.assertIn("bash not found", result.output)


if __name__ == "__main__":
    unittest.main()
