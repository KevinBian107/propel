"""Tests for the Propel block in launcher.collect_status(), the propel-update
action, and terminal setup's update line.

Usage: python -m unittest tests/test_launcher_status.py -v

Reuses the FakePropel clone from test_install.py. Tool detection (claude, codex,
node, plugins) is stubbed out so nothing here shells out to real binaries or
reads ~/.claude.
"""

import io
import shutil
import sys
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "src"))
sys.path.insert(0, str(ROOT / "tests"))

import click  # noqa: E402

from propel_cli import cli as cli_mod  # noqa: E402
from propel_cli import install, launcher, terminal_setup  # noqa: E402
from test_install import InstallTestCase  # noqa: E402


class LauncherStatusTestCase(InstallTestCase):
    def collect(self, propel_root=None, root_error=None):
        if root_error is not None:
            root_patch = mock.patch.object(cli_mod, "get_propel_root", side_effect=root_error)
        else:
            root_patch = mock.patch.object(
                cli_mod, "get_propel_root", return_value=propel_root or self.propel.root
            )
        with root_patch, \
                mock.patch.object(launcher, "_project_root", return_value=self.project), \
                mock.patch.object(launcher, "_version", return_value=None), \
                mock.patch.object(launcher, "_installed_plugin_ids", return_value=set()):
            return launcher.collect_status()


class CollectStatusTests(LauncherStatusTestCase):
    def test_not_installed(self):
        status = self.collect()
        self.assertIs(status["propel"]["installed"], False)
        self.assertIs(status["project"]["initialized"], False)

    def test_current_after_install(self):
        self.run_install()
        status = self.collect()
        self.assertNotIn("error", status["propel"])
        self.assertIs(status["propel"]["installed"], True)
        self.assertIs(status["propel"]["update_available"], False)
        self.assertEqual(status["propel"]["changes"], 0)
        self.assertIs(status["project"]["initialized"], True)

    def test_update_available_after_upstream_change(self):
        self.run_install()
        self.propel.write("agents/code-reviewer.md", "reviewer v2\n")
        self.propel.commit("v2")
        status = self.collect()
        self.assertIs(status["propel"]["update_available"], True)
        self.assertEqual(status["propel"]["changes"], 1)
        self.assertIs(status["project"]["initialized"], True)

    def test_corrupt_manifest_is_an_error_entry(self):
        self.run_install()
        (self.project / ".propel" / "manifest.json").write_text("{not json")
        status = self.collect()
        self.assertIn("error", status["propel"])
        self.assertEqual(status["propel"]["error_kind"], "manifest")
        self.assertIs(status["propel"]["installed"], True)
        self.assertIs(status["project"]["initialized"], True)

    def test_corrupt_manifest_without_claude_dir_is_not_initialized(self):
        (self.project / ".propel").mkdir()
        (self.project / ".propel" / "manifest.json").write_text("{not json")
        status = self.collect()
        self.assertIn("error", status["propel"])
        self.assertIs(status["propel"]["installed"], False)
        self.assertIs(status["project"]["initialized"], False)

    def test_orphan_manifest_is_not_initialized(self):
        self.run_install()
        shutil.rmtree(self.claude)
        status = self.collect()
        self.assertNotIn("error", status["propel"])
        self.assertIs(status["propel"]["installed"], False)
        self.assertIs(status["project"]["initialized"], False)

    def test_missing_propel_root_is_an_error_entry(self):
        status = self.collect(root_error=FileNotFoundError("no clone"))
        self.assertEqual(status["propel"], {"error": "no clone", "error_kind": "other"})
        # Falls back to the legacy check
        self.assertIs(status["project"]["initialized"], False)

    def test_missing_propel_root_falls_back_to_legacy_dir(self):
        (self.claude / "skills" / "using-propel").mkdir(parents=True)
        status = self.collect(root_error=FileNotFoundError("no clone"))
        self.assertIn("error", status["propel"])
        self.assertIs(status["project"]["initialized"], True)


class ActionTests(unittest.TestCase):
    def test_propel_update_action(self):
        spec = launcher.ACTIONS["propel-update"]
        self.assertEqual(spec["self"], ["init"])
        self.assertIs(spec["cwd_project"], True)
        self.assertEqual(spec["label"], "Update Propel in this project")

    def test_propel_init_unchanged(self):
        self.assertEqual(
            launcher.ACTIONS["propel-init"],
            {"label": "Install Propel into this project", "self": ["init"], "cwd_project": True},
        )


