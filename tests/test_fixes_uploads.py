#!/usr/bin/env python3
"""UPLOADS — an image from the phone becomes a file on this Mac, and the reply
is the path an agent can actually read.

    python3 -m unittest tests.test_fixes_uploads -v

`POST /api/v1/uploads` is the one route in this program that writes a file
whose CONTENT came off the network, so the things pinned here are the things
that go wrong when a route like it is written quickly:

  U1  the format comes from the MAGIC BYTES, never from the client — every
      accepted format sniffed out of a real file's head, and a zip, a script,
      an SVG and an MP4 refused by a sentence that names what arrived;
  U2  the client's `name` is a hint and reaches the filesystem NOWHERE: a
      traversal, a NUL, a separator and a leading dot all land on the same
      server-generated `<16 hex>.<sniffed ext>` inside today's directory;
  U3  the size cap is enforced TWICE — on the encoded string before anything
      is decoded (proved by making `b64decode` explode), and on the decoded
      bytes — and `server.MAX_BODY` is still 256 KB for every other route;
  U4  0700 on the directories, 0600 on the file;
  U5  one audit line per upload, carrying the byte count and the kind and not
      one byte of the image;
  U6  the path returned exists, is absolute, and lives OUTSIDE every git
      worktree — `finish.start_finish(clean_scratch=True)` deletes untracked
      files in a worktree, so an upload inside one is a path handed to an agent
      and then destroyed underneath it;
  U7  `disk.prune_uploads` reaps an old upload, keeps a fresh one, and cannot
      be talked into touching anything it did not name;
  U8  the door: a remote request with no token is refused, and the route is
      exempt from nothing.

The image fixtures are REAL FILES, not hand-written headers. The PNG was
generated with `zlib`/`struct`, converted by `sips -s format {jpeg,gif,heic}`
on this machine (the HEIC is the same container an iPhone photo uses:
`ftypheic` with `mif1`/`miaf`/`heic` in its compatible-brand list), and the
WebP head is the first 64 bytes of a real VP8 `.webp`. Isolation follows
`tests/test_fixes_disk.py::DiskCase` — the uploads root and the audit log are
rebound into a tmpdir and restored in tearDown.
"""

import base64
import http.client
import io
import json
import os
import re
import shutil
import stat
import sys
import tempfile
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))
import orchestra as fb  # noqa: E402

DAY = 86400.0

# ---- real files, base64'd (see the module docstring for how they were made) --

PNG = base64.b64decode(
    "iVBORw0KGgoAAAANSUhEUgAAAEAAAABACAIAAAAlC+aJAAAAT0lEQVR42u3PQQkAAAgE"
    "sItjCPtjLCP4FgYrsEz1axEQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQ"
    "EBAQEBAQEBAQEBAQuCxzdcEP/ItULAAAAABJRU5ErkJggg==")
GIF = base64.b64decode(
    "R0lGODdhQABAAJEAAAAAAMgoPP///wAAACH5BAQAAAAALAAAAABAAEAAAAJFjI+py+0P"
    "o5y02ouz3rz7D4biSJbmiabqyrbuC8fyTNf2jef6zvf+DwwKh8Si8YhMKpfMpvMJjUqn"
    "1Kr1is1qt9yuN1AAADs=")
# A real HEIC, whole: `sips -s format heic`. Its brands are exactly what an
# iPhone still carries — major `heic`, compatible `mif1 MiPr miaf MiHB heic`.
HEIC = base64.b64decode(
    "AAAAJGZ0eXBoZWljAAAAAG1pZjFNaVBybWlhZk1pSEJoZWljAAABhW1ldGEAAAAAAAAA"
    "IWhkbHIAAAAAAAAAAHBpY3QAAAAAAAAAAAAAAAAAAAAAJGRpbmYAAAAcZHJlZgAAAAAA"
    "AAABAAAADHVybCAAAAABAAAADnBpdG0AAAAAAAEAAAAjaWluZgAAAAAAAQAAABVpbmZl"
    "AgAAAAABAABodmMxAAAAAOVpcHJwAAAAxGlwY28AAAATY29scm5jbHgAAgACAAaAAAAA"
    "DGNsbGkAywBAAAAAFGlzcGUAAAAAAAAAQAAAAEAAAAAJaXJvdAAAAAAQcGl4aQAAAAAD"
    "CAgIAAAAcGh2Y0MBA3AAAACwAAAAAAAe8AD8/fj4AAALA6AAAQAXQAEMAf//A3AAAAMA"
    "sAAAAwAAAwAecCShAAEAIkIBAQNwAAADALAAAAMAAAMAHqAUIEHBj4h7kWVTcCAgYAii"
    "AAEACUQBwGFyyEBTJAAAABlpcG1hAAAAAAAAAAEAAQaBAgMFhoQAAAAeaWxvYwAAAABE"
    "AAABAAEAAAABAAABuQAAADAAAAABbWRhdAAAAAAAAABAAAAALCgBr6L6RsV//ssL/9CP"
    "IeGx4z3ET//qCB//wY4//uC9P6f/QD5uBwmY4qj8")
