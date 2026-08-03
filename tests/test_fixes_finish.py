#!/usr/bin/env python3
"""FINISH/DISPATCH fixes — state that outlives `./start.sh`, and the one
destructive thing on the closeout path.

    python3 -m unittest tests.test_fixes_finish -v

Three fixes, one theme: the server restarts by design, and until now every
restart threw away something a client was still holding.

  * `finish._closeouts` is persisted (`finish.closeouts.json`). A restart used
    to drop the two-step, so the card reverted from ✕ close to ✓ finish and
    the next press re-typed a ~600-character closeout brief at an agent that
    was already halfway through one. TTL semantics are unchanged and pinned
    here, because the file must not quietly extend the life of a flag.

  * `dispatch._jobs` is an in-memory LRU-20; the phone polls a job for 90 s
    from a background task, so a restart inside that window answered "unknown
    job" forever for a mission that had in fact launched. Settled results are
    persisted and replayed; a job left in flight under a different boot gets
    the honest "the server restarted while this job ran", never "unknown".

  * `clean_scratch` — the new, explicit, opt-in knob on the finish body. With
    it, a LANDED branch whose only leftovers are untracked `??` files has them
    deleted here instead of a 600-character brief going to an agent to do it.
    Most of this file is what it REFUSES: an unlanded branch, any tracked
    change, and every .gitignored file on the disk (`-x` is never passed, so
    git never lists them and this never sees them).

Every test here failed before the fix it pins.
"""

import json
import os
import shutil
import stat
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))
import orchestra as fb  # noqa: E402

HAVE_GIT = shutil.which("git") is not None


def git(cwd, *args):
    subprocess.run(["git", "-C", str(cwd), *args], check=True,
                   capture_output=True, text=True)


def a_repo(path):
    """A real git repo with one commit, for tests that must read real
    porcelain rather than a fixture's idea of it."""
    path.mkdir(parents=True, exist_ok=True)
    git(path, "init", "-q", "-b", "main")
    git(path, "config", "user.email", "t@t.t")
    git(path, "config", "user.name", "t")
    (path / "keep.py").write_text("print('keep')\n")
    git(path, "add", "-A")
    git(path, "commit", "-q", "-m", "initial")
    return path


# ------------------------------------------------- persisted closeout flags

