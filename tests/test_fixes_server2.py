"""Fixes for orchestra.server — the legacy GET chain, and the headers on every answer.

Same shape as `tests/test_fixes_server.py`: `Handler` is driven DIRECTLY, on an
instance built with `__new__` (so `parse_request`/`auth.check` never runs — every
test here is about what the handler does with a request the door already let in)
and a `BytesIO` in place of the wire.

Three defects, each of which passes every existing test:

  Q1  `/api/chat` matched its parameters out of the RAW path
      (`account=([^&]+)`), so an account label containing a space, a `+` or a
      non-ASCII character arrived percent-encoded and matched no discovered
      Claude home. The chat drawer was simply empty, for that user, forever.
      `_query` — the decoder `/api/focus` already uses — is the fix.
  Q2  `/api/dispatch/status` answered a MISSING `job=` with the same
      `200 {"ok":false,…}` it answers an unknown one with, so a client with a
      broken URL could not tell "you asked wrong" from "that job is gone" and
      polled forever. The missing/empty case is now a 400; the unknown-but-
      well-formed case keeps its 200 body, which both boards branch on.
  Q3  `X-Content-Type-Options: nosniff` and `Referrer-Policy: no-referrer` were
      on no response at all.
"""

import http.client
import io
import json
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import orchestra as fb  # noqa: E402


def _handler(path, body=b"", command="GET", **headers):
    """A `Handler` wired to in-memory buffers, ready for `do_GET`/`do_POST`."""
    h = fb.Handler.__new__(fb.Handler)
    h.path = path
    h.command = command
    h.requestline = f"{command} {path} HTTP/1.0"
    h.request_version = "HTTP/1.0"
    h.protocol_version = "HTTP/1.0"
    h.client_address = ("127.0.0.1", 54321)
    h.close_connection = False
    h.headers = http.client.HTTPMessage()
    for key, val in headers.items():
        h.headers[key.replace("_", "-")] = str(val)
    h.rfile = io.BytesIO(body)
    h.wfile = io.BytesIO()
    return h


def _status(h):
    return int(h.wfile.getvalue().split(b"\r\n", 1)[0].split(b" ")[1])


def _headers(h):
    """The response headers, lowercased keys -> value."""
    head = h.wfile.getvalue().split(b"\r\n\r\n", 1)[0].decode("latin-1")
    out = {}
    for line in head.split("\r\n")[1:]:
        if ":" in line:
            k, v = line.split(":", 1)
            out[k.strip().lower()] = v.strip()
    return out


def _body(h):
    return json.loads(h.wfile.getvalue().split(b"\r\n\r\n", 1)[1])


# ------------------------------------------------------------ Q1: /api/chat

class TestChatQueryIsDecoded(unittest.TestCase):

    def setUp(self):
        self._read = fb.chat.read_chat
        self.seen = []
        fb.chat.read_chat = lambda account, sid: (
            self.seen.append((account, sid)) or {"ok": True, "messages": []})

    def tearDown(self):
        fb.chat.read_chat = self._read

    def test_an_account_label_with_a_space_round_trips(self):
        # `~/.claude-side project` labels as `side project`. Pre-fix the handler
        # passed the literal `side%20project` to a comparison against the
        # decoded label, so this drawer could never load.
        h = _handler("/api/chat?account=side%20project&sid=abc-123")
        h.do_GET()
        self.assertEqual(_status(h), 200)
        self.assertEqual(self.seen, [("side project", "abc-123")])

    def test_a_plus_in_a_label_is_a_plus_and_not_a_space(self):
        h = _handler("/api/chat?account=work%2Bpersonal&sid=abc-123")
        h.do_GET()
        self.assertEqual(self.seen, [("work+personal", "abc-123")])

    def test_a_non_ascii_label_arrives_as_text(self):
        h = _handler("/api/chat?account=caf%C3%A9&sid=abc-123")
        h.do_GET()
        self.assertEqual(self.seen, [("café", "abc-123")])

    def test_parameter_order_does_not_matter(self):
        h = _handler("/api/chat?sid=abc-123&account=main")
        h.do_GET()
        self.assertEqual(self.seen, [("main", "abc-123")])

    def test_a_missing_parameter_still_refuses_in_the_old_envelope(self):
        h = _handler("/api/chat?account=main")
        h.do_GET()
        self.assertEqual(_status(h), 200)
        self.assertEqual(_body(h), {"ok": False, "error": "need account & sid"})
        self.assertEqual(self.seen, [])

    def test_a_sid_that_is_not_sid_shaped_never_reaches_the_glob(self):
        # `read_chat` feeds `sid` straight into `projects/*/<sid>.jsonl`. The old
        # regex refused a slash as a side effect of matching; decoding removes
        # that accident, so the shape is asserted deliberately.
        h = _handler("/api/chat?account=main&sid=..%2F..%2Fetc%2Fpasswd")
        h.do_GET()
        self.assertEqual(_body(h)["error"], "need account & sid")
        self.assertEqual(self.seen, [])


