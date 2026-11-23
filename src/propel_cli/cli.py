"""Propel CLI — init and session management for Claude Code research workflows.

Adapted from scott-yj-yang/new-prompt with:
- `propel init` to auto-scaffold .claude/ in any project
- Auto-detection of project root via git rev-parse (no hardcoded paths)
- Investigation artifact linking (scratch/ symlinks)
- Session index maintenance (sessions/INDEX.md)
"""

import importlib.metadata
import json
import os
import re
import shutil
import subprocess
import sys
import uuid
from datetime import datetime
from pathlib import Path

import click

from . import __version__, install


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def get_propel_root() -> Path:
    """Locate the propel data root (skills/, agents/, commands/, hooks/).

    Works for both editable installs (pip install -e .) and running from source.
    Walks up from this file's directory until we find skills/ alongside src/.
    """
    current = Path(__file__).resolve().parent  # src/propel_cli/
    for _ in range(5):
        current = current.parent
        if (current / "skills").is_dir() and (current / "agents").is_dir():
            return current
    raise FileNotFoundError(
        "Could not locate Propel data directories (skills/, agents/). "
        "Install from the propel directory with `pip install -e .` inside an activated env."
    )


def get_project_root() -> Path:
    """Find the project root via git rev-parse --show-toplevel."""
    try:
        result = subprocess.run(
            ["git", "rev-parse", "--show-toplevel"],
            capture_output=True,
            text=True,
            check=True,
        )
        return Path(result.stdout.strip())
    except (subprocess.CalledProcessError, FileNotFoundError):
        return Path.cwd()


def slugify(text: str) -> str:
    """Convert text to a filesystem-safe slug."""
    text = text.lower().strip()
    text = re.sub(r"[^\w\s-]", "", text)
    text = re.sub(r"[\s_]+", "-", text)
    text = re.sub(r"-+", "-", text)
    return text.strip("-")


def get_sessions_dir() -> Path:
    """Get or create the sessions directory at project root."""
    root = get_project_root()
    sessions = root / "sessions"
    sessions.mkdir(exist_ok=True)
    return sessions


def get_claude_history_dir() -> Path:
    """Find Claude Code's chat history directory."""
    home = Path.home()
    claude_dir = home / ".claude" / "projects"
    if claude_dir.exists():
        return claude_dir
    return home / ".claude"


def find_latest_investigation() -> Path | None:
    """Find the most recent investigation in scratch/."""
    root = get_project_root()
    scratch = root / "scratch"
    if not scratch.exists():
        return None

    investigations = sorted(
        [d for d in scratch.iterdir() if d.is_dir() and (d / "README.md").exists()],
        key=lambda d: d.name,
        reverse=True,
    )
    return investigations[0] if investigations else None


def link_investigation(session_dir: Path) -> None:
    """Create a symlink from the session dir to the active investigation."""
    investigation = find_latest_investigation()
    if investigation is None:
        return

    link_path = session_dir / "scratch"
    if not link_path.exists():
        try:
            link_path.symlink_to(investigation.resolve())
        except OSError:
            pass


def update_index(sessions_dir: Path, session_name: str, description: str) -> None:
    """Update sessions/INDEX.md with the new session entry."""
    index_path = sessions_dir / "INDEX.md"

    now = datetime.now()
    date_str = now.strftime("%Y-%m-%d %H:%M")

    if not index_path.exists():
        header = "# Session Index\n\n| Date | Session | Description | History |\n|------|---------|-------------|--------|\n"
    else:
        header = index_path.read_text()

    entry = f"| {date_str} | [{session_name}]({session_name}/) | {description} | [chat]({session_name}/chat_history.jsonl) |\n"
    content = header + entry
    index_path.write_text(content)


def create_prompt_template(session_dir: Path, description: str) -> None:
    """Create a prompt.md template in the session directory."""
    content = f"""# Session: {description}

## Goal
{description}

## Context
- Started: {datetime.now().strftime("%Y-%m-%d %H:%M")}
- Investigation: [link to scratch/ investigation if applicable]

## Notes
[Add session notes here]
"""
    (session_dir / "prompt.md").write_text(content)


def save_chat_history(session_id: str, session_dir: Path) -> bool:
    """Copy Claude Code chat history into the session directory."""
    claude_dir = get_claude_history_dir()

    for project_dir in claude_dir.rglob("*"):
        if not project_dir.is_dir():
            continue
        history_file = project_dir / f"{session_id}.jsonl"
        if history_file.exists():
            dest = session_dir / "chat_history.jsonl"
            dest.write_bytes(history_file.read_bytes())
            return True

    return False


def _is_new_format_group(entry: dict) -> bool:
    """Check if a hook entry uses the new matcher+hooks format."""
    return isinstance(entry, dict) and "hooks" in entry and isinstance(entry["hooks"], list)


def _group_commands(group: dict) -> list:
    return [h.get("command") if isinstance(h, dict) else None for h in group["hooks"]]


def _group_key(event, group: dict) -> tuple:
    """Identity of a matcher group for ownership: (event, matcher, commands).
    Other fields (timeout, type) are ignored, so a user tweak doesn't orphan it."""
    hooks = group.get("hooks") if isinstance(group.get("hooks"), list) else []
    commands = tuple(h.get("command") if isinstance(h, dict) else None for h in hooks)
    return (event, group.get("matcher") or "", commands)


def read_settings(settings_path: Path) -> tuple[dict, str | None]:
    """Parse .claude/settings.local.json. Returns (settings, original_text or None).

    An empty or whitespace-only file counts as {}. A file that does not
    parse, or is not a JSON object, or whose "hooks" is not an object, raises
    a ClickException naming the file. Nothing is written. (The parsing lives
    in install.read_settings, which `propel status` shares.)
    """
    settings_write_target(settings_path)
    try:
        return install.read_settings(settings_path)
    except install.SettingsError as exc:
        raise click.ClickException(f"{exc} Fix it and re-run; nothing was changed.")


def settings_write_target(settings_path: Path) -> Path | None:
    """The file a settings write lands in when settings_path is a symlink, else None.

    Users link .claude/settings.local.json to share a permission allowlist from
    their dotfiles, so the write goes through the link (to its resolved target)
    and the link stays. A broken link raises a ClickException: the target is
    never created. read_settings calls this first, so init stops on a broken
    link before anything is written.
    """
    if not settings_path.is_symlink():
        return None
    if not settings_path.exists():
        raise click.ClickException(
            f"{settings_path} is a symlink to {os.readlink(settings_path)}, which does not exist. "
            "Create the target or remove the link, then re-run; nothing was changed."
        )
    return settings_path.resolve()


def _describe_settings_link(settings_path: Path, target: Path) -> str:
    return f"wrote through symlink {settings_path.parent.name}/{settings_path.name} -> {target}"


