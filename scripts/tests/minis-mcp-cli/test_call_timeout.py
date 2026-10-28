#!/usr/bin/env python3
"""Tests for the bounded, never-retried tools/call timeout (FIX-261022-13).

Run: python3 test_call_timeout.py  (stdlib unittest, no deps)

A STDIO MCP server whose process wedges (Node stuck in a futex wait inside the
emulated guest) never answers. The daemon used to wait RPC_TIMEOUT (300 s),
re-spawn the server, and wait 300 s again. Now one request waits
config.resolve_call_timeout() (90 s by default), the stuck server's whole
process group is killed, and the call fails with a message that says it was
not retried and what to do instead. The next call starts a fresh server.

Real processes, real MCPPool; the fake server answers the handshake and
tools/list, and a tools/call of `hang` never returns, ignores SIGTERM and does
not exit on EOF, with a descendant in its process group like npx -> node.

Only the Windows copy has this so far; MINIS_MCP_CLI_DIR selects another.
"""

import json
import os
import shutil
import subprocess
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

WEDGING_SERVER = r'''
import json, os, signal, subprocess, sys, time
starts = sys.argv[1]
signal.signal(signal.SIGTERM, signal.SIG_IGN)
kid = subprocess.Popen([sys.executable, "-c",
    "import signal, time\nsignal.signal(signal.SIGTERM, signal.SIG_IGN)\ntime.sleep(600)\n"])
with open(starts, "a") as f:
    f.write(json.dumps([os.getpid(), kid.pid]) + "\n")
for line in sys.stdin:
    msg = json.loads(line)
    if "id" not in msg:
        continue
    method = msg.get("method")
    if method == "initialize":
        result = {"protocolVersion": "2025-06-18", "capabilities": {}, "serverInfo": {"name": "wedge"}}
    elif method == "tools/list":
        result = {"tools": [{"name": "hang"}, {"name": "echo"}]}
    elif method == "tools/call" and msg["params"]["name"] == "hang":
        while True:          # wedged: no reply, no exit, SIGTERM ignored
            time.sleep(1)
    else:
        result = {"content": [{"type": "text", "text": "ok"}]}
    sys.stdout.write(json.dumps({"jsonrpc": "2.0", "id": msg["id"], "result": result}) + "\n")
    sys.stdout.flush()
while True:                  # EOF on stdin does not end it either
    time.sleep(1)
'''


def live(pids):
    out = subprocess.run(["ps", "-o", "pid=,stat=", "-p", ",".join(map(str, pids))],
                         capture_output=True, text=True).stdout
    return [int(p[0]) for p in (line.split() for line in out.splitlines())
            if len(p) >= 2 and not p[1].startswith("Z")]


class ResolveCallTimeoutTests(unittest.TestCase):
    def test_default(self):
        self.assertEqual(config.resolve_call_timeout({}, env={}), (90, None))
        self.assertEqual(config.resolve_call_timeout(None, env={}), (90, None))

    def test_env_then_server_field(self):
        env = {config.CALL_TIMEOUT_ENV: "45"}
        self.assertEqual(config.resolve_call_timeout({}, env=env), (45, None))
        self.assertEqual(config.resolve_call_timeout({"callTimeoutSeconds": 300}, env=env), (300, None))
        self.assertEqual(config.resolve_call_timeout({"tool_timeout_sec": "120"}, env={}), (120, None))

    def test_invalid_values_fall_back_with_a_warning(self):
        for bad in ("abc", 0, -1, 901, 1.5, True, None):
            value, warning = config.resolve_call_timeout({"callTimeoutSeconds": bad},
                                                         env={config.CALL_TIMEOUT_ENV: "30"})
            self.assertEqual(value, 30, bad)
            self.assertIn("callTimeoutSeconds", warning)
            value, warning = config.resolve_call_timeout({}, env={config.CALL_TIMEOUT_ENV: str(bad)})
            self.assertEqual(value, 90, bad)
            self.assertIn(config.CALL_TIMEOUT_ENV, warning)

    def test_only_tool_requests_use_it(self):
        srv = daemon.MCPServerProcess("x", {"command": "x", "callTimeoutSeconds": 7})
        seen = []
        srv._send = lambda *a, **k: 1
        srv._read_reply = lambda want_id, timeout: seen.append(timeout) or {"result": {}}
        srv._rpc("tools/call", {})
        srv._rpc("tools/list")
        srv._rpc("tools/list", timeout=10)      # ping keeps its own
        srv._rpc("initialize", {}, timeout=60)  # the handshake keeps its own
        self.assertEqual(seen, [7, 7, 10, 60])


class StuckServerTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="mcp-stuck-")
        self.script = os.path.join(self.tmp, "wedge.py")
        with open(self.script, "w") as f:
            f.write(WEDGING_SERVER)
        self.starts = os.path.join(self.tmp, "starts")
        self.servers = {"wedge": {"command": sys.executable, "args": [self.script, self.starts],
                                  "callTimeoutSeconds": 1}}
        self._orig_get_server = daemon.config.get_server
        daemon.config.get_server = lambda name: self.servers.get(name)
        self.pool = daemon.MCPPool(on_empty=lambda: None)

    def tearDown(self):
        self.pool.shutdown()
        daemon.config.get_server = self._orig_get_server
        for pid in self.started_pids():
            try:
                os.kill(pid, 9)
            except OSError:
                pass
        shutil.rmtree(self.tmp, ignore_errors=True)

    def started(self):
        try:
            with open(self.starts) as f:
                return [json.loads(line) for line in f if line.strip()]
        except OSError:
            return []

    def started_pids(self):
        return [p for pair in self.started() for p in pair]

    def call(self, tool):
        return self.pool.call_with_retry("wedge", lambda s: s.call_tool(tool, {}))

    def test_a_stuck_call_fails_fast_once_and_kills_the_server(self):
        t0 = time.time()
        with self.assertRaises(MCPError) as ctx:
            self.call("hang")
        elapsed = time.time() - t0
        # 1 s timeout + the kill; never a second 1 s wait on a re-spawned server.
        self.assertLess(elapsed, 6, elapsed)
        self.assertEqual(ctx.exception.code, "TIMEOUT")
        msg = ctx.exception.message
        for part in ("no reply after 1s. The server looks stuck", "stuck", "not retried", "curl",
                     "mcpServers.wedge.callTimeoutSeconds", config.CALL_TIMEOUT_ENV):
            self.assertIn(part, msg)
        self.assertEqual(len(self.started()), 1, "spawned once, not re-spawned for a retry")
        self.assertEqual(self.pool.alive_servers(), [])
        deadline = time.time() + 5
        while live(self.started_pids()) and time.time() < deadline:
            time.sleep(0.05)
        self.assertEqual(live(self.started_pids()), [], "the stuck server's whole group is gone")

    def test_the_next_call_starts_a_fresh_server(self):
        with self.assertRaises(MCPError):
            self.call("hang")
        result = self.call("echo")
        self.assertEqual(result["content"][0]["text"], "ok")
        starts = self.started()
        self.assertEqual(len(starts), 2)
        self.assertNotEqual(starts[0][0], starts[1][0])


class HTTPTimeoutTests(unittest.TestCase):
    """An HTTP session's TIMEOUT is not retried either (it used to be sent
    again, doubling the 300 s httpx wait)."""

    def test_not_retried(self):
        calls = []

        class Session:
            inflight = 0
            last_activity = 0

            def is_alive(self):
                return True

            def stop(self):
                pass

        pool = daemon.MCPPool(on_empty=lambda: None)
        pool._pool["web"] = Session()

        def fn(_):
            calls.append(1)
            raise MCPError("TIMEOUT", "request timed out after 300s")

        with self.assertRaises(MCPError) as ctx:
            pool.call_with_retry("web", fn)
        self.assertEqual(len(calls), 1)
        self.assertIn("not retried", ctx.exception.message)
        self.assertNotIn("callTimeoutSeconds", ctx.exception.message)
        self.assertEqual(pool.alive_servers(), [])

    def test_a_crash_is_still_retried_once(self):
        calls = []
        pool = daemon.MCPPool(on_empty=lambda: None)

        class Session:
            inflight = 0
            last_activity = 0

            def is_alive(self):
                return True

            def stop(self):
                pass

        pool._pool["web"] = Session()
        orig = daemon.config.get_server
        daemon.config.get_server = lambda name: {"url": "http://127.0.0.1:1/mcp"}
        try:
            def fn(_):
                calls.append(1)
                if len(calls) == 1:
                    raise MCPError("STDIO_CRASH", "child closed stdin")
                return "second"
            self.assertEqual(pool.call_with_retry("web", fn), "second")
        finally:
            daemon.config.get_server = orig
        self.assertEqual(len(calls), 2)


if __name__ == "__main__":
    unittest.main(verbosity=2)