# The first 64 bytes of real files. Only the first twelve decide anything, and
# a truncated JPEG/WebP is still exactly the head the sniffer reads.
JPEG = base64.b64decode(
    "/9j/4AAQSkZJRgABAQAASABIAAD/4QBMRXhpZgAATU0AKgAAAAgAAYdpAAQAAAABAAAA"
    "GgAAAAAAA6ABAAMAAAABAAEAAKACAAQAAAABAAAAQKADAAQAAAABAAAAQAAAAAA=")
WEBP = (b"RIFF>\x06\x01\x00WEBPVP8 2\x06\x01\x00p\xa4\x04\x9d\x01*\xae\x03\x00"
        b"\x08>)\x14\x88C!\xa1!\x10\xc9\x1c\x9c\x18\x02\x84\xb4\xb7~\x0c2\xc4")

# The things a share sheet hands out by mistake, and one thing an attacker
# hands over on purpose.
ZIP = b"PK\x03\x04\x14\x00\x08\x00\x08\x00" + b"\x00" * 40
SCRIPT = b"#!/bin/sh\nrm -rf ~\n"
SVG = b'<svg xmlns="http://www.w3.org/2000/svg"><rect width="9" height="9"/></svg>'
MP4 = b"\x00\x00\x00\x18ftypisom\x00\x00\x02\x00isomiso2mp41" + b"\x00" * 16


def b64(data):
    return base64.b64encode(data).decode()


class UploadCase(unittest.TestCase):
    def setUp(self):
        self.dir = Path(tempfile.mkdtemp(prefix="fb-fix-uploads-"))
        self._saved = (fb.uploads.UPLOAD_ROOT, fb.auth.AUDIT_LOG,
                       fb.auth.REGISTRY)
        fb.uploads.UPLOAD_ROOT = self.dir / "home" / ".orchestra" / "uploads"
        fb.auth.AUDIT_LOG = self.dir / "audit.log.jsonl"
        fb.auth.REGISTRY = self.dir / "devices.json"
        fb.auth._forget_registry()
        fb.auth._reset_buckets()
        fb.disk._reset()
        self._cfg = dict(fb.CFG)

    def tearDown(self):
        (fb.uploads.UPLOAD_ROOT, fb.auth.AUDIT_LOG,
         fb.auth.REGISTRY) = self._saved
        fb.auth._forget_registry()
        fb.auth._reset_buckets()
        fb.disk._reset()
        fb.CFG.clear()
        fb.CFG.update(self._cfg)
        shutil.rmtree(self.dir, ignore_errors=True)

    # -- helpers -----------------------------------------------------------

    def send(self, data, name=None, **kw):
        payload = {"data": b64(data) if isinstance(data, bytes) else data}
        if name is not None:
            payload["name"] = name
        return fb.uploads.receive(payload, **kw)

    def day_dir(self, now=None):
        day = time.strftime("%Y-%m-%d", time.localtime(now or time.time()))
        return Path(fb.uploads.UPLOAD_ROOT) / day

    def audit(self):
        return fb.auth.read_audit(50)

    def plant(self, name, body=b"x", age_days=0.0, day=None):
        """A file inside a day directory, optionally aged. For the prune tests."""
        folder = Path(fb.uploads.UPLOAD_ROOT) / (day or "2026-01-02")
        folder.mkdir(parents=True, exist_ok=True)
        p = folder / name
        p.write_bytes(body)
        t = time.time() - age_days * DAY
        os.utime(p, (t, t))
        return p


# ------------------------------------------- U1: the bytes decide the format

