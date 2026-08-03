#!/usr/bin/env python3
"""DISK — retention for the board's own logs, and a report on the corpus it
must never touch (PRODUCTION-READINESS.md Tier 4 §12).

    python3 -m unittest tests.test_fixes_disk -v

The Tier 4 item said "there's a backup job; there is no pruning". There is no
backup job: `transcripts.py` is read-only end to end, so what grows ~1,000
files/day is the USER's `~/.claude*/projects`, not a copy orchestra made. That
turns the item into two different pieces of work, and both are pinned here:

  * the corpus is REPORTED and never written — the guards below are watched
    firing against a path under a Claude home, which is the test this whole
    module exists for;
  * orchestra's OWN two append-only logs rotate at a size cap, their segments
    are reaped only past `log_keep` AND past a hard 7-day floor, every batch
    that removes something writes an audit line, and both readers still return
    their last N lines across the rotation boundary.

Isolation follows `test_fixes_auth.py::FixCase` — a private registry, audit log
and dispatch log rebound at runtime into a tmpdir, restored in tearDown.
"""

import json
import os
import shutil
import sys
import tempfile
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))
import orchestra as fb  # noqa: E402

DAY = 86400.0


class DiskCase(unittest.TestCase):
    def setUp(self):
        self.dir = Path(tempfile.mkdtemp(prefix="fb-fix-disk-"))
        self._saved = (fb.auth.REGISTRY, fb.auth.AUDIT_LOG,
                       fb.dispatch.DISPATCH_LOG)
        fb.auth.REGISTRY = self.dir / "devices.json"
        fb.auth.AUDIT_LOG = self.dir / "audit.log.jsonl"
        fb.dispatch.DISPATCH_LOG = self.dir / "dispatch.log.jsonl"
        fb.auth._forget_registry()
        fb.auth._reset_buckets()
        fb.disk._reset()
        self._cfg = dict(fb.CFG)

    def tearDown(self):
        (fb.auth.REGISTRY, fb.auth.AUDIT_LOG,
         fb.dispatch.DISPATCH_LOG) = self._saved
        fb.auth._forget_registry()
        fb.auth._reset_buckets()
        fb.disk._reset()
        fb.CFG.clear()
        fb.CFG.update(self._cfg)
        shutil.rmtree(self.dir, ignore_errors=True)

    def seg(self, live, stamp, body="x\n", age_days=None):
        """A rotated segment of `live`, optionally aged."""
        p = Path(live).with_name(Path(live).name + "." + stamp)
        p.write_text(body)
        os.chmod(p, 0o600)
        if age_days is not None:
            t = time.time() - age_days * DAY
            os.utime(p, (t, t))
        return p


# --------------------------------------------------- D1: the deletion guards

class TestTheGuards(DiskCase):
    """Nothing under a Claude home is ever a candidate for deletion."""

    def test_a_transcript_is_never_ours(self):
        """The rule the whole module is built to keep.

        A `.jsonl` under `~/.claude*/projects` is the user's data. Even shaped
        to look like a segment of the audit log it must not pass the guard.
        """
        home = self.dir / ".claude-account9" / "projects" / "-Users-x-code"
        home.mkdir(parents=True)
        transcript = home / "audit.log.jsonl.20260101T000000"
        transcript.write_text('{"real": "session"}\n')
        self.assertFalse(fb.disk._ours(home / "audit.log.jsonl", transcript))
        self.assertTrue(fb.disk._user_data(transcript))
        # And it survives a prune aimed straight at it.
        fb.disk.prune_logs(logs=[home / "audit.log.jsonl"],
                           keep=0, floor_s=0.0, now=time.time() + 999 * DAY)
        self.assertTrue(transcript.exists())

    def test_a_symlink_into_a_claude_home_is_not_laundered(self):
        """`_user_data` resolves first, so a link cannot rename the corpus."""
        home = self.dir / ".claude" / "projects"
        home.mkdir(parents=True)
        real = home / "session.jsonl"
        real.write_text("{}\n")
        live = self.dir / "audit.log.jsonl"
        link = live.with_name("audit.log.jsonl.20260101T000000")
        try:
            link.symlink_to(real)
        except OSError:
            self.skipTest("symlinks unavailable")
        self.assertFalse(fb.disk._ours(live, link))

    def test_only_our_own_stamp_shape_counts(self):
        live = self.dir / "audit.log.jsonl"
        live.write_text("{}\n")
        for name in ("audit.log.jsonl.1",            # the logrotate shape
                     "audit.log.jsonl.bak",
                     "audit.log.jsonl.2026-08-04",   # not our stamp
                     "audit.log.jsonlX.20260804T000000",
                     "devices.json.20260804T000000"):
            p = self.dir / name
            p.write_text("x\n")
            self.assertFalse(fb.disk._ours(live, p), name)
        good = self.seg(live, "20260804T000000")
        self.assertTrue(fb.disk._ours(live, good))

    def test_a_segment_in_another_directory_is_not_ours(self):
        live = self.dir / "audit.log.jsonl"
        other = self.dir / "elsewhere"
        other.mkdir()
        stray = other / "audit.log.jsonl.20260804T000000"
        stray.write_text("x\n")
        self.assertFalse(fb.disk._ours(live, stray))


