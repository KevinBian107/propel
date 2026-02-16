"""Propel session management CLI.

Adapted from scott-yj-yang/new-prompt with:
- Auto-detection of project root via git rev-parse (no hardcoded paths)
- Investigation artifact linking (scratch/ symlinks)
- Session index maintenance (sessions/INDEX.md)
"""

import os
import re
import subprocess
import uuid
from datetime import datetime
from pathlib import Path

import click


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
        # Fallback to current directory if not in a git repo
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
            pass  # Symlinks may not work on all systems


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

    # Search for the session's chat history in Claude's project directories
    for project_dir in claude_dir.rglob("*"):
        if not project_dir.is_dir():
            continue
        history_file = project_dir / f"{session_id}.jsonl"
        if history_file.exists():
            dest = session_dir / "chat_history.jsonl"
            dest.write_bytes(history_file.read_bytes())
            return True

    return False


@click.group()
def cli():
    """Propel session management — archive and index Claude Code sessions."""
    pass


@cli.command()
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


@cli.command()
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


@cli.command(name="list")
def list_sessions():
    """List all recorded sessions."""
    sessions_dir = get_sessions_dir()
    index_path = sessions_dir / "INDEX.md"

    if index_path.exists():
        click.echo(index_path.read_text())
    else:
        click.echo("No sessions recorded yet.")
        click.echo(f"Create one with: propel-session launch \"my experiment\"")


if __name__ == "__main__":
    cli()
