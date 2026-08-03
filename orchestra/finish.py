"""orchestra.finish — the closeout: an agent lands the branch, the card frees.

✓ finish is the one button that ends a mission. It does not merge anything
itself; it hands an agent a brief and lets the agent do the work, because
landing a branch is judgment (conflicts, scratch files, half-done work) and
the board refuses to guess. This module owns the briefs, the flag that makes
finish a visible two-step, and the single case where the board *does* run git
write commands itself.

Three texts, tiered by what is actually left. `CLOSEOUT_TEXT` is the full
brief for a branch that still needs landing. `SLIM_CLOSEOUT_TEXT` is for a
branch that already landed — nothing merged gets re-checked. `CLOSEOUT_NUDGE_TEXT`
is the follow-up for the one observed deadlock: an agent that finished its
closeout but left a file it took for another session's in-flight work, so it
idles forever while ✕ close refuses forever.

`_closeouts` is the two-step: worktree name -> when its live agent was briefed.
While it is set the card shows ✕ close instead of ✓ finish, so a mid-closeout
agent never gets the brief typed at it twice. A card with no live procs never
renders it, so it dies with the terminal as far as the board shows, and this
module reaps the entry itself — on its next action, or by `CLOSEOUT_TTL_S`.
It is PERSISTED (`CLOSEOUT_STATE`, loaded at import): `./start.sh` restarts
this process by design, and a restart that dropped the map put ✓ finish back
on a card whose agent was mid-closeout — one press away from re-typing a
600-character brief at it. The file is written the way every sibling state
file is (tmp + os.replace, 0600 at create); a missing or corrupt one starts
empty, because the worst an empty map costs is the old behaviour.

`_park_on_trunk` is the exception to "watching touches nothing": when the
branch has already landed and the tree is clean, two git commands don't need
an agent — the provably-safe case. `_clean_scratch` is the second one, and
the only place orchestra deletes a file the user did not name: it runs solely
when the request asks for it by name, solely on a landed branch, and solely
when git itself says every leftover is untracked.

`start_finish` is the button itself: it reads the worktree (gitrepo, procs,
transcripts), asks status which step of the two-step it is on, and acts
through terminal or dispatch. That makes finish the top of the act layer —
it imports observe, never the other way round. observer needs one thing back
(it READS `_closeouts` to decide which button a card shows — it never writes
it) and it takes it through a function-local import, so this module's imports
stay a one-way DAG. See ADR 0010, 'cycles'. `auth` is imported for one reason
only: every scratch deletion writes an audit line, and the audit log is where
"who did what to this machine" already lives.

CLOSEOUT_STATE is rebound at runtime (tests point it at a temp file), so it is
deliberately NOT re-exported by the facade — reach it as
`finish.CLOSEOUT_STATE`.
"""

import json
import os
import shutil
import sys
import threading
import time

from . import (config, shell, status, gitrepo, procs, transcripts, terminal,
               observer, dispatch, auth)


# ------------------------------------------------------------- finish

# The full closeout brief, for a branch that still needs landing. ✓ finish
# hands it to an agent: the live one if a terminal exists, a freshly
# dispatched one if not. (Once a branch HAS landed, finish stops delegating —
# see SLIM_CLOSEOUT_TEXT and _park_on_trunk below.)
CLOSEOUT_TEXT = (
    "Close out this worktree now: "
    "1) wait for (or stop) any background agents and workflows you started; "
    "2) commit remaining meaningful work — drop scratch files; "
    "3) land the branch: merge {trunk} into it, resolve any conflicts — but "
    "if a conflict needs real judgment about the code, stop and report it "
    "instead of guessing — push the branch, then push it to the trunk and "
    "verify with `git merge-base --is-ancestor HEAD {trunk}`; "
    "4) switch this worktree to the trunk branch and pull, so it starts the "
    "next mission clean; "
    "5) reply with a one-line summary of what landed."
)

# The slim brief for a branch that already landed (HEAD is an ancestor of the
# trunk): nothing merged gets re-checked — only whatever is actually left.
SLIM_CLOSEOUT_TEXT = (
    "This worktree's branch has already landed on {trunk} — do not re-merge, "
    "re-push, or re-verify any of that. Close out only what's left: "
    "1) stop (or wait for) any background agents and workflows you started; "
    "2) drop scratch files; if meaningful uncommitted work remains, commit it "
    "and land it on {trunk} like a normal closeout; "
    "3) switch this worktree to the trunk branch and pull, so it starts the "
    "next mission clean; "
    "4) reply with one line saying what, if anything, was left to do."
)