class TestTheBytesDecide(UploadCase):
    """The client's word is never consulted. `sniff` reads magic bytes."""

    def test_every_accepted_format_is_sniffed_from_a_real_head(self):
        for data, kind in ((PNG, "png"), (JPEG, "jpeg"), (GIF, "gif"),
                           (WEBP, "webp"), (HEIC, "heic")):
            self.assertEqual(fb.uploads.sniff(data), kind)

    def test_the_route_reports_the_sniffed_kind_and_extension(self):
        for data, kind, ext in ((PNG, "png", ".png"), (JPEG, "jpeg", ".jpg"),
                                (GIF, "gif", ".gif"), (WEBP, "webp", ".webp"),
                                (HEIC, "heic", ".heic")):
            out = self.send(data)
            self.assertTrue(out["ok"], out)
            self.assertEqual(out["kind"], kind)
            self.assertTrue(out["path"].endswith(ext), out["path"])

    def test_a_lying_name_cannot_change_the_extension(self):
        """The classic: a `.png` name on a JPEG, and a `.exe` name on a PNG."""
        out = self.send(JPEG, name="screenshot.png")
        self.assertEqual(out["kind"], "jpeg")
        self.assertTrue(out["path"].endswith(".jpg"), out["path"])
        out = self.send(PNG, name="payload.exe")
        self.assertTrue(out["path"].endswith(".png"), out["path"])

    def test_a_zip_is_refused_and_the_sentence_says_what_arrived(self):
        out = self.send(ZIP, name="photo.png")
        self.assertFalse(out["ok"])
        self.assertIn("zip archive", out["error"])
        self.assertIn("PNG, JPEG, GIF, WebP and HEIC/HEIF", out["error"])
        self.assertEqual(list(Path(fb.uploads.UPLOAD_ROOT).glob("**/*")), [])

    def test_a_script_is_refused_by_name(self):
        out = self.send(SCRIPT, name="cat.gif")
        self.assertFalse(out["ok"])
        self.assertIn("#!", out["error"])

    def test_an_svg_is_refused_because_it_is_markup(self):
        out = self.send(SVG)
        self.assertFalse(out["ok"])
        self.assertIn("SVG", out["error"])

    def test_bytes_with_no_shape_at_all_are_described_as_bytes(self):
        """A run of NULs decodes as UTF-8 perfectly happily, and calling that
        "text" sends somebody looking for a text editor."""
        self.assertEqual(fb.uploads.describe(b"\x00" * 64),
                         "64 bytes beginning 0000000000000000")
        self.assertEqual(fb.uploads.describe(b"hello there\n"), "text")
        self.assertEqual(fb.uploads.describe(b""), "nothing at all")

    def test_an_mp4_shares_heics_container_and_is_still_refused(self):
        """The ftyp box is the whole difference between a photo and a video."""
        self.assertIsNone(fb.uploads.sniff(MP4))
        out = self.send(MP4)
        self.assertFalse(out["ok"])
        self.assertIn("isom", out["error"])

    def test_the_heic_brand_table_reads_the_compatible_list(self):
        """An edited iPhone photo declares `mif1` as its MAJOR brand and lists
        `heic` further down; calling that a `.heif` would be true and useless."""
        mif1 = (b"\x00\x00\x00\x20ftypmif1\x00\x00\x00\x00"
                b"mif1heic" + b"\x00" * 16)
        self.assertEqual(fb.uploads.sniff(mif1), "heic")
        plain = b"\x00\x00\x00\x18ftypmif1\x00\x00\x00\x00mif1" + b"\x00" * 16
        self.assertEqual(fb.uploads.sniff(plain), "heif")

    def test_a_lying_ftyp_length_buys_one_short_loop(self):
        """The box length is client-controlled; the walk is bounded by the data
        we have and by `_FTYP_SCAN`, so a huge length cannot spin."""
        liar = b"\xff\xff\xff\xffftypisom\x00\x00\x00\x00" + b"heic" * 4
        self.assertEqual(fb.uploads.sniff(liar), "heic")   # a real compatible brand
        self.assertLessEqual(len(list(fb.uploads._brands(liar))), 20)

    def test_an_empty_or_missing_data_field_is_a_sentence_not_a_crash(self):
        for payload in ({}, {"data": ""}, {"data": None}, {"data": 42},
                        {"data": "   "}, {"name": "x.png"}):
            out = fb.uploads.receive(payload)
            self.assertFalse(out["ok"], payload)
            self.assertIn("base64", out["error"])

    def test_a_body_that_is_not_base64_is_refused_rather_than_salvaged(self):
        """`validate=True`: the lenient default DISCARDS stray characters, so a
        body with a NUL in it would decode to something neither end sent."""
        out = fb.uploads.receive({"data": "not base64 at all!!\x00"})
        self.assertFalse(out["ok"])
        self.assertIn("not valid base64", out["error"])

    def test_a_data_url_prefix_is_stripped_and_its_claim_ignored(self):
        out = fb.uploads.receive({"data": "data:image/png;base64," + b64(JPEG)})
        self.assertTrue(out["ok"], out)
        self.assertEqual(out["kind"], "jpeg")      # the bytes, not the prefix