class TestCloseoutPersistence(unittest.TestCase):
    """The two-step must survive `./start.sh`. Before this, it did not."""

    def setUp(self):
        self.dir = Path(tempfile.mkdtemp(prefix="fb-closeout-"))
        self._state = fb.finish.CLOSEOUT_STATE
        fb.finish.CLOSEOUT_STATE = self.dir / "finish.closeouts.json"
        self._saved = dict(fb._closeouts)
        fb.finish._reset_closeouts()

    def tearDown(self):
        fb.finish._reset_closeouts()
        fb._closeouts.update(self._saved)
        fb.finish.CLOSEOUT_STATE = self._state
        shutil.rmtree(self.dir, ignore_errors=True)

    def restart(self):
        """Everything a restart does to this module: memory gone, file kept."""
        fb.finish._reset_closeouts()
        fb.finish._load_closeouts()

    def test_a_brief_survives_a_restart(self):
        # the whole point: the card keeps showing ✕ close, so the next press
        # cannot re-type the closeout brief at a mid-closeout agent
        fb.finish._mark_closeout("wt", ts=(now := time.time()))
        self.restart()
        self.assertEqual(fb._closeouts, {"wt": now})

    def test_the_file_is_json_and_owner_only(self):
        # 0600, like every sibling state file — config.HERE is commonly a
        # Dropbox/iCloud-synced, Time-Machined directory
        fb.finish._mark_closeout("wt", ts=1000.0)
        blob = json.loads(fb.finish.CLOSEOUT_STATE.read_text())
        self.assertEqual(blob, {"closeouts": {"wt": 1000.0}})
        mode = stat.S_IMODE(os.stat(fb.finish.CLOSEOUT_STATE).st_mode)
        self.assertEqual(mode, 0o600)

    def test_the_write_is_atomic_and_leaves_no_tmp(self):
        fb.finish._mark_closeout("wt", ts=1000.0)
        self.assertEqual(list(self.dir.glob("*.tmp")), [])

    def test_a_dropped_flag_is_dropped_on_disk_too(self):
        # ✕ close verified and /exited: a restart must NOT resurrect the flag
        fb.finish._mark_closeout("wt", ts=time.time())
        fb.finish._mark_closeout("other", ts=time.time())
        fb.finish._drop_closeout("wt")
        self.restart()
        self.assertEqual(list(fb._closeouts), ["other"])

    def test_a_missing_file_starts_empty(self):
        self.restart()
        self.assertEqual(fb._closeouts, {})

    def test_a_corrupt_file_starts_empty_instead_of_raising(self):
        fb.finish.CLOSEOUT_STATE.write_text("{not json at all")
        self.restart()                       # must not raise
        self.assertEqual(fb._closeouts, {})

    def test_a_file_of_the_wrong_shape_starts_empty(self):
        fb.finish.CLOSEOUT_STATE.write_text('["a list, somehow"]')
        self.restart()
        self.assertEqual(fb._closeouts, {})

    def test_an_unparseable_timestamp_is_skipped_not_fatal(self):
        fb.finish.CLOSEOUT_STATE.write_text(json.dumps(
            {"closeouts": {"bad": "soon", "good": time.time()}}))
        self.restart()
        self.assertNotIn("bad", fb._closeouts)
        self.assertIn("good", fb._closeouts)

    def test_flags_past_the_ttl_are_never_loaded(self):
        # persistence must not extend the life of a flag: an hour-old brief
        # restored onto a card is exactly the misleading ✕ close the TTL
        # exists to retire
        old = time.time() - 10 * fb.CLOSEOUT_TTL_S
        fresh = time.time()
        fb.finish.CLOSEOUT_STATE.write_text(json.dumps(
            {"closeouts": {"stale": old, "fresh": fresh}}))
        self.restart()
        self.assertNotIn("stale", fb._closeouts)
        self.assertEqual(fb._closeouts, {"fresh": fresh})

    def test_the_running_process_wins_over_the_file(self):
        # a load can only ever ADD what this process does not already know
        fb.finish.CLOSEOUT_STATE.write_text(json.dumps(
            {"closeouts": {"wt": time.time() - 60}}))
        fb._closeouts["wt"] = now = time.time()
        fb.finish._load_closeouts()
        self.assertEqual(fb._closeouts["wt"], now)

    def test_ttl_prune_semantics_are_unchanged(self):
        fb._closeouts["stale"] = 1000.0
        fb._closeouts["fresh"] = 1000.0 + fb.CLOSEOUT_TTL_S
        fb._prune_closeouts(now=1000.0 + fb.CLOSEOUT_TTL_S + 0.5)
        self.assertEqual(list(fb._closeouts), ["fresh"])

    def test_a_prune_that_drops_nothing_writes_nothing(self):
        # the common press: no stale flags, no disk touched
        fb._closeouts["fresh"] = time.time()
        fb._prune_closeouts()
        self.assertFalse(fb.finish.CLOSEOUT_STATE.exists())

    def test_a_prune_that_drops_something_persists_the_drop(self):
        fb.finish._mark_closeout("fresh", ts=time.time())
        fb._closeouts["stale"] = time.time() - 10 * fb.CLOSEOUT_TTL_S
        fb._prune_closeouts()
        self.restart()
        self.assertEqual(list(fb._closeouts), ["fresh"])

    def test_an_unwritable_path_is_loud_but_not_fatal(self):
        fb.finish.CLOSEOUT_STATE = self.dir / "nope" / "finish.closeouts.json"
        err = sys.stderr
        sys.stderr = io = __import__("io").StringIO()
        try:
            fb.finish._mark_closeout("wt")      # must not raise
        finally:
            sys.stderr = err
        self.assertIn("couldn't save", io.getvalue())
        self.assertEqual(fb._closeouts["wt"], fb._closeouts["wt"])  # still set


# ------------------------------------------------------ persisted job records