# ------------------------------------------------------------ D2: rotation

class TestRotation(DiskCase):
    def test_a_log_past_the_cap_is_rotated_and_the_new_one_is_0600(self):
        log = fb.auth.AUDIT_LOG
        fb.CFG["log_max_mb"] = 0.001            # 1,024 bytes
        log.write_text("y" * 2000 + "\n")
        os.chmod(log, 0o600)
        rec = fb.disk.rotate_if_needed(log, record=False)
        self.assertIsNotNone(rec)
        self.assertEqual(rec["bytes"], 2001)
        segs = fb.disk.segments(log)
        self.assertEqual(len(segs), 1)
        self.assertEqual(os.stat(segs[0]).st_mode & 0o777, 0o600)
        self.assertFalse(log.exists())          # the append recreates it, 0600
        fb.auth.audit(at=1.0, event="after")
        self.assertEqual(os.stat(log).st_mode & 0o777, 0o600)

    def test_a_log_under_the_cap_is_left_alone(self):
        log = fb.auth.AUDIT_LOG
        fb.CFG["log_max_mb"] = 8.0
        log.write_text("small\n")
        self.assertIsNone(fb.disk.rotate_if_needed(log, record=False))
        self.assertEqual(fb.disk.segments(log), [])

    def test_log_max_mb_zero_means_off_not_rotate_every_line(self):
        """The literal reading is a cap every line is over — a fresh segment
        per second, forever. A misconfiguration must not become a worse disk
        problem than the one this module exists for."""
        log = fb.auth.AUDIT_LOG
        fb.CFG["log_max_mb"] = 0
        for i in range(5):
            fb.auth.audit(at=float(i), peer="127.0.0.1")
        self.assertEqual(fb.disk.segments(log), [])
        self.assertEqual(len(fb.auth.read_audit()), 5)

    def test_a_junk_log_max_mb_falls_back_to_the_default(self):
        fb.CFG["log_max_mb"] = "eight"
        self.assertEqual(fb.disk._max_bytes(), fb.disk.LOG_MAX_MB * 1024 * 1024)
        fb.CFG["log_keep"] = None
        self.assertEqual(fb.disk._keep(), fb.disk.LOG_KEEP)

    def test_rotation_never_deletes(self):
        """Rotation and reaping are split so the only unlink is in prune_logs."""
        log = fb.auth.AUDIT_LOG
        fb.CFG.update(log_max_mb=0.001, log_keep=1)
        for i in range(4):
            log.write_text("z" * 2000 + "\n")
            fb.disk.rotate_if_needed(log, record=False,
                                     now=time.time() + i * 3600)
        self.assertEqual(len(fb.disk.segments(log)), 4)   # keep=1 did NOT bite

    def test_the_audit_log_records_its_own_rotation_in_the_new_file(self):
        """The marker is the first line of the fresh file, written inline.

        `auth.audit` holds `_audit_lock` while it rotates, so a line written
        from inside `disk` would deadlock on it — this pins that the marker
        still lands, and lands where a reader will find it.
        """
        fb.CFG["log_max_mb"] = 0.001
        fb.auth.AUDIT_LOG.write_text("q" * 2000 + "\n")
        fb.auth.audit(at=2.0, peer="127.0.0.1", outcome="allow")
        lines = [json.loads(x) for x in
                 fb.auth.AUDIT_LOG.read_text().splitlines()]
        self.assertEqual(lines[0]["event"], "log_rotated")
        self.assertEqual(lines[0]["file"], "audit.log.jsonl")
        self.assertEqual(lines[0]["bytes"], 2001)
        self.assertEqual(lines[1]["outcome"], "allow")

    def test_the_dispatch_log_rotation_is_audited(self):
        """Its marker goes to the AUDIT log, not into its own rows — a
        synthetic row would come back out of `read_dispatch_log` as an entry
        with no session for the board to render."""
        fb.CFG["log_max_mb"] = 0.001
        fb.dispatch.DISPATCH_LOG.write_text("w" * 2000 + "\n")
        fb.dispatch._append_log(session="fleet-x", worktree="wt")
        events = [r.get("event") for r in fb.auth.read_audit()]
        self.assertIn("log_rotated", events)
        rows = fb.dispatch.read_dispatch_log()["entries"]
        self.assertTrue(all(r.get("event") != "log_rotated" for r in rows))


