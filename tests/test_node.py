#!/usr/bin/env python3
"""The node identity and the card key (ADR 0016 Phase 0, docs/mobile/NODES.md).

Three groups of claims, one file, because they are one contract:

* **the id** — stable, persisted, human-meaningful, overridable, refusable.
* **the key algebra** — `<node>/<worktree>` joins and splits unambiguously,
  and a card without a node cannot be keyed at all.
* **the door** — every acting route's `worktree` parameter resolves to a
  node-local bare name or to a refusal that names the node; a bare name reads
  as "the local node", because a bare name can never address a remote machine.

    python3 -m unittest discover -s tests
"""

import json
import shutil
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))
import orchestra as fb  # noqa: E402


class NodeCase(unittest.TestCase):
    """Its own node.json in a tmpdir, no config override, a cold cache."""

    def setUp(self):
        self.dir = Path(tempfile.mkdtemp(prefix="fb-node-"))
        self._file = fb.node.NODE_FILE
        fb.node.NODE_FILE = self.dir / "node.json"
        self._cfg_node = fb.CFG.get("node")
        fb.CFG["node"] = ""
        fb.node._reset()

    def tearDown(self):
        fb.node.NODE_FILE = self._file
        fb.CFG["node"] = self._cfg_node
        fb.node._reset()
        shutil.rmtree(self.dir, ignore_errors=True)


class TheId(NodeCase):
    def test_generated_id_is_valid_and_persists(self):
        nid = fb.node.node_id()
        self.assertTrue(fb.node.valid(nid))
        on_disk = json.loads(fb.node.NODE_FILE.read_text())
        self.assertEqual(on_disk["id"], nid)

    def test_the_id_is_stable_across_processes(self):
        """A restart — simulated by dropping the in-process cache — reads the
        same id back. Stability is the entire reason the file exists."""
        first = fb.node.node_id()
        fb.node._reset()
        self.assertEqual(fb.node.node_id(), first)

    def test_the_id_survives_a_hostname_change(self):
        """The persisted id wins over whatever the hostname is today — that is
        the ADR's 'hostnames change and are not unique'."""
        fb.node.NODE_FILE.write_text(json.dumps({"version": 1, "id": "old-mac"}))
        self.assertEqual(fb.node.node_id(), "old-mac")

    def test_a_corrupt_file_regenerates_rather_than_crashes(self):
        fb.node.NODE_FILE.write_text("not json")
        nid = fb.node.node_id()
        self.assertTrue(fb.node.valid(nid))
        self.assertEqual(json.loads(fb.node.NODE_FILE.read_text())["id"], nid)

    def test_the_config_override_wins_and_writes_nothing(self):
        fb.CFG["node"] = "work"
        self.assertEqual(fb.node.node_id(), "work")
        self.assertFalse(fb.node.NODE_FILE.exists(),
                         "an override must not mint a file it will never read")

    def test_a_bad_override_raises_rather_than_keying_cards(self):
        for bad in ("Work", "a/b", "a|b", "", " ", "-x", "a" * 33, "über"):
            fb.CFG["node"] = bad
            if not bad.strip():
                continue        # falsy overrides fall through to generation
            with self.assertRaises(ValueError, msg=repr(bad)):
                fb.node.node_id()

    def test_the_format(self):
        for ok in ("a", "work", "gaia-7f3k", "m1-pro", "x" * 32):
            self.assertTrue(fb.node.valid(ok), ok)
        for bad in ("", "A", "a_b", "a/b", "a|b", "a b", "-a", "x" * 33,
                    None, 7, "café"):
            self.assertFalse(fb.node.valid(bad), repr(bad))

    def test_the_slug_reduces_a_hostname_to_the_id_charset(self):
        self.assertEqual(fb.node._slug("Achills-MacBook-Pro.local"),
                         "achills-macbook-pro")
        self.assertEqual(fb.node._slug("My Mac (2)"), "my-mac-2")
        self.assertEqual(fb.node._slug("...."), "node")
        self.assertEqual(fb.node._slug(""), "node")
        self.assertTrue(len(fb.node._slug("x" * 99)) <= 24)


class TheKey(NodeCase):
    def test_join_and_split_round_trip(self):
        fb.CFG["node"] = "gaia"
        self.assertEqual(fb.node.key("ConfidAI2"), "gaia/ConfidAI2")
        self.assertEqual(fb.node.split_key("gaia/ConfidAI2"),
                         ("gaia", "ConfidAI2"))

    def test_a_bare_name_splits_to_no_node(self):
        self.assertEqual(fb.node.split_key("ConfidAI2"), (None, "ConfidAI2"))

    def test_a_name_with_odd_characters_survives_the_round_trip(self):
        """Worktree names are directory basenames: spaces, dots, pipes and
        unicode are all legal in them — only `/` is impossible, which is the
        whole reason it is the separator."""
        for name in ("a b", "it's", "a|b", "naïve", "x.y"):
            self.assertEqual(fb.node.split_key(fb.node.key(name, "n1")),
                             ("n1", name))

    def test_card_key_is_strict_about_the_node_field(self):
        self.assertEqual(fb.node.card_key({"node": "n1", "name": "wt"}), "n1/wt")
        with self.assertRaises(KeyError):
            # a card the merge never stamped must fail loudly, not quietly
            # re-create the bare-name collision this key exists to end
            fb.node.card_key({"name": "wt"})


class TheDoor(NodeCase):
    def setUp(self):
        super().setUp()
        fb.CFG["node"] = "gaia"

    def test_a_bare_name_is_the_local_node(self):
        self.assertEqual(fb.node.local_name("ConfidAI2"), ("ConfidAI2", None))

    def test_a_qualified_local_key_strips_to_the_bare_name(self):
        self.assertEqual(fb.node.local_name("gaia/ConfidAI2"),
                         ("ConfidAI2", None))

    def test_a_foreign_node_is_refused_by_name(self):
        name, refusal = fb.node.local_name("work/ConfidAI2")
        self.assertIsNone(name)
        self.assertFalse(refusal["ok"])
        self.assertEqual(refusal["error"], "unknown_node")
        self.assertIn("work", refusal["message"])
        self.assertIn("gaia", refusal["message"])

    def test_falsy_in_falsy_out(self):
        """Routes keep their own empty-input refusals ("no worktree named…");
        the door must not invent a different one."""
        for empty in ("", None):
            self.assertEqual(fb.node.local_name(empty), (empty, None))


if __name__ == "__main__":
    unittest.main()
