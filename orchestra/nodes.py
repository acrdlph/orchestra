"""orchestra.nodes — the board's memory of every collector that ever spoke.

Phase 1 of ADR 0016 (docs/mobile/NODES.md §11): remote collectors dial out
and POST their node snapshots; this registry is where those snapshots land,
and `observer.board_state` merges them with the local collector's on every
sweep. The registry never forgets a node on its own — the ADR's one hard
rule about absence is that **a dark node must not look like a quiet one**:
a collector that stops reporting leaves its cards exactly as they were,
dated by `freshness["node:<id>"]`, because a disappeared card reads as
"all clear" and that is the one lie this board refuses to tell.

It PERSISTS (`nodes.cache.json`, the devices.json discipline: atomic tmp +
rename, 0600) for the same reason: a board restart that forgot its remote
nodes would make their cards vanish until the next heartbeat — the same lie,
compressed into a window. Reloaded snapshots come back exactly as stale as
they are, their `received_at` untouched.

Everything here is a dict under one lock; the merge itself lives in
`observer.merge_nodes`, which validates ids a second time. The route
(`server._nodes_snapshot`) is the door where a bad id or the board's own id
is refused — this module double-checks both, because by Phase 1 deposits
arrive from the network and a registry that trusts its caller is a registry
one bug away from keying two machines' cards together.
"""

import json
import os
import threading

from . import config, node

CACHE = config.HERE / "nodes.cache.json"    # tests rebind, like auth.REGISTRY

_lock = threading.Lock()
_reg = {}            # node_id -> {"label", "state", "seq", "sent_at", "received_at"}
_loaded = False


def _load():
    """Fill the registry from disk, once. Missing or corrupt -> stay empty
    (a fresh board), and never retry — the flag is set first so a corrupt
    file cannot re-parse on every sweep."""
    global _loaded
    if _loaded:
        return
    _loaded = True
    try:
        raw = json.loads(CACHE.read_text())
        entries = raw.get("nodes") if isinstance(raw, dict) else None
    except (OSError, ValueError):
        return
    if not isinstance(entries, dict):
        return
    for nid, e in entries.items():
        if node.valid(nid) and isinstance(e, dict) and isinstance(e.get("state"), dict):
            _reg[nid] = e


def _save():
    """Caller holds `_lock`. Atomic, 0600 — a torn write here loses every
    remote node's last-known board at once."""
    blob = json.dumps({"version": 1, "nodes": _reg})
    tmp = CACHE.with_suffix(".json.tmp")
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        f.write(blob)
    os.replace(tmp, CACHE)


def deposit(nid, state, label=None, seq=None, sent_at=None, received_at=None):
    """One snapshot in. Returns a refusal dict or None.

    Refuses an id that cannot key cards, and the board's OWN id — a remote
    claiming the local identity is the one collision the qualified key
    cannot survive (two sources both writing `<local>/<name>`)."""
    if not node.valid(nid):
        return {"ok": False, "error": "node_invalid",
                "message": f"node id {nid!r} cannot key cards"}
    if nid == node.node_id():
        return {"ok": False, "error": "node_is_self",
                "message": f"'{nid}' is this board's own node id — a remote "
                           "collector must carry its own identity"}
    if not isinstance(state, dict) or not isinstance(state.get("worktrees", []), list):
        return {"ok": False, "error": "state_invalid",
                "message": "state must be a collect_state-shaped object"}
    with _lock:
        _load()
        _reg[nid] = {"label": label or nid, "state": state, "seq": seq,
                     "sent_at": sent_at, "received_at": received_at}
        _save()
    return None


def remote_states():
    """`{node_id: node_snapshot}` for the merge. A copy of the mapping (the
    snapshots themselves are shared read-only — the merge never mutates)."""
    with _lock:
        _load()
        return {nid: e["state"] for nid, e in _reg.items()}


def ages():
    """`{node_id: received_at}` — what `freshness["node:<id>"]` is stamped
    from. Absent for a node never heard from, which cannot happen for a node
    with cards on the board (deposit is the only way in)."""
    with _lock:
        _load()
        return {nid: e.get("received_at") for nid, e in _reg.items()
                if e.get("received_at")}


def _reset():
    """Tests only."""
    global _loaded
    with _lock:
        _reg.clear()
        _loaded = False