# -------------------------------------------------- D3: the reaper and floor

class TestPruneKeepsTheFloor(DiskCase):
    def test_segments_past_keep_and_past_the_floor_are_removed(self):
        log = fb.auth.AUDIT_LOG
        log.write_text("{}\n")
        old = [self.seg(log, f"2025010{i}T000000", "old\n" * 10, age_days=30 + i)
               for i in range(1, 5)]
        summary = fb.disk.prune_logs(logs=[log], keep=1, record=False)
        self.assertEqual(summary["removed"], 3)
        self.assertEqual(summary["bytes_freed"], 3 * len("old\n" * 10))
        self.assertFalse(any(p.exists() for p in old[:3]))
        self.assertTrue(old[3].exists())        # the newest, kept

    def test_the_seven_day_floor_outranks_log_keep(self):
        """THE floor. `keep=0` asks for every segment to go; the ones written
        this week stay anyway, because the week just gone is the window in
        which somebody investigating a stolen token goes looking."""
        log = fb.auth.AUDIT_LOG
        log.write_text("{}\n")
        young = self.seg(log, "20260801T000000", age_days=6.9)
        older = self.seg(log, "20260101T000000", age_days=8.0)
        summary = fb.disk.prune_logs(logs=[log], keep=0, record=False)
        self.assertTrue(young.exists(), "a segment under 7 days was deleted")
        self.assertFalse(older.exists())
        self.assertEqual(summary["removed"], 1)
        self.assertEqual(summary["held_by_floor"], 1)

    def test_the_floor_is_not_a_config_key(self):
        """It cannot be turned off from a config file, by design."""
        self.assertEqual(fb.disk.PRUNE_FLOOR_S, 7 * 86400)
        self.assertNotIn("prune_floor_s", fb.CFG)
        self.assertNotIn("retention_days", fb.CFG)

    def test_a_prune_batch_writes_one_audit_line_with_counts_and_bytes(self):
        log = fb.dispatch.DISPATCH_LOG
        log.write_text("{}\n")
        self.seg(log, "20250101T000000", "gone\n" * 5, age_days=40)
        self.seg(log, "20250102T000000", "gone\n" * 5, age_days=39)
        summary = fb.disk.prune_logs(logs=[log], keep=0)
        rows = [r for r in fb.auth.read_audit() if r.get("event") == "disk_prune"]
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["removed"], 2)
        self.assertEqual(rows[0]["bytes_freed"], summary["bytes_freed"])
        self.assertGreater(rows[0]["bytes_freed"], 0)

    def test_a_batch_that_removed_nothing_writes_nothing(self):
        """An audit line per pass would bury the eleven lines the log is for."""
        log = fb.auth.AUDIT_LOG
        log.write_text("{}\n")
        self.seg(log, "20260801T000000", age_days=1.0)
        fb.disk.prune_logs(logs=[log], keep=0)
        self.assertEqual([r for r in fb.auth.read_audit()
                          if r.get("event") == "disk_prune"], [])


# ------------------------------------------- D4: the readers survive rotation

class TestReadersCrossTheBoundary(DiskCase):
    def test_read_audit_still_returns_its_last_n_after_a_rotation(self):
        """Without this a rotation looks exactly like a wiped audit log."""
        for i in range(30):
            fb.auth.audit(at=float(i), peer="127.0.0.1", n=i)
        fb.disk.rotate_if_needed(fb.auth.AUDIT_LOG, max_bytes=1, record=False)
        fb.auth.audit(at=99.0, peer="127.0.0.1", n=99)
        rows = fb.auth.read_audit(limit=20)
        self.assertEqual(len(rows), 20)
        self.assertEqual(rows[-1]["n"], 99)
        # 30 lines in the segment + 1 live: a tail of 20 is n=11..29 then 99,
        # i.e. it reached 19 lines back INTO the segment for them.
        self.assertEqual(rows[0]["n"], 11)

    def test_read_dispatch_log_still_returns_its_last_n_after_a_rotation(self):
        for i in range(10):
            fb.dispatch._append_log(session=f"s{i}", worktree="wt")
        fb.disk.rotate_if_needed(fb.dispatch.DISPATCH_LOG, max_bytes=1,
                                 record=False)
        fb.dispatch._append_log(session="s10", worktree="wt")
        entries = fb.dispatch.read_dispatch_log(limit=5)["entries"]
        self.assertEqual([e["session"] for e in entries],
                         ["s10", "s9", "s8", "s7", "s6"])

    def test_a_missing_log_reads_as_empty_not_as_an_error(self):
        self.assertEqual(fb.auth.read_audit(), [])
        self.assertEqual(fb.dispatch.read_dispatch_log(), {"entries": []})


