"""Propel launcher — a local setup console for Claude Code and Codex.

`propel launch` (or bare `propel` on a machine with a display) starts a tiny
HTTP server bound to 127.0.0.1 on a random port, opens the browser at it, and
serves a one-page console that:

  * detects git / Claude Code / Codex (and Node, for claude-hud) and whether
    each is signed in
  * installs the missing ones with one click, using the vendors' own native
    installers — no Node, no npm, no sudo
  * opens a real terminal for the two logins that are genuinely interactive
  * runs `propel init` in the project you point it at

Detection and install specs here are shared with `terminal_setup.py`, the
headless path that bare `propel` picks on a cluster or over SSH.

Design notes that matter:

  * **Allowlist, not shell.** The browser can only name an action key from
    ACTIONS. It can never send a command string. A page served on localhost is
    reachable by anything else running on localhost, and an endpoint that
    executes arbitrary strings would be a remote shell.
  * **Token-gated.** Every request carries a per-process random token. A stray
    tab on another origin cannot drive the console.
  * **stdlib only.** Propel's single dependency is click. A setup tool that
    needs its own dependencies installed first is not a setup tool.
"""

from __future__ import annotations

import http.server
import json
import os
import platform
import secrets
import shlex
import shutil
import socketserver
import subprocess
import sys
import threading
import uuid
import webbrowser
from pathlib import Path

HERE = Path(__file__).resolve().parent
PAGE = HERE / "launcher.html"

TOKEN = secrets.token_urlsafe(24)
JOBS: dict[str, dict] = {}
JOBS_LOCK = threading.Lock()

# Where both native installers put their binaries. It is often not on PATH yet
# in the shell that ran the installer — or ever, for Claude's installer, which
# does not edit shell config — so detection looks here explicitly.
LOCAL_BIN = Path.home() / ".local" / "bin"


# ---------------------------------------------------------------------------
# Environment
# ---------------------------------------------------------------------------


def is_headless() -> bool:
    """Is there no screen to open a browser or a terminal window on?

    True over SSH (including VS Code Remote) and on Linux with no X/Wayland
    display — a cluster node, a container, a Jupyter terminal. This says
    nothing about whether stdin is interactive; that is a separate check.
    """
    if os.environ.get("SSH_CONNECTION") or os.environ.get("SSH_TTY"):
        return True
    if platform.system() == "Linux":
        return not (os.environ.get("DISPLAY") or os.environ.get("WAYLAND_DISPLAY"))
    return False


def tool_path(binary: str) -> str | None:
    """Absolute path of `binary`: PATH first, then ~/.local/bin.

    Every caller runs the path this returns, never the bare name, so a tool
    that detection can see is a tool that can actually be executed.
    """
    found = shutil.which(binary)
    if found:
        return found
    candidate = LOCAL_BIN / binary
    if candidate.is_file() and os.access(candidate, os.X_OK):
        return str(candidate)
    return None


def local_bin_on_path() -> bool:
    try:
        target = LOCAL_BIN.resolve()
    except OSError:
        return False
    return any(p.resolve() == target for p in _path_dirs() if p.exists())


def shell_rc() -> Path:
    """The rc file a PATH line belongs in, for the user's login shell."""
    shell = os.path.basename(os.environ.get("SHELL", ""))
    if shell == "zsh":
        return Path.home() / ".zshrc"
    if shell == "fish":
        return Path.home() / ".config" / "fish" / "config.fish"
    return Path.home() / ".bashrc"


def path_line() -> str:
    if shell_rc().name == "config.fish":
        return "fish_add_path $HOME/.local/bin"
    return 'export PATH="$HOME/.local/bin:$PATH"'


# ---------------------------------------------------------------------------
# Detection
# ---------------------------------------------------------------------------


def _run(cmd: list[str], timeout: int = 12) -> tuple[int, str]:
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return p.returncode, (p.stdout + p.stderr).strip()
    except FileNotFoundError:
        return 127, "not found"
    except subprocess.TimeoutExpired:
        return 124, "timed out"
    except Exception as exc:  # pragma: no cover - defensive
        return 1, str(exc)


def _version(binary: str, *args: str, path_only: bool = False) -> str | None:
    """`path_only` for tools other code runs by bare name (git, node), so
    detection never claims a tool that the caller then can't find."""
    exe = shutil.which(binary) if path_only else tool_path(binary)
    if exe is None:
        return None
    code, out = _run([exe, *(args or ("--version",))])
    if code != 0:
        return None
    return out.splitlines()[0].strip() if out else "installed"


