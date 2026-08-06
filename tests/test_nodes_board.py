#!/usr/bin/env python3
"""The merged board (ADR 0016 Phase 0): qualified keys, the nodes map, the door.

The claims, in the order they can go wrong:

* **the gate proof** — two nodes each holding a `ConfidAI2` put TWO cards on
  one board, under distinct keys, with counts summed. This is the collision
  the whole phase exists to end, driven through the real `Observer.publish`
  and `delta_since`, not a paraphrase of them.
* **the invariant** (docs/mobile/NODES.md §6, sibling of test_pairing's
  "everything advertised must be answerable"): every node a payload
  references, that payload's `nodes` map describes — on the state shape and
  on BOTH frame branches. A card whose node the client cannot name is the
  node-shaped version of advertising a Host you refuse to answer.
* **the fourth bump term** — a node appearing with zero cards moves the
  version with no card changing, and the delta a client is handed for that
  bump actually carries the nodes map.
* **the door** (NODES.md §4) — every acting route accepts the qualified key,
  hands its local path the bare name, reads a bare value as the local node,
  and refuses a foreign node by name.

    python3 -m unittest discover -s tests
"""

import json
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))
import orchestra as fb  # noqa: E402


def _card(name, avail="free", status="ended", sid=None):
    return {"name": name, "path": "/x/" + name,
            "git": {"branch": "main", "dirty": 0},
            "sessions": [{"sid": sid or f"s-{name}", "status": status,
                          "last_write_at": 1000.0}],
            "availability": avail, "live_procs": []}


def _snap(cards, hostname="h.local", user="u", at=100.0, counts=None, other=()):
    return {"generated_at": at, "hostname": hostname, "user": user,
            "counts": counts or {"working": 0, "needs_input": 0, "limit": 0,
                                 "blocked": 0, "waiting": 0, "ended": len(cards)},
            "worktrees": list(cards),
            "other_procs": [{"pid": p, "cpu": 0.0, "etime": "1:00",
                             "tty": None, "host": None, "cwd": "/x"}
                            for p in other]}


def _referenced_nodes(payload):
    """Every node id a payload names, from every field that names one."""
    refs = set()
    for c in payload.get("worktrees") or []:
        refs.add(c["node"])
    for field in ("order", "free_worktrees"):
        for k in payload.get(field) or []:
            refs.add(k.split("/", 1)[0])
    for k in payload.get("cards") or {}:
        refs.add(k.split("/", 1)[0])
    for p in payload.get("other_procs") or []:
        if "node" in p:
            refs.add(p["node"])
    for k in payload.get("resumes") or {}:
        refs.add(k.split("/", 1)[0])
    return refs


class NodeBoardCase(unittest.TestCase):
    def setUp(self):
        self._cfg_node = fb.CFG.get("node")
        fb.CFG["node"] = "gaia"
        fb.node._reset()

    def tearDown(self):
        fb.CFG["node"] = self._cfg_node
        fb.node._reset()


