#!/usr/bin/env python3
"""The full-transcript reader — orchestra/sessionlog.py, API.md §9.11.

`/api/chat` shows the phone 900 characters per turn with every newline
collapsed to a space, no tool traffic at all, and a truncation the client can
only INFER from a trailing "…". These tests pin the reader that replaces it on
the phone's chat screen, and every one of them is a property the old reader
does not have:

  * newlines survive `format=raw` (and `format=clean` still collapses them);
  * the cut is a REAL field — `truncated` plus the true `chars` — and no
    ellipsis is appended, so prose that legitimately ends in "…" is not
    mistaken for a clipped answer;
  * `tool_use` and `tool_result` are entries of their own, paired by id, so the
    result carries the tool's NAME too;
  * paging backwards by byte offset reaches byte 0 and says `has_more_before:
    false` exactly once, with no message returned twice and none skipped;
  * a 100 MB transcript is never read whole — asserted against the module's one
    read function, not hoped for;
  * a partial leading line, a garbled line and a valid-JSON scalar line are all
    skipped rather than crashed on;
  * machine text is MARKED (`meta`, and `why` names the rule) rather than
    dropped, so the client decides what to collapse;
  * `/messages/at/{off}` re-reads one line uncapped, which is what makes the
    4000-char cap safe to have.

    python3 -m unittest tests.test_fixes_sessionlog -v
"""

import http.client
import io
import json
import shutil
import tempfile
import threading
import unittest
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))
import orchestra as fb  # noqa: E402
from orchestra import config, sessionlog  # noqa: E402

SID = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"


def _obj(e):
    return json.dumps(e)


def _user(text, **kw):
    return {"type": "user", "cwd": "/w", "timestamp": "2026-08-04T10:00:00Z",
            "message": {"role": "user", "content": text}, **kw}


def _assistant(blocks, model="claude-fable-5", **kw):
    return {"type": "assistant", "cwd": "/w",
            "timestamp": "2026-08-04T10:00:01Z",
            "message": {"model": model, "content": blocks}, **kw}


def _tool_use(name, tid, inp=None):
    return {"type": "tool_use", "id": tid, "name": name, "input": inp or {}}


def _tool_result(tid, text, is_error=False):
    return {"type": "user", "cwd": "/w", "timestamp": "2026-08-04T10:00:02Z",
            "message": {"role": "user", "content": [
                {"type": "tool_result", "tool_use_id": tid, "content": text,
                 "is_error": is_error}]}}


class LogCase(unittest.TestCase):
    """One Claude home in a temp dir, one transcript in it.

    `config.CFG["homes"]` is the same override `test_fixes_transcripts` uses —
    `claude_homes()` prefers it over the auto-discovered `~/.claude*`, so a test
    never reads the machine it runs on.
    """

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="fb-sessionlog-"))
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.home = self.tmp / ".claude-test"     # account label "test"
        self.proj = self.home / "projects" / "-w"
        self.proj.mkdir(parents=True)
        self.fp = self.proj / f"{SID}.jsonl"
        self._saved = config.CFG.get("homes")
        config.CFG["homes"] = [str(self.home)]
        self.addCleanup(self._restore)

    def _restore(self):
        config.CFG["homes"] = self._saved

    def write(self, entries, path=None):
        """Entries (dicts, or raw strings for the malformed cases) as JSONL."""
        with open(path or self.fp, "w") as f:
            for e in entries:
                f.write((e if isinstance(e, str) else _obj(e)) + "\n")

    def read(self, **kw):
        return sessionlog.read_messages("test", SID, **kw)


# ------------------------------------------------------------- raw vs clean

class TestRawKeepsTheStructure(LogCase):

    def test_newlines_survive_format_raw(self):
        body = "def f():\n    return 1\n\n# done"
        self.write([_assistant([{"type": "text", "text": body}])])
        msg = self.read()["messages"][0]
        self.assertEqual(msg["text"], body)
        self.assertEqual(msg["text"].count("\n"), 3)

    def test_format_clean_still_collapses_them(self):
        # The board's behaviour, unchanged and still reachable — `clean` is
        # `_clean` minus its truncation, so a client that wants the old shape
        # asks for it rather than getting it by accident.
        self.write([_assistant([{"type": "text",
                                 "text": "one\ntwo\n\nthree"}])])
        msg = self.read(fmt="clean")["messages"][0]
        self.assertEqual(msg["text"], "one two three")

    def test_raw_strips_ansi_and_nothing_else(self):
        self.write([_assistant([{"type": "text",
                                 "text": "\x1b[31mred\x1b[0m\nplain"}])])
        self.assertEqual(self.read()["messages"][0]["text"], "red\nplain")

    def test_the_default_format_is_raw(self):
        self.write([_assistant([{"type": "text", "text": "a\nb"}])])
        self.assertEqual(self.read()["format"], "raw")
        self.assertIn("\n", self.read()["messages"][0]["text"])


