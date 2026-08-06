#!/usr/bin/env python3
"""ADR 0016 Phase 1 — the read-only collector, and the board that merges it.

The claims, by layer:

* **the registry** (`orchestra/nodes.py`) — deposits validate identity at the
  door, persist atomically, and reload after a restart exactly as stale as
  they are. A dark node must not look like a quiet one, and a REBOOTED board
  must not make it look like a missing one.
* **the merge** — a deposited remote snapshot reaches `board_state`, and the
  freshness map gains `node:<id>` stamps on BOTH compose paths (the sweep and
  the request), on the no-bump path — a heartbeat must never tick the version.
* **the wire** — `POST /api/v1/nodes/snapshot` against a real `Server`:
  accepted, refused by id (422), refused as self (409), capped (413), and the
  deposit visible on the very next `GET /api/state` with the §6 invariant
  intact.
* **the dial-out loop** (`orchestra/collector.py`) — ships the PRE-MERGE
  snapshot, re-ships on a heartbeat, retries without raising, and stops when
  told. Driven with a fake opener; no socket, no sleep longer than the test.

    python3 -m unittest discover -s tests
"""

import http.client
import io
import json
import shutil
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))
import orchestra as fb  # noqa: E402


def _card(name, avail="free", status="ended"):
    return {"name": name, "path": "/x/" + name,
            "git": {"branch": "main", "dirty": 0},
            "sessions": [{"sid": f"s-{name}", "status": status,
                          "last_write_at": 1000.0}],
            "availability": avail, "live_procs": []}


def _snap(cards, hostname="w.local", user="u", at=100.0):
    return {"generated_at": at, "hostname": hostname, "user": user,
            "counts": {"working": 0, "needs_input": 0, "limit": 0,
                       "blocked": 0, "waiting": 0, "ended": len(cards)},
            "worktrees": list(cards), "other_procs": []}


class RegistryCase(unittest.TestCase):
    """Its own cache file, its own node id, a cold registry."""

    def setUp(self):
        self.dir = Path(tempfile.mkdtemp(prefix="fb-nodes-"))
        self._cache = fb.nodes.CACHE
        fb.nodes.CACHE = self.dir / "nodes.cache.json"
        self._cfg_node = fb.CFG.get("node")
        fb.CFG["node"] = "board"
        fb.node._reset()
        fb.nodes._reset()

    def tearDown(self):
        fb.nodes.CACHE = self._cache
        fb.CFG["node"] = self._cfg_node
        fb.node._reset()
        fb.nodes._reset()
        shutil.rmtree(self.dir, ignore_errors=True)


class TheRegistry(RegistryCase):
    def test_a_deposit_lands_and_reads_back(self):
        self.assertIsNone(fb.nodes.deposit("work", _snap([_card("wt")]),
                                           label="Work", received_at=50.0))
        self.assertEqual(list(fb.nodes.remote_states()), ["work"])
        self.assertEqual(fb.nodes.ages(), {"work": 50.0})

    def test_an_id_that_cannot_key_cards_is_refused(self):
        for bad in ("Work", "a/b", "", None, "a|b"):
            r = fb.nodes.deposit(bad, _snap([]))
            self.assertEqual(r["error"], "node_invalid", repr(bad))

    def test_the_boards_own_id_is_refused(self):
        """A remote claiming the local identity is the one collision the
        qualified key cannot survive — two sources writing `board/<name>`."""
        r = fb.nodes.deposit("board", _snap([]))
        self.assertEqual(r["error"], "node_is_self")

    def test_a_shapeless_state_is_refused(self):
        for bad in (None, [], "x", {"worktrees": "nope"}):
            r = fb.nodes.deposit("work", bad)
            self.assertEqual(r["error"], "state_invalid", repr(bad))

    def test_a_restarted_board_reloads_the_node_exactly_as_stale_as_it_is(self):
        """The persistence rule: remote cards vanishing until the next
        heartbeat is the disappeared-card-reads-all-clear lie, compressed
        into a window. `received_at` must come back UNTOUCHED."""
        fb.nodes.deposit("work", _snap([_card("wt")]), received_at=50.0)
        fb.nodes._reset()                      # the restart
        self.assertEqual(list(fb.nodes.remote_states()), ["work"])
        self.assertEqual(fb.nodes.ages(), {"work": 50.0},
                         "a reloaded snapshot must keep its age, not mint one")

    def test_a_corrupt_cache_is_an_empty_registry_not_a_crash(self):
        fb.nodes.CACHE.write_text("not json")
        self.assertEqual(fb.nodes.remote_states(), {})


