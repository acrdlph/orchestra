"""orchestra.sessionlog — the WHOLE transcript, paged by byte offset.

`chat.read_chat` answers the board's drawer: forty turns, machine text refused,
each one `_clean`ed to 900 characters with every newline collapsed to a space.
That is the right shape for a card and the wrong shape for a phone that wants
to read what the TERMINAL showed. Code arrives as one run-on line, tool calls
and their results are absent entirely, and a truncation is only inferable from
a trailing "…" — which false-positives on prose that legitimately ends in one.

This module is the other reader. Same files, same bounded discipline, opposite
policy: newlines survive, tool traffic is first class, and nothing is dropped
for being machine text — it is MARKED (`meta`, and `why` says which rule fired)
so the client decides what to collapse. `chat.py` is untouched and still serves
the board.

BYTE OFFSETS ARE THE WHOLE DESIGN. A transcript can exceed 100 MB (the largest
on this machine is 103,839,151 bytes) so nothing here may be a function of the
file's length: a page is "the window ending at byte X", never "skip N lines",
and `MAX_READ` is the hard ceiling on what one request may touch. `off` is
where a line starts; transcripts are append-only, so it stays valid. A
COMPACTION REWRITES THE FILE and voids every offset at once, which is why the
reply carries `file` = (dev, ino, size, mtime_ns): a client that sees the inode
move throws its offsets away rather than rendering somebody else's bytes.

A JSONL LINE IS NOT A MESSAGE. One `assistant` entry carries thinking, prose
and several `tool_use` blocks; one `user` entry carries several `tool_result`s.
So a line EXPANDS into messages, `(off, i)` is the unique id, and a page never
cuts a line in half — `_page` takes whole lines only, because `cursor_before`
is a byte offset and half a line has no offset of its own to name.

The 4000-char cap is per message and it is HONEST: `chars` is the true length,
`truncated` is a real field, and no ellipsis is appended. `/messages/at/{off}`
re-reads one line with a 256 KB ceiling instead — the "show me the whole thing"
affordance.
"""

import json
import os
import re

from . import config, transcripts

# API.md §9.11's number, per message and not per page.
MAX_ENTRY_CHARS = 4000
# The uncapped read's ceiling. Still a cap — a `tool_result` holding a whole
# file is exactly what this route is tapped for, and "uncapped" cannot mean
# "whatever the disk says" on a phone.
MAX_ONE_CHARS = 256 * 1024

DEFAULT_LIMIT = 60
MAX_LIMIT = 200

# One window. Sized off `chat.py`'s 512 KB, which is the measured shape of a
# few dozen turns; a page that wants more pages again rather than reading more.
WINDOW_BYTES = 512 * 1024
# The ceiling on ONE request's total disk reads, and the reason a 100 MB
# transcript costs the same as a 100 KB one. It is not WINDOW_BYTES because a
# single line can be larger than a window: the largest observed on this machine
# is 1,243,903 bytes (a tool_result carrying a whole file), and a window that
# cannot hold one complete line yields nothing and would stall paging forever.
MAX_READ = 8 * 1024 * 1024

FORMATS = ("raw", "clean")

# CSI, OSC and the two-character escapes. `_clean`'s regex is SGR only
# (`\x1b\[…m`), which is right for a card — anything it misses is collapsed by
# the whitespace pass a moment later. Raw text has no such pass, so a cursor
# move or a title sequence would reach the phone verbatim.
_ANSI = re.compile(r"\x1b\[[0-9;?]*[ -/]*[@-~]"
                   r"|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)"
                   r"|\x1b[@-Z\\-_]")

# `_clean` truncates at its `limit` and appends "…". The cap and the flag are
# this module's job (rule 2: the flag is the signal, the ellipsis was a guess),
# so `clean` asks it for the transformation and not for the cut.
_NO_LIMIT = 1 << 30

_SID_RE = re.compile(r"[0-9a-fA-F-]+")


# ------------------------------------------------------------------- reading

def _read_span(fp, start, end):
    """Bytes [start, end) of a file, or b"" if it cannot be read.

    THE ONLY READ IN THIS MODULE, deliberately: a test that wants to prove no
    request here ever reads a whole transcript has exactly one place to watch,
    and every bound below is expressed in what this function was asked for.
    """
    if end <= start:
        return b""
    try:
        with open(fp, "rb") as f:
            f.seek(start)
            return f.read(end - start)
    except OSError:
        return b""


