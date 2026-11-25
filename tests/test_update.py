"""Tests for the single version source, `propel --version`, `propel status` and
`propel update`.

Usage: python -m unittest tests/test_update.py -v

Every git operation runs against a fake propel clone in a temp dir (see
test_install.FakePropel). Child processes that update would start -- the pip
probe, the pip or uv reinstall, and the re-run of `propel init` -- are
intercepted, so nothing is installed and this repo is never pulled.
"""

import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "src"))
sys.path.insert(0, str(Path(__file__).resolve().parent))

from click.testing import CliRunner  # noqa: E402

import propel_cli  # noqa: E402
from propel_cli import cli as cli_mod  # noqa: E402
from propel_cli import install  # noqa: E402
from test_install import FakePropel, InstallTestCase, git  # noqa: E402


class VersionTests(unittest.TestCase):
    def test_plugin_json_matches_package_version(self):
        plugin = json.loads((ROOT / ".claude-plugin" / "plugin.json").read_text())
        self.assertEqual(plugin["version"], propel_cli.__version__)

    def test_pyproject_reads_version_from_package(self):
        text = (ROOT / "pyproject.toml").read_text()
        self.assertIn('dynamic = ["version"]', text)
        self.assertIn('version = {attr = "propel_cli.__version__"}', text)
        project = text.split("[project]", 1)[1].split("\n[", 1)[0]
        self.assertNotRegex(project, r'(?m)^version\s*=')

    def test_update_dry_run_help(self):
        result = CliRunner().invoke(cli_mod.cli, ["update", "--help"])
        self.assertEqual(result.exit_code, 0, result.output)
        self.assertIn("changes no working files (may fetch from the", " ".join(result.output.split()))

    def test_version_option(self):
        result = CliRunner().invoke(cli_mod.cli, ["--version"])
        self.assertEqual(result.exit_code, 0, result.output)
        self.assertEqual(result.output.strip(), f"propel, version {propel_cli.__version__}")


INIT_CMD = [
    sys.executable,
    "-c",
    "import sys; sys.path[:] = [p for p in sys.path if p not in ('', '.')]; "
    "from propel_cli.cli import cli; cli(prog_name='propel')",
    "init",
]


FAKE_UV = "/fake/bin/uv"


def _kind(cmd) -> str:
    """'probe' for `-m pip --version`, 'pip' / 'uv' for the reinstall, 'init'
    for the child `propel init`."""
    if cmd[0] == FAKE_UV:
        return "uv"
    if cmd[1:4] == ["-m", "pip", "--version"]:
        return "probe"
    return "pip" if cmd[1:3] == ["-m", "pip"] else "init"


class ChildRecorder:
    """Stands in for subprocess.run: records the reinstall / child-init calls
    and returns canned exit codes; lets every other command (git) run for real.

    has_pip: whether `sys.executable -m pip --version` succeeds. Probes are
    kept in .probes, not .calls.
    git_rc: {git subcommand: returncode} to fake, e.g. {"diff": 128}.
    on_init: called (no arguments) when the child init would run, to fake its
    side effects."""

    def __init__(self, init_rc=0, pip_rc=0, git_rc=None, on_init=None, has_pip=True):
        self.calls = []
        self.probes = []
        self.init_rc = init_rc
        self.pip_rc = pip_rc
        self.git_rc = git_rc or {}
        self.on_init = on_init
        self.has_pip = has_pip
        self._real_run = subprocess.run

    def __call__(self, cmd, *args, **kwargs):
        if cmd and cmd[0] in (sys.executable, FAKE_UV):
            if _kind(cmd) == "probe":
                self.probes.append(list(cmd))
                return subprocess.CompletedProcess(cmd, 0 if self.has_pip else 1, "", "")
            self.calls.append((list(cmd), kwargs))
            if _kind(cmd) == "init" and self.on_init is not None:
                self.on_init()
            rc = self.pip_rc if _kind(cmd) in ("pip", "uv") else self.init_rc
            return subprocess.CompletedProcess(cmd, rc, "", "pip exploded" if rc else "")
        if cmd and cmd[0] == "git" and len(cmd) > 3 and cmd[3] in self.git_rc:
            return subprocess.CompletedProcess(cmd, self.git_rc[cmd[3]], "", "fatal: faked")
        return self._real_run(cmd, *args, **kwargs)

    def of(self, kind: str) -> list:
        return [c for c in self.calls if _kind(c[0]) == kind]