# Follow-up typed at a live agent when step two (✕ close) still can't verify a
# clean landing AND nothing else is working in this worktree — so the leftover
# files are this agent's call, not "another session's in-flight work" it can
# quietly ignore. That misjudgment is the exact deadlock this breaks: without
# the nudge the agent idles forever and ✕ close refuses forever, because no
# other session exists to ever converge the tree. {files} is up to five raw
# `git status --porcelain` lines (blank when the branch simply hasn't landed).
CLOSEOUT_NUDGE_TEXT = (
    "Step two of the closeout still can't verify a clean landing: {left}. "
    "{files}"
    "No other session is working in this worktree, so these files are yours to "
    "judge — none of them is another session's in-flight work. Commit and land "
    "anything meaningful, drop scratch, and leave the tree clean on {trunk}. If "
    "any of it genuinely needs the user's decision, stop and ask explicitly — "
    "don't just leave it dirty."
)

# worktree name -> epoch seconds when a closeout brief was typed at its live
# agent. Step two of ✓ finish: while this is set (and the terminal lives) the
# board shows ✕ close instead — which only verifies the landing and /exits;
# it never re-types the brief into a mid-closeout agent. A card with no live
# procs never renders the flag, so it dies with the terminal as far as anyone
# can see; this module reaps the entry itself.
#
# The dict object is the identity everything reads — `observer` looks it up
# directly and the facade re-exports it — so it is MUTATED, never rebound. The
# loader fills this same dict.
_closeouts = {}

# An hour-old brief is not a two-step in progress any more — it is an agent
# that never converged, or a terminal that has been gone for most of an hour.
# Past this the flag can only mislead (a fresh mission in that worktree greeted
# by ✕ close and its refusal), so it is dropped and the card goes back to
# ✓ finish, which is the honest offer at that point.
CLOSEOUT_TTL_S = 3600.0

# Beside resume.schedule.json, idem.store.json and the auth registry — the same
# runtime-state directory, the same write discipline. What it buys: `./start.sh`
# is how this server is restarted, and until now a restart forgot every
# in-flight closeout. The card reverted from ✕ close to ✓ finish, and the next
# press typed the whole closeout brief at an agent that was already halfway
# through one — the exact double-brief the two-step exists to prevent.
CLOSEOUT_STATE = config.HERE / "finish.closeouts.json"

_closeouts_lock = threading.Lock()   # guards the FILE; the dict is guarded by
                                     # the per-worktree finish lock as before
_closeouts_loaded = False


def _load_closeouts():
    """Fill `_closeouts` from disk, once. Missing or corrupt -> stay empty, and
    never raise: a broken flag file must not take the board down, and an empty
    map is exactly the behaviour that shipped before the file existed.

    Entries already past `CLOSEOUT_TTL_S` are dropped on the way in rather than
    loaded and pruned later — the load runs at import, before any mutation
    path, and `observer` reads the map on its own schedule from there on. An
    hour-old flag restored onto a card would be the misleading ✕ close the TTL
    exists to retire.

    An in-memory entry always wins over a stored one: the process that is
    running now knows more than the file it started from."""
    global _closeouts_loaded
    with _closeouts_lock:
        if _closeouts_loaded:
            return
        _closeouts_loaded = True    # set first: a corrupt file must not retry
        try:
            raw = CLOSEOUT_STATE.read_text()
        except OSError:
            return
        try:
            data = json.loads(raw)
        except ValueError:
            return
        sent = data.get("closeouts") if isinstance(data, dict) else None
        if not isinstance(sent, dict):
            return
        now = time.time()
        for name, ts in sent.items():
            try:
                ts = float(ts)
            except (TypeError, ValueError):
                continue
            if now - ts <= CLOSEOUT_TTL_S:
                _closeouts.setdefault(name, ts)