class InitProjectTests(LauncherStatusTestCase):
    def run_init_project(self, status, tty=False):
        out = io.StringIO()
        stdin = mock.Mock()
        stdin.isatty.return_value = tty
        with mock.patch.object(terminal_setup.sys, "stdin", stdin), \
                mock.patch.object(terminal_setup, "_ask") as ask, \
                mock.patch.object(terminal_setup, "_run_live", return_value=0) as run_live, \
                mock.patch.object(click, "echo", side_effect=lambda m="", **k: out.write(f"{m}\n")):
            terminal_setup._init_project(status)
        return out.getvalue(), ask, run_live

    def test_update_line_without_prompt_when_not_a_tty(self):
        self.run_install()
        self.propel.write("agents/code-reviewer.md", "reviewer v2\n")
        self.propel.commit("v2")
        status = self.collect()
        output, ask, run_live = self.run_init_project(status, tty=False)
        p = status["propel"]
        self.assertIn(
            f"Propel {p['installed_version']} is installed; 1 file change(s) available from {p['available_version']}.",
            output,
        )
        ask.assert_not_called()
        run_live.assert_not_called()

    def test_update_prompt_on_a_tty_defaults_no(self):
        self.run_install()
        self.propel.write("agents/code-reviewer.md", "reviewer v2\n")
        self.propel.commit("v2")
        status = self.collect()
        stdin = mock.Mock()
        stdin.isatty.return_value = True
        with mock.patch.object(terminal_setup.sys, "stdin", stdin), \
                mock.patch.object(terminal_setup, "_ask", return_value=True) as ask, \
                mock.patch.object(terminal_setup, "_run_live", return_value=0) as run_live, \
                mock.patch.object(click, "echo"):
            terminal_setup._init_project(status)
        ask.assert_called_once_with("  Update Propel in this project?", False)
        run_live.assert_called_once()
        self.assertEqual(run_live.call_args.args[0][-1], "init")
        self.assertEqual(run_live.call_args.kwargs["cwd"], str(self.project))

    def test_update_line_names_edited_files(self):
        self.run_install()
        (self.claude / "core/CORE.md").write_text("edited\n")
        status = self.collect()
        output, ask, run_live = self.run_init_project(status, tty=False)
        p = status["propel"]
        self.assertIn(
            f"Propel {p['installed_version']} is installed; 1 file change(s) available from "
            f"{p['available_version']}. 1 file(s) you edited will be backed up and replaced.",
            output,
        )

    def test_update_line_omits_edited_note_when_none(self):
        self.run_install()
        self.propel.write("agents/code-reviewer.md", "reviewer v2\n")
        self.propel.commit("v2")
        output, _, _ = self.run_init_project(self.collect(), tty=False)
        self.assertNotIn("you edited", output)

    def test_up_to_date_line(self):
        self.run_install()
        status = self.collect()
        output, ask, run_live = self.run_init_project(status, tty=True)
        self.assertIn(
            f"Propel {status['propel']['installed_version']} is up to date in this project.", output
        )
        ask.assert_not_called()
        run_live.assert_not_called()

    def test_error_is_a_warning_and_continues(self):
        self.run_install()
        (self.project / ".propel" / "manifest.json").write_text("{not json")
        status = self.collect()
        output, ask, run_live = self.run_init_project(status, tty=True)
        self.assertIn(status["propel"]["error"], output)
        ask.assert_not_called()
        run_live.assert_not_called()


class ManualStepsTests(LauncherStatusTestCase):
    def manual_steps(self, status):
        # Claude/Codex present and signed in, so only the Propel step can appear.
        status["tools"] = [
            {"key": "claude", "ok": True, "auth": True},
            {"key": "codex", "ok": True, "auth": True},
        ]
        out = io.StringIO()
        with mock.patch.object(terminal_setup, "local_bin_on_path", return_value=True), \
                mock.patch.object(click, "echo", side_effect=lambda m="", **k: out.write(f"{m}\n")):
            terminal_setup._print_manual_steps(status)
        return out.getvalue()

    def test_error_step_names_error_and_fix(self):
        (self.project / ".propel").mkdir()
        (self.project / ".propel" / "manifest.json").write_text("{not json")
        status = self.collect()
        output = self.manual_steps(status)
        self.assertIn(status["propel"]["error"], output)
        # The ManifestError message carries its own fix; it is not repeated.
        self.assertEqual(output.count("Fix or delete"), 1)
        self.assertIn(f"    Then: cd {self.project} && propel init", output)
        self.assertNotIn("pip install -e", output)
        self.assertNotIn("Everything is set up", output)

    def test_manifest_error_without_its_own_fix_gets_the_hint(self):
        status = self.collect()
        status["propel"] = {"error": "manifest unreadable", "error_kind": "manifest", "installed": True}
        output = self.manual_steps(status)
        self.assertIn(
            f"Fix or delete .propel/manifest.json, then: cd {self.project} && propel init", output
        )

    def test_other_error_step_points_at_the_install_not_the_manifest(self):
        status = self.collect(root_error=FileNotFoundError("no clone"))
        output = self.manual_steps(status)
        self.assertIn("Couldn't check Propel in this project: no clone", output)
        self.assertIn("Check that Propel was installed with `pip install -e <clone>`", output)
        self.assertNotIn("manifest.json", output)

    def test_update_step_when_update_available(self):
        self.run_install()
        self.propel.write("agents/code-reviewer.md", "reviewer v2\n")
        self.propel.commit("v2")
        output = self.manual_steps(self.collect())
        self.assertIn(f"Update Propel here (1 file change(s)): cd {self.project} && propel init", output)

    def test_no_propel_step_when_current(self):
        self.run_install()
        output = self.manual_steps(self.collect())
        self.assertIn("Everything is set up", output)

    def test_orphan_manifest_lists_propel_init(self):
        self.run_install()
        shutil.rmtree(self.claude)
        output = self.manual_steps(self.collect())
        self.assertIn(f"    cd {self.project} && propel init", output)



class PendingSummaryTests(unittest.TestCase):
    def test_names_files_and_hooks(self):
        from propel_cli.terminal_setup import _pending_summary as f
        self.assertEqual(f({"changes": 0, "hooks_pending": 1}), "1 hook registration(s)")
        self.assertEqual(f({"changes": 3, "hooks_pending": 1}),
                         "3 file change(s) and 1 hook registration(s)")
        self.assertEqual(f({"changes": 2, "hooks_pending": None}), "2 file change(s)")


if __name__ == "__main__":
    unittest.main()
