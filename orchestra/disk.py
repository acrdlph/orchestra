"""orchestra.disk — what the corpus costs, and rotation for the board's own logs.

Two jobs, and the line between them is the entire point of this module.

  * **REPORT the transcript corpus, never touch it.** `~/.claude*/projects` is
    the user's own data. Claude Code writes it; this board reads a bounded tail
    of it (`transcripts.py`) and nothing here ever writes, moves, truncates or
    unlinks a single byte of it. Retention on that corpus is the USER's
    decision, and the most this module will ever do is tell them what it costs.
  * **PRUNE orchestra's OWN append-only logs.** `audit.log.jsonl` and
    `dispatch.log.jsonl` are files this program creates and is therefore
    entitled to rotate. They had no rotation at all: `auth.audit`'s own
    docstring said "appended, 0600, never rotated" as a statement of fact.

The reason for the fuss is a real incident, not a policy preference. A
workflow-running session could not write its `.jsonl` because the disk was
full, the board mis-paired the live process to a done sibling, and a busy
worktree cried "needs you" (fixed in `1e5efe2`; `stale_alive_s` is the residual
guard). A full disk breaks the fleet SILENTLY. So the number wants watching —
and the thing that fills the disk is the user's transcripts, which is exactly
the thing this program must not delete.

Measured on the machine this was written on, and these are the numbers that
size the defaults:

    ~/.claude*/projects   4.878 GB   35,365 files   7 homes   oldest 193 days
    filesystem            13.5 GB free of 494.4 GB   (48 % capacity)
    audit.log.jsonl       47 KB      dispatch.log.jsonl   126 KB

Read those two lines together: orchestra's own logs are 0.004 % of what the
corpus costs. Rotating them reclaims nothing worth having — it is here because
an unbounded append-only file is a defect on its own terms (`auth.audit` is
reachable, at a throttled ceiling, by an unauthenticated peer), not because it
is the answer to the disk. The answer to the disk is the report, and the person
reading it.

THE TWO DELETION GUARDS, and they are both checked at the syscall and not at
the call site, because a call site can be added by someone who has not read this:

  1. `_ours` — a path may be unlinked only if it is a rotated SEGMENT sitting
     beside a log this module was handed, with the stamp suffix this module
     writes. Not "in a directory we like": the same name, the same parent, the
     shape we made.
  2. `_user_data` — and never, under any circumstance, if any component of the
     resolved path starts with `.claude`. Guard 1 already excludes it; this one
     exists so that a future refactor of guard 1 cannot reach the corpus by
     accident. It is the guard that has no legitimate way to fire.

The watcher's open descriptors need no third guard, and that is worth stating
so nobody goes looking: `watcher.py` holds fds on transcripts and on session
directories — all of them under a Claude home, all of them behind guard 2.
Nothing this module can delete is anything the watcher can hold.
"""

import os
import re
import shutil
import sys
import threading
import time
from pathlib import Path

from . import config

# Rotate a log the board writes when it passes this; keep this many segments.
# 8 MB is ~170x today's dispatch log and ~65x the audit log after a year of
# real use, so a rotation is an event, not a routine — which is what makes the
# `log_rotated` audit line worth reading.
LOG_MAX_MB = 8.0            # config key "log_max_mb"
LOG_KEEP = 5                # config key "log_keep"

# The floor, and it outranks `log_keep` in both directions of the argument. A
# segment younger than this is NEVER removed, however many there are: the week
# just gone is the window in which somebody investigating a stolen token or a
# double dispatch goes looking, and "orchestra deleted the evidence while you
# were reading about it" is the one outcome this file must make impossible.
#
# It cannot be turned into a disk risk by a flood, because the flood is already
# capped upstream: `auth._audit_gate` holds an unauthenticated peer to ~10
# lines/min/IP, so the worst case is bounded by the write rate, not by this
# number. If the floor and `log_keep` disagree, the floor wins and the extra
# segments simply survive until they age out.
PRUNE_FLOOR_S = 7 * 86400   # not a config key ON PURPOSE

# What the corpus scan costs, measured over the 35,365 files above: 1,256 ms
# cold, 135 ms warm. That is why it is never on a request path and never in the
# sweep — it is a background pass on a multi-hour clock, and this TTL is what
# stops the CLI and the loop from paying for it twice.
CORPUS_TTL_S = 3600.0
REPORT_H = 6.0              # config key "disk_report_h"; <= 0 disables the loop
WARN_GB = 10.0              # config key "disk_warn_gb"
FREE_GB = 10.0              # config key "disk_free_gb"

