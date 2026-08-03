"""Fixes for orchestra.server — the legacy GET chain reads a DECODED query.

Same shape as `tests/test_fixes_server.py`: `Handler` is driven DIRECTLY, on an
instance built with `__new__` (so `parse_request`/`auth.check` never runs — every
test here is about what the handler does with a request the door already let in)
and a `BytesIO` in place of the wire.

Two defects, each of which passes every existing test:

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


if __name__ == "__main__":
    unittest.main()