class CommandTestCase(InstallTestCase):
    def invoke(self, args, propel_root=None, recorder=None, installed_version=None,
               uv_on_path=False, uv_tool_env=False):
        """installed_version: what the installed `propel` distribution reports.
        None (the default) is "no metadata", which turns the version check off,
        so tests don't depend on the interpreter running them.
        uv_on_path: shutil.which("uv") finds FAKE_UV. uv_tool_env: sys.prefix
        holds a uv-receipt.toml, as in a `uv tool install` env."""
        recorder = recorder or ChildRecorder()
        prefix = Path(self._tmp.name) / "env"
        prefix.mkdir(exist_ok=True)
        if uv_tool_env:
            (prefix / "uv-receipt.toml").write_text("[tool]\n")
        real_which = cli_mod.shutil.which

        def which(name, *a, **kw):
            if name == "uv":
                return FAKE_UV if uv_on_path else None
            return real_which(name, *a, **kw)

        with mock.patch.object(cli_mod, "get_propel_root", return_value=propel_root or self.propel.root), \
                mock.patch.object(cli_mod, "get_project_root", return_value=self.project), \
                mock.patch.object(cli_mod, "_installed_version", return_value=installed_version), \
                mock.patch.object(cli_mod.shutil, "which", side_effect=which), \
                mock.patch.object(cli_mod.sys, "prefix", str(prefix)), \
                mock.patch.object(cli_mod.subprocess, "run", side_effect=recorder):
            # CliRunner's default output carries stderr too (click < 8.2 mixes
            # it in; 8.2+ always interleaves it), so error text is in .output.
            result = CliRunner().invoke(cli_mod.cli, args)
        return result, recorder


class StatusCommandTests(CommandTestCase):
    def test_not_installed(self):
        result, _ = self.invoke(["status"])
        self.assertEqual(result.exit_code, 0, result.output)
        self.assertIn("Installed: not installed", result.output)
        self.assertIn(f"Available: {propel_cli.__version__}", result.output)
        self.assertIn(
            "Update available: n/a — Propel isn't installed here; run `propel init`", result.output
        )
        self.assertNotIn("Update available: yes", result.output)
        self.assertIn("Changes pending:       n/a", result.output)
        self.assertIn("Edited bundled files:  n/a", result.output)
        self.assertIn("User files kept:       n/a", result.output)
        self.assertIn("Hook registrations pending: n/a", result.output)

    def test_dirty_source_is_shown(self):
        # Installed first: a not-installed status runs no git, so shows no commit.
        self.run_install()
        self.propel.write("agents/code-reviewer.md", "local edit\n")
        commit = install.source_info(self.propel.root)["commit"]
        result, _ = self.invoke(["status"])
        self.assertEqual(result.exit_code, 0, result.output)
        self.assertIn(f"Available: {propel_cli.__version__} ({commit} + uncommitted changes)", result.output)

    def test_edited_bundled_label(self):
        self.run_install()
        result, _ = self.invoke(["status"])
        self.assertIn("(replaced or removed on update, backed up first)", result.output)

    def test_installed_and_current(self):
        self.run_install()
        commit = install.source_info(self.propel.root)["commit"]
        result, _ = self.invoke(["status"])
        self.assertEqual(result.exit_code, 0, result.output)
        self.assertIn(f"Installed: {propel_cli.__version__} ({commit})", result.output)
        self.assertIn("Changes pending:       0", result.output)
        self.assertIn("Hook registrations pending: 0", result.output)
        self.assertIn("Update available: no", result.output)

    def test_hook_registration_pending_is_an_update(self):
        self.run_install()
        settings_path = self.claude / "settings.local.json"
        settings = json.loads(settings_path.read_text())
        del settings["hooks"]["UserPromptSubmit"]
        settings_path.write_text(json.dumps(settings))
        result, _ = self.invoke(["status"])
        self.assertEqual(result.exit_code, 0, result.output)
        self.assertIn("Changes pending:       0", result.output)
        self.assertIn("Hook registrations pending: 1", result.output)
        self.assertIn("Update available: yes", result.output)

    def test_unparsable_settings_is_reported_not_raised(self):
        self.run_install()
        (self.claude / "settings.local.json").write_text("{not json")
        result, _ = self.invoke(["status"])
        self.assertEqual(result.exit_code, 0, result.output)
        self.assertIn("Hook registrations pending: n/a", result.output)
        self.assertIn("Settings: Could not parse", result.output)
        self.assertIn("Update available: no", result.output)

    def test_installed_with_pending_change(self):
        self.run_install()
        self.propel.write("agents/code-reviewer.md", "reviewer v2\n")
        self.propel.commit("v2")
        result, _ = self.invoke(["status"])
        self.assertIn("Changes pending:       1", result.output)
        self.assertIn("Update available: yes", result.output)

    def test_broken_manifest_is_a_clean_error(self):
        (self.project / ".propel").mkdir()
        (self.project / ".propel" / "manifest.json").write_text("{not json")
        result, _ = self.invoke(["status"])
        self.assertEqual(result.exit_code, 1)
        self.assertIn("manifest.json", result.output)
        self.assertNotIsInstance(result.exception, install.ManifestError)