def _save_closeouts():
    """Persist the flags — atomically, and under `_closeouts_lock`.

    tmp + os.replace (`resume.save_resumes`, `idem._save`): a plain
    truncate-write killed mid-flight by `./start.sh` leaves an empty file, and
    the next boot reads that as "no closeout in flight" — losing exactly what
    this file is for. 0600 at create like every sibling: the map is a list of
    worktree names, and `config.HERE` is commonly a synced directory.

    A persistent write failure is printed, not swallowed. A flag map that has
    quietly stopped persisting is a closeout brief waiting to be typed twice."""
    tmp = CLOSEOUT_STATE.with_name(CLOSEOUT_STATE.name + ".tmp")
    with _closeouts_lock:
        try:
            blob = json.dumps({"closeouts": _closeouts}, indent=1)
            fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
            with os.fdopen(fd, "w") as fh:
                fh.write(blob + "\n")
            os.replace(tmp, CLOSEOUT_STATE)
        except OSError as e:
            print(f"orchestra: couldn't save {CLOSEOUT_STATE.name}: {e}",
                  file=sys.stderr)


def _mark_closeout(wt_name, ts=None):
    """Brief sent (or re-sent) at `wt_name` — remember it, on disk too."""
    _closeouts[wt_name] = time.time() if ts is None else ts
    _save_closeouts()


def _drop_closeout(wt_name):
    """The two-step is over (or moot) for `wt_name`. Only writes when the entry
    was actually there — the no-live-agent path runs this on every press."""
    if _closeouts.pop(wt_name, None) is not None:
        _save_closeouts()


def _reset_closeouts():
    """Tests only: forget every flag and force the next load to re-read
    CLOSEOUT_STATE (the process-wide map outlives a single test)."""
    global _closeouts_loaded
    _closeouts.clear()
    with _closeouts_lock:
        _closeouts_loaded = False


# At import, not on the first press. `observer` reads `_closeouts` directly on
# its own schedule and is the FIRST thing to look after a restart — a lazy load
# hung off the mutation path would leave the very first sweep advertising
# ✓ finish on a card whose agent is mid-closeout, which is the whole failure
# this file exists to close. One small read; importing this package still
# starts nothing and touches nothing else.
_load_closeouts()

# One ✓ finish in flight per worktree (ARCHITECTURE.md §5.6). Everything
# start_finish decides on sits downstream of a 30 s `git fetch` and two
# process scans, and the server is threaded — without this lock two
# concurrent presses (a double-tap, or phone + desktop) both read "no
# closeout in flight" and both act: two closeout agents merging and pushing
# the same branch, the worst outcome this product can produce. Non-blocking
# on purpose: the loser gets a clean refusal, never a queued second run.
_finish_locks = {}                 # worktree name -> threading.Lock
_finish_locks_guard = threading.Lock()


def _prune_closeouts(now=None):
    """Drop closeout flags too old to mean anything. Called on this module's
    next action, because reaping is a MUTATION and only a mutation path may do
    it (ENGINE.md §2.5) — `collect_state` used to pop stale entries as a side
    effect of being looked at, which under the perpetual sweep would run on a
    schedule nobody requested.

    The rule is unchanged by persistence: older than `CLOSEOUT_TTL_S`, gone.
    The file is only rewritten when something actually went, so the common
    press — nothing stale — still touches no disk."""
    now = time.time() if now is None else now
    stale = [n for n, ts in _closeouts.items() if now - ts > CLOSEOUT_TTL_S]
    for name in stale:
        _closeouts.pop(name, None)
    if stale:
        _save_closeouts()


def _park_on_trunk(git_root, trunk):
    """Landed and clean: park the worktree on the trunk branch right here —
    two git commands don't need an agent. Returns None if the switch fails so
    the caller can hand it to an agent instead."""
    branch = trunk.split("/", 1)[-1]
    if shell.run(["git", "switch", branch], cwd=git_root, timeout=30)[0] != 0:
        return None
    pulled = shell.run(["git", "pull", "--ff-only", "--quiet"], cwd=git_root,
                       timeout=60)[0] == 0
    return {"ok": True, "mode": "parked", "message":
            f"already landed — parked on {branch}, no agent needed"
            + ("" if pulled else " (pull failed; next dispatch refreshes)")}


def _porcelain(git_root):
    """`git status --porcelain`, blank lines dropped — the listing every tier
    below counts and shows."""
    return [l for l in shell.run(["git", "status", "--porcelain"],
                                 cwd=git_root)[1].splitlines() if l.strip()]