# ------------------------------------- U2: the client's name touches nothing

class TestTheServerNamesTheFile(UploadCase):
    """A client-supplied filename reaching the filesystem is the oldest hole
    there is, and this route writes to a real user's disk from a phone."""

    HOSTILE = ("../../etc/passwd", "..", ".", "....//....//etc/passwd",
               "/etc/passwd", "sub/dir/photo.png", "photo\x00.png",
               ".bashrc", "-rf", "photo.png\n../../x", "\\..\\..\\win.ini",
               "%2e%2e%2fetc%2fpasswd", "a" * 400, "", "‮exe.gnp")

    def test_no_hint_can_influence_the_written_path(self):
        root = Path(fb.uploads.UPLOAD_ROOT)
        for hint in self.HOSTILE:
            out = self.send(PNG, name=hint)
            self.assertTrue(out["ok"], (hint, out))
            path = Path(out["path"])
            self.assertEqual(path.parent, self.day_dir(), hint)
            self.assertTrue(fb.uploads.NAME_RE.match(path.name), (hint, path.name))
            self.assertEqual(out["name"], path.name)
            self.assertTrue(path.is_file(), hint)
        # Nothing was created anywhere but the one day directory, and every
        # file in it is one this server named.
        written = sorted(p for p in root.glob("**/*") if p.is_file())
        self.assertTrue(written)
        for p in written:
            self.assertEqual(p.parent, self.day_dir())
            self.assertTrue(fb.uploads.NAME_RE.match(p.name), p.name)
        # …and nothing escaped the tmp home at all.
        self.assertEqual(sorted(x.name for x in self.dir.iterdir()),
                         ["audit.log.jsonl", "home"])

    def test_the_name_is_content_addressed_and_stable(self):
        first, second = self.send(PNG, name="a.png"), self.send(PNG, name="b.png")
        self.assertEqual(first["path"], second["path"])
        self.assertEqual(first["name"][:16], fb.uploads.hashlib.sha256(PNG)
                         .hexdigest()[:16])

    def test_a_duplicate_writes_nothing_and_restarts_the_retention_clock(self):
        """A phone whose upload timed out and retried must not leave two copies
        — and the path it is handed the second time must not be one that ages
        out on the FIRST upload's clock."""
        first = self.send(PNG)
        path = Path(first["path"])
        old = time.time() - 20 * DAY
        os.utime(path, (old, old))
        before = sorted(p.name for p in self.day_dir().iterdir())
        second = self.send(PNG)
        self.assertEqual(second["path"], first["path"])
        self.assertEqual(sorted(p.name for p in self.day_dir().iterdir()), before)
        self.assertGreater(path.stat().st_mtime, old + DAY)

    def test_no_temp_file_survives_a_write(self):
        self.send(PNG)
        self.assertEqual([p.name for p in self.day_dir().iterdir()
                          if ".part-" in p.name], [])


# ------------------------------------------------------- U3: the size cap

class _Explode:
    """Stands in for `base64` so a decode that should never happen is loud."""

    def b64decode(self, *a, **kw):
        raise AssertionError("the encoded body was decoded before the cap ran")