class UpdateNoPullTests(CommandTestCase):
    def test_reruns_init_in_installed_project(self):
        self.run_install()
        head = git(self.propel.root, "rev-parse", "HEAD")
        result, rec = self.invoke(["update", "--no-pull"])
        self.assertEqual(result.exit_code, 0, result.output)
        self.assertEqual(rec.of("pip"), [])
        [(cmd, kwargs)] = rec.of("init")
        self.assertEqual(cmd, INIT_CMD)
        self.assertEqual(kwargs.get("cwd"), str(self.project))
        self.assertEqual(git(self.propel.root, "rev-parse", "HEAD"), head)
        self.assertIn("pull skipped", result.output)

    def test_dry_run_passes_dry_run_to_init(self):
        self.run_install()
        result, rec = self.invoke(["update", "--no-pull", "--dry-run", "--yes"])
        self.assertEqual(result.exit_code, 0, result.output)
        [(cmd, _)] = rec.of("init")
        self.assertEqual(cmd, INIT_CMD + ["--dry-run"])

    def test_child_init_ignores_shadowing_module_in_project(self):
        # The real child runs here (not faked), with PYTHONPATH at this repo's
        # src so it imports the real package hermetically. A decoy propel_cli
        # package in the project (the child's cwd) must never be imported.
        self.run_install()
        decoy = self.project / "propel_cli"
        decoy.mkdir()
        (decoy / "__init__.py").write_text('raise RuntimeError("DECOY IMPORTED")\n')
        env = dict(os.environ, PYTHONPATH=str(ROOT / "src"))
        env.pop("PYTHONSAFEPATH", None)
        # Control: a plain `python -c` in that cwd does pick up the decoy.
        control = subprocess.run(
            [sys.executable, "-c", "import propel_cli"], cwd=str(self.project),
            env=env, capture_output=True, text=True,
        )
        self.assertIn("DECOY IMPORTED", control.stderr)

        runs = []
        real_run = subprocess.run

        def run(cmd, *args, **kwargs):
            if cmd and cmd[0] == sys.executable and _kind(cmd) == "init":
                kwargs.update(env=env, capture_output=True, text=True)
                proc = real_run(cmd, *args, **kwargs)
                runs.append(proc)
                return proc
            return real_run(cmd, *args, **kwargs)

        with mock.patch.object(cli_mod, "get_propel_root", return_value=self.propel.root), \
                mock.patch.object(cli_mod, "get_project_root", return_value=self.project), \
                mock.patch.object(cli_mod.subprocess, "run", side_effect=run):
            result = CliRunner().invoke(cli_mod.cli, ["update", "--no-pull", "--dry-run"])
        [proc] = runs
        self.assertNotIn("DECOY IMPORTED", proc.stderr)
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        self.assertIn("Dry run", proc.stdout)
        self.assertEqual(result.exit_code, 0, result.output)

    def test_not_installed_does_not_run_init(self):
        result, rec = self.invoke(["update", "--no-pull"])
        self.assertEqual(result.exit_code, 0, result.output)
        self.assertEqual(rec.calls, [])
        self.assertIn(f"No Propel install in {self.project}", result.output)

    def test_installed_check_does_not_parse_the_manifest(self):
        # The old code must not abort on a manifest the new init may understand.
        (self.project / ".propel").mkdir()
        (self.project / ".propel" / "manifest.json").write_text('{"schema": 999, "future": true}')
        result, rec = self.invoke(["update", "--no-pull"])
        self.assertEqual(result.exit_code, 0, result.output)
        self.assertEqual(len(rec.of("init")), 1)

    def test_skill_dir_alone_counts_as_installed(self):
        (self.project / ".claude" / "skills" / "using-propel").mkdir(parents=True)
        result, rec = self.invoke(["update", "--no-pull"])
        self.assertEqual(result.exit_code, 0, result.output)
        self.assertEqual(len(rec.of("init")), 1)

    def test_init_exit_code_propagates(self):
        self.run_install()
        result, _ = self.invoke(["update", "--no-pull"], recorder=ChildRecorder(init_rc=3))
        self.assertEqual(result.exit_code, 3, result.output)

    # Version check: a manual `git pull` or --no-pull still reinstalls when the
    # installed package is behind the clone.
    def write_source_version(self, version):
        self.propel.write("src/propel_cli/__init__.py", f'__version__ = "{version}"\n')
        self.propel.commit(f"version {version}")

    def test_stale_installed_version_reinstalls(self):
        self.run_install()
        self.write_source_version("9.9.9")
        result, rec = self.invoke(["update", "--no-pull"], installed_version="0.1.0")
        self.assertEqual(result.exit_code, 0, result.output)
        [(cmd, _)] = rec.of("pip")
        self.assertEqual(cmd, [sys.executable, "-m", "pip", "install", "-e", str(self.propel.root)])
        self.assertEqual([_kind(c[0]) for c in rec.calls], ["pip", "init"])
        self.assertIn(
            "installed package is version 0.1.0 but the clone is 9.9.9; reinstalling the package",
            result.output,
        )
        self.assertIn("reinstalled with pip", result.output)

    # Installer selection: pip if this interpreter has it, else uv.
    def test_pip_available_uses_pip_even_with_uv(self):
        self.run_install()
        self.write_source_version("9.9.9")
        result, rec = self.invoke(
            ["update", "--no-pull"], installed_version="0.1.0", uv_on_path=True, uv_tool_env=True
        )
        self.assertEqual(result.exit_code, 0, result.output)
        self.assertEqual(rec.of("uv"), [])
        [(cmd, _)] = rec.of("pip")
        self.assertEqual(cmd, [sys.executable, "-m", "pip", "install", "-e", str(self.propel.root)])
        self.assertIn("using pip:", result.output)

    def test_no_pip_uv_venv_uses_uv_pip(self):
        self.run_install()
        self.write_source_version("9.9.9")
        result, rec = self.invoke(
            ["update", "--no-pull"], installed_version="0.1.0",
            recorder=ChildRecorder(has_pip=False), uv_on_path=True,
        )
        self.assertEqual(result.exit_code, 0, result.output)
        self.assertEqual(rec.of("pip"), [])
        [(cmd, _)] = rec.of("uv")
        self.assertEqual(
            cmd, [FAKE_UV, "pip", "install", "--python", sys.executable, "-e", str(self.propel.root)]
        )
        self.assertEqual([_kind(c[0]) for c in rec.calls], ["uv", "init"])
        self.assertIn("using uv pip:", result.output)
        self.assertIn("reinstalled with uv pip", result.output)

    def test_no_pip_uv_tool_env_uses_uv_tool_install(self):
        self.run_install()
        self.write_source_version("9.9.9")
        result, rec = self.invoke(
            ["update", "--no-pull"], installed_version="0.1.0",
            recorder=ChildRecorder(has_pip=False), uv_on_path=True, uv_tool_env=True,
        )
        self.assertEqual(result.exit_code, 0, result.output)
        [(cmd, _)] = rec.of("uv")
        self.assertEqual(cmd, [FAKE_UV, "tool", "install", "--reinstall", "--editable", str(self.propel.root)])
        self.assertEqual([_kind(c[0]) for c in rec.calls], ["uv", "init"])
        self.assertIn("reinstalled with uv tool", result.output)

    def test_neither_pip_nor_uv_fails_with_both_commands(self):
        self.run_install()
        self.write_source_version("9.9.9")
        result, rec = self.invoke(
            ["update", "--no-pull"], installed_version="0.1.0", recorder=ChildRecorder(has_pip=False),
        )
        self.assertEqual(result.exit_code, 1, result.output)
        self.assertEqual(rec.of("pip") + rec.of("uv"), [])
        out = result.output
        self.assertIn("Reinstall failed: neither pip", out)
        self.assertIn(f"pip install -e {self.propel.root}", out)
        self.assertIn(f"uv pip install --python {sys.executable} -e {self.propel.root}", out)
        self.assertIn(f"uv tool install --reinstall --editable {self.propel.root}", out)
        self.assertIn("reinstall failed — see above", out)
        # Matches the pip-failure path: init still runs, and the exit is 1.
        self.assertEqual(len(rec.of("init")), 1)

    def test_dry_run_names_the_installer_without_running_it(self):
        self.run_install()
        self.write_source_version("9.9.9")
        result, rec = self.invoke(
            ["update", "--no-pull", "--dry-run"], installed_version="0.1.0",
            recorder=ChildRecorder(has_pip=False), uv_on_path=True,
        )
        self.assertEqual(result.exit_code, 0, result.output)
        self.assertEqual(rec.of("uv"), [])
        self.assertIn(f"would use uv pip: {FAKE_UV} pip install --python", result.output)

    def test_in_uv_tool_env_reads_the_receipt(self):
        prefix = Path(self._tmp.name) / "toolenv"
        prefix.mkdir()
        with mock.patch.object(cli_mod.sys, "prefix", str(prefix)):
            self.assertFalse(cli_mod._in_uv_tool_env())
            (prefix / "uv-receipt.toml").write_text("[tool]\n")
            self.assertTrue(cli_mod._in_uv_tool_env())

    def test_matching_versions_do_not_reinstall(self):
        self.run_install()
        self.write_source_version("9.9.9")
        result, rec = self.invoke(["update", "--no-pull"], installed_version="9.9.9")
        self.assertEqual(result.exit_code, 0, result.output)
        self.assertEqual(rec.of("pip"), [])
        self.assertNotIn("reinstall", result.output)

    def test_stale_version_dry_run_says_what_would_happen(self):
        self.run_install()
        self.write_source_version("9.9.9")
        result, rec = self.invoke(["update", "--no-pull", "--dry-run"], installed_version="0.1.0")
        self.assertEqual(result.exit_code, 0, result.output)
        self.assertEqual(rec.of("pip"), [])
        self.assertIn(
            "installed package is version 0.1.0 but the clone is 9.9.9;"
            " would reinstall the package (not done: dry run)",
            result.output,
        )
        self.assertIn("would reinstall", result.output.splitlines()[-1])
        self.assertIn("would use pip:", result.output)

    def test_no_installed_metadata_skips_version_check(self):
        self.run_install()
        self.write_source_version("9.9.9")
        result, rec = self.invoke(["update", "--no-pull"], installed_version=None)
        self.assertEqual(result.exit_code, 0, result.output)
        self.assertEqual(rec.of("pip"), [])

    def test_installed_version_guards_missing_distribution(self):
        import importlib.metadata
        with mock.patch.object(
            cli_mod.importlib.metadata, "version",
            side_effect=importlib.metadata.PackageNotFoundError("propel"),
        ):
            self.assertIsNone(cli_mod._installed_version())

    def test_source_version_is_read_from_the_clone_file(self):
        self.assertIsNone(cli_mod._source_version(self.propel.root))
        self.write_source_version("1.2.3")
        self.assertEqual(cli_mod._source_version(self.propel.root), "1.2.3")

    # Restart hint: printed once, after update's summary, when the child init
    # changed the hook registrations.
    def drop_a_registration(self):
        settings_path = self.claude / "settings.local.json"
        settings = json.loads(settings_path.read_text())
        del settings["hooks"]["UserPromptSubmit"]
        settings_path.write_text(json.dumps(settings))

    def test_restart_hint_after_summary_when_child_changes_hooks(self):
        self.run_install()
        rec = ChildRecorder(on_init=self.drop_a_registration)
        result, rec = self.invoke(["update", "--no-pull"], recorder=rec)
        self.assertEqual(result.exit_code, 0, result.output)
        lines = result.output.rstrip("\n").splitlines()
        self.assertEqual(lines[-1], cli_mod.RESTART_HINT)
        self.assertTrue(lines[-2].startswith("Update: "), lines[-2])
        self.assertEqual(result.output.count(cli_mod.RESTART_HINT), 1)
        # The child is told to leave the hint to update.
        [(_, kwargs)] = rec.of("init")
        self.assertEqual(kwargs["env"].get(cli_mod._RESTART_HINT_ENV), "1")

    def test_no_restart_hint_when_hooks_unchanged(self):
        self.run_install()
        result, _ = self.invoke(["update", "--no-pull"])
        self.assertEqual(result.exit_code, 0, result.output)
        self.assertNotIn(cli_mod.RESTART_HINT, result.output)

    def test_not_a_git_clone_skips_pull(self):
        plain = FakePropel(Path(self._tmp.name) / "plain", repo=None)
        result, _ = self.invoke(["update"], propel_root=plain.root)
        self.assertEqual(result.exit_code, 0, result.output)
        self.assertIn(f"Propel at {plain.root} is not a git clone; skipping pull", result.output)