# ------------------------------------------------------------ the honest cap

class TestTheCapIsHonest(LogCase):

    def test_a_long_entry_is_cut_and_says_so_without_an_ellipsis(self):
        body = "x" * 9000
        self.write([_assistant([{"type": "text", "text": body}])])
        msg = self.read()["messages"][0]
        self.assertTrue(msg["truncated"])
        self.assertEqual(msg["chars"], 9000)
        self.assertEqual(len(msg["text"]), sessionlog.MAX_ENTRY_CHARS)
        # Rule 2: the FLAG is the signal. An appended "…" is a guess the client
        # then has to un-guess, and it is wrong on the text below.
        self.assertFalse(msg["text"].endswith("…"))

    def test_text_that_legitimately_ends_in_an_ellipsis_is_not_truncated(self):
        # The exact false positive the old inference makes: a short answer that
        # ends in an ellipsis on purpose read as clipped, so the client offered
        # a "show more" that had nothing more to show.
        self.write([_assistant([{"type": "text", "text": "still thinking…"}])])
        msg = self.read()["messages"][0]
        self.assertFalse(msg["truncated"])
        self.assertEqual(msg["chars"], len("still thinking…"))
        self.assertTrue(msg["text"].endswith("…"))

    def test_chars_is_the_length_before_the_cut_not_after(self):
        self.write([_tool_result("t1", "y" * 50_000)])
        msg = self.read()["messages"][0]
        self.assertEqual(msg["chars"], 50_000)
        self.assertEqual(len(msg["text"]), sessionlog.MAX_ENTRY_CHARS)

    def test_an_entry_exactly_at_the_cap_is_not_truncated(self):
        self.write([_assistant([{"type": "text",
                                 "text": "z" * sessionlog.MAX_ENTRY_CHARS}])])
        msg = self.read()["messages"][0]
        self.assertFalse(msg["truncated"])
        self.assertEqual(msg["chars"], sessionlog.MAX_ENTRY_CHARS)


# ---------------------------------------------------------------- tool traffic

class TestToolTraffic(LogCase):

    def test_a_call_and_its_result_are_entries_that_share_the_name(self):
        self.write([
            _assistant([_tool_use("Bash", "toolu_01", {"command": "ls -la"})]),
            _tool_result("toolu_01", "a.py\nb.py"),
        ])
        msgs = self.read()["messages"]
        self.assertEqual([m["role"] for m in msgs], ["tool_use", "tool_result"])
        self.assertEqual(msgs[0]["tool"], {"name": "Bash", "id": "toolu_01",
                                           "ok": None})
        # The NAME on the result is the whole point of the pairing: without it
        # a phone renders an anonymous wall of output.
        self.assertEqual(msgs[1]["tool"]["name"], "Bash")
        self.assertEqual(msgs[1]["tool"]["id"], "toolu_01")
        self.assertIs(msgs[1]["tool"]["ok"], True)
        self.assertEqual(msgs[1]["text"], "a.py\nb.py")

    def test_a_call_carries_its_arguments_as_readable_text(self):
        self.write([_assistant([_tool_use("Write", "toolu_02",
                                          {"file_path": "/a", "content": "x"})])])
        text = self.read()["messages"][0]["text"]
        self.assertIn("file_path", text)
        self.assertIn("\n", text)               # indented, not one run-on line

    def test_is_error_rides_out_as_tool_ok_false(self):
        self.write([
            _assistant([_tool_use("Bash", "toolu_03")]),
            _tool_result("toolu_03", "boom", is_error=True),
        ])
        self.assertIs(self.read()["messages"][1]["tool"]["ok"], False)

    def test_a_tool_use_error_in_the_text_alone_is_still_a_failure(self):
        # `parse_session_tail` matches this shape rather than `is_error`, so a
        # result carrying only the marker must not read as a success here.
        self.write([_tool_result("toolu_05",
                                 "<tool_use_error>File not found</tool_use_error>")])
        self.assertIs(self.read()["messages"][0]["tool"]["ok"], False)

    def test_a_queue_operation_is_marked_as_the_harness_speaking(self):
        # A `<task-notification>` arrives in three shapes; this is the one that
        # carries its text at the TOP level, with no `message` at all.
        self.write([{"type": "queue-operation", "operation": "enqueue",
                     "content": "<task-notification><status>completed</status>"
                                "</task-notification>"}])
        msg = self.read()["messages"][0]
        self.assertEqual(msg["role"], "system")
        self.assertTrue(msg["meta"])
        self.assertEqual(msg["why"], "system")

    def test_a_result_whose_call_is_out_of_the_window_says_null(self):
        # A guess would be worse than a null here: the client would label
        # somebody else's output with the wrong tool.
        self.write([_tool_result("toolu_gone", "orphan output")])
        msg = self.read()["messages"][0]
        self.assertEqual(msg["role"], "tool_result")
        self.assertIsNone(msg["tool"]["name"])

    def test_tool_entries_are_not_meta(self):
        self.write([
            _assistant([_tool_use("Read", "toolu_04")]),
            _tool_result("toolu_04", "file body"),
        ])
        self.assertEqual([m["meta"] for m in self.read()["messages"]],
                         [False, False])


