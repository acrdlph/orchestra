#!/usr/bin/env python3
"""SUBMIT fixes — the send that typed but never pressed Return.

    python3 -m unittest tests.test_fixes_submit -v

`POST /api/send` to a Terminal.app-hosted agent answered
`{"ok": true, "message": "typed into Terminal (ttys008)"}` and the transcript
never grew: `do script "<text>" in t` writes the text and its newline in one
burst, the CLI's paste heuristic swallows the newline, and the message parks in
the composer unsubmitted — the `[Pasted text #N]` failure `deliver_text` was
written to defeat on the tmux side. rc 0 from osascript means "AppleScript found
the tab", never "the agent received it".

So every test here is about the second keystroke: the Return sent on its own,
the retry when it does not land, the refusal to press Enter at a composer the
text never reached, and the sentences — the client classifies a send by reading
them, so the wording is a contract, not prose. Every test here failed before the
fix it pins.
"""

import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))
import orchestra as fb  # noqa: E402


class SendHarness(unittest.TestCase):
    """One resolved agent, a recording `shell.run`, no real world.

    The resolver is stubbed because identity is not what these tests are about
    (`test_fixes_actuate` and `test_orchestra` own that); everything below the
    resolve is the real actuator, so the recorded commands ARE the keystrokes.
    """

    HOST = "Terminal"
    TTY = "ttys008"

    def setUp(self):
        self._demo, self._resolve, self._run = (
            fb.config.DEMO, fb.identity.resolve, fb.shell.run)
        fb.config.DEMO = False
        fb.identity.resolve = lambda pid, **ident: (
            {"pid": 4242, "tty": self.TTY, "host": self.HOST, "host_kind": "app",
             "tmux_sock": None, "tmux_target": None}, None)
        self.calls = []
        # (rc, out) per osascript call, in order; the default is "found the tab"
        self.replies = []
        fb.shell.run = self.fake_run

    def tearDown(self):
        fb.config.DEMO, fb.identity.resolve, fb.shell.run = (
            self._demo, self._resolve, self._run)

    def fake_run(self, cmd, **kw):
        self.calls.append(cmd)
        if self.replies:
            return self.replies.pop(0)
        return 0, "true"

    def scripts(self):
        return [c[2] for c in self.calls if c[0] == "osascript"]


# ------------------------------------------------------- Terminal.app: the fix

class TestTerminalSubmitsWithASecondReturn(SendHarness):

    def test_the_text_is_followed_by_a_bare_return(self):
        res = fb.send_to_process(4242, "hello", sid="s-alpha")
        self.assertTrue(res["ok"], res)
        typed, submit = self.scripts()
        self.assertIn('do script "hello" in t', typed)
        self.assertIn('do script "" in t', submit)     # a Return, no text
        self.assertNotIn("hello", submit)              # and only a Return

    def test_the_return_is_its_own_osascript_call(self):
        # the whole point: a newline inside the same burst as the text is the
        # one that gets swallowed. Two invocations, not one script with both.
        fb.send_to_process(4242, "hello", sid="s-alpha")
        self.assertEqual(len(self.scripts()), 2)

    def test_the_return_script_waits_a_beat_before_pressing(self):
        # and the beat is inside the AppleScript, so no test here sleeps
        fb.send_to_process(4242, "hello", sid="s-alpha")
        self.assertIn("delay", self.scripts()[1])

    def test_it_looks_the_tab_up_by_tty_again(self):
        fb.send_to_process(4242, "hello", sid="s-alpha")
        for script in self.scripts():
            self.assertIn('"/dev/ttys008"', script)

    def test_a_closeout_sized_brief_gets_the_same_two_steps(self):
        # finish.py's briefs are ~600 chars through this same call; they are
        # covered by fixing send_to_process itself, and this pins that
        brief = "land the branch and report back. " * 20
        res = fb.send_to_process(4242, brief, sid="s-alpha")
        self.assertTrue(res["ok"], res)
        self.assertEqual(len(self.scripts()), 2)
        self.assertIn('do script "" in t', self.scripts()[1])


class TestTerminalSaysWhatItKnows(SendHarness):

    def test_a_landed_send_says_typed_and_submitted(self):
        res = fb.send_to_process(4242, "hello", sid="s-alpha")
        self.assertEqual(res["message"], "typed and submitted (Terminal ttys008)")

    def test_a_returnless_send_says_the_message_is_in_the_composer(self):
        # THE BUG, in the one state that survives the fix: the text went in and
        # the Return did not. ok:true here was the false receipt.
        self.replies = [(0, "true"), (0, "false"), (0, "false")]
        res = fb.send_to_process(4242, "hello", sid="s-alpha")
        self.assertFalse(res["ok"])
        self.assertIn("typed into Terminal (ttys008)", res["message"])
        self.assertIn("sitting in the composer, unsent", res["message"])

    def test_a_tab_that_was_never_found_is_still_a_clean_refusal(self):
        self.replies = [(0, "false")]
        res = fb.send_to_process(4242, "hello", sid="s-alpha")
        self.assertFalse(res["ok"])
        self.assertIn("Automation permission?", res["message"])
        self.assertNotIn("composer", res["message"])   # nothing was typed

    def test_no_reachable_tab_means_no_return_is_pressed(self):
        # a Return at a tab the text never reached submits whatever IS there
        self.replies = [(1, "")]
        fb.send_to_process(4242, "hello", sid="s-alpha")
        self.assertEqual(len(self.scripts()), 1)


