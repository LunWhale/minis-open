#!/usr/bin/env python3
"""Unit tests for the first-start handshake timeout of package-runner MCP
servers (Windows G5).

Run: python3 test_first_start_timeout.py  (stdlib unittest, no deps)

A server started through npx / uvx / ... downloads its packages on its first
start, which in the emulated guest can take minutes, so until it has finished
one handshake it gets config.FIRST_START_TIMEOUT at least, and a timeout then
says the packages may still be downloading.

Only the Windows copy has this so far; MINIS_MCP_CLI_DIR selects another.
"""

import os
import sys
import tempfile
import time
import unittest

_PKG = os.environ.get("MINIS_MCP_CLI_DIR") or os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "..", "..", "..",
    "src", "windows", "crates", "minis-shell", "assets", "minis-mcp-cli", "lib")
sys.path.insert(0, os.path.abspath(_PKG))

from utils import config  # noqa: E402
from transport.http import MCPError  # noqa: E402
import daemon  # noqa: E402

NPX = {"command": "npx", "args": ["-y", "firecrawl-mcp"]}


class _SilentProc:
    """A child that never answers `initialize`."""

    class _Stdin:
        def write(self, _):
            pass

        def flush(self):
            pass

    stdin = _Stdin()

    @property
    def stdout(self):
        def gen():
            while True:
                time.sleep(0.05)
            yield ""
        return gen()

    def poll(self):
        return None


class FirstStartTests(unittest.TestCase):
    def setUp(self):
        self._dir = tempfile.TemporaryDirectory()
        self._orig = (config.STARTED_PATH, config.FIRST_START_TIMEOUT)
        config.STARTED_PATH = os.path.join(self._dir.name, "cache", "started.json")

    def tearDown(self):
        config.STARTED_PATH, config.FIRST_START_TIMEOUT = self._orig
        self._dir.cleanup()

    def _timeout_of(self, cfg):
        captured = {}
        srv = daemon.MCPServerProcess("firecrawl", cfg)
        srv._rpc = lambda m, p=None, timeout=None: captured.setdefault("timeout", timeout) or {}
        srv._send = lambda *a, **k: None
        srv._handshake()
        return captured["timeout"]

    def test_package_runners(self):
        for cfg in (NPX, {"command": "/usr/bin/uvx", "args": ["mcp-x"]}, {"command": "bunx"},
                    {"command": "npm", "args": ["exec", "x"]}, {"command": "pipx", "args": ["run", "x"]}):
            self.assertTrue(config.fetches_packages(cfg), cfg)
        for cfg in ({"command": "node", "args": ["server.js"]}, {"command": "npm", "args": ["start"]},
                    {"command": "python3"}, {"url": "https://x"}, {}, None):
            self.assertFalse(config.fetches_packages(cfg), cfg)

    def test_first_start_waits_longer_then_the_configured_timeout(self):
        self.assertEqual(self._timeout_of(NPX), 300)
        # The handshake finished, so from now on the configured value applies.
        self.assertEqual(self._timeout_of(NPX), 60)
        self.assertEqual(self._timeout_of(dict(NPX, startupTimeoutSeconds=90)), 90)
        # Another package is a new download.
        self.assertEqual(self._timeout_of({"command": "npx", "args": ["-y", "other-mcp"]}), 300)

    def test_a_longer_configured_timeout_is_kept(self):
        self.assertEqual(self._timeout_of(dict(NPX, startupTimeoutSeconds=600)), 600)

    def test_other_servers_are_unchanged(self):
        self.assertEqual(self._timeout_of({"command": "node", "args": ["s.js"]}), 60)
        self.assertFalse(os.path.exists(config.STARTED_PATH))

    def test_a_first_start_timeout_says_the_packages_may_be_downloading(self):
        config.FIRST_START_TIMEOUT = 0.05
        srv = daemon.MCPServerProcess("firecrawl", dict(NPX, startupTimeoutSeconds=1))
        srv.proc = _SilentProc()
        orig = config.resolve_startup_timeout
        config.resolve_startup_timeout = lambda cfg: (0.01, None)
        try:
            with self.assertRaises(MCPError) as ctx:
                srv._handshake()
        finally:
            config.resolve_startup_timeout = orig
        msg = ctx.exception.message
        self.assertEqual(ctx.exception.code, "TIMEOUT")
        self.assertIn("first start", msg)
        self.assertIn("downloaded", msg)
        self.assertIn("startupTimeoutSeconds", msg)
        # Not recorded as started: the next try waits the long timeout again.
        self.assertTrue(config.is_first_package_start(NPX))

    def test_an_unreadable_state_file_counts_as_not_started(self):
        os.makedirs(os.path.dirname(config.STARTED_PATH))
        with open(config.STARTED_PATH, "w") as f:
            f.write("{not json")
        self.assertTrue(config.is_first_package_start(NPX))
        config.mark_started(NPX)
        self.assertFalse(config.is_first_package_start(NPX))


if __name__ == "__main__":
    unittest.main(verbosity=2)
