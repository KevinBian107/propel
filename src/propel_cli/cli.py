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


VALID_HOOK_EVENTS = {
    "SessionStart",
    "UserPromptSubmit",
    "PreToolUse",
    "PermissionRequest",
    "PostToolUse",
    "PostToolUseFailure",
    "Notification",
    "SubagentStart",
    "SubagentStop",
    "Stop",
    "TeammateIdle",
    "TaskCompleted",
    "PreCompact",
    "SessionEnd",
}


def _is_new_format_group(entry: dict) -> bool:
    """Check if a hook entry uses the new matcher+hooks format."""
    return "hooks" in entry and isinstance(entry["hooks"], list)


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

    Also cleans up invalid event names and old-format entries left from
    previous installs.
    """
    if settings_path.exists():
        try:
            settings = json.loads(settings_path.read_text())
        except (json.JSONDecodeError, ValueError):
            settings = {}
    else:
        settings = {}

    existing_hooks = settings.get("hooks", {})

    # Remove invalid event names (e.g. SessionResume, PostClear, PostCompact)
    for key in list(existing_hooks.keys()):
        if key not in VALID_HOOK_EVENTS:
            del existing_hooks[key]

    # Remove old-format entries (flat {"command": "..."} without matcher+hooks)
    for event in list(existing_hooks.keys()):
        existing_hooks[event] = [
            e for e in existing_hooks[event] if _is_new_format_group(e)
        ]

    # Add new hooks
    for hook in hooks_config:
        event = hook["event"]
        command = hook["command"]
        matcher = hook.get("matcher", "")

        matcher_group = {
            "matcher": matcher,
            "hooks": [{"type": "command", "command": command}],
        }

        if event not in existing_hooks:
            existing_hooks[event] = []

        # Skip if the same command is already registered under the same matcher.
        # (matcher, command) rather than command alone — the same script can
        # legitimately be registered under two different tool matchers.
        existing_pairs = set()
        for group in existing_hooks[event]:
            for h in group.get("hooks", []):
                existing_pairs.add((group.get("matcher", ""), h.get("command", "")))
        if (matcher, command) not in existing_pairs:
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


def _cleanup_stale_files(claude_dir: Path, propel_root: Path) -> None:
    """Remove files from previous installs that no longer exist in propel source.

    For each Propel-managed directory, any file in the installed .claude/ copy
    that doesn't have a corresponding file in the current propel source gets
    removed. This handles renames (e.g. commands moved into a subdirectory).
    """
    dirs_to_check = ["skills", "agents", "commands", "hooks", "core", "scripts"]
    removed = 0

    for dirname in dirs_to_check:
        src = propel_root / dirname
        dst = claude_dir / dirname
        if not dst.is_dir() or not src.is_dir():
            continue

        for installed_file in list(dst.rglob("*")):
            if not installed_file.is_file():
                continue
            rel = installed_file.relative_to(dst)
            if not (src / rel).exists():
                installed_file.unlink()
                removed += 1

        # Remove empty directories left behind
        for d in sorted(dst.rglob("*"), reverse=True):
            if d.is_dir() and not any(d.iterdir()):
                d.rmdir()

    if removed:
        click.echo(f"  Cleaned up {removed} stale file(s) from previous install\n")


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------


@click.group(invoke_without_command=True)
@click.pass_context
def cli(ctx):
    """Propel — research workflow CLI for Claude Code.

    Run `propel` with no arguments to open the setup console.
    """
    if ctx.invoked_subcommand is None:
        ctx.invoke(launch)


# ---------------------------------------------------------------------------
# propel launch
# ---------------------------------------------------------------------------


@cli.command()
@click.option("--no-browser", is_flag=True, help="Print the URL instead of opening a browser.")
@click.option("--port", default=0, type=int, help="Bind to a specific port (default: random).")
def launch(no_browser: bool, port: int):
    """Open the Propel setup console in your browser.

    Detects Claude Code, Codex, node and git; installs what's missing; opens a
    terminal for the two logins that genuinely need one; and installs Propel
    into the current project.
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

    # Clean up stale files from previous installs before copying
    _cleanup_stale_files(claude_dir, propel_root)

    # Copy skills, agents, commands, hooks
    dirs_to_copy = ["skills", "agents", "commands", "hooks", "core", "scripts"]
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
            ).replace("bash scripts/", "bash .claude/scripts/")
        settings_path = claude_dir / "settings.local.json"
        merge_hooks_config(settings_path, hooks_config)
        click.echo(f"\n  settings.local.json — hooks configured")

    # Create CLAUDE.md template if one doesn't exist
    claude_md = claude_dir / "CLAUDE.md"
    template = propel_root / "templates" / "CLAUDE.md"
    if not claude_md.exists() and template.exists():
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

    # Shell helpers must stay executable through the copy
    for sh in list((claude_dir / "hooks").glob("*.sh")) + list(
        (claude_dir / "scripts").glob("*.sh")
    ):
        sh.chmod(sh.stat().st_mode | 0o111)

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

    click.echo(f"\nDone! {total_files} files installed into {claude_dir}/")
    click.echo("Run `propel launch` to check your Claude Code / Codex setup,")
    click.echo("or `claude` to start working.")


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
            enabled = cfg.get("enabled", True)
            available = cfg.get("available")
        except (json.JSONDecodeError, ValueError):
            pass

    cli_path = shutil.which("codex")

    click.echo("")
    click.echo(f"  project      {root}")
    click.echo(f"  enabled      {'yes' if enabled else 'no  (/enable-codex to turn on)'}")
    if cli_path:
        code, out = 0, ""
        try:
            proc = subprocess.run(
                ["codex", "--version"], capture_output=True, text=True, timeout=10
            )
            out = (proc.stdout + proc.stderr).strip().splitlines()[0]
        except Exception:
            out = "installed"
        click.echo(f"  cli          {cli_path}  ({out})")
    else:
        click.echo("  cli          NOT FOUND on PATH \u2014 run `propel` and click Install Codex")

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