def claude_signed_in() -> bool | None:
    """True / False, or None when the CLI's answer can't be read.

    `~/.claude.json` is deliberately not consulted: Claude Code writes it on
    first run whether or not you ever sign in.
    """
    if os.environ.get("ANTHROPIC_API_KEY"):
        return True
    exe = tool_path("claude")
    if exe:
        try:
            p = subprocess.run(
                [exe, "auth", "status", "--json"],
                capture_output=True, text=True, timeout=10,
            )
            out = p.stdout
            data = json.loads(out[out.index("{"):]) if "{" in out else None
            if isinstance(data, dict) and "loggedIn" in data:
                return bool(data["loggedIn"])
        except (subprocess.TimeoutExpired, OSError, ValueError):
            pass
    # Older CLIs without `auth status`: a credentials file is real evidence.
    creds = Path.home() / ".claude" / ".credentials.json"
    if creds.exists() and creds.stat().st_size > 2:
        return True
    return None if exe else False


def codex_signed_in() -> bool | None:
    """`codex login status` exits 0 when signed in, 1 when not."""
    if os.environ.get("OPENAI_API_KEY"):
        return True
    exe = tool_path("codex")
    if exe:
        code, out = _run([exe, "login", "status"], timeout=10)
        if code == 0:
            return True
        if code == 1 and "not logged in" in out.lower():
            return False
    auth = Path.home() / ".codex" / "auth.json"
    if auth.exists() and auth.stat().st_size > 2:
        return True
    return None if exe else False


def _path_dirs() -> list[Path]:
    return [Path(d) for d in os.environ.get("PATH", "").split(os.pathsep) if d]


def _npm_prefix_writable() -> tuple[bool, str]:
    """Can `npm install -g` actually write, without sudo?

    The default prefix on a stock macOS/Homebrew Node is /usr/local, which is
    root-owned. Clicking an install button should not fail with a wall of
    EACCES, and it should certainly not silently escalate to sudo.
    """
    if shutil.which("npm") is None:
        return False, ""
    code, out = _run(["npm", "prefix", "-g"], timeout=15)
    prefix = out.strip().splitlines()[-1] if (code == 0 and out.strip()) else ""
    if not prefix:
        return False, ""
    lib = Path(prefix) / "lib" / "node_modules"
    probe = lib if lib.exists() else Path(prefix)
    return os.access(probe, os.W_OK), prefix


def _user_npm_prefix() -> Path:
    """A writable prefix to fall back to.

    Prefer one whose bin/ is already on PATH, so the installed binary works
    immediately with no shell-config edit and no new instructions to follow.
    """
    on_path = {p.resolve() for p in _path_dirs() if p.exists()}
    for candidate in (Path.home() / ".local", Path.home() / ".npm-global"):
        if (candidate / "bin").resolve() in on_path:
            return candidate
    return Path.home() / ".local"


def _npm_global_install(package: str) -> tuple[list[str], str]:
    """The command to install `package` globally, plus a note for the log."""
    writable, prefix = _npm_prefix_writable()
    if writable:
        return ["npm", "install", "-g", package], ""

    target = _user_npm_prefix()
    bin_dir = target / "bin"
    on_path = bin_dir.resolve() in {p.resolve() for p in _path_dirs() if p.exists()}

    note = (
        f"npm's global prefix ({prefix or 'unknown'}) isn't writable by your user,\n"
        f"so this installs into {target} instead of asking for sudo.\n"
    )
    if on_path:
        note += f"{bin_dir} is already on your PATH, so this will just work.\n"
    else:
        note += (
            f"\n{bin_dir} is NOT on your PATH yet. After this finishes, add it:\n\n"
            f'    echo \'export PATH="{bin_dir}:$PATH"\' >> ~/.zshrc && exec zsh\n'
        )
    return ["npm", "install", "-g", "--prefix", str(target), package], note + "\n"


NATIVE_INSTALLERS = {
    "claude": {
        "name": "Claude Code",
        "url": "https://claude.ai/install.sh",
        "shell": "bash",
        "env": {},
    },
    "codex": {
        "name": "Codex CLI",
        "url": "https://chatgpt.com/codex/install.sh",
        "shell": "sh",
        # Its prompts read /dev/tty, which a console job must never block on.
        "env": {"CODEX_NON_INTERACTIVE": "1"},
    },
}