class TwoNodesOneBoard(NodeBoardCase):
    """The Phase 0 gate proof, end to end through the real publish point."""

    def test_two_same_named_worktrees_hold_two_cards(self):
        board = fb.observer.merge_nodes({
            "gaia": _snap([_card("ConfidAI2", "busy", "working")],
                          counts={"working": 1, "needs_input": 0, "limit": 0,
                                  "blocked": 0, "waiting": 0, "ended": 0}),
            "work": _snap([_card("ConfidAI2", "attention", "needs_input")],
                          counts={"working": 0, "needs_input": 1, "limit": 0,
                                  "blocked": 0, "waiting": 0, "ended": 0},
                          at=101.0),
        })
        o = fb.observer.Observer(watch=False)
        snap = o.publish(board)
        self.assertEqual(set(snap.cards),
                         {"gaia/ConfidAI2", "work/ConfidAI2"},
                         "two machines' same-named worktrees must be two cards")
        # severity interleave: needs_input outranks working, node breaks ties
        self.assertEqual(list(snap.cards),
                         ["work/ConfidAI2", "gaia/ConfidAI2"])
        self.assertEqual(snap.counts["working"], 1)
        self.assertEqual(snap.counts["needs_input"], 1)
        frame = o.delta_since(0)
        self.assertEqual(frame["type"], "snapshot")
        self.assertEqual(set(frame["cards"]),
                         {"gaia/ConfidAI2", "work/ConfidAI2"})

    def test_free_worktrees_are_qualified_keys_in_board_order(self):
        board = fb.observer.merge_nodes({
            "gaia": _snap([_card("alpha"), _card("beta")]),
            "work": _snap([_card("alpha")]),
        })
        self.assertEqual(board["free_worktrees"],
                         ["gaia/alpha", "work/alpha", "gaia/beta"])

    def test_one_node_keeps_the_collect_order(self):
        """The single-machine board through the merge is the same board —
        the migration story: same cards, same order, one nodes entry."""
        local = _snap([_card("alpha", "attention", "needs_input"),
                       _card("beta", "busy", "working")],
                      hostname="gaia.local", user="me")
        board = fb.observer.board_state(local)
        self.assertEqual([c["name"] for c in board["worktrees"]],
                         ["alpha", "beta"])
        self.assertEqual([c["node"] for c in board["worktrees"]],
                         ["gaia", "gaia"])
        self.assertEqual(board["hostname"], "gaia.local")
        self.assertEqual(board["user"], "me")
        self.assertEqual(board["node"], "gaia",
                         "the board names its own node — the client's only "
                         "honest local/remote test for loose processes")
        self.assertEqual(board["nodes"],
                         {"gaia": {"label": "gaia", "hostname": "gaia.local",
                                   "user": "me"}})

    def test_a_node_id_that_cannot_key_cards_is_refused(self):
        """By Phase 1 these ids arrive from the network; an id that fails the
        format must never be composed into a board it can only corrupt."""
        for bad in ("Work", "a/b", "", "a|b"):
            with self.assertRaises(ValueError, msg=repr(bad)):
                fb.observer.merge_nodes({bad: _snap([])})

    def test_a_card_the_merge_never_stamped_cannot_be_published(self):
        """`publish` is strict: keying an unstamped card quietly by bare name
        would resurrect exactly the collision this phase ends."""
        o = fb.observer.Observer(watch=False)
        board = fb.observer.merge_nodes({"gaia": _snap([_card("alpha")])})
        del board["worktrees"][0]["node"]
        with self.assertRaises(KeyError):
            o.publish(board)


class TheInvariant(NodeBoardCase):
    """Everything referenced must be described (NODES.md §6)."""

    def _two_node_observer(self):
        o = fb.observer.Observer(watch=False)
        o.publish(fb.observer.merge_nodes({
            "gaia": _snap([_card("alpha", "busy", "working")], other=(41,)),
            "work": _snap([_card("alpha", "attention", "needs_input")], at=101.0),
        }))
        return o

    def test_the_state_payload_describes_every_node_it_references(self):
        local = _snap([_card("alpha")], hostname="gaia.local")
        board = fb.observer.board_state(local)
        refs = _referenced_nodes(board)
        self.assertTrue(refs)
        self.assertLessEqual(refs, set(board["nodes"]))

    def test_the_snapshot_frame_describes_every_node_it_references(self):
        frame = self._two_node_observer().delta_since(0)
        self.assertEqual(frame["type"], "snapshot")
        refs = _referenced_nodes(frame)
        self.assertEqual(refs, {"gaia", "work"})
        self.assertLessEqual(refs, set(frame["nodes"]))

    def test_the_delta_frame_describes_every_node_it_references(self):
        o = self._two_node_observer()
        base = o.snapshot().v
        o.publish(fb.observer.merge_nodes({
            "gaia": _snap([_card("alpha", "busy", "working")], other=(41,)),
            "work": _snap([_card("alpha", "attention", "blocked")], at=102.0),
        }))
        frame = o.delta_since(base)
        self.assertEqual(frame["type"], "delta")
        refs = _referenced_nodes(frame)
        self.assertTrue(refs)
        self.assertLessEqual(refs, set(frame["nodes"]))

    def test_the_resumes_keys_reference_only_described_nodes(self):
        """The /api/state envelope carries `resumes` beside the board; its
        qualified keys must resolve against the same nodes map."""
        saved = dict(fb.resume._resumes)
        try:
            fb.resume._resumes.clear()
            fb.resume._resumes["alpha|sid-1"] = {
                "worktree": "alpha", "sid": "sid-1", "account": "main",
                "status": "pending", "due_at": 1.0, "attempts": 0}
            board = fb.observer.board_state(_snap([_card("alpha")]))
            payload = {**board, "resumes": fb.resume.resume_public()}
            self.assertIn("gaia/alpha|sid-1", payload["resumes"])
            self.assertEqual(payload["resumes"]["gaia/alpha|sid-1"]["worktree"],
                             "gaia/alpha")
            self.assertLessEqual(_referenced_nodes(payload),
                                 set(payload["nodes"]))
        finally:
            fb.resume._resumes.clear()
            fb.resume._resumes.update(saved)

    def test_the_demo_board_holds_the_same_invariant(self):
        demo = fb.observer.demo_state()
        payload = {**demo, "resumes": fb.resume.demo_resumes()}
        self.assertLessEqual(_referenced_nodes(payload), set(payload["nodes"]))