def compute_hooks_merge(
    settings: dict,
    hooks_config: list[dict],
    previous_hooks: list[dict] | None,
    propel_registrations: set[tuple[str, str, str]],
) -> tuple[dict, list[dict], list[tuple[str, dict]]]:
    """Merge Propel's hook registrations into a settings dict, in memory only.

    Generates the current Claude Code hooks format:
    {
      "hooks": {
        "EventName": [
          {
            "matcher": "",
            "hooks": [{"type": "command", "command": "..."}]
          }
        ]
      }
    }

    Only Propel's own registrations are ever removed. A matcher group is
    removed when it is no longer in hooks.json AND it is Propel's:
    - it matches a group recorded in the previous manifest (`previous_hooks`)
      by (event, matcher, commands) — other fields are ignored; or
    - when nothing was recorded (`previous_hooks` is None or empty), every
      command in it, as the exact tuple (event, matcher, command), is one
      Propel has registered: in `propel_registrations` (current hooks.json,
      every version in git history, RETIRED_HOOK_REGISTRATIONS). A user's own
      registration — even of a Propel script, with other arguments or under
      another matcher or event — is never an exact match, so it is kept.
    Old flat `{"command": ...}` entries are removed by that same exact rule,
    with matcher "", manifest or not. Unknown event names and every other
    settings key are kept.

    Returns (new_settings, wanted, removed): `wanted` is the Propel groups now
    registered, as [{"event", "matcher", "hooks"}], for the install manifest;
    `removed` is [(event, entry)] for every entry taken out.
    """
    settings = json.loads(json.dumps(settings))
    existing_hooks = settings.get("hooks", {})

    # The groups hooks.json asks for, in registration order, deduplicated.
    wanted: list[dict] = []
    wanted_pairs: dict[str, set] = {}
    for hook in hooks_config:
        event = hook["event"]
        matcher = hook.get("matcher", "")
        command = hook["command"]
        if (matcher, command) in wanted_pairs.setdefault(event, set()):
            continue
        wanted_pairs[event].add((matcher, command))
        wanted.append(
            {
                "event": event,
                "matcher": matcher,
                "hooks": [{"type": "command", "command": command}],
            }
        )

    recorded = None
    if previous_hooks:
        recorded = {
            _group_key(g.get("event"), g) for g in previous_hooks if isinstance(g, dict)
        }

    def still_wanted(event: str, group: dict) -> bool:
        pairs = wanted_pairs.get(event, set())
        matcher = group.get("matcher", "")
        commands = _group_commands(group)
        return bool(commands) and all((matcher, c) in pairs for c in commands)

    def is_propel_group(event: str, group: dict) -> bool:
        if recorded is not None:
            return _group_key(event, group) in recorded
        commands = _group_commands(group)
        matcher = group.get("matcher") or ""
        return bool(commands) and all(
            isinstance(c, str) and isinstance(matcher, str)
            and (event, matcher, c) in propel_registrations
            for c in commands
        )

    removed: list[tuple[str, dict]] = []
    for event in list(existing_hooks.keys()):
        entries = existing_hooks[event]
        if not isinstance(entries, list):
            continue  # not ours to interpret
        kept = []
        for entry in entries:
            if not _is_new_format_group(entry):
                # Old flat {"command": "..."} entry from a previous install.
                command = entry.get("command") if isinstance(entry, dict) else None
                if isinstance(command, str) and (event, "", command) in propel_registrations:
                    removed.append((event, entry))
                    continue
                kept.append(entry)
                continue
            if is_propel_group(event, entry) and not still_wanted(event, entry):
                removed.append((event, entry))
                continue
            kept.append(entry)
        if len(kept) != len(entries):
            if kept:
                existing_hooks[event] = kept
            else:
                del existing_hooks[event]

    # Add new hooks: every wanted (event, matcher, command) not already
    # registered under the same matcher — (matcher, command) rather than
    # command alone, since the same script can legitimately be registered under
    # two different tool matchers. install.missing_hook_registrations is the
    # same test `propel status` uses to count pending registrations.
    for event, matcher, command in install.missing_hook_registrations(
        {"hooks": existing_hooks}, hooks_config
    ):
        entries = existing_hooks.setdefault(event, [])
        entries.append({"matcher": matcher, "hooks": [{"type": "command", "command": command}]})

    settings["hooks"] = existing_hooks
    return settings, wanted, removed


def settings_need_write(settings: dict, new_settings: dict, original_text: str | None) -> bool:
    if original_text is None:
        return bool(new_settings.get("hooks"))
    return new_settings != settings


def write_settings(
    settings_path: Path,
    new_settings: dict,
    original_text: str | None,
    backup_dir: Path | None,
) -> Path | None:
    """Write settings atomically. An existing file is first copied into
    `backup_dir` (the run's .propel/backup/<ts>/). Returns the backup path.

    A symlinked settings_path is written through: atomically to its resolved
    target (temp file in the target's directory), keeping the link. See
    settings_write_target."""
    target = settings_write_target(settings_path) or settings_path
    backup = None
    if original_text is not None and backup_dir is not None:
        backup = backup_dir / settings_path.name
        backup.write_text(original_text)
    install.atomic_write_text(target, json.dumps(new_settings, indent=2) + "\n")
    return backup


def merge_hooks_config(
    settings_path: Path,
    hooks_config: list[dict],
    previous_hooks: list[dict] | None = None,
    propel_registrations: set[tuple[str, str, str]] | None = None,
) -> list[dict]:
    """Read, merge and write .claude/settings.local.json in one call.

    See compute_hooks_merge for the ownership rules. A file that does not
    parse aborts with a ClickException and nothing is written. An existing
    file that changes is backed up to <project>/.propel/backup/<ts>/ first.
    Returns the Propel groups now registered.
    """
    settings, original_text = read_settings(settings_path)
    new_settings, wanted, _removed = compute_hooks_merge(
        settings, hooks_config, previous_hooks, propel_registrations or set()
    )
    if settings_need_write(settings, new_settings, original_text):
        backup_dir = None
        if original_text is not None:
            backup_dir = install.reserve_backup_dir(settings_path.parent.parent)
        write_settings(settings_path, new_settings, original_text, backup_dir)
        link_target = settings_write_target(settings_path)
        if link_target is not None:
            click.echo(f"  {_describe_settings_link(settings_path, link_target)}")
    return wanted


def ensure_gitignore_entries(project_root: Path, entries: list[str]) -> list[str]:
    """Add entries to .gitignore if not already present. Returns entries added."""
    gitignore = project_root / ".gitignore"
    existing = ""
    if gitignore.exists():
        existing = gitignore.read_text()

    added = []
    lines_to_add = []
    for entry in entries:
        if entry not in existing:
            lines_to_add.append(entry)
            added.append(entry)

    if lines_to_add:
        suffix = "\n" if existing and not existing.endswith("\n") else ""
        gitignore.write_text(existing + suffix + "\n".join(lines_to_add) + "\n")

    return added


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------


@click.group(invoke_without_command=True)
@click.version_option(__version__, prog_name="propel")
@click.pass_context
def cli(ctx):
    """Propel — research workflow CLI for Claude Code.

    Run `propel` with no arguments to set up. On a desktop that opens the
    browser console (`propel launch`); on a machine with no display — a
    cluster node, a container, anything over SSH — it runs the same steps in
    the terminal (`propel setup`). It says which, and either can be forced.
    """
    if ctx.invoked_subcommand is not None:
        return
    from .launcher import is_headless

    if is_headless():
        click.echo("No display here (cluster, container or SSH), so setup runs in the terminal.")
        click.echo("For the browser console instead: propel launch --no-browser")
        ctx.invoke(setup)
    else:
        click.echo("Opening the setup console in your browser. On a remote machine: propel setup")
        ctx.invoke(launch_console)