# Download first, then run. `curl … | sh` reports the shell's exit status, so a
# failed download that pipes nothing into sh looks like a successful install.
_FETCH_AND_RUN = r"""
tmp=$(mktemp) || exit 1
trap 'rm -f "$tmp"' EXIT
if command -v curl >/dev/null 2>&1; then
  curl -fsSL "$PROPEL_INSTALLER_URL" -o "$tmp" || exit 1
elif command -v wget >/dev/null 2>&1; then
  wget -q -O "$tmp" "$PROPEL_INSTALLER_URL" || exit 1
else
  echo "Neither curl nor wget is installed, so the installer can't be downloaded." >&2
  exit 127
fi
"$PROPEL_INSTALLER_SHELL" "$tmp"
"""


def native_install(tool: str) -> tuple[list[str], dict[str, str], str] | str:
    """(command, env, display line) for the vendor installer, or an error string.

    Windows has no POSIX installer to run, so it keeps the npm route.
    """
    spec = NATIVE_INSTALLERS[tool]
    if platform.system() == "Windows":
        package = "@anthropic-ai/claude-code" if tool == "claude" else "@openai/codex"
        if shutil.which("npm") is None:
            return "On Windows this installs with npm, and npm isn't installed. See the manual link."
        cmd, _ = _npm_global_install(package)
        return cmd, dict(os.environ), "$ " + " ".join(cmd)
    if shutil.which("curl") is None and shutil.which("wget") is None:
        return "Neither curl nor wget is installed, so the installer can't be downloaded."
    env = dict(os.environ)
    env.update(spec["env"])
    env["PROPEL_INSTALLER_URL"] = spec["url"]
    env["PROPEL_INSTALLER_SHELL"] = spec["shell"]
    display = f"$ curl -fsSL {spec['url']} | {spec['shell']}"
    return ["sh", "-c", _FETCH_AND_RUN], env, display


def path_note() -> str:
    """What to tell someone whose ~/.local/bin isn't on PATH yet."""
    if local_bin_on_path():
        return ""
    return (
        f"\n{LOCAL_BIN} is not on your PATH, so new shells won't find these tools.\n"
        f"Add it:\n\n    echo '{path_line()}' >> {shell_rc()}\n\n"
        "Propel itself already finds them there.\n"
    )


def _self_command(args: list[str]) -> list[str]:
    """Re-invoke Propel itself.

    Prefer the console script when it is on PATH, because `$ propel init` is a
    line the user can copy. Otherwise fall back to this very interpreter, which
    can always import the package — it is the one running this code. Requiring
    a `propel` binary on PATH to install Propel is a bootstrap problem the
    launcher has no reason to have.
    """
    exe = shutil.which("propel")
    if exe:
        return [exe, *args]
    return [sys.executable, "-m", "propel_cli", *args]


def _explain_failure(output: str) -> str:
    """Turn a known installer failure into something actionable."""
    if "curl:" in output or "wget:" in output or "Could not resolve host" in output:
        return (
            "\nThe installer couldn't be downloaded. On a cluster this is usually an\n"
            "outbound-network restriction: check your proxy (https_proxy) or try\n"
            "from a login node that has internet access.\n"
        )
    if "EACCES" in output or "permission denied" in output:
        return (
            "\nThis is a permissions problem, not a package problem. npm's global\n"
            "directory is owned by root. Propel does not run sudo for you — install\n"
            "into a user-owned prefix instead:\n\n"
            f"    npm install -g --prefix {_user_npm_prefix()} <package>\n\n"
            "Press Re-check after it completes.\n"
        )
    if "ENOTFOUND" in output or "ETIMEDOUT" in output or "ENETUNREACH" in output:
        return "\nLooks like a network problem reaching the npm registry. Check your connection or proxy and try again.\n"
    if "EEXIST" in output:
        return "\nSomething is already installed at that path. Remove it, or install with --force.\n"
    return ""