class UpdatePullTests(CommandTestCase):
    """self.propel is the upstream; self.clone is what the user installed from."""

    def setUp(self):
        super().setUp()
        self.propel.write("pyproject.toml", "[project]\nname = \"propel\"\n")
        self.propel.commit("add pyproject")
        self.clone = Path(self._tmp.name) / "clone"
        git(Path(self._tmp.name), "clone", "-q", str(self.propel.root), str(self.clone))

    def head(self) -> str:
        return git(self.clone, "rev-parse", "HEAD").strip()

    def test_dirty_tracked_file_refuses(self):
        (self.clone / "agents" / "code-reviewer.md").write_text("local edit\n")
        self.propel.write("agents/code-reviewer.md", "reviewer v2\n")
        self.propel.commit("v2")
        before = self.head()
        result, rec = self.invoke(["update"], propel_root=self.clone)
        self.assertEqual(result.exit_code, 1)
        out = result.output
        self.assertIn("agents/code-reviewer.md", out)
        self.assertIn("--no-pull", out)
        self.assertEqual(self.head(), before)
        self.assertEqual(rec.calls, [])

    def test_untracked_files_do_not_block(self):
        (self.clone / "scratch.txt").write_text("mine\n")
        result, _ = self.invoke(["update"], propel_root=self.clone)
        self.assertEqual(result.exit_code, 0, result.output)
        self.assertIn("already up to date", result.output)

    def test_pyproject_change_triggers_pip(self):
        self.run_install()
        self.propel.write("pyproject.toml", "[project]\nname = \"propel\"\n# v2\n")
        self.propel.commit("bump pyproject")
        result, rec = self.invoke(["update"], propel_root=self.clone)
        self.assertEqual(result.exit_code, 0, result.output)
        self.assertEqual(self.head(), git(self.propel.root, "rev-parse", "HEAD").strip())
        [(cmd, _)] = rec.of("pip")
        self.assertEqual(cmd, [sys.executable, "-m", "pip", "install", "-e", str(self.clone)])
        self.assertEqual(len(rec.of("init")), 1)
        self.assertIn("pulled 1 commit(s)", result.output)
        # pip ran before init
        self.assertEqual([_kind(c[0]) for c in rec.calls], ["pip", "init"])

    def test_init_py_change_triggers_pip(self):
        self.run_install()
        self.propel.write("src/propel_cli/__init__.py", '__version__ = "9.9.9"\n')
        self.propel.commit("bump version")
        result, rec = self.invoke(["update"], propel_root=self.clone)
        self.assertEqual(result.exit_code, 0, result.output)
        self.assertEqual(len(rec.of("pip")), 1)
        self.assertIn("reinstalled", result.output)

    def test_diff_error_reinstalls_to_be_safe(self):
        self.run_install()
        self.propel.write("agents/code-reviewer.md", "reviewer v2\n")
        self.propel.commit("v2")
        result, rec = self.invoke(["update"], propel_root=self.clone, recorder=ChildRecorder(git_rc={"diff": 128}))
        self.assertEqual(result.exit_code, 0, result.output)
        self.assertIn(
            "could not compare pyproject.toml/__init__.py (git exit 128); reinstalling to be safe", result.output
        )
        self.assertEqual(len(rec.of("pip")), 1)

    def test_other_change_skips_pip(self):
        self.propel.write("agents/code-reviewer.md", "reviewer v2\n")
        self.propel.commit("v2")
        result, rec = self.invoke(["update"], propel_root=self.clone)
        self.assertEqual(result.exit_code, 0, result.output)
        self.assertEqual(rec.of("pip"), [])
        self.assertEqual((self.clone / "agents" / "code-reviewer.md").read_text(), "reviewer v2\n")

    def test_pip_failure_prints_remedies_and_continues(self):
        self.run_install()
        self.propel.write("pyproject.toml", "[project]\nname = \"propel\"\n# v2\n")
        self.propel.commit("bump pyproject")
        result, rec = self.invoke(["update"], propel_root=self.clone, recorder=ChildRecorder(pip_rc=1))
        self.assertEqual(result.exit_code, 1, result.output)
        out = result.output
        self.assertIn(f"pip install -e {self.clone}", out)
        self.assertIn(f"uv pip install --python {sys.executable} -e {self.clone}", out)
        self.assertIn(f"uv tool install --reinstall --editable {self.clone}", out)
        self.assertIn("pipx reinstall propel", out)
        self.assertIn("reinstall failed — see above", out)
        self.assertEqual(len(rec.of("init")), 1)

    def test_pip_failure_and_init_failure_propagates_init_code(self):
        self.run_install()
        self.propel.write("pyproject.toml", "[project]\nname = \"propel\"\n# v2\n")
        self.propel.commit("bump pyproject")
        result, _ = self.invoke(["update"], propel_root=self.clone, recorder=ChildRecorder(pip_rc=1, init_rc=4))
        self.assertEqual(result.exit_code, 4, result.output)

    def test_dry_run_fetches_but_does_not_pull(self):
        self.run_install()
        self.propel.write("pyproject.toml", "[project]\nname = \"propel\"\n# v2\n")
        self.propel.commit("bump pyproject")
        before = self.head()
        result, rec = self.invoke(["update", "--dry-run"], propel_root=self.clone)
        self.assertEqual(result.exit_code, 0, result.output)
        self.assertEqual(self.head(), before)
        self.assertIn("1 commit(s) behind", result.output)
        self.assertEqual(rec.of("pip"), [])
        [(cmd, _)] = rec.of("init")
        self.assertEqual(cmd[-1], "--dry-run")

    def test_ff_only_failure_is_a_clean_error(self):
        git(self.clone, "-c", "user.email=t@e.com", "-c", "user.name=T", "-c", "commit.gpgsign=false",
            "commit", "-q", "--allow-empty", "-m", "local diverge")
        self.propel.write("agents/code-reviewer.md", "reviewer v2\n")
        self.propel.commit("v2")
        result, rec = self.invoke(["update"], propel_root=self.clone)
        self.assertEqual(result.exit_code, 1)
        self.assertIn("git pull --ff-only failed", result.output)
        self.assertEqual(rec.calls, [])


if __name__ == "__main__":
    unittest.main()