# `<log>.20260804T005712`, one rename per rotation. NOT the `.1`/`.2` shift
# logrotate uses: under the 7-day floor the shift has to renumber a set whose
# tail cannot be dropped yet, so every rotation would rewrite every segment's
# name and an interrupted pass would leave two files claiming to be `.2`. A
# stamp is written once, sorts lexically into chronological order, and says on
# its face when the segment closed.
_STAMP = "%Y%m%dT%H%M%S"
_SEGMENT_RE = re.compile(r"^\.\d{8}T\d{6}$")

_corpus = {"at": 0.0, "data": None}   # mutated in place, never rebound
_lock = threading.Lock()


# --------------------------------------------------------------- the guards

def _user_data(path):
    """Is this path inside a Claude home? Then it is not ours, ever.

    Checked on the RESOLVED path, so a symlink into `~/.claude` cannot launder
    a transcript into something that looks like a segment of ours. `.claude`,
    `.claude-account2`, `.claude-flow` — every home this project has ever seen
    starts with the same six characters, which is also how `claude_homes`
    discovers them.
    """
    try:
        parts = Path(path).resolve().parts
    except OSError:
        return True          # cannot resolve it => cannot prove it is ours
    return any(p.startswith(".claude") for p in parts)


def _ours(live, seg):
    """May `seg` be unlinked as a rotated segment of `live`?

    Sibling, same base name, our stamp suffix — and not under a Claude home.
    Deliberately expressed against the log it belongs to rather than against a
    fixed directory: the tests rebind `auth.AUDIT_LOG` into a tmpdir, and a
    guard that only holds in production is a guard no test can watch fail.
    """
    live, seg = Path(live), Path(seg)
    if seg.parent != live.parent:
        return False
    if not seg.name.startswith(live.name + "."):
        return False
    if not _SEGMENT_RE.match(seg.name[len(live.name):]):
        return False
    return not _user_data(seg)


# ------------------------------------------------------------- the own logs

def _max_bytes():
    try:
        return float(config.CFG.get("log_max_mb", LOG_MAX_MB)) * 1024 * 1024
    except (TypeError, ValueError):
        return LOG_MAX_MB * 1024 * 1024


def segments(live):
    """Every rotated segment of `live`, oldest first. Never raises."""
    live = Path(live)
    try:
        found = [p for p in live.parent.iterdir() if _ours(live, p)]
    except OSError:
        return []
    return sorted(found, key=lambda p: p.name)


def rotate_if_needed(live, max_bytes=None, now=None, record=True):
    """Rename `live` aside if it has grown past the cap. Returns what happened.

    `None` when nothing was done — which is the overwhelmingly common answer,
    and the reason this is one `os.stat` and no more on the append path.

    THIS FUNCTION NEVER DELETES. Rotation and reaping are split so that the
    only code that can unlink is `prune_logs`, where the floor lives; a
    rotation that also dropped the oldest segment would put a deletion on the
    hot path of every audited request, under the caller's lock.

    `record=False` is for `auth.audit` itself: it calls this while holding
    `_audit_lock`, and an audit line written from in here would deadlock on it.
    It writes the marker inline into the fresh file instead.
    """
    live = Path(live)
    cap = _max_bytes() if max_bytes is None else max_bytes
    if cap <= 0:
        # `"log_max_mb": 0` reads as "do not rotate", which is the only sane
        # meaning — the literal one is a cap every line is over, i.e. a fresh
        # segment per second forever. A misconfiguration must not become a
        # worse disk problem than the one this module is here for.
        return None
    try:
        size = live.stat().st_size
    except OSError:
        return None
    if size < cap:
        return None
    now = time.time() if now is None else now
    seg = live.with_name(live.name + "." + time.strftime(_STAMP, time.localtime(now)))
    if seg.exists():
        # Two rotations inside one second. Let the live file run over by
        # another second's worth of writes rather than clobber a segment.
        return None
    try:
        os.rename(live, seg)
        os.chmod(seg, 0o600)     # tighten a file that predates the 0600 fix
    except OSError:
        return None
    rec = {"file": live.name, "segment": seg.name, "bytes": size}
    if record:
        audit_event(event="log_rotated", **rec)
    return rec