def _porcelain_z(git_root):
    """`git status --porcelain -z` as [(XY, path)] — or None if git refused.

    -z, where every other reader here takes the line-oriented listing, and the
    difference matters exactly once: without it git C-quotes any path holding a
    space, a quote or a newline, and `_clean_scratch` would have to unquote it
    to delete it. Deleting a mis-unquoted path is the one bug this feature is
    not allowed to have. NUL-separated paths are verbatim, always.

    A rename's second field (the old path) parses here as a junk entry, which
    is harmless: an `R` status is present too, and any status but `??` refuses
    the whole clean before a path is touched."""
    rc, out = shell.run(["git", "status", "--porcelain", "-z"], cwd=git_root)
    if rc != 0:
        return None
    entries = []
    for e in out.split("\0"):
        if not e.strip():
            continue
        # `shell.run` strips the blob it returns, which eats the leading space
        # of a ' M path' entry whenever that entry is the first one — and then
        # the path reads as 'eep.py' and the status as 'M '. The field is two
        # characters and a space, always; put back the one that was eaten.
        if len(e) > 2 and e[2] != " ":
            e = " " + e
        entries.append((e[:2], e[3:]))
    return entries


def _clean_scratch(git_root, trunk, landed, wt_name):
    """Delete this worktree's untracked leftovers. THE destructive path.

    It runs only when the request asked for it by name (`clean_scratch` in the
    finish body — absent or false is exactly the behaviour that shipped
    before), and then only under two conditions it verifies itself:

      * the branch has LANDED. On an unlanded branch an untracked file can be
        the only copy of the mission's work, and no flag from a phone is worth
        that. Refuse, name the trunk, delete nothing.  (The caller adds a
        third: no session in this worktree may be mid-turn — see
        `_working_here`.)
      * every leftover git reports is `??`. One ` M`, `A `, `D ` or `R ` line
        means the mission is not landed-clean — a tracked file changed after
        the merge, and that is a human's or the agent's call, not a checkbox's.
        Refuse, name the offender, delete nothing.

    `-x` is never passed to anything here, and `git clean` is never run at all:
    a .gitignored file is invisible to `git status`, therefore invisible to
    this. `.env`, venvs, build caches and every other precious ignored thing
    survive a clean untouched. What gets deleted is what git itself was already
    listing as untracked, and every removal is written to the audit log.

    Returns {"ok": True, "removed": [...], "failed": [...]} or a ready-to-serve
    refusal {"ok": False, "mode": "clean_refused", ...}."""
    if not landed:
        return {"ok": False, "mode": "clean_refused", "message":
                f"won't clean scratch — this branch hasn't landed on {trunk} "
                "yet, and an untracked file here can be the only copy of this "
                "mission's work. land it first, then clean"}
    entries = _porcelain_z(git_root)
    if entries is None:
        return {"ok": False, "mode": "clean_refused", "message":
                "won't clean scratch — git status wouldn't answer in this "
                "worktree, so nothing here is safe to delete"}
    tracked = [f"{st} {p}" for st, p in entries if st != "??"]
    if tracked:
        return {"ok": False, "mode": "clean_refused", "files": tracked[:5],
                "message":
                f"won't clean scratch — {len(tracked)} of the {len(entries)} "
                f"leftover file(s) "
                + ("is a tracked change" if len(tracked) == 1
                   else "are tracked changes")
                + f", not scratch ({tracked[0]}). this mission isn't "
                "landed-clean; a human or the agent has to look at that before "
                "anything gets deleted"}
    root = os.path.realpath(git_root)
    removed, failed = [], []
    for _st, rel in entries:
        # git collapses a wholly-untracked directory to one 'dir/' entry
        rel = rel.rstrip("/")
        if not rel:
            continue
        # Containment, checked on the RESOLVED parent: `..` in a path, or a
        # symlinked parent directory, cannot walk the delete out of the
        # worktree. The leaf itself is deliberately not resolved — an untracked
        # symlink is removed as the link it is, never followed.
        parent = os.path.realpath(os.path.join(git_root, os.path.dirname(rel)))
        if parent != root and not parent.startswith(root + os.sep):
            failed.append(rel)
            continue
        target = os.path.join(parent, os.path.basename(rel))
        try:
            if os.path.islink(target) or os.path.isfile(target):
                os.remove(target)
            elif os.path.isdir(target):
                shutil.rmtree(target)
            else:
                continue          # gone between the listing and here
        except OSError:
            failed.append(rel)
            continue
        removed.append(rel)
        # the audit log is already the answer to "what was done to this
        # machine, and when" — a deletion belongs in it more than anything
        # else on this path does
        auth.audit(at=time.time(), outcome="removed", what="scratch",
                   worktree=wt_name, path=rel[:200])
    return {"ok": True, "removed": removed, "failed": failed}