class TestDispatchJobPersistence(unittest.TestCase):
    """A phone polls a job for 90 s. `./start.sh` restarts the server inside
    that window routinely, and "unknown job" was a lie about a live mission."""

    def setUp(self):
        self.dir = Path(tempfile.mkdtemp(prefix="fb-jobs-"))
        self._state = fb.dispatch.DISPATCH_JOBS
        fb.dispatch.DISPATCH_JOBS = self.dir / "dispatch.jobs.json"
        self._boot = fb.idem.BOOT_ID
        fb.dispatch._reset_jobs()

    def tearDown(self):
        fb.idem.BOOT_ID = self._boot
        fb.dispatch._reset_jobs()
        fb.dispatch.DISPATCH_JOBS = self._state
        shutil.rmtree(self.dir, ignore_errors=True)

    def record(self, job_id, done, result=None, progress=()):
        with fb.dispatch._jobs_lock:
            fb.dispatch._record_job(job_id, done, result, list(progress))

    def restart(self, boot="a-different-boot"):
        """Memory gone, file kept, a new boot token — a real restart."""
        fb.dispatch._reset_jobs()
        fb.idem.BOOT_ID = boot

    def test_a_settled_job_answers_after_a_restart(self):
        result = {"ok": True, "message": "launched mission-w-120000 in w"}
        self.record("job-1", done=True, result=result, progress=["✓ launched"])
        self.restart()
        out = fb.dispatch.dispatch_status("job-1")
        self.assertTrue(out["ok"])
        self.assertTrue(out["done"])
        self.assertEqual(out["result"], result)
        self.assertEqual(out["progress"], ["✓ launched"])

    def test_an_in_flight_job_says_the_server_restarted(self):
        # genuinely unknowable — the worker thread went with the process — so
        # it says that, instead of denying the job ever existed
        self.record("job-1", done=False)
        self.restart()
        out = fb.dispatch.dispatch_status("job-1")
        self.assertFalse(out["ok"])
        self.assertIn("restarted", out["error"])
        self.assertNotIn("unknown job", out["error"])

    def test_a_job_id_nobody_ever_issued_is_still_unknown(self):
        self.restart()
        self.assertEqual(fb.dispatch.dispatch_status("job-nope"),
                         {"ok": False, "error": "unknown job"})

    def test_memory_answers_before_disk(self):
        self.record("job-1", done=True, result={"ok": True, "message": "old"})
        with fb.dispatch._jobs_lock:
            fb.dispatch._jobs["job-1"] = {"id": "job-1", "progress": ["live"],
                                          "done": False, "result": None}
        out = fb.dispatch.dispatch_status("job-1")
        self.assertFalse(out["done"])
        self.assertEqual(out["progress"], ["live"])

    def test_an_in_flight_job_of_this_boot_is_not_called_a_restart(self):
        # twenty dispatches deep the LRU drops a running job from memory; that
        # is a different sentence from "the server restarted"
        self.record("job-1", done=False)
        fb.dispatch._reset_jobs()          # memory only — same BOOT_ID
        out = fb.dispatch.dispatch_status("job-1")
        self.assertFalse(out["ok"])
        self.assertIn("still running", out["error"])

    def test_the_store_is_bounded(self):
        for i in range(fb.dispatch.JOBS_KEEP + 7):
            self.record(f"job-{i}", done=True, result={"ok": True})
        blob = json.loads(fb.dispatch.DISPATCH_JOBS.read_text())
        self.assertEqual(len(blob["jobs"]), fb.dispatch.JOBS_KEEP)
        self.assertNotIn("job-0", blob["jobs"])
        self.assertIn(f"job-{fb.dispatch.JOBS_KEEP + 6}", blob["jobs"])

    def test_the_file_is_owner_only_and_leaves_no_tmp(self):
        # a stored result carries the verbatim kickoff brief
        self.record("job-1", done=True, result={"ok": True, "kickoff": "secret"})
        mode = stat.S_IMODE(os.stat(fb.dispatch.DISPATCH_JOBS).st_mode)
        self.assertEqual(mode, 0o600)
        self.assertEqual(list(self.dir.glob("*.tmp")), [])

    def test_a_corrupt_store_degrades_to_unknown_job(self):
        fb.dispatch.DISPATCH_JOBS.write_text("}{ not json")
        self.restart()
        self.assertEqual(fb.dispatch.dispatch_status("job-1"),
                         {"ok": False, "error": "unknown job"})

    def test_start_dispatch_records_write_ahead(self):
        # the record has to be on disk BEFORE the worker runs, or a restart
        # mid-launch has nothing to be honest about
        saved_run, saved_demo = fb.dispatch._run_dispatch, fb.config.DEMO
        fb.dispatch._run_dispatch = lambda *a, **kw: None   # never settles
        fb.config.DEMO = False
        try:
            job_id = fb.start_dispatch("close out", worktree="w-wa",
                                       closeout_trunk="origin/main")["job"]
        finally:
            fb.dispatch._run_dispatch = saved_run
            fb.config.DEMO = saved_demo
            fb.dispatch._release_worktree("w-wa")
        blob = json.loads(fb.dispatch.DISPATCH_JOBS.read_text())
        self.assertIn(job_id, blob["jobs"])
        self.assertFalse(blob["jobs"][job_id]["done"])
        self.restart()
        self.assertIn("restarted", fb.dispatch.dispatch_status(job_id)["error"])

    def test_a_settling_worker_persists_its_result(self):
        saved_demo = fb.config.DEMO
        fb.config.DEMO = True          # settles immediately, launches nothing
        try:
            job = {"id": "job-settle", "progress": [], "done": False,
                   "result": None}
            fb.dispatch._run_dispatch(job, "mission", "w", "acct", "opus", "high")
        finally:
            fb.config.DEMO = saved_demo
        blob = json.loads(fb.dispatch.DISPATCH_JOBS.read_text())
        self.assertTrue(blob["jobs"]["job-settle"]["done"])
        self.assertFalse(blob["jobs"]["job-settle"]["result"]["ok"])