def _window(fp, end, size):
    """Complete lines inside [end-size, end) as [(byte offset, line bytes)].

    The leading partial line is dropped — a window almost never opens on a line
    boundary — and the second return is where the first COMPLETE line starts.
    That offset is the only one a caller may keep paging back from, and
    `base == 0` is the ONLY proof in this module that byte 0 was reached.

    An empty list with `base > 0` is not "no data": it is "this window is
    smaller than one line", which the caller answers by growing the window
    rather than by sliding it (sliding would step over the line's start and
    lose it).
    """
    start = max(0, end - size)
    data = _read_span(fp, start, end)
    if start > 0:
        cut = data.find(b"\n")
        if cut < 0:
            return [], start
        data = data[cut + 1:]
        start += cut + 1
    lines, off = [], start
    for chunk in data.split(b"\n"):
        if chunk:
            lines.append((off, chunk))
        off += len(chunk) + 1
    return lines, start


def _one_window(fp, end, budget):
    """`_window`, grown until it holds a complete line. (lines, base, spent).

    Doubling re-reads the bytes it already read, and each read is charged to
    the budget anyway — the budget is a promise about DISK, not about distinct
    bytes, and a promise that quietly ignores re-reads is not one. Worst case
    costs about twice the final window, which is why MAX_READ has room.
    """
    size, spent = WINDOW_BYTES, 0
    while True:
        size = min(size, budget - spent)
        if size <= 0:
            return [], end, spent
        lines, base = _window(fp, end, size)
        spent += end - max(0, end - size)
        if lines or base == 0 or spent >= budget or size >= MAX_READ:
            return lines, base, spent
        size *= 2


# ------------------------------------------------------------ one line's text

def _format(text, fmt):
    if not isinstance(text, str):
        return ""
    if fmt == "clean":
        return transcripts._clean(text, _NO_LIMIT)
    return _ANSI.sub("", text)


def _role(entry):
    """`user` and `assistant` are themselves; everything else the CLI writes —
    `system`, `summary`, `queue-operation`, `attachment` — is the harness, and
    the harness is `system`. Tool blocks override this per block."""
    t = entry.get("type")
    return t if t in ("user", "assistant") else "system"


def _result_text(block):
    """A tool_result's text with its structure intact.

    `transcripts._result_text` joins with " " because everything downstream of
    it is about to have its whitespace collapsed anyway. Here the newline is
    the payload: a result is usually a file, a diff or a test run.
    """
    c = block.get("content")
    if isinstance(c, str):
        return c
    if isinstance(c, list):
        parts = []
        for b in c:
            if not isinstance(b, dict):
                continue
            if b.get("type") == "image":
                parts.append("[image]")
            elif isinstance(b.get("text"), str):
                parts.append(b["text"])
        return "\n".join(parts)
    return ""