def _working_here(wt, mine):
    """Is a session in this worktree mid-turn right now?

    The third guard on the clean, and the one git cannot answer: a branch can
    be landed and every leftover untracked while an agent is, this second,
    writing one of them. Typing at such an agent is an interruption; deleting
    the file under it is a different and worse class of harm, so the clean
    waits. Costs a transcript scan, and only on a clean press."""
    if not mine:
        return False
    sessions = transcripts.scan_sessions([wt], mine, time.time()).get(wt["path"], [])
    return any(s.get("status") == "working" for s in sessions)


def _reachable(p):
    return bool(p.get("tmux_target")) or (
        p.get("host") in ("Terminal", "iTerm2") and p.get("tty"))


def _addr(wt_name, p):
    """The durable address of this card's live agent, for `send_to_process`.

    finish is already identity-addressed at the front door — `/api/finish`
    names a worktree, never a pid — but it then picks a process out of its own
    `claude_processes()` scan and types at it, and between that scan and the
    keystroke sit a `git fetch`, a merge-base, a status and (on the nudge path)
    a transcript scan. Seconds, unattended, with an exit or a closeout brief on
    the other end. So the worktree travels down with the pid and the send
    re-resolves it (ADR 0008): the process must still be a live claude, still
    in this worktree, still in the pane and on the tty this scan saw.
    """
    return {"worktree": wt_name, "tmux": p.get("tmux_target"), "tty": p.get("tty")}


def start_finish(wt_name, clean_scratch=False):
    """One button, tiered by what's actually left to do:
    live agent -> type a brief at it — the slim one if the branch already
    landed, the full closeout otherwise; everything landed and an agent
    idling -> type /exit; no terminal + landed + clean -> park on the trunk
    right here, no agent; anything else -> launch a one-shot closeout agent
    (headless; frees the card itself, or parks as needs-you if the landing
    doesn't verify).

    `clean_scratch` is the one opt-in — `POST /api/finish {"worktree": …,
    "clean_scratch": true}`. With it, a LANDED branch whose only remaining
    leftovers are untracked (`??`) has them deleted here, and the press then
    falls through the tiers above against a clean tree — usually all the way
    to /exit or a park, with no agent and no brief. Absent or false it is
    precisely today's behaviour, which is why the client has to say the word:
    orchestra deleting files in somebody's worktree is not a default. See
    `_clean_scratch` for the two things it refuses.

    The worktree's finish lock is taken synchronously here, before anything
    is read or typed (§5.6): a second press that lands while the first is
    still mid-fetch gets the refusal below instead of a second brief — or a
    second closeout agent."""
    if config.DEMO:
        return {"ok": False, "message": "demo mode — nothing to finish"}
    with _finish_locks_guard:
        lock = _finish_locks.setdefault(wt_name, threading.Lock())
    if not lock.acquire(blocking=False):
        return {"ok": False, "message":
                "a finish is already in progress for this worktree — "
                "wait for it to settle"}
    try:
        return _finish_locked(wt_name, clean_scratch)
    finally:
        lock.release()


