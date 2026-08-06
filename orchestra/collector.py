"""orchestra.collector — the dial-out half of ADR 0016 Phase 1.

A collector is a machine watching itself: the same Observer sweep, the same
watcher, the same settled statuses — and instead of serving a board, it POSTs
its node snapshot to one. **This module never listens.** No socket is bound,
no port is opened, nothing on this machine is reachable — the collector is a
client, and on a managed work machine that is the difference between "a
process that makes outbound connections" and "a service" (the ADR's whole
security argument, and the property that must never be quietly traded away
for convenience).

What crosses the wire is the PRE-MERGE node snapshot the local Observer just
published (`Observer._local_snap` — settled by its own Settler, composed
where kqueue and inode identity are real), never a merged board: a collector
re-exporting other nodes' cards would make the board a rumour mill. ~38 KB on
a nine-worktree fleet, shipped on every version bump and on a heartbeat
(`collect_heartbeat_s`) even when nothing changed, because the board's
node-down honesty is only as good as its cadence of proof-of-life.

Failure is routine, not exceptional: the board may be asleep, the tailnet
may be flapping. Phase 1 retries on a flat clock and logs state CHANGES only
(reachable -> unreachable and back), so a laptop lid closing does not write
a thousand identical lines. Real backoff and clock-skew discipline are
Phase 3, by the ADR's own phasing.

Stdlib only, like everything here: `urllib.request` against the board's
`POST /api/v1/nodes/snapshot`, a Bearer token from config ("collect_token"),
`Content-Type: application/json` because the board's CSRF guard refuses
anything else.
"""

import json
import sys
import time
import urllib.error
import urllib.request

from . import config, node

SNAPSHOT_ROUTE = "/api/v1/nodes/snapshot"
RETRY_S = 5.0                  # flat, Phase 1; Phase 3 owns real backoff
TIMEOUT_S = 10.0               # one POST's deadline — a wedged board must not
                               # wedge the loop past a heartbeat


def payload(local_snap, seq):
    """The wire body, from one pre-merge node snapshot."""
    return {"node": node.node_id(), "label": node.label(),
            "state": local_snap, "seq": seq, "sent_at": time.time()}


def post_snapshot(board_url, token, body, opener=None):
    """One POST. Returns (ok, detail) and never raises — the loop's whole
    contract is that a dead board costs latency, not a crash."""
    url = board_url.rstrip("/") + SNAPSHOT_ROUTE
    req = urllib.request.Request(
        url, data=json.dumps(body).encode(),
        headers={"Content-Type": "application/json",
                 "Authorization": f"Bearer {token}"},
        method="POST")
    try:
        open_fn = opener or urllib.request.urlopen
        with open_fn(req, timeout=TIMEOUT_S) as resp:
            answer = json.loads(resp.read().decode() or "{}")
            if answer.get("ok"):
                return True, "ok"
            # The board ANSWERED and said no — a refusal, not an outage, and
            # the two must read differently in the log: a refusal will not
            # heal by retrying and names a config mistake (a bad node id, a
            # clashing identity), not a network one.
            return False, f"refused: {answer.get('error')} — {answer.get('message')}"
    except urllib.error.HTTPError as e:
        try:
            answer = json.loads(e.read().decode() or "{}")
            return False, (f"refused ({e.code}): {answer.get('error')} — "
                           f"{answer.get('message')}")
        except ValueError:
            return False, f"refused ({e.code})"
    except (urllib.error.URLError, OSError, ValueError) as e:
        return False, f"unreachable: {getattr(e, 'reason', e)}"


def run_collector(board_url, observer_instance, token=None, heartbeat_s=None,
                  stop=None, opener=None):
    """The loop: post on every version bump, and on the heartbeat regardless.

    `stop` is a threading.Event for tests and for shutdown; `opener` lets a
    test drive the whole loop against a fake board without a socket. The loop
    waits ON THE OBSERVER's publish condition (`wait_for`), so a busy fleet
    ships within milliseconds of a sweep and a quiet one costs exactly one
    POST per heartbeat.
    """
    hb = float(config.CFG.get("collect_heartbeat_s", 15.0)
               if heartbeat_s is None else heartbeat_s)
    token = token if token is not None else (config.CFG.get("collect_token") or "")
    cursor = 0
    was_up = None                  # tri-state: unknown / up / down
    while not (stop is not None and stop.is_set()):
        snap = observer_instance.wait_for(cursor, timeout=hb)
        if stop is not None and stop.is_set():
            return
        if snap is not None:
            cursor = snap.v
        local = observer_instance._local_snap
        if local is None:          # nothing collected yet — wait, don't spin
            time.sleep(min(1.0, hb))
            continue
        ok, detail = post_snapshot(board_url, token,
                                   payload(local, cursor), opener=opener)
        if ok != was_up:           # log EDGES, never every heartbeat
            print(f"orchestra collector: board {board_url} "
                  + ("reachable — posting" if ok else f"not accepting — {detail}"),
                  file=sys.stderr)
            was_up = ok
        if not ok:
            # a flat clock, deliberately (Phase 3 owns backoff) — but honour
            # `stop` while waiting so shutdown is prompt
            if stop is not None:
                if stop.wait(RETRY_S):
                    return
            else:
                time.sleep(RETRY_S)
