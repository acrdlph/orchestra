# Nodes — one board over many machines

**Status:** the working design for ADR 0016's Phase 0 (and the parts of Phase 1
that must be shaped now so Phase 0 does not have to be re-broken later). The ADR
holds the decision and the reasoning; this file holds the decisions the ADR
deliberately left open, written down *before* the code, so that the code can be
checked against it rather than the other way round.

The one-sentence version: **a card's identity is `<node>/<worktree>`; the wire
speaks qualified keys; actuation state stays node-local and bare; translation
happens at the server's door.**

---

## 1. The node id

A **node** is one machine being watched — more precisely, one *collector
installation*: the checkout + config that watches that machine's `roots`.

- **Format:** `^[a-z0-9][a-z0-9-]{0,31}$` — a lowercase hostname-label shape.
  No `/` (it is the key separator), no `|` (the resume/registry composite keys
  use a literal pipe), no uppercase (two ids differing only in case are a
  support ticket). A config value that fails this refuses at startup with a
  named error, exactly as a bad `pattern` regex does — a wrong identity
  discovered at 3am on a merged board is far worse than a refusal at boot.
- **Generation:** first use with no override and no persisted id generates
  `slug(short hostname)-XXXX` — the hostname sanitised into the format above
  (truncated to 24 chars), plus 4 random base-32 chars. The suffix exists
  because default hostnames collide (`mac`, `Mac.local`, a work laptop imaged
  from the same template); the hostname prefix exists because an id a human
  cannot recognise on a board is an id they will mis-act on.
- **Persistence:** `node.json` beside the package (`config.HERE`), the same
  place and the same atomic-write discipline as `devices.json`. Persisted
  because hostnames change and the id must not: rename the Mac and the board's
  history, drafts, and schedules still refer to the same node.
- **Override:** config key `"node"` (default `""` = use/create the persisted
  id). The override wins and nothing is written. Tests set it for hermeticity;
  users set it for taste (`"node": "work"`).
- **The label rides, the id keys.** The hostname is read live at compose time
  and travels as a display label (`nodes[id].label`); it is never part of the
  key. This is the ADR's "the hostname rides along as a label only".

## 2. The card key

- **`key = f"{node}/{name}"`** — `name` is the worktree directory's basename
  and cannot contain `/`; the node id cannot either (format above); so
  `key.split("/", 1)` is unambiguous in both directions.
- **One derivation rule everywhere.** Cards (and topology branches) carry
  `node` and `name` as separate fields; every client derives the key with one
  shared helper and never parses it back apart for display. Where a *single
  string* names a card on the wire — `free_worktrees`, `order`, the keys of a
  frame's `cards`, the keys of `resumes`, the `worktree` parameter of every
  acting route — that string is the qualified key.
- **What this does not fix, on purpose:** two roots on ONE machine each holding
  a `ConfidAI` still collide, exactly as today (`Snapshot`'s docstring calls a
  duplicate name "impossible" for the rest of the app; API.md §7.1's unbuilt
  `wid` sketch was shaped around this). Phase 0 changes the identity's *scope*
  from machine to fleet; it does not change its grain within a machine. Same
  known limitation, same standing.

## 3. What the wire carries (the breaking change)

`/api/state` and every SSE frame, coordinated with both clients in one phase:

- Every card gains `"node": "<id>"`.
- `free_worktrees` becomes a list of **qualified keys** (still derived by
  clients from cards; still never a second source of truth).
- `order` and frame `cards` keys become qualified keys; the delta ring stores
  qualified keys.
- A new top-level **`nodes`** map: `{"<id>": {"label": …, "hostname": …,
  "user": …}}`. It rides **whole on every frame** and is the **fourth bump
  term** of the composed view — a node can appear with zero cards (a collector
  watching empty roots), which must move the version with no card changing.
  `observer.delta_since`'s audit and its two pinning tests extend to it; that
  audit is precisely the discipline the handoff's "two individually-correct
  changes" trap demands.
- Top-level `hostname`/`user` keep their meaning: **the board host**, constant
  for the life of the process, still fetched on the side path. Per-node
  identity lives in `nodes`, and a top-level `node` names the board's own node
  id — the client's only honest way to tell local from remote (the ⌖ focus
  button on a loose process is actuation on the board machine, and a remote
  node's process must not offer it).
- `other_procs` entries gain `"node"`. Pids remain node-local hints and never
  form a cross-node identity (ADR 0016).
- `/api/topology` branch entries gain `"node"`; the map joins topology to state
  by qualified key. Same-repo worktrees from two machines will share a trunk
  group by origin URL — that is a feature, not an accident, and it is why the
  branch entry carries `node` rather than the group.
