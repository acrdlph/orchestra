"""orchestra.uploads — an image from the phone becomes a file on this Mac.

The phone cannot hand an agent a picture. What an agent CAN read is a path:
dragging a file into a `claude` session inserts its absolute path, and the CLI
reads the bytes off disk itself. So the upload route does exactly that and no
more — take the bytes, write one file, hand back the absolute path — and the
app pastes the path into the message it was already sending. Nothing here
knows about chat, dispatch or sessions; it writes a file and says where.

WHY BASE64 IN A JSON BODY, and not multipart. `auth.check`'s last guard
demands `Content-Type: application/json` on every mutation, because that is
what stops a page you are merely VISITING posting into your fleet through your
browser (a `multipart/form-data` POST is one of the three types a form can send
with no preflight — it is the CSRF hole in person). A raw-bytes or multipart
upload route would need an exemption from that guard, which is the one guard
that cannot have exemptions. Base64 costs 33 % on the wire between a phone and
a Mac on the same tailnet, and buys the upload the same door as everything
else.

THE FOUR RULES, and each is a hole somebody has fallen into before:

  1. THE TYPE COMES FROM THE BYTES. `sniff` reads magic bytes; the client's
     `name` never decides an extension, and a `Content-Type` on the part is not
     even collected. A client that says `.png` and sends a shell script gets a
     sentence naming what actually arrived.
  2. THE SERVER NAMES THE FILE. `sha256(bytes)[:16] + the sniffed extension` —
     no byte of client input reaches the filesystem, so there is no traversal
     to defend against rather than a filter to get right. It also makes a
     re-upload of the same image land on the same path and write nothing, which
     is what a phone retrying over a flaky tailnet needs.
  3. THE DESTINATION IS OUTSIDE EVERY WORKTREE. See `UPLOAD_ROOT`.
  4. THE SIZE IS CAPPED TWICE. Cheaply on the encoded length before anything is
     decoded, and again on the decoded length — `server.do_POST` refuses an
     over-long body from its `Content-Length` before it reads a byte, and this
     module refuses an over-long string before it materialises the bytes.

A leaf, like `idem`: it imports `config` and nothing else at module level, so
nothing it guards can import it into a cycle. `auth` is reached lazily inside
`_audit` for that reason (`disk.audit_event` does the same thing for the same
reason), and `disk` reaches THIS module lazily to prune what it writes.
"""

import base64
import hashlib
import os
import re
import secrets
import stat
import time
from pathlib import Path

from . import config

ROUTE = "/api/v1/uploads"       # `server.do_POST` spells this literally, twice,
                                # on purpose: the router and the body cap must
                                # say the same word, and a test reads the
                                # literals back out of the handler's source.

# WHERE THE FILES GO, AND WHY IT IS NOT NEGOTIABLE.
#
# `~/.orchestra/uploads/<YYYY-MM-DD>/` — under the user's HOME, never under
# `config.HERE` where the audit log, the device registry and the idempotency
# store live. `config.HERE` is the repo root, which is a git worktree, and
# `finish.start_finish(clean_scratch=True)` deletes untracked files in a
# worktree when a mission closes out. An upload living inside one would be
# handed to an agent as a path and then destroyed underneath it by a closeout
# — silently, minutes later, with the agent holding a path to nothing. That is
# the entire reason for this line. DO NOT "tidy" these into the repo.
#
# Rebound at runtime by the tests (a tmpdir), so every reader reaches it as
# `uploads.UPLOAD_ROOT` and no caller copies it into a local at import time.
UPLOAD_ROOT = config.HOME / ".orchestra" / "uploads"

# The cap on ONE image, decoded. 10 MB takes any iPhone screenshot (~400 KB),
# any HEIC photo (2–5 MB) and a 12 MP JPEG with room to spare; it is a config
# knob because a user photographing a whiteboard at 48 MP is a real thing and
# raising a number is better than a support conversation.
MAX_MB = 10.0                   # config key "upload_max_mb"

# How long an upload is kept. These files are ORCHESTRA'S OWN — it named them,
# it wrote them, and `disk.py` is allowed to reap them for exactly that reason,
# which is the same rule that forbids it touching a transcript. 30 days is long
# past the life of the conversation the path was pasted into.
RETAIN_DAYS = 30.0              # config key "upload_retain_days"; 0 = keep forever