# --------------------------------------------------------------------- paging

class TestPagingBackwards(LogCase):

    def _conversation(self, turns):
        entries = []
        for n in range(turns):
            entries.append(_user(f"question {n}"))
            entries.append(_assistant([{"type": "text", "text": f"answer {n}"}]))
        self.write(entries)
        return turns * 2

    def test_paging_reaches_the_start_and_stops_exactly_once(self):
        total = self._conversation(40)
        seen, before, pages, stops = [], None, 0, 0
        while True:
            page = self.read(limit=9, before=before)
            self.assertTrue(page["ok"])
            seen = page["messages"] + seen
            pages += 1
            if not page["has_more_before"]:
                stops += 1
                break
            before = page["cursor_before"]
            self.assertIsNotNone(before)
            self.assertLess(pages, 50, "paging did not terminate")
        # Exactly once, and only on the page that actually reached byte 0.
        self.assertEqual(stops, 1)
        self.assertGreater(pages, 1)
        self.assertEqual(len(seen), total)
        self.assertEqual([m["text"] for m in seen][:2],
                         ["question 0", "answer 0"])
        # No message twice, none skipped: the offsets are strictly increasing.
        keys = [(m["off"], m["i"]) for m in seen]
        self.assertEqual(keys, sorted(keys))
        self.assertEqual(len(set(keys)), len(keys))

    def test_before_is_exclusive_so_nothing_arrives_twice(self):
        self._conversation(10)
        first = self.read(limit=5)
        second = self.read(limit=5, before=first["cursor_before"])
        self.assertTrue(second["messages"])
        self.assertLess(second["messages"][-1]["off"], first["messages"][0]["off"])

    def test_the_cursor_is_the_oldest_offset_returned(self):
        self._conversation(10)
        page = self.read(limit=6)
        self.assertEqual(page["cursor_before"], page["messages"][0]["off"])

    def test_a_short_transcript_says_there_is_nothing_before_it(self):
        self.write([_user("hello")])
        page = self.read()
        self.assertFalse(page["has_more_before"])
        self.assertEqual(len(page["messages"]), 1)

    def test_a_page_never_cuts_a_jsonl_line_in_half(self):
        # `cursor_before` is a byte offset and half a line has no offset of its
        # own, so a line that does not fit is left for the next page — the
        # client must never hold a message it cannot page back to.
        self.write([
            _assistant([{"type": "text", "text": "one"},
                        _tool_use("A", "t1"), _tool_use("B", "t2")]),
            _assistant([{"type": "text", "text": "two"},
                        _tool_use("C", "t3"), _tool_use("D", "t4")]),
        ])
        page = self.read(limit=4)
        self.assertEqual(len(page["messages"]), 3)      # the second line, whole
        self.assertEqual(len({m["off"] for m in page["messages"]}), 1)
        self.assertTrue(page["has_more_before"])
        older = self.read(limit=4, before=page["cursor_before"])
        self.assertEqual(len(older["messages"]), 3)
        self.assertFalse(older["has_more_before"])

    def test_one_line_bigger_than_the_limit_is_still_returned_whole(self):
        # The exception to the rule above: shrinking further would return an
        # empty page and a cursor that never moves.
        self.write([_assistant([_tool_use(f"T{n}", f"t{n}") for n in range(5)])])
        page = self.read(limit=2)
        self.assertEqual(len(page["messages"]), 5)
        self.assertFalse(page["has_more_before"])

    def test_bookkeeping_only_lines_do_not_stall_the_walk(self):
        # `mode`, `permission-mode` and `file-history-snapshot` open every real
        # transcript and carry nothing a terminal draws. They produce no
        # messages, and `has_more_before` must still go false on them.
        self.write([
            {"type": "mode", "mode": "normal", "sessionId": SID},
            {"type": "permission-mode", "permissionMode": "bypassPermissions"},
            {"type": "file-history-snapshot", "snapshot": {"a": "b"}},
            {"type": "system", "subtype": "turn_duration", "durationMs": 5},
            _user("the first thing anybody said"),
        ])
        page = self.read()
        self.assertEqual(len(page["messages"]), 1)
        self.assertFalse(page["has_more_before"])


# ------------------------------------------------------------- bounded reads