class TestTheCapIsEnforcedTwice(UploadCase):
    def setUp(self):
        super().setUp()
        fb.CFG["upload_max_mb"] = 1 / 1024.0        # exactly 1024 bytes
        self.assertEqual(fb.uploads.max_bytes(), 1024)

    def pad(self, n):
        """A real PNG padded out to exactly `n` bytes. The head is what the
        sniffer reads, so this is a PNG of the size the test wants."""
        return (PNG + b"\x00" * n)[:n]

    def test_exactly_at_the_cap_is_accepted(self):
        out = self.send(self.pad(1024))
        self.assertTrue(out["ok"], out)
        self.assertEqual(out["bytes"], 1024)

    def test_one_byte_over_is_refused_by_the_decoded_check(self):
        out = self.send(self.pad(1025))
        self.assertFalse(out["ok"])
        self.assertIn("that image is", out["error"])
        self.assertIn("upload_max_mb", out["error"])

    def test_a_huge_string_is_refused_before_it_is_decoded(self):
        """The cheap check, proved: `b64decode` is replaced by something that
        raises, and the refusal still comes back."""
        saved = fb.uploads.base64
        fb.uploads.base64 = _Explode()
        try:
            out = fb.uploads.receive({"data": "A" * (4 * 1024 * 1024)})
        finally:
            fb.uploads.base64 = saved
        self.assertFalse(out["ok"])
        self.assertIn("that upload is about", out["error"])
        self.assertIn("upload_max_mb", out["error"])

    def test_the_two_checks_meet_without_a_gap(self):
        """A payload the cheap check lets through is caught by the decoded one:
        the encoded bound is the SMALLEST decode a string can produce, so it
        can never refuse an image that is exactly on the cap."""
        raw = self.pad(1025)
        text = b64(raw)
        self.assertLessEqual(fb.uploads._raw_len(len(text)), 1024)   # passes cheap
        self.assertFalse(self.send(raw)["ok"])                       # caught late

    def test_a_broken_knob_falls_back_to_the_default(self):
        for bad in ("banana", None, {}):
            fb.CFG["upload_max_mb"] = bad
            self.assertEqual(fb.uploads.max_bytes(),
                             int(fb.uploads.MAX_MB * 1024 * 1024))


# --------------------------------------------- U4/U5: modes, and the audit

class TestModesAndAudit(UploadCase):
    def test_the_file_is_0600_and_every_directory_0700(self):
        out = self.send(PNG)
        path = Path(out["path"])
        self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
        self.assertEqual(stat.S_IMODE(path.parent.stat().st_mode), 0o700)
        self.assertEqual(stat.S_IMODE(Path(fb.uploads.UPLOAD_ROOT)
                                      .stat().st_mode), 0o700)

    def test_a_loose_directory_from_an_older_run_is_tightened(self):
        root = Path(fb.uploads.UPLOAD_ROOT)
        root.mkdir(parents=True)
        os.chmod(root, 0o755)
        self.send(PNG)
        self.assertEqual(stat.S_IMODE(root.stat().st_mode), 0o700)

    def test_one_audit_line_per_upload_with_the_bytes_and_the_kind(self):
        self.send(HEIC, name="IMG_0421.HEIC", device="a1b2c3d4", peer="100.64.0.9")
        lines = [ln for ln in self.audit() if ln.get("event") == "upload"]
        self.assertEqual(len(lines), 1)
        line = lines[0]
        self.assertEqual(line["kind"], "heic")
        self.assertEqual(line["bytes"], len(HEIC))
        self.assertEqual(line["device"], "a1b2c3d4")
        self.assertEqual(line["peer"], "100.64.0.9")
        self.assertFalse(line["duplicate"])

    def test_the_audit_carries_no_image_and_no_client_text(self):
        """WHO / WHAT / WHEN and deliberately not WHAT WAS SENT — the pixels
        are the asset the tokens exist to protect, and the client's `name` is
        user text of exactly the sort `auth.audit` declines to keep."""
        self.send(PNG, name="my-secret-whiteboard.png")
        text = Path(fb.auth.AUDIT_LOG).read_text()
        self.assertIn('"event": "upload"', text)
        self.assertNotIn(b64(PNG)[:32], text)
        self.assertNotIn("whiteboard", text)
        self.assertNotIn(PNG[:8].hex(), text)

    def test_a_refused_upload_writes_no_upload_line(self):
        self.send(ZIP)
        self.assertEqual([ln for ln in self.audit()
                          if ln.get("event") == "upload"], [])


# ----------------------------------------- U6: the path, and where it lives