# ---------------------------------------------------------------------------
# propel launch / propel setup
# ---------------------------------------------------------------------------


# The function is not called `launch`: `propel session launch` below is, and a
# second module-level `launch` would silently replace this one wherever the
# name is looked up — which is how bare `propel` once ran session launch.
@cli.command(name="launch")
@click.option("--no-browser", is_flag=True, help="Print the URL instead of opening a browser (for SSH tunnels).")
@click.option("--port", default=0, type=int, help="Bind to a specific port (default: random).")
def launch_console(no_browser: bool, port: int):
    """Open the Propel setup console in your browser (desktop).

    Detects git, Claude Code and Codex and whether each is signed in; installs
    what's missing with the vendors' native installers; opens a terminal for
    the two logins; and installs Propel into the current project.
    """
    from . import launcher

    try:
        launcher.serve(open_browser=not no_browser, port=port)
    except FileNotFoundError as exc:
        click.echo(f"Launcher assets missing: {exc}", err=True)
        raise SystemExit(1)
    except OSError as exc:
        click.echo(f"Could not start the launcher: {exc}", err=True)
        raise SystemExit(1)


@cli.command()
def setup():
    """Set up Propel in the terminal (cluster, container, SSH).

    Same checklist as the browser console, with no browser and no port
    forwarding: installs Claude Code and Codex with their native installers,
    signs both in with codes you approve on any device, and installs Propel
    into the current project. Asks before every change.
    """
    from . import terminal_setup

    raise SystemExit(terminal_setup.run())


# ---------------------------------------------------------------------------
# propel init
# ---------------------------------------------------------------------------


def _load_hooks_config(propel_root: Path) -> list[dict]:
    """hooks/hooks.json with commands rewritten to .claude/ paths, or [] if absent.

    See install.load_hooks_config, which `propel status` shares.
    """
    return install.load_hooks_config(propel_root)


def _describe_hook_group(event: str, entry: dict) -> str:
    if _is_new_format_group(entry):
        commands = [c for c in _group_commands(entry) if isinstance(c, str)]
        matcher = entry.get("matcher") or ""
    else:
        commands = [entry.get("command")] if isinstance(entry.get("command"), str) else []
        matcher = ""
    where = f"{event} [{matcher}]" if matcher else event
    return f"{where}: {'; '.join(commands) or '(no command)'}"


def _echo_hook_conflicts(the_plan, registered: list[dict]) -> None:
    """Warn when a Propel hook registration points at a file Propel kept as the user's.

    A conflict_user file under hooks/ or scripts/ means Propel's copy was not
    installed — but the registration for it still is, so it runs the user's file.
    """
    for a in the_plan.of("conflict_user"):
        if a.path.split("/", 1)[0] not in ("hooks", "scripts"):
            continue
        target = f".claude/{a.path}"
        for group in registered:
            for command in _group_commands(group):
                if isinstance(command, str) and target in command.split():
                    click.echo(
                        f"  WARNING: hook {_describe_hook_group(group['event'], group)} — "
                        f"the registration runs YOUR file {target}, not Propel's"
                    )


def _echo_install_summary(
    the_plan, report: dict | None, project_root: Path, propel_root: Path, dry_run: bool
) -> None:
    """Print the plan grouped by action. `report` is None under --dry-run."""
    added = the_plan.of("add")
    replaced = the_plan.of("replace")
    edited = the_plan.of("replace_edited")
    removed = the_plan.of("remove")
    removed_edited = the_plan.of("remove_edited")
    kept = the_plan.of("keep_user")
    conflicts = the_plan.of("conflict_user")
    backups = (report or {}).get("backups", {})

    def rel_to_project(path: Path) -> str:
        try:
            return str(path.relative_to(project_root))
        except ValueError:
            return str(path)

    def with_backup(a) -> str:
        line = f"    .claude/{a.path}"
        if a.note:
            line += f"  ({a.note})"
        if a.path in backups:
            line += f"  ->  backup {rel_to_project(backups[a.path])}"
        return line

    if not the_plan.changes:
        click.echo("  Propel files — no changes")
    if added:
        per_dir: dict[str, int] = {}
        for a in added:
            top = a.path.split("/", 1)[0]
            per_dir[top] = per_dir.get(top, 0) + 1
        breakdown = ", ".join(f"{d}/ {n}" for d, n in per_dir.items())
        verb = "would add" if dry_run else "added"
        click.echo(f"  {verb} {len(added)} file(s) — {breakdown}")
    if replaced:
        verb = "would update" if dry_run else "updated"
        click.echo(f"  {verb} {len(replaced)} file(s)")
        for a in replaced:
            click.echo(f"    .claude/{a.path}" + (f"  — {a.note}" if a.note else ""))
    if edited:
        if dry_run:
            click.echo(f"  would replace {len(edited)} edited Propel file(s), backing each up first:")
        else:
            click.echo(f"  replaced {len(edited)} edited Propel file(s) — your copy is backed up:")
        for a in edited:
            click.echo(with_backup(a))
    if removed:
        verb = "would remove" if dry_run else "removed"
        click.echo(f"  {verb} {len(removed)} stale Propel file(s), backed up first")
        for a in removed:
            click.echo(f"    .claude/{a.path}" + (f"  — {a.note}" if a.note else ""))
    if removed_edited:
        if dry_run:
            click.echo(f"  would remove {len(removed_edited)} edited stale Propel file(s), backing each up first:")
        else:
            click.echo(f"  removed {len(removed_edited)} edited stale Propel file(s) — your copy is backed up:")
        for a in removed_edited:
            click.echo(with_backup(a))
    if conflicts:
        click.echo(
            f"  WARNING: kept {len(conflicts)} file(s) of yours where Propel ships a file;"
            " Propel's copy was not installed:"
        )
        for a in conflicts:
            click.echo(f"    .claude/{a.path} — {a.note}")
            click.echo(f"      Propel's copy is at {propel_root / a.path}")
    unsafe = [a for a in kept if a.note]
    if unsafe:
        click.echo(f"  WARNING: left {len(unsafe)} path(s) alone:")
        for a in unsafe:
            click.echo(f"    .claude/{a.path} — {a.note}")
    plain_kept = [a for a in kept if not a.note]
    if plain_kept:
        click.echo(f"  kept {len(plain_kept)} file(s) of your own, untouched")
    if report and report.get("backup_dir"):
        click.echo(f"  backups in {rel_to_project(report['backup_dir'])}/")


