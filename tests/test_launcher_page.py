"""Tests for the launcher page (src/propel_cli/launcher.html).

Usage: python -m unittest tests/test_launcher_page.py -v

The page is static HTML plus inline JS, so these are source-level checks:
every allowlisted action is reachable from the page, the Propel update block
reads the status fields it needs, the request format and token are intact,
and the visual tells the redesign removed stay removed. They check for
identifiers and patterns, not markup, so the layout can change freely.
"""

import re
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "src"))

from propel_cli import cli as cli_mod  # noqa: E402
from propel_cli import launcher  # noqa: E402

PAGE = launcher.PAGE.read_text(encoding="utf-8")


def _style() -> str:
    m = re.search(r"<style>(.*?)</style>", PAGE, re.S)
    return m.group(1) if m else ""


def _script() -> str:
    m = re.search(r"<script>(.*?)</script>", PAGE, re.S)
    return m.group(1) if m else ""


class ActionsReachableTests(unittest.TestCase):
    """Every ACTIONS key is either named in the page or delivered by the status
    JSON into a field the page binds to data-act."""

    # Keys the page names literally.
    STATIC = {"propel-init", "propel-update", "enable-codex", "disable-codex"}

    def _status(self) -> dict:
        with tempfile.TemporaryDirectory() as tmp, \
                mock.patch.object(launcher, "_project_root", return_value=Path(tmp)), \
                mock.patch.object(launcher, "_version", return_value=None), \
                mock.patch.object(launcher, "_installed_plugin_ids", return_value=set()), \
                mock.patch.object(launcher, "_propel_status", return_value={"installed": False}), \
                mock.patch.object(launcher.shutil, "which", side_effect=lambda n: f"/usr/bin/{n}"), \
                mock.patch.object(cli_mod, "get_propel_root", return_value=ROOT):
            return launcher.collect_status()

    def test_static_actions_named_in_page(self):
        for key in self.STATIC:
            self.assertIn(key, launcher.ACTIONS, key)
            self.assertRegex(_script(), r"""["']""" + re.escape(key) + r"""["']""", key)

    def test_dynamic_actions_bound_from_status_fields(self):
        js = _script()
        # The fields the status JSON uses to carry action keys, and the page
        # putting each into data-act.
        for field in ("t.install", "t.login", "p.install"):
            self.assertRegex(js, r"data-act=\"\$\{esc\(" + re.escape(field) + r"\)\}\"", field)

    def test_every_action_is_reachable(self):
        s = self._status()
        dynamic = set()
        for t in s["tools"]:
            dynamic.update(k for k in (t.get("install"), t.get("login")) if k)
        dynamic.update(p["install"] for p in s["plugins"])
        missing = set(launcher.ACTIONS) - self.STATIC - dynamic
        self.assertEqual(missing, set(), f"actions the page cannot trigger: {missing}")
        self.assertIn("login-claude", dynamic)
        self.assertIn("login-codex", dynamic)


class RequestFormatTests(unittest.TestCase):
    def test_token_placeholder_and_query_param(self):
        self.assertIn('"__TOKEN__"', PAGE)
        self.assertIn('"t=" + T', _script())

    def test_routes_and_body(self):
        js = _script()
        for route in ("/api/status", "/api/action", "/api/job/"):
            self.assertIn(route, js)
        self.assertRegex(js, r"JSON\.stringify\(\{\s*action\s*\}\)")
        self.assertRegex(js, r"""method:\s*["']POST["']""")

    def test_status_refetched_after_actions(self):
        # refresh() is called on the error, immediate and polled-job paths.
        body = re.search(r"async function run\(.*?\n\}\n", _script(), re.S)
        self.assertIsNotNone(body)
        self.assertGreaterEqual(body.group(0).count("refresh()"), 3)

    def test_server_substitutes_token(self):
        served = PAGE.replace("__TOKEN__", "tok")
        self.assertNotIn("__TOKEN__", served)


class PropelBlockTests(unittest.TestCase):
    FIELDS = (
        "update_available", "settings_error", "skipped_symlinked", "edited_bundled",
        "user_files", "hooks_pending", "changes", "installed_version",
        "available_version", "error_kind",
    )

    def test_reads_propel_status_fields(self):
        js = _script()
        self.assertIn("s.propel", js)
        for field in self.FIELDS:
            self.assertRegex(js, r"\b" + field + r"\b", field)

    def test_update_button_disabled_by_settings_error(self):
        js = _script()
        self.assertIn('data-act="propel-update"', js)
        # A settings error marks the button blocked, and re-enabling skips it.
        self.assertIn("data-blocked", js)
        self.assertRegex(js, r"dataset\.blocked")

    def test_install_hint_names_pip_and_uv(self):
        js = _script()
        for form in ("pip install -e", "uv pip install -e", "uv tool install --editable"):
            self.assertIn(form, js)

    def test_strings_are_escaped(self):
        js = _script()
        self.assertIn("function esc(", js)
        for field in ("pr.settings_error", "pr.error", "p.root", "t.version", "p.blurb"):
            self.assertNotRegex(js, r"\$\{" + re.escape(field) + r"\}", field)


class VisualTellsRemovedTests(unittest.TestCase):
    def test_old_palette_gone(self):
        lower = PAGE.lower()
        for hex_ in ("#0d1117", "#151b23", "#3fb950"):
            self.assertNotIn(hex_, lower)

    def test_no_glow_or_uppercase_labels(self):
        css = _style()
        self.assertNotIn("box-shadow", css)
        self.assertNotRegex(css, r"text-transform\s*:\s*uppercase")

    def test_whole_pixel_font_sizes(self):
        self.assertNotRegex(_style(), r"font-size\s*:\s*\d+\.\d+px")

    def test_light_and_dark(self):
        self.assertIn("prefers-color-scheme: dark", _style())

    def test_no_check_glyphs_or_em_dashes(self):
        for glyph in ("✓", "\\u2713", "—", "&mdash;"):
            self.assertNotIn(glyph, PAGE, repr(glyph))


if __name__ == "__main__":
    unittest.main()