class TheFourthBumpTerm(NodeBoardCase):
    def test_a_node_with_zero_cards_bumps_the_version(self):
        o = fb.observer.Observer(watch=False)
        o.publish(fb.observer.merge_nodes({"gaia": _snap([], at=100.0)}))
        v1 = o.snapshot().v
        o.publish(fb.observer.merge_nodes({"gaia": _snap([], at=101.0),
                                           "work": _snap([], at=101.0)}))
        self.assertGreater(o.snapshot().v, v1,
                           "a collector watching empty roots appeared — the "
                           "version must say so with no card changing")
        frame = o.delta_since(v1)
        self.assertEqual(set(frame["nodes"]), {"gaia", "work"},
                         "…and the frame for that bump must carry the map")

    def test_an_unchanged_board_still_publishes_no_new_version(self):
        o = fb.observer.Observer(watch=False)
        board = fb.observer.merge_nodes({"gaia": _snap([_card("alpha")])})
        v1 = o.publish(board).v
        again = fb.observer.merge_nodes({"gaia": _snap([_card("alpha")],
                                                       at=105.0)})
        self.assertEqual(o.publish(again).v, v1,
                         "the nodes term must not spin the version when "
                         "nothing about the nodes changed")


class TheDoor(NodeBoardCase):
    """The route boundary: qualified in, bare local out, foreign refused.

    Driven at the seam (`node.local_name` + the route wiring) through the
    module functions the routes call, with the actuation below patched out —
    the refusal must happen BEFORE anything local runs.
    """

    def test_send_strips_the_local_prefix(self):
        seen = {}
        saved = fb.terminal.send_to_process
        fb.terminal.send_to_process = lambda pid, text, **kw: (
            seen.update(kw) or {"ok": True, "message": "sent"})
        try:
            wt, bad = fb.node.local_name("gaia/ConfidAI2")
            self.assertIsNone(bad)
            fb.terminal.send_to_process(0, "hi", worktree=wt)
            self.assertEqual(seen["worktree"], "ConfidAI2")
        finally:
            fb.terminal.send_to_process = saved

    def test_a_foreign_worktree_key_is_refused_with_the_node_named(self):
        wt, bad = fb.node.local_name("work/ConfidAI2")
        self.assertIsNone(wt)
        self.assertEqual(bad["error"], "unknown_node")
        self.assertIn("work", bad["message"])

    def test_dispatch_auto_pick_never_chooses_a_foreign_card(self):
        board = fb.observer.merge_nodes({
            "gaia": _snap([_card("mine", "free")]),
            "work": _snap([_card("cleaner", "free")]),
        })
        # the foreign card is "cleaner" in every sense the picker sorts by —
        # it must still lose, because dispatch is local actuation
        saved_state = fb.observer.cached_state
        saved_limits = (fb.limits.cached_limits, fb.limits.limits_by_account)
        fb.observer.cached_state = lambda: board
        fb.limits.cached_limits = lambda **kw: {}
        fb.limits.limits_by_account = lambda: {}
        try:
            wt, _ = fb.dispatch._pick_defaults(pick_worktree=True)
            self.assertEqual(wt, "mine")
        finally:
            fb.observer.cached_state = saved_state
            fb.limits.cached_limits, fb.limits.limits_by_account = saved_limits
            fb.dispatch._release_worktree("mine")

    def test_the_dispatch_log_is_qualified_on_the_way_out(self):
        tmp = Path(tempfile.mkdtemp(prefix="fb-dlog-"))
        saved = fb.dispatch.DISPATCH_LOG
        fb.dispatch.DISPATCH_LOG = tmp / "dispatch.log.jsonl"
        try:
            fb.dispatch.DISPATCH_LOG.write_text(json.dumps(
                {"ts": "2026-08-06T01:00:00", "session": "mission-x",
                 "worktree": "ConfidAI2", "account": "main"}) + "\n")
            entries = fb.dispatch.read_dispatch_log()["entries"]
            self.assertEqual(entries[0]["worktree"], "gaia/ConfidAI2")
        finally:
            fb.dispatch.DISPATCH_LOG = saved
            shutil.rmtree(tmp, ignore_errors=True)