def prune_logs(logs=None, keep=None, floor_s=PRUNE_FLOOR_S, now=None, record=True):
    """Reap rotated segments beyond `keep` that are older than the floor.

    THE ONLY code in orchestra that unlinks anything. Returns a summary —
    `{"removed": n, "bytes_freed": b, "kept": k, "held_by_floor": h}` — and
    writes one audit line per batch that actually removed something.

    Opt-in in the sense that matters: it is never called from a request path
    and never from the sweep. `python3 -m orchestra --prune-logs` runs it once
    at a shell, and `disk_loop` runs it on the report's multi-hour clock.
    """
    now = time.time() if now is None else now
    keep = _keep() if keep is None else keep
    removed = freed = held = kept = 0
    for live in own_logs() if logs is None else [Path(p) for p in logs]:
        segs = segments(live)
        kept += min(len(segs), keep)
        # Oldest first, and only the ones past `keep` are even candidates.
        for seg in segs[:max(0, len(segs) - keep)]:
            try:
                st = seg.stat()
            except OSError:
                continue
            if now - st.st_mtime < floor_s:
                held += 1
                continue
            if not _ours(live, seg):     # unreachable via `segments`; belt and braces
                continue
            try:
                os.unlink(seg)
            except OSError:
                continue
            removed += 1
            freed += st.st_size
    out = {"removed": removed, "bytes_freed": freed, "kept": kept,
           "held_by_floor": held}
    if record and removed:
        audit_event(event="disk_prune", **out)
    return out


def _keep():
    try:
        return max(0, int(config.CFG.get("log_keep", LOG_KEEP)))
    except (TypeError, ValueError):
        return LOG_KEEP


def own_logs():
    """The append-only files orchestra writes and may therefore rotate.

    Reached through the module objects because both are REBOUND at runtime —
    the tests point them at a tmpdir, and a list built at import time would
    prune the developer's real logs during the test run.
    """
    from . import auth, dispatch      # deferred: `auth` imports this module
    return [Path(auth.AUDIT_LOG), Path(dispatch.DISPATCH_LOG)]


def audit_event(**fields):
    """One line into the audit log, from this module's own maintenance.

    The import is deferred because `auth` imports THIS module at load time (it
    rotates its log before every append), and a module-level import back would
    be a cycle. Reaching `auth.audit` through the module object also keeps the
    test mock seam.
    """
    from . import auth
    auth.audit(at=time.time(), **fields)


def tail_lines(path, limit):
    """The last `limit` lines of a log, reading BACK ACROSS its segments.

    Without this, rotation quietly breaks both readers built on these files:
    `read_audit(200)` and `read_dispatch_log(25)` each read one file and take a
    tail, so the first request after a rotation would show three lines and look
    like a wiped history. The segments are ours and they are right there, so a
    reader that wants 200 lines gets 200 lines across the boundary.
    """
    path = Path(path)
    try:
        lines = path.read_text().splitlines()
    except OSError:
        lines = []
    if len(lines) >= limit:
        return lines[-limit:]
    for seg in reversed(segments(path)):
        try:
            lines = seg.read_text().splitlines() + lines
        except OSError:
            continue
        if len(lines) >= limit:
            break
    return lines[-limit:]


# ------------------------------------------------------------- the corpus

def corpus(force=False, now=None):
    """Size and age of `~/.claude*/projects`. READ-ONLY, and cached.

    One `os.scandir` walk per home — 1,256 ms cold, 135 ms warm over 35,365
    files — so it is behind `CORPUS_TTL_S` and belongs on the background clock.
    Symlinks are never followed: the corpus is a directory tree of the user's,
    and a link out of it is not part of what it costs.
    """
    now = time.time() if now is None else now
    with _lock:
        if not force and _corpus["data"] and now - _corpus["at"] < CORPUS_TTL_S:
            return _corpus["data"]
    from . import transcripts        # deferred: keeps `auth -> disk` a leaf edge
    homes = transcripts.claude_homes()
    t0 = time.monotonic()
    total = files = 0
    oldest_at, oldest_path = None, None
    per_home = []
    for home in homes:
        hb = hf = 0
        stack = [str(Path(home) / "projects")]
        while stack:
            try:
                it = os.scandir(stack.pop())
            except OSError:
                continue
            with it:
                for entry in it:
                    try:
                        if entry.is_dir(follow_symlinks=False):
                            stack.append(entry.path)
                            continue
                        st = entry.stat(follow_symlinks=False)
                    except OSError:
                        continue
                    hb += st.st_size
                    hf += 1
                    if oldest_at is None or st.st_mtime < oldest_at:
                        oldest_at, oldest_path = st.st_mtime, entry.path
        total += hb
        files += hf
        per_home.append({"home": Path(home).name, "bytes": hb, "files": hf})
    # The filesystem the corpus is ON is the number that actually predicts the
    # incident — a 5 GB corpus is fine on a 2 TB disk and fatal on a full one.
    try:
        free = shutil.disk_usage(str(homes[0] if homes else config.HOME)).free
    except OSError:
        free = None
    data = {"at": now, "bytes": total, "files": files, "homes": per_home,
            "oldest_at": oldest_at, "oldest": oldest_path, "free": free,
            "scan_ms": (time.monotonic() - t0) * 1000.0}
    with _lock:
        _corpus.update(at=now, data=data)
    return data


