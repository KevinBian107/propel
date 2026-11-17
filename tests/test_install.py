"""Tests for the install planner (src/propel_cli/install.py), `propel init`, and
the settings merge.

Usage: python -m unittest tests/test_install.py -v

Every test builds a fake propel clone in a temp dir, with its own git history,
and points the planner at it. Nothing touches this repo or ~/.claude (one test
only reads this repo's git history, to guard RETIRED_PATHS and
RETIRED_HOOK_REGISTRATIONS).
"""

import json
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

import click  # noqa: E402
from click.testing import CliRunner  # noqa: E402

from propel_cli import cli as cli_mod  # noqa: E402
from propel_cli import install  # noqa: E402


HOOKS_JSON = {
    "hooks": [
        {"event": "SessionStart", "command": "bash hooks/session-start.sh"},
        {"event": "UserPromptSubmit", "command": "bash hooks/route.sh"},
        {
            "event": "PostToolUse",
            "matcher": "Edit|Write",
            "command": "bash hooks/auditor-dispatch.sh",
        },
    ]
}

INITIAL_FILES = {
    "skills/investigation/SKILL.md": "investigation v1\n",
    "skills/using-propel/SKILL.md": "using propel v1\n",
    "agents/code-reviewer.md": "reviewer v1\n",
    "commands/intro.md": "intro v1\n",
    "hooks/session-start.sh": "#!/bin/bash\necho start\n",
    "hooks/route.sh": "#!/bin/bash\necho route\n",
    "hooks/auditor-dispatch.sh": "#!/bin/bash\necho audit\n",
    "hooks/hooks.json": json.dumps(HOOKS_JSON, indent=2) + "\n",
    "core/CORE.md": "core v1\n",
    "scripts/codex-consult.sh": "#!/bin/bash\necho codex\n",
}


GIT_CONFIG = (
    "-c", "user.email=test@example.com", "-c", "user.name=Test",
    "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null",
    "-c", "init.defaultBranch=main",
)


def git(root: Path, *args: str) -> str:
    return subprocess.run(
        ["git", *GIT_CONFIG, "-C", str(root), *args],
        capture_output=True, text=True, check=True,
    ).stdout


class FakePropel:
    """A propel clone with the six managed dirs.

    repo="own" (default): its own git history. repo=<Path>: the clone lives
    inside that outer repository, which holds the history. repo=None: no git.
    """

    def __init__(self, root: Path, repo="own"):
        self.root = root
        root.mkdir(parents=True)
        if repo == "own":
            self.repo = root
            git(root, "init", "-q", ".")
        else:
            self.repo = repo
        for rel, text in INITIAL_FILES.items():
            self.write(rel, text)
        self.commit("initial")

    def write(self, rel: str, text: str) -> None:
        path = self.root / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)

    def delete(self, rel: str) -> None:
        (self.root / rel).unlink()

    def commit(self, message: str) -> None:
        if self.repo is None:
            return
        git(self.repo, "add", "-A")
        git(self.repo, "commit", "-q", "-m", message)


