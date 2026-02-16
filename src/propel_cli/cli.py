"""Propel CLI — init and session management for Claude Code research workflows.

Adapted from scott-yj-yang/new-prompt with:
- `propel init` to auto-scaffold .claude/ in any project
- Auto-detection of project root via git rev-parse (no hardcoded paths)
- Investigation artifact linking (scratch/ symlinks)
- Session index maintenance (sessions/INDEX.md)
"""

import json
import os
import re
import shutil
import subprocess
import uuid
from datetime import datetime
from pathlib import Path

import click


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
        "Make sure you installed with `pip install -e .` from the propel directory."
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
    except subprocess.CalledProcessError:
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


def copytree_merge(src: Path, dst: Path) -> int:
    """Copy src tree into dst, merging directories and overwriting files.

    Returns the number of files copied.
    """
    count = 0
    for item in src.rglob("*"):
        if item.is_file():
            rel = item.relative_to(src)
            dest = dst / rel
            dest.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(item, dest)
            count += 1
    return count


def merge_hooks_config(settings_path: Path, hooks_config: list[dict]) -> None:
    """Create or merge hook entries into .claude/settings.local.json.

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
    """
    if settings_path.exists():
        try:
            settings = json.loads(settings_path.read_text())
        except (json.JSONDecodeError, ValueError):
            settings = {}
    else:
        settings = {}

    existing_hooks = settings.get("hooks", {})

    for hook in hooks_config:
        event = hook["event"]
        command = hook["command"]

        # Build a matcher group in the new format
        matcher_group = {
            "matcher": "",
            "hooks": [{"type": "command", "command": command}],
        }

        if event not in existing_hooks:
            existing_hooks[event] = []

        # Skip if an identical command is already registered
        existing_commands = []
        for group in existing_hooks[event]:
            for h in group.get("hooks", []):
                existing_commands.append(h.get("command", ""))
        if command not in existing_commands:
            existing_hooks[event].append(matcher_group)

    settings["hooks"] = existing_hooks
    settings_path.write_text(json.dumps(settings, indent=2) + "\n")


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


@click.group()
def cli():
    """Propel — research workflow CLI for Claude Code."""
    pass


# ---------------------------------------------------------------------------
# propel init
# ---------------------------------------------------------------------------


@cli.command()
def init():
    """Set up .claude/ with Propel skills, agents, commands, and hooks."""
    propel_root = get_propel_root()
    project_root = get_project_root()
    claude_dir = project_root / ".claude"

    click.echo(f"Initializing Propel in {project_root}")
    click.echo(f"Using Propel data from {propel_root}\n")

    # Copy skills, agents, commands, hooks
    dirs_to_copy = ["skills", "agents", "commands", "hooks"]
    total_files = 0

    for dirname in dirs_to_copy:
        src = propel_root / dirname
        dst = claude_dir / dirname
        if src.is_dir():
            count = copytree_merge(src, dst)
            total_files += count
            click.echo(f"  {dirname}/ — {count} files")
        else:
            click.echo(f"  {dirname}/ — not found in propel, skipped")

    # Merge hooks into settings.local.json
    hooks_json = propel_root / "hooks" / "hooks.json"
    if hooks_json.exists():
        hooks_config = json.loads(hooks_json.read_text()).get("hooks", [])
        # Rewrite hook commands to use .claude/ relative paths
        for hook in hooks_config:
            hook["command"] = hook["command"].replace(
                "bash hooks/", "bash .claude/hooks/"
            )
        settings_path = claude_dir / "settings.local.json"
        merge_hooks_config(settings_path, hooks_config)
        click.echo(f"\n  settings.local.json — hooks configured")

    # Update .gitignore
    added = ensure_gitignore_entries(project_root, ["scratch/", "sessions/"])
    if added:
        click.echo(f"  .gitignore — added {', '.join(added)}")
    else:
        click.echo(f"  .gitignore — already up to date")

    click.echo(f"\nDone! {total_files} files installed into {claude_dir}/")
    click.echo("Run `claude` to start using Propel.")


# ---------------------------------------------------------------------------
# propel session
# ---------------------------------------------------------------------------


@cli.group()
def session():
    """Manage Claude Code sessions — launch, save, and list."""
    pass


@session.command()
@click.argument("description", nargs=-1, required=True)
def launch(description: str):
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
    click.echo(f"\nLaunching Claude Code...")
    try:
        subprocess.run(
            ["claude", "--session-id", session_id],
            cwd=get_project_root(),
        )
    except FileNotFoundError:
        click.echo("Claude Code CLI not found. Run manually with:")
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