def _gb(n):
    return "unknown" if n is None else f"{n / 1e9:.1f} GB"


def report_lines(force=False, now=None):
    """What the corpus costs, in the words a human needs at 2 a.m.

    The warning says what orchestra will NOT do before it says what the user
    might: a message about disk space from a program that watches your
    transcripts must not read as a threat to delete them.
    """
    now = time.time() if now is None else now
    c = corpus(force=force, now=now)
    age = ("unknown" if not c["oldest_at"] else
           f"{(now - c['oldest_at']) / 86400:.0f} days")
    out = [f"orchestra: transcript corpus {_gb(c['bytes'])} in {c['files']:,} "
           f"files across {len(c['homes'])} Claude home(s); oldest write {age} "
           f"ago; {_gb(c['free'])} free on that filesystem."]
    warn_gb, free_gb = _thresholds()
    over = c["bytes"] >= warn_gb * 1e9
    tight = c["free"] is not None and c["free"] < free_gb * 1e9
    if over or tight:
        why = []
        if tight:
            why.append(f"only {_gb(c['free'])} free (disk_free_gb {free_gb:g})")
        if over:
            why.append(f"corpus over disk_warn_gb ({warn_gb:g})")
        out.append(f"orchestra: WARNING — {', and '.join(why)}. A full disk "
                   f"stops agents writing transcripts, and a session with no "
                   f"transcript is one this board cannot read.")
        if c["oldest"]:
            out.append(f"   oldest file: {c['oldest']}")
        # Never a `-delete` one-liner. This is the user's data and the command
        # that removes it should be one they typed, having read the list.
        out.append("   orchestra never deletes your transcripts. To see what "
                   "the old ones are:")
        out.append("     find ~/.claude*/projects -name '*.jsonl' -mtime +90 -print")
    return out


def _thresholds():
    def num(key, default):
        try:
            return float(config.CFG.get(key, default))
        except (TypeError, ValueError):
            return default
    return num("disk_warn_gb", WARN_GB), num("disk_free_gb", FREE_GB)


def report(force=False, now=None, stream=None):
    """Print the report. Returns the lines, for a caller that wants them."""
    lines = report_lines(force=force, now=now)
    for line in lines:
        print(line, file=sys.stderr if stream is None else stream)
    return lines


# ----------------------------------------------------------------- the loop

def _report_s():
    try:
        return float(config.CFG.get("disk_report_h", REPORT_H)) * 3600.0
    except (TypeError, ValueError):
        return REPORT_H * 3600.0


def disk_loop():
    """Daemon: say what the corpus costs, reap orchestra's own old segments.

    Reports FIRST and sleeps after — the opposite of `resume_loop`, on purpose.
    The line at startup is the whole point of the surface; one that arrived six
    hours into a session would be a line nobody ever saw. After that the clock
    is `disk_report_h`, because the number it reports moves in gigabytes per
    week and there is nothing to be gained by asking more often than the TTL.

    A pass that raises must not kill the thread: this is a reporting surface,
    and a board that stops reporting because one home was unreadable for a
    moment is worse than a board that reports late.
    """
    while True:
        every = _report_s()
        if every <= 0:
            return               # disk_report_h: 0 — the documented off switch
        try:
            report(force=True)
            prune_logs()
        except Exception as e:   # noqa: BLE001 — a broken pass must not end the loop
            print(f"orchestra: disk report failed: {e}", file=sys.stderr)
        time.sleep(every)


def prune_report(summary):
    """The one-line human form of a `prune_logs` summary."""
    return (f"orchestra: removed {summary['removed']} rotated log segment(s), "
            f"{summary['bytes_freed'] / 1024:.1f} KB freed; "
            f"{summary['kept']} kept, {summary['held_by_floor']} held by the "
            f"7-day floor.")


def _reset():
    """Tests only: drop the corpus cache between scenarios."""
    with _lock:
        _corpus.update(at=0.0, data=None)
