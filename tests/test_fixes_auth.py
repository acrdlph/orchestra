#!/usr/bin/env python3
"""Regression tests for the AUTH fixes — the audit-flood ceiling, the pairing
door, the corrupt-registry 503, and the registry flock.

Each test is written to FAIL on the code as it was before the fix and PASS
after. They isolate exactly as `tests/test_auth.py::AuthCase` does — a private
registry and audit log rebound at runtime, an empty budget, and the stat-keyed
memo dropped between cases.

    python3 -m unittest tests.test_fixes_auth -v
"""

import fcntl
import os
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

TAILNET = "100.64.0.9"          # a plausible peer that is not this machine


class FixCase(unittest.TestCase):
    def setUp(self):
        self.dir = Path(tempfile.mkdtemp(prefix="fb-fix-auth-"))
        self._saved = (fb.auth.REGISTRY, fb.auth.AUDIT_LOG)
        fb.auth.REGISTRY = self.dir / "devices.json"
        fb.auth.AUDIT_LOG = self.dir / "audit.log.jsonl"
        fb.auth._forget_registry()
        fb.auth._reset_buckets()
        fb.pairing._reset()
        self._cfg = dict(fb.CFG)

    def tearDown(self):
        fb.auth.REGISTRY, fb.auth.AUDIT_LOG = self._saved
        fb.auth._forget_registry()
        fb.auth._reset_buckets()
        fb.pairing._reset()
        fb.CFG.clear()
        fb.CFG.update(self._cfg)
        shutil.rmtree(self.dir, ignore_errors=True)


# ---------------------------------------------------------- F1: the audit flood

class TestAuditFloodCeiling(FixCase):
    """The documented 10 lines/min/IP ceiling exists now, on both doors."""

    def test_an_exhausted_peer_stops_writing_to_the_audit_log(self):
        """The primary flood: a 429-throttled peer wrote one line PER REQUEST.

        Once the budget is burned, the log must stop growing — at most the one
        `throttled` marker beyond the burst that drained it.
        """
        for _ in range(fb.auth.FAIL_BURST):
            fb.auth.check(TAILNET, "Bearer wrong", "GET", "/api/state",
                          now=1000.0)
        settled = len(fb.auth.read_audit())
        for _ in range(500):
            v = fb.auth.check(TAILNET, "Bearer wrong", "GET", "/api/state",
                              now=1000.0)
            self.assertEqual(v.status, 429)          # every one is throttled
        grew_by = len(fb.auth.read_audit()) - settled
        self.assertLessEqual(grew_by, 1, "the 429 flood is still writing a line "
                                         "per request")

    def test_the_crossing_leaves_exactly_one_throttled_marker(self):
        for _ in range(fb.auth.FAIL_BURST * 4):
            fb.auth.check(TAILNET, "Bearer wrong", "GET", "/api/state",
                          now=1000.0)
        markers = [l for l in fb.auth.read_audit()
                   if l.get("outcome") == "throttled"]
        self.assertEqual(len(markers), 1)
        self.assertEqual(markers[0]["code"], fb.auth.AUDIT_THROTTLED)
        self.assertEqual(markers[0]["peer"], TAILNET)

    def test_an_unauthenticated_pairing_flood_is_bounded(self):
        """No window open, so every claim refuses `pairing_not_open`. Through
        the door this used to be TWO disk writes per request (an `allow` from
        `auth.check` and a `refuse` from `pairing._audit`), unthrottled, from an
        unauthenticated peer. It must now be bounded by the failure budget."""
        for _ in range(400):
            v = fb.auth.check(TAILNET, None, "POST", "/api/v1/pair", now=1000.0,
                              content_type="application/json")
            if v.ok:
                fb.pairing.claim(TAILNET, {"code": "AAAAAAAA"}, now=1000.0)
        lines = fb.auth.read_audit()
        self.assertLess(len(lines), 3 * fb.auth.FAIL_BURST,
                        f"the pairing door wrote {len(lines)} lines under a "
                        f"400-request flood")

    def test_the_pairing_door_closes_when_the_budget_is_burned(self):
        """`POST /api/v1/pair` was EXEMPT above the budget, so it answered a
        flood forever. It must now consult the same bucket and refuse 429."""
        for _ in range(fb.auth.FAIL_BURST):
            v = fb.auth.check(TAILNET, None, "POST", "/api/v1/pair", now=1000.0,
                              content_type="application/json")
            if v.ok:
                fb.pairing.claim(TAILNET, {"code": "AAAAAAAA"}, now=1000.0)
        v = fb.auth.check(TAILNET, None, "POST", "/api/v1/pair", now=1000.0,
                          content_type="application/json")
        self.assertEqual(v.status, 429)
        self.assertEqual(v.code, fb.auth.RATE_LIMITED)

    def test_health_still_answers_a_peer_that_has_burned_its_budget(self):
        """The pairing gate must not have dragged `/api/health` below the
        budget — it is the route you use to diagnose a burned credential."""
        for _ in range(fb.auth.FAIL_BURST + 5):
            fb.auth.check(TAILNET, "Bearer wrong", "GET", "/api/state",
                          now=1000.0)
        self.assertTrue(fb.auth.check(TAILNET, None, "GET", "/api/health",
                                      now=1000.0).ok)

    def test_a_single_refusal_is_still_recorded(self):
        """The gate must not suppress the lines that matter: one refusal from a
        peer with budget is still one audit line."""
        fb.auth.check(TAILNET, "Bearer orc1_abcdef01_nope", "GET", "/api/state",
                      now=1000.0)
        lines = fb.auth.read_audit()
        self.assertEqual(len(lines), 1)
        self.assertEqual(lines[0]["outcome"], "refuse")