def _finish_locked(wt_name, clean_scratch=False):
    """start_finish's body, run under the worktree's finish lock: read the
    worktree, optionally clean its scratch, then run the tiers against what is
    actually left."""
    _prune_closeouts()   # every press cleans the whole map, not just this card
    wt = next((w for w in gitrepo.discover_worktrees() if w["name"] == wt_name), None)
    if not wt:
        return {"ok": False, "message": f"unknown worktree '{wt_name}'"}
    path, git_root = wt["path"], wt["git"]
    trunk = gitrepo._base_ref(git_root)
    if not trunk:
        return {"ok": False, "message": "no trunk ref found for this repo"}
    shell.run(["git", "fetch", "--quiet", "origin"], cwd=git_root, timeout=30)
    landed = shell.run(["git", "merge-base", "--is-ancestor", "HEAD", trunk],
                       cwd=git_root)[0] == 0
    porcelain = _porcelain(git_root)
    mine = [p for p in procs.claude_processes() if p.get("cwd")
            and (p["cwd"] == path or p["cwd"].startswith(path + os.sep))]
    cleaned = None
    if clean_scratch and porcelain:
        if _working_here(wt, mine):
            return {"ok": False, "mode": "clean_refused", "message":
                    "won't clean scratch — an agent in this worktree is "
                    "mid-turn, and an untracked file here may be something it "
                    "is writing right now. finish again once it settles"}
        swept = _clean_scratch(git_root, trunk, landed, wt_name)
        if not swept["ok"]:
            # A refused clean stops here rather than quietly falling back to
            # the brief. The press asked for one specific thing under one
            # specific precondition; the precondition failed, so nothing
            # happened and the sentence says which file broke it. Pressing
            # ✓ finish without the knob still does everything it always did.
            return swept
        cleaned = swept
        porcelain = _porcelain(git_root)   # the tiers judge the tree as it is now
    out = _finish_tiers(wt, wt_name, path, git_root, trunk, landed, porcelain, mine)
    if cleaned and (cleaned["removed"] or cleaned["failed"]):
        _note_clean(out, cleaned)
    # Orchestra's own leftovers, on the presses where the mission actually
    # ended. Provably-safe only: a fleet session whose panes are all dead.
    if out.get("ok") and out.get("mode") in ("exit", "parked", "noop"):
        reaped = dispatch.reap_dead_sessions(wt_name)
        if reaped:
            out["reaped"] = reaped
            out["message"] = (out.get("message") or "") + \
                f" · reaped {len(reaped)} dead fleet session(s)"
    return out


def _note_clean(out, swept):
    """Say what was deleted, in front of whatever the tiers decided. The
    frontend renders `message` verbatim, so the deletion cannot be something
    the user only finds out about by reading a log."""
    removed, failed = swept["removed"], swept["failed"]
    out["cleaned"] = removed
    note = f"removed {len(removed)} untracked scratch file(s)"
    if failed:
        out["clean_failed"] = failed
        note += f" ({len(failed)} wouldn't delete)"
    out["message"] = note + " — " + (out.get("message") or "")