# Plugins Propel knows how to set up. Deliberately NOT installed by
# `propel init`: a plugin can ship hooks, commands, agents and MCP servers, so
# it executes code in the user's session. Deciding whose code may run in a
# research environment is a judgment call, and Propel's own rule is that
# judgment calls go to a human. They are offered here, one click, with the
# publisher named -- never installed as a side effect of setting up a project.
PLUGINS = [
    {
        "key": "claude-hud",
        "id": "claude-hud@claude-hud",
        "name": "claude-hud",
        "publisher": "jarrodwatts",
        "marketplace": ("claude-hud", "jarrodwatts/claude-hud"),
        "blurb": (
            "Status line: model, context budget, running subagents. Propel's "
            "Codex task block renders beneath it."
        ),
        "used_for": "status line",
        # Its status-line command runs under node (scripts/propel-statusline.sh).
        "needs": "node",
    },
    {
        "key": "code-review",
        "id": "code-review@claude-plugins-official",
        "name": "code-review",
        "publisher": "Anthropic",
        "marketplace": ("claude-plugins-official", "anthropics/claude-plugins-official"),
        "blurb": (
            "Anthropic's general-purpose review rubric. /c-review folds it into "
            "the Gate 3 card alongside Propel's auditors and the Codex consult."
        ),
        "used_for": "deeper review at Gate 3",
    },
]


def _installed_plugin_ids() -> set[str]:
    exe = tool_path("claude")
    if exe is None:
        return set()
    code, out = _run([exe, "plugin", "list", "--json"], timeout=20)
    if code != 0 or not out:
        return set()
    try:
        data = json.loads(out[out.index("[") :]) if "[" in out else []
    except (json.JSONDecodeError, ValueError):
        return set()
    return {
        entry.get("id", "")
        for entry in data
        if isinstance(entry, dict) and entry.get("enabled") is not False
    }


def _project_root() -> Path:
    try:
        p = subprocess.run(
            ["git", "rev-parse", "--show-toplevel"],
            capture_output=True,
            text=True,
            check=True,
        )
        return Path(p.stdout.strip())
    except Exception:
        return Path.cwd()


def collect_status() -> dict:
    node_v = _version("node", path_only=True)
    claude_v = _version("claude")
    codex_v = _version("codex")
    root = _project_root()
    has_brew = shutil.which("brew") is not None

    installed = _installed_plugin_ids()

    return {
        "platform": platform.system(),
        "headless": is_headless(),
        "local_bin_on_path": local_bin_on_path(),
        "path_hint": f"echo '{path_line()}' >> {shell_rc()}",
        "plugins": [
            {
                "key": p["key"],
                "name": p["name"],
                "publisher": p["publisher"],
                "blurb": p["blurb"],
                "used_for": p["used_for"],
                "installed": p["id"] in installed,
                "install": f"install-plugin-{p['key']}",
                "needs": p.get("needs"),
            }
            for p in PLUGINS
        ],
        "project": {
            "root": str(root),
            "is_git": (root / ".git").exists(),
            "initialized": (root / ".claude" / "skills" / "using-propel").exists(),
            "codex_enabled": _codex_config(root),
        },
        "tools": [
            {
                "key": "git",
                "name": "git",
                "blurb": "Propel scopes investigations and regressions to a repository.",
                "version": _version("git", path_only=True),
                "ok": shutil.which("git") is not None,
                "has_auth": False,
                "auth": None,
                "install": "install-git" if has_brew else None,
                "manual": "https://git-scm.com/downloads",
                "required": True,
            },
            {
                "key": "claude",
                "name": "Claude Code",
                "blurb": "The agent Propel runs inside. Required. Installed with Anthropic's native installer — no Node needed.",
                "version": claude_v,
                "ok": claude_v is not None,
                "has_auth": True,
                "auth": claude_signed_in() if claude_v else False,
                "install": "install-claude",
                "login": "login-claude",
                "manual": "https://code.claude.com/docs/en/setup",
                "required": True,
            },
            {
                "key": "codex",
                "name": "OpenAI Codex",
                "blurb": "The second model. Propel consults it automatically at every gate. Installed with OpenAI's native installer — no Node needed.",
                "version": codex_v,
                "ok": codex_v is not None,
                "has_auth": True,
                "auth": codex_signed_in() if codex_v else False,
                "install": "install-codex",
                "login": "login-codex",
                "manual": "https://developers.openai.com/codex/cli",
                "required": False,
            },
            {
                "key": "node",
                "name": "Node.js",
                "blurb": "Only needed for the claude-hud status line plugin. Claude Code and Codex don't use it.",
                "version": node_v,
                "ok": node_v is not None,
                "has_auth": False,
                "auth": None,
                "install": "install-node" if has_brew else None,
                "manual": "https://nodejs.org/en/download",
                "required": False,
            },
        ],
    }