@cli.command()
@click.option("--dry-run", is_flag=True, help="Show what would change and write nothing.")
@click.option("--yes", is_flag=True, help="Non-interactive; accepted for scripts and the console.")
def init(dry_run: bool, yes: bool):
    """Set up .claude/ with Propel skills, agents, commands, and hooks.

    Propel's own files are added, updated or removed to match this Propel
    version; any you had edited are backed up to .propel/backup/ first. Files
    you added yourself are never touched.
    """
    # --yes is a placeholder: init asks nothing today, so there is nothing to
    # confirm. It exists so non-interactive callers can pass it unconditionally.
    del yes
    propel_root = get_propel_root()
    project_root = get_project_root()
    claude_dir = project_root / ".claude"
    settings_path = claude_dir / "settings.local.json"

    click.echo(f"Initializing Propel in {project_root}")
    click.echo(f"Using Propel data from {propel_root}\n")
    if dry_run:
        click.echo("  Dry run — nothing will be written.\n")

    # 1. Settings first: a settings file that doesn't parse aborts the whole
    #    init (dry run included) before anything has been written.
    try:
        settings, original_text = read_settings(settings_path)
    except click.ClickException as exc:
        if dry_run:
            raise click.ClickException(f"Dry run: init would abort here. {exc.message}")
        raise

    # 2. Plan the files and compute the merged settings, both in memory. A
    #    manifest that exists but cannot be used aborts here too.
    try:
        manifest = install.load_manifest(project_root)
    except install.ManifestError as exc:
        if dry_run:
            raise click.ClickException(f"Dry run: init would abort here. {exc}")
        raise click.ClickException(str(exc))
    the_plan = install.plan(propel_root, claude_dir, manifest)
    hooks_config = _load_hooks_config(propel_root)
    previous_hooks = manifest.get("hooks") if manifest else None
    if not isinstance(previous_hooks, list):
        previous_hooks = None
    propel_registrations = (
        install.historical_hook_registrations(propel_root) | install.RETIRED_HOOK_REGISTRATIONS
    )
    new_settings, registered, removed_groups = compute_hooks_merge(
        settings, hooks_config, previous_hooks, propel_registrations
    )
    write_needed = settings_need_write(settings, new_settings, original_text)
    to_add = install.missing_hook_registrations(settings, hooks_config)
    hooks_changed = bool(removed_groups or to_add)

    if dry_run:
        _echo_install_summary(the_plan, None, project_root, propel_root, dry_run=True)
        _echo_hook_conflicts(the_plan, registered)
        if removed_groups or to_add:
            click.echo("\n  settings.local.json:")
        if to_add:
            click.echo(f"    would add {len(to_add)} Propel hook group(s):")
            for event, matcher, command in to_add:
                group = {"matcher": matcher, "hooks": [{"type": "command", "command": command}]}
                click.echo(f"      {_describe_hook_group(event, group)}")
        if removed_groups:
            click.echo(f"    would remove {len(removed_groups)} stale Propel hook group(s):")
            for event, entry in removed_groups:
                click.echo(f"      {_describe_hook_group(event, entry)}")
        if not (removed_groups or to_add):
            if write_needed:
                click.echo("\n  settings.local.json — hooks would be merged")
            else:
                click.echo("\n  settings.local.json — no changes")
        click.echo("\nDry run complete. Re-run without --dry-run to apply.")
        return

    # 3. Files, then 4. settings (into the same backup directory), then 5. the
    #    manifest, last: if the settings write fails, the old manifest stays.
    report = install.apply(
        the_plan, project_root, install.source_info(propel_root), hooks=registered
    )
    _echo_install_summary(the_plan, report, project_root, propel_root, dry_run=False)
    _echo_hook_conflicts(the_plan, registered)

    backup_dir = report["backup_dir"]
    settings_backup = None
    if write_needed:
        if original_text is not None and backup_dir is None:
            backup_dir = install.reserve_backup_dir(project_root)
        settings_backup = write_settings(settings_path, new_settings, original_text, backup_dir)
    # Rewrite the manifest only when something besides the timestamp changed,
    # so a no-op init leaves .propel/manifest.json byte-identical.
    def without_timestamp(m):
        return {k: v for k, v in (m or {}).items() if k != "installed_at"}

    if manifest is None or without_timestamp(manifest) != without_timestamp(report["manifest"]):
        install.write_manifest(project_root, report["manifest"])
    install.prune_backups(project_root, protect=(backup_dir,))

    if write_needed:
        click.echo("\n  settings.local.json — hooks configured")
        link_target = settings_write_target(settings_path)
        if link_target is not None:
            click.echo(f"    {_describe_settings_link(settings_path, link_target)}")
        for event, entry in removed_groups:
            click.echo(f"    removed stale Propel hook group {_describe_hook_group(event, entry)}")
        if settings_backup is not None:
            click.echo(f"    previous settings backed up to {settings_backup.relative_to(project_root)}")
    else:
        click.echo("\n  settings.local.json — hooks already configured")

    # Create CLAUDE.md template if one doesn't exist
    claude_md = claude_dir / "CLAUDE.md"
    template = propel_root / "templates" / "CLAUDE.md"
    if claude_md.is_symlink():
        # Dangling or not, never write through a link.
        click.echo("  CLAUDE.md — is a symlink, left alone")
    elif not claude_md.exists() and template.exists():
        shutil.copy2(template, claude_md)
        click.echo(f"  CLAUDE.md — template created (fill in your research context!)")
    elif claude_md.exists():
        click.echo(f"  CLAUDE.md — already exists, skipped")

    # Update .gitignore
    added = ensure_gitignore_entries(project_root, ["scratch/", "sessions/", ".propel/", ".claude/", "propel/"])
    if added:
        click.echo(f"  .gitignore — added {', '.join(added)}")
    else:
        click.echo(f"  .gitignore — already up to date")

    # Shell helpers are made executable by install.apply (Propel's own only).

    # If the status line is wired up, refresh the global copies too. They live
    # outside the clone so moving the repo can't break them -- but that also
    # means editing a script here would otherwise leave the status line silently
    # serving a stale version.
    if GLOBAL_DIR.exists():
        refreshed = _sync_global_scripts(propel_root)
        if refreshed:
            click.echo(f"  status line — refreshed {', '.join(refreshed)}")

    # Seed the dual-model config so the state is explicit and inspectable
    propel_dir = project_root / ".propel"
    propel_dir.mkdir(exist_ok=True)
    codex_config = propel_dir / "codex.json"
    if not codex_config.exists():
        codex_config.write_text(
            json.dumps(
                {
                    "enabled": True,
                    "available": None,
                    "note": (
                        "Codex is consulted automatically at every major decision "
                        "point. Turn it off with /disable-codex."
                    ),
                },
                indent=2,
            )
            + "\n"
        )
        click.echo("  .propel/codex.json — dual-model layer enabled")

    click.echo(f"\nDone! Propel owns {len(report['manifest']['files'])} files in {claude_dir}/")
    click.echo("Run `propel` to check your Claude Code / Codex setup,")
    click.echo("or `claude` to start working.")
    # `propel update` prints this itself, after its own summary.
    if hooks_changed and write_needed and not os.environ.get(_RESTART_HINT_ENV):
        click.echo(RESTART_HINT)


# ---------------------------------------------------------------------------
# propel status / propel update
# ---------------------------------------------------------------------------


RESTART_HINT = (
    "Restart any Claude Code session open in this project: hook changes load at session start."
)
# Set for the child `propel init` that `propel update` runs, so the hint is
# printed once, after update's summary, rather than in the middle of the output.
_RESTART_HINT_ENV = "PROPEL_DEFER_RESTART_HINT"


