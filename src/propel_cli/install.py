"""Install planner for `propel init` — decides, per file, what Propel may touch.

Ownership rules (Gate 2 and Gate 3, 2026-11-16):

- A path that exists upstream now is Propel's. It is added if missing, and
  replaced if it differs — backed up first, and named in the output when the
  installed copy had been edited since Propel wrote it.
- With a manifest, the removal candidates are the paths the manifest recorded,
  and nothing else: a user's own file at a retired path is the user's. Without
  one (a legacy install) they are every path in the clone's main-line git
  history plus RETIRED_PATHS. A candidate that is gone upstream is a stale
  Propel file: removed, backed up first.
- Collision: with a manifest, a differing file at an upstream path that the
  manifest never recorded is the user's. It is kept, Propel's copy is skipped,
  and a warning names it. Without a manifest, the file is replaced either way;
  the label says whether it matched a shipped version — or, when the clone has
  no usable history (not its own repo, shallow, or no git), says only that it
  was updated, since "edited" cannot be told apart from "older version".
- Case-insensitive filesystems: an installed file that matches a shipped path
  only case-insensitively is the same file. Identical bytes are left alone;
  differing bytes go through the rules above. Its existing case is kept.
- Anything else under the managed directories is user-authored. It is never
  opened for writing, never chmodded and never deleted. Nothing is ever
  written or removed outside `.claude/`, symlinks included — with one
  exception: a `.claude/settings.local.json` that is a symlink is written
  through to its target (atomically, in the target's directory) and the link
  is kept, because users link it to share a permission allowlist from their
  dotfiles. A broken link is refused, never created (cli.settings_write_target).

Paths are relative to `.claude/` ("skills/x/SKILL.md"), which is also how they
appear relative to the propel clone root, so one key works for upstream files,
installed files, the manifest and git history alike.

Stdlib only.
"""

import hashlib
import json
import os
import shutil
import subprocess
import tempfile
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path

from . import __version__

MANAGED_DIRS = ("skills", "agents", "commands", "hooks", "core", "scripts")
MANIFEST_SCHEMA = 1
SKIP_NAMES = {"__pycache__", ".DS_Store"}

# Paths Propel shipped once and no longer ships. History-based detection only
# works in a full git clone; this list is what lets a zip download, a shallow
# clone or a vendored copy still clean these files out of an old install.
# Every future deletion or rename of a shipped path must be added here — a
# unit test (tests/test_install.py) fails when main-line history has a deleted
# path that is missing from this set.
RETIRED_PATHS = frozenset({
    "commands/propel.md",
    "commands/propel/debug-training.md",
    "commands/propel/intro.md",
    "commands/propel/new-session.md",
    "commands/propel/primer.md",
    "commands/propel/read-paper.md",
    "commands/propel/trace-shapes.md",
    "skills/c-codex/SKILL.md",
    "skills/codex-lead/SKILL.md",
})

# Hook registrations Propel shipped once and no longer ships, as (event,
# matcher, command) after init's `bash hooks/` -> `bash .claude/hooks/` rewrite.
# Same role as RETIRED_PATHS: history-based detection (historical_hook_registrations)
# only works in a full git clone; this set lets a zip download, a shallow clone
# or a vendored copy still remove these exact registrations from an old,
# manifest-less install. Every registration dropped from hooks/hooks.json must be
# added here — a unit test fails when main-line history has one that is missing.
RETIRED_HOOK_REGISTRATIONS = frozenset({
    ("PostClear", "", "bash .claude/hooks/session-start.sh"),
    ("PostCompact", "", "bash .claude/hooks/session-start.sh"),
    ("PreCompact", "", "bash .claude/hooks/session-start.sh"),
    ("PreCompact", "", "bash .claude/hooks/working-memory.sh"),
    ("SessionResume", "", "bash .claude/hooks/session-start.sh"),
    ("SessionStart", "", "bash .claude/hooks/session-start.sh"),
    # Never in any hooks.json: init at c597211..027964f ignored the matcher and
    # wrote "" for every hook, so installs from that window carry a matcher-less
    # auditor-dispatch registration that fires after every tool call.
    ("PostToolUse", "", "bash .claude/hooks/auditor-dispatch.sh"),
})

# Actions that change something on disk. keep_user / conflict_user never do.
CHANGE_KINDS = ("add", "replace", "replace_edited", "remove", "remove_edited")
KEEP_KINDS = ("keep_user", "conflict_user")
BACKUP_KINDS = ("replace", "replace_edited", "remove", "remove_edited")
WRITE_KINDS = ("add", "replace", "replace_edited")
REMOVE_KINDS = ("remove", "remove_edited")