def _codex_config(root: Path) -> bool | None:
    f = root / ".propel" / "codex.json"
    if not f.exists():
        return None
    try:
        return bool(json.loads(f.read_text()).get("enabled", True))
    except Exception:
        return None


# ---------------------------------------------------------------------------
# Actions (allowlist)
# ---------------------------------------------------------------------------

ACTIONS: dict[str, dict] = {
    "install-git": {
        "label": "Install git",
        "cmd": ["brew", "install", "git"],
    },
    "install-node": {
        "label": "Install Node.js",
        "cmd": ["brew", "install", "node"],
    },
    "install-claude": {
        "label": "Install Claude Code",
        "native": "claude",
    },
    "install-codex": {
        "label": "Install Codex CLI",
        "native": "codex",
    },
    # Login argv is resolved at click time (tool_path), because the binary may
    # have been installed seconds ago into a directory that isn't on PATH.
    "login-claude": {
        "label": "Sign in to Claude Code",
        "login": ("claude", ["auth", "login"]),
        "note": "A terminal window will open. Finish the sign-in there, then come back and press Re-check.",
    },
    "login-codex": {
        "label": "Sign in to Codex",
        "login": ("codex", ["login"]),
        "note": "A terminal window will open for the OAuth flow. Finish it, then press Re-check.",
    },
    "install-plugin-claude-hud": {
        "label": "Install claude-hud",
        "plugin": "claude-hud",
    },
    "install-plugin-code-review": {
        "label": "Install code-review",
        "plugin": "code-review",
    },
    "propel-init": {
        "label": "Install Propel into this project",
        "self": ["init"],
        "cwd_project": True,
    },
    "enable-codex": {
        "label": "Enable the dual-model layer",
        "config": {"enabled": True},
    },
    "disable-codex": {
        "label": "Disable the dual-model layer",
        "config": {"enabled": False},
    },
}


def _open_terminal(command: str) -> tuple[bool, str]:
    """Open a real terminal window running `command`.

    Interactive logins need a TTY the browser cannot provide. Rather than
    pretending, we hand the user a terminal that is already running the right
    command — and if we can't, we say so and show the command to paste.
    """
    system = platform.system()
    cwd = str(_project_root())
    try:
        if system == "Darwin":
            script = (
                f'tell application "Terminal" to do script '
                f'"cd {json.dumps(cwd)[1:-1]} && {command}"\n'
                'tell application "Terminal" to activate'
            )
            subprocess.Popen(["osascript", "-e", script])
            return True, "Opened Terminal.app."
        if system == "Linux":
            for term, flag in (
                ("x-terminal-emulator", "-e"),
                ("gnome-terminal", "--"),
                ("konsole", "-e"),
                ("xterm", "-e"),
            ):
                if shutil.which(term):
                    subprocess.Popen([term, flag, "bash", "-lc", f"cd {cwd!r} && {command}; exec bash"])
                    return True, f"Opened {term}."
            return False, "No terminal emulator found."
        if system == "Windows":
            subprocess.Popen(["cmd", "/c", "start", "cmd", "/k", command], cwd=cwd)
            return True, "Opened a command prompt."
    except Exception as exc:
        return False, str(exc)
    return False, "Unsupported platform."


def login_argv(key: str) -> list[str] | None:
    """Resolved argv for a login action, or None if the tool isn't installed."""
    tool, args = ACTIONS[key]["login"]
    exe = tool_path(tool)
    return [exe, *args] if exe else None


def plugin_install_cmd(entry: dict, claude_exe: str) -> list[str]:
    """Add the marketplace (a no-op when it's already configured), then install."""
    _, market_repo = entry["marketplace"]
    exe = shlex.quote(claude_exe)
    return [
        "sh", "-c",
        f"{exe} plugin marketplace add {shlex.quote(market_repo)} 2>/dev/null; "
        f"{exe} plugin install {shlex.quote(entry['id'])}",
    ]


def plugin_note(entry: dict) -> str:
    return (
        f"Installing {entry['name']} from {entry['publisher']}.\n"
        f"Marketplace: {entry['marketplace'][1]}\n\n"
        "Plugins can ship hooks, commands, agents and MCP servers -- they run\n"
        "code in your Claude Code session. Propel never installs one on its own.\n\n"
    )


