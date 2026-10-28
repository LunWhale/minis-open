#!/usr/bin/env python3
"""Tests for the daemon's cap on live STDIO MCP servers [T-mcp-pool-stdio-cap].

Run: python3 test_pool_stdio_cap.py  (stdlib unittest, no deps)
     MINIS_MCP_CLI_DIR=<.../src/ios/default_mount/usr/local/lib/minis-mcp-cli> \
         python3 test_pool_stdio_cap.py        # the iOS copy

Real processes, real MCPPool: each fake server is a Python script that answers
the MCP stdio handshake and, like `npx` launching `npm` launching the server,
leaves two descendants in its process group that do NOT exit when the leader
reads EOF on stdin. That is the shape that used to leak: stop() only reaped the
leader. Covers:

  * starting 5 servers one after another never has more than 3 alive at once
    (sampled continuously from the process table, not just the pool dict);
  * the evicted server is the least recently used one, and the eviction is
    logged as "[pool] evicting <name> (LRU, cap=3)";
  * a server serving a request is never evicted, even when it is the oldest;
  * when every live server is busy, a new server waits for a slot and then
    takes it; past SLOT_WAIT_SECONDS it fails with POOL_FULL;
  * an evicted server's whole process tree exits, including a descendant that
    ignores SIGTERM;
  * HTTP servers do not count toward the cap;
  * MINIS_MCP_MAX_STDIO_SERVERS overrides the cap; invalid values fall back.
"""

import json
import logging
import os
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import unittest

_PKG = os.environ.get("MINIS_MCP_CLI_DIR") or os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "..", "..", "..",
    "src", "android", "app", "src", "main", "assets", "default_mount",
    "usr", "local", "lib", "minis-mcp-cli")
sys.path.insert(0, os.path.abspath(_PKG))

from utils import config  # noqa: E402
from transport.http import MCPError  # noqa: E402
import daemon  # noqa: E402

FAKE_SERVER = r'''
import json, os, signal, subprocess, sys, time
pidfile, stubborn = sys.argv[1], sys.argv[2] == "1"
# Two descendants in this process group, standing in for npm and the server.
child = ("import signal, time\n"
         + ("signal.signal(signal.SIGTERM, signal.SIG_IGN)\n" if stubborn else "")
         + "time.sleep(600)\n")
kids = [subprocess.Popen([sys.executable, "-c", child]) for _ in range(2)]
with open(pidfile + ".tmp", "w") as f:
    json.dump({"leader": os.getpid(), "kids": [k.pid for k in kids]}, f)
os.replace(pidfile + ".tmp", pidfile)
for line in sys.stdin:
    msg = json.loads(line)
    if "id" not in msg:
        continue
    method = msg.get("method")
    if method == "initialize":
        result = {"protocolVersion": "2025-06-18", "capabilities": {}, "serverInfo": {"name": "fake"}}
    elif method == "tools/list":
        result = {"tools": []}
    elif method == "tools/call":
        time.sleep(float(msg["params"]["arguments"].get("seconds", 0)))
        result = {"content": [{"type": "text", "text": "done"}]}
    else:
        result = {}
    sys.stdout.write(json.dumps({"jsonrpc": "2.0", "id": msg["id"], "result": result}) + "\n")
    sys.stdout.flush()
# EOF on stdin: the leader exits, the descendants stay behind (as npm/node did).
'''


def live_pids(pids):
    """The pids that are running. A zombie (dead, not yet reaped by init) does
    not count: os.kill(pid, 0) still succeeds on one, but it holds no memory -
    the same rule daemon._group_pids applies."""
    pids = [int(p) for p in pids]
    if not pids:
        return []
    out = subprocess.run(["ps", "-o", "pid=,stat=", "-p", ",".join(map(str, pids))],
                         capture_output=True, text=True).stdout
    alive = []
    for line in out.splitlines():
        parts = line.split()
        if len(parts) >= 2 and not parts[1].startswith("Z"):
            alive.append(int(parts[0]))
    return alive


def pid_alive(pid):
    return bool(live_pids([pid]))


