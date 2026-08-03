#!/usr/bin/env python3
"""WEB fix verification — index.html and map.html, the two frozen board pages.

Covers three adversarially-verified defects:

  F1  launchMission() had no submit lock, so a double-click fired two
      POST /api/dispatch — two agents for one mission.
  F2  esc() HTML-encodes for a text node; dropped into a single-quoted JS
      string inside an inline onclick, an apostrophe in a worktree name
      (esc'd to &#39;, which the parser decodes back to ') broke out of the
      string and could inject arbitrary JS at the board's full-privilege origin.
  F3  map.html keyed its node registry on the esc()'d name but read it back via
      dataset (HTML-decoded), so a name with &<>"' looked up a key the registry
      never stored — the node went inert.

The escaping and lookup-key claims are checked by driving the SHIPPED helpers
(esc / escArg extracted verbatim from each page) through node — a browser's
HTML-attribute decode is simulated, then the decoded expression is evaluated in
a sandbox that records what the handler actually receives and whether anything
injected ran. The submit-lock and the source-level facts are checked by reading
the files. These tests fail on the pre-fix source and pass on the fixed source.
"""

import re
import shutil
import subprocess
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
INDEX = ROOT / "index.html"
MAP = ROOT / "map.html"
LIMITS = ROOT / "limits.html"
NODE = shutil.which("node")


def _extract_const(src, name):
    """Pull a `const <name> = ...;` one-liner out of the page, verbatim."""
    m = re.search(r"^const %s = .*;$" % re.escape(name), src, re.MULTILINE)
    if not m:
        raise AssertionError("could not find `const %s` in the page" % name)
    return m.group(0)


class SubmitLock(unittest.TestCase):
    """F1 — launchMission must not let a second click reach the wire while the
    first POST is in flight."""

    def setUp(self):
        self.src = INDEX.read_text()

    def test_a_submitting_lock_exists_and_is_declared(self):
        self.assertIn("let submitting = false;", self.src,
                      "no dedicated submit lock declared")

    def test_the_lock_is_checked_before_the_textarea_is_cleared(self):
        body = self.src[self.src.index("async function launchMission"):]
        body = body[:body.index("\nfunction showModelDecision")]
        # the early-return guard, the set, the textarea clear and the release
        guard = body.index("if (submitting) return;")
        setit = body.index("submitting = true;")
        clear = body.index('$("mText").value = "";')
        release = body.index("submitting = false;")
        self.assertLess(guard, setit, "guard must precede the set")
        # the lock is taken before the input is emptied, so the second click —
        # which would otherwise read the same text back off inFlight — is stopped
        self.assertLess(setit, clear, "lock must be taken before clearing input")
        # and released after the fetch, on every path (a finally)
        self.assertLess(clear, release, "lock must be released after the launch")
        self.assertRegex(body, r"finally\s*\{\s*submitting = false;",
                         "the release must be in a finally so every path clears it")

    def test_the_lock_is_separate_from_inFlight(self):
        # the brief is explicit: `inFlight` is reused by relaunch on purpose, so
        # the double-click guard has to be its own variable
        self.assertIn("let inFlight = null;", self.src)
        self.assertNotIn("if (inFlight) return;", self.src)