# -------------------------------------------- Q2: /api/dispatch/status

class TestDispatchStatusValidatesItsJob(unittest.TestCase):

    def setUp(self):
        self._status_fn = fb.dispatch.dispatch_status
        self.seen = []
        fb.dispatch.dispatch_status = lambda job: (
            self.seen.append(job) or {"ok": False, "error": "unknown job"})

    def tearDown(self):
        fb.dispatch.dispatch_status = self._status_fn

    def test_no_job_parameter_is_a_400(self):
        h = _handler("/api/dispatch/status")
        h.do_GET()
        self.assertEqual(_status(h), 400)
        self.assertEqual(_body(h)["error"], "no job")
        self.assertEqual(self.seen, [], "nothing should have been looked up")

    def test_an_empty_job_parameter_is_a_400(self):
        h = _handler("/api/dispatch/status?job=")
        h.do_GET()
        self.assertEqual(_status(h), 400)
        self.assertEqual(self.seen, [])

    def test_a_whitespace_only_job_is_a_400(self):
        h = _handler("/api/dispatch/status?job=%20%20")
        h.do_GET()
        self.assertEqual(_status(h), 400)
        self.assertEqual(self.seen, [])

    def test_a_well_formed_but_unknown_job_keeps_its_200(self):
        # DELIBERATELY unchanged: index.html's pollDispatch and pollFinishJob
        # both read `s.ok` off a 200 body, and a job evicted from the ring of
        # twenty is a real answer rather than a bad request.
        h = _handler("/api/dispatch/status?job=job-121314-7")
        h.do_GET()
        self.assertEqual(_status(h), 200)
        self.assertEqual(_body(h), {"ok": False, "error": "unknown job"})
        self.assertEqual(self.seen, ["job-121314-7"])

    def test_a_known_job_is_answered_from_the_ring(self):
        fb.dispatch.dispatch_status = lambda job: {"ok": True, "done": True,
                                                   "progress": [], "result": None}
        h = _handler("/api/dispatch/status?job=job-121314-7")
        h.do_GET()
        self.assertEqual(_status(h), 200)
        self.assertTrue(_body(h)["ok"])


# ------------------------------------------------------ Q3: common headers

class TestSecurityHeadersOnEveryAnswer(unittest.TestCase):
    """`send_response` is the one choke point every answer passes through —
    including `send_error` — which is why the two headers live there."""

    WANT = {"x-content-type-options": "nosniff",
            "referrer-policy": "no-referrer"}

    def _assert_headers(self, h):
        got = _headers(h)
        for key, val in self.WANT.items():
            self.assertEqual(got.get(key), val,
                             f"{key} missing from a {_status(h)}")

    def test_on_a_plain_200(self):
        h = _handler("/api/health")
        h.do_GET()
        self.assertEqual(_status(h), 200)
        self._assert_headers(h)

    def test_on_a_404_from_send_error(self):
        h = _handler("/nope")
        h.do_GET()
        self.assertEqual(_status(h), 404)
        self._assert_headers(h)

    def test_on_a_400_from_the_json_writer(self):
        h = _handler("/api/dispatch/status")
        h.do_GET()
        self.assertEqual(_status(h), 400)
        self._assert_headers(h)

    def test_on_a_500_the_dispatcher_had_to_invent(self):
        boom = fb.observer.cached_state
        fb.observer.cached_state = lambda *a, **k: 1 / 0
        self.addCleanup(lambda: setattr(fb.observer, "cached_state", boom))
        h = _handler("/api/state")
        h.do_GET()
        self.assertEqual(_status(h), 500)
        self._assert_headers(h)

    def test_on_a_post_answer(self):
        launched = []
        real = fb.dispatch.start_dispatch
        fb.dispatch.start_dispatch = lambda *a, **k: (launched.append(a)
                                                      or {"ok": True})
        self.addCleanup(lambda: setattr(fb.dispatch, "start_dispatch", real))
        body = b'{"mission": "x"}'
        h = _handler("/api/dispatch", body=body, command="POST",
                     Content_Length=str(len(body)))
        h.do_POST()
        self.assertEqual(_status(h), 200)
        self._assert_headers(h)

    def test_no_content_security_policy_is_claimed(self):
        """CSP is deferred whole, not half-shipped: every page is pervasively
        inline. A header that says otherwise would be a promise the board
        breaks on its own first click."""
        h = _handler("/api/health")
        h.do_GET()
        self.assertNotIn("content-security-policy", _headers(h))


if __name__ == "__main__":
    unittest.main()