# ------------------------------------------------------------- reaping tmux

class FakeTmux:
    """Stand-in for shell.run that answers the three tmux calls the reaper
    makes. `panes` maps a session name to its per-pane `#{pane_dead}` flags."""

    def __init__(self, sessions=(), panes=None):
        self.sessions, self.panes = list(sessions), dict(panes or {})
        self.killed = []

    def __call__(self, cmd, cwd=None, timeout=None, **kw):
        if "list-sessions" in cmd:
            return 0, "\n".join(self.sessions)
        if "list-panes" in cmd:
            name = cmd[cmd.index("-t") + 1]
            flags = self.panes.get(name)
            if flags is None:
                return 1, ""
            return 0, "\n".join(flags)
        if "kill-session" in cmd:
            self.killed.append(cmd[cmd.index("-t") + 1])
            return 0, ""
        raise AssertionError(f"unexpected call: {cmd}")


class TestReapDeadSessions(unittest.TestCase):
    """Orchestra's own leftovers. The rule is deliberately the narrowest safe
    one there is: our name, and every pane in it dead."""

    def setUp(self):
        self._run = fb.shell.run

    def tearDown(self):
        fb.shell.run = self._run

    def reap(self, worktree, sessions, panes):
        fb.shell.run = self.tmux = FakeTmux(sessions, panes)
        return fb.dispatch.reap_dead_sessions(worktree)

    def test_a_dead_session_of_this_worktree_is_killed(self):
        killed = self.reap("orbital web", ["mission-orbital-web-120000"],
                           {"mission-orbital-web-120000": ["1"]})
        self.assertEqual(killed, ["mission-orbital-web-120000"])
        self.assertEqual(self.tmux.killed, ["mission-orbital-web-120000"])

    def test_a_live_pane_is_never_killed(self):
        # the failure mode this rule exists to make impossible
        killed = self.reap("wt", ["mission-wt-120000"],
                           {"mission-wt-120000": ["0"]})
        self.assertEqual(killed, [])
        self.assertEqual(self.tmux.killed, [])

    def test_one_live_pane_among_dead_ones_saves_the_session(self):
        killed = self.reap("wt", ["mission-wt-120000"],
                           {"mission-wt-120000": ["1", "0"]})
        self.assertEqual(self.tmux.killed, [])
        self.assertEqual(killed, [])

    def test_a_session_tmux_will_not_describe_is_left_alone(self):
        killed = self.reap("wt", ["mission-wt-120000"], {})   # list-panes fails
        self.assertEqual(killed, [])

    def test_another_worktrees_session_is_never_touched(self):
        killed = self.reap("wt", ["mission-other-120000"],
                           {"mission-other-120000": ["1"]})
        self.assertEqual(killed, [])

    def test_a_session_orchestra_did_not_mint_is_never_touched(self):
        # somebody's own tmux session on the fleet socket, dead pane and all
        killed = self.reap("wt", ["wt", "my-wt-120000", "mission-wt-12000"],
                           {"wt": ["1"], "my-wt-120000": ["1"],
                            "mission-wt-12000": ["1"]})
        self.assertEqual(killed, [])

    def test_closeout_sessions_count_too(self):
        killed = self.reap("wt", ["closeout-wt-235959"],
                           {"closeout-wt-235959": ["1"]})
        self.assertEqual(killed, ["closeout-wt-235959"])

    def test_the_names_the_launch_paths_mint_are_the_names_reaped(self):
        # one definition of the pattern, so the reaper cannot drift off it
        for kind in ("mission", "closeout"):
            name = fb.dispatch.session_name(kind, "Orbital Web!", now=0)
            killed = self.reap("Orbital Web!", [name], {name: ["1"]})
            self.assertEqual(killed, [name])