@unittest.skipUnless(NODE, "node not available")
class JsStringEscaping(unittest.TestCase):
    """F2 — identifiers interpolated into an inline onclick must survive both
    the HTML-attribute decode and the JS-string parse without breaking out."""

    # reverse of esc(): one pass, exactly what a browser does to an attribute
    DECODE = r"""
    function htmlDecodeAttr(s) {
      return s.replace(/&(amp|lt|gt|quot|#39);/g,
        (_, e) => ({amp:"&", lt:"<", gt:">", quot:'"', "#39":"'"}[e]));
    }
    """

    def _run(self, page, arg_expr_template, name):
        """Build `handler(<escArg output>)` the way the page does, put it in an
        onclick attribute, decode the attribute, and eval the result in a
        sandbox. Returns [received-arg, injected-flag]."""
        src = page.read_text()
        esc = _extract_const(src, "esc")
        escArg = _extract_const(src, "escArg")
        arg = arg_expr_template  # a JS expression that uses escArg(...)
        driver = f"""
        {esc}
        {escArg}
        {self.DECODE}
        const NAME = {name!r};
        // exactly how the page interpolates it into the attribute
        const attr = "handler(" + ({arg}) + ")";
        const decoded = htmlDecodeAttr(attr);   // what the JS engine actually sees
        let received = null, injected = false;
        const handler = (x) => {{ received = x; }};
        // if the string broke out, THIS assignment would run
        globalThis.__inject = () => {{ injected = true; }};
        eval(decoded);
        process.stdout.write(JSON.stringify([received, injected]));
        """
        proc = subprocess.run([NODE, "-e", driver],
                              capture_output=True, text=True, timeout=30)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        import json
        return json.loads(proc.stdout)

    def test_apostrophe_name_reaches_the_handler_intact(self):
        # a benign name that the old esc()-in-a-quote path silently killed
        received, injected = self._run(INDEX, "escArg(NAME)", "john's-branch|s-1")
        self.assertEqual(received, "john's-branch|s-1")
        self.assertFalse(injected)

    def test_a_breakout_payload_cannot_inject(self):
        # the RCE case: a worktree name crafted to escape the string and run JS
        payload = "x');globalThis.__inject();openChat('"
        received, injected = self._run(INDEX, "escArg(NAME)", payload)
        self.assertEqual(received, payload, "the whole name must arrive as data")
        self.assertFalse(injected, "no interpolated identifier may execute")

    def test_double_quote_payload_cannot_inject(self):
        payload = 'x");globalThis.__inject();openChat("'
        received, injected = self._run(INDEX, "escArg(NAME)", payload)
        self.assertEqual(received, payload)
        self.assertFalse(injected)

    def test_map_focus_handler_is_injection_safe(self):
        payload = "x');globalThis.__inject();('"
        received, injected = self._run(MAP, "escArg(NAME)", payload)
        self.assertEqual(received, payload)
        self.assertFalse(injected)

    def test_the_pages_no_longer_single_quote_esc_into_openchat(self):
        # the exact pre-fix shape must be gone from both handlers
        idx = INDEX.read_text()
        self.assertNotIn("openChat('${esc(w.name)}|${esc(s.sid)}')", idx)
        self.assertNotIn("openChat('${esc(key)}')", idx)
        mp = MAP.read_text()
        self.assertNotIn("tipFocus('${esc(b.worktree)}')", mp)
        self.assertNotIn("tipFinish(this, '${esc(b.worktree)}')", mp)


@unittest.skipUnless(NODE, "node not available")
class MapLookupKeyAgreement(unittest.TestCase):
    """F3 — the registry key and the key read back off the DOM must agree for a
    worktree name containing an HTML-special character."""

    def test_stored_key_matches_the_decoded_dataset_read(self):
        src = MAP.read_text()
        esc = _extract_const(src, "esc")
        # a name with every special char esc() touches
        driver = f"""
        {esc}
        const name = 'a&b<c>d"e' + String.fromCharCode(39) + 'f';
        const storedKey = "b:" + name;              // lookup is keyed on the RAW name
        const attrValue = esc("b:" + name);          // data-key is written esc'd
        // dataset returns the HTML-DECODED attribute value
        function htmlDecodeAttr(s) {{
          return s.replace(/&(amp|lt|gt|quot|#39);/g,
            (_, e) => ({{amp:"&", lt:"<", gt:">", quot:'"', "#39":"'"}}[e]));
        }}
        const readKey = htmlDecodeAttr(attrValue);
        process.stdout.write(JSON.stringify([storedKey, readKey]));
        """
        proc = subprocess.run([NODE, "-e", driver],
                              capture_output=True, text=True, timeout=30)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        import json
        stored, read = json.loads(proc.stdout)
        self.assertEqual(stored, read,
                         "lookup key and dataset read must resolve to the same string")

    def test_source_keys_lookup_on_raw_name_and_writes_esc_attribute(self):
        src = MAP.read_text()
        # both node builders (branches + riders) key on the raw name now
        self.assertEqual(src.count("const key = `b:${b.worktree}`;"), 2)
        self.assertNotIn("const key = `b:${esc(b.worktree)}`;", src)
        # and the attribute is the escaped one
        self.assertIn('data-key="${esc(key)}"', src)
        self.assertNotIn('data-key="${key}"', src)


# ------------------------------------------------ F4: Idempotency-Key on POSTs

PAGES = (("index.html", INDEX), ("map.html", MAP), ("limits.html", LIMITS))


def _post_sites(src):
    """(index, the 240 chars that follow) for every mutation POST on a page."""
    out, at = [], 0
    while True:
        at = src.find('method: "POST"', at)
        if at == -1:
            return out
        out.append((at, src[at:at + 240]))
        at += 1


def _extract_fn(src, name):
    """A `function <name>() { … }` block, verbatim, to its column-0 brace."""
    start = src.index(f"function {name}(")
    return src[start:src.index("\n}\n", start) + 3]