class TheProjection(NodeBoardCase):
    """notify diffs the same world the board serves (observer.py:1005's twin)."""

    def test_the_push_projection_keys_cards_by_the_qualified_key(self):
        board = fb.observer.merge_nodes({
            "gaia": _snap([_card("ConfidAI2", "busy", "working")]),
            "work": _snap([_card("ConfidAI2", "attention", "needs_input",
                                 sid="s-remote")]),
        })
        proj = fb.notify.project(board)
        self.assertEqual(set(proj["worktrees"]),
                         {"gaia/ConfidAI2", "work/ConfidAI2"},
                         "two nodes' same-named worktrees must be two "
                         "conditions, or the push pipeline merges their alerts")
        self.assertEqual(proj["sessions"]["s-remote"]["worktree"],
                         "work/ConfidAI2")


class ThePushTitle(NodeBoardCase):
    """NODES.md §7 in the one place that has no badge to lean on: the lock
    screen. The alert title speaks the bare name; a card on ANOTHER node says
    so in words; and the identity fields underneath (`wt`, `thread-id`,
    `dedupe_key`) stay fully qualified — display and identity never trade."""

    def _event(self, wt):
        return fb.notify.Event(id="ev-1", at=1000.0,
                               type="session.needs_answer", level="P1",
                               dedupe_key=f"session.needs_answer|{wt}|s1|1",
                               worktree=wt, account="main")

    def test_the_title_speaks_the_bare_name_for_a_local_card(self):
        payload = fb.notify.compose(self._event("gaia/ConfidAI2"))["payload"]
        self.assertEqual(payload["aps"]["alert"]["title"],
                         "ConfidAI2 needs an answer")

    def test_the_title_names_a_foreign_node_in_words(self):
        payload = fb.notify.compose(self._event("work/ConfidAI2"))["payload"]
        self.assertEqual(payload["aps"]["alert"]["title"],
                         "ConfidAI2 on work needs an answer")

    def test_the_identity_fields_underneath_stay_qualified(self):
        payload = fb.notify.compose(self._event("work/ConfidAI2"),
                                    server="gaia-board")["payload"]
        self.assertEqual(payload["wt"], "work/ConfidAI2")
        self.assertEqual(payload["aps"]["thread-id"],
                         "gaia-board|work/ConfidAI2")


class TheMapJoin(NodeBoardCase):
    def test_demo_topology_carries_the_demo_node(self):
        topo = fb.gitrepo.demo_topology()
        for grp in topo["groups"]:
            for b in grp["branches"]:
                self.assertEqual(b["node"], "starbase")

    def test_branch_topology_tags_every_branch_with_this_node(self):
        """A real repo with no origin: the branch carries the node id and the
        group key cannot collide with another machine's path-twin."""
        tmp = Path(tempfile.mkdtemp(prefix="fb-topo-"))
        try:
            repo = tmp / "solo"
            repo.mkdir()
            for cmd in (["git", "init", "-q", "-b", "main"],
                        ["git", "-c", "user.email=t@t", "-c", "user.name=t",
                         "commit", "-q", "--allow-empty", "-m", "root"],
                        ["git", "branch", "-q", "feat"],
                        ["git", "checkout", "-q", "feat"],
                        ["git", "-c", "user.email=t@t", "-c", "user.name=t",
                         "commit", "-q", "--allow-empty", "-m", "tip"]):
                subprocess.run(cmd, cwd=repo, check=True, capture_output=True)
            saved_roots = fb.CFG["roots"]
            fb.CFG["roots"] = [str(tmp)]
            try:
                topo = fb.gitrepo.branch_topology()
            finally:
                fb.CFG["roots"] = saved_roots
            branches = [b for g in topo["groups"] for b in g["branches"]]
            self.assertTrue(branches, "the repo must appear on the map")
            for b in branches:
                self.assertEqual(b["node"], "gaia")
        finally:
            shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    unittest.main()
