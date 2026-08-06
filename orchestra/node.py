"""orchestra.node — which machine this collector is, and the card key.

ADR 0016: one board watches many machines, so a bare worktree name stops being
an identity — two machines each holding a `ConfidAI2` collide the moment their
cards land on one board. Every card is therefore keyed `<node>/<worktree>`,
and this module owns both halves of that: the **node id** (who this machine
is) and the **key algebra** (join, split, and the door translation the acting
routes use). docs/mobile/NODES.md is the design; this file is its code.

The id is *stable* and *human-meaningful*, and deliberately not the hostname:
hostnames collide (two default-named laptops) and change (a rename must not
orphan every schedule and draft that names this node). So it is generated once
— `slug(short hostname)-XXXX`, recognisable to a human, made unique by the
suffix — and persisted in `node.json` beside the package, the same place and
the same atomic-write discipline as `devices.json`. The hostname itself rides
the wire as a display label only, read live at compose time.

A config key `"node"` overrides everything and writes nothing; tests set it
for hermeticity, users set it for taste. An override that fails the format
check raises at first use rather than composing a board around a key that
cannot round-trip — `/` is the key separator and `|` is the composite-key
separator (`resume.py`'s `worktree|sid`), so neither may appear in an id, and
lowercase-only keeps two ids from differing only in case.

Nothing here mutates anything but its own `node.json`, and only when no
override and no file exist. Leaf module: imports `config` and nothing else in
the package, so anything may import it.
"""

import json
import os
import re
import secrets
import socket

from . import config

NODE_FILE = config.HERE / "node.json"      # tests rebind this, like auth.REGISTRY

# A lowercase hostname-label shape. The cap is 32 so a key stays readable on a
# board; the charset is the one that survives every composite it rides in —
# `<node>/<name>` (no slash), `<key>|<sid>` (no pipe), a DOM data- attribute, a
# tmux session name, a URL query value.
NODE_RE = re.compile(r"^[a-z0-9][a-z0-9-]{0,31}$")

# The generated-id resolution, cached for the life of the process: an id that
# changed mid-process would strand every key already published. The config
# override is deliberately NOT cached — it is one dict read, and the tests
# swap it per-case.
_cached = {"id": None}


def valid(node_id):
    """Whether `node_id` may key cards. A str matching NODE_RE, nothing else."""
    return isinstance(node_id, str) and bool(NODE_RE.match(node_id))


def _slug(hostname):
    """The hostname, reduced to the id charset: lowercase, runs of anything
    else collapsed to one `-`, trimmed, capped at 24 so the suffix still fits.
    An empty result (a hostname of dots, say) falls back to "node"."""
    s = re.sub(r"[^a-z0-9]+", "-", (hostname or "").split(".")[0].lower())
    s = s.strip("-")[:24].rstrip("-")
    return s or "node"


def _generate():
    """`slug(short hostname)-XXXX`. The suffix is what makes two identically
    named machines mint different ids without ever talking to each other; the
    prefix is what lets a human tell whose card they are looking at."""
    suffix = "".join(secrets.choice("abcdefghijklmnopqrstuvwxyz234567")
                     for _ in range(4))
    return f"{_slug(socket.gethostname())}-{suffix}"


def _reset():
    """Tests only: drop the process-lifetime cache."""
    _cached["id"] = None


def node_id():
    """This collector's id: config override > node.json > generate-and-persist.

    The override is validated on every read and a bad one RAISES — a board
    composed around an id that cannot round-trip through `<node>/<name>` is
    wrong everywhere at once, and the earliest loud failure is the cheapest.
    `__main__` turns this into a friendly refusal at boot.
    """
    cfg = (config.CFG.get("node") or "").strip()
    if cfg:
        if not valid(cfg):
            raise ValueError(
                f"config key \"node\" is {cfg!r} — a node id must match "
                f"{NODE_RE.pattern} (lowercase letters, digits and '-'; "
                f"it keys cards as '<node>/<worktree>')")
        return cfg
    if _cached["id"]:
        return _cached["id"]
    try:
        raw = json.loads(NODE_FILE.read_text())
        nid = raw.get("id") if isinstance(raw, dict) else None
    except (OSError, ValueError):
        nid = None
    if not valid(nid):
        nid = _generate()
        tmp = NODE_FILE.with_suffix(".json.tmp")
        # 0600 + rename, the devices.json discipline: never a torn file.
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w") as f:
            f.write(json.dumps({"version": 1, "id": nid}, indent=1))
        os.replace(tmp, NODE_FILE)
    _cached["id"] = nid
    return nid


def label():
    """The human name for this machine, read live — a rename shows up on the
    next compose. A LABEL only; never part of a key."""
    return socket.gethostname().split(".")[0]


def key(name, nid=None):
    """The card key: `<node>/<worktree>`. `name` is a directory basename and
    cannot contain `/`; `nid` cannot either (NODE_RE), so the join is
    unambiguous in both directions."""
    return f"{node_id() if nid is None else nid}/{name}"


def card_key(card):
    """The key for one composed card. STRICT: a card without a `node` field is
    a card the merge never saw, and keying it quietly by bare name would
    resurrect exactly the collision ADR 0016 exists to end."""
    return f"{card['node']}/{card['name']}"


def split_key(k):
    """`<node>/<name>` -> (node, name); a bare name -> (None, name).

    The bare form is legal on purpose: it is the pre-split wire, and every
    acting route reads it as "on the local node" — the safe reading, since a
    bare name can never address a remote machine.
    """
    if "/" in (k or ""):
        nid, name = k.split("/", 1)
        return nid, name
    return None, k


def local_name(worktree):
    """The door translation (NODES.md §4): a route's `worktree` parameter in,
    the node-local bare name out — or a refusal naming the node it cannot act
    on. Falsy in, falsy out, so routes keep their existing empty-input
    behaviour ("no worktree named …") unchanged.

    Returns `(name, None)` or `(None, refusal_dict)`.
    """
    if not worktree:
        return worktree, None
    nid, name = split_key(worktree)
    if nid is None or nid == node_id():
        return name, None
    return None, {"ok": False, "error": "unknown_node",
                  "message": f"no node '{nid}' on this board — this server is "
                             f"node '{node_id()}' and can only act locally"}