class TestTerminalRetriesTheReturnOnce(SendHarness):

    def test_a_second_attempt_lands_it(self):
        self.replies = [(0, "true"), (1, ""), (0, "true")]
        res = fb.send_to_process(4242, "hello", sid="s-alpha")
        self.assertTrue(res["ok"], res)
        self.assertEqual(len(self.scripts()), 3)

    def test_two_failures_stop_trying_and_report(self):
        self.replies = [(0, "true"), (1, ""), (1, "")]
        res = fb.send_to_process(4242, "hello", sid="s-alpha")
        self.assertFalse(res["ok"])
        self.assertEqual(len(self.scripts()), 3)       # not a loop forever


# ----------------------------------------------------------- iTerm2, per host

class TestITermSubmitsToo(SendHarness):
    """`write text` is `do script`'s shape, newline and all — same fix."""

    HOST = "iTerm2"
    TTY = "ttys012"

    def test_the_submit_is_an_empty_write_text(self):
        res = fb.send_to_process(4242, "hello", sid="s-alpha")
        self.assertTrue(res["ok"], res)
        typed, submit = self.scripts()
        self.assertIn('tell s to write text "hello"', typed)
        self.assertIn('tell s to write text ""', submit)
        self.assertIn("iTerm2", submit)                # not Terminal's script
        self.assertIn("delay", submit)

    def test_it_names_iterm_in_the_receipt(self):
        res = fb.send_to_process(4242, "hello", sid="s-alpha")
        self.assertEqual(res["message"], "typed and submitted (iTerm2 ttys012)")

    def test_a_returnless_send_says_the_same_thing_about_the_composer(self):
        self.replies = [(0, "true"), (0, "false"), (0, "false")]
        res = fb.send_to_process(4242, "hello", sid="s-alpha")
        self.assertFalse(res["ok"])
        self.assertIn("sitting in the composer, unsent", res["message"])


# ------------------------------------------------------- the quoting, unmoved

class TestQuotingIsUnchanged(SendHarness):
    """These scripts type into terminals running --dangerously-skip-permissions.
    The escaping is `_osa_escape`, applied where it always was, and the Return
    script interpolates no message text at all."""

    def test_quotes_and_backslashes_are_escaped_into_the_typed_script(self):
        fb.send_to_process(4242, 'say "hi" \\ now', sid="s-alpha")
        self.assertIn(r'do script "say \"hi\" \\ now" in t', self.scripts()[0])

    def test_the_return_script_carries_no_user_text(self):
        fb.send_to_process(4242, '" & (do shell script "id") & "', sid="s-alpha")
        self.assertNotIn("do shell script", self.scripts()[1])

    def test_newlines_are_still_collapsed_before_anything_is_typed(self):
        fb.send_to_process(4242, "one\n  two", sid="s-alpha")
        self.assertIn('do script "one two" in t', self.scripts()[0])


# ------------------------------------------------------------- tmux, same rule

class TmuxHarness(SendHarness):

    def setUp(self):
        super().setUp()
        fb.identity.resolve = lambda pid, **ident: (
            {"pid": 4242, "tty": None, "host": "tmux", "host_kind": "tmux",
             "tmux_sock": "fleet", "tmux_target": "sess:0.1"}, None)

    def enters(self):
        return [c for c in self.calls if c[-1] == "Enter"]


class TestTmuxEnterIsRetriedAndReported(TmuxHarness):

    def test_the_happy_path_says_typed_and_submitted(self):
        res = fb.send_to_process(4242, "hello", sid="s-alpha")
        self.assertTrue(res["ok"], res)
        self.assertEqual(res["message"], "typed and submitted via tmux")

    def test_a_failed_enter_is_retried_once(self):
        self.replies = [(0, ""), (1, ""), (0, "")]
        res = fb.send_to_process(4242, "hello", sid="s-alpha")
        self.assertTrue(res["ok"], res)
        self.assertEqual(len(self.enters()), 2)

    def test_two_failed_enters_say_the_message_is_in_the_composer(self):
        self.replies = [(0, ""), (1, ""), (1, "")]
        res = fb.send_to_process(4242, "hello", sid="s-alpha")
        self.assertFalse(res["ok"])
        self.assertEqual(len(self.enters()), 2)
        self.assertIn("sitting in the composer, unsent", res["message"])
        # the client classifies a send by substring: this exact one is what
        # makes it `.ambiguous`, which is what refuses an auto-retry that
        # would type the message in a second time on top of the first
        self.assertIn("tmux send-keys failed", res["message"])

    def test_a_failed_literal_write_never_presses_enter(self):
        # before: Enter went out regardless, submitting whatever was already
        # in the composer — `deliver_text`'s rule, now honoured here too
        self.replies = [(1, "")]
        res = fb.send_to_process(4242, "hello", sid="s-alpha")
        self.assertFalse(res["ok"])
        self.assertEqual(self.enters(), [])
        self.assertIn("nothing was typed", res["message"])
        self.assertIn("tmux send-keys failed", res["message"])

    def test_the_dash_dash_and_the_socket_are_unmoved(self):
        fb.send_to_process(4242, "-l ok", sid="s-alpha")
        literal = self.calls[0]
        self.assertEqual(literal[:5], ["tmux", "-L", "fleet", "send-keys", "-t"])
        self.assertEqual(literal[-2:], ["--", "-l ok"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