class TheMergedBoard(RegistryCase):
    def test_a_deposited_node_reaches_the_board(self):
        fb.nodes.deposit("work", _snap([_card("ConfidAI2", "busy", "working")]),
                         received_at=50.0)
        board = fb.observer.board_state(_snap([_card("ConfidAI2")],
                                              hostname="board.local"))
        self.assertEqual({(c["node"], c["name"]) for c in board["worktrees"]},
                         {("board", "ConfidAI2"), ("work", "ConfidAI2")})
        self.assertEqual(set(board["nodes"]), {"board", "work"})
        self.assertEqual(board["node"], "board")

    def test_the_freshness_map_dates_every_node_on_the_sweep_path(self):
        fb.nodes.deposit("work", _snap([_card("wt")]), received_at=50.0)
        saved = fb.observer.collect_state
        fb.observer.collect_state = lambda **kw: _snap([_card("local-wt")],
                                                       at=200.0)
        try:
            o = fb.observer.Observer(watch=False)
            snap = o.sweep()
            self.assertEqual(snap.freshness.get("node:work"), 50.0)
            self.assertEqual(snap.freshness.get("node:board"), 200.0)
        finally:
            fb.observer.collect_state = saved

    def test_a_heartbeat_alone_never_ticks_the_version(self):
        """The reason recency lives in freshness and not in the nodes map:
        a re-deposit with an unchanged snapshot must move the age and NOT
        the version (NODES.md §11)."""
        fb.nodes.deposit("work", _snap([_card("wt")]), received_at=50.0)
        saved = fb.observer.collect_state
        fb.observer.collect_state = lambda **kw: _snap([_card("local-wt")],
                                                       at=200.0)
        try:
            o = fb.observer.Observer(watch=False)
            v1 = o.sweep().v
            fb.nodes.deposit("work", _snap([_card("wt")]), received_at=90.0)
            snap = o.sweep()
            self.assertEqual(snap.v, v1, "same cards, fresher heartbeat — "
                                         "the version must not move")
            self.assertEqual(snap.freshness.get("node:work"), 90.0,
                             "…but the age must")
        finally:
            fb.observer.collect_state = saved


class TheWire(RegistryCase):
    """A real Server on a real port, loopback-trusted (the default config)."""

    def setUp(self):
        super().setUp()
        self._observer_saved = fb.observer._observer
        fb.observer._observer = None
        fb.observer._cache.update(t=0.0, state=None)
        self._collect_saved = fb.observer.collect_state
        fb.observer.collect_state = lambda **kw: _snap([_card("local-wt")],
                                                       at=200.0,
                                                       hostname="board.local")
        self.httpd = fb.server.Server(("127.0.0.1", 0), fb.server.Handler)
        self.port = self.httpd.server_address[1]
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()

    def tearDown(self):
        self.httpd.shutdown()
        self.httpd.server_close()
        fb.observer.collect_state = self._collect_saved
        fb.observer._observer = self._observer_saved
        fb.observer._cache.update(t=0.0, state=None)
        super().tearDown()

    def _post(self, body, raw=None):
        conn = http.client.HTTPConnection("127.0.0.1", self.port, timeout=10)
        payload = raw if raw is not None else json.dumps(body).encode()
        conn.request("POST", "/api/v1/nodes/snapshot", body=payload,
                     headers={"Content-Type": "application/json"})
        resp = conn.getresponse()
        out = (resp.status, json.loads(resp.read().decode() or "{}"))
        conn.close()
        return out

    def _get_state(self):
        conn = http.client.HTTPConnection("127.0.0.1", self.port, timeout=10)
        conn.request("GET", "/api/state")
        resp = conn.getresponse()
        out = json.loads(resp.read().decode())
        conn.close()
        return out

    def test_a_snapshot_is_accepted_and_lands_on_the_very_next_state(self):
        st, body = self._post({"node": "work", "label": "Work",
                               "state": _snap([_card("ConfidAI2", "busy",
                                                     "working")]),
                               "seq": 7, "sent_at": time.time()})
        self.assertEqual((st, body["ok"]), (200, True))
        state = self._get_state()
        self.assertEqual({(c["node"], c["name"]) for c in state["worktrees"]},
                         {("board", "local-wt"), ("work", "ConfidAI2")})
        self.assertIn("node:work", state["freshness"])
        refs = {c["node"] for c in state["worktrees"]}
        self.assertLessEqual(refs, set(state["nodes"]),
                             "the §6 invariant holds over the wire")

    def test_an_invalid_id_is_a_422_naming_the_problem(self):
        st, body = self._post({"node": "Not Valid", "state": _snap([])})
        self.assertEqual((st, body["error"]), (422, "node_invalid"))

    def test_the_boards_own_id_is_a_409(self):
        st, body = self._post({"node": "board", "state": _snap([])})
        self.assertEqual((st, body["error"]), (409, "node_is_self"))

    def test_a_body_past_the_snapshot_cap_is_a_413(self):
        saved = fb.CFG.get("node_snapshot_max_mb")
        fb.CFG["node_snapshot_max_mb"] = 0.0001          # ~105 bytes
        try:
            st, body = self._post(None, raw=b"x" * 4096)
            self.assertEqual((st, body["error"]), (413, "too_large"))
        finally:
            fb.CFG["node_snapshot_max_mb"] = saved