def _start_job(key: str) -> dict:
    spec = ACTIONS.get(key)
    if spec is None:
        return {"error": f"unknown action: {key}"}

    job_id = uuid.uuid4().hex[:12]

    # Config toggles are instantaneous — no job needed.
    if "config" in spec:
        root = _project_root()
        d = root / ".propel"
        d.mkdir(exist_ok=True)
        f = d / "codex.json"
        try:
            cfg = json.loads(f.read_text())
        except Exception:
            cfg = {}
        cfg.update(spec["config"])
        f.write_text(json.dumps(cfg, indent=2) + "\n")
        state = "enabled" if spec["config"]["enabled"] else "disabled"
        return {
            "job": job_id,
            "done": True,
            "ok": True,
            "output": f"Dual-model layer {state} for {root}.\nWrote {f}.",
        }

    # Interactive logins get a real terminal.
    if "login" in spec:
        argv = login_argv(key)
        if argv is None:
            return {
                "job": job_id, "done": True, "ok": False,
                "output": f"{spec['login'][0]} isn't installed yet. Install it first, then sign in.",
            }
        # cmd.exe doesn't understand POSIX single quotes around a C:\ path.
        command = subprocess.list2cmdline(argv) if platform.system() == "Windows" else shlex.join(argv)
        if is_headless():
            ok, msg = False, "this machine has no display"
        else:
            ok, msg = _open_terminal(command)
        output = (
            f"{msg}\n\n{spec.get('note', '')}"
            if ok
            else (
                f"Could not open a terminal ({msg}).\n\nRun this in your shell:\n\n    {command}\n\n"
                "On a remote machine, `propel setup` does every step in the terminal instead.\n"
            )
        )
        return {"job": job_id, "done": True, "ok": ok, "output": output}

    # Everything else runs as a background job the page polls.
    note = ""
    if "plugin" in spec:
        entry = next((p for p in PLUGINS if p["key"] == spec["plugin"]), None)
        if entry is None:
            return {"error": f"unknown plugin: {spec['plugin']}"}
        claude_exe = tool_path("claude")
        if claude_exe is None:
            return {
                "job": job_id, "done": True, "ok": False,
                "output": "Claude Code isn't installed yet, so there's nothing to install a plugin into.",
            }
        with JOBS_LOCK:
            JOBS[job_id] = {
                "done": False, "ok": None,
                "output": plugin_note(entry) + f"$ claude plugin install {entry['id']}\n",
            }
        _spawn(job_id, plugin_install_cmd(entry, claude_exe), None)
        return {"job": job_id, "done": False}

    if "native" in spec:
        result = native_install(spec["native"])
        if isinstance(result, str):
            return {"job": job_id, "done": True, "ok": False, "output": result}
        cmd, env, display = result
        with JOBS_LOCK:
            JOBS[job_id] = {"done": False, "ok": None, "output": display + "\n"}
        _spawn(job_id, cmd, None, env=env, after_success=path_note)
        return {"job": job_id, "done": False}

    if "self" in spec:
        cmd = _self_command(spec["self"])
    else:
        cmd = spec["cmd"]
    if not Path(cmd[0]).is_absolute() and shutil.which(cmd[0]) is None:
        return {
            "job": job_id,
            "done": True,
            "ok": False,
            "output": f"`{cmd[0]}` is not installed, so this step can't run yet.\nInstall it first, or use the manual link.",
        }

    cwd = str(_project_root()) if spec.get("cwd_project") else None
    with JOBS_LOCK:
        JOBS[job_id] = {"done": False, "ok": None, "output": note + f"$ {' '.join(cmd)}\n"}
    _spawn(job_id, cmd, cwd)
    return {"job": job_id, "done": False}


def _spawn(
    job_id: str,
    cmd: list[str],
    cwd: str | None,
    env: dict[str, str] | None = None,
    after_success=None,
) -> None:
    def worker() -> None:
        try:
            # No stdin and no controlling terminal: a job the browser can't
            # answer must not be able to stop and wait for an answer.
            proc = subprocess.Popen(
                cmd,
                cwd=cwd,
                env=env,
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                bufsize=1,
                start_new_session=True,
            )
            assert proc.stdout is not None
            for line in proc.stdout:
                with JOBS_LOCK:
                    JOBS[job_id]["output"] += line
            proc.wait()
            with JOBS_LOCK:
                JOBS[job_id]["done"] = True
                JOBS[job_id]["ok"] = proc.returncode == 0
                if proc.returncode == 0:
                    JOBS[job_id]["output"] += "\n✓ done.\n"
                    if after_success:
                        JOBS[job_id]["output"] += after_success()
                else:
                    JOBS[job_id]["output"] += f"\n✗ exited {proc.returncode}.\n"
                    JOBS[job_id]["output"] += _explain_failure(JOBS[job_id]["output"])
        except Exception as exc:  # pragma: no cover - defensive
            with JOBS_LOCK:
                JOBS[job_id]["done"] = True
                JOBS[job_id]["ok"] = False
                JOBS[job_id]["output"] += f"\n✗ {exc}\n"

    threading.Thread(target=worker, daemon=True).start()


