"""Propel terminal setup — the headless twin of the browser console.

`propel setup` (or bare `propel` on a machine with no display: a cluster node,
a container, a Jupyter terminal, anything over SSH) walks the same checklist as
`propel launch`, in the terminal:

  * shows what is installed and signed in
  * installs Claude Code and Codex with the vendors' native installers into
    ~/.local/bin — no Node, no npm, no sudo
  * signs in inline: `claude auth login` and `codex login --device-auth` both
    print a URL you open on any device, so this machine needs no browser
  * offers the optional plugins, default No — whose code runs in your session
    is a judgment call, so it stays yours
  * runs `propel init` in the current project

Detection and install specs are shared with launcher.py, so the two paths
cannot drift apart. It only asks questions when stdin and stdout are a real
terminal. Piped, under CI, or from a notebook `!propel`, it prints the
checklist and the commands to run, and exits 0.
"""

from __future__ import annotations

import shlex
import shutil
import subprocess
import sys

import click

from .launcher import (
    LOCAL_BIN,
    NATIVE_INSTALLERS,
    PLUGINS,
    claude_signed_in,
    codex_signed_in,
    collect_status,
    local_bin_on_path,
    login_argv,
    native_install,
    path_line,
    plugin_install_cmd,
    plugin_note,
    shell_rc,
    tool_path,
    _project_root,
    _self_command,
)

OK = click.style("✓", fg="green")
BAD = click.style("✗", fg="red")
WARN = click.style("!", fg="yellow")
OFF = click.style("–", fg="bright_black")


def _ask(question: str, default: bool) -> bool:
    try:
        return click.confirm(question, default=default)
    except click.Abort:
        raise KeyboardInterrupt


def _run_live(cmd: list[str], env: dict[str, str] | None = None, cwd: str | None = None) -> int:
    """Run with this terminal's stdin/stdout, so prompts and URLs reach the user."""
    try:
        return subprocess.call(cmd, env=env, cwd=cwd)
    except FileNotFoundError:
        return 127


def _auth_label(auth: bool | None) -> str:
    if auth is True:
        return "signed in"
    if auth is False:
        return "not signed in"
    return "sign-in status unknown"


def _print_status(status: dict) -> None:
    click.echo("")
    for t in status["tools"]:
        if t["ok"] and (not t["has_auth"] or t["auth"] is True):
            mark = OK
        elif t["ok"]:
            mark = WARN
        elif t["required"]:
            mark = BAD
        else:
            mark = OFF
        detail = t["version"] or "not installed"
        if t["ok"] and t["has_auth"]:
            detail += f" · {_auth_label(t['auth'])}"
        tag = "" if t["required"] else click.style("  (optional)", fg="bright_black")
        click.echo(f"  {mark} {t['name']:<14} {detail}{tag}")

    for p in status["plugins"]:
        mark = OK if p["installed"] else OFF
        state = "installed" if p["installed"] else "not installed"
        click.echo(
            f"  {mark} {p['name']:<14} {state}"
            + click.style(f"  (optional plugin, by {p['publisher']})", fg="bright_black")
        )

    proj = status["project"]
    mark = OK if proj["initialized"] else OFF
    state = "Propel installed" if proj["initialized"] else "Propel not installed yet"
    click.echo(f"  {mark} {'project':<14} {state} — {proj['root']}")
    click.echo("")


def _tools(status: dict) -> dict:
    return {t["key"]: t for t in status["tools"]}


def _print_manual_steps(status: dict) -> None:
    """Everything the interactive path would do, as commands to paste."""
    tools = _tools(status)
    steps: list[str] = []      # needed to work at all
    optional: list[str] = []   # Codex: Propel runs single-model without it

    if not tools["claude"]["ok"]:
        spec = NATIVE_INSTALLERS["claude"]
        steps.append(f"curl -fsSL {spec['url']} | {spec['shell']}")
    if not tools["codex"]["ok"]:
        spec = NATIVE_INSTALLERS["codex"]
        optional.append(f"curl -fsSL {spec['url']} | {spec['shell']}")
        optional.append("codex login --device-auth")
    elif tools["codex"]["auth"] is not True:
        optional.append("codex login --device-auth")
    # Only when a tool actually lives (or is about to live) in ~/.local/bin.
    uses_local_bin = any((LOCAL_BIN / b).exists() for b in ("claude", "codex")) or not tools["claude"]["ok"]
    if uses_local_bin and not local_bin_on_path():
        steps.append(f"echo '{path_line()}' >> {shell_rc()}   # new shells")
        steps.append(f"{path_line()}   # this shell")
    if tools["claude"]["auth"] is not True:
        steps.append("claude auth login")
    if not status["project"]["initialized"]:
        steps.append(f"cd {shlex.quote(status['project']['root'])} && propel init")

    if not steps and not optional:
        click.echo("  Everything is set up. Start with: claude\n")
        return
    if steps:
        click.echo("  This isn't an interactive terminal, so nothing was changed.")
        click.echo("  Run `propel setup` in a terminal to be walked through it, or do it by hand:\n")
        for s in steps:
            click.echo(f"    {s}")
        click.echo("")
    else:
        click.echo("  Ready to go: start with `claude`.")
    if optional:
        click.echo("  Optional, for the second model (Codex):\n")
        for s in optional:
            click.echo(f"    {s}")
        click.echo("")