LABEL_OLDER_VERSION = "updated (older Propel version)"
LABEL_NO_SHIPPED_MATCH = "differs from every shipped version — backed up"
LABEL_NO_HISTORY = "updated (no history to compare — backed up)"
REASON_SYMLINK = "outside .claude/ via symlink"
BACKUPS_KEPT = 10


class ManifestError(Exception):
    """.propel/manifest.json exists but cannot be used."""


class SettingsError(Exception):
    """.claude/settings.local.json exists but does not parse into a usable object."""


_CODEX_OFF_STRINGS = frozenset({"false", "0", "off", "no", ""})


def codex_enabled(config: object) -> bool:
    """Whether a parsed .propel/codex.json turns the dual-model layer on.

    The shared rule: OFF when "enabled" is false, null or 0, or a string that,
    trimmed and lowercased, is "false", "0", "off", "no" or "". A missing key
    (or a config that is not a JSON object) means on.
    """
    if not isinstance(config, dict) or "enabled" not in config:
        return True
    value = config["enabled"]
    if value is None or value is False:
        return False
    if isinstance(value, (int, float)) and not isinstance(value, bool) and value == 0:
        return False
    if isinstance(value, str) and value.strip().lower() in _CODEX_OFF_STRINGS:
        return False
    return True


# ---------------------------------------------------------------------------
# Data
# ---------------------------------------------------------------------------


@dataclass
class Action:
    kind: str  # add | replace | replace_edited | remove | remove_edited | keep_user | conflict_user
    path: str  # relative to .claude/, POSIX separators
    source: Path | None = None  # upstream file, for add / replace*
    note: str = ""  # label or reason shown in the output
    on_disk: str | None = None  # installed rel path when it differs in case only (written in place)


@dataclass
class Plan:
    claude_dir: Path
    upstream: dict[str, Path]  # rel path -> upstream file
    actions: list[Action] = field(default_factory=list)
    unchanged: list[str] = field(default_factory=list)  # upstream paths already identical

    def of(self, kind: str) -> list[Action]:
        return [a for a in self.actions if a.kind == kind]

    @property
    def changes(self) -> int:
        return sum(1 for a in self.actions if a.kind in CHANGE_KINDS)

    @property
    def owned(self) -> list[str]:
        """Upstream paths Propel will own after apply (written or already identical)."""
        written = [a.path for a in self.actions if a.kind in WRITE_KINDS]
        return sorted(set(written) | set(self.unchanged))


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _sha256(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 16), b""):
            h.update(chunk)
    return h.hexdigest()


def _git_blob_sha(path: Path) -> str:
    """The id git would give this file's content (sha1 of "blob <len>\\0" + content)."""
    data = path.read_bytes()
    return hashlib.sha1(b"blob %d\0" % len(data) + data).hexdigest()


def _skipped(rel_parts: tuple[str, ...]) -> bool:
    return any(part in SKIP_NAMES for part in rel_parts)


def _files_under(root: Path) -> dict[str, Path]:
    """Map rel path (relative to `root`) -> file, for every file in the managed dirs.

    Symlinked directories are never followed — not even a managed directory
    that is itself a link — so the index cannot reach outside `root`.
    """
    found: dict[str, Path] = {}
    for dirname in MANAGED_DIRS:
        base = root / dirname
        if base.is_symlink() or not base.is_dir():
            continue
        for dirpath, dirnames, filenames in os.walk(base, followlinks=False):
            dirnames[:] = [d for d in dirnames if d not in SKIP_NAMES]
            for name in filenames:
                item = Path(dirpath) / name
                rel = item.relative_to(root)
                if _skipped(rel.parts) or not item.is_file():
                    continue
                found[rel.as_posix()] = item
    return found


def _git(root: Path, *args: str) -> subprocess.CompletedProcess | None:
    try:
        return subprocess.run(
            ["git", "-C", str(root), *args],
            capture_output=True,
            encoding="utf-8",
            errors="surrogateescape",
            env={**os.environ, "GIT_OPTIONAL_LOCKS": "0"},
            check=True,
            timeout=20,
        )
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired, FileNotFoundError, OSError):
        return None


def _is_dedicated_repo(propel_root: Path) -> bool:
    """True only when propel_root is the top level of its own git repository.

    A copy nested inside some other repository (vendored, a monorepo, a zip
    unpacked inside a project) must not read that repository's history.
    """
    top = _git(propel_root, "rev-parse", "--show-toplevel")
    if top is None or not top.stdout.strip():
        return False
    try:
        return Path(top.stdout.strip()).resolve() == propel_root.resolve()
    except OSError:
        return False