def _entry_messages(entry, off, pending, fmt, cap):
    """One JSONL line, expanded into the messages it carries.

    A line yielding NOTHING is a line with no human-visible text — the CLI's
    bookkeeping (`last-prompt`, `file-history-snapshot`, `file-history-delta`,
    `ai-title`, `mode`, `permission-mode`, and `system/turn_duration`, none of
    which the terminal draws either). That is a consequence of the rule "text
    or nothing", not a type allowlist, so a CLI release that invents a new
    bookkeeping shape is skipped without an edit here, and one that invents a
    new SPEAKING shape shows up as soon as it carries `content`.
    """
    out = []
    ts = entry.get("timestamp") if isinstance(entry.get("timestamp"), str) else None
    role = _role(entry)
    msg = entry.get("message") if isinstance(entry.get("message"), dict) else {}
    model = msg.get("model") if entry.get("type") == "assistant" else None
    # Entry-wide reasons outrank per-block ones: a sidechain tool_result is
    # subagent work first and a tool result second, and that is the fact a
    # client collapses on.
    entry_why = ("sidechain" if entry.get("isSidechain") else
                 "isMeta" if entry.get("isMeta") else
                 "system" if entry.get("type") == "system" else None)

    # `i` counts BLOCKS, not emitted messages, so `(off, i)` names the same
    # thing in `raw` and in `clean` — `clean` strips a whitespace-only block to
    # nothing and would otherwise shift every index after it, and `?i=` on the
    # uncapped route would then open the wrong block.
    seq = [0]

    def add(role_, text, why=None, tool=None):
        i, seq[0] = seq[0], seq[0] + 1
        text = _format(text, fmt)
        if not text and tool is None:
            return                      # an empty block is not a message
        chars = len(text)
        m = {"off": off, "i": i, "role": role_, "text": text[:cap],
             "truncated": chars > cap, "chars": chars, "ts": ts,
             "meta": bool(entry_why or why), "model": model}
        if entry_why or why:
            m["why"] = entry_why or why
        if tool is not None:
            m["tool"] = tool
        out.append(m)

    content = msg.get("content")
    if isinstance(content, str):
        add(role, content, _machine_why(role, content))
    elif isinstance(content, list):
        for b in content:
            if not isinstance(b, dict):
                continue
            kind = b.get("type")
            if kind == "text":
                add(role, b.get("text"), _machine_why(role, b.get("text")))
            elif kind == "thinking":
                # `signature` rides beside it and is a kilobyte of base64 nobody
                # can read; only the prose leaves this module.
                add(role, b.get("thinking"), "thinking")
            elif kind == "tool_use":
                tid, name = b.get("id"), b.get("name") or "?"
                if isinstance(tid, str):
                    pending[tid] = name
                add("tool_use", _tool_input(b.get("input")), None,
                    {"name": name, "id": tid, "ok": None})
            elif kind == "tool_result":
                tid, body = b.get("tool_use_id"), _result_text(b)
                # `is_error` is the CLI's own word, and `<tool_use_error>` is
                # the same fact written into the text — `parse_session_tail`
                # matches the second one, so a result carrying only that must
                # not read as a success here. A result whose `tool_use` is older
                # than this read has no name: null, not a guess.
                add("tool_result", body, None,
                    {"name": pending.get(tid), "id": tid,
                     "ok": not b.get("is_error")
                     and "<tool_use_error>" not in body})
            elif kind == "image":
                add(role, "[image]", "image")
    elif isinstance(entry.get("content"), str):
        # `queue-operation`, and any `system` entry that carries its text at the
        # top level rather than under `message`. Both are the harness speaking,
        # which `entry_why` only catches for the literal `system` type.
        add(role, entry["content"], "system" if role == "system" else None)
    elif isinstance(entry.get("summary"), str):
        add("system", entry["summary"], "summary")
    elif isinstance(entry.get("attachment"), dict) and \
            isinstance(entry["attachment"].get("prompt"), str):
        # The third shape a `<task-notification>` arrives in (TRANSCRIPT-FORMAT
        # §"Three on-disk shapes"). The other attachment kinds — `task_reminder`
        # and friends — carry a list of records, not prose, and are skipped.
        add("system", entry["attachment"]["prompt"], "attachment")
    return out


def _tool_input(value):
    """A tool call's arguments, rendered so a human can read them.

    Indented JSON rather than one line: `format=raw` promises newlines, and a
    `Write` call's `content` or a `Bash` call's heredoc is the thing somebody
    opened this route to see. `format=clean` collapses it again.
    """
    if value is None:
        return ""
    try:
        return json.dumps(value, indent=2, ensure_ascii=False)
    except (TypeError, ValueError):
        return str(value)


def _machine_why(role, text):
    """`meta` for the harness writing as the user, and ONLY as the user.

    `transcripts._MACHINE_TEXT` matches `toolu_` ids and `<system-reminder>`,
    both of which an ASSISTANT legitimately quotes in its own prose — the same
    trap `_notification_texts` documents for `<task-notification>`. So the
    filter that refuses machine text on a card is asked here about user entries
    only, and it MARKS rather than drops.
    """
    if role != "user" or not isinstance(text, str):
        return None
    return "machine-text" if transcripts._MACHINE_TEXT.search(text) else None


