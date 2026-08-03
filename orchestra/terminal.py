"""orchestra.terminal — the actuator: focus a window, type into a shell.

Everything else in the package observes. This module is where the board
touches the outside world, and it has exactly two verbs. `focus_process`
brings the terminal hosting a pid to the front — or, for a tmux-hosted agent,
opens a real Terminal window attached to the session so you can type in it
directly. `send_to_process` types a line into the shell a claude process is
running in, and then — as a SECOND, separate keystroke — submits it.

Typing and submitting are two acts here, on both mechanisms, because the CLI
makes them two: a newline that arrives inside the same burst as the text is
swallowed by the paste heuristic (the `[Pasted text #N]` behaviour), so the
message parks in the composer, unsent, while every return code says success.
`dispatch.deliver_text` solved that for the fleet's tmux sessions; this module
applies the same rule — type, then submit as its own event, and if the submit
cannot be made to land, say the text is sitting in the composer rather than
claiming a send. That sentence is a contract: the iOS client reads it as
ambiguous and refuses to offer a retry, because a retry would type the message
in a second time on top of the first.

Two mechanisms, picked by how the agent is hosted. tmux panes get
`tmux send-keys`, which is exact and needs no permissions. Terminal.app and
iTerm2 get AppleScript, matched on the tty — which means the user must have
granted Automation permission, so every failure path here says so rather than
failing silently. Anything else (Cursor, VS Code, an unknown host) can't be
scripted at all; we say that too, and offer focus as the fallback.

The AppleScript templates are `%`-formatted with values that came from a
transcript, so `_osa_escape` guards the quoting. `send_to_process` also
collapses every newline to a space before typing: a bare Enter mid-message
would submit half a prompt.

NEITHER VERB TAKES A PID AS ITS ADDRESS. Both take a durable identity — a sid,
a worktree, a tmux pane, a cwd — and hand it to `identity.resolve`, which
re-reads the process table and answers with the process that identity names
*now*; the pid rides along as a hint and is checked against that answer. This
module is the only place in the package that types at an agent, so routing both
verbs through one resolver is what makes the rule unskippable rather than a
convention. ADR 0008, and the reason it exists: the drawer captures a pid when
it opens and the user sends minutes later, so a recycled pid delivers the
message to a stranger running --dangerously-skip-permissions.
"""

import re
import shlex

from . import config, shell, identity


# --------------------------------------------------------------- focus jump

_FOCUS_TERMINAL = '''
tell application "Terminal"
  set found to false
  repeat with w in windows
    repeat with t in tabs of w
      try
        if (tty of t) is "%s" then
          set selected tab of w to t
          set index of w to 1
          set found to true
        end if
      end try
    end repeat
  end repeat
  if found then activate
  return found
end tell'''

_FOCUS_ITERM = '''
tell application "iTerm2"
  set found to false
  repeat with w in windows
    repeat with t in tabs of w
      repeat with s in sessions of t
        try
          if (tty of s) is "%s" then
            tell s to select
            tell t to select
            select w
            set found to true
          end if
        end try
      end repeat
    end repeat
  end repeat
  if found then activate
  return found
end tell'''