def history_available(propel_root: Path) -> bool:
    """True when propel_root's main-line history can tell an edit from an old version.

    False if git is missing, propel_root is not its own repository, or the
    clone is shallow (its history is cut off, so old shipped blobs are missing).
    """
    if not _is_dedicated_repo(propel_root):
        return False
    shallow = _git(propel_root, "rev-parse", "--is-shallow-repository")
    return shallow is not None and shallow.stdout.strip() == "false"


def _is_case_insensitive(claude_dir: Path) -> bool:
    """Whether the filesystem holding claude_dir folds case (macOS default)."""
    if not claude_dir.exists():
        return False
    swapped = claude_dir.parent / claude_dir.name.swapcase()
    if swapped.name == claude_dir.name or not swapped.exists():
        return False
    try:
        return os.path.samefile(claude_dir, swapped)
    except OSError:
        return False


def _inside(root: Path, path: Path) -> bool:
    try:
        path.relative_to(root)
        return True
    except ValueError:
        return False


def _escapes(claude_root: Path, dest: Path) -> bool:
    """True when writing or unlinking `dest` would act outside .claude/."""
    if not _inside(claude_root, dest.parent.resolve()):
        return True
    if dest.is_symlink() and not _inside(claude_root, dest.resolve()):
        return True
    return False


def reserve_backup_dir(project_root: Path) -> Path:
    """Create and return a fresh .propel/backup/<timestamp>[-N]/ directory.

    mkdir(exist_ok=False) is the reservation, so two runs in the same second
    can never share (and overwrite) one directory.
    """
    base = project_root / ".propel" / "backup"
    base.mkdir(parents=True, exist_ok=True)
    stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    n = 0
    while True:
        candidate = base / (stamp if n == 0 else f"{stamp}-{n}")
        try:
            candidate.mkdir(exist_ok=False)
            return candidate
        except FileExistsError:
            n += 1


def prune_backups(project_root: Path, keep: int = BACKUPS_KEPT, protect=()) -> list[Path]:
    """Delete all but the newest `keep` directories under .propel/backup/.

    Names are timestamps, so name order is age order. Directories in `protect`
    (the one this run just created) are never deleted. Symlinks and plain files
    are ignored. Best-effort: a directory that cannot be removed is left.
    Returns the directories removed.
    """
    base = project_root / ".propel" / "backup"
    if base.is_symlink() or not base.is_dir():
        return []
    protected = {Path(p).resolve() for p in protect if p is not None}
    dirs = sorted(
        (d for d in base.iterdir() if d.is_dir() and not d.is_symlink()),
        key=lambda d: d.name,
    )
    removed = []
    for old in dirs[: max(len(dirs) - keep, 0)]:
        if old.resolve() in protected:
            continue
        try:
            shutil.rmtree(old)
            removed.append(old)
        except OSError:
            pass
    return removed