class TestThePathIsReal(UploadCase):
    def test_the_returned_path_exists_and_holds_exactly_what_was_sent(self):
        out = self.send(HEIC)
        path = Path(out["path"])
        self.assertTrue(path.is_absolute())
        self.assertTrue(path.exists())
        self.assertEqual(path.read_bytes(), HEIC)
        self.assertEqual(out["bytes"], len(HEIC))

    def test_the_default_root_is_outside_every_git_worktree(self):
        """THE REASON THIS MODULE WRITES TO ~ AND NOT TO THE REPO.
        `finish.start_finish(clean_scratch=True)` deletes untracked files in a
        worktree when a mission closes out. An upload living inside one would
        be handed to an agent as a path and then destroyed underneath it,
        silently, minutes later."""
        default = Path(self._saved[0])           # the production value
        self.assertEqual(default, Path(fb.HOME) / ".orchestra" / "uploads")
        here = Path(fb.HERE).resolve()
        self.assertNotIn(here, [default] + list(default.parents))
        for parent in [default] + list(default.parents):
            self.assertFalse((parent / ".git").exists(),
                             f"{parent} is inside a git worktree")

    def test_the_day_directory_is_todays_date(self):
        out = self.send(PNG)
        day = Path(out["path"]).parent.name
        self.assertTrue(fb.uploads.DAY_RE.match(day), day)
        self.assertEqual(day, time.strftime("%Y-%m-%d"))

    def test_a_disk_that_says_no_is_a_sentence_and_not_a_traceback(self):
        root = Path(fb.uploads.UPLOAD_ROOT)
        root.mkdir(parents=True)
        os.chmod(root, 0o500)                    # read-only: cannot mkdir a day
        try:
            out = self.send(PNG)
        finally:
            os.chmod(root, 0o700)
        self.assertFalse(out["ok"])
        self.assertIn("could not be written", out["error"])


# ------------------------------------------------------- U7: the retention