def _pending_before(fp, off):
    """`tool_use id -> name` for the calls in one window below `off`.

    `/messages/at/{off}` reads ONE line, and a `tool_result` never names its own
    tool — the `tool_use` that did is an earlier line. The client already holds
    the name (it tapped a message that carried it), but a route whose answer
    depends on what the caller happens to remember is a route that lies to
    curl. One bounded window back is what makes `tool.name` mean the same thing
    on both routes; a call older than that window stays null, as it does on the
    paged one.
    """
    lines, _ = _window(fp, off, WINDOW_BYTES)
    names = {}
    for _, raw in lines:
        try:
            entry = json.loads(raw)
        except ValueError:
            continue
        if not isinstance(entry, dict) or entry.get("type") != "assistant":
            continue
        content = (entry.get("message") or {}).get("content")
        if not isinstance(content, list):
            continue
        for b in content:
            if isinstance(b, dict) and b.get("type") == "tool_use" \
                    and isinstance(b.get("id"), str):
                names[b["id"]] = b.get("name") or "?"
    return names


def _expand(lines, fmt, cap):
    """[(line offset, [messages])] in file order, skipping silent lines.

    Walked forwards so `tool_use` is seen before the `tool_result` that pairs
    with it — the pairing dict is `parse_session_tail`'s, rebuilt per call
    because a page is a fresh window and nothing may leak between requests.
    A result whose call fell outside this window keeps `tool.name: null`.
    """
    pending, groups = {}, []
    for off, raw in lines:
        try:
            entry = json.loads(raw)
        except ValueError:
            continue                    # a partial or garbled line is skipped
        if not isinstance(entry, dict):
            continue                    # a valid-JSON scalar line: 42, "s", [1]
        msgs = _entry_messages(entry, off, pending, fmt, cap)
        if msgs:
            groups.append((off, msgs))
    return groups


# ------------------------------------------------------------------- paging

def _page(fp, end, limit, fmt, cap):
    """The last `limit` messages ending at byte `end`. (messages, more, cursor).

    WHOLE LINES ONLY. `cursor_before` is a byte offset and half a line has no
    offset of its own, so a page that ran out of budget mid-line drops that
    line entirely and lets the next page carry it — returning fewer than
    `limit` rather than returning blocks the client can never page back to.
    The one exception is a line with more blocks than `limit`: it is returned
    whole, because the alternative is an empty page and a stuck cursor.
    """
    lines, base, spent = [], end, 0
    reached_zero = end <= 0
    groups = _expand(lines, fmt, cap)
    while not reached_zero and spent < MAX_READ:
        if sum(len(m) for _, m in groups) >= limit:
            break
        got, new_base, sp = _one_window(fp, base, MAX_READ - spent)
        spent += sp
        if new_base >= base and not got:
            break                       # no progress; do not spin on it
        lines = got + lines
        base = new_base
        reached_zero = base <= 0
        groups = _expand(lines, fmt, cap)

    picked, n = [], 0
    for off, msgs in reversed(groups):
        if picked and n + len(msgs) > limit:
            break
        picked.append((off, msgs))
        n += len(msgs)
    picked.reverse()
    more = (not reached_zero) or len(picked) < len(groups)
    # With nothing picked the cursor is the oldest line start this read proved
    # exists, so a page of pure bookkeeping still walks backwards instead of
    # stalling on a null.
    cursor = picked[0][0] if picked else (None if reached_zero else base)
    if cursor == end and end > 0:
        # A single line larger than MAX_READ: the window can never open on its
        # start, so handing back the offset the caller just asked for would
        # loop it forever. Step over the read instead — the next window drops
        # the partial leading line and lands on real ones.
        cursor = max(0, end - MAX_READ)
    return [m for _, msgs in picked for m in msgs], more, cursor


# --------------------------------------------------------------- the two reads

def _resolve(account, sid):
    """(path, error). The same two refusals `chat.read_chat` gives, in the same
    words, because a client branching on them must not have to learn a second
    vocabulary for the same two failures."""
    if not isinstance(sid, str) or not _SID_RE.fullmatch(sid):
        return None, "bad sid"
    home = next((h for h in transcripts.claude_homes()
                 if config.account_label(h) == account), None)
    if not home:
        return None, f"unknown account {account}"
    fp = next(iter((home / "projects").glob(f"*/{sid}.jsonl")), None)
    if not fp:
        return None, "transcript not found"
    return fp, None