class PoolCapTestBase(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="mcp-cap-")
        self.script = os.path.join(self.tmp, "fake_server.py")
        with open(self.script, "w") as f:
            f.write(FAKE_SERVER)
        self.servers = {}
        self._orig_get_server = daemon.config.get_server
        daemon.config.get_server = lambda name: self.servers.get(name)
        self._orig_wait = daemon.SLOT_WAIT_SECONDS
        self._env = os.environ.pop(config.MAX_STDIO_SERVERS_ENV, None)
        self.pool = daemon.MCPPool(on_empty=lambda: None)
        self.all_pids = []

    def tearDown(self):
        self.pool.shutdown()
        daemon.config.get_server = self._orig_get_server
        daemon.SLOT_WAIT_SECONDS = self._orig_wait
        if self._env is not None:
            os.environ[config.MAX_STDIO_SERVERS_ENV] = self._env
        else:
            os.environ.pop(config.MAX_STDIO_SERVERS_ENV, None)
        # Never leave anything behind, whatever the test outcome.
        for pid in self.all_pids:
            try:
                os.kill(pid, 9)
            except OSError:
                pass
        shutil.rmtree(self.tmp, ignore_errors=True)

    def add_stdio(self, name, stubborn=False):
        self.servers[name] = {
            "command": sys.executable,
            "args": [self.script, self.pidfile(name), "1" if stubborn else "0"],
        }

    def pidfile(self, name):
        return os.path.join(self.tmp, name + ".pids")

    def tree(self, name):
        with open(self.pidfile(name)) as f:
            d = json.load(f)
        return [d["leader"]] + d["kids"]

    def ping(self, name):
        self.pool.call_with_retry(name, lambda s: s.ping())
        for pid in self.tree(name):
            if pid not in self.all_pids:
                self.all_pids.append(pid)

    def live_names(self):
        return sorted(self.pool.alive_servers())

    def alive_trees(self):
        """Servers with ANY process of their tree still running."""
        trees = {name: self.tree(name) for name in self.servers if os.path.exists(self.pidfile(name))}
        running = set(live_pids([p for t in trees.values() for p in t]))
        return [name for name, t in trees.items() if running.intersection(t)]


class CapAndLRUTests(PoolCapTestBase):
    def test_five_servers_never_more_than_three_alive(self):
        for i in range(1, 6):
            self.add_stdio("s%d" % i)
        peak = {"n": 0}
        stop = threading.Event()

        def sampler():
            while not stop.is_set():
                peak["n"] = max(peak["n"], len(self.alive_trees()))
                time.sleep(0.01)

        t = threading.Thread(target=sampler, daemon=True)
        t.start()
        try:
            for i in range(1, 6):
                self.ping("s%d" % i)
                self.assertLessEqual(len(self.pool.alive_servers()), 3)
                time.sleep(0.02)
        finally:
            stop.set()
            t.join()
        self.assertEqual(self.live_names(), ["s3", "s4", "s5"])
        self.assertLessEqual(peak["n"], 3, "a 4th server tree was alive at some point")
        self.assertEqual(sorted(self.alive_trees()), ["s3", "s4", "s5"])

    def test_least_recently_used_is_evicted_and_logged(self):
        for name in ("a", "b", "c", "d", "e"):
            self.add_stdio(name)
        for name in ("a", "b", "c"):
            self.ping(name)
            time.sleep(0.02)
        self.ping("a")  # a is now the most recent; b is the LRU
        with self.assertLogs("mcp-daemon", level="INFO") as logs:
            self.ping("d")
        self.assertEqual(self.live_names(), ["a", "c", "d"])
        self.assertIn("[pool] evicting b (LRU, cap=3)", "\n".join(logs.output))
        self.ping("e")  # c is now the LRU
        self.assertEqual(self.live_names(), ["a", "d", "e"])

    def test_reusing_a_live_server_evicts_nothing(self):
        for name in ("a", "b", "c"):
            self.add_stdio(name)
            self.ping(name)
        leader_a = self.tree("a")[0]
        self.ping("a")
        self.assertEqual(self.live_names(), ["a", "b", "c"])
        self.assertEqual(self.tree("a")[0], leader_a, "a was respawned")

    def test_dead_server_is_dropped_before_a_live_one(self):
        for name in ("a", "b", "c", "d"):
            self.add_stdio(name)
        for name in ("a", "b", "c"):
            self.ping(name)
            time.sleep(0.02)
        leader_c = self.tree("c")[0]
        os.kill(leader_c, 9)  # c crashes; a is still the LRU
        self.pool._pool["c"].proc.wait(5)
        self.ping("d")
        self.assertEqual(self.live_names(), ["a", "b", "d"])

    def test_http_servers_do_not_count(self):
        self.servers["h1"] = {"url": "http://127.0.0.1:9/mcp"}
        self.servers["h2"] = {"url": "http://127.0.0.1:9/mcp"}
        self.pool.get("h1")
        self.pool.get("h2")
        for name in ("a", "b", "c"):
            self.add_stdio(name)
            self.ping(name)
        self.assertEqual(self.live_names(), ["a", "b", "c", "h1", "h2"])
        self.add_stdio("d")
        self.ping("d")
        self.assertEqual(self.live_names(), ["b", "c", "d", "h1", "h2"])