# ------------------------------------------------------- D5: the corpus report

class TestCorpusIsReportedNeverTouched(DiskCase):
    def _fake_home(self, name=".claude-test", days=200, size=4096):
        home = self.dir / name
        proj = home / "projects" / "-Users-x-code"
        proj.mkdir(parents=True)
        f = proj / "session.jsonl"
        f.write_text("j" * size)
        t = time.time() - days * DAY
        os.utime(f, (t, t))
        fb.CFG["homes"] = [str(home)]
        fb.disk._reset()
        return home, f

    def test_it_counts_bytes_files_and_the_oldest_write(self):
        _, f = self._fake_home(days=193, size=4096)
        c = fb.disk.corpus(force=True)
        self.assertEqual(c["files"], 1)
        self.assertEqual(c["bytes"], 4096)
        self.assertEqual(c["oldest"], str(f))
        self.assertAlmostEqual((time.time() - c["oldest_at"]) / DAY, 193,
                               delta=0.1)

    def test_the_report_names_the_size_and_the_oldest_file(self):
        _, f = self._fake_home(days=193)
        fb.CFG.update(disk_warn_gb=0.0, disk_free_gb=1e9)   # force the warning
        lines = fb.disk.report_lines(force=True)
        blob = "\n".join(lines)
        self.assertIn("193 days ago", blob)
        self.assertIn("WARNING", blob)
        self.assertIn(str(f), blob)
        self.assertIn("orchestra never deletes your transcripts", blob)
        # It must never hand the user a destructive one-liner to paste.
        self.assertIn("-print", blob)
        self.assertNotIn("-delete", blob)
        self.assertNotIn("rm ", blob)

    def test_a_quiet_disk_says_one_line_and_no_warning(self):
        self._fake_home(size=4096)
        fb.CFG.update(disk_warn_gb=1e6, disk_free_gb=0.0)
        lines = fb.disk.report_lines(force=True)
        self.assertEqual(len(lines), 1)
        self.assertNotIn("WARNING", lines[0])
        # …and that one line is still the report, not a placeholder: it names
        # the size and the count, which is what makes it worth logging at all.
        self.assertIn("transcript corpus", lines[0])
        self.assertIn("1 files", lines[0])
        self.assertIn("free on that filesystem", lines[0])

    def test_reporting_writes_nothing_and_deletes_nothing(self):
        """The corpus is the user's. A report that changed it would be a bug
        with no error message."""
        home, f = self._fake_home()
        before = {p: (p.stat().st_size, p.stat().st_mtime)
                  for p in home.rglob("*") if p.is_file()}
        fb.disk.corpus(force=True)
        fb.disk.report_lines(force=True)
        fb.disk.prune_logs(keep=0, floor_s=0.0)
        after = {p: (p.stat().st_size, p.stat().st_mtime)
                 for p in home.rglob("*") if p.is_file()}
        self.assertEqual(before, after)
        self.assertTrue(f.exists())

    def test_the_scan_is_cached_because_it_is_expensive(self):
        """1,256 ms cold over 35,365 real files — never on a request path."""
        self._fake_home()
        first = fb.disk.corpus(force=True)
        again = fb.disk.corpus()
        self.assertIs(first, again)
        self.assertIsNot(first, fb.disk.corpus(force=True))

    def test_no_claude_home_is_not_a_crash(self):
        fb.CFG["homes"] = [str(self.dir / "nowhere")]
        fb.disk._reset()
        c = fb.disk.corpus(force=True)
        self.assertEqual((c["files"], c["bytes"], c["homes"]), (0, 0, []))
        self.assertEqual(len(fb.disk.report_lines(force=True)), 1)


# ------------------------------------------------------------ D6: the loop

class TestTheLoopIsOptional(DiskCase):
    def test_disk_report_h_zero_stops_the_thread(self):
        """A documented off switch that returns instead of spinning."""
        fb.CFG["disk_report_h"] = 0
        fb.disk.disk_loop()          # returns; a spin would hang the suite

    def test_own_logs_are_read_through_the_module_objects(self):
        """They are REBOUND at runtime — a list built at import time would
        prune the developer's real logs during the test run."""
        self.assertEqual(fb.disk.own_logs(),
                         [self.dir / "audit.log.jsonl",
                          self.dir / "dispatch.log.jsonl"])


if __name__ == "__main__":
    unittest.main()