- Session objects are untouched: sids are UUIDs and already global.
- `resumes` keys become `"<node>/<worktree>|<sid>"`, and each schedule's
  `worktree` field on the wire is the qualified key.

**Freshness stays flat in Phase 0** (one node; identical semantics). Phase 1
puts per-node recency in the `freshness` map — keys `node:<id>`, the epoch the
board last heard that collector — because `freshness` is already the no-bump
path that rides every frame. It must NOT live in the `nodes` map: `nodes` is a
bump term, and recency that moved on every heartbeat would spin the version
forever. A node going quiet must *date* its cards, never vanish them and never
tick the version doing it.

## 4. What stays node-local and bare

Actuation is irreducibly local (ADR 0016), so the state that belongs to
actuation keeps bare names *inside* the node that owns it:

- `finish._closeouts` and its file; `resume._resumes` internals and the tmux
  session names it derives; dispatch's worktree reservations and job records;
  `terminal.py` / `identity.resolve` inputs; tmux targets, ttys, cwds.
- **The server door translates.** Every acting route (`/api/send`,
  `/api/finish`, `/api/dispatch`, `/api/resume/*`, `/api/focus`) accepts the
  qualified key in its existing `worktree`/`wt` parameter, splits it, verifies
  the node is one this board can act on (Phase 0/1: the local node only), and
  hands the bare name to the unchanged local path. A value with no `/` is
  treated as a bare name **on the local node** — the safe reading, since a bare
  name can never address a remote machine. An unknown node id is a refusal
  that names the node, not a timeout.
- This door is deliberately the exact seam Phase 2's routing needs: board looks
  up the owning node from the key, forwards over that node's channel, the
  collector runs the same local path unchanged.
- Migration, per persisted file: `resume.schedule.json` records written before
  this change hold bare names and their keys ride the wire — `load_resumes`
  qualifies them with the local node id, once, on load. `finish.closeouts.json`
  and `dispatch.jobs.json` stay bare — they never leave the node.
  `events.log.json` keeps its history untouched; an open condition re-derives
  once under its new dedupe key (§8).

## 5. The built-in local collector

`collect_state()` remains the per-node composer. What is new is the seam above
it:

- A **node registry** holds the latest snapshot per node id (Phase 0: exactly
  one, deposited by the sweep; Phase 1: remote collectors deposit via POST).
- A pure **merge**: `{node_id: node_state} → board_state` — qualifies keys,
  unions cards, re-sorts globally, sums `counts`, unions `free_worktrees`,
  tags and concatenates `other_procs`, builds `nodes`. It is a pure function
  with no I/O; the two-machines-one-name proof test drives it directly, and
  the single-machine case goes through it on every sweep — the multi-machine
  path with the network absent, which is the ADR's whole migration story.
- Global sort key: `(severity, name.lower(), node)` — byte-identical order to
  today on one node, deterministic interleaving on many.
- **The kqueue exit-watch set filters to the local node.** `Observer._live_pids`
  reads the *published* snapshot to arm `EVFILT_PROC`; once the snapshot can
  hold merged cards, an unfiltered read would arm exit watches on another
  machine's pids. The filter lands in Phase 0, when the seam is cut, not in
  Phase 1 when it would first misfire.

## 6. The invariant, pinned

Sibling of `test_pairing.py`'s *everything advertised must be answerable*, and
pinned for the same reason (it is a fact about the PAIR of things, so it lives
in a test, not in either module):

> **Every node a payload references is described by that payload.** Each card's
> `node`, every key in `free_worktrees`/`order`/frame `cards`, every
> `other_procs[].node` and `resumes` key appears in the same payload's `nodes`
> map — on `/api/state` and on BOTH branches of `delta_since`.

A card whose node the client cannot name is the node-shaped version of
advertising a Host you refuse to answer: two individually-correct changes away
from a board nobody can act on.

## 7. Display

The qualified key is identity, not typography: boards and the app show the bare
`name` (plus a node badge) — and the node badge appears only when more than one
node is on the board, so the single-machine board renders exactly as it does
today. Same rule on the web board, the map, and the phone.

One parser needs care rather than typography: the iOS debug deep-link grammar
(`DebugRoute`, `chat:<wt>/<account>/<sid>`) splits on `/`. With a qualified key
in the worktree position it splits **from the right** — account labels and sids
cannot contain `/`, the key's tail cannot either, so the last two segments are
account and sid and everything before them is the key.

## 8. Push and events

`notify.py`'s projection, dedupe keys and payload `worktree` fields follow the
card key (qualified). Consequence, accepted and stated: dedupe keys change
shape at the upgrade, so a condition that was already notified before the
upgrade may notify once more after it. One duplicate per open condition, once,
at a deliberate upgrade — not worth a migration shim.