class TestThePrune(UploadCase):
    """These files are ORCHESTRA'S OWN — it chose the directory, chose the name
    and wrote the bytes — which is the whole reason `disk.py` may reap them and
    may not touch a transcript."""

    def name(self, ext=".png"):
        return "0123456789abcdef"[:16] + ext

    def test_an_old_upload_is_reaped_and_a_fresh_one_is_not(self):
        old = self.plant("aaaaaaaaaaaaaaaa.png", age_days=40)
        new = self.plant("bbbbbbbbbbbbbbbb.png", age_days=2)
        out = fb.disk.prune_uploads()
        self.assertEqual(out["removed"], 1)
        self.assertFalse(old.exists())
        self.assertTrue(new.exists())
        self.assertEqual(out["kept"], 1)
        self.assertEqual(out["bytes_freed"], 1)

    def test_the_floor_outranks_the_knob(self):
        """A path handed to an agent this morning is not reaped this afternoon,
        whatever `upload_retain_days` says. `held_by_floor` means what it means
        for the logs — this one was DUE and the floor held it — so a merely
        fresh file counts as kept, not as held."""
        fb.CFG["upload_retain_days"] = 1 / 86400.0       # "one second"
        fresh = self.plant("cccccccccccccccc.png", age_days=0.25)
        out = fb.disk.prune_uploads()
        self.assertEqual(out["removed"], 0)
        self.assertEqual(out["held_by_floor"], 1)
        self.assertEqual(out["kept"], 0)
        self.assertTrue(fresh.exists())
        fb.CFG["upload_retain_days"] = 30
        self.assertEqual(fb.disk.prune_uploads(),
                         {"removed": 0, "bytes_freed": 0, "kept": 1,
                          "held_by_floor": 0})

    def test_zero_days_means_keep_them_forever(self):
        fb.CFG["upload_retain_days"] = 0
        ancient = self.plant("dddddddddddddddd.png", age_days=900)
        self.assertEqual(fb.disk.prune_uploads()["removed"], 0)
        self.assertTrue(ancient.exists())

    def test_a_file_this_program_did_not_name_is_never_touched(self):
        """Guard 3 is a SHAPE test, so anything a human dropped in the folder —
        or anything a bug wrote under a different name — survives."""
        keepers = [self.plant(n, age_days=400) for n in
                   ("notes.txt", "holiday.png", "aaaaaaaaaaaaaaaa.exe",
                    "AAAAAAAAAAAAAAAA.png", "0123456789abcde.png",
                    "0123456789abcdef0.png", ".hidden.png")]
        out = fb.disk.prune_uploads()
        self.assertEqual(out["removed"], 0)
        for p in keepers:
            self.assertTrue(p.exists(), p.name)

    def test_a_write_killed_halfway_is_swept_up_a_day_later(self):
        """`kill -9` between the `open` and the `os.replace` is the one case
        `_write_once` cannot clean up after itself, and nothing else in the
        program ever comes back to that directory."""
        orphan = self.plant("aaaaaaaaaaaaaaaa.png.part-0f0f0f0f", age_days=40)
        fresh = self.plant("bbbbbbbbbbbbbbbb.png.part-1a1a1a1a", age_days=0.01)
        self.assertEqual(fb.disk.prune_uploads()["removed"], 1)
        self.assertFalse(orphan.exists())
        self.assertTrue(fresh.exists())

    def test_a_symlink_wearing_a_generated_name_is_not_followed(self):
        decoy = self.dir / "precious.png"
        decoy.write_bytes(PNG)
        folder = Path(fb.uploads.UPLOAD_ROOT) / "2026-01-02"
        folder.mkdir(parents=True, exist_ok=True)
        link = folder / "eeeeeeeeeeeeeeee.png"
        os.symlink(decoy, link)
        old = time.time() - 400 * DAY
        os.utime(link, (old, old), follow_symlinks=False)
        out = fb.disk.prune_uploads()
        self.assertEqual(out["removed"], 0)
        self.assertTrue(decoy.exists())
        self.assertTrue(link.is_symlink())

    def test_a_directory_that_is_not_a_date_is_left_alone(self):
        stray = Path(fb.uploads.UPLOAD_ROOT) / "keepme"
        stray.mkdir(parents=True)
        victim = stray / "ffffffffffffffff.png"
        victim.write_bytes(b"x")
        old = time.time() - 400 * DAY
        os.utime(victim, (old, old))
        self.assertEqual(fb.disk.prune_uploads()["removed"], 0)
        self.assertTrue(victim.exists())

    def test_an_emptied_day_goes_but_todays_never_does(self):
        self.plant("aaaaaaaaaaaaaaaa.png", age_days=40, day="2026-01-02")
        today = time.strftime("%Y-%m-%d")
        empty_today = Path(fb.uploads.UPLOAD_ROOT) / today
        empty_today.mkdir(parents=True, exist_ok=True)
        fb.disk.prune_uploads()
        self.assertFalse((Path(fb.uploads.UPLOAD_ROOT) / "2026-01-02").exists())
        self.assertTrue(empty_today.exists())

    def test_a_batch_that_removed_something_writes_one_audit_line(self):
        self.plant("aaaaaaaaaaaaaaaa.png", age_days=40)
        fb.disk.prune_uploads()
        lines = [ln for ln in self.audit() if ln.get("event") == "upload_prune"]
        self.assertEqual(len(lines), 1)
        self.assertEqual(lines[0]["removed"], 1)

    def test_nothing_removed_writes_nothing(self):
        self.plant("aaaaaaaaaaaaaaaa.png", age_days=1)
        fb.disk.prune_uploads()
        self.assertEqual([ln for ln in self.audit()
                          if ln.get("event") == "upload_prune"], [])

    def test_a_missing_root_is_the_common_case_and_not_an_error(self):
        self.assertEqual(fb.disk.prune_uploads()["removed"], 0)

    def test_the_transcript_guard_still_covers_this_path(self):
        """Guard 2 has no legitimate way to fire here, which is exactly why it
        is checked: a future refactor of guard 3 must not reach the corpus."""
        home = self.dir / ".claude" / "uploads"
        (home / "2026-01-02").mkdir(parents=True)
        victim = home / "2026-01-02" / "aaaaaaaaaaaaaaaa.png"
        victim.write_bytes(b"x")
        self.assertFalse(fb.disk._ours_upload(victim, root=home))

    def test_the_reap_runs_on_the_disk_loop(self):
        """`disk_loop` is where this is actually called from — pinned so a
        refactor cannot leave the uploads growing forever in silence. Read out
        of the source rather than by running the loop, which never returns."""
        src = (ROOT / "orchestra" / "disk.py").read_text()
        loop = src.split("def disk_loop(")[1].split("\ndef ")[0]
        self.assertIn("prune_uploads()", loop)


# ---------------------------------------------------------- U8: the door

def _handler(path, body=b"", command="POST", **headers):
    """A `Handler` on in-memory buffers, built with `__new__` so
    `parse_request`/`auth.check` never runs — the door is tested separately,
    below, against `auth.check` itself."""
    h = fb.Handler.__new__(fb.Handler)
    h.path = path
    h.command = command
    h.requestline = f"{command} {path} HTTP/1.0"
    h.request_version = "HTTP/1.0"
    h.protocol_version = "HTTP/1.0"
    h.client_address = ("100.64.0.9", 54321)
    h.close_connection = False
    h.headers = http.client.HTTPMessage()
    h.headers["Content-Length"] = str(len(body))
    for key, val in headers.items():
        h.headers[key.replace("_", "-")] = str(val)
    h.rfile = io.BytesIO(body)
    h.wfile = io.BytesIO()
    return h