def _describe_version(version, commit, dirty=False) -> str:
    if version is None:
        return "unknown"
    if commit:
        return f"{version} ({commit}{' + uncommitted changes' if dirty else ''})"
    return f"{version} (uncommitted changes)" if dirty else str(version)


@cli.command(name="status")
def status_cmd():
    """Show the installed and available Propel versions for this project."""
    propel_root = get_propel_root()
    project_root = get_project_root()
    try:
        s = install.status(propel_root, project_root)
    except install.ManifestError as exc:
        raise click.ClickException(str(exc))

    click.echo(f"Project:   {project_root}")
    click.echo(f"Propel:    {propel_root}")
    available = _describe_version(s["available_version"], s["available_commit"], s.get("available_dirty"))
    click.echo(f"Available: {available}")
    if s["installed"]:
        click.echo(f"Installed: {_describe_version(s['installed_version'], s['installed_commit'])}")
    else:
        click.echo("Installed: not installed")
    def count(n):
        return "n/a" if n is None else n

    click.echo(f"Changes pending:       {count(s['changes'])}")
    click.echo(f"Edited bundled files:  {count(s['edited_bundled'])} (replaced or removed on update, backed up first)")
    click.echo(f"User files kept:       {count(s['user_files'])}")
    click.echo(f"Hook registrations pending: {count(s.get('hooks_pending'))}")
    if s.get("skipped_symlinked"):
        click.echo(
            f"WARNING: {s['skipped_symlinked']} Propel path(s) left alone under a symlink pointing"
            " outside .claude/ — they are not updated (`propel init --dry-run` lists them)"
        )
    if s.get("settings_error"):
        click.echo(f"Settings: {s['settings_error']}")
    if not s["installed"]:
        click.echo("Update available: n/a — Propel isn't installed here; run `propel init`")
    else:
        click.echo(f"Update available: {'yes' if s['update_available'] else 'no'}")


# ---------------------------------------------------------------------------
# propel tasks
# ---------------------------------------------------------------------------


TASK_QUEUE_REL = Path(".claude") / "scripts" / "task-queue.sh"


def _find_tasks_root(start: Path) -> Path:
    """The project whose ledger to read: the nearest ancestor of `start` (itself
    included) with .propel/ or an installed task-queue.sh, else the git root / cwd."""
    start = start.resolve()
    for d in (start, *start.parents):
        if (d / ".propel").is_dir() or (d / TASK_QUEUE_REL).is_file():
            return d
    return get_project_root()


@cli.command(name="tasks")
@click.option("--all", "show_all", is_flag=True, help="Also show finished tasks (done, failed, abandoned).")
@click.option("--sessions", default=10, show_default=True, type=click.IntRange(min=1, max=1000),
              help="With --all: finished tasks come from the newest N session files of the "
                   "last 14 days. Open tasks are always shown.")
def tasks_cmd(show_all: bool, sessions: int):
    """Show the task ledger: training runs, plan tasks and monitor loops
    recorded by Claude sessions in this project (.propel/tasks/).

    One row per task, with its id, kind, status, progress, start time and the
    session that started it. By default only open tasks are listed (running,
    blocked, lost, unknown); --all adds recent finished ones. Read-only, apart
    from recording a done/failed result the script reads from a run's exit file.
    """
    root = _find_tasks_root(Path.cwd())
    if not (root / ".propel").is_dir():
        # No ledger here. Calling the script would make it walk further up and
        # read some ancestor's ledger instead.
        click.echo("No tasks recorded." if show_all else "No open tasks.")
        return
    script = root / TASK_QUEUE_REL
    if not script.is_file():
        try:
            script = get_propel_root() / "scripts" / "task-queue.sh"
        except FileNotFoundError:
            script = None
    if script is None or not script.is_file():
        raise click.ClickException(
            f"task-queue.sh not found in {root / TASK_QUEUE_REL} or the Propel clone; run `propel init`."
        )
    bash = shutil.which("bash")
    if bash is None:
        raise click.ClickException("bash not found on PATH; `propel tasks` needs it to read the ledger.")

    args = [bash, str(script), "list", "--table", "--sessions", str(sessions)]
    if not show_all:
        args.insert(4, "--open")
    # The script prefers $CLAUDE_PROJECT_DIR over its cwd; pin it to the root
    # found here so a stale value from the calling shell can't redirect the read.
    env = {**os.environ, "CLAUDE_PROJECT_DIR": str(root)}
    try:
        result = subprocess.run(
            args, cwd=root, env=env, capture_output=True, text=True, encoding="utf-8", errors="replace"
        )
    except KeyboardInterrupt:
        raise SystemExit(130)
    if result.stdout:
        click.echo(result.stdout, nl=False)
    if result.stderr:
        click.echo(result.stderr, nl=False, err=True)
    code = result.returncode
    raise SystemExit(128 - code if code < 0 else code)


_UNKNOWN = object()


def _registered_hooks(settings_path: Path):
    """The "hooks" object of a settings file ({} when absent), or _UNKNOWN if
    it cannot be read. Used to tell whether the child init changed them."""
    try:
        settings, _text = install.read_settings(settings_path)
    except Exception:  # noqa: BLE001 — only decides whether to print a hint
        return _UNKNOWN
    return settings.get("hooks", {})


def _installed_version() -> str | None:
    """Version of the installed `propel` distribution, or None if it has no metadata."""
    try:
        return importlib.metadata.version("propel")
    except importlib.metadata.PackageNotFoundError:
        return None


def _source_version(propel_root: Path) -> str | None:
    """`__version__` as written in the clone's src/propel_cli/__init__.py, or None.

    Read from the file, not imported: after a pull this process still holds the
    old module, and the file is what a reinstall would pick up.
    """
    try:
        text = (propel_root / "src" / "propel_cli" / "__init__.py").read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError):
        return None
    match = re.search(r"""(?m)^__version__\s*=\s*["']([^"']+)["']""", text)
    return match.group(1) if match else None


def _run_git(root: Path, *args: str) -> subprocess.CompletedProcess:
    """git -C root <args>, never raising; a missing git binary reads as returncode 127."""
    try:
        return subprocess.run(
            ["git", "-C", str(root), *args],
            capture_output=True,
            text=True,
        )
    except (FileNotFoundError, OSError) as exc:
        return subprocess.CompletedProcess(["git", *args], 127, "", str(exc))