# ---------------------------------------------------------------------------
# Steps
# ---------------------------------------------------------------------------


def _install_tools(status: dict) -> None:
    tools = _tools(status)

    if not tools["git"]["ok"]:
        click.echo(
            f"  {BAD} git is missing. Propel doesn't run sudo for you — install it with your\n"
            "    system package manager (apt, dnf, conda install git) or ask your admin.\n"
        )

    for key, default, why in (
        ("claude", True, "required — the agent Propel runs inside"),
        ("codex", True, "optional — the second model Propel consults at every gate"),
    ):
        if tools[key]["ok"]:
            continue
        spec = NATIVE_INSTALLERS[key]
        click.echo(f"  {spec['name']} is not installed ({why}).")
        click.echo(f"    Installer: curl -fsSL {spec['url']} | {spec['shell']}  ->  {LOCAL_BIN}")
        if not _ask(f"  Install {spec['name']} now?", default):
            click.echo("")
            continue
        result = native_install(key)
        if isinstance(result, str):
            click.echo(f"  {BAD} {result}\n")
            continue
        cmd, env, _ = result
        click.echo("")
        rc = _run_live(cmd, env=env)
        if rc == 0 and tool_path(key):
            click.echo(f"\n  {OK} {spec['name']} installed.\n")
        else:
            click.echo(
                f"\n  {BAD} The installer exited {rc}; its output is above. If it couldn't\n"
                "    download, this machine may have no outbound internet — check https_proxy,\n"
                "    or run setup from a login node.\n"
            )


def _fix_path() -> None:
    have_local = any((LOCAL_BIN / b).exists() for b in ("claude", "codex"))
    if not have_local or local_bin_on_path():
        return
    rc = shell_rc()
    line = path_line()
    click.echo(f"  {WARN} {LOCAL_BIN} is not on your PATH, so new shells won't find claude/codex.")
    already = rc.exists() and line in rc.read_text(errors="replace")
    if already:
        click.echo(f"    {rc} already has the line; open a new shell to pick it up.\n")
        return
    if _ask(f"  Add `{line}` to {rc}?", True):
        rc.parent.mkdir(parents=True, exist_ok=True)
        with rc.open("a") as f:
            f.write(f"\n# Added by propel setup\n{line}\n")
        click.echo(f"  {OK} Added. New shells will have it; for this one run:\n    {line}\n")
    else:
        click.echo(f"    Skipped. To fix it later:  echo '{line}' >> {rc}\n")


def _sign_in() -> None:
    # Claude Code
    exe = tool_path("claude")
    if exe:
        auth = claude_signed_in()
        if auth is not True:
            click.echo(f"  Claude Code: {_auth_label(auth)}.")
            click.echo(
                "    It prints a URL — open it on any device (your laptop is fine), approve,\n"
                "    and paste the code back here if it asks for one."
            )
            if _ask("  Sign in to Claude Code now?", True):
                click.echo("")
                _run_live(login_argv("login-claude") or [exe, "auth", "login"])
                after = claude_signed_in()
                mark = OK if after is True else WARN
                click.echo(f"\n  {mark} Claude Code: {_auth_label(after)}.\n")
            else:
                click.echo("    Later:  claude auth login\n")

    # Codex — device code, because its default flow waits for a browser
    # callback on localhost:1455 of *this* machine.
    exe = tool_path("codex")
    if exe:
        auth = codex_signed_in()
        if auth is not True:
            click.echo(f"  Codex: {_auth_label(auth)}.")
            click.echo("    Device sign-in: it shows a URL and a one-time code to enter on any device.")
            if _ask("  Sign in to Codex now?", True):
                click.echo("")
                rc = _run_live([exe, "login", "--device-auth"])
                after = codex_signed_in()
                if after is True:
                    click.echo(f"\n  {OK} Codex: signed in.\n")
                else:
                    click.echo(
                        f"\n  {WARN} Codex sign-in didn't complete (exit {rc}). Other routes:\n"
                        "    • browser flow over a tunnel: on your laptop run\n"
                        "        ssh -L 1455:localhost:1455 <this-host>\n"
                        "      then here:  codex login\n"
                        "    • API key:  printenv OPENAI_API_KEY | codex login --with-api-key\n"
                        "    Propel runs single-model until Codex is signed in. It never blocks.\n"
                    )
            else:
                click.echo("    Later:  codex login --device-auth\n")