# ----------------------------------------------- F4: the structurally corrupt registry

class TestCorruptRegistryFailsClosed(FixCase):
    """A registry that is valid JSON but the wrong SHAPE crashed every request
    with an AttributeError; it must be the designed 503 instead."""

    SHAPES = ('{"devices": ["x"]}',            # a list of non-dicts
              '{"devices": "abcd"}',           # a string (iterates characters)
              '{"devices": {"a": 1}}',         # a dict (iterates keys)
              '{"devices": [1, 2, 3]}')        # a list of ints

    def test_a_corrupt_registry_is_503_not_a_traceback(self):
        for blob in self.SHAPES:
            fb.auth.REGISTRY.write_text(blob)
            fb.auth._forget_registry()
            fb.auth._reset_buckets()
            v = fb.auth.check(TAILNET, "Bearer orc1_abcdef01_" + "x" * 43,
                              "GET", "/api/state", now=1000.0)
            self.assertEqual((v.status, v.code),
                             (503, fb.auth.UNAVAILABLE), blob)

    def test_a_corrupt_registry_refuses_the_bind_instead_of_crashing(self):
        fb.auth.REGISTRY.write_text('{"devices": ["x"]}')
        fb.auth._forget_registry()
        why = fb.auth.bind_refusal("100.113.110.31")
        self.assertIsNotNone(why)
        self.assertIn("cannot be read", why)

    def test_the_board_still_works_while_the_registry_is_corrupt(self):
        """Loopback trust is decided before the registry is opened, so the local
        browser is not taken down with it — even by the shape that used to
        raise."""
        fb.auth.REGISTRY.write_text('{"devices": ["x"]}')
        fb.auth._forget_registry()
        self.assertTrue(fb.auth.check("127.0.0.1", None, "GET", "/api/state",
                                      now=1000.0).ok)


# ------------------------------------------------------- F3: the registry flock