@cli.command(name="update")
@click.option("--dry-run", is_flag=True, help="Show what would happen; changes no working files (may fetch from the remote).")
@click.option("--no-pull", is_flag=True, help="Skip the git pull; just re-apply this Propel to the project.")
@click.option("--yes", is_flag=True, help="Non-interactive; accepted for scripts and the console.")
def update_cmd(dry_run: bool, no_pull: bool, yes: bool):
    """Pull the latest Propel, reinstall if needed, and refresh this project.

    Runs `git pull --ff-only` in the Propel clone (refusing if its tracked
    files have local changes), reinstalls the package if the pull changed
    pyproject.toml or src/propel_cli/__init__.py, or if the installed
    package's version differs from the clone's __version__, then re-runs
    `propel init` here with the new code.
    """
    # --yes is a placeholder, as for init: nothing is asked today.
    del yes
    propel_root = get_propel_root()
    project_root = get_project_root()
    summary = []

    # a. Pull the clone.
    old_head = new_head = None
    if no_pull:
        summary.append("pull skipped")
    elif not install._is_dedicated_repo(propel_root):
        click.echo(f"Propel at {propel_root} is not a git clone; skipping pull")
        summary.append("not a git clone, pull skipped")
    else:
        porcelain = _run_git(propel_root, "status", "--porcelain", "--untracked-files=no")
        if porcelain.returncode != 0:
            raise click.ClickException(
                f"Could not check {propel_root} for local changes: {porcelain.stderr.strip()}"
            )
        dirty = [line for line in porcelain.stdout.splitlines() if line.strip()]
        if dirty:
            listing = "\n".join(f"  {line}" for line in dirty)
            raise click.ClickException(
                f"Propel at {propel_root} has local changes to tracked files:\n{listing}\n"
                "Commit or stash them, or use --no-pull."
            )
        head = _run_git(propel_root, "rev-parse", "HEAD")
        old_head = head.stdout.strip() if head.returncode == 0 else None
        if dry_run:
            fetch = _run_git(propel_root, "fetch")
            if fetch.returncode != 0:
                raise click.ClickException(f"git fetch failed in {propel_root}:\n{fetch.stderr.strip()}")
            behind = _run_git(propel_root, "rev-list", "--count", "HEAD..@{u}")
            if behind.returncode != 0:
                click.echo(f"Propel at {propel_root} has no upstream branch; nothing to pull")
                summary.append("no upstream")
            else:
                n = behind.stdout.strip()
                click.echo(f"Propel at {propel_root} is {n} commit(s) behind its upstream (not pulled: dry run)")
                summary.append(f"{n} commit(s) behind")
                if n != "0":
                    new_head = "@{u}"  # what the pull would move HEAD to
        else:
            click.echo(f"Pulling Propel in {propel_root}")
            pull = _run_git(propel_root, "pull", "--ff-only")
            if pull.returncode != 0:
                raise click.ClickException(
                    f"git pull --ff-only failed in {propel_root}:\n{(pull.stderr or pull.stdout).strip()}"
                )
            head = _run_git(propel_root, "rev-parse", "HEAD")
            new_head = head.stdout.strip() if head.returncode == 0 else None
            if old_head and new_head and old_head != new_head:
                count = _run_git(propel_root, "rev-list", "--count", f"{old_head}..{new_head}")
                n = count.stdout.strip() if count.returncode == 0 else "?"
                click.echo(f"  pulled {n} commit(s): {old_head[:7]}..{new_head[:7]}")
                summary.append(f"pulled {n} commit(s)")
            else:
                click.echo("  already up to date")
                summary.append("already up to date")

    # b. Reinstall the package if its metadata changed. The version lives in
    # __init__.py, and editable-install metadata is only refreshed by a reinstall.
    # Two triggers: (1) this run's pull changed pyproject.toml or __init__.py;
    # (2) the installed distribution's version differs from the clone's
    # __version__ — which also catches a manual `git pull` or --no-pull. A
    # dependency change without a version bump after a manual pull is missed.
    reinstall_failed = False
    reasons = []  # (why, what the real run says it does about it)
    if old_head and new_head and old_head != new_head:
        diff = _run_git(
            propel_root, "diff", "--quiet", old_head, new_head, "--",
            "pyproject.toml", "src/propel_cli/__init__.py",
        )
        if diff.returncode == 1:
            reasons.append(("pyproject.toml or __init__.py changed", "reinstalling the package"))
        elif diff.returncode != 0:
            reasons.append((
                f"could not compare pyproject.toml/__init__.py (git exit {diff.returncode})",
                "reinstalling to be safe",
            ))
    installed_version = _installed_version()
    source_version = _source_version(propel_root)
    if installed_version and source_version and installed_version != source_version:
        reasons.append((
            f"installed package is version {installed_version} but the clone is {source_version}",
            "reinstalling the package",
        ))
    if dry_run:
        for why, _ in reasons:
            click.echo(f"{why}; would reinstall the package (not done: dry run)")
        if reasons:
            summary.append("would reinstall")
    else:
        for why, action in reasons:
            click.echo(f"{why}; {action}")
        if reasons:
            try:
                pip = subprocess.run(
                    [sys.executable, "-m", "pip", "install", "-e", str(propel_root)],
                    capture_output=True,
                    text=True,
                )
                pip_failed = pip.returncode != 0
                pip_error = (pip.stderr or pip.stdout).strip()
            except OSError as exc:
                pip_failed = True
                pip_error = str(exc)
            if pip_failed:
                reinstall_failed = True
                click.echo(f"  Reinstall failed: {pip_error.splitlines()[-1] if pip_error else 'unknown error'}", err=True)
                click.echo("  Reinstall by hand, then re-run `propel update --no-pull`:", err=True)
                click.echo(f"    pip install -e {propel_root}     (inside the env you installed Propel into)", err=True)
                click.echo("    pipx reinstall propel             (if you installed it with pipx)", err=True)
                summary.append("reinstall failed — see above")
            else:
                click.echo("  reinstalled")
                summary.append("reinstalled")

    # c. Re-run init in a fresh interpreter, so the freshly pulled code runs.
    # A cheap existence check, not install.status(): this is the OLD code, and a
    # manifest-format change in the new code must not make it abort here.
    installed = (project_root / ".propel" / "manifest.json").exists() or (
        project_root / ".claude" / "skills" / "using-propel"
    ).is_dir()
    rc = 0
    hooks_changed = False
    if installed:
        # Strip '' / '.' from sys.path so a propel_cli/ in the project (the
        # child's cwd) can't shadow the installed package.
        cmd = [
            sys.executable,
            "-c",
            "import sys; sys.path[:] = [p for p in sys.path if p not in ('', '.')]; "
            "from propel_cli.cli import cli; cli(prog_name='propel')",
            "init",
        ]
        if dry_run:
            cmd.append("--dry-run")
        click.echo(f"\nRe-running `propel init{' --dry-run' if dry_run else ''}` in {project_root}\n")
        settings_path = project_root / ".claude" / "settings.local.json"
        hooks_before = _registered_hooks(settings_path)
        rc = subprocess.run(
            cmd, cwd=str(project_root), env={**os.environ, _RESTART_HINT_ENV: "1"}
        ).returncode
        hooks_after = _registered_hooks(settings_path)
        hooks_changed = (
            not dry_run and hooks_before is not _UNKNOWN and hooks_after is not _UNKNOWN
            and hooks_before != hooks_after
        )
        summary.append(f"init {'dry run ' if dry_run else ''}{'ok' if rc == 0 else f'failed (exit {rc})'}")
    else:
        click.echo(f"No Propel install in {project_root}; run `propel init` there to install.")
        summary.append("project not installed")

    # d. Summary. init's own failure wins; otherwise a failed reinstall is exit 1.
    click.echo(f"\nUpdate{' (dry run)' if dry_run else ''}: {'; '.join(summary)}.")
    if hooks_changed:
        click.echo(RESTART_HINT)
    if rc != 0:
        raise SystemExit(rc)
    if reinstall_failed:
        raise SystemExit(1)