def _file_id(fp):
    """What makes a compaction DETECTABLE. `ino` and `dev` are identity — a
    rewrite lands on a new inode and every offset the client holds is void —
    and `(size, mtime_ns)` is the append cursor beside it (TRANSCRIPT-FORMAT:
    "compaction rewrites, so identity (st_dev, st_ino) must be carried")."""
    try:
        st = os.stat(fp)
    except OSError:
        return None
    return {"size": st.st_size, "ino": st.st_ino, "dev": st.st_dev,
            "mtime_ns": st.st_mtime_ns}


def _int_param(value, name, lo, hi, default):
    if value is None or value == "":
        return default, None
    try:
        n = int(value)
    except (TypeError, ValueError):
        return None, f"bad {name}"
    if n < lo or n > hi:
        return None, f"bad {name}"
    return n, None


def read_messages(account, sid, limit=None, before=None, fmt=None):
    """`GET /api/v1/sessions/{sid}/messages`.

    `before` is a BYTE OFFSET, exclusive: the read ends there, so the line at
    `before` belongs to the page the client already has and cannot arrive
    twice. Absent, the read ends at the file's size — the newest page.
    """
    fmt = fmt or "raw"
    if fmt not in FORMATS:
        return {"ok": False, "error": "bad format"}
    limit, err = _int_param(limit, "limit", 1, MAX_LIMIT, DEFAULT_LIMIT)
    if err:
        return {"ok": False, "error": err}
    fp, err = _resolve(account, sid)
    if err:
        return {"ok": False, "error": err}
    ident = _file_id(fp)
    if ident is None:
        return {"ok": False, "error": "transcript not found"}
    # The ceiling is the file's own size: an offset past the end is a client
    # holding a cursor into a transcript that has since been compacted, and
    # clamping it reads the newest page rather than returning nothing at all.
    before, err = _int_param(before, "before", 0, ident["size"], ident["size"])
    if err:
        return {"ok": False, "error": err}
    messages, more, cursor = _page(fp, before, limit, fmt, MAX_ENTRY_CHARS)
    return {"ok": True, "sid": sid, "account": account, "format": fmt,
            "messages": messages, "has_more_before": more,
            "cursor_before": cursor, "file": ident}


def read_entry(account, sid, off, i=None, fmt=None):
    """`GET /api/v1/sessions/{sid}/messages/at/{off}` — one line, uncapped.

    One LINE, not one message: a JSONL line carries several blocks and each is
    its own message, so this answers with the whole line's messages and `?i=`
    picks one of them. `truncated` still ships, because MAX_ONE_CHARS is a real
    ceiling and a 256 KB tool_result is not hypothetical.
    """
    fmt = fmt or "raw"
    if fmt not in FORMATS:
        return {"ok": False, "error": "bad format"}
    fp, err = _resolve(account, sid)
    if err:
        return {"ok": False, "error": err}
    ident = _file_id(fp)
    if ident is None:
        return {"ok": False, "error": "transcript not found"}
    off, err = _int_param(off, "off", 0, max(0, ident["size"] - 1), None)
    if err or off is None:
        return {"ok": False, "error": err or "bad off"}
    idx, err = _int_param(i, "i", 0, 1 << 20, None)
    if err:
        return {"ok": False, "error": err}

    size = WINDOW_BYTES
    while True:
        blob = _read_span(fp, off, off + size)
        cut = blob.find(b"\n")
        if cut >= 0 or len(blob) < size or size >= MAX_READ:
            break
        size = min(size * 2, MAX_READ)
    line = blob[:cut] if cut >= 0 else blob
    msgs = _expand([(off, line)], fmt, MAX_ONE_CHARS)
    if not msgs:
        # Either `off` is not a line start, or the line is bookkeeping the
        # paged route never emitted. Both are "there is nothing to show here",
        # and both are the client's cursor being wrong rather than an error
        # this server can fix.
        return {"ok": False, "error": "no entry at that offset"}
    out = msgs[0][1]
    if any(m["role"] == "tool_result" and m["tool"]["name"] is None
           for m in out):
        names = _pending_before(fp, off)
        for m in out:
            if m["role"] == "tool_result" and m["tool"]["name"] is None:
                m["tool"]["name"] = names.get(m["tool"]["id"])
    if idx is not None:
        out = [m for m in out if m["i"] == idx]
        if not out:
            return {"ok": False, "error": "no entry at that offset"}
    return {"ok": True, "sid": sid, "account": account, "format": fmt,
            "off": off, "messages": out, "file": ident}