class TestRegistryFlock(FixCase):
    """Every load-modify-write serialises on a cross-process flock, so a
    `--revoke-device` in another process cannot be silently clobbered."""

    def _mint(self):
        device, _ = fb.auth.add_device("iPhone")
        return device["id"]

    def test_a_writer_blocks_on_a_lock_another_process_holds(self):
        """Hold the sidecar lock as `--revoke-device` in a second process would,
        and assert an in-process writer cannot complete until it is released.
        Before the fix there was no flock, so the writer sailed straight
        through."""
        devid = self._mint()
        lockpath = fb.auth.REGISTRY.with_suffix(".lock")
        fd = os.open(lockpath, os.O_WRONLY | os.O_CREAT, 0o600)
        fcntl.flock(fd, fcntl.LOCK_EX)
        done = threading.Event()

        def writer():
            fb.auth.revoke_device(devid, now=2000.0)
            done.set()

        t = threading.Thread(target=writer, daemon=True)
        t.start()
        try:
            # While the lock is held elsewhere, the revoke must not land.
            self.assertFalse(done.wait(0.6),
                             "a writer completed while another process held the "
                             "registry lock — there is no flock")
            fcntl.flock(fd, fcntl.LOCK_UN)
            os.close(fd)
            fd = None
            # …and once released it goes through and the revoke sticks.
            self.assertTrue(done.wait(3.0))
        finally:
            if fd is not None:
                os.close(fd)
            t.join(3.0)
        fb.auth._forget_registry()
        self.assertIsNotNone(fb.auth.devices()[0]["revoked"])

    def test_the_lock_does_not_break_ordinary_writes(self):
        """The lock must be invisible in the common single-process case: mint,
        touch, revoke all still work."""
        devid = self._mint()
        fb.auth.check(TAILNET, "Bearer nope", "GET", "/x", now=1.0)  # noise
        # a normal touch-through-check records last_seen
        _, token = fb.auth.add_device("phone2")
        v = fb.auth.check(TAILNET, f"Bearer {token}", "GET", "/api/state",
                          now=5000.0)
        self.assertTrue(v.ok)
        fb.auth._forget_registry()
        seen = {d["id"]: d.get("last_seen") for d in fb.auth.devices()}
        self.assertEqual(seen[v.device["id"]], 5000.0)
        self.assertIsNotNone(fb.auth.revoke_device(devid))


# ------------------------------------------------ H1: side-effecting GETs cross-site