# ---------------------------------------------------------------------------
# propel codex
# ---------------------------------------------------------------------------


OUTCOME_LABEL = {
    "reply": "reply",
    "no-findings": "no findings",
    "unavailable": "UNAVAILABLE",
    "disabled": "disabled",
}


def _codex_log_path() -> Path:
    return get_project_root() / ".propel" / "codex-log.jsonl"


def _read_codex_log() -> list[dict]:
    """Read the consult ledger, skipping any line that isn't parseable.

    A corrupt line is never fatal. The ledger's value is that it exists at all;
    losing one entry to a partial write is better than refusing to show the rest.
    """
    path = _codex_log_path()
    if not path.exists():
        return []
    entries = []
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            entries.append(json.loads(line))
        except (json.JSONDecodeError, ValueError):
            continue
    return entries


@cli.group()
def codex():
    """Inspect the dual-model layer \u2014 what Codex was asked, and when."""
    pass


@codex.command(name="log")
@click.option("-n", "--number", default=20, help="How many recent consults to show.")
@click.option("--all", "show_all", is_flag=True, help="Show every recorded consult.")
@click.option("--json", "as_json", is_flag=True, help="Emit raw JSONL instead of a table.")
@click.option("-q", "--questions", is_flag=True, help="Also show the question sent each time.")
def codex_log(number: int, show_all: bool, as_json: bool, questions: bool):
    """Show the Codex consult audit trail for this project.

    This ledger is written by scripts/codex-consult.sh, not by a model. That is
    the point of it: a gate that claimed a Codex consult with no matching entry
    here did not consult Codex.
    """
    entries = _read_codex_log()

    if not entries:
        click.echo("\nNo Codex consults recorded in this project yet.")
        click.echo(f"Ledger: {_codex_log_path()}")
        click.echo(
            "\nIf a session claimed to consult Codex and nothing is here, "
            "the consult did not happen."
        )
        return

    shown = entries if show_all else entries[-number:]

    if as_json:
        for e in shown:
            click.echo(json.dumps(e))
        return

    click.echo("")
    click.echo(f"  {'TIME':<10}{'GATE':<26}{'OUTCOME':<14}TOOK")
    for e in shown:
        ts = (e.get("ts") or "")[11:19] or "--:--:--"
        label = (e.get("label") or "?")[:24]
        outcome = OUTCOME_LABEL.get(e.get("outcome", ""), e.get("outcome") or "?")
        took = e.get("duration_s")
        took_s = f"{took}s" if took is not None else "--"
        click.echo(f"  {ts:<10}{label:<26}{outcome:<14}{took_s}")
        if e.get("outcome") in ("unavailable", "disabled") and e.get("detail"):
            click.echo(f"  {'':<10}\u2514 {e['detail']}")
        if questions and e.get("question"):
            click.echo(f"  {'':<10}\u2514 asked: {e['question']}")

    total = len(entries)
    replies = sum(1 for e in entries if e.get("outcome") in ("reply", "no-findings"))
    unavailable = sum(1 for e in entries if e.get("outcome") == "unavailable")
    disabled = sum(1 for e in entries if e.get("outcome") == "disabled")

    parts = [f"{total} consult{'s' if total != 1 else ''}", f"{replies} replied"]
    if unavailable:
        parts.append(f"{unavailable} unavailable")
    if disabled:
        parts.append(f"{disabled} skipped (disabled)")
    click.echo("")
    click.echo("  " + " \u00b7 ".join(parts))
    if not show_all and len(entries) > len(shown):
        click.echo(f"  showing last {len(shown)} \u2014 use --all for the rest")
    click.echo("")


GLOBAL_DIR = Path.home() / ".claude" / "propel"
SEGMENT_SCRIPTS = (
    "propel-statusline.sh",   # the wrapper Claude Code invokes
    "codex-statusline.sh",    # the one-line session segment
    "codex-tasks.sh",         # the Codex task block
)
PREV_STATUSLINE = GLOBAL_DIR / "previous-statusline.json"


def _sync_global_scripts(propel_root: Path) -> list[str]:
    """Copy the status-line scripts outside the clone, so moving the repo can't
    break the status line. Returns the names that changed."""
    changed = []
    GLOBAL_DIR.mkdir(parents=True, exist_ok=True)
    for name in SEGMENT_SCRIPTS:
        src = propel_root / "scripts" / name
        if not src.exists():
            continue
        dst = GLOBAL_DIR / name
        if not dst.exists() or dst.read_bytes() != src.read_bytes():
            shutil.copy2(src, dst)
            changed.append(name)
        dst.chmod(dst.stat().st_mode | 0o111)
    return changed


@codex.command(name="statusline")
@click.option("--install", "do_install", is_flag=True,
              help="Actually modify ~/.claude/settings.json (a backup is written first).")