class TestNothingReadsAWholeTranscript(LogCase):
    """The rule this whole module exists under: a transcript can exceed 100 MB
    (the largest on the dev machine is 103,839,151 bytes), so a page must cost
    the same on that file as on a 4 KB one."""

    def _spy(self):
        reads = []
        original = sessionlog._read_span

        def spy(fp, start, end):
            reads.append(end - start)
            return original(fp, start, end)

        sessionlog._read_span = spy
        self.addCleanup(setattr, sessionlog, "_read_span", original)
        return reads

    def _huge(self):
        """A 100 MB-class file: a sparse hole, then real lines at the end.

        `truncate` costs nothing on APFS and the hole reads back as NULs, which
        is a fine stand-in for 100 MB of transcript nobody may touch — the
        assertion is about how many bytes are ASKED FOR, and a read that walked
        the file would ask for all of them either way.
        """
        hole = 100 * 1024 * 1024
        lines = [_user(f"question {n}") for n in range(20)]
        with open(self.fp, "wb") as f:
            f.truncate(hole)
            f.seek(hole)
            f.write(b"\n" + "\n".join(_obj(e) for e in lines).encode() + b"\n")
        return hole

    def test_a_hundred_megabyte_transcript_is_never_read_whole(self):
        hole = self._huge()
        reads = self._spy()
        page = self.read(limit=10)
        self.assertTrue(page["ok"])
        self.assertEqual(len(page["messages"]), 10)
        self.assertEqual(page["messages"][-1]["text"], "question 19")
        self.assertTrue(page["file"]["size"] > hole)
        self.assertTrue(reads, "the spy never saw a read")
        self.assertLessEqual(max(reads), sessionlog.MAX_READ)
        self.assertLessEqual(sum(reads), sessionlog.MAX_READ)
        # And in practice one window, not the ceiling.
        self.assertLessEqual(sum(reads), sessionlog.WINDOW_BYTES)

    def test_paging_back_into_the_hole_stays_bounded_too(self):
        self._huge()
        first = self.read(limit=5)
        reads = self._spy()
        older = self.read(limit=5, before=first["cursor_before"])
        self.assertTrue(older["ok"])
        self.assertLessEqual(sum(reads), sessionlog.MAX_READ)

    def test_the_uncapped_route_is_bounded_as_well(self):
        self._huge()
        page = self.read(limit=1)
        reads = self._spy()
        one = sessionlog.read_entry("test", SID, page["messages"][0]["off"])
        self.assertTrue(one["ok"])
        # `+ WINDOW_BYTES`: a tool_result also looks one window back for the
        # call that names it (`_pending_before`), and that is the only read in
        # this module that is not inside the page's own budget.
        self.assertLessEqual(sum(reads),
                             sessionlog.MAX_READ + sessionlog.WINDOW_BYTES)


# ------------------------------------------------------------ malformed input

class TestMalformedLines(LogCase):

    def test_a_partial_leading_line_is_dropped_not_crashed_on(self):
        # A window almost never opens on a line boundary, so the first thing
        # every read sees is half a JSON object.
        good = [_user(f"question {n}") for n in range(3)]
        with open(self.fp, "w") as f:
            f.write('{"type": "user", "message": {"content": "half an obj')
            f.write("\n")
            for e in good:
                f.write(_obj(e) + "\n")
        page = self.read()
        self.assertTrue(page["ok"])
        self.assertEqual([m["text"] for m in page["messages"]],
                         ["question 0", "question 1", "question 2"])

    def test_garbage_and_scalar_lines_are_skipped(self):
        # The four valid-JSON, non-object shapes `test_fixes_transcripts` pins
        # for the card readers, plus outright garbage.
        self.write(["42", '"a bare string"', "[1, 2, 3]", "null",
                    "{not json at all", _user("the real one")])
        page = self.read()
        self.assertEqual([m["text"] for m in page["messages"]], ["the real one"])

    def test_an_empty_transcript_is_an_empty_page_not_an_error(self):
        self.write([])
        page = self.read()
        self.assertTrue(page["ok"])
        self.assertEqual(page["messages"], [])
        self.assertFalse(page["has_more_before"])
        self.assertIsNone(page["cursor_before"])


# ----------------------------------------------------------------- refusals