class InstallTestCase(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        tmp = Path(self._tmp.name)
        self.propel = FakePropel(tmp / "propel")
        self.project = tmp / "project"
        self.project.mkdir()
        self.claude = self.project / ".claude"

    def tearDown(self):
        self._tmp.cleanup()

    # -- helpers ----------------------------------------------------------

    def run_install(self):
        """Files, then hook registrations, then the manifest — as init does, so
        install.status() sees no pending hook registrations afterwards."""
        manifest = install.load_manifest(self.project)
        p = install.plan(self.propel.root, self.claude, manifest)
        report = install.apply(p, self.project, install.source_info(self.propel.root))
        cli_mod.merge_hooks_config(
            self.claude / "settings.local.json", cli_mod._load_hooks_config(self.propel.root)
        )
        install.write_manifest(self.project, report["manifest"])
        return p, report

    def backup_dirs(self) -> list[str]:
        base = self.project / ".propel" / "backup"
        return sorted(d.name for d in base.iterdir()) if base.is_dir() else []

    def case_insensitive_or_skip(self):
        self.claude.mkdir(exist_ok=True)
        if not install._is_case_insensitive(self.claude):
            self.skipTest("filesystem is case-sensitive")

    def snapshot(self) -> dict:
        """Every file under the project, path -> bytes."""
        return {
            str(f.relative_to(self.project)): f.read_bytes()
            for f in self.project.rglob("*")
            if f.is_file()
        }

    def kinds(self, p) -> dict:
        return {a.path: a.kind for a in p.actions}


class PlannerTests(InstallTestCase):
    # 1
    def test_fresh_install_adds_everything_and_writes_manifest(self):
        p, report = self.run_install()
        self.assertTrue(p.actions)
        self.assertEqual({a.kind for a in p.actions}, {"add"})
        self.assertEqual(len(p.actions), len(INITIAL_FILES))
        for rel, text in INITIAL_FILES.items():
            self.assertEqual((self.claude / rel).read_text(), text)

        manifest = json.loads((self.project / ".propel" / "manifest.json").read_text())
        self.assertEqual(manifest["schema"], 1)
        self.assertEqual(manifest["propel_version"], cli_mod.install.__version__)
        self.assertEqual(manifest["source_commit"], git(self.propel.root, "rev-parse", "--short", "HEAD").strip())
        self.assertIs(manifest["source_dirty"], False)
        self.assertIn("installed_at", manifest)
        self.assertEqual(set(manifest["files"]), set(INITIAL_FILES))
        self.assertIsNone(report["backup_dir"])
        self.assertFalse((self.project / ".propel" / "backup").exists())
        # Shell helpers are executable
        self.assertTrue((self.claude / "hooks" / "route.sh").stat().st_mode & 0o111)
        self.assertTrue((self.claude / "scripts" / "codex-consult.sh").stat().st_mode & 0o111)

    # 2
    def test_second_run_is_idempotent(self):
        self.run_install()
        p, report = self.run_install()
        self.assertEqual(p.changes, 0)
        self.assertEqual(p.actions, [])
        self.assertIsNone(report["backup_dir"])

    # 3
    def test_user_skill_is_kept_across_runs(self):
        self.run_install()
        mine = self.claude / "skills" / "my-own" / "SKILL.md"
        mine.parent.mkdir(parents=True)
        mine.write_text("mine\n")
        before_mode = mine.stat().st_mode

        p, _ = self.run_install()
        self.assertEqual(self.kinds(p).get("skills/my-own/SKILL.md"), "keep_user")
        # Upstream moves on; the user file still survives
        self.propel.write("skills/investigation/SKILL.md", "investigation v2\n")
        self.propel.commit("v2")
        self.run_install()
        self.assertEqual(mine.read_text(), "mine\n")
        self.assertEqual(mine.stat().st_mode, before_mode)

    # 4
    def test_hand_edited_bundled_skill_is_replaced_and_backed_up(self):
        self.run_install()
        target = self.claude / "skills" / "investigation" / "SKILL.md"
        target.write_text("investigation v1\nmy edit\n")

        p, report = self.run_install()
        self.assertEqual(self.kinds(p), {"skills/investigation/SKILL.md": "replace_edited"})
        self.assertEqual(target.read_text(), "investigation v1\n")
        backup = report["backups"]["skills/investigation/SKILL.md"]
        self.assertTrue(backup.is_file())
        self.assertEqual(backup.read_text(), "investigation v1\nmy edit\n")
        self.assertEqual(backup.relative_to(report["backup_dir"]).as_posix(),
                         "skills/investigation/SKILL.md")
        self.assertEqual(report["backup_dir"].parent, self.project / ".propel" / "backup")

    def test_unedited_bundled_file_changed_upstream_is_plain_replace(self):
        self.run_install()
        self.propel.write("agents/code-reviewer.md", "reviewer v2\n")
        self.propel.commit("v2")
        p, report = self.run_install()
        self.assertEqual(self.kinds(p), {"agents/code-reviewer.md": "replace"})
        self.assertEqual((self.claude / "agents/code-reviewer.md").read_text(), "reviewer v2\n")
        self.assertTrue(report["backups"]["agents/code-reviewer.md"].is_file())

    # 5
    def test_file_removed_upstream_is_removed_and_backed_up(self):
        self.propel.write("skills/old-skill/SKILL.md", "old\n")
        self.propel.commit("add old skill")
        self.run_install()
        self.assertTrue((self.claude / "skills/old-skill/SKILL.md").exists())

        self.propel.delete("skills/old-skill/SKILL.md")
        self.propel.commit("drop old skill")
        p, report = self.run_install()
        self.assertEqual(self.kinds(p), {"skills/old-skill/SKILL.md": "remove"})
        self.assertFalse((self.claude / "skills/old-skill/SKILL.md").exists())
        self.assertFalse((self.claude / "skills/old-skill").exists(), "empty dir left behind")
        self.assertTrue((self.claude / "skills").is_dir())
        self.assertEqual(report["backups"]["skills/old-skill/SKILL.md"].read_text(), "old\n")

    def test_removal_keeps_directory_holding_user_files(self):
        self.propel.write("skills/old-skill/SKILL.md", "old\n")
        self.propel.commit("add old skill")
        self.run_install()
        notes = self.claude / "skills/old-skill/notes.md"
        notes.write_text("my notes\n")
        self.propel.delete("skills/old-skill/SKILL.md")
        self.propel.commit("drop old skill")
        self.run_install()
        self.assertEqual(notes.read_text(), "my notes\n")

    # 6
    def test_legacy_install_without_manifest(self):
        # A path Propel shipped once and later dropped, still sitting in an
        # old install; and a file Propel never shipped.
        self.propel.write("commands/renamed-away.md", "old command\n")
        self.propel.commit("add command")
        self.propel.delete("commands/renamed-away.md")
        self.propel.commit("drop command")

        for rel, text in INITIAL_FILES.items():
            dest = self.claude / rel
            dest.parent.mkdir(parents=True, exist_ok=True)
            dest.write_text(text)
        (self.claude / "commands/renamed-away.md").write_text("old command\n")
        (self.claude / "commands/my-command.md").write_text("mine\n")
        self.assertIsNone(install.load_manifest(self.project))

        p, _ = self.run_install()
        kinds = self.kinds(p)
        self.assertEqual(kinds["commands/renamed-away.md"], "remove")
        self.assertEqual(kinds["commands/my-command.md"], "keep_user")
        self.assertFalse((self.claude / "commands/renamed-away.md").exists())
        self.assertEqual((self.claude / "commands/my-command.md").read_text(), "mine\n")
        self.assertTrue((self.project / ".propel" / "manifest.json").is_file())

    def test_legacy_install_differing_file_counts_as_edited(self):
        dest = self.claude / "core/CORE.md"
        dest.parent.mkdir(parents=True)
        dest.write_text("something else\n")
        p = install.plan(self.propel.root, self.claude, None)
        self.assertEqual(self.kinds(p)["core/CORE.md"], "replace_edited")

    def test_historical_paths_without_git_is_empty(self):
        with tempfile.TemporaryDirectory() as d:
            self.assertEqual(install.historical_paths(Path(d)), set())

    def test_legacy_differing_file_matching_old_shipped_blob_is_neutral_replace(self):
        # Installed from an older Propel: matches a blob in history, so it is
        # an update, not an edit.
        self.propel.write("core/CORE.md", "core v2\n")
        self.propel.commit("v2")
        dest = self.claude / "core/CORE.md"
        dest.parent.mkdir(parents=True)
        dest.write_text("core v1\n")
        p = install.plan(self.propel.root, self.claude, None)
        action = next(a for a in p.actions if a.path == "core/CORE.md")
        self.assertEqual(action.kind, "replace")
        self.assertEqual(action.note, install.LABEL_OLDER_VERSION)

    def test_legacy_differing_file_matching_no_blob_is_labelled(self):
        dest = self.claude / "core/CORE.md"
        dest.parent.mkdir(parents=True)
        dest.write_text("something else\n")
        p = install.plan(self.propel.root, self.claude, None)
        action = next(a for a in p.actions if a.path == "core/CORE.md")
        self.assertEqual(action.note, install.LABEL_NO_SHIPPED_MATCH)

    def test_shallow_clone_misses_renamed_path_but_retired_paths_cover_it(self):
        # In a depth-1 clone the rename commit is the root, so the old path is
        # in no visible commit: history alone cannot find it. RETIRED_PATHS can.
        git(self.propel.root, "mv", "agents/code-reviewer.md", "agents/reviewer.md")
        self.propel.commit("rename")
        full = install.historical_paths(self.propel.root)
        self.assertIn("agents/code-reviewer.md", full)

        shallow = self.propel.root.parent / "shallow"
        subprocess.run(
            ["git", *GIT_CONFIG, "clone", "-q", "--depth", "1",
             self.propel.root.as_uri(), str(shallow)],
            capture_output=True, text=True, check=True,
        )
        history = install.historical_paths(shallow)
        self.assertIn("agents/reviewer.md", history)
        self.assertNotIn("agents/code-reviewer.md", history)

        old = self.claude / "agents/code-reviewer.md"
        old.parent.mkdir(parents=True)
        old.write_text("reviewer v1\n")
        p = install.plan(shallow, self.claude, None)
        self.assertEqual(self.kinds(p)["agents/code-reviewer.md"], "keep_user")
        with mock.patch.object(install, "RETIRED_PATHS",
                               install.RETIRED_PATHS | {"agents/code-reviewer.md"}):
            p = install.plan(shallow, self.claude, None)
        self.assertIn(self.kinds(p)["agents/code-reviewer.md"], ("remove", "remove_edited"))

    def test_nested_clone_does_not_read_outer_repo_history(self):
        outer = self.propel.root.parent / "outer"
        outer.mkdir()
        git(outer, "init", "-q", ".")
        nested = FakePropel(outer / "propel", repo=outer)
        nested.write("commands/gone.md", "gone\n")
        nested.commit("add gone")
        nested.delete("commands/gone.md")
        nested.commit("drop gone")
        self.assertEqual(install.historical_paths(nested.root), set())
        self.assertEqual(install.historical_blobs(nested.root), {})
        self.assertIsNone(install.source_info(nested.root)["commit"])

        gone = self.claude / "commands/gone.md"
        gone.parent.mkdir(parents=True)
        gone.write_text("gone\n")
        manifest = install.load_manifest(self.project)
        p = install.plan(nested.root, self.claude, manifest)
        install.apply(p, self.project, install.source_info(nested.root))
        self.assertEqual(self.kinds(p)["commands/gone.md"], "keep_user")
        self.assertEqual(gone.read_text(), "gone\n")

    def test_removal_via_manifest_alone(self):
        self.propel.write("skills/old-skill/SKILL.md", "old\n")
        self.run_install()
        self.propel.delete("skills/old-skill/SKILL.md")
        # Never committed: history knows nothing. The manifest is enough.
        manifest = install.load_manifest(self.project)
        p = install.plan(self.propel.root, self.claude, manifest, history=set(), blobs={})
        self.assertEqual(self.kinds(p), {"skills/old-skill/SKILL.md": "remove"})
        install.apply(p, self.project, None)
        self.assertFalse((self.claude / "skills/old-skill/SKILL.md").exists())

    def test_edited_removal_is_remove_edited_with_backup(self):
        self.propel.write("skills/old-skill/SKILL.md", "old\n")
        self.run_install()
        (self.claude / "skills/old-skill/SKILL.md").write_text("old\nmine\n")
        self.propel.delete("skills/old-skill/SKILL.md")
        p, report = self.run_install()
        self.assertEqual(self.kinds(p), {"skills/old-skill/SKILL.md": "remove_edited"})
        self.assertEqual(report["backups"]["skills/old-skill/SKILL.md"].read_text(), "old\nmine\n")
        self.assertFalse((self.claude / "skills/old-skill/SKILL.md").exists())

    def test_retired_path_removed_without_any_git(self):
        nogit = FakePropel(self.propel.root.parent / "zip-propel", repo=None)
        self.assertEqual(install.historical_paths(nogit.root), set())
        c = self.claude / "skills/c-codex/SKILL.md"
        c.parent.mkdir(parents=True)
        c.write_text("old c-codex\n")
        p = install.plan(nogit.root, self.claude, None)
        report = install.apply(p, self.project, install.source_info(nogit.root))
        self.assertIn(self.kinds(p)["skills/c-codex/SKILL.md"], ("remove", "remove_edited"))
        self.assertFalse(c.exists())
        self.assertEqual(report["backups"]["skills/c-codex/SKILL.md"].read_text(), "old c-codex\n")

    def test_user_hook_mode_bits_untouched(self):
        self.run_install()
        mine = self.claude / "hooks" / "my.sh"
        mine.write_text("#!/bin/bash\necho mine\n")
        mine.chmod(0o644)
        self.propel.write("hooks/route.sh", "#!/bin/bash\necho route v2\n")
        self.propel.commit("v2")
        p, _ = self.run_install()
        self.assertEqual(self.kinds(p)["hooks/my.sh"], "keep_user")
        self.assertEqual(mine.stat().st_mode & 0o777, 0o644)
        self.assertTrue((self.claude / "hooks/route.sh").stat().st_mode & 0o111)

    def test_conflict_user_file_at_newly_shipped_path(self):
        self.run_install()
        clash = self.claude / "agents" / "new-agent.md"
        clash.write_text("my agent\n")
        p, _ = self.run_install()
        self.assertEqual(self.kinds(p), {"agents/new-agent.md": "keep_user"})

        self.propel.write("agents/new-agent.md", "propel agent\n")
        self.propel.commit("new agent")
        p, report = self.run_install()
        self.assertEqual(self.kinds(p), {"agents/new-agent.md": "conflict_user"})
        self.assertEqual(p.changes, 0)
        self.assertEqual(clash.read_text(), "my agent\n")
        self.assertNotIn("agents/new-agent.md", install.load_manifest(self.project)["files"])
        self.assertEqual(report["backups"], {})

    def test_symlinked_skills_dir_outside_is_never_touched(self):
        self.run_install()
        outside = self.propel.root.parent / "outside-skills"
        outside.mkdir()
        (outside / "investigation").mkdir()
        (outside / "investigation" / "SKILL.md").write_text("outside\n")
        (outside / "c-codex").mkdir()
        (outside / "c-codex" / "SKILL.md").write_text("outside c-codex\n")
        before = {str(f): f.read_bytes() for f in outside.rglob("*") if f.is_file()}

        import shutil
        shutil.rmtree(self.claude / "skills")
        (self.claude / "skills").symlink_to(outside, target_is_directory=True)
        p, report = self.run_install()
        kinds = self.kinds(p)
        self.assertEqual(kinds["skills/investigation/SKILL.md"], "keep_user")
        self.assertEqual(kinds["skills/using-propel/SKILL.md"], "keep_user")
        self.assertNotIn("skills/c-codex/SKILL.md", kinds)
        after = {str(f): f.read_bytes() for f in outside.rglob("*") if f.is_file()}
        self.assertEqual(after, before)
        self.assertFalse(any(k.startswith("skills/") for k in install.load_manifest(self.project)["files"]))

    def test_symlinked_file_pointing_outside_is_kept(self):
        self.run_install()
        outside = self.propel.root.parent / "outside.md"
        outside.write_text("outside\n")
        link = self.claude / "core/CORE.md"
        link.unlink()
        link.symlink_to(outside)
        p, _ = self.run_install()
        action = next(a for a in p.actions if a.path == "core/CORE.md")
        self.assertEqual((action.kind, action.note), ("keep_user", install.REASON_SYMLINK))
        self.assertTrue(link.is_symlink())
        self.assertEqual(outside.read_text(), "outside\n")

    def test_file_dir_clash_is_conflict_and_apply_completes(self):
        self.run_install()
        # A user file where Propel's new skill needs a directory, and a user
        # directory where Propel's new agent needs a file.
        (self.claude / "skills/new-skill").write_text("a file\n")
        (self.claude / "agents/new-agent.md").mkdir()
        (self.claude / "agents/new-agent.md/notes.txt").write_text("mine\n")
        self.propel.write("skills/new-skill/SKILL.md", "new skill\n")
        self.propel.write("agents/new-agent.md", "new agent\n")
        self.propel.write("core/NEW.md", "new core\n")
        self.propel.commit("new paths")
        p, _ = self.run_install()
        kinds = self.kinds(p)
        self.assertEqual(kinds["skills/new-skill/SKILL.md"], "conflict_user")
        self.assertEqual(kinds["agents/new-agent.md"], "conflict_user")
        self.assertEqual(kinds["core/NEW.md"], "add")
        self.assertEqual((self.claude / "core/NEW.md").read_text(), "new core\n")
        self.assertEqual((self.claude / "skills/new-skill").read_text(), "a file\n")
        files = install.load_manifest(self.project)["files"]
        self.assertNotIn("skills/new-skill/SKILL.md", files)
        self.assertIn("core/NEW.md", files)

    def test_manifest_records_only_owned_paths_with_disk_hashes(self):
        self.run_install()
        self.propel.write("agents/new-agent.md", "propel agent\n")
        self.propel.commit("new agent")
        (self.claude / "agents/new-agent.md").write_text("my agent\n")
        self.run_install()
        files = install.load_manifest(self.project)["files"]
        self.assertNotIn("agents/new-agent.md", files)
        for rel, digest in files.items():
            self.assertEqual(digest, install._sha256(self.claude / rel))

    def test_case_only_rename_with_same_bytes_is_unchanged(self):
        self.propel.write("skills/Casey/SKILL.md", "casey\n")
        self.propel.commit("add Casey")
        self.run_install()
        self.case_insensitive_or_skip()
        git(self.propel.root, "mv", "skills/Casey/SKILL.md", "skills/Casey/skill.md")
        self.propel.commit("lowercase")
        p, _ = self.run_install()
        self.assertEqual(p.actions, [])
        self.assertIn("skills/Casey/skill.md", p.unchanged)
        # Recorded under the shipped key; the file keeps its existing name.
        self.assertIn("skills/Casey/skill.md", install.load_manifest(self.project)["files"])
        self.assertEqual(os.listdir(self.claude / "skills/Casey"), ["SKILL.md"])

    def test_case_mismatched_directory_never_loops(self):
        self.run_install()
        self.case_insensitive_or_skip()
        skills = self.claude / "skills"
        (skills / "investigation").rename(skills / "tmp-x")
        (skills / "tmp-x").rename(skills / "Investigation")
        before = self.backup_dirs()
        for _ in range(2):
            p, report = self.run_install()
            self.assertEqual(p.changes, 0, p.actions)
            self.assertIsNone(report["backup_dir"])
        self.assertEqual(self.backup_dirs(), before)
        self.assertIn("Investigation", os.listdir(skills))
        self.assertIn("skills/investigation/SKILL.md", install.load_manifest(self.project)["files"])

    def test_case_mismatched_edited_file_follows_ownership_rules(self):
        self.run_install()
        self.case_insensitive_or_skip()
        skills = self.claude / "skills"
        (skills / "investigation").rename(skills / "tmp-x")
        (skills / "tmp-x").rename(skills / "Investigation")
        (skills / "Investigation/SKILL.md").write_text("investigation v1\nmine\n")
        p, report = self.run_install()
        self.assertEqual(self.kinds(p), {"skills/investigation/SKILL.md": "replace_edited"})
        self.assertEqual((skills / "Investigation/SKILL.md").read_text(), "investigation v1\n")
        self.assertEqual(report["backups"]["skills/investigation/SKILL.md"].read_text(),
                         "investigation v1\nmine\n")
        self.assertIn("Investigation", os.listdir(skills))
        before = self.backup_dirs()
        p, _ = self.run_install()
        self.assertEqual(p.changes, 0)
        self.assertEqual(self.backup_dirs(), before)

    def test_case_mismatched_unrecorded_file_is_conflict_with_manifest(self):
        self.run_install()
        self.case_insensitive_or_skip()
        (self.claude / "agents/New-Agent.md").write_text("my agent\n")
        self.propel.write("agents/new-agent.md", "propel agent\n")
        self.propel.commit("new agent")
        p, _ = self.run_install()
        self.assertEqual(self.kinds(p), {"agents/new-agent.md": "conflict_user"})
        self.assertEqual((self.claude / "agents/New-Agent.md").read_text(), "my agent\n")

    def test_case_mismatched_legacy_file_matching_blob_is_neutral_replace(self):
        self.case_insensitive_or_skip()
        self.propel.write("core/CORE.md", "core v2\n")
        self.propel.commit("v2")
        (self.claude / "Core").mkdir()
        (self.claude / "Core/CORE.md").write_text("core v1\n")
        p = install.plan(self.propel.root, self.claude, None)
        action = next(a for a in p.actions if a.path == "core/CORE.md")
        self.assertEqual((action.kind, action.note), ("replace", install.LABEL_OLDER_VERSION))

    def test_retired_paths_cover_every_deletion_in_this_repo(self):
        # Guards future renames: a shipped path deleted on main line without
        # being added to RETIRED_PATHS fails here.
        if not install._is_dedicated_repo(ROOT):
            self.skipTest("not running from a git clone of propel")
        out = subprocess.run(
            ["git", "-C", str(ROOT), "log", "HEAD", "--no-renames", "--diff-filter=D",
             "--name-only", "--pretty=format:", "-z", "--", *install.MANAGED_DIRS],
            capture_output=True, text=True, check=True,
        ).stdout
        deleted = {p.strip("\n") for p in out.split("\0") if p.strip("\n")}
        current = set(install._files_under(ROOT))
        missing = sorted(deleted - current - install.RETIRED_PATHS)
        self.assertEqual(missing, [], "add these to install.RETIRED_PATHS")

    def test_retired_hook_registrations_cover_every_dropped_registration_in_this_repo(self):
        # Guards future edits to hooks/hooks.json: a registration dropped on
        # main line without being added to RETIRED_HOOK_REGISTRATIONS fails here.
        if not install._is_dedicated_repo(ROOT):
            self.skipTest("not running from a git clone of propel")
        history = install.git_hook_registrations(ROOT)
        self.assertTrue(history, "expected hooks/hooks.json in this repo's history")
        current = install.parse_hook_registrations((ROOT / "hooks" / "hooks.json").read_text())
        missing = sorted(history - current - install.RETIRED_HOOK_REGISTRATIONS)
        self.assertEqual(missing, [], "add these to install.RETIRED_HOOK_REGISTRATIONS")

    def test_historical_hook_registrations(self):
        self.propel.write("hooks/hooks.json", json.dumps({"hooks": [
            *HOOKS_JSON["hooks"],
            {"event": "SessionStart", "command": "bash hooks/session-start.sh oldpart"},
        ]}))
        self.propel.commit("add oldpart")
        self.propel.write("hooks/hooks.json", "{not json")
        self.propel.commit("broken version")
        self.propel.write("hooks/hooks.json", json.dumps(HOOKS_JSON, indent=2) + "\n")
        self.propel.commit("drop oldpart")
        found = install.historical_hook_registrations(self.propel.root)
        self.assertIn(("SessionStart", "", "bash .claude/hooks/session-start.sh oldpart"), found)
        self.assertIn(("PostToolUse", "Edit|Write", "bash .claude/hooks/auditor-dispatch.sh"), found)
        # Without git: the current hooks.json only.
        nogit = FakePropel(self.propel.root.parent / "zip-propel", repo=None)
        self.assertEqual(install.historical_hook_registrations(nogit.root), {
            ("SessionStart", "", "bash .claude/hooks/session-start.sh"),
            ("UserPromptSubmit", "", "bash .claude/hooks/route.sh"),
            ("PostToolUse", "Edit|Write", "bash .claude/hooks/auditor-dispatch.sh"),
        })

    def test_user_file_at_retired_path_is_kept_with_manifest(self):
        self.run_install()
        mine = self.claude / "commands/propel.md"
        mine.write_text("my own propel command\n")
        p, report = self.run_install()
        self.assertEqual(self.kinds(p), {"commands/propel.md": "keep_user"})
        self.assertEqual(mine.read_text(), "my own propel command\n")
        self.assertIsNone(report["backup_dir"])

    def test_retired_path_still_removed_in_legacy_mode(self):
        (self.claude / "commands").mkdir(parents=True)
        (self.claude / "commands/propel.md").write_text("old\n")
        p = install.plan(self.propel.root, self.claude, None)
        self.assertIn(self.kinds(p)["commands/propel.md"], ("remove", "remove_edited"))

    def test_no_history_legacy_labels_are_neutral(self):
        nogit = FakePropel(self.propel.root.parent / "zip-propel", repo=None)
        self.assertFalse(install.history_available(nogit.root))
        core = self.claude / "core/CORE.md"
        core.parent.mkdir(parents=True)
        core.write_text("something else\n")
        c = self.claude / "skills/c-codex/SKILL.md"
        c.parent.mkdir(parents=True)
        c.write_text("old c-codex\n")
        p = install.plan(nogit.root, self.claude, None)
        by_path = {a.path: a for a in p.actions}
        self.assertEqual((by_path["core/CORE.md"].kind, by_path["core/CORE.md"].note),
                         ("replace", install.LABEL_NO_HISTORY))
        self.assertEqual((by_path["skills/c-codex/SKILL.md"].kind, by_path["skills/c-codex/SKILL.md"].note),
                         ("remove", install.LABEL_NO_HISTORY))
        self.assertFalse(p.of("replace_edited") + p.of("remove_edited"))

    def test_shallow_clone_has_no_history(self):
        self.assertTrue(install.history_available(self.propel.root))
        shallow = self.propel.root.parent / "shallow"
        subprocess.run(
            ["git", *GIT_CONFIG, "clone", "-q", "--depth", "1",
             self.propel.root.as_uri(), str(shallow)],
            capture_output=True, text=True, check=True,
        )
        self.assertFalse(install.history_available(shallow))
        core = self.claude / "core/CORE.md"
        core.parent.mkdir(parents=True)
        core.write_text("something else\n")
        action = next(a for a in install.plan(shallow, self.claude, None).actions if a.path == "core/CORE.md")
        self.assertEqual((action.kind, action.note), ("replace", install.LABEL_NO_HISTORY))

    def test_history_unavailable_when_git_missing(self):
        with mock.patch.object(install.subprocess, "run", side_effect=FileNotFoundError):
            self.assertFalse(install.history_available(self.propel.root))

    def test_missing_manifest_is_none_corrupt_manifest_raises(self):
        self.assertIsNone(install.load_manifest(self.project))
        path = self.project / ".propel" / "manifest.json"
        path.parent.mkdir()
        for bad in ("{not json", "[1, 2]", '{"files": []}', ""):
            path.write_text(bad)
            with self.assertRaises(install.ManifestError) as ctx:
                install.load_manifest(self.project)
            self.assertIn(str(path), str(ctx.exception))
            self.assertIn("delete", str(ctx.exception))

    def test_apply_returns_manifest_without_writing_it(self):
        p = install.plan(self.propel.root, self.claude, None)
        report = install.apply(p, self.project, install.source_info(self.propel.root))
        self.assertFalse((self.project / ".propel" / "manifest.json").exists())
        self.assertEqual(set(report["manifest"]["files"]), set(INITIAL_FILES))
        path = install.write_manifest(self.project, report["manifest"])
        self.assertEqual(install.load_manifest(self.project), report["manifest"])
        self.assertEqual(path, self.project / ".propel" / "manifest.json")

    def test_failed_write_leaves_original_file_intact(self):
        self.run_install()
        target = self.claude / "agents/code-reviewer.md"
        self.propel.write("agents/code-reviewer.md", "reviewer v2\n")
        self.propel.commit("v2")
        p = install.plan(self.propel.root, self.claude, install.load_manifest(self.project))
        with mock.patch.object(install.os, "replace", side_effect=OSError("disk full")):
            with self.assertRaises(OSError):
                install.apply(p, self.project, None)
        self.assertEqual(target.read_text(), "reviewer v1\n")
        leftovers = [n for n in os.listdir(target.parent) if n.endswith(".tmp")]
        self.assertEqual(leftovers, [])

    def test_replace_preserves_source_mode(self):
        self.run_install()
        self.propel.write("core/CORE.md", "core v2\n")
        (self.propel.root / "core/CORE.md").chmod(0o640)
        self.propel.commit("v2")
        self.run_install()
        core = self.claude / "core/CORE.md"
        self.assertEqual(core.read_text(), "core v2\n")
        self.assertEqual(core.stat().st_mode & 0o777, 0o640)

    def test_inside_symlink_leaf_is_replaced_by_regular_file(self):
        self.run_install()
        link = self.claude / "core/CORE.md"
        other = self.claude / "core/other.md"
        other.write_text("other\n")
        link.unlink()
        link.symlink_to(other)
        self.run_install()
        self.assertFalse(link.is_symlink())
        self.assertEqual(link.read_text(), "core v1\n")
        self.assertEqual(other.read_text(), "other\n")

    def test_prune_keeps_newest_ten_and_never_the_protected_one(self):
        base = self.project / ".propel" / "backup"
        names = [f"20250101-0000{i:02d}" for i in range(12)]
        for n in names:
            (base / n).mkdir(parents=True)
        (base / "stray-file").write_text("x")
        removed = install.prune_backups(self.project, protect=(base / names[0],))
        self.assertEqual(sorted(r.name for r in removed), [names[1]])
        self.assertIn(names[0], os.listdir(base))
        removed = install.prune_backups(self.project)
        self.assertEqual(sorted(d.name for d in base.iterdir() if d.is_dir()), names[2:])

    def test_apply_prunes_old_backups(self):
        base = self.project / ".propel" / "backup"
        for i in range(12):
            (base / f"20000101-0000{i:02d}").mkdir(parents=True)
        self.run_install()
        (self.claude / "core/CORE.md").write_text("edited\n")
        _, report = self.run_install()
        dirs = self.backup_dirs()
        self.assertEqual(len(dirs), install.BACKUPS_KEPT)
        self.assertIn(report["backup_dir"].name, dirs)
        self.assertNotIn("20000101-000000", dirs)

    # 8 (planner level)
    def test_plan_alone_writes_nothing(self):
        self.run_install()
        (self.claude / "core/CORE.md").write_text("edited\n")
        before = self.snapshot()
        p = install.plan(self.propel.root, self.claude, install.load_manifest(self.project))
        self.assertTrue(p.changes)
        self.assertEqual(self.snapshot(), before)

    def test_status(self):
        s = install.status(self.propel.root, self.project)
        self.assertFalse(s["installed"])
        self.assertFalse(s["update_available"])
        self.run_install()
        (self.claude / "skills/my-own").mkdir()
        (self.claude / "skills/my-own/SKILL.md").write_text("x\n")
        (self.claude / "core/CORE.md").write_text("edited\n")
        s = install.status(self.propel.root, self.project)
        self.assertTrue(s["installed"])
        self.assertEqual(s["changes"], 1)
        self.assertEqual(s["edited_bundled"], 1)
        self.assertEqual(s["user_files"], 1)
        self.assertTrue(s["update_available"])
        self.assertEqual(s["installed_version"], s["available_version"])

    def test_status_not_installed_runs_no_plan_or_git(self):
        with mock.patch.object(install, "_git", side_effect=AssertionError("git called")), \
                mock.patch.object(install, "plan", side_effect=AssertionError("plan called")):
            s = install.status(self.propel.root, self.project)
        self.assertEqual(s, {
            "available_version": install.__version__,
            "available_commit": None,
            "available_dirty": None,
            "installed_version": None,
            "installed_commit": None,
            "installed": False,
            "changes": None,
            "edited_bundled": None,
            "user_files": None,
            "hooks_pending": None,
            "settings_error": None,
            "update_available": False,
        })

    def settings_path(self) -> Path:
        return self.claude / "settings.local.json"

    def test_status_counts_hook_registration_deleted_from_settings(self):
        self.run_install()
        s = install.status(self.propel.root, self.project)
        self.assertEqual((s["changes"], s["hooks_pending"], s["settings_error"]), (0, 0, None))
        self.assertIs(s["update_available"], False)
        settings = json.loads(self.settings_path().read_text())
        del settings["hooks"]["UserPromptSubmit"]
        self.settings_path().write_text(json.dumps(settings))
        s = install.status(self.propel.root, self.project)
        self.assertEqual(s["changes"], 0)
        self.assertEqual(s["hooks_pending"], 1)
        self.assertIs(s["update_available"], True)

    def test_status_missing_settings_means_every_registration_pending(self):
        self.run_install()
        self.settings_path().unlink()
        s = install.status(self.propel.root, self.project)
        self.assertEqual(s["hooks_pending"], len(HOOKS_JSON["hooks"]))
        self.assertIs(s["update_available"], True)

    def test_status_unparsable_settings_never_raises(self):
        self.run_install()
        self.settings_path().write_text("{not json")
        s = install.status(self.propel.root, self.project)
        self.assertIsNone(s["hooks_pending"])
        self.assertIn("Could not parse", s["settings_error"])
        self.assertIs(s["update_available"], False)
        self.settings_path().write_text('{"hooks": []}')
        s = install.status(self.propel.root, self.project)
        self.assertIsNone(s["hooks_pending"])
        self.assertIn('"hooks" in', s["settings_error"])

    def test_orphan_manifest_without_claude_dir_is_not_installed(self):
        self.run_install()
        shutil.rmtree(self.claude)
        s = install.status(self.propel.root, self.project)
        self.assertIs(s["installed"], False)
        self.assertIsNone(s["changes"])
        self.assertIs(s["update_available"], False)

    def test_git_timeout_is_a_failed_call(self):
        timeout = subprocess.TimeoutExpired(["git"], 20)
        with mock.patch.object(install.subprocess, "run", side_effect=timeout) as run:
            self.assertIsNone(install._git(self.propel.root, "rev-parse", "HEAD"))
        self.assertEqual(run.call_args.kwargs["timeout"], 20)


class InitCommandTests(InstallTestCase):
    def invoke_init(self, *args):
        runner = CliRunner()
        with mock.patch.object(cli_mod, "get_propel_root", return_value=self.propel.root), \
                mock.patch.object(cli_mod, "get_project_root", return_value=self.project), \
                mock.patch.object(cli_mod, "GLOBAL_DIR", self.project / "no-global-dir"):
            result = runner.invoke(cli_mod.cli, ["init", *args], catch_exceptions=False)
        return result

    # 8 (command level)
    def test_dry_run_writes_nothing(self):
        before = self.snapshot()
        result = self.invoke_init("--dry-run")
        self.assertEqual(result.exit_code, 0, result.output)
        self.assertIn("would add", result.output)
        self.assertEqual(self.snapshot(), before)
        self.assertFalse(self.claude.exists())
        self.assertFalse((self.project / ".propel").exists())

    def test_dry_run_on_installed_project_writes_nothing(self):
        self.assertEqual(self.invoke_init().exit_code, 0)
        (self.claude / "core/CORE.md").write_text("edited\n")
        before = self.snapshot()
        result = self.invoke_init("--dry-run", "--yes")
        self.assertEqual(result.exit_code, 0, result.output)
        self.assertIn("would replace 1 edited", result.output)
        self.assertEqual(self.snapshot(), before)

    def test_init_end_to_end(self):
        result = self.invoke_init()
        self.assertEqual(result.exit_code, 0, result.output)
        manifest = install.load_manifest(self.project)
        self.assertEqual(len(manifest["hooks"]), 3)
        self.assertEqual(
            manifest["hooks"][0],
            {"event": "SessionStart", "matcher": "",
             "hooks": [{"type": "command", "command": "bash .claude/hooks/session-start.sh"}]},
        )

        mine = self.claude / "skills/my-own/SKILL.md"
        mine.parent.mkdir(parents=True)
        mine.write_text("mine\n")
        with open(self.claude / "skills/investigation/SKILL.md", "a") as f:
            f.write("edited\n")

        result = self.invoke_init()
        self.assertEqual(result.exit_code, 0, result.output)
        self.assertEqual(mine.read_text(), "mine\n")
        self.assertEqual((self.claude / "skills/investigation/SKILL.md").read_text(), "investigation v1\n")
        self.assertIn(".claude/skills/investigation/SKILL.md  ->  backup .propel/backup/", result.output)
        self.assertIn("kept 1 file(s) of your own", result.output)

        result = self.invoke_init()
        self.assertIn("Propel files — no changes", result.output)

    def write_settings(self, data: dict) -> Path:
        self.claude.mkdir(exist_ok=True)
        path = self.claude / "settings.local.json"
        path.write_text(json.dumps(data))
        return path

    def group(self, command, matcher=""):
        return {"matcher": matcher, "hooks": [{"type": "command", "command": command}]}

    def test_legacy_first_run_keeps_user_hook_and_removes_propel_precompact(self):
        # working-memory.sh shipped once and was dropped; its PreCompact
        # registration is in RETIRED_HOOK_REGISTRATIONS.
        self.propel.write("hooks/working-memory.sh", "#!/bin/bash\n")
        self.propel.commit("add wm")
        self.propel.delete("hooks/working-memory.sh")
        self.propel.commit("drop wm")
        mine = self.group("bash .claude/hooks/my-lint.sh", "Edit|Write")
        path = self.write_settings({"hooks": {
            "PostToolUse": [mine],
            "PreCompact": [self.group("bash .claude/hooks/working-memory.sh")],
        }})
        (self.claude / "hooks").mkdir()
        (self.claude / "hooks/my-lint.sh").write_text("#!/bin/bash\n")
        result = self.invoke_init()
        self.assertEqual(result.exit_code, 0, result.output)
        hooks = json.loads(path.read_text())["hooks"]
        self.assertIn(mine, hooks["PostToolUse"])
        self.assertNotIn("PreCompact", hooks)
        self.assertTrue((self.claude / "hooks/my-lint.sh").exists())
        self.assertIn("removed stale Propel hook group PreCompact: bash .claude/hooks/working-memory.sh",
                      result.output)
        self.assertIn("previous settings backed up to .propel/backup/", result.output)

    def test_legacy_part_dropped_from_hooks_json_is_removed_via_history(self):
        # A registration that existed in a past hooks.json and is gone now is
        # Propel's by history alone (it is not in RETIRED_HOOK_REGISTRATIONS).
        self.propel.write("hooks/hooks.json", json.dumps({"hooks": [
            *HOOKS_JSON["hooks"],
            {"event": "SessionStart", "command": "bash hooks/session-start.sh oldpart"},
        ]}))
        self.propel.commit("add oldpart")
        self.propel.write("hooks/hooks.json", json.dumps(HOOKS_JSON, indent=2) + "\n")
        self.propel.commit("drop oldpart")
        stale = self.group("bash .claude/hooks/session-start.sh oldpart")
        mine = self.group("bash .claude/hooks/session-start.sh otherpart")
        path = self.write_settings({"hooks": {"SessionStart": [stale, mine]}})
        result = self.invoke_init()
        self.assertEqual(result.exit_code, 0, result.output)
        entries = json.loads(path.read_text())["hooks"]["SessionStart"]
        self.assertNotIn(stale, entries)
        self.assertIn(mine, entries)
        self.assertIn("removed stale Propel hook group SessionStart: "
                      "bash .claude/hooks/session-start.sh oldpart", result.output)

    def test_zip_clone_retired_registrations_still_remove_precompact(self):
        self.propel = FakePropel(self.propel.root.parent / "zip-propel", repo=None)
        mine = self.group("bash .claude/hooks/session-start.sh", "compact")
        path = self.write_settings({"hooks": {
            "PreCompact": [
                self.group("bash .claude/hooks/session-start.sh"),
                self.group("bash .claude/hooks/working-memory.sh"),
            ],
            "SessionStart": [mine],
        }})
        result = self.invoke_init()
        self.assertEqual(result.exit_code, 0, result.output)
        hooks = json.loads(path.read_text())["hooks"]
        self.assertNotIn("PreCompact", hooks)
        self.assertIn(mine, hooks["SessionStart"])

    def test_upgrade_from_head_style_settings_keeps_user_groups(self):
        # Propel's current hooks.json, as shipped by this repo.
        self.propel.write("hooks/hooks.json", (ROOT / "hooks" / "hooks.json").read_text())
        self.propel.commit("current hooks.json")
        old_propel = [
            ("SessionStart", self.group("bash .claude/hooks/session-start.sh")),
            ("PreCompact", self.group("bash .claude/hooks/session-start.sh")),
            ("SessionStart", self.group("bash .claude/hooks/working-memory.sh")),
            ("PreCompact", self.group("bash .claude/hooks/working-memory.sh")),
            ("UserPromptSubmit", self.group("bash .claude/hooks/route.sh")),
            ("PostToolUse", self.group("bash .claude/hooks/auditor-dispatch.sh",
                                       "Edit|Write|MultiEdit|NotebookEdit")),
        ]
        user = [
            ("Stop", self.group("bash .claude/scripts/codex-consult.sh --label x")),
            ("Stop", self.group("bash .claude/hooks/route.sh --verbose")),
            ("SessionStart", self.group("bash .claude/hooks/session-start.sh", "compact")),
            ("PostToolUse", self.group("bash .claude/hooks/my-lint.sh fast", "Edit|Write")),
            ("PreCompact", self.group("echo my precompact")),
        ]
        hooks: dict = {}
        for event, g in old_propel + user:
            hooks.setdefault(event, []).append(g)
        path = self.write_settings({"permissions": {"allow": ["Bash(ls:*)"]}, "hooks": hooks})

        result = self.invoke_init()
        self.assertEqual(result.exit_code, 0, result.output)
        after = json.loads(path.read_text())
        self.assertEqual(after["permissions"], {"allow": ["Bash(ls:*)"]})
        current = install.parse_hook_registrations((ROOT / "hooks" / "hooks.json").read_text())
        user_keys = {(e, g["matcher"], g["hooks"][0]["command"]) for e, g in user}
        got = set()
        for event, groups in after["hooks"].items():
            for g in groups:
                self.assertEqual(len(g["hooks"]), 1)
                got.add((event, g.get("matcher") or "", g["hooks"][0]["command"]))
        self.assertEqual(got, current | user_keys)
        for event, g in user:
            self.assertIn(g, after["hooks"][event])
        # Exactly the old registrations not in the current hooks.json were removed.
        removed = sorted(line.strip() for line in result.output.splitlines()
                         if "removed stale Propel hook group" in line)
        self.assertEqual(removed, sorted([
            "removed stale Propel hook group PreCompact: bash .claude/hooks/session-start.sh",
            "removed stale Propel hook group PreCompact: bash .claude/hooks/working-memory.sh",
            "removed stale Propel hook group SessionStart: bash .claude/hooks/session-start.sh",
        ]))

        first = path.read_bytes()
        result = self.invoke_init()
        self.assertEqual(result.exit_code, 0, result.output)
        self.assertEqual(path.read_bytes(), first)
        self.assertIn("settings.local.json — hooks already configured", result.output)

    def test_two_runs_each_removing_a_group_keep_both_backups(self):
        path = self.write_settings({"hooks": {
            "PreCompact": [self.group("bash .claude/hooks/session-start.sh")],
        }})
        self.assertEqual(self.invoke_init().exit_code, 0)
        hooks = json.loads(path.read_text())
        hooks["hooks"]["Stop"] = [self.group("bash .claude/hooks/route.sh")]
        path.write_text(json.dumps(hooks))
        # Record the Stop group as Propel's, so the next run removes it as stale.
        manifest_path = self.project / ".propel" / "manifest.json"
        manifest = json.loads(manifest_path.read_text())
        manifest["hooks"].append({"event": "Stop", **self.group("bash .claude/hooks/route.sh")})
        manifest_path.write_text(json.dumps(manifest))
        result = self.invoke_init()
        self.assertEqual(result.exit_code, 0, result.output)
        self.assertNotIn("Stop", json.loads(path.read_text())["hooks"])
        backups = sorted((self.project / ".propel" / "backup").glob("*/settings.local.json"))
        self.assertEqual(len(backups), 2)
        self.assertIn("PreCompact", backups[0].read_text())
        self.assertIn("Stop", backups[1].read_text())

    def test_dry_run_with_invalid_settings_reports_abort_and_writes_nothing(self):
        self.claude.mkdir()
        (self.claude / "settings.local.json").write_text("{not json")
        before = self.snapshot()
        with mock.patch.object(cli_mod, "get_propel_root", return_value=self.propel.root), \
                mock.patch.object(cli_mod, "get_project_root", return_value=self.project), \
                mock.patch.object(cli_mod, "GLOBAL_DIR", self.project / "no-global-dir"):
            result = CliRunner().invoke(cli_mod.cli, ["init", "--dry-run"])
        self.assertNotEqual(result.exit_code, 0)
        self.assertIn("Dry run: init would abort", result.output)
        self.assertIn("settings.local.json", result.output)
        self.assertEqual(self.snapshot(), before)
        self.assertFalse((self.project / ".propel").exists())

    def test_dry_run_lists_hook_groups_that_would_be_removed(self):
        self.write_settings({"hooks": {
            "PreCompact": [self.group("bash .claude/hooks/session-start.sh")],
        }})
        before = self.snapshot()
        result = self.invoke_init("--dry-run")
        self.assertEqual(result.exit_code, 0, result.output)
        self.assertIn("would remove 1 stale Propel hook group(s)", result.output)
        self.assertIn("PreCompact: bash .claude/hooks/session-start.sh", result.output)
        self.assertEqual(self.snapshot(), before)

    def test_status_hook_drift_cleared_by_init(self):
        self.assertEqual(self.invoke_init().exit_code, 0)
        settings_path = self.claude / "settings.local.json"
        settings = json.loads(settings_path.read_text())
        del settings["hooks"]["PostToolUse"]
        settings_path.write_text(json.dumps(settings))
        s = install.status(self.propel.root, self.project)
        self.assertEqual((s["changes"], s["hooks_pending"]), (0, 1))
        self.assertIs(s["update_available"], True)
        self.assertEqual(self.invoke_init().exit_code, 0)
        s = install.status(self.propel.root, self.project)
        self.assertEqual(s["hooks_pending"], 0)
        self.assertIs(s["update_available"], False)

    def test_dry_run_lists_hook_groups_that_would_be_added(self):
        self.assertEqual(self.invoke_init().exit_code, 0)
        settings_path = self.claude / "settings.local.json"
        settings = json.loads(settings_path.read_text())
        del settings["hooks"]["PostToolUse"]
        settings_path.write_text(json.dumps(settings))
        before = self.snapshot()
        result = self.invoke_init("--dry-run")
        self.assertEqual(result.exit_code, 0, result.output)
        self.assertIn("would add 1 Propel hook group(s)", result.output)
        self.assertIn("PostToolUse [Edit|Write]: bash .claude/hooks/auditor-dispatch.sh", result.output)
        self.assertNotIn("would remove", result.output)
        self.assertEqual(self.snapshot(), before)

    def test_second_init_leaves_manifest_byte_identical(self):
        self.assertEqual(self.invoke_init().exit_code, 0)
        manifest_path = self.project / ".propel" / "manifest.json"
        first = manifest_path.read_bytes()
        stamp = json.loads(first)["installed_at"]
        with mock.patch.object(install, "datetime") as fake_dt:
            fake_dt.now.return_value.isoformat.return_value = "2099-01-01T00:00:00"
            fake_dt.now.return_value.strftime.return_value = "20990101-000000"
            self.assertEqual(self.invoke_init().exit_code, 0)
        self.assertEqual(manifest_path.read_bytes(), first)
        self.assertEqual(json.loads(manifest_path.read_text())["installed_at"], stamp)
        # A real change still rewrites it.
        self.propel.write("agents/code-reviewer.md", "reviewer v2\n")
        self.propel.commit("v2")
        self.assertEqual(self.invoke_init().exit_code, 0)
        self.assertNotEqual(manifest_path.read_bytes(), first)

    def test_hook_pointing_at_user_file_is_warned(self):
        self.assertEqual(self.invoke_init().exit_code, 0)
        # A new Propel hook, registered in hooks.json, at a path where the user
        # already has a file of their own.
        (self.claude / "hooks/new-hook.sh").write_text("#!/bin/bash\necho mine\n")
        self.propel.write("hooks/new-hook.sh", "#!/bin/bash\necho propel\n")
        hooks = json.loads(json.dumps(HOOKS_JSON))
        hooks["hooks"].append({"event": "Stop", "command": "bash hooks/new-hook.sh --flag"})
        self.propel.write("hooks/hooks.json", json.dumps(hooks, indent=2) + "\n")
        self.propel.commit("new hook")
        for args in (("--dry-run",), ()):
            result = self.invoke_init(*args)
            self.assertEqual(result.exit_code, 0, result.output)
            self.assertIn(
                "WARNING: hook Stop: bash .claude/hooks/new-hook.sh --flag — "
                "the registration runs YOUR file .claude/hooks/new-hook.sh, not Propel's",
                result.output,
            )
        # Still registered, and the user's file is untouched.
        settings = json.loads((self.claude / "settings.local.json").read_text())
        self.assertEqual(settings["hooks"]["Stop"][0]["hooks"][0]["command"], "bash .claude/hooks/new-hook.sh --flag")
        self.assertEqual((self.claude / "hooks/new-hook.sh").read_text(), "#!/bin/bash\necho mine\n")

    def test_no_hook_warning_for_unregistered_user_file(self):
        self.assertEqual(self.invoke_init().exit_code, 0)
        (self.claude / "scripts/helper.sh").write_text("mine\n")
        self.propel.write("scripts/helper.sh", "propel\n")
        self.propel.commit("helper")
        result = self.invoke_init()
        self.assertEqual(result.exit_code, 0, result.output)
        self.assertIn(".claude/scripts/helper.sh", result.output)
        self.assertNotIn("the registration runs YOUR file", result.output)

    def test_hooks_json_absent_still_removes_recorded_groups(self):
        self.assertEqual(self.invoke_init().exit_code, 0)
        self.propel.delete("hooks/hooks.json")
        self.propel.commit("drop hooks.json")
        result = self.invoke_init()
        self.assertEqual(result.exit_code, 0, result.output)
        settings = json.loads((self.claude / "settings.local.json").read_text())
        self.assertEqual(settings["hooks"], {})
        self.assertEqual(install.load_manifest(self.project)["hooks"], [])

    def test_conflict_warning_names_file_and_propel_copy(self):
        self.assertEqual(self.invoke_init().exit_code, 0)
        (self.claude / "agents/new-agent.md").write_text("my agent\n")
        self.propel.write("agents/new-agent.md", "propel agent\n")
        self.propel.commit("new agent")
        result = self.invoke_init()
        self.assertEqual(result.exit_code, 0, result.output)
        self.assertIn("WARNING", result.output)
        self.assertIn(".claude/agents/new-agent.md", result.output)
        self.assertIn(f"Propel's copy is at {self.propel.root / 'agents/new-agent.md'}", result.output)
        self.assertEqual((self.claude / "agents/new-agent.md").read_text(), "my agent\n")

    def test_init_aborts_on_bad_settings_before_touching_files(self):
        self.claude.mkdir()
        settings = self.claude / "settings.local.json"
        settings.write_text("{not json")
        with mock.patch.object(cli_mod, "get_propel_root", return_value=self.propel.root), \
                mock.patch.object(cli_mod, "get_project_root", return_value=self.project), \
                mock.patch.object(cli_mod, "GLOBAL_DIR", self.project / "no-global-dir"):
            result = CliRunner().invoke(cli_mod.cli, ["init"])
        self.assertNotEqual(result.exit_code, 0)
        self.assertIn("settings.local.json", result.output)
        self.assertEqual(settings.read_text(), "{not json")
        self.assertFalse((self.claude / "skills").exists())
        self.assertFalse((self.project / ".propel" / "manifest.json").exists())

    def test_init_shallow_legacy_output_never_says_edited(self):
        shallow = self.propel.root.parent / "shallow"
        subprocess.run(
            ["git", *GIT_CONFIG, "clone", "-q", "--depth", "1",
             self.propel.root.as_uri(), str(shallow)],
            capture_output=True, text=True, check=True,
        )
        (self.claude / "core").mkdir(parents=True)
        (self.claude / "core/CORE.md").write_text("something else\n")
        (self.claude / "skills/c-codex").mkdir(parents=True)
        (self.claude / "skills/c-codex/SKILL.md").write_text("old\n")
        self.propel.root = shallow
        result = self.invoke_init()
        self.assertEqual(result.exit_code, 0, result.output)
        self.assertNotIn("edited", result.output)
        self.assertIn(install.LABEL_NO_HISTORY, result.output)
        self.assertIn(".claude/skills/c-codex/SKILL.md  — " + install.LABEL_NO_HISTORY, result.output)

    def test_dangling_claude_md_symlink_is_not_written_through(self):
        self.claude.mkdir()
        target = self.project / "elsewhere" / "CLAUDE.md"
        (self.claude / "CLAUDE.md").symlink_to(target)
        (self.propel.root / "templates").mkdir()
        (self.propel.root / "templates/CLAUDE.md").write_text("template\n")
        result = self.invoke_init()
        self.assertEqual(result.exit_code, 0, result.output)
        self.assertIn("CLAUDE.md — is a symlink, left alone", result.output)
        self.assertFalse(target.exists())
        self.assertFalse(target.parent.exists())
        self.assertTrue((self.claude / "CLAUDE.md").is_symlink())

    def test_corrupt_manifest_aborts_init_and_dry_run(self):
        path = self.project / ".propel" / "manifest.json"
        path.parent.mkdir()
        path.write_text("{oops")
        for args in ((), ("--dry-run",)):
            with mock.patch.object(cli_mod, "get_propel_root", return_value=self.propel.root), \
                    mock.patch.object(cli_mod, "get_project_root", return_value=self.project), \
                    mock.patch.object(cli_mod, "GLOBAL_DIR", self.project / "no-global-dir"):
                result = CliRunner().invoke(cli_mod.cli, ["init", *args])
            self.assertEqual(result.exit_code, 1, result.output)
            self.assertIn("manifest.json", result.output)
            self.assertIn("delete", result.output)
            if args:
                self.assertIn("Dry run: init would abort", result.output)
            self.assertFalse(self.claude.exists())
            self.assertEqual(path.read_text(), "{oops")

    def test_settings_write_failure_leaves_manifest_unchanged(self):
        self.assertEqual(self.invoke_init().exit_code, 0)
        manifest_path = self.project / ".propel" / "manifest.json"
        before = manifest_path.read_text()
        self.propel.write("core/NEW.md", "new\n")
        self.propel.commit("new")
        (self.claude / "settings.local.json").write_text("{}")
        with mock.patch.object(cli_mod, "write_settings", side_effect=OSError("disk full")):
            with self.assertRaises(OSError):
                self.invoke_init()
        self.assertEqual(manifest_path.read_text(), before)
        result = self.invoke_init()
        self.assertEqual(result.exit_code, 0, result.output)
        self.assertIn("core/NEW.md", install.load_manifest(self.project)["files"])

    def test_empty_settings_file_is_treated_as_empty_object(self):
        for text in ("", "  \n\t"):
            self.claude.mkdir(exist_ok=True)
            (self.claude / "settings.local.json").write_text(text)
            result = self.invoke_init()
            self.assertEqual(result.exit_code, 0, result.output)
            settings = json.loads((self.claude / "settings.local.json").read_text())
            self.assertIn("SessionStart", settings["hooks"])

    def test_done_line_reports_owned_files(self):
        self.assertEqual(self.invoke_init().exit_code, 0)
        (self.claude / "agents/new-agent.md").write_text("my agent\n")
        self.propel.write("agents/new-agent.md", "propel agent\n")
        self.propel.commit("new agent")
        result = self.invoke_init()
        self.assertEqual(result.exit_code, 0, result.output)
        self.assertIn(f"Done! Propel owns {len(INITIAL_FILES)} files in", result.output)


class SettingsMergeTests(unittest.TestCase):
    # Exact registrations Propel has made: the fixture's hooks.json, plus the
    # retired ones (what init passes in: history | RETIRED_HOOK_REGISTRATIONS).
    PROPEL_REGISTRATIONS = {
        ("SessionStart", "", "bash .claude/hooks/session-start.sh"),
        ("PostToolUse", "Edit|Write", "bash .claude/hooks/auditor-dispatch.sh"),
        ("UserPromptSubmit", "", "bash .claude/hooks/route.sh"),
    } | install.RETIRED_HOOK_REGISTRATIONS

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.project = Path(self._tmp.name)
        (self.project / ".claude").mkdir()
        self.path = self.project / ".claude" / "settings.local.json"
        self.hooks_config = [
            {"event": "SessionStart", "command": "bash .claude/hooks/session-start.sh"},
            {"event": "PostToolUse", "matcher": "Edit|Write",
             "command": "bash .claude/hooks/auditor-dispatch.sh"},
        ]

    def tearDown(self):
        self._tmp.cleanup()

    def group(self, command, matcher=""):
        return {"matcher": matcher, "hooks": [{"type": "command", "command": command}]}

    def merge(self, previous=None, hooks_config=None):
        return cli_mod.merge_hooks_config(
            self.path, self.hooks_config if hooks_config is None else hooks_config,
            previous, self.PROPEL_REGISTRATIONS,
        )

    def backups(self) -> list[Path]:
        return sorted((self.project / ".propel" / "backup").glob("*/settings.local.json"))

    def test_non_list_event_aborts_unchanged(self):
        # Otherwise Propel's SessionStart hooks would silently never register
        # while status reports "up to date".
        self.path.write_text('{"hooks": {"SessionStart": {}}}')
        with self.assertRaises(click.ClickException) as ctx:
            self.merge()
        self.assertIn('"hooks.SessionStart"', ctx.exception.message)
        self.assertEqual(self.path.read_text(), '{"hooks": {"SessionStart": {}}}')

    def test_non_utf8_settings_is_a_clean_error(self):
        self.path.write_bytes(b'{"permissions": "\xff\xfe"}')
        with self.assertRaises(click.ClickException) as ctx:
            self.merge()
        self.assertIn("not valid UTF-8", ctx.exception.message)

    def test_bad_json_aborts_unchanged(self):
        self.path.write_text('{"permissions": {"allow": [}')
        with self.assertRaises(click.ClickException) as ctx:
            self.merge()
        self.assertIn(str(self.path), ctx.exception.message)
        self.assertEqual(self.path.read_text(), '{"permissions": {"allow": [}')
        self.assertEqual(self.backups(), [])

    def test_unknown_event_user_hook_survives(self):
        user_group = self.group("echo mine")
        self.path.write_text(json.dumps({"hooks": {"FutureEvent": [user_group]}}))
        self.merge()
        settings = json.loads(self.path.read_text())
        self.assertEqual(settings["hooks"]["FutureEvent"], [user_group])

    def test_stale_precompact_propel_groups_removed_legacy(self):
        user_pre = self.group("echo my precompact")
        self.path.write_text(json.dumps({
            "permissions": {"allow": ["Bash(ls:*)"]},
            "hooks": {
                "SessionStart": [self.group("bash .claude/hooks/session-start.sh")],
                "PreCompact": [
                    self.group("bash .claude/hooks/session-start.sh"),
                    self.group("bash .claude/hooks/working-memory.sh"),
                    user_pre,
                ],
            },
        }))
        original = self.path.read_text()
        self.merge()
        settings = json.loads(self.path.read_text())
        self.assertEqual(settings["hooks"]["PreCompact"], [user_pre])
        self.assertEqual(settings["hooks"]["SessionStart"],
                         [self.group("bash .claude/hooks/session-start.sh")])
        self.assertEqual([b.read_text() for b in self.backups()], [original])
        self.assertFalse(self.path.with_name(self.path.name + ".propel-bak").exists())

    def test_user_hook_under_claude_hooks_survives_legacy(self):
        mine = self.group("bash .claude/hooks/my-lint.sh", "Edit|Write")
        self.path.write_text(json.dumps({"hooks": {
            "PostToolUse": [mine],
            "Stop": [{"command": "bash .claude/hooks/my-lint.sh"}],
        }}))
        self.merge(None)
        settings = json.loads(self.path.read_text())
        self.assertIn(mine, settings["hooks"]["PostToolUse"])
        self.assertEqual(settings["hooks"]["Stop"], [{"command": "bash .claude/hooks/my-lint.sh"}])

    def test_legacy_merge_keeps_user_registrations_of_propel_scripts(self):
        # Ownership is the exact (event, matcher, command) Propel registered.
        # A user's own registration of a Propel script — other arguments,
        # another event, another matcher — is never removed.
        user = {
            "Stop": [
                self.group("bash .claude/scripts/codex-consult.sh --label x"),
                self.group("bash .claude/hooks/route.sh --verbose"),
            ],
            "SessionStart": [
                self.group("bash .claude/hooks/session-start.sh", "compact"),
                self.group("bash .claude/hooks/my-lint.sh fast"),
            ],
        }
        self.path.write_text(json.dumps({"hooks": user}))
        self.merge(None)
        settings = json.loads(self.path.read_text())
        self.assertEqual(settings["hooks"]["Stop"], user["Stop"])
        for g in user["SessionStart"]:
            self.assertIn(g, settings["hooks"]["SessionStart"])

    def test_legacy_merge_removes_retired_registrations(self):
        # Neither is in the desired list; both are exact retired registrations.
        mine = self.group("bash .claude/hooks/my-lint.sh fast")
        self.path.write_text(json.dumps({"hooks": {
            "SessionStart": [self.group("bash .claude/hooks/session-start.sh"), mine],
            "PreCompact": [self.group("bash .claude/hooks/session-start.sh")],
        }}))
        self.merge(None, hooks_config=[
            {"event": "SessionStart", "command": "bash .claude/hooks/session-start.sh core"},
        ])
        settings = json.loads(self.path.read_text())
        self.assertEqual(settings["hooks"]["SessionStart"],
                         [mine, self.group("bash .claude/hooks/session-start.sh core")])
        self.assertNotIn("PreCompact", settings["hooks"])

    def test_legacy_matcherless_auditor_dispatch_is_replaced(self):
        # Installs from the window when init dropped matchers carry an
        # auditor-dispatch group with matcher "" (fires after every tool call).
        old = self.group("bash .claude/hooks/auditor-dispatch.sh", "")
        self.path.write_text(json.dumps({"hooks": {"PostToolUse": [old]}}))
        self.merge(None)
        groups = json.loads(self.path.read_text())["hooks"]["PostToolUse"]
        self.assertEqual(groups, [self.group("bash .claude/hooks/auditor-dispatch.sh", "Edit|Write")])

    def test_mixed_group_with_stale_propel_and_user_command_is_kept(self):
        mixed = {"matcher": "", "hooks": [
            {"type": "command", "command": "bash .claude/hooks/session-start.sh"},
            {"type": "command", "command": "echo mine"},
        ]}
        self.path.write_text(json.dumps({"hooks": {"PreCompact": [mixed]}}))
        self.merge(None)
        self.assertEqual(json.loads(self.path.read_text())["hooks"]["PreCompact"], [mixed])

    def test_stale_groups_removed_by_manifest_record(self):
        stale = {"event": "PreCompact", **self.group("bash .claude/hooks/session-start.sh")}
        self.path.write_text(json.dumps({"hooks": {
            "PreCompact": [self.group("bash .claude/hooks/session-start.sh")],
        }}))
        self.merge([stale])
        settings = json.loads(self.path.read_text())
        self.assertNotIn("PreCompact", settings["hooks"])

    def test_recorded_group_with_extra_timeout_field_is_still_recognized(self):
        stale = {"event": "PreCompact", **self.group("bash .claude/hooks/session-start.sh")}
        on_disk = {"matcher": "", "hooks": [
            {"type": "command", "command": "bash .claude/hooks/session-start.sh", "timeout": 30},
        ]}
        self.path.write_text(json.dumps({"hooks": {"PreCompact": [on_disk]}}))
        self.merge([stale])
        settings = json.loads(self.path.read_text())
        self.assertNotIn("PreCompact", settings["hooks"])

    def test_with_manifest_unrecorded_user_group_is_kept(self):
        # previous_hooks == [] falls back to the exact-registration rule,
        # which does not claim a registration Propel never made.
        group = self.group("bash .claude/hooks/my-hook.sh")
        self.path.write_text(json.dumps({"hooks": {"Stop": [group]}}))
        self.merge([])
        settings = json.loads(self.path.read_text())
        self.assertEqual(settings["hooks"]["Stop"], [group])

    def test_with_manifest_recording_nothing_legacy_rule_applies(self):
        self.path.write_text(json.dumps({"hooks": {
            "PreCompact": [self.group("bash .claude/hooks/working-memory.sh")],
        }}))
        self.merge([])
        self.assertNotIn("PreCompact", json.loads(self.path.read_text())["hooks"])

    def test_empty_desired_list_removes_stale_recorded_groups(self):
        recorded = {"event": "SessionStart", **self.group("bash .claude/hooks/session-start.sh")}
        self.path.write_text(json.dumps({"hooks": {
            "SessionStart": [self.group("bash .claude/hooks/session-start.sh")],
        }}))
        registered = self.merge([recorded], hooks_config=[])
        self.assertEqual(registered, [])
        self.assertEqual(json.loads(self.path.read_text())["hooks"], {})

    def test_user_permissions_and_other_keys_preserved(self):
        original = {
            "permissions": {"allow": ["Bash(git:*)"], "deny": ["Read(.env)"]},
            "statusLine": {"type": "command", "command": "x"},
            "hooks": {"Stop": [self.group("echo user stop")]},
        }
        self.path.write_text(json.dumps(original))
        registered = self.merge()
        settings = json.loads(self.path.read_text())
        self.assertEqual(settings["permissions"], original["permissions"])
        self.assertEqual(settings["statusLine"], original["statusLine"])
        self.assertEqual(settings["hooks"]["Stop"], original["hooks"]["Stop"])
        self.assertEqual(settings["hooks"]["PostToolUse"],
                         [self.group("bash .claude/hooks/auditor-dispatch.sh", "Edit|Write")])
        self.assertEqual(len(registered), 2)
        self.assertFalse(self.path.with_name(self.path.name + ".propel-bak").exists())

    def test_flat_entries_removed_only_when_propel_owned(self):
        user_flat = {"command": "echo user flat"}
        self.path.write_text(json.dumps({"hooks": {"SessionStart": [
            {"command": "bash .claude/hooks/session-start.sh"},
            user_flat,
        ]}}))
        # Regardless of manifest presence.
        self.merge([{"event": "X", **self.group("bash .claude/hooks/other.sh")}])
        entries = json.loads(self.path.read_text())["hooks"]["SessionStart"]
        self.assertIn(user_flat, entries)
        self.assertNotIn({"command": "bash .claude/hooks/session-start.sh"}, entries)

    def test_merge_is_idempotent(self):
        self.merge()
        first = self.path.read_text()
        self.merge()
        self.assertEqual(self.path.read_text(), first)
        self.assertEqual(self.backups(), [])

    def test_settings_written_atomically_leave_no_temp_files(self):
        self.merge()
        leftovers = [p.name for p in self.path.parent.iterdir() if p.name != self.path.name]
        self.assertEqual(leftovers, [])

if __name__ == "__main__":
    unittest.main()