def focus_process(pid, **ident):
    """Best-effort: bring the terminal window hosting an agent to the front.

    Identity-addressed like `send_to_process`, and for a smaller reason: focus
    types nothing, so a misdirected focus costs confusion rather than an
    injected instruction. It is still refused rather than guessed, because the
    tmux branch below does not merely raise a window — it OPENS one, attached
    read-write to a session — and because a rule with an exception is a rule
    somebody will copy the exception from.
    """
    proc, refusal = identity.resolve(pid, **ident)
    if refusal:
        return refusal
    pid = proc["pid"]
    tty, host, kind = proc["tty"], proc["host"], proc["host_kind"]
    where = f"pid {pid}" + (f" · {tty}" if tty else "")
    if kind == "tmux":
        # Open a real Terminal window attached to the session (read-write —
        # you can type in it directly). Detach later with Ctrl-b d.
        sock = proc.get("tmux_sock")
        session = (proc.get("tmux_target") or "").split(":", 1)[0]
        if not session:
            return {"ok": False, "message": f"{where}: couldn't resolve tmux session"}
        attach = "tmux" + (f" -L {shlex.quote(sock)}" if sock else "") + \
                 f" attach -t {shlex.quote(session)}"
        script = ('tell application "Terminal"\n  do script "%s"\n  activate\nend tell'
                  % _osa_escape(attach))
        rc, _ = shell.run(["osascript", "-e", script], timeout=8)
        if rc == 0:
            return {"ok": True, "message": f"opened Terminal attached to {session} (Ctrl-b d to detach)"}
        return {"ok": False, "message":
                f"couldn't open Terminal — grant Automation permission, or run:  {attach}"}
    if host in ("Terminal", "iTerm2") and tty:
        script = (_FOCUS_TERMINAL if host == "Terminal" else _FOCUS_ITERM) % f"/dev/{tty}"
        rc, out = shell.run(["osascript", "-e", script], timeout=8)
        if rc == 0 and out.strip() == "true":
            return {"ok": True, "message": f"focused {host} window ({tty})"}
        if rc != 0:
            return {"ok": False, "message":
                    f"couldn't script {host} — grant Automation permission "
                    f"(System Settings → Privacy → Automation), or find {tty} manually"}
        return {"ok": False, "message": f"no {host} tab with {tty} found"}
    if host in ("Cursor", "VS Code"):
        app = "Cursor" if host == "Cursor" else "Visual Studio Code"
        shell.run(["open", "-a", app])
        return {"ok": True, "message":
                f"{where} lives in an embedded terminal inside {host} — "
                f"activated it, check its terminal panel"}
    if host:
        return {"ok": True, "message": f"{where} runs in {host} — look for {tty}"}
    return {"ok": False, "message": f"unknown host for {where}"}


# ----------------------------------------------------- talk to agents (send)

_SEND_TERMINAL = '''
tell application "Terminal"
  repeat with w in windows
    repeat with t in tabs of w
      try
        if (tty of t) is "%s" then
          do script "%s" in t
          return true
        end if
      end try
    end repeat
  end repeat
  return false
end tell'''

_SEND_ITERM = '''
tell application "iTerm2"
  repeat with w in windows
    repeat with t in tabs of w
      repeat with s in sessions of t
        try
          if (tty of s) is "%s" then
            tell s to write text "%s"
            return true
          end if
        end try
      end repeat
    end repeat
  end repeat
  return false
end tell'''

# The submit. Same tab lookup, no text: `do script ""` / `write text ""` write
# a newline and nothing else, which is a Return pressed on its own. The `delay`
# is the point of the whole second script — it puts the newline in a burst of
# its own, out of reach of the heuristic that ate the first one — and it lives
# INSIDE the AppleScript so the beat costs osascript's wall clock rather than
# this process's, and so a test that stubs `shell.run` never waits for it.
#
# Both hosts need it, and iTerm2 says so in its own dictionary: `sdef
# /Applications/iTerm.app` documents `write`'s `newline` parameter as "If
# newline should be added to end of text (default: yes)". So `write text
# "<text>"` is `do script`'s exact shape — text and newline, one burst — and
# `write text ""` is the bare Return that gets the composer submitted.
_RETURN_TERMINAL = '''
delay 0.4
tell application "Terminal"
  repeat with w in windows
    repeat with t in tabs of w
      try
        if (tty of t) is "%s" then
          do script "" in t
          return true
        end if
      end try
    end repeat
  end repeat
  return false
end tell'''

_RETURN_ITERM = '''
delay 0.4
tell application "iTerm2"
  repeat with w in windows
    repeat with t in tabs of w
      repeat with s in sessions of t
        try
          if (tty of s) is "%s" then
            tell s to write text ""
            return true
          end if
        end try
      end repeat
    end repeat
  end repeat
  return false
end tell'''


def _osa_escape(text):
    return text.replace("\\", "\\\\").replace('"', '\\"')