class TestTheHouseErrorShape(LogCase):
    """`/api/chat` answers a failure as `200 {"ok": false, "error": …}`. These
    routes replace it on the phone's chat screen, so they answer the same way —
    a client branching on the status line must not break the day it switches."""

    def test_an_unknown_account(self):
        self.write([_user("hi")])
        self.assertEqual(sessionlog.read_messages("nosuch", SID),
                         {"ok": False, "error": "unknown account nosuch"})

    def test_a_missing_transcript(self):
        self.assertEqual(
            sessionlog.read_messages("test", "0000aaaa-1111"),
            {"ok": False, "error": "transcript not found"})

    def test_a_bad_sid_never_reaches_a_glob(self):
        # `sid` is the only part of the request that becomes a filesystem
        # pattern, so its shape is asserted before it gets there.
        for bad in ("../../etc/passwd", "*", "a/b", "sid;rm", ""):
            self.assertEqual(sessionlog.read_messages("test", bad),
                             {"ok": False, "error": "bad sid"})

    def test_a_limit_out_of_range(self):
        self.write([_user("hi")])
        for bad in (0, -1, 201, "many"):
            self.assertEqual(self.read(limit=bad),
                             {"ok": False, "error": "bad limit"})
        self.assertTrue(self.read(limit=200)["ok"])
        self.assertTrue(self.read(limit=1)["ok"])

    def test_a_bad_format(self):
        self.write([_user("hi")])
        self.assertEqual(self.read(fmt="pretty"),
                         {"ok": False, "error": "bad format"})

    def test_a_bad_before(self):
        self.write([_user("hi")])
        self.assertEqual(self.read(before="soon"),
                         {"ok": False, "error": "bad before"})
        self.assertEqual(self.read(before=-1),
                         {"ok": False, "error": "bad before"})


# --------------------------------------------------------------------- meta

class TestMetaMarksRatherThanDrops(LogCase):
    """Rule 5. The old reader REFUSED machine text, which is right for a card
    and wrong for a transcript: the terminal showed it, so the phone gets it —
    flagged, with `why` naming the rule, and the client decides."""

    def test_system_reminder_shaped_user_text_is_marked_and_kept(self):
        body = "<system-reminder>the plan file changed</system-reminder>"
        self.write([_user(body)])
        msg = self.read()["messages"][0]
        self.assertTrue(msg["meta"])
        self.assertEqual(msg["why"], "machine-text")
        self.assertEqual(msg["text"], body)     # kept, not dropped

    def test_the_other_machine_shapes_are_marked_too(self):
        for body in ("<local-command-stdout>x</local-command-stdout>",
                     "<command-message>/model opus</command-message>",
                     "[SYSTEM NOTIFICATION] a task finished",
                     "This session is being continued from a previous "
                     "conversation that ran out of context."):
            self.write([_user(body)])
            self.assertTrue(self.read()["messages"][0]["meta"], body)

    def test_a_genuine_prompt_is_not_meta(self):
        self.write([_user("summarize the diff and tell me what broke")])
        msg = self.read()["messages"][0]
        self.assertFalse(msg["meta"])
        self.assertNotIn("why", msg)

    def test_an_assistant_quoting_the_tag_is_not_marked(self):
        # The `_notification_texts` trap: an agent must not be able to talk its
        # own guard on or off by quoting the harness's vocabulary.
        self.write([_assistant([{"type": "text",
                                 "text": "grep for <system-reminder> next"}])])
        self.assertFalse(self.read()["messages"][0]["meta"])

    def test_ismeta_is_marked(self):
        self.write([_user("harness text", isMeta=True)])
        msg = self.read()["messages"][0]
        self.assertTrue(msg["meta"])
        self.assertEqual(msg["why"], "isMeta")

    def test_sidechain_is_included_and_marked(self):
        # Subagent work living in the main file. Included — it is what the
        # terminal showed — but a client that renders it as the session's own
        # words is quoting somebody else, so it says so.
        self.write([_assistant([{"type": "text", "text": "subagent report"}],
                               isSidechain=True)])
        msg = self.read()["messages"][0]
        self.assertEqual(msg["text"], "subagent report")
        self.assertTrue(msg["meta"])
        self.assertEqual(msg["why"], "sidechain")

    def test_thinking_is_marked_and_its_signature_never_ships(self):
        self.write([_assistant([{"type": "thinking",
                                 "thinking": "weighing\nthe options",
                                 "signature": "SIGNATURE" * 400}])])
        msg = self.read()["messages"][0]
        self.assertEqual(msg["role"], "assistant")
        self.assertEqual(msg["text"], "weighing\nthe options")
        self.assertTrue(msg["meta"])
        self.assertEqual(msg["why"], "thinking")
        self.assertNotIn("SIGNATURE", msg["text"])

    def test_a_system_entry_is_marked(self):
        self.write([{"type": "system", "subtype": "info",
                     "content": "Context low · /compact to continue"}])
        msg = self.read()["messages"][0]
        self.assertEqual(msg["role"], "system")
        self.assertTrue(msg["meta"])


class TestTheModelRidesAlong(LogCase):

    def test_an_assistant_entry_carries_its_model(self):
        self.write([_assistant([{"type": "text", "text": "hi"}],
                               model="claude-opus-5")])
        self.assertEqual(self.read()["messages"][0]["model"], "claude-opus-5")

    def test_a_user_entry_carries_none(self):
        self.write([_user("hi")])
        self.assertIsNone(self.read()["messages"][0]["model"])