class _Unreadable(io.BytesIO):
    def read(self, *a, **kw):
        raise AssertionError("an over-long body was read from the socket")


def _status(h):
    return int(h.wfile.getvalue().split(b"\r\n", 1)[0].split(b" ")[1])


def _body(h):
    return json.loads(h.wfile.getvalue().split(b"\r\n\r\n", 1)[1])


class TestTheRoute(UploadCase):
    def test_the_route_answers_with_the_path(self):
        body = json.dumps({"data": b64(PNG), "name": "IMG_0421.PNG"}).encode()
        h = _handler("/api/v1/uploads", body)
        h.do_POST()
        self.assertEqual(_status(h), 200)
        out = _body(h)
        self.assertTrue(out["ok"], out)
        self.assertTrue(Path(out["path"]).exists())
        self.assertEqual(out["kind"], "png")
        self.assertEqual(Path(out["path"]).name, out["name"])

    def test_a_refusal_is_a_200_carrying_a_sentence(self):
        """The house envelope: every refusal here is something the person
        holding the phone has to fix, so the app gets a sentence to show."""
        body = json.dumps({"data": b64(ZIP)}).encode()
        h = _handler("/api/v1/uploads", body)
        h.do_POST()
        self.assertEqual(_status(h), 200)
        out = _body(h)
        self.assertFalse(out["ok"])
        self.assertIn("zip archive", out["error"])

    def test_the_body_cap_is_this_routes_own_and_nothing_is_read(self):
        h = _handler("/api/v1/uploads")
        h.headers.replace_header("Content-Length",
                                 str(fb.uploads.max_body() + 1))
        h.rfile = _Unreadable()
        h.do_POST()
        self.assertEqual(_status(h), 413)
        self.assertIn(str(fb.uploads.max_body()), _body(h)["message"])

    def test_a_body_inside_the_upload_cap_is_read_on_this_route_only(self):
        """The same length that this route accepts is refused everywhere else,
        which is the whole point of a per-route cap."""
        big = b64(b"\x00" * (300 * 1024))
        body = json.dumps({"data": big}).encode()
        self.assertGreater(len(body), fb.server.MAX_BODY)
        h = _handler("/api/v1/uploads", body)
        h.do_POST()
        self.assertEqual(_status(h), 200)          # read, then refused on merit
        self.assertFalse(_body(h)["ok"])
        h = _handler("/api/send", body)
        h.rfile = _Unreadable()
        h.do_POST()
        self.assertEqual(_status(h), 413)

    def test_the_global_cap_did_not_move(self):
        self.assertEqual(fb.server.MAX_BODY, 256 * 1024)

    def test_the_router_and_the_cap_say_the_same_word(self):
        src = (ROOT / "orchestra" / "server.py").read_text()
        self.assertEqual(src.count('"%s"' % fb.uploads.ROUTE), 2)


class TestTheDoor(UploadCase):
    """It is a MUTATION that writes to the user's disk, so it is exempt from
    nothing — not from the token, not from the CSRF guard, not from the audit."""

    def test_a_stranger_with_no_token_is_refused(self):
        v = fb.auth.check("100.64.0.9", None, "POST", "/api/v1/uploads",
                          content_type="application/json")
        self.assertFalse(v.ok)
        self.assertEqual(v.status, 401)

    def test_it_is_in_no_exemption_list(self):
        self.assertFalse(fb.auth.exempt("POST", "/api/v1/uploads"))
        self.assertNotIn(("POST", "/api/v1/uploads"), fb.auth.EXEMPT)
        # `_acting_get` is the GET-side carve-out; a POST must never be in it.
        self.assertFalse(fb.auth._acting_get("POST", "/api/v1/uploads"))
        self.assertFalse(fb.auth._acting_get("GET", "/api/v1/uploads"))

    def test_the_csrf_guard_still_covers_it(self):
        """Without `Content-Type: application/json` a page you are merely
        visiting could post an image into your fleet from your browser."""
        v = fb.auth.check("127.0.0.1", None, "POST", "/api/v1/uploads",
                          content_type="text/plain")
        self.assertFalse(v.ok)
        self.assertEqual(v.status, 415)
        self.assertEqual(v.code, fb.auth.NOT_JSON)

    def test_the_door_audits_it_like_every_other_mutation(self):
        self.assertTrue(fb.auth.audited("POST", "/api/v1/uploads"))


if __name__ == "__main__":
    unittest.main()