def _osa_send(host, tty, text):
    """Type `text` into the tab on `tty`, then press Return at it. -> (typed, submitted)

    Two osascript calls, and the second one is the fix. `do script "<text>" in t`
    — and iTerm2's `write text`, which is the same shape — writes the text AND
    its newline in one burst; the CLI's paste heuristic chunks that burst and
    swallows the newline, exactly the `[Pasted text #N]` failure
    `dispatch.deliver_text` exists to defeat on the tmux path. Falsified in both
    directions on 2026-07-22: the probe sat in the composer unsubmitted, and a
    subsequent bare `do script "" in t` submitted it immediately.

    So rc 0 on the first call proves only that AppleScript found the tab and
    wrote to it, which is why it is reported as `typed` and never as sent. The
    Return is tried twice: an extra Return is a no-op — the CLI ignores Enter on
    an empty composer, and a shell just draws a fresh prompt — while a missing
    one is a message nobody will ever read.

    The text is interpolated through `_osa_escape` and the tty is not, exactly
    as `focus_process` does it: these templates run against terminals hosting
    --dangerously-skip-permissions agents, so the escaping discipline is copied
    rather than re-derived.
    """
    dev = f"/dev/{tty}"
    send_tpl, return_tpl = ((_SEND_TERMINAL, _RETURN_TERMINAL) if host == "Terminal"
                            else (_SEND_ITERM, _RETURN_ITERM))
    rc, out = shell.run(["osascript", "-e", send_tpl % (dev, _osa_escape(text))],
                        timeout=10)
    if rc != 0 or out.strip() != "true":
        return False, False
    for _ in range(2):
        rc, out = shell.run(["osascript", "-e", return_tpl % dev], timeout=10)
        if rc == 0 and out.strip() == "true":
            return True, True
    return True, False


def send_to_process(pid, text, **ident):
    """Type `text` into the terminal hosting a claude process, then submit it.

    `ok` means "typed, and Return pressed at it" — not "the agent read it".
    Nothing here reads the conversation back, so the message says what was done
    rather than what was received, and the one state worth its own sentence is
    the half-done one: the text went in and the Return did not, which leaves the
    message in the composer where a retry would type it a second time on top.

    `pid` is a hint; `ident` is the address (`sid`/`account`, `worktree`,
    `cwd`, `tmux`, `tty` — see `identity.resolve`). The resolve happens HERE,
    immediately before the keystroke, not in the caller and not off a snapshot:
    everything between reading the board and typing is window for the pid to
    become somebody else's.

    The identity is checked after the message is normalised and found non-empty
    — an empty send should cost nothing, least of all a `ps` — and before any
    of the three delivery mechanisms, which is the only ordering that has all
    of them covered.
    """
    if config.DEMO:
        return {"ok": False, "message": "demo mode — no live agents to talk to"}
    # Collapse any run of line breaks — CR, LF or CRLF — with their surrounding
    # whitespace to one space. A *bare* CR is the case the old `\n`-only pattern
    # missed: it is whitespace but carries no LF, and it reaches the terminal as
    # a Return that submits the message early, splitting one line into two.
    text = re.sub(r"\s*[\r\n]+\s*", " ", text).strip()
    if not text:
        return {"ok": False, "message": "empty message"}
    proc, refusal = identity.resolve(pid, **ident)
    if refusal:
        return refusal
    if proc.get("tmux_target"):
        sock = ["-L", proc["tmux_sock"]] if proc["tmux_sock"] else []
        # `--` ends option parsing: without it a dash-leading message ('-l ok',
        # '-N 30 y') is read as more send-keys flags — the send errors out, or
        # types something else entirely. tmux flag injection, not shell.
        keys = ["tmux"] + sock + ["send-keys", "-t", proc["tmux_target"]]
        rc1, _ = shell.run(keys + ["-l", "--", text])
        if rc1 != 0:
            # Enter is NOT pressed here. `deliver_text`'s rule: a Return on a
            # composer the text never reached submits whatever IS there.
            return {"ok": False, "message": "tmux send-keys failed — nothing was typed"}
        for _ in range(2):
            rc2, _ = shell.run(keys + ["Enter"])
            if rc2 == 0:
                return {"ok": True, "message": "typed and submitted via tmux"}
        return {"ok": False, "message":
                "tmux send-keys failed on the Enter — the message is sitting "
                "in the composer, unsent"}
    if proc["host"] in ("Terminal", "iTerm2") and proc["tty"]:
        typed, submitted = _osa_send(proc["host"], proc["tty"], text)
        if submitted:
            return {"ok": True,
                    "message": f"typed and submitted ({proc['host']} {proc['tty']})"}
        if typed:
            return {"ok": False, "message":
                    f"typed into {proc['host']} ({proc['tty']}) but the Return "
                    f"never landed — the message is sitting in the composer, unsent"}
        return {"ok": False, "message":
                f"couldn't reach {proc['host']} — Automation permission? ({proc['tty']})"}
    return {"ok": False, "message":
            f"{proc['host'] or 'unknown host'} terminals can't be scripted — focus it instead"}