# ------------------------------------------------------- the uncapped route

class TestTheUncappedRoute(LogCase):

    def test_at_off_returns_the_entry_uncapped(self):
        body = "L" * 60_000
        self.write([_tool_result("toolu_9", body)])
        page = self.read()
        clipped = page["messages"][0]
        self.assertTrue(clipped["truncated"])
        self.assertEqual(len(clipped["text"]), sessionlog.MAX_ENTRY_CHARS)

        one = sessionlog.read_entry("test", SID, clipped["off"])
        self.assertTrue(one["ok"])
        self.assertEqual(len(one["messages"]), 1)
        whole = one["messages"][0]
        self.assertEqual(whole["text"], body)
        self.assertFalse(whole["truncated"])
        self.assertEqual(whole["chars"], 60_000)
        self.assertEqual(one["off"], clipped["off"])

    def test_even_the_uncapped_route_has_a_ceiling(self):
        self.write([_tool_result("toolu_9", "M" * (sessionlog.MAX_ONE_CHARS + 500))])
        off = self.read()["messages"][0]["off"]
        whole = sessionlog.read_entry("test", SID, off)["messages"][0]
        self.assertTrue(whole["truncated"])
        self.assertEqual(len(whole["text"]), sessionlog.MAX_ONE_CHARS)
        self.assertEqual(whole["chars"], sessionlog.MAX_ONE_CHARS + 500)

    def test_a_line_with_several_blocks_answers_with_all_of_them(self):
        # `off` names a LINE; `(off, i)` names a message. Both ship, and `?i=`
        # picks one.
        self.write([_assistant([{"type": "text", "text": "doing it"},
                                _tool_use("Bash", "t1"),
                                _tool_use("Read", "t2")])])
        off = self.read()["messages"][0]["off"]
        every = sessionlog.read_entry("test", SID, off)
        self.assertEqual([m["i"] for m in every["messages"]], [0, 1, 2])
        one = sessionlog.read_entry("test", SID, off, i=2)
        self.assertEqual(len(one["messages"]), 1)
        self.assertEqual(one["messages"][0]["tool"]["name"], "Read")

    def test_a_result_fetched_alone_still_names_its_tool(self):
        # The line holding a `tool_result` never names the tool — the call is
        # an earlier line — so this route looks one bounded window back for it.
        # Without that, tapping "show the whole thing" loses the header.
        self.write([
            _assistant([_tool_use("Grep", "toolu_77")]),
            _tool_result("toolu_77", "R" * 9000),
        ])
        off = self.read()["messages"][1]["off"]
        whole = sessionlog.read_entry("test", SID, off)["messages"][0]
        self.assertEqual(whole["tool"]["name"], "Grep")
        self.assertEqual(whole["chars"], 9000)

    def test_a_result_whose_call_is_older_than_the_window_stays_null(self):
        self.write([_tool_result("toolu_78", "orphan")])
        off = self.read()["messages"][0]["off"]
        whole = sessionlog.read_entry("test", SID, off)["messages"][0]
        self.assertIsNone(whole["tool"]["name"])

    def test_an_offset_that_is_not_a_line_start_is_refused(self):
        self.write([_user("hello there")])
        self.assertEqual(sessionlog.read_entry("test", SID, 5),
                         {"ok": False, "error": "no entry at that offset"})

    def test_the_house_error_shape_applies_here_too(self):
        self.write([_user("hi")])
        self.assertEqual(sessionlog.read_entry("nosuch", SID, 0),
                         {"ok": False, "error": "unknown account nosuch"})
        self.assertEqual(sessionlog.read_entry("test", "../x", 0),
                         {"ok": False, "error": "bad sid"})
        self.assertEqual(sessionlog.read_entry("test", SID, "start"),
                         {"ok": False, "error": "bad off"})


# ------------------------------------------------------ compaction is visible

class TestACompactionIsDetectable(LogCase):

    def test_the_file_block_carries_identity_and_the_append_cursor(self):
        self.write([_user("hi")])
        ident = self.read()["file"]
        self.assertEqual(set(ident), {"size", "ino", "dev", "mtime_ns"})
        import os
        st = os.stat(self.fp)
        self.assertEqual(ident["ino"], st.st_ino)
        self.assertEqual(ident["size"], st.st_size)

    def test_a_rewrite_onto_a_new_inode_shows_up_as_a_new_ino(self):
        # Compaction REWRITES the file, so every byte offset the client holds
        # is void. `(dev, ino)` is how it finds out; `(size, mtime_ns)` alone
        # would not, because a rewrite can land on the same length.
        self.write([_user("hi")])
        before = self.read()["file"]
        replacement = self.proj / "tmp.jsonl"
        self.write([_user("ho")], path=replacement)
        replacement.replace(self.fp)
        after = self.read()["file"]
        self.assertNotEqual(before["ino"], after["ino"])

    def test_a_cursor_past_the_end_reads_the_newest_page(self):
        # A stale cursor into a compacted file must not answer nothing at all.
        self.write([_user("hi"), _user("ho")])
        page = self.read(before=10 ** 9)
        self.assertEqual(page, {"ok": False, "error": "bad before"})
        page = self.read(before=self.read()["file"]["size"])
        self.assertEqual(len(page["messages"]), 2)