class TestActingGetsAreCrossSiteGuarded(FixCase):
    """A GET that ACTS is reachable from a page you merely VISIT.

    `same_origin` waves a tag-initiated GET through — an `<img>`/`<script>`
    sends no `Origin`, and absent is same-origin per fetch — so `/api/focus`
    (osascript), `/api/events` (an SSE slot; 32 exhaust the ceiling) and
    `/api/limits?refresh=1` (cclimits) were reachable cross-site from any web
    page. The close is `Sec-Fetch-Site`, a header a browser sets and page JS
    cannot: PRESENT and cross-site is refused; ABSENT (curl, phone, loopback)
    still passes because it arrived with a token or loopback trust.
    """

    LOOPBACK = "127.0.0.1"
    HOST = "127.0.0.1:4242"

    def test_a_cross_site_tag_get_to_focus_is_refused(self):
        v = fb.auth.check(self.LOOPBACK, None, "GET", "/api/focus?pid=1",
                          now=1000.0, host=self.HOST,
                          sec_fetch_site="cross-site")
        self.assertEqual((v.status, v.code), (403, fb.auth.CROSS_SITE))

    def test_a_cross_site_tag_get_to_events_is_refused(self):
        v = fb.auth.check(self.LOOPBACK, None, "GET", "/api/events",
                          now=1000.0, host=self.HOST,
                          sec_fetch_site="cross-site")
        self.assertEqual((v.status, v.code), (403, fb.auth.CROSS_SITE))

    def test_a_cross_site_refresh_limits_is_refused(self):
        v = fb.auth.check(self.LOOPBACK, None, "GET", "/api/limits?refresh=1",
                          now=1000.0, host=self.HOST,
                          sec_fetch_site="cross-site")
        self.assertEqual((v.status, v.code), (403, fb.auth.CROSS_SITE))

    def test_a_plain_limits_read_is_not_guarded(self):
        # a read that does not spawn cclimits is not an acting GET, so a
        # cross-site value does not refuse it (it is just data).
        v = fb.auth.check(self.LOOPBACK, None, "GET", "/api/limits",
                          now=1000.0, host=self.HOST,
                          sec_fetch_site="cross-site")
        self.assertTrue(v.ok)

    def test_the_same_origin_sse_open_still_passes(self):
        # the board's own EventSource — same-origin, loopback, no token.
        v = fb.auth.check(self.LOOPBACK, None, "GET", "/api/events",
                          now=1000.0, host=self.HOST,
                          sec_fetch_site="same-origin")
        self.assertTrue(v.ok)

    def test_a_bearer_token_curl_with_no_header_passes(self):
        # a non-browser client sends no Sec-Fetch-Site; it carries a token. It
        # also sends no Host here (curl need not), which host_allowed passes —
        # this test is about the Sec-Fetch guard, not the host allowlist.
        _, token = fb.auth.add_device("cli")
        v = fb.auth.check(TAILNET, f"Bearer {token}", "GET", "/api/focus?pid=1",
                          now=1000.0)
        self.assertTrue(v.ok)

    def test_a_loopback_curl_with_no_header_passes(self):
        v = fb.auth.check(self.LOOPBACK, None, "GET", "/api/focus?pid=1",
                          now=1000.0, host=self.HOST)
        self.assertTrue(v.ok)

    def test_an_unrecognised_sec_fetch_value_fails_closed(self):
        # page JS cannot set this header, so a value outside the known set is
        # not a browser we trust — refuse, do not guess.
        v = fb.auth.check(self.LOOPBACK, None, "GET", "/api/focus?pid=1",
                          now=1000.0, host=self.HOST,
                          sec_fetch_site="banana")
        self.assertEqual((v.status, v.code), (403, fb.auth.CROSS_SITE))

    def test_the_cross_site_refusal_does_not_spend_the_budget(self):
        # a visited page hammering /api/focus must not lock out the real phone.
        for _ in range(fb.auth.FAIL_BURST * 3):
            fb.auth.check(self.LOOPBACK, None, "GET", "/api/focus",
                          now=1000.0, host=self.HOST,
                          sec_fetch_site="cross-site")
        _, token = fb.auth.add_device("phone")
        self.assertTrue(fb.auth.check(TAILNET, f"Bearer {token}", "GET",
                                      "/api/state", now=1000.0).ok)

    def test_events_opens_are_audited(self):
        # the audit half of H1: an /api/events open earns a line, where before
        # `audited("GET", "/api/events")` was False.
        self.assertTrue(fb.auth.audited("GET", "/api/events"))
        self.assertTrue(fb.auth.audited("GET", "/api/events?foo=1"))
        fb.auth.check(self.LOOPBACK, None, "GET", "/api/events", now=1000.0,
                      host=self.HOST, sec_fetch_site="same-origin")
        line, = fb.auth.read_audit()
        self.assertEqual((line["path"], line["outcome"]),
                         ("/api/events", "allow"))


# --------------------------------------------- M2: _under_admin on the raw path

class TestAdminDecidesOnRawPath(FixCase):
    """`_under_admin` decides on the RAW request path, so a traversal that slips
    under the `self` carve-out must fail safe to admin, never self-service — the
    twin of the `/api/v1/devicesX` incident."""

    def test_a_traversal_under_self_is_not_self_service(self):
        # matches SELF_SUBTREE + "/" by prefix, yet addresses another device's
        # revoke; before the fix this classified as self and returned False.
        p = "/api/v1/devices/self/../aabbccdd/revoke"
        self.assertTrue(fb.auth._under_admin(p))
        self.assertTrue(fb.auth.admin("POST", p))

    def test_a_double_slash_is_admin_required(self):
        self.assertTrue(fb.auth._under_admin("/api/v1/devices//self"))

    def test_a_percent_encoded_slash_is_admin_required(self):
        self.assertTrue(
            fb.auth._under_admin("/api/v1/devices/self%2f..%2faabbccdd/revoke"))
        self.assertTrue(
            fb.auth._under_admin("/api/v1/devices/self%2F../x/revoke"))

    def test_a_clean_self_route_is_still_self_service(self):
        # the guard must not have swallowed the legitimate self subtree.
        self.assertFalse(fb.auth._under_admin("/api/v1/devices/self"))
        self.assertFalse(fb.auth._under_admin("/api/v1/devices/self/push"))
        self.assertFalse(fb.auth._under_admin("/api/v1/devices/self/settings"))


if __name__ == "__main__":
    unittest.main()