class IdempotencyKeyIsSent(unittest.TestCase):
    """F4 — the server's idempotency layer (orchestra/idem.py, wired in
    `server.do_POST`) is OPT-IN per request: with no `Idempotency-Key` header
    there is no reservation, no replay, and a retry that lands after a restart
    re-runs the side effect. The iOS client has sent one on every mutation since
    `Endpoint.freshIdempotency`; the three board pages sent none, so the client
    on the same machine as the fleet was the unprotected one."""

    def test_every_mutation_post_carries_the_headers(self):
        for label, page in PAGES:
            src = page.read_text()
            sites = _post_sites(src)
            self.assertTrue(sites, f"{label}: no POST found — did the page move?")
            for at, window in sites:
                self.assertIn("headers: idemHeaders()", window,
                              f"{label}: the POST at offset {at} sends no key")

    def test_no_page_still_hand_writes_a_content_type_only_header_on_a_post(self):
        for label, page in PAGES:
            for at, window in _post_sites(page.read_text()):
                self.assertNotIn('headers: { "Content-Type": "application/json" }',
                                 window, f"{label}: bare headers at offset {at}")

    def test_the_routes_covered_are_the_server_s_mutation_routes(self):
        """Not "some POSTs" — the ones idem.py actually guards. `/api/send`,
        `/api/finish`, `/api/dispatch`, `/api/reserve` and both `/api/resume`
        routes are the whole of `idem.MUTATION_ROUTES`; a board POST to one of
        them without a key is a gap in the layer, not an oversight in a page."""
        import orchestra as fb
        joined = "".join(p.read_text() for _, p in PAGES)
        for route in sorted(fb.idem.MUTATION_ROUTES):
            stem = route.rsplit("/", 1)[0] if route.startswith("/api/resume") \
                else route
            self.assertIn(stem, joined, f"{route} is not reachable from the board")

    def test_each_page_mints_its_own_key(self):
        for label, page in PAGES:
            src = page.read_text()
            self.assertIn("function idemKey()", src, label)
            self.assertIn("function idemHeaders()", src, label)
            # per TAP, not per payload: the key is minted inside the mint, and
            # nothing stores one on a module-level variable to be reused
            self.assertNotIn("const IDEM_KEY", src, label)


@unittest.skipUnless(NODE, "node not available")
class IdempotencyHeaderShape(unittest.TestCase):
    """The SHIPPED mint, run through node — the header names and the value
    shapes have to match what `idem.begin` and `_idem_issued_at` read."""

    def _mint(self, page, drop_random_uuid=False):
        src = page.read_text()
        driver = f"""
        const self = globalThis;
        {"delete crypto.randomUUID;" if drop_random_uuid else ""}
        {_extract_fn(src, "idemKey")}
        {_extract_fn(src, "idemHeaders")}
        process.stdout.write(JSON.stringify([idemHeaders(), idemHeaders()]));
        """
        proc = subprocess.run([NODE, "-e", driver],
                              capture_output=True, text=True, timeout=30)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        import json
        return json.loads(proc.stdout)

    UUID = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}"
                      r"-[89ab][0-9a-f]{3}-[0-9a-f]{12}$")

    def test_the_header_names_are_the_ones_the_server_reads(self):
        first, _ = self._mint(INDEX)
        self.assertEqual(first["Content-Type"], "application/json")
        self.assertIn("Idempotency-Key", first)
        self.assertIn("Idempotency-Issued-At", first)

    def test_two_taps_are_two_keys(self):
        first, second = self._mint(INDEX)
        self.assertNotEqual(first["Idempotency-Key"], second["Idempotency-Key"],
                            "a reused key would replay the FIRST answer")

    def test_the_key_is_a_v4_uuid_on_every_page(self):
        for label, page in PAGES:
            first, _ = self._mint(page)
            self.assertRegex(first["Idempotency-Key"], self.UUID, label)

    def test_the_fallback_mints_a_v4_uuid_too(self):
        """`crypto.randomUUID` is exposed only in a secure context, and this
        board is served over plain HTTP on the tailnet — which is precisely
        where the phone opens it."""
        first, second = self._mint(INDEX, drop_random_uuid=True)
        self.assertRegex(first["Idempotency-Key"], self.UUID)
        self.assertNotEqual(first["Idempotency-Key"], second["Idempotency-Key"])

    def test_issued_at_is_a_float_epoch_in_seconds(self):
        import time
        first, _ = self._mint(INDEX)
        raw = first["Idempotency-Issued-At"]
        self.assertRegex(raw, r"^\d+\.\d{3}$", "a fixed '.' and milliseconds")
        # inside idem.IDEM_EXPIRE_S of now, or the server refuses it as expired
        self.assertLess(abs(float(raw) - time.time()), 60)


if __name__ == "__main__":
    unittest.main()