# --------------------------------------------------------- clean_scratch

@unittest.skipUnless(HAVE_GIT, "git not available")
class TestCleanScratch(unittest.TestCase):
    """The one place orchestra deletes a file nobody named. Against a real
    repo, because the whole feature turns on what `git status` actually says."""

    def setUp(self):
        self.dir = Path(tempfile.mkdtemp(prefix="fb-clean-"))
        self.repo = a_repo(self.dir / "repo")
        self._audit = fb.auth.AUDIT_LOG
        fb.auth.AUDIT_LOG = self.dir / "audit.log.jsonl"

    def tearDown(self):
        fb.auth.AUDIT_LOG = self._audit
        shutil.rmtree(self.dir, ignore_errors=True)

    def clean(self, landed=True):
        return fb.finish._clean_scratch(str(self.repo), "origin/main", landed, "wt")

    def porcelain(self):
        return subprocess.run(["git", "-C", str(self.repo), "status", "--porcelain"],
                              capture_output=True, text=True).stdout.strip()

    def test_untracked_scratch_is_deleted_and_the_tree_goes_clean(self):
        (self.repo / "scratch.txt").write_text("junk\n")
        (self.repo / "notes.md").write_text("junk\n")
        out = self.clean()
        self.assertTrue(out["ok"])
        self.assertEqual(sorted(out["removed"]), ["notes.md", "scratch.txt"])
        self.assertEqual(out["failed"], [])
        self.assertFalse((self.repo / "scratch.txt").exists())
        self.assertEqual(self.porcelain(), "")

    def test_an_untracked_directory_goes_whole(self):
        (self.repo / "scratchpad").mkdir()
        (self.repo / "scratchpad" / "a.txt").write_text("x\n")
        (self.repo / "scratchpad" / "deep").mkdir()
        (self.repo / "scratchpad" / "deep" / "b.txt").write_text("x\n")
        out = self.clean()
        self.assertTrue(out["ok"])
        self.assertEqual(out["removed"], ["scratchpad"])   # git collapses it
        self.assertFalse((self.repo / "scratchpad").exists())
        self.assertEqual(self.porcelain(), "")

    def test_a_path_with_a_space_and_a_quote_is_deleted_correctly(self):
        # the -z reason: git C-quotes these in the line-oriented listing, and
        # a mis-unquoted path is the one bug a delete may not have
        odd = self.repo / 'my "notes" file.txt'
        odd.write_text("x\n")
        out = self.clean()
        self.assertEqual(out["removed"], ['my "notes" file.txt'])
        self.assertFalse(odd.exists())
        self.assertEqual(self.porcelain(), "")

    def test_a_modified_tracked_file_refuses_the_whole_clean(self):
        (self.repo / "keep.py").write_text("print('edited')\n")
        (self.repo / "scratch.txt").write_text("junk\n")
        out = self.clean()
        self.assertFalse(out["ok"])
        self.assertEqual(out["mode"], "clean_refused")
        self.assertIn("keep.py", out["message"])
        self.assertIn("tracked change", out["message"])
        # nothing at all was deleted — not even the obvious scratch
        self.assertTrue((self.repo / "scratch.txt").exists())
        self.assertTrue((self.repo / "keep.py").exists())

    def test_a_staged_addition_refuses_too(self):
        (self.repo / "new.py").write_text("x\n")
        git(self.repo, "add", "new.py")
        (self.repo / "scratch.txt").write_text("junk\n")
        out = self.clean()
        self.assertFalse(out["ok"])
        self.assertIn("new.py", out["message"])
        self.assertTrue((self.repo / "scratch.txt").exists())

    def test_a_deleted_tracked_file_refuses_too(self):
        os.remove(self.repo / "keep.py")
        out = self.clean()
        self.assertFalse(out["ok"])
        self.assertIn("keep.py", out["message"])

    def test_an_unlanded_branch_refuses_before_reading_anything(self):
        # an untracked file on an unlanded branch can be the only copy of the
        # mission's work; no checkbox from a phone is worth that
        (self.repo / "scratch.txt").write_text("junk\n")
        out = self.clean(landed=False)
        self.assertFalse(out["ok"])
        self.assertEqual(out["mode"], "clean_refused")
        self.assertIn("hasn't landed on origin/main", out["message"])
        self.assertTrue((self.repo / "scratch.txt").exists())

    def test_gitignored_files_survive_because_git_never_lists_them(self):
        # `-x` is never passed to anything here, and `git clean` is never run:
        # .env, venvs and build caches are invisible to git status, therefore
        # invisible to this
        (self.repo / ".gitignore").write_text(".env\nnode_modules/\n")
        git(self.repo, "add", ".gitignore")
        git(self.repo, "commit", "-q", "-m", "ignore")
        (self.repo / ".env").write_text("SECRET=1\n")
        (self.repo / "node_modules").mkdir()
        (self.repo / "node_modules" / "dep.js").write_text("x\n")
        (self.repo / "scratch.txt").write_text("junk\n")
        out = self.clean()
        self.assertEqual(out["removed"], ["scratch.txt"])
        self.assertTrue((self.repo / ".env").exists())
        self.assertTrue((self.repo / "node_modules" / "dep.js").exists())

    def test_every_removal_writes_an_audit_line(self):
        (self.repo / "scratch.txt").write_text("junk\n")
        (self.repo / "notes.md").write_text("junk\n")
        self.clean()
        rows = [r for r in fb.auth.read_audit() if r.get("what") == "scratch"]
        self.assertEqual(len(rows), 2)
        self.assertEqual({r["path"] for r in rows}, {"scratch.txt", "notes.md"})
        for r in rows:
            self.assertEqual(r["outcome"], "removed")
            self.assertEqual(r["worktree"], "wt")
            self.assertIn("at", r)

    def test_a_refusal_writes_no_audit_line_because_it_deletes_nothing(self):
        (self.repo / "keep.py").write_text("print('edited')\n")
        self.clean()
        self.assertEqual([r for r in fb.auth.read_audit()
                          if r.get("what") == "scratch"], [])

    def test_a_symlink_is_removed_as_a_link_never_followed(self):
        outside = self.dir / "precious.txt"
        outside.write_text("do not delete me\n")
        os.symlink(outside, self.repo / "link.txt")
        out = self.clean()
        self.assertEqual(out["removed"], ["link.txt"])
        self.assertFalse((self.repo / "link.txt").exists())
        self.assertTrue(outside.exists())          # the target is untouched

    def test_nothing_to_clean_is_an_empty_success(self):
        out = self.clean()
        self.assertTrue(out["ok"])
        self.assertEqual(out["removed"], [])

    def test_a_git_that_will_not_answer_deletes_nothing(self):
        saved = fb.shell.run
        fb.shell.run = lambda cmd, **kw: (1, "")
        try:
            out = self.clean()
        finally:
            fb.shell.run = saved
        self.assertFalse(out["ok"])
        self.assertIn("git status wouldn't answer", out["message"])

    def test_a_path_that_escapes_the_worktree_is_refused_not_deleted(self):
        # git never emits such a path; this is the check that means a doctored
        # one still deletes nothing
        outside = self.dir / "precious.txt"
        outside.write_text("do not delete me\n")
        saved = fb.shell.run

        def fake(cmd, **kw):
            if "-z" in cmd:
                return 0, "?? ../precious.txt\0"
            return saved(cmd, **kw)
        fb.shell.run = fake
        try:
            out = self.clean()
        finally:
            fb.shell.run = saved
        self.assertTrue(out["ok"])
        self.assertEqual(out["removed"], [])
        self.assertEqual(out["failed"], ["../precious.txt"])
        self.assertTrue(outside.exists())