def _plugins(status: dict) -> None:
    tools = _tools(status)
    exe = tool_path("claude")
    pending = [p for p in status["plugins"] if not p["installed"]]
    if not pending or exe is None:
        return
    click.echo("  Optional plugins. Each runs its publisher's code in your Claude Code")
    click.echo("  sessions, so Propel never installs one without asking.\n")
    for p in pending:
        entry = next(e for e in PLUGINS if e["key"] == p["key"])
        click.echo(f"  {p['name']} — by {p['publisher']}. {p['blurb']}")
        needs = p.get("needs")
        if needs and not tools.get(needs, {}).get("ok"):
            click.echo(f"    Skipped: needs {needs}, which isn't installed.\n")
            continue
        if _ask(f"  Install {p['name']}?", False):
            click.echo("")
            click.echo(plugin_note(entry), nl=False)
            rc = _run_live(plugin_install_cmd(entry, exe))
            click.echo(f"\n  {OK if rc == 0 else BAD} {p['name']}: {'installed' if rc == 0 else f'exited {rc}'}.\n")
        else:
            click.echo("")


def _init_project(status: dict) -> None:
    proj = status["project"]
    if proj["initialized"]:
        return
    root = proj["root"]
    if not proj["is_git"]:
        click.echo(f"  {WARN} {root} is not a git repository. Propel works best inside one.")
    if _ask(f"  Install Propel into {root}?", True):
        click.echo("")
        _run_live(_self_command(["init"]), cwd=root)
        click.echo("")
    else:
        click.echo(f"    Later:  cd {shlex.quote(root)} && propel init\n")


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------


def run(interactive: bool | None = None) -> int:
    if interactive is None:
        interactive = sys.stdin.isatty() and sys.stdout.isatty()

    click.echo(click.style("\n  Propel setup", bold=True) + " — terminal")
    click.echo(f"  Project: {_project_root()}")

    status = collect_status()
    _print_status(status)

    if not interactive:
        _print_manual_steps(status)
        return 0

    try:
        _install_tools(status)
        _fix_path()
        _sign_in()
        status = collect_status()
        _plugins(status)
        _init_project(status)
    except KeyboardInterrupt:
        click.echo("\n\n  Setup interrupted. Re-run `propel setup` any time — it picks up where it left off.\n")
        return 130

    status = collect_status()
    click.echo(click.style("  Where things stand", bold=True))
    _print_status(status)
    tools = _tools(status)
    if tools["claude"]["ok"] and tools["claude"]["auth"] is not True:
        click.echo("  Claude Code isn't signed in. Run:  claude auth login")
    if tools["codex"]["ok"] and tools["codex"]["auth"] is not True:
        click.echo(
            "  Codex isn't signed in, so gates run single-model. Sign in with:\n"
            "    codex login --device-auth\n"
            "  It prints a URL and a code: open the URL on your laptop and enter the code.\n"
            "  (There is no browser pop-up on a remote machine; that's expected.)\n"
        )
    if tools["claude"]["ok"] and status["project"]["initialized"]:
        cd = f"cd {shlex.quote(status['project']['root'])}"
        if shutil.which("claude"):
            click.echo(f"  Next:  {cd} && claude\n")
        else:
            # setup can't change the PATH of the shell that started it, so the
            # bare `claude` it would suggest is "command not found" right here.
            click.echo(f"  claude is in {LOCAL_BIN}, which this shell's PATH doesn't include yet.")
            click.echo("  Next (this shell):")
            click.echo(f"    {path_line()}")
            click.echo(f"    {cd} && claude\n")
    else:
        click.echo("  Re-run `propel setup` to finish the remaining steps.\n")
    return 0