# Slack for the JSON around the base64 — the braces, the two keys, and a `name`
# hint long enough to be somebody's camera roll filename. Deliberately generous:
# it is the difference between "your photo is too big" and "your photo is too
# big by eleven bytes of punctuation".
ENVELOPE_SLACK = 4096

# What we write, and the only shapes `disk._ours_upload` will ever unlink.
KINDS = {"png": ".png", "jpeg": ".jpg", "gif": ".gif", "webp": ".webp",
         "heic": ".heic", "heif": ".heif"}
NAME_RE = re.compile(r"^[0-9a-f]{16}\.(?:png|jpg|gif|webp|heic|heif)$")
DAY_RE = re.compile(r"^\d{4}-\d{2}-\d{2}$")
# The half-written form, which exists for the microseconds between the write
# and the `os.replace`. `_write_once` removes its own on any error it can see;
# this shape is here so that the one it CANNOT see — a kill -9 mid-write — is
# reaped by `disk.prune_uploads` a day later rather than living in that
# directory forever. Nothing else in the program would ever come back to it.
TEMP_RE = re.compile(
    r"^[0-9a-f]{16}\.(?:png|jpg|gif|webp|heic|heif)\.part-[0-9a-f]{8}$")

# HEIC is not one magic number. It is ISO base media format — the same
# container as MP4 — distinguished only by the brands in its `ftyp` box, so the
# brand table is what separates "an iPhone photo" from "a video somebody
# renamed". An iPhone still is `heic`; an edited or depth-effect one often
# declares `mif1` as its major brand and carries `heic` further down the
# compatible list, which is why every brand in the box is consulted and `heic`
# wins over `heif` when both appear. Anything else with an `ftyp` box — `isom`,
# `mp42`, `qt  `, `avif` — is NOT in this table and is refused by name.
HEIF_BRANDS = {
    b"heic": "heic", b"heix": "heic", b"heim": "heic", b"heis": "heic",
    b"hevc": "heic", b"hevx": "heic", b"hevm": "heic", b"hevs": "heic",
    b"mif1": "heif", b"mif2": "heif", b"msf1": "heif", b"miaf": "heif",
}

# Enough of the head to sniff every format above: the longest prefix that
# decides anything is the RIFF/WEBP pair at byte 12, and the ftyp box walk is
# separately bounded at `_FTYP_SCAN`.
HEAD_BYTES = 64
_FTYP_SCAN = 512                # never walk a compatible-brand list past this


def _num(key, default):
    """One config knob, as a float, never raising. A garbled value reads as the
    default rather than taking the route down — the same shape as
    `disk._thresholds`."""
    try:
        return float(config.CFG.get(key, default))
    except (TypeError, ValueError):
        return default


def max_bytes():
    """The cap on the DECODED image, in bytes."""
    return int(max(0.0, _num("upload_max_mb", MAX_MB)) * 1024 * 1024)


def max_body():
    """The cap on the whole POST body for this route, for `server.do_POST`.

    `server.MAX_BODY` is 256 KB for every other route and STAYS 256 KB — the
    global is what stops an unauthenticated peer buffering gigabytes into one
    `bytes` object, and raising it for everybody to carry an image would put
    every route on this server behind an image-sized cap. This route brings its
    own instead, resolved from the path before a byte is read, and the two
    never meet: `do_POST` consults one or the other, never the larger of them.

    The number is what `max_bytes()` costs once base64 has added its third
    (4 bytes out per 3 in, rounded up to the padding) plus `ENVELOPE_SLACK` for
    the JSON around it.
    """
    return _b64_len(max_bytes()) + ENVELOPE_SLACK


def _b64_len(n):
    """Encoded length of `n` raw bytes: 4 characters per 3, padded."""
    return (n + 2) // 3 * 4