def _atomic_copy(src: Path, target: Path) -> None:
    """Copy src over target via a temp file in target's directory and os.replace.

    Mode and timestamps come from src (as shutil.copy2 would). A failure part
    way leaves the old target intact, never a missing or truncated file.
    """
    fd, tmp = tempfile.mkstemp(dir=target.parent, prefix=f".{target.name}.", suffix=".tmp")
    os.close(fd)
    try:
        shutil.copyfile(src, tmp)
        shutil.copystat(src, tmp)
        os.replace(tmp, target)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def atomic_write_text(path: Path, text: str) -> None:
    """Write via a temp file in the same directory and os.replace it into place."""
    path.parent.mkdir(parents=True, exist_ok=True)
    try:
        mode = path.stat().st_mode & 0o777
    except OSError:
        umask = os.umask(0)
        os.umask(umask)
        mode = 0o666 & ~umask
    fd, tmp = tempfile.mkstemp(dir=path.parent, prefix=f".{path.name}.", suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(text)
            f.flush()
            os.fsync(f.fileno())
        os.chmod(tmp, mode)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


# ---------------------------------------------------------------------------
# Inputs
# ---------------------------------------------------------------------------


def load_manifest(project_root: Path) -> dict | None:
    """Read .propel/manifest.json. None only if there is no such file.

    A manifest that exists but cannot be read, does not parse, is not a JSON
    object, or whose "files" is not an object of strings raises ManifestError:
    silently treating it as missing would re-adopt the install in legacy mode
    (or claim the user's files), so the user decides instead.
    """
    path = project_root / ".propel" / "manifest.json"
    if not path.exists() and not path.is_symlink():
        return None
    fix = f"Fix or delete {path} and re-run (deleting it re-adopts the install in legacy mode)."
    try:
        data = json.loads(path.read_text())
    except (json.JSONDecodeError, ValueError, OSError) as exc:
        raise ManifestError(f"Could not read {path}: {exc}. {fix}") from exc
    if not isinstance(data, dict):
        raise ManifestError(f"{path} is not a JSON object. {fix}")
    files = data.get("files", {})
    if not isinstance(files, dict) or not all(
        isinstance(k, str) and isinstance(v, str) for k, v in files.items()
    ):
        raise ManifestError(f'"files" in {path} is not an object of path -> hash. {fix}')
    return data


def write_manifest(project_root: Path, manifest: dict) -> Path:
    """Write .propel/manifest.json atomically. Returns its path.

    Callers write it last — after settings — so a failure earlier in the run
    leaves the previous manifest in place.
    """
    path = project_root / ".propel" / "manifest.json"
    atomic_write_text(path, json.dumps(manifest, indent=2) + "\n")
    return path


def historical_blobs(propel_root: Path) -> dict[str, set[str]]:
    """{path: every blob id it ever had} under the managed dirs, from HEAD's history.

    Main line only (`HEAD`, not `--all`), and only when propel_root is its own
    repository. `--no-renames` so a renamed file contributes its old path too.
    Empty dict if git, the repository or the history is missing.
    """
    if not _is_dedicated_repo(propel_root):
        return {}
    result = _git(
        propel_root,
        "log", "HEAD", "--no-renames", "--raw", "--no-abbrev",
        "--pretty=format:", "-z", "--", *MANAGED_DIRS,
    )
    if result is None:
        return {}
    blobs: dict[str, set[str]] = {}
    tokens = result.stdout.split("\0")
    i = 0
    while i < len(tokens):
        token = tokens[i].lstrip("\n")
        if not token.startswith(":") or i + 1 >= len(tokens):
            i += 1
            continue
        fields = token[1:].split()
        path = tokens[i + 1]
        i += 2
        if len(fields) < 5 or path.split("/", 1)[0] not in MANAGED_DIRS:
            continue
        ids = blobs.setdefault(path, set())
        for sha in (fields[2], fields[3]):
            if sha.strip("0"):
                ids.add(sha)
    return blobs


def historical_paths(propel_root: Path) -> set[str]:
    """Every path ever committed under the managed dirs on HEAD's main line.

    Empty set unless propel_root is its own git repository (see historical_blobs).
    """
    return set(historical_blobs(propel_root))


def rewrite_hook_command(command: str) -> str:
    """The rewrite init applies to hooks.json commands: repo-relative -> .claude/."""
    return command.replace("bash hooks/", "bash .claude/hooks/").replace(
        "bash scripts/", "bash .claude/scripts/"
    )


def parse_hook_registrations(text: str) -> set[tuple[str, str, str]]:
    """(event, matcher or "", rewritten command) for every entry in a hooks.json text.

    Empty set if the text does not parse or has no usable entries; malformed
    entries are skipped.
    """
    try:
        data = json.loads(text)
    except (json.JSONDecodeError, ValueError):
        return set()
    hooks = data.get("hooks") if isinstance(data, dict) else None
    if not isinstance(hooks, list):
        return set()
    found = set()
    for hook in hooks:
        if not isinstance(hook, dict):
            continue
        event, command = hook.get("event"), hook.get("command")
        matcher = hook.get("matcher") or ""
        if isinstance(event, str) and isinstance(command, str) and isinstance(matcher, str):
            found.add((event, matcher, rewrite_hook_command(command)))
    return found


def load_hooks_config(propel_root: Path) -> list[dict]:
    """hooks/hooks.json with commands rewritten to .claude/ paths, or [] if absent.

    Absent still means "merge": an empty desired list against the previous
    registrations removes stale Propel groups and keeps the manifest consistent.
    A file that does not parse raises (json.JSONDecodeError / ValueError).
    """
    hooks_json = propel_root / "hooks" / "hooks.json"
    if not hooks_json.exists():
        return []
    hooks_config = json.loads(hooks_json.read_text()).get("hooks", [])
    for hook in hooks_config:
        hook["command"] = rewrite_hook_command(hook["command"])
    return hooks_config


def read_settings(settings_path: Path) -> tuple[dict, str | None]:
    """Parse .claude/settings.local.json. Returns (settings, original_text or None).

    An empty or whitespace-only file counts as {}. A file that does not parse,
    is not a JSON object, or whose "hooks" is not an object raises
    SettingsError naming the file. OSError from reading it propagates.
    """
    if not settings_path.exists():
        return {}, None
    try:
        original_text = settings_path.read_text(encoding="utf-8")
    except UnicodeDecodeError as exc:
        raise SettingsError(f"{settings_path} is not valid UTF-8: {exc}.") from exc
    if not original_text.strip():
        return {}, original_text
    try:
        settings = json.loads(original_text)
    except (json.JSONDecodeError, ValueError) as exc:
        raise SettingsError(f"Could not parse {settings_path}: {exc}.") from exc
    if not isinstance(settings, dict):
        raise SettingsError(f"{settings_path} is not a JSON object.")
    if not isinstance(settings.get("hooks", {}), dict):
        raise SettingsError(f'"hooks" in {settings_path} is not a JSON object.')
    # A non-list event value would make Propel skip that event silently (its
    # hooks never register, yet status says "up to date"), so refuse it here.
    for event, groups in settings.get("hooks", {}).items():
        if not isinstance(groups, list):
            raise SettingsError(f'"hooks.{event}" in {settings_path} is not a list.')
    return settings, original_text


def missing_hook_registrations(settings: dict, hooks_config: list[dict]) -> list[tuple[str, str, str]]:
    """(event, matcher, command) for every registration in `hooks_config` that
    `settings` lacks, in hooks.json order, deduplicated.

    A registration is present when some matcher group under its event has the
    same matcher and a hook with the same command — the test init uses before
    adding one. An event whose value is not a list is skipped: init cannot add
    to it either. Malformed entries on either side are skipped, never raised on.
    """
    hooks = settings.get("hooks", {}) if isinstance(settings, dict) else {}
    if not isinstance(hooks, dict):
        hooks = {}
    missing: list[tuple[str, str, str]] = []
    seen: set[tuple] = set()
    for hook in hooks_config:
        if not isinstance(hook, dict):
            continue
        event, matcher, command = hook.get("event"), hook.get("matcher", ""), hook.get("command")
        if not isinstance(event, str) or not isinstance(command, str):
            continue
        if (event, matcher, command) in seen:
            continue
        seen.add((event, matcher, command))
        entries = hooks.get(event, [])
        if not isinstance(entries, list):
            continue
        present = any(
            isinstance(g, dict) and isinstance(g.get("hooks"), list)
            and g.get("matcher", "") == matcher
            and any(isinstance(h, dict) and h.get("command", "") == command for h in g["hooks"])
            for g in entries
        )
        if not present:
            missing.append((event, matcher, command))
    return missing


def git_hook_registrations(propel_root: Path) -> set[tuple[str, str, str]]:
    """Registrations from every version of hooks/hooks.json on HEAD's main line.

    Empty set unless propel_root is its own git repository. Versions that do
    not parse are skipped.
    """
    if not _is_dedicated_repo(propel_root):
        return set()
    log = _git(propel_root, "log", "HEAD", "--format=%H", "--", "hooks/hooks.json")
    if log is None:
        return set()
    found: set[tuple[str, str, str]] = set()
    for sha in log.stdout.split():
        shown = _git(propel_root, "show", f"{sha}:hooks/hooks.json")
        if shown is not None:
            found |= parse_hook_registrations(shown.stdout)
    return found


def historical_hook_registrations(propel_root: Path) -> set[tuple[str, str, str]]:
    """Every (event, matcher, command) Propel has registered: the current
    hooks/hooks.json on disk plus, in a dedicated clone, every version in git
    history. Callers add RETIRED_HOOK_REGISTRATIONS for zip/shallow installs.
    """
    found = git_hook_registrations(propel_root)
    current = propel_root / "hooks" / "hooks.json"
    try:
        found |= parse_hook_registrations(current.read_text())
    except OSError:
        pass
    return found


def source_info(propel_root: Path) -> dict:
    """{version, commit, dirty} for the propel clone.

    commit/dirty are None without git, or when propel_root is not its own repo.
    """
    commit = None
    dirty = None
    if _is_dedicated_repo(propel_root):
        head = _git(propel_root, "rev-parse", "--short", "HEAD")
        if head is not None:
            commit = head.stdout.strip() or None
            porcelain = _git(propel_root, "status", "--porcelain", "--untracked-files=no")
            if porcelain is not None:
                dirty = bool(porcelain.stdout.strip())
    return {"version": __version__, "commit": commit, "dirty": dirty}


# ---------------------------------------------------------------------------
# Plan
# ---------------------------------------------------------------------------


def _clash(claude_dir: Path, rel: str, removals: set[str], fold) -> str | None:
    """Why a file cannot be written at `rel`, or None. Checked before anything runs."""
    parts = rel.split("/")
    for i in range(1, len(parts)):
        ancestor_rel = "/".join(parts[:i])
        ancestor = claude_dir / ancestor_rel
        if ancestor.is_symlink() and not ancestor.exists():
            return f"a broken link sits at .claude/{ancestor_rel}, where Propel needs a directory"
        if ancestor.exists() and not ancestor.is_dir():
            if fold(ancestor_rel) in removals:
                continue  # removed before anything is written
            return f"a file sits at .claude/{ancestor_rel}, where Propel needs a directory"
    dest = claude_dir / rel
    if dest.is_dir() and not dest.is_symlink():
        # Fine only if the directory holds nothing but stale Propel files
        # about to be removed, so it is emptied and cleared before the write.
        if not _only_removals_under(dest, claude_dir, removals, fold):
            return "a directory sits at this path"
    return None


def _only_removals_under(dest: Path, claude_dir: Path, removals: set[str], fold) -> bool:
    """True if every entry under `dest` is a removal target (and there is at least one)."""
    found = False
    for dirpath, dirnames, filenames in os.walk(dest, followlinks=False):
        # A symlinked directory is listed in dirnames and would block rmdir.
        if any((Path(dirpath) / d).is_symlink() for d in dirnames):
            return False
        for name in filenames:
            inner = (Path(dirpath) / name).relative_to(claude_dir).as_posix()
            if fold(inner) not in removals:
                return False
            found = True
    return found


def plan(
    propel_root: Path,
    claude_dir: Path,
    manifest: dict | None,
    history: set[str] | None = None,
    blobs: dict[str, set[str]] | None = None,
    has_history: bool | None = None,
) -> Plan:
    """Classify every upstream file and every installed file under the managed dirs.

    `history` and `blobs` (historical paths, and blob ids per path) are read
    from git only for a legacy install (no manifest), and only when not given;
    tests may pass them in. `has_history` (see history_available) likewise.
    """
    recorded = (manifest or {}).get("files") or {}
    if not isinstance(recorded, dict):
        recorded = {}
    legacy = manifest is None
    if legacy and (history is None or blobs is None):
        found = historical_blobs(propel_root)
        if history is None:
            history = set(found)
        if blobs is None:
            blobs = found
    if legacy and has_history is None:
        has_history = history_available(propel_root)
    history = history or set()
    blobs = blobs or {}

    ci = _is_case_insensitive(claude_dir)

    def fold(rel: str) -> str:
        return rel.casefold() if ci else rel

    upstream = _files_under(propel_root)
    installed_files = _files_under(claude_dir)
    installed: dict[str, str] = {fold(rel): rel for rel in installed_files}
    upstream_keys = {fold(rel) for rel in upstream}
    claude_root = claude_dir.resolve()
    result = Plan(claude_dir=claude_dir, upstream=upstream)

    # RETIRED_PATHS only in legacy mode: with a manifest, Propel knows exactly
    # what it wrote, and a file at a retired path it never recorded is the user's.
    candidates = (set(RETIRED_PATHS) | history) if legacy else set(recorded)
    candidate_keys = {fold(rel) for rel in candidates}

    def recorded_hash(*rels: str) -> str | None:
        for rel in rels:
            if rel in recorded:
                return recorded[rel]
        return None

    # Removals first: an upstream write may depend on a removal clearing the way.
    removal_actions: list[Action] = []
    for key in sorted(installed):
        rel = installed[key]
        if key in upstream_keys:
            continue
        dest = claude_dir / rel
        if key not in candidate_keys:
            result.actions.append(Action("keep_user", rel))
            continue
        if _escapes(claude_root, dest):
            result.actions.append(Action("keep_user", rel, note=REASON_SYMLINK))
            continue
        if legacy and not has_history:
            removal_actions.append(Action("remove", rel, note=LABEL_NO_HISTORY))
            continue
        if legacy:
            matches = _git_blob_sha(dest) in blobs.get(rel, set())
        else:
            matches = recorded_hash(rel) == _sha256(dest)
        removal_actions.append(Action("remove" if matches else "remove_edited", rel))
    removals = {fold(a.path) for a in removal_actions}

    for rel in sorted(upstream):
        src = upstream[rel]
        key = fold(rel)
        on_disk = installed.get(key)
        dest = claude_dir / (on_disk or rel)
        if _escapes(claude_root, dest):
            result.actions.append(Action("keep_user", rel, note=REASON_SYMLINK))
            continue
        if on_disk is None:
            clash = _clash(claude_dir, rel, removals, fold)
            if clash is not None:
                result.actions.append(Action("conflict_user", rel, note=clash))
            elif dest.exists() or dest.is_symlink():
                # Something Propel cannot index sits at the path (a dangling
                # link, a file reached through a symlinked directory).
                result.actions.append(
                    Action("conflict_user", rel, note="not a regular file Propel can manage")
                )
            else:
                result.actions.append(Action("add", rel, src))
            continue

        # On a case-insensitive filesystem `on_disk` may differ from `rel` in
        # case only: it is the same file. It is compared, owned and recorded
        # under the shipped key, but written in place under its existing name,
        # and a case-mismatched directory keeps its case — renaming it is not
        # Propel's call, and identical bytes must stay "unchanged" so repeated
        # runs never loop on it.
        alias = on_disk if on_disk != rel else None
        current = _sha256(dest)
        if current == _sha256(src):
            result.unchanged.append(rel)
            continue
        if legacy:
            if not has_history:
                result.actions.append(Action("replace", rel, src, note=LABEL_NO_HISTORY, on_disk=alias))
            elif _git_blob_sha(dest) in blobs.get(rel, set()) | blobs.get(on_disk, set()):
                result.actions.append(Action("replace", rel, src, note=LABEL_OLDER_VERSION, on_disk=alias))
            else:
                result.actions.append(
                    Action("replace_edited", rel, src, note=LABEL_NO_SHIPPED_MATCH, on_disk=alias)
                )
            continue
        previous = recorded_hash(rel, on_disk)
        if previous is None:
            result.actions.append(Action(
                "conflict_user", rel,
                note="your file at a path Propel now ships; Propel's copy was not installed",
            ))
        elif previous == current:
            result.actions.append(Action("replace", rel, src, on_disk=alias))
        else:
            result.actions.append(Action("replace_edited", rel, src, on_disk=alias))

    result.actions.extend(removal_actions)
    result.actions.sort(key=lambda a: a.path)
    return result


# ---------------------------------------------------------------------------
# Apply
# ---------------------------------------------------------------------------


def apply(
    the_plan: Plan,
    project_root: Path,
    source: dict | None,
    hooks: list[dict] | None = None,
    backup_dir: Path | None = None,
) -> dict:
    """Execute a plan: back up, remove, write, chmod, build the manifest.

    `backup_dir` reuses an already reserved backup directory; otherwise one is
    reserved only if something needs backing up. Old backup directories beyond
    the newest BACKUPS_KEPT are pruned afterwards.

    The manifest is returned, not written: the caller writes it last, with
    write_manifest, once everything else (settings) has succeeded.

    Returns {"backup_dir": Path|None, "backups": {rel: Path}, "counts": {kind: n},
    "manifest": dict}.
    """
    claude_dir = the_plan.claude_dir
    claude_root = claude_dir.resolve()
    source = source or {}

    def target_of(action: Action) -> Path:
        return claude_dir / (action.on_disk or action.path)

    # Last line of defence: the plan already classified escapes as keep_user.
    actionable = [
        a for a in the_plan.actions
        if a.kind in CHANGE_KINDS and not _escapes(claude_root, target_of(a))
    ]

    to_backup = [a for a in actionable if a.kind in BACKUP_KINDS]
    if to_backup and backup_dir is None:
        backup_dir = reserve_backup_dir(project_root)
    backups: dict[str, Path] = {}
    for action in to_backup:
        dest = backup_dir / action.path
        dest.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(target_of(action), dest)
        backups[action.path] = dest

    # Removes first, so a path that turned from a file into a directory
    # upstream can be recreated by the writes below.
    removed_parents: set[Path] = set()
    for action in actionable:
        if action.kind not in REMOVE_KINDS:
            continue
        target = target_of(action)
        target.unlink()
        removed_parents.add(target.parent)

    # Drop directories emptied by the removals, walking up but never past the
    # managed directory itself.
    roots = {claude_dir / d for d in MANAGED_DIRS}
    for parent in sorted(removed_parents, key=lambda p: len(p.parts), reverse=True):
        d = parent
        while d not in roots and claude_dir in d.parents:
            try:
                d.rmdir()  # only succeeds when empty
            except OSError:
                break
            d = d.parent

    written: set[str] = set()
    for action in actionable:
        if action.kind not in WRITE_KINDS:
            continue
        target = target_of(action)
        target.parent.mkdir(parents=True, exist_ok=True)
        if target.is_symlink():
            # Never write through a link. The plan made outside-pointing links
            # keep_user, so this one points inside .claude/; drop the link.
            target.unlink()
        _atomic_copy(action.source, target)
        written.add(action.path)

    owned = sorted(written | set(the_plan.unchanged))

    # Shell helpers must stay executable. Only files Propel owns: user files
    # are never written, and that includes their mode bits.
    for rel in owned:
        top = rel.split("/", 1)[0]
        if top in ("hooks", "scripts") and rel.endswith(".sh"):
            sh = claude_dir / rel
            if sh.is_file() and not sh.is_symlink():
                sh.chmod(sh.stat().st_mode | 0o111)

    manifest = {
        "schema": MANIFEST_SCHEMA,
        "propel_version": source.get("version", __version__),
        "source_commit": source.get("commit"),
        "source_dirty": source.get("dirty"),
        "installed_at": datetime.now().isoformat(timespec="seconds"),
        "files": {
            rel: _sha256(claude_dir / rel) for rel in owned if (claude_dir / rel).is_file()
        },
        "hooks": hooks or [],
    }
    used_backup_dir = backup_dir if backups else None
    prune_backups(project_root, protect=(backup_dir,))

    counts = {kind: len(the_plan.of(kind)) for kind in CHANGE_KINDS + KEEP_KINDS}
    return {
        "backup_dir": used_backup_dir,
        "backups": backups,
        "counts": counts,
        "manifest": manifest,
    }


# ---------------------------------------------------------------------------
# Status
# ---------------------------------------------------------------------------


def status(propel_root: Path, project_root: Path) -> dict:
    """What an update would do in this project, without doing it.

    "Installed" means Propel's files are present (.claude/skills/using-propel
    is a directory); a manifest alone is not enough. When not installed, no
    plan is built and git is never run: the per-file counts are None,
    available_commit/available_dirty are None, and update_available is False.

    When installed, "hooks_pending" counts the registrations in the current
    hooks/hooks.json that .claude/settings.local.json lacks (a missing settings
    file: all of them). A settings file that cannot be read or parsed — or a
    hooks.json that cannot — never raises: hooks_pending is None and
    "settings_error" says why. update_available is true when files would change
    or a registration is pending.

    "skipped_symlinked" counts the paths left alone because they sit under (or
    are) a symlink pointing outside .claude/ — e.g. `.claude/skills -> ~/shared`.
    They do not make update_available true: linking them was the user's choice,
    but `propel status` warns that they are not being updated. None when not
    installed.

    Raises ManifestError if .propel/manifest.json exists but is unusable.
    """
    manifest = load_manifest(project_root)
    claude_dir = project_root / ".claude"
    installed = (claude_dir / "skills" / "using-propel").is_dir()
    if not installed:
        return {
            "available_version": __version__,
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
            "skipped_symlinked": None,
            "update_available": False,
        }
    p = plan(propel_root, claude_dir, manifest)
    src = source_info(propel_root)
    changes = p.changes
    hooks_pending, settings_error = _hooks_pending(propel_root, claude_dir / "settings.local.json")
    return {
        "available_version": src["version"],
        "available_commit": src["commit"],
        "available_dirty": src["dirty"],
        "installed_version": (manifest or {}).get("propel_version"),
        "installed_commit": (manifest or {}).get("source_commit"),
        "installed": installed,
        "changes": changes,
        "edited_bundled": len(p.of("replace_edited")) + len(p.of("remove_edited")),
        "user_files": len(p.of("keep_user")) + len(p.of("conflict_user")),
        "hooks_pending": hooks_pending,
        "settings_error": settings_error,
        "skipped_symlinked": sum(1 for a in p.of("keep_user") if a.note == REASON_SYMLINK),
        # init refuses to run while the settings file is unreadable or a broken
        # link, so don't offer an update it would refuse.
        "update_available": settings_error is None and (changes > 0 or (hooks_pending or 0) > 0),
    }


def _hooks_pending(propel_root: Path, settings_path: Path) -> tuple[int | None, str | None]:
    """(registrations from hooks.json missing in settings, error). Never raises."""
    try:
        hooks_config = load_hooks_config(propel_root)
    except Exception as exc:  # noqa: BLE001 — status must never raise
        return None, f"could not read {propel_root / 'hooks' / 'hooks.json'}: {exc}"
    if settings_path.is_symlink() and not settings_path.exists():
        # init refuses a broken link (or a loop) before any write; report it as
        # an error, not as an update. os.readlink, not resolve(): resolve raises
        # RuntimeError on a loop before Python 3.13.
        try:
            target = os.readlink(settings_path)
        except (OSError, RuntimeError, ValueError):
            return None, f"{settings_path} is a broken symlink"
        return None, f"{settings_path} is a symlink to {target}, which does not exist"
    try:
        settings, _text = read_settings(settings_path)
    except SettingsError as exc:
        return None, str(exc)
    except (OSError, ValueError) as exc:
        return None, f"could not read {settings_path}: {exc}"
    return len(missing_hook_registrations(settings, hooks_config)), None