def _finish_tiers(wt, wt_name, path, git_root, trunk, landed, porcelain, mine):
    """The tiers themselves, against a tree that has already been read (and
    possibly cleaned) and a process scan already taken. Split out of
    `_finish_locked` so the clean can happen once, before them, instead of
    inside each of eight return paths."""
    live = next((p for p in mine if _reachable(p)), None)
    if live:
        if landed and not porcelain:
            res = terminal.send_to_process(live["pid"], "/exit", **_addr(wt_name, live))
            if res["ok"]:
                _drop_closeout(wt_name)
                observer._cache["t"] = 0.0    # button reverts on the next poll
                observer.nudge("finish/exit")  # …and the sweep sees it now
            return {"ok": res["ok"], "mode": "exit", "message":
                    "already landed — sent /exit to close the terminal"
                    if res["ok"] else res["message"]}
        sent = _closeouts.get(wt_name)
        if sent:
            # step two (✕ close), but the landing still doesn't verify. What to
            # do isn't a fixed refusal — it depends on THIS worktree's live
            # session. The observed deadlock: the agent finished its closeout
            # but left one dirty file it took for another session's in-flight
            # work; nothing else was live, so ✕ close refused forever while the
            # agent idled forever. classify the session and nudge it out of that.
            left = (f"{len(porcelain)} leftover file(s)" if landed
                    else f"branch not landed on {trunk}")
            files = porcelain[:5]          # ≤5 raw lines, for the agent + UI
            now = time.time()
            sessions = transcripts.scan_sessions([wt], mine, now).get(path, [])
            paired = next((s for s in sessions
                           if s.get("pid") == live["pid"]), None)
            any_working = any(s.get("status") == "working" for s in sessions)
            step = status.closeout_step(paired["status"] if paired else None,
                                        any_working, sent, now)
            if step == "nudge":
                # idle agent, nothing else working, briefed ≥60s ago: type the
                # specifics so it stops treating the leftovers as untouchable.
                block = "\n".join(files)
                if len(porcelain) > len(files):
                    block += f"\n… and {len(porcelain) - len(files)} more"
                nudge = CLOSEOUT_NUDGE_TEXT.format(
                    left=left, trunk=trunk, files=(block + "\n") if block else "")
                res = terminal.send_to_process(live["pid"], nudge, **_addr(wt_name, live))
                if not res["ok"]:
                    return {"ok": False, "mode": "nudge", "message": res["message"]}
                _mark_closeout(wt_name)     # restart the "sent Xm ago" clock
                observer._cache["t"] = 0.0  # …and re-arm the 60s guard
                observer.nudge("finish/nudge")
                # `left`/`files` ride along so the card note can say what's
                # blocked without parsing the human message
                return {"ok": True, "mode": "nudge", "left": left,
                        **({"files": files} if files else {}), "message":
                        f"closeout had stalled — sent the agent the specifics "
                        f"({left}); ✕ close works once it reports clean"}
            # otherwise refuse, but hand the frontend the specifics too: `left`
            # (short reason), `files` (≤5 porcelain lines, only when any), and
            # `sent` (the epoch it was briefed). mode "pending" is a plain
            # refusal; mode "chat" is a DISTINCT mode meaning the agent is stuck
            # on a question/approval — a typed nudge would collide with its open
            # dialog, so the frontend must route the user to ✉ chat instead.
            extra = {"left": left, "sent": sent}
            if files:
                extra["files"] = files
            if step == "chat":
                return {"ok": False, "mode": "chat", **extra, "message":
                        f"can't close yet — {left}, and the agent is stuck on a "
                        "question or approval. Answer it in ✉ chat — a typed "
                        "nudge would collide with its open dialog. ✕ close works "
                        "once the landing verifies."}
            # The refusal names no elapsed time. It used to end "…went to the
            # agent 4m ago", computed here and then read minutes later off a
            # toast or a reloaded card — dead on arrival (ENGINE.md §3.4).
            # `sent` is already in `extra` as an absolute epoch; the board
            # counts up from it against its own clock.
            return {"ok": False, "mode": "pending", **extra, "message":
                    f"can't close yet — {left}. The closeout brief has already "
                    f"gone to the agent; if it looks stuck, ✉ chat with it. "
                    "✕ close works once the landing verifies."}
        brief = (SLIM_CLOSEOUT_TEXT if landed else CLOSEOUT_TEXT)
        res = terminal.send_to_process(live["pid"], brief.format(trunk=trunk),
                                       **_addr(wt_name, live))
        if not res["ok"]:
            return {"ok": False, "mode": "slim" if landed else "brief",
                    "message": res["message"]}
        _mark_closeout(wt_name)
        observer._cache["t"] = 0.0   # show ✕ close on the next poll, not in 4s
        observer.nudge("finish/brief")
        return {"ok": True, "mode": "slim" if landed else "brief", "message":
                ("already landed — slim brief sent (tidy scratch and park, "
                 "no re-merge)" if landed else
                 "closeout brief sent to the live agent")
                + " — when it reports done, ✕ close verifies the landing "
                  "and closes the terminal"}
    _drop_closeout(wt_name)   # no live agent — the two-step is moot
    if mine:
        return {"ok": False, "message":
                "a live process exists but its terminal can't be scripted — "
                "finish from that terminal, or close it and ✓ finish again"}
    if landed and not porcelain:
        branch = shell.run(["git", "rev-parse", "--abbrev-ref", "HEAD"],
                           cwd=git_root)[1].strip()
        if branch == trunk.split("/", 1)[-1]:
            return {"ok": True, "mode": "noop",
                    "message": "already landed and clean — nothing to finish"}
        parked = _park_on_trunk(git_root, trunk)
        if parked:
            # The one path where the board itself moves git — switch + pull.
            # It KNOWS the branch changed under it, so it says so: without this
            # the card serves the old branch until git's own clock comes round
            # (GIT_S, up to 15s), and this is the single mutation the observer
            # could never have inferred any sooner.
            observer._cache["t"] = 0.0
            observer.nudge("finish/park")
            return parked
        # the switch itself failed — fall through and let an agent sort it out
    # any leftover file — even untracked scratch — goes to an agent: whether
    # it's droppable is a judgment call, not ours. haiku is enough for the
    # mechanical run, a landed branch gets the slim brief so nothing already
    # merged is re-checked, and a failed landing escalates itself (see
    # closeout_shell's rescue line)
    brief = (SLIM_CLOSEOUT_TEXT if landed
             else CLOSEOUT_TEXT).format(trunk=trunk)
    out = dispatch.start_dispatch(brief, worktree=wt_name,
                                  model="haiku", closeout_trunk=trunk)
    out.setdefault("ok", True)
    out["mode"] = "dispatch"
    out.setdefault("message",
                   "no live terminal — launched a one-shot closeout agent; "
                   "the card frees itself once the landing verifies")
    return out