def _raw_len(n):
    """The SMALLEST number of raw bytes `n` base64 characters can decode to.

    Used BEFORE decoding, so a 400 MB string is refused without materialising
    it — and it has to be the smallest rather than the largest, or an image
    sitting exactly ON the cap would be refused by the cheap check for the two
    padding characters its encoding happens to carry.
    """
    return max(0, n // 4 * 3 - 2)


def retain_s():
    """Seconds an upload is kept. <= 0 means "never reap", which is the only
    sane reading of `"upload_retain_days": 0` — the literal one deletes
    everything the moment it is written."""
    return max(0.0, _num("upload_retain_days", RETAIN_DAYS)) * 86400.0


# ------------------------------------------------------------------ sniffing

def sniff(data):
    """The format, from the bytes themselves, or None. NEVER from the client.

    Order is irrelevant here — no two of these prefixes can both match — but
    the ftyp walk is last because it is the only one that is not a memcmp.
    """
    if data.startswith(b"\x89PNG\r\n\x1a\n"):
        return "png"
    if data.startswith(b"\xff\xd8\xff"):
        return "jpeg"
    if data.startswith(b"GIF87a") or data.startswith(b"GIF89a"):
        return "gif"
    # A RIFF container whose form type is WEBP. `RIFF` alone is also WAV and
    # AVI, so the form type at byte 8 is the whole test.
    if data[:4] == b"RIFF" and data[8:12] == b"WEBP":
        return "webp"
    return _heif_kind(data)


def _heif_kind(data):
    """"heic", "heif", or None — read out of the `ftyp` box's brand list."""
    if len(data) < 12 or data[4:8] != b"ftyp":
        return None
    kinds = set()
    for brand in _brands(data):
        kind = HEIF_BRANDS.get(brand)
        if kind:
            kinds.add(kind)
    # `heic` outranks `heif` when both are declared: a photo whose major brand
    # is `mif1` but which lists `heic` as compatible IS a HEIC, and calling it
    # `.heif` would be a true statement that no tool expects.
    return "heic" if "heic" in kinds else ("heif" if kinds else None)


def _brands(data):
    """Major brand first, then every compatible brand in the `ftyp` box.

    The box length is the first four bytes, and it is a number the CLIENT
    controls — so the walk is bounded by the data we actually have AND by
    `_FTYP_SCAN`, and a lying length buys an attacker one short loop.
    """
    yield data[8:12]
    try:
        size = int.from_bytes(data[0:4], "big")
    except (TypeError, ValueError):     # not reachable from bytes; belt and braces
        return
    end = min(size, len(data), _FTYP_SCAN)
    off = 16
    while off + 4 <= end:
        yield data[off:off + 4]
        off += 4


# What a refusal calls the thing that arrived. Not an exhaustive file(1) — the
# job is to make ONE sentence useful enough that the person holding the phone
# knows what they picked, so the list is the things a photo picker or a share
# sheet actually hands out by mistake.
_SIGNATURES = (
    (b"PK\x03\x04", "a zip archive"),
    (b"PK\x05\x06", "an empty zip archive"),
    (b"\x1f\x8b", "a gzip stream"),
    (b"BZh", "a bzip2 archive"),
    (b"%PDF-", "a PDF"),
    (b"\x7fELF", "an ELF binary"),
    (b"\xcf\xfa\xed\xfe", "a Mach-O binary"),
    (b"\xca\xfe\xba\xbe", "a Mach-O universal binary"),
    (b"#!", "a script with a #! line"),
    (b"BM", "a BMP (not one of the five formats accepted here)"),
    (b"II*\x00", "a TIFF (not one of the five formats accepted here)"),
    (b"MM\x00*", "a TIFF (not one of the five formats accepted here)"),
    (b"<svg", "an SVG, which is markup rather than a picture"),
    (b"<?xml", "an XML document"),
    (b"<!DOC", "an HTML document"),
    (b"\x00\x00\x01\x00", "a Windows icon"),
    (b"OggS", "an Ogg stream"),
    (b"fLaC", "a FLAC stream"),
    (b"ID3", "an MP3"),
)


def describe(data):
    """What arrived, in words a refusal can put in a sentence.

    Never the bytes themselves and never more than 8 of them as hex: this
    string ends up in an HTTP response, and a response that echoes attacker
    content back is a response that has to be escaped by everyone who renders
    it. Hex of a prefix is inert everywhere.
    """
    if not data:
        return "nothing at all"
    if len(data) >= 12 and data[4:8] == b"ftyp":
        brand = "".join(chr(b) if 32 <= b < 127 else "?" for b in data[8:12])
        return (f"an ISO base-media file of brand '{brand.strip()}' — the MP4/MOV "
                f"family, not a still this server accepts")
    for magic, what in _SIGNATURES:
        if data.startswith(magic):
            return what
    try:
        text = data[:32].decode("utf-8")
    except UnicodeDecodeError:
        pass
    else:
        # PRINTABLE text, not merely decodable: a run of NUL bytes decodes as
        # UTF-8 perfectly happily, and calling that "text" would have sent
        # somebody looking for a text editor. `isprintable` is False for a
        # newline, so the three ordinary whitespace characters are allowed back.
        if text.strip() and all(c.isprintable() or c in "\r\n\t" for c in text):
            return "text"
    return f"{len(data)} bytes beginning {data[:8].hex()}"


# ------------------------------------------------------------------ the write

def _refuse(sentence):
    """The house envelope. `error` carries a SENTENCE here rather than a code,
    which is what the rest of the legacy surface does and what the app puts in
    front of the user unmodified — the person holding the phone is the only one
    who can fix "that was a video"."""
    return {"ok": False, "error": sentence}


def receive(payload, device=None, peer=None, now=None):
    """`{"data": "<base64>", "name": "<hint>"}` -> the file, and where it is.

    Returns the wire body either way: `{"ok": true, path, bytes, kind, name}`
    or `{"ok": false, "error": "<sentence>"}`. It never raises — a route that
    can throw on a phone's malformed body is a 500 the user reads as "the Mac
    is broken".

    `device` is the ID of the authenticated device and never its registry
    record — the record carries a token hash and a push endpoint, and the audit
    log is not the place for either. `peer` is the address it came from. Both
    end up on one line and nowhere else.

    `name` is an OPTIONAL HINT AND IS DISCARDED. It is accepted because a
    client naturally has one and sending it costs nothing, and it is thrown
    away because the only thing it could contribute is a filename, and a
    client-supplied filename reaching the filesystem is the oldest hole there
    is — this route writes to a real user's disk from a phone on a network.
    The bytes name themselves (rule 2 in the module docstring), so there is
    nothing here to sanitise: `../../etc/passwd`, a NUL, a separator and a
    leading dot are all equally uninvolved.
    """
    now = time.time() if now is None else now
    data = payload.get("data") if isinstance(payload, dict) else None
    if not isinstance(data, str) or not data.strip():
        return _refuse("send the image as base64 in a `data` field; this "
                       "request carried none.")
    cap = max_bytes()
    text = _strip_data_url(data)
    # THE CHEAP CHECK, before `b64decode` allocates anything. `server.do_POST`
    # has already refused an oversized `Content-Length`, but that guard is on
    # the wire and this one is on the value — a caller inside this process, a
    # test, or a future route reusing this function reaches here without ever
    # having had a Content-Length.
    if _raw_len(len(text)) > cap:
        return _refuse(f"that upload is about {_raw_len(len(text)) / 1048576:.1f} MB, "
                       f"over the {cap / 1048576:g} MB limit this server writes "
                       f"(upload_max_mb).")
    try:
        # `validate=True` on purpose: the lenient default DISCARDS characters
        # outside the alphabet, so a body with a NUL or a stray quote in it
        # would decode to something neither end asked for. A malformed string
        # is a refusal, not a best effort.
        raw = base64.b64decode(text, validate=True)
    except (ValueError, TypeError):
        return _refuse("the `data` field is not valid base64 — send the file's "
                       "bytes base64-encoded, with nothing else in the string.")
    if not raw:
        return _refuse("that upload decoded to zero bytes.")
    if len(raw) > cap:
        return _refuse(f"that image is {len(raw) / 1048576:.1f} MB, over the "
                       f"{cap / 1048576:g} MB limit this server writes "
                       f"(upload_max_mb).")
    kind = sniff(raw[:HEAD_BYTES])
    if kind is None:
        return _refuse(f"that is not an image this server writes to disk — it "
                       f"arrived as {describe(raw)}, and only PNG, JPEG, GIF, "
                       f"WebP and HEIC/HEIF are accepted.")
    # The name is the CONTENT, so the same image uploaded twice is the same
    # file: a phone whose upload timed out and retried does not leave two
    # copies, and the path it is handed the second time is the one it was
    # handed the first. 16 hex characters of sha256 is 64 bits — a collision
    # needs ~4 billion images in ONE day directory.
    name = hashlib.sha256(raw).hexdigest()[:16] + KINDS[kind]
    day = time.strftime("%Y-%m-%d", time.localtime(now))
    try:
        folder = _day_dir(day)
        dest = folder / name
        fresh = _write_once(dest, raw, now)
    except OSError as e:
        # The disk said no — full, read-only, a permission somebody changed.
        # Say which, because the user is the only one who can fix it.
        return _refuse(f"the upload could not be written to "
                       f"{UPLOAD_ROOT / day}: {e.strerror or e}.")
    # ONE LINE PER UPLOAD, and never the image. Bytes and kind are the two
    # facts an audit reader needs ("a 4 MB HEIC arrived from this device at
    # this time"); the pixels are the thing the tokens exist to protect, and
    # the client's `name` hint is user text of exactly the sort `auth.audit`
    # declines to keep.
    _audit(at=now, event="upload", peer=peer, device=device, kind=kind,
           bytes=len(raw), name=name, duplicate=not fresh)
    return {"ok": True, "path": str(dest), "bytes": len(raw), "kind": kind,
            "name": name}


def _strip_data_url(text):
    """`data:image/png;base64,AAAA` -> `AAAA`.

    A phone that hands us a canvas export or a pasted data URL is trying to do
    the right thing, and refusing it teaches nobody anything. The DECLARED
    media type is thrown away with the prefix — `sniff` still decides what this
    is, so a `data:image/png` header on a zip changes nothing.
    """
    text = "".join(text.split())        # whitespace, including a wrapped body
    if text.startswith("data:") and "," in text[:128]:
        return text.split(",", 1)[1]
    return text


def _day_dir(day):
    """`~/.orchestra/uploads/<YYYY-MM-DD>/`, 0700, created if missing.

    A day per directory so retention is a walk rather than a stat of every file
    ever uploaded, and so a human opening the folder can see what arrived when.

    0700 on both levels we create: this directory holds pictures the user sent
    from their phone — a whiteboard, a screenshot of an error, whatever was on
    the screen — and every other account on a shared Mac has no business
    listing it. `os.makedirs`' mode is masked by the umask, so the mode is set
    again afterwards; that also tightens a directory that predates this code.
    `~/.orchestra` itself is only CREATED at 0700, never re-chmodded: it is not
    ours alone (`apns_key_path` lives there in the shipped example config), and
    silently changing the mode of a directory another feature owns is how a
    "helpful" tightening becomes somebody else's bug report.
    """
    parent = Path(UPLOAD_ROOT)
    if not parent.parent.exists():
        os.makedirs(parent.parent, mode=0o700, exist_ok=True)
    folder = parent / day
    os.makedirs(folder, mode=0o700, exist_ok=True)
    for path in (parent, folder):
        try:
            os.chmod(path, 0o700)
        except OSError:
            pass            # a directory we cannot chmod is one the open below
                            # will fail on, with a better message than this
    return folder


def _write_once(dest, raw, now):
    """Write `raw` to `dest` unless it is already there. True if we wrote.

    Atomic by tmp + `os.replace`, so a reader — the agent, which may be handed
    this path within milliseconds — never sees a half-written image. `O_EXCL`
    so two concurrent uploads cannot share a temp file, and `O_NOFOLLOW` so a
    symlink planted at the temp name cannot redirect the write out of this
    directory.

    The duplicate case TOUCHES the file. Retention is by mtime, so re-uploading
    an image that landed 29 days ago must restart its clock — otherwise the
    path handed to an agent today is reaped tomorrow.
    """
    try:
        st = os.lstat(dest)
        if stat.S_ISREG(st.st_mode) and st.st_size == len(raw):
            os.utime(dest, (now, now))
            os.chmod(dest, 0o600)
            return False
    except OSError:
        pass
    tmp = dest.with_name(dest.name + ".part-" + secrets.token_hex(4))
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                 0o600)
    try:
        with os.fdopen(fd, "wb") as f:
            f.write(raw)
        os.chmod(tmp, 0o600)        # 0600 regardless of the umask in effect
        os.replace(tmp, dest)
    except OSError:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise
    return True


def _audit(**fields):
    """One line into the audit log. `auth` is imported HERE rather than at
    module level because `auth` -> `disk` -> (lazily) this module, and a
    module-level import back would close the ring. `disk.audit_event` defers
    for the same reason."""
    from . import auth
    auth.audit(**fields)