# ------------------------------------------------- clean_scratch, wired up

class CleanGit:
    """Stand-in for shell.run over a REAL directory of files: git answers are
    fixtures, the deletions are real, so the wiring is tested end to end
    without needing a repo with a remote to merge-base against."""

    def __init__(self, root, landed=True, porcelain=(), branch="feat/x"):
        self.root, self.landed, self.branch = str(root), landed, branch
        self.porcelain = list(porcelain)
        self.calls = []

    def __call__(self, cmd, cwd=None, timeout=None, **kw):
        self.calls.append(cmd)
        if cmd[0] == "tmux":
            return 0, ""                      # no fleet sessions
        if "fetch" in cmd:
            return 0, ""
        if "merge-base" in cmd:
            return (0 if self.landed else 1), ""
        if "status" in cmd:
            live = [l for l in self.porcelain
                    if os.path.lexists(os.path.join(self.root, l[3:].rstrip("/")))]
            if "-z" in cmd:
                return 0, "".join(l + "\0" for l in live)
            return 0, "\n".join(live)
        if "rev-parse" in cmd:
            return 0, self.branch + "\n"
        if "switch" in cmd:
            self.branch = cmd[-1]
            return 0, ""
        if "pull" in cmd:
            return 0, ""
        raise AssertionError(f"unexpected call: {cmd}")


