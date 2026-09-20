"""Propel launcher — a local setup console for Claude Code and Codex.

`propel` (or `propel launch`) starts a tiny HTTP server bound to 127.0.0.1 on a
random port, opens the browser at it, and serves a one-page console that:

  * detects git / node / npm / Claude Code / Codex and whether each is signed in
  * installs the missing ones with one click
  * opens a real terminal for the two logins that are genuinely interactive
  * runs `propel init` in the project you point it at

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


def _version(binary: str, *args: str) -> str | None:
    if shutil.which(binary) is None:
        return None
    code, out = _run([binary, *(args or ("--version",))])
    if code != 0:
        return None
    return out.splitlines()[0].strip() if out else "installed"


def _node_ok(version: str | None) -> bool:
    """Codex needs Node 18.18+."""
    if not version:
        return False
    digits = "".join(c if c.isdigit() or c == "." else " " for c in version).split()
    if not digits:
        return False
    try:
        parts = [int(x) for x in digits[0].split(".")[:2]]
    except ValueError:
        return False
    major = parts[0]
    minor = parts[1] if len(parts) > 1 else 0
    return major > 18 or (major == 18 and minor >= 18)


def _claude_signed_in() -> bool:
    if os.environ.get("ANTHROPIC_API_KEY"):
        return True
    home = Path.home()
    for candidate in (home / ".claude" / ".credentials.json", home / ".claude.json"):
        if candidate.exists() and candidate.stat().st_size > 2:
            return True
    # Keychain-backed installs keep no credential file; fall back to asking the CLI.
    if shutil.which("claude"):
        code, out = _run(["claude", "auth", "status"], timeout=10)
        if code == 0 and out and "not" not in out.lower()[:40]:
            return True
    return False


def _codex_signed_in() -> bool:
    if os.environ.get("OPENAI_API_KEY"):
        return True
    auth = Path.home() / ".codex" / "auth.json"
    return auth.exists() and auth.stat().st_size > 2


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
    """Turn a known npm failure into something actionable."""
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
    if shutil.which("claude") is None:
        return set()
    code, out = _run(["claude", "plugin", "list", "--json"], timeout=20)
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
    node_v = _version("node")
    claude_v = _version("claude")
    codex_v = _version("codex")
    root = _project_root()
    has_brew = shutil.which("brew") is not None

    installed = _installed_plugin_ids()

    return {
        "platform": platform.system(),
        "plugins": [
            {
                "key": p["key"],
                "name": p["name"],
                "publisher": p["publisher"],
                "blurb": p["blurb"],
                "used_for": p["used_for"],
                "installed": p["id"] in installed,
                "install": f"install-plugin-{p['key']}",
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
                "version": _version("git"),
                "ok": shutil.which("git") is not None,
                "auth": None,
                "install": "install-git" if has_brew else None,
                "manual": "https://git-scm.com/downloads",
                "required": True,
            },
            {
                "key": "node",
                "name": "Node.js 18.18+",
                "blurb": "Required by the Codex CLI. Not needed if you only use Claude Code.",
                "version": node_v,
                "ok": _node_ok(node_v),
                "auth": None,
                "install": "install-node" if has_brew else None,
                "manual": "https://nodejs.org/en/download",
                "required": False,
                "warn": (
                    "Installed but older than 18.18 — Codex will not run."
                    if node_v and not _node_ok(node_v)
                    else None
                ),
            },
            {
                "key": "claude",
                "name": "Claude Code",
                "blurb": "The agent Propel runs inside. Required.",
                "version": claude_v,
                "ok": claude_v is not None,
                "auth": _claude_signed_in() if claude_v else False,
                "install": "install-claude",
                "login": "login-claude",
                "manual": "https://code.claude.com/docs/en/quickstart",
                "required": True,
            },
            {
                "key": "codex",
                "name": "OpenAI Codex",
                "blurb": "The second model. Propel consults it automatically at every gate.",
                "version": codex_v,
                "ok": codex_v is not None,
                "auth": _codex_signed_in() if codex_v else False,
                "install": "install-codex",
                "login": "login-codex",
                "manual": "https://developers.openai.com/codex/cli",
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
        "npm": "@anthropic-ai/claude-code",
    },
    "install-codex": {
        "label": "Install Codex CLI",
        "npm": "@openai/codex",
    },
    "login-claude": {
        "label": "Sign in to Claude Code",
        "terminal": "claude",
        "note": "A terminal window will open. Follow the /login flow there, then come back and press Re-check.",
    },
    "login-codex": {
        "label": "Sign in to Codex",
        "terminal": "codex login",
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
    if "terminal" in spec:
        ok, msg = _open_terminal(spec["terminal"])
        output = (
            f"{msg}\n\n{spec.get('note', '')}"
            if ok
            else f"Could not open a terminal ({msg}).\n\nRun this yourself:\n\n    {spec['terminal']}\n"
        )
        return {"job": job_id, "done": True, "ok": ok, "output": output}

    # Everything else runs as a background job the page polls.
    note = ""
    if "plugin" in spec:
        entry = next((p for p in PLUGINS if p["key"] == spec["plugin"]), None)
        if entry is None:
            return {"error": f"unknown plugin: {spec['plugin']}"}
        if shutil.which("claude") is None:
            return {
                "job": job_id, "done": True, "ok": False,
                "output": "Claude Code isn't installed yet, so there's nothing to install a plugin into.",
            }
        market_name, market_repo = entry["marketplace"]
        note = (
            f"Installing {entry['name']} from {entry['publisher']}.\n"
            f"Marketplace: {market_repo}\n\n"
            "Plugins can ship hooks, commands, agents and MCP servers -- they run\n"
            "code in your Claude Code session. Propel never installs one on its own.\n\n"
        )
        # Adding an already-configured marketplace is a no-op, so this is safe to
        # run every time and makes the action work on a fresh machine.
        cmd = [
            "sh", "-c",
            f"claude plugin marketplace add {market_repo} 2>/dev/null; "
            f"claude plugin install {entry['id']}",
        ]
        cwd = None
        with JOBS_LOCK:
            JOBS[job_id] = {"done": False, "ok": None, "output": note + f"$ claude plugin install {entry['id']}\n"}
        _spawn(job_id, cmd, cwd)
        return {"job": job_id, "done": False}

    if "npm" in spec:
        cmd, note = _npm_global_install(spec["npm"])
    elif "self" in spec:
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


def _spawn(job_id: str, cmd: list[str], cwd: str | None) -> None:
    def worker() -> None:
        try:
            proc = subprocess.Popen(
                cmd,
                cwd=cwd,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                bufsize=1,
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
                self._send(403, b"Forbidden", "text/plain")
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
        print("  Ctrl-C to close.\n")
        if open_browser:
            threading.Timer(0.4, lambda: webbrowser.open(url)).start()
        try:
            httpd.serve_forever()
        except KeyboardInterrupt:
            print("\n  Launcher closed.\n")