# ---------------------------------------------------------------------------
# Server
# ---------------------------------------------------------------------------


FORBIDDEN_HELP = (
    "Forbidden: this URL is missing the console's access token, or has one from\n"
    "an earlier run.\n\n"
    "Open the full URL printed in the terminal where `propel launch` is running,\n"
    "including everything after ?t= . A new token is made every time it starts.\n\n"
    "On a remote machine you don't need this page at all: run `propel setup`\n"
    "there, and it does every step in the terminal.\n"
).encode()


class Handler(http.server.BaseHTTPRequestHandler):
    server_version = "PropelLauncher/1.0"

    def log_message(self, *args) -> None:  # keep the terminal clean
        pass

    # -- helpers ----------------------------------------------------------
    def _send(self, code: int, body: bytes, ctype: str) -> None:
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def _json(self, obj: dict, code: int = 200) -> None:
        self._send(code, json.dumps(obj).encode(), "application/json")

    def _authed(self) -> bool:
        from urllib.parse import parse_qs, urlparse

        q = parse_qs(urlparse(self.path).query)
        return secrets.compare_digest(q.get("t", [""])[0], TOKEN)

    # -- routes -----------------------------------------------------------
    def do_GET(self) -> None:
        from urllib.parse import urlparse

        path = urlparse(self.path).path

        if path == "/":
            if not self._authed():
                self._send(403, FORBIDDEN_HELP, "text/plain; charset=utf-8")
                return
            html = PAGE.read_text(encoding="utf-8").replace("__TOKEN__", TOKEN)
            self._send(200, html.encode(), "text/html; charset=utf-8")
            return

        if not self._authed():
            self._json({"error": "forbidden"}, 403)
            return

        if path == "/api/status":
            self._json(collect_status())
            return

        if path.startswith("/api/job/"):
            job_id = path.rsplit("/", 1)[-1]
            with JOBS_LOCK:
                job = JOBS.get(job_id)
            self._json(job or {"error": "no such job"}, 200 if job else 404)
            return

        self._send(404, b"Not found", "text/plain")

    def do_POST(self) -> None:
        from urllib.parse import urlparse

        if not self._authed():
            self._json({"error": "forbidden"}, 403)
            return
        if urlparse(self.path).path != "/api/action":
            self._send(404, b"Not found", "text/plain")
            return

        length = int(self.headers.get("Content-Length") or 0)
        try:
            payload = json.loads(self.rfile.read(length) or b"{}")
        except Exception:
            self._json({"error": "bad request"}, 400)
            return

        key = payload.get("action", "")
        if key not in ACTIONS:
            self._json({"error": f"unknown action: {key}"}, 400)
            return
        self._json(_start_job(key))


class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


def serve(open_browser: bool = True, port: int = 0) -> None:
    if not PAGE.exists():
        raise FileNotFoundError(f"launcher page missing: {PAGE}")

    with Server(("127.0.0.1", port), Handler) as httpd:
        actual = httpd.server_address[1]
        url = f"http://127.0.0.1:{actual}/?t={TOKEN}"
        print("\n  Propel launcher")
        print(f"  {url}\n")
        if is_headless():
            print("  This machine has no display. To use the page from your laptop:")
            print(f"    ssh -L {actual}:localhost:{actual} <this-host>")
            print("  then open the URL above there, token included.")
            print("  Simpler: Ctrl-C and run `propel setup`, which needs no browser.\n")
        print("  Ctrl-C to close.\n", flush=True)  # the URL must show up even under nohup/tee
        if open_browser:
            threading.Timer(0.4, lambda: webbrowser.open(url)).start()
        try:
            httpd.serve_forever()
        except KeyboardInterrupt:
            print("\n  Launcher closed.\n")