@click.option("--remove", "do_remove", is_flag=True, help="Restore the previous status line.")
def codex_statusline(do_install: bool, do_remove: bool):
    """Show Codex state and in-flight consults in your Claude Code status line.

    Adds two things: a segment on the session line reading `codex * 4 . 3s`
    (enabled, four consults today, last one three seconds ago), and a block
    beneath claude-hud's agents line showing the consults themselves.

    Without --install this only prints what it would do.
    """
    settings_path = Path.home() / ".claude" / "settings.json"
    wrapper = GLOBAL_DIR / "propel-statusline.sh"
    wrapper_cmd = f"bash {wrapper}"

    try:
        settings = json.loads(settings_path.read_text()) if settings_path.exists() else {}
    except (json.JSONDecodeError, ValueError):
        click.echo(f"Could not parse {settings_path} - fix it before wiring anything in.", err=True)
        raise SystemExit(1)

    status_line = settings.get("statusLine") or {}
    command = status_line.get("command", "") if isinstance(status_line, dict) else ""
    installed = wrapper_cmd in command

    # ---- remove: put back exactly what was there before ----------------
    if do_remove:
        if not installed:
            click.echo("\nPropel's status line isn't installed. Nothing to remove.\n")
            return
        backup = settings_path.with_suffix(".json.propel-bak")
        backup.write_text(settings_path.read_text())
        previous = None
        if PREV_STATUSLINE.exists():
            try:
                previous = json.loads(PREV_STATUSLINE.read_text()).get("statusLine")
            except (json.JSONDecodeError, ValueError):
                previous = None
        if previous:
            settings["statusLine"] = previous
            click.echo("\nRestored your previous status line.")
        else:
            settings.pop("statusLine", None)
            click.echo("\nRemoved the status line (no previous one was recorded).")
        settings_path.write_text(json.dumps(settings, indent=2) + "\n")
        click.echo(f"Backup of the replaced file: {backup}\n")
        return

    # ---- already installed --------------------------------------------
    if installed:
        changed = _sync_global_scripts(get_propel_root())
        click.echo("\nAlready installed. Your status line runs:")
        click.echo(f"  {wrapper_cmd}")
        if changed:
            click.echo(f"\n  Refreshed: {', '.join(changed)}")
        click.echo("\nUndo with: propel codex statusline --remove\n")
        return

    has_hud = "claude-hud" in command or "dist/index.js" in command

    click.echo("\nThis will:\n")
    click.echo(f"  1. copy the status-line scripts to {GLOBAL_DIR}/")
    click.echo("     (outside the propel clone, so moving the repo can't break it)")
    click.echo(f"  2. record your current status line so --remove can restore it")
    click.echo(f"  3. set statusLine.command in {settings_path} to:")
    click.echo(f"       {wrapper_cmd}")
    click.echo("  4. back up the current settings.json first\n")

    if has_hud:
        click.echo("  Your claude-hud status line is preserved: the wrapper runs hud")
        click.echo("  first, prints its output unchanged, then appends the Codex block")
        click.echo("  underneath. If hud ever fails, the Codex block still renders.\n")
    else:
        click.echo("  You don't appear to run claude-hud. The wrapper will still work -")
        click.echo("  it just prints the Codex block on its own. Install claude-hud from")
        click.echo("  `propel launch` for the full status line.\n")

    click.echo("  In a project without .propel/, nothing Codex-related is printed.\n")

    if not do_install:
        click.echo("  Dry run. Re-run with --install to apply.\n")
        return

    propel_root = get_propel_root()
    if not (propel_root / "scripts" / "propel-statusline.sh").exists():
        click.echo("Status-line scripts missing from the propel source tree.", err=True)
        raise SystemExit(1)

    _sync_global_scripts(propel_root)

    if command:
        PREV_STATUSLINE.write_text(
            json.dumps({"statusLine": status_line, "saved_at": datetime.now().isoformat()},
                       indent=2) + "\n"
        )

    if settings_path.exists():
        backup = settings_path.with_suffix(".json.propel-bak")
        backup.write_text(settings_path.read_text())
    else:
        backup = None

    settings["statusLine"] = {"type": "command", "command": wrapper_cmd}
    settings_path.parent.mkdir(parents=True, exist_ok=True)
    settings_path.write_text(json.dumps(settings, indent=2) + "\n")

    click.echo("  Done.")
    if backup:
        click.echo(f"  Backup: {backup}")
    click.echo("  Open a new Claude Code session to see it.")
    click.echo("  Undo with: propel codex statusline --remove\n")


@codex.command(name="status")
def codex_status():
    """Show whether the dual-model layer is on, reachable, and being used."""
    root = get_project_root()
    config_path = root / ".propel" / "codex.json"

    enabled = True
    available = None
    if config_path.exists():
        try:
            cfg = json.loads(config_path.read_text())
            enabled = install.codex_enabled(cfg)
            available = cfg.get("available") if isinstance(cfg, dict) else None
        except (json.JSONDecodeError, ValueError):
            pass

    from .launcher import tool_path

    cli_path = tool_path("codex")

    click.echo("")
    click.echo(f"  project      {root}")
    click.echo(f"  enabled      {'yes' if enabled else 'no  (/enable-codex to turn on)'}")
    if cli_path:
        code, out = 0, ""
        try:
            proc = subprocess.run(
                [cli_path, "--version"], capture_output=True, text=True, timeout=10
            )
            out = (proc.stdout + proc.stderr).strip().splitlines()[0]
        except Exception:
            out = "installed"
        click.echo(f"  cli          {cli_path}  ({out})")
    else:
        click.echo("  cli          NOT FOUND \u2014 run `propel` to install it")

    if available is False and cli_path:
        click.echo(
            "  note         config says unavailable from an earlier session; "
            "run /enable-codex to re-check"
        )

    entries = _read_codex_log()
    if entries:
        last = entries[-1]
        click.echo(f"  consults     {len(entries)} recorded")
        click.echo(
            f"  last         {last.get('label') or '?'} "
            f"at {(last.get('ts') or '')[:19]} \u2014 {last.get('outcome')}"
        )
    else:
        click.echo("  consults     none recorded yet")
    click.echo("")
    click.echo("  Full trail:  propel codex log")
    click.echo("")


# ---------------------------------------------------------------------------
# propel session
# ---------------------------------------------------------------------------


@cli.group()
def session():
    """Manage Claude Code sessions — launch, save, and list."""
    pass


@session.command(name="launch")
@click.argument("description", nargs=-1, required=True)
def session_launch(description: str):
    """Create a new session directory and launch Claude Code.

    DESCRIPTION: A short description of the session (e.g., "RVQ depth-2 rotation experiment")
    """
    description_str = " ".join(description)
    slug = slugify(description_str)
    now = datetime.now()
    date_prefix = now.strftime("%-m-%-d-%y")

    session_name = f"{date_prefix}-{slug}"
    sessions_dir = get_sessions_dir()
    session_dir = sessions_dir / session_name

    if session_dir.exists():
        click.echo(f"Session directory already exists: {session_dir}", err=True)
        raise SystemExit(1)

    session_dir.mkdir(parents=True)

    # Generate session UUID
    session_id = str(uuid.uuid4())
    (session_dir / ".session_id").write_text(session_id)

    # Create prompt template
    create_prompt_template(session_dir, description_str)

    # Link to active investigation
    link_investigation(session_dir)

    # Update index
    update_index(sessions_dir, session_name, description_str)

    click.echo(f"Created session: {session_dir}")
    click.echo(f"Session ID: {session_id}")
    click.echo(f"Prompt template: {session_dir / 'prompt.md'}")

    # Launch Claude Code with the session ID
    from .launcher import tool_path

    click.echo(f"\nLaunching Claude Code...")
    try:
        subprocess.run(
            [tool_path("claude") or "claude", "--session-id", session_id],
            cwd=get_project_root(),
        )
    except FileNotFoundError:
        click.echo("Claude Code CLI not found. Install it with `propel setup`, then run:")
        click.echo(f"  claude --session-id {session_id}")
        return

    # After Claude exits, save chat history
    click.echo("\nSaving chat history...")
    if save_chat_history(session_id, session_dir):
        click.echo(f"Chat history saved to {session_dir / 'chat_history.jsonl'}")
    else:
        click.echo("Could not find chat history to save.")


@session.command()
@click.argument("session_id")
@click.argument("session_dir", type=click.Path())
def save(session_id: str, session_dir: str):
    """Save chat history for an existing session.

    SESSION_ID: The UUID of the Claude Code session
    SESSION_DIR: Path to the session directory
    """
    session_path = Path(session_dir)
    if not session_path.exists():
        click.echo(f"Session directory not found: {session_path}", err=True)
        raise SystemExit(1)

    if save_chat_history(session_id, session_path):
        click.echo(f"Chat history saved to {session_path / 'chat_history.jsonl'}")
    else:
        click.echo("Could not find chat history to save.", err=True)
        raise SystemExit(1)


@session.command(name="list")
def list_sessions():
    """List all recorded sessions."""
    sessions_dir = get_sessions_dir()
    index_path = sessions_dir / "INDEX.md"

    if index_path.exists():
        click.echo(index_path.read_text())
    else:
        click.echo("No sessions recorded yet.")
        click.echo('Create one with: propel session launch "my experiment"')


if __name__ == "__main__":
    cli()