class TheDialOutLoop(RegistryCase):
    """`collector.py` against a fake opener — no sockets, no real clocks."""

    class _FakeObserver:
        def __init__(self, snap):
            self._local_snap = snap
            self._v = 1
            self._snap_obj = type("S", (), {"v": 1})()

        def wait_for(self, after, timeout=None):
            if self._v > after:
                self._snap_obj.v = self._v
                return self._snap_obj
            return None                    # timeout: the heartbeat case

    @staticmethod
    def _opener(log, status=200, body=b'{"ok": true}'):
        class _Resp(io.BytesIO):
            def __enter__(self): return self
            def __exit__(self, *a): return False
        def open_fn(req, timeout=None):
            log.append(json.loads(req.data.decode()))
            return _Resp(body)
        return open_fn

    def test_the_payload_is_the_premerge_snapshot_under_this_node(self):
        fb.CFG["node"] = "work"
        body = fb.collector.payload(_snap([_card("wt")]), seq=9)
        self.assertEqual(body["node"], "work")
        self.assertEqual(body["seq"], 9)
        self.assertEqual([c["name"] for c in body["state"]["worktrees"]],
                         ["wt"])
        self.assertNotIn("nodes", body["state"],
                         "a collector ships its OWN snapshot, never a merged "
                         "board — re-exporting other nodes makes rumours")

    def test_the_loop_posts_on_publish_and_again_on_heartbeat(self):
        fb.CFG["node"] = "work"
        log = []
        obs = self._FakeObserver(_snap([_card("wt")]))
        stop = threading.Event()
        posts = {"n": 0}
        real_opener = self._opener(log)
        def opener(req, timeout=None):
            posts["n"] += 1
            if posts["n"] >= 3:
                stop.set()
            return real_opener(req, timeout)
        t = threading.Thread(target=fb.collector.run_collector,
                             args=("http://board.test:1", obs),
                             kwargs={"token": "orc1_x", "heartbeat_s": 0.05,
                                     "stop": stop, "opener": opener})
        t.start()
        t.join(timeout=5)
        self.assertFalse(t.is_alive(), "the loop must honour stop")
        self.assertGreaterEqual(len(log), 3,
                                "one post for the version, then heartbeats")
        self.assertTrue(all(b["node"] == "work" for b in log))

    def test_an_unreachable_board_is_retried_not_raised(self):
        fb.CFG["node"] = "work"
        obs = self._FakeObserver(_snap([_card("wt")]))
        stop = threading.Event()
        calls = {"n": 0}
        def opener(req, timeout=None):
            calls["n"] += 1
            if calls["n"] >= 2:
                stop.set()
            raise OSError("no route to host")
        saved = fb.collector.RETRY_S
        fb.collector.RETRY_S = 0.01
        try:
            t = threading.Thread(target=fb.collector.run_collector,
                                 args=("http://board.test:1", obs),
                                 kwargs={"token": "orc1_x",
                                         "heartbeat_s": 0.05,
                                         "stop": stop, "opener": opener})
            t.start()
            t.join(timeout=5)
            self.assertFalse(t.is_alive())
            self.assertGreaterEqual(calls["n"], 2, "it kept trying")
        finally:
            fb.collector.RETRY_S = saved


if __name__ == "__main__":
    unittest.main()