class InflightTests(PoolCapTestBase):
    def _busy(self, name, seconds):
        """Run a slow tools/call on `name` in the background."""
        box = {}

        def run():
            try:
                box["result"] = self.pool.call_with_retry(
                    name, lambda s: s.call_tool("sleep", {"seconds": seconds}))
            except Exception as exc:  # noqa: BLE001
                box["error"] = exc

        t = threading.Thread(target=run, daemon=True)
        t.start()
        deadline = time.time() + 5
        while time.time() < deadline:
            session = self.pool._pool.get(name)
            if session is not None and session.inflight > 0:
                break
            time.sleep(0.01)
        return t, box

    def test_busy_server_is_not_evicted_even_if_oldest(self):
        for name in ("a", "b", "c", "d"):
            self.add_stdio(name)
        for name in ("a", "b", "c"):
            self.ping(name)
            time.sleep(0.02)
        t, box = self._busy("a", 1.5)  # a is the oldest, but busy
        self.ping("d")
        self.assertEqual(self.live_names(), ["a", "c", "d"], "the idle LRU (b) should go, not busy a")
        t.join(10)
        self.assertNotIn("error", box)
        self.assertEqual(box["result"]["content"][0]["text"], "done")

    def test_all_busy_waits_for_a_slot(self):
        for name in ("a", "b", "c", "d"):
            self.add_stdio(name)
        for name in ("a", "b", "c"):
            self.ping(name)
        busy = [self._busy("a", 1.0), self._busy("b", 3.0), self._busy("c", 3.0)]
        start = time.time()
        self.ping("d")  # must wait until a finishes, then take its slot
        waited = time.time() - start
        self.assertGreaterEqual(waited, 0.5)
        self.assertEqual(self.live_names(), ["b", "c", "d"])
        for t, box in busy:
            t.join(10)
            self.assertNotIn("error", box)

    def test_all_busy_past_the_wait_fails_with_pool_full(self):
        daemon.SLOT_WAIT_SECONDS = 0.5
        for name in ("a", "b", "c", "d"):
            self.add_stdio(name)
        for name in ("a", "b", "c"):
            self.ping(name)
        busy = [self._busy(n, 3.0) for n in ("a", "b", "c")]
        with self.assertRaises(MCPError) as ctx:
            self.pool.call_with_retry("d", lambda s: s.ping())
        self.assertEqual(ctx.exception.code, "POOL_FULL")
        self.assertFalse(os.path.exists(self.pidfile("d")), "d must not have been spawned")
        self.assertEqual(self.live_names(), ["a", "b", "c"])
        for t, box in busy:
            t.join(10)
            self.assertNotIn("error", box)