class TestFinishWithCleanScratch(unittest.TestCase):
    """The knob on the wire: absent is exactly today's behaviour, present is
    the only way a file ever gets deleted."""

    def setUp(self):
        self.dir = Path(tempfile.mkdtemp(prefix="fb-finishclean-"))
        self.wt = self.dir / "wt"
        self.wt.mkdir()
        self._state = fb.finish.CLOSEOUT_STATE
        fb.finish.CLOSEOUT_STATE = self.dir / "finish.closeouts.json"
        self._audit = fb.auth.AUDIT_LOG
        fb.auth.AUDIT_LOG = self.dir / "audit.log.jsonl"
        self._saved = (fb.shell.run, fb.config.DEMO,
                       fb.gitrepo.discover_worktrees, fb.gitrepo._base_ref,
                       fb.procs.claude_processes, fb.dispatch.start_dispatch,
                       fb.terminal.send_to_process, fb.transcripts.scan_sessions)
        fb.config.DEMO = False
        fb.transcripts.scan_sessions = lambda wts, procs, now: {}
        fb.gitrepo.discover_worktrees = lambda: [
            {"name": "wt", "path": str(self.wt), "git": str(self.wt)}]
        fb.gitrepo._base_ref = lambda root: "origin/main"
        fb.procs.claude_processes = lambda **_: []
        self.dispatched, self.sent = [], []
        fb.dispatch.start_dispatch = lambda brief, **kw: (
            self.dispatched.append(brief) or {"ok": True, "job": "j1"})
        fb.terminal.send_to_process = lambda pid, text, **ident: (
            self.sent.append(text) or {"ok": True})
        fb._closeouts.clear()

    def tearDown(self):
        (fb.shell.run, fb.config.DEMO, fb.gitrepo.discover_worktrees,
         fb.gitrepo._base_ref, fb.procs.claude_processes,
         fb.dispatch.start_dispatch, fb.terminal.send_to_process,
         fb.transcripts.scan_sessions) = self._saved
        fb._closeouts.clear()
        fb.finish.CLOSEOUT_STATE = self._state
        fb.auth.AUDIT_LOG = self._audit
        shutil.rmtree(self.dir, ignore_errors=True)

    def scratch(self, *names):
        for n in names:
            (self.wt / n).write_text("junk\n")

    def finish(self, porcelain=(), landed=True, clean=False):
        fb.shell.run = self.git = CleanGit(self.wt, landed=landed,
                                           porcelain=porcelain)
        return fb.start_finish("wt", clean_scratch=clean)

    def test_without_the_knob_a_leftover_still_goes_to_an_agent(self):
        # the default is byte-for-byte today's behaviour: whether scratch is
        # droppable is a judgment call, and without the knob it is not ours
        self.scratch("scratch.txt")
        out = self.finish(porcelain=["?? scratch.txt"])
        self.assertEqual(out["mode"], "dispatch")
        self.assertEqual(len(self.dispatched), 1)
        self.assertTrue((self.wt / "scratch.txt").exists())
        self.assertNotIn("cleaned", out)

    def test_with_the_knob_the_scratch_goes_and_the_worktree_parks(self):
        # the whole point: no agent, no account usage, no 600-character brief
        self.scratch("scratch.txt", "notes.md")
        out = self.finish(porcelain=["?? scratch.txt", "?? notes.md"],
                          clean=True)
        self.assertEqual(out["mode"], "parked")
        self.assertEqual(self.dispatched, [])
        self.assertFalse((self.wt / "scratch.txt").exists())
        self.assertEqual(sorted(out["cleaned"]), ["notes.md", "scratch.txt"])
        self.assertTrue(out["message"].startswith(
            "removed 2 untracked scratch file(s) — "))
        self.assertIn("parked on main", out["message"])

    def test_a_live_agent_gets_exit_once_the_scratch_is_gone(self):
        self.scratch("scratch.txt")
        fb.procs.claude_processes = lambda **_: [
            {"pid": 1, "cwd": str(self.wt), "tmux_target": "s:0",
             "cmd": "claude --dangerously-skip-permissions"}]
        out = self.finish(porcelain=["?? scratch.txt"], clean=True)
        self.assertEqual(out["mode"], "exit")
        self.assertEqual(self.sent, ["/exit"])
        self.assertIn("removed 1 untracked scratch file(s)", out["message"])

    def test_a_tracked_change_refuses_the_press_and_types_nothing(self):
        # a refused clean does not quietly fall back to the brief: the press
        # asked for one thing under one precondition, and it did not hold
        self.scratch("scratch.txt")
        (self.wt / "app.py").write_text("edited\n")
        out = self.finish(porcelain=["?? scratch.txt", " M app.py"], clean=True)
        self.assertFalse(out["ok"])
        self.assertEqual(out["mode"], "clean_refused")
        self.assertIn("app.py", out["message"])
        self.assertEqual(out["files"], [" M app.py"])
        self.assertEqual(self.dispatched, [])
        self.assertEqual(self.sent, [])
        self.assertTrue((self.wt / "scratch.txt").exists())

    def test_an_unlanded_branch_refuses_the_clean(self):
        self.scratch("scratch.txt")
        out = self.finish(porcelain=["?? scratch.txt"], landed=False, clean=True)
        self.assertFalse(out["ok"])
        self.assertEqual(out["mode"], "clean_refused")
        self.assertIn("hasn't landed", out["message"])
        self.assertEqual(self.dispatched, [])
        self.assertTrue((self.wt / "scratch.txt").exists())

    def test_an_agent_mid_turn_refuses_the_clean(self):
        # git can say the branch landed and every leftover is untracked while
        # an agent is, this second, writing one of them. Typing at it is an
        # interruption; deleting the file under it is worse.
        self.scratch("scratch.txt")
        fb.procs.claude_processes = lambda **_: [
            {"pid": 1, "cwd": str(self.wt), "tmux_target": "s:0",
             "cmd": "claude --dangerously-skip-permissions"}]
        fb.transcripts.scan_sessions = lambda wts, procs, now: {
            str(self.wt): [{"sid": "s1", "pid": 1, "status": "working"}]}
        out = self.finish(porcelain=["?? scratch.txt"], clean=True)
        self.assertFalse(out["ok"])
        self.assertEqual(out["mode"], "clean_refused")
        self.assertIn("mid-turn", out["message"])
        self.assertTrue((self.wt / "scratch.txt").exists())
        self.assertEqual(self.sent, [])

    def test_an_idle_agent_does_not_block_the_clean(self):
        self.scratch("scratch.txt")
        fb.procs.claude_processes = lambda **_: [
            {"pid": 1, "cwd": str(self.wt), "tmux_target": "s:0",
             "cmd": "claude --dangerously-skip-permissions"}]
        fb.transcripts.scan_sessions = lambda wts, procs, now: {
            str(self.wt): [{"sid": "s1", "pid": 1, "status": "waiting"}]}
        out = self.finish(porcelain=["?? scratch.txt"], clean=True)
        self.assertEqual(out["mode"], "exit")
        self.assertFalse((self.wt / "scratch.txt").exists())

    def test_the_knob_on_a_clean_tree_changes_nothing(self):
        out = self.finish(porcelain=[], clean=True)
        self.assertEqual(out["mode"], "parked")
        self.assertNotIn("cleaned", out)

    def test_the_reap_runs_only_when_the_mission_actually_closed(self):
        reaped = []
        saved = fb.dispatch.reap_dead_sessions
        fb.dispatch.reap_dead_sessions = lambda wt: reaped.append(wt) or []
        try:
            self.scratch("scratch.txt")
            self.finish(porcelain=["?? scratch.txt"])       # -> dispatch
            self.assertEqual(reaped, [])
            self.finish(porcelain=[])                       # -> parked
            self.assertEqual(reaped, ["wt"])
        finally:
            fb.dispatch.reap_dead_sessions = saved


if __name__ == "__main__":
    unittest.main()