# --------------------------------------------------------------- the routes

def _handler(path, command="GET", peer="127.0.0.1", **headers):
    """A `Handler` on in-memory buffers — the same shape `test_fixes_server`
    uses. `parse_request` never runs, so these cases are about what the router
    does with a request the door already let in."""
    h = fb.Handler.__new__(fb.Handler)
    h.path = path
    h.command = command
    h.requestline = f"{command} {path} HTTP/1.0"
    h.request_version = "HTTP/1.0"
    h.protocol_version = "HTTP/1.0"
    h.client_address = (peer, 54321)
    h.close_connection = False
    h.headers = http.client.HTTPMessage()
    for key, val in headers.items():
        h.headers[key.replace("_", "-")] = str(val)
    h.rfile = io.BytesIO(b"")
    h.wfile = io.BytesIO()
    return h


def _payload(h):
    raw = h.wfile.getvalue()
    return json.loads(raw.split(b"\r\n\r\n", 1)[1])


def _status(h):
    return int(h.wfile.getvalue().split(b"\r\n", 1)[0].split(b" ")[1])


class TestTheRoutes(LogCase):

    def test_the_messages_route_answers(self):
        self.write([_user("what broke?"),
                    _assistant([{"type": "text", "text": "the parser\ndid"}])])
        h = _handler(f"/api/v1/sessions/{SID}/messages?account=test&limit=5")
        h.do_GET()
        body = _payload(h)
        self.assertEqual(_status(h), 200)
        self.assertTrue(body["ok"])
        self.assertEqual([m["text"] for m in body["messages"]],
                         ["what broke?", "the parser\ndid"])
        self.assertIn("cursor_before", body)
        self.assertIn("file", body)

    def test_the_account_is_percent_decoded(self):
        # `~/.claude-side project` is the account `side project`; the raw regex
        # `/api/chat` used to carry would have compared `side%20project`.
        home = self.tmp / ".claude-side project"
        (home / "projects" / "-w").mkdir(parents=True)
        self.write([_user("spaced out")],
                   path=home / "projects" / "-w" / f"{SID}.jsonl")
        config.CFG["homes"] = [str(home)]
        h = _handler(f"/api/v1/sessions/{SID}/messages?account=side%20project")
        h.do_GET()
        body = _payload(h)
        self.assertTrue(body["ok"], body)
        self.assertEqual(body["messages"][0]["text"], "spaced out")

    def test_the_at_route_answers(self):
        self.write([_tool_result("t1", "Q" * 20_000)])
        h = _handler(f"/api/v1/sessions/{SID}/messages?account=test")
        h.do_GET()
        off = _payload(h)["messages"][0]["off"]
        h = _handler(f"/api/v1/sessions/{SID}/messages/at/{off}?account=test")
        h.do_GET()
        body = _payload(h)
        self.assertTrue(body["ok"])
        self.assertEqual(body["messages"][0]["chars"], 20_000)
        self.assertEqual(len(body["messages"][0]["text"]), 20_000)

    def test_a_bad_sid_in_the_path_is_the_house_shape(self):
        for sid in ("zzzz-not-hex", "sid%20with%20space", "sid.jsonl"):
            h = _handler(f"/api/v1/sessions/{sid}/messages?account=test")
            h.do_GET()
            self.assertEqual(_status(h), 200, sid)
            self.assertEqual(_payload(h), {"ok": False, "error": "bad sid"}, sid)

    def test_a_traversal_never_even_reaches_this_router(self):
        # `auth._under_admin` claims any path carrying `..`, `//` or `%2f`
        # BEFORE `do_GET` reaches the elif chain — the M2 fail-safe. So the
        # sid guard above is the second lock on that door, not the first, and
        # this pins the first one for the route that globs a transcript path.
        for path in (f"/api/v1/sessions/../../etc/messages",
                     f"/api/v1/sessions/..%2f..%2fetc/messages",
                     f"/api/v1/sessions//{SID}/messages"):
            self.assertTrue(fb.auth.admin("GET", path + "?account=test"), path)

    def test_a_missing_account_is_the_house_shape(self):
        h = _handler(f"/api/v1/sessions/{SID}/messages")
        h.do_GET()
        self.assertEqual(_payload(h),
                         {"ok": False, "error": "need account & sid"})

    def test_an_unknown_subpath_is_not_a_transcript(self):
        for path in ("/api/v1/sessions",
                     f"/api/v1/sessions/{SID}",
                     f"/api/v1/sessions/{SID}/messages/at",
                     f"/api/v1/sessions/{SID}/replies?account=test"):
            h = _handler(path + ("?account=test" if "?" not in path else ""))
            h.do_GET()
            self.assertFalse(_payload(h)["ok"], path)

    def test_a_suffix_on_the_route_is_a_404_not_a_transcript(self):
        # `/api/v1` resolves at a SEGMENT boundary — the `/api/v1/devicesX`
        # rule, applied to a route that reads whole transcripts.
        self.write([_user("secret")])
        h = _handler(f"/api/v1/sessionsX/{SID}/messages?account=test")
        h.do_GET()
        self.assertEqual(_status(h), 404)
        self.assertNotIn(b"secret", h.wfile.getvalue())

    def test_these_reads_are_not_acting_gets(self):
        # A recent hardening demands `Sec-Fetch-Site` on the GETs that ACT —
        # `/api/focus`, `/api/events`, `/api/limits?refresh=1`. Reading a
        # transcript is what a `read` token is FOR, so these two routes must
        # not join that set: a phone's `URLSession` sends no `Sec-Fetch-Site`
        # at all, and adding them would make the chat screen unreachable.
        for path in (f"/api/v1/sessions/{SID}/messages?account=test",
                     f"/api/v1/sessions/{SID}/messages/at/0?account=test"):
            self.assertFalse(fb.auth._acting_get("GET", path), path)