class ProcessTreeTests(PoolCapTestBase):
    def test_evicted_server_tree_exits(self):
        for name in ("a", "b", "c", "d"):
            self.add_stdio(name)
        for name in ("a", "b", "c"):
            self.ping(name)
            time.sleep(0.02)
        tree_a = self.tree("a")
        self.assertTrue(all(pid_alive(p) for p in tree_a))
        self.ping("d")  # evicts a
        self.assertEqual(live_pids(tree_a), [], "processes of evicted a still running")

    def test_descendant_ignoring_sigterm_is_killed(self):
        self.add_stdio("stubborn", stubborn=True)
        for name in ("b", "c", "d"):
            self.add_stdio(name)
        self.ping("stubborn")
        time.sleep(0.02)
        self.ping("b")
        self.ping("c")
        tree = self.tree("stubborn")
        self.ping("d")  # evicts stubborn
        self.assertEqual(live_pids(tree), [])

    def test_ttl_and_shutdown_also_clean_the_tree(self):
        self.add_stdio("a")
        self.ping("a")
        tree = self.tree("a")
        self.pool._pool["a"].last_activity -= daemon.TTL_SECONDS + 1
        self.pool.gc()
        self.assertEqual(self.live_names(), [])
        self.assertEqual(live_pids(tree), [])

    def test_ttl_skips_a_busy_server(self):
        self.add_stdio("a")
        self.ping("a")
        session = self.pool._pool["a"]
        session.inflight = 1
        session.last_activity -= daemon.TTL_SECONDS + 1
        self.pool.gc()
        self.assertEqual(self.live_names(), ["a"])
        session.inflight = 0


class ProcScanTests(unittest.TestCase):
    """daemon._group_pids is what runs on iSH / PRoot (macOS has no /proc, so
    the process tests above go through killpg). Exercise it on a fake /proc."""

    def setUp(self):
        self.root = tempfile.mkdtemp(prefix="fakeproc-")
        self._orig = daemon.PROC_ROOT
        daemon.PROC_ROOT = self.root

    def tearDown(self):
        daemon.PROC_ROOT = self._orig
        shutil.rmtree(self.root, ignore_errors=True)

    def add(self, pid, comm, state, pgrp):
        os.makedirs(os.path.join(self.root, str(pid)))
        with open(os.path.join(self.root, str(pid), "stat"), "w") as f:
            f.write("%d (%s) %s 1 %d %d 0 -1 0 0 0" % (pid, comm, state, pgrp, pgrp))

    def test_members_of_the_group_only(self):
        self.add(100, "npx", "R", 100)
        self.add(101, "npm exec (x) y", "S", 100)   # comm with spaces and parens
        self.add(102, "node", "Z", 100)             # zombie: already dead
        self.add(200, "node", "R", 200)             # another server's group
        os.makedirs(os.path.join(self.root, "self"))
        with open(os.path.join(self.root, "uptime"), "w") as f:
            f.write("1 1")
        self.assertEqual(sorted(daemon.MCPServerProcess._group_pids(100)), [100, 101])
        self.assertEqual(daemon.MCPServerProcess._group_pids(300), [])

    def test_no_proc_means_none(self):
        daemon.PROC_ROOT = os.path.join(self.root, "missing")
        self.assertIsNone(daemon.MCPServerProcess._group_pids(100))


class CapOverrideTests(PoolCapTestBase):
    def test_env_override(self):
        os.environ[config.MAX_STDIO_SERVERS_ENV] = "2"
        for name in ("a", "b", "c"):
            self.add_stdio(name)
            self.ping(name)
            time.sleep(0.02)
        self.assertEqual(self.live_names(), ["b", "c"])

    def test_resolve(self):
        self.assertEqual(config.resolve_max_stdio_servers(3, {}), (3, None))
        self.assertEqual(config.resolve_max_stdio_servers(3, {config.MAX_STDIO_SERVERS_ENV: ""}), (3, None))
        self.assertEqual(config.resolve_max_stdio_servers(3, {config.MAX_STDIO_SERVERS_ENV: " 5 "}), (5, None))
        for bad in ("0", "-1", "17", "three"):
            value, warning = config.resolve_max_stdio_servers(3, {config.MAX_STDIO_SERVERS_ENV: bad})
            self.assertEqual(value, 3, bad)
            self.assertIsNotNone(warning, bad)

    def test_default_is_three(self):
        self.assertEqual(daemon.MAX_STDIO_SERVERS, 3)
        self.assertEqual(daemon.TTL_SECONDS, 600)


if __name__ == "__main__":
    logging.basicConfig(level=logging.WARNING)
    unittest.main(verbosity=2)