## 9. What else keys on identity (asked, per the handoff)

Checked and unaffected: auth's Host allowlist (board-side only; collectors dial
out and present tokens, they answer to no Host), pairing (board-only), session
sids (UUIDs), the transcript/proc memos (`st_dev`/`st_ino`/pid+generation —
node-local by construction, and the reason network mounts are forbidden),
idempotency keys (per-request UUIDs; fingerprints change shape with the payload,
which only tightens them). Changed knowingly: push dedupe keys (§8), client
registries (`REG`/`SCHED`/`FIN_PENDING`/`dataset.wt` on the board, the applier
and per-worktree stores on the phone) — all follow the card key.

## 10. Account labels — the third axis, deferred on purpose

Account labels (`main`, `work`, …) are derived from each machine's Claude home
directories, which makes them the same class of node-local identity as worktree
names: two machines can both hold a home labelled `work`, and those may or may
not be the same Anthropic account. Phase 0/1 does not qualify them, because it
does not have to: the account↔limits join happens inside `collect_state`, which
runs per node, and `/api/limits` probes only the board machine's own homes. On
a merged board an account label is therefore a **per-node display label**, read
in the context of the card (and node) it sits on. Whether two nodes' `work`
labels are one account — which decides whether limit warnings should merge —
is a genuine identity question that gets its own decision when Phase 2's
routing makes it actionable, not a mechanical qualification now.

## 11. Phase 1 — the read-only collector, decided before built

The ADR fixes the direction (the collector dials OUT; the work machine never
listens); these are the working decisions under it.

**The run mode.** `python3 -m orchestra --collect-to http://<board>:<port>`
starts everything a watcher needs — config, node id, the Observer sweep with
its watcher and settler — and **no listener of any kind**: no `Server`, no
port, no pairing surface. The push pipeline does not run either; the BOARD
owns notifications, and a collector that pushed its own would notify twice.
The token rides in config (`"collect_token"`, an ordinary device token minted
on the board with `--add-device`; the file sits beside `devices.json` under
the same file-permission discipline). A dedicated collector credential and
allowlist are Phase 3 hardening, per the ADR's own phasing — a device token
already holds the power to type into agents, so snapshot ingest grants it
nothing new.

**What crosses the wire.** After every local publish, and on a heartbeat
(`"collect_heartbeat_s"`, default 15 s) even when nothing changed, the
collector POSTs its **node snapshot** — the settled, pre-merge
`collect_state` output its own Observer just published, never its merged
board — as `POST /api/v1/nodes/snapshot`:
`{"node": <id>, "label": <hostname>, "state": {…}, "seq": <local version>,
"sent_at": <epoch>}`. Bearer token, JSON content type (the CSRF guard
applies), its own body cap (`"node_snapshot_max_mb"`, default 1 MB — a
snapshot is ~38 KB on a nine-worktree fleet, and the global 256 KB cap would
silently strand a fifty-worktree machine). No idempotency key: latest-wins is
the route's whole semantics.

**The board's ingest.** Validates the id (format; and REFUSES the board's own
node id — a remote claiming the local identity is the one collision the key
cannot survive), stores `{node_id: {state, label, received_at, seq}}` in a
registry, nudges the observer (`git=False`), and the next sweep's
`board_state` merges local + registry through the same `merge_nodes` Phase 0
built. The registry **persists** (atomic write beside the other state files):
a board restart must reload last-known snapshots as *stale*, because the
alternative — remote cards vanishing until the next heartbeat — is the
disappeared-card-reads-all-clear lie, compressed into a window.

**Node-down.** A collector that stops reporting leaves its cards exactly as
they were, dated by `freshness["node:<id>"]`; boards and the phone render the
age ("node `work` last spoke 4m ago") once it passes ~3 heartbeats. Nothing
is deleted, nothing un-bumps, and a dark node's cards never read as free.
The collector's own send loop retries on a flat 5 s clock in Phase 1;
real backoff, reconnect discipline and clock-skew handling are Phase 3.

## 12. The documents

API.md §16.1 freezes the legacy surface byte-stable; ADR 0016 breaks that
freeze deliberately and this is the commit that does it. Every place API.md,
ENGINE.md, ARCHITECTURE.md, FRESHNESS.md or UX.md states the old identity
(bare-name keys, singular `hostname`/`user`, `delta_since`'s "constant for the
life of the process" premise) is corrected in the same commit as the wire —
the house rule. The unbuilt v1 sketch's `wid` (§7.1) gains a note that node
identity folds into whatever id the v1 surface eventually mints.