class _RemoteHandler(fb.Handler):
    """The handler believing its peer is on the tailnet — `test_auth`'s trick,
    which is the whole of the lie: the socket and the request are real."""

    def setup(self):
        super().setup()
        self.client_address = ("100.64.0.9", 51000)


class TestOnTheWire(LogCase):
    """The door is `parse_request`, and no test above ran it. These two do,
    over a real socket: a loopback read and a token read must both reach the
    transcript with no `Sec-Fetch-Site` header anywhere in sight."""

    def setUp(self):
        super().setUp()
        self.registry = self.tmp / "devices.json"
        self._saved_auth = (fb.auth.REGISTRY, fb.auth.AUDIT_LOG)
        fb.auth.REGISTRY = self.registry
        fb.auth.AUDIT_LOG = self.tmp / "audit.log.jsonl"
        fb.auth._forget_registry()
        fb.auth._reset_buckets()
        self.addCleanup(self._restore_auth)
        self.write([_user("what broke?"),
                    _assistant([{"type": "text", "text": "the parser\ndid"}])])

    def _restore_auth(self):
        fb.auth.REGISTRY, fb.auth.AUDIT_LOG = self._saved_auth
        fb.auth._forget_registry()
        fb.auth._reset_buckets()

    def _serve(self, handler=fb.Handler):
        srv = fb.Server(("127.0.0.1", 0), handler)
        threading.Thread(target=srv.serve_forever, daemon=True).start()
        self.addCleanup(srv.server_close)
        self.addCleanup(srv.shutdown)
        return srv.server_address[1]

    def _get(self, port, path, token=None):
        conn = http.client.HTTPConnection("127.0.0.1", port, timeout=10)
        head = {"Authorization": f"Bearer {token}"} if token else {}
        try:
            conn.request("GET", path, headers=head)
            r = conn.getresponse()
            return r.status, r.read()
        finally:
            conn.close()

    def test_a_loopback_read_passes_the_door(self):
        port = self._serve()
        status, blob = self._get(
            port, f"/api/v1/sessions/{SID}/messages?account=test")
        self.assertEqual(status, 200)
        body = json.loads(blob)
        self.assertTrue(body["ok"])
        self.assertEqual(body["messages"][1]["text"], "the parser\ndid")

    def test_a_token_read_from_the_tailnet_passes_the_door(self):
        _, token = fb.auth.add_device("iPhone")
        port = self._serve(_RemoteHandler)
        status, blob = self._get(
            port, f"/api/v1/sessions/{SID}/messages?account=test", token=token)
        self.assertEqual(status, 200)
        self.assertTrue(json.loads(blob)["ok"])

    def test_a_stranger_with_no_token_is_still_refused(self):
        port = self._serve(_RemoteHandler)
        status, blob = self._get(
            port, f"/api/v1/sessions/{SID}/messages?account=test")
        self.assertEqual(status, 401)
        self.assertFalse(json.loads(blob)["ok"])


if __name__ == "__main__":
    unittest.main()
