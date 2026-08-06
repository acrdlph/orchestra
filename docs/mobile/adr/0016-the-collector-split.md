# ADR 0016 — one board, many collectors

**Status:** accepted; Phase 0 built 2026-08-06 against [`NODES.md`](../NODES.md).
Supersedes nothing; extends ADR 0006 (observation is
continuous) and ADR 0001 (transport is Tailscale).

## The ask

Run agents on a second, much more powerful machine, and still see one board. The board
itself must stay in **one** place — the home Mac, which is always on, always reachable, and
is "the centre of the system". And, further out: one board over *every* project, not the
one repo that happens to be in front of us today.

## The thing to be clear about first

Orchestra is not the expensive process. The observer costs ~5 % of a core; it reads
transcripts and git and composes cards. The compute worth moving is the **agents** —
`claude` in tmux, running builds and test suites. So this is not "distribute orchestra". It
is: *let agents run anywhere, and keep one honest board over them.*

That is a smaller problem, because orchestra is already a watcher of work happening
elsewhere rather than the thing doing the work.

## Decision

Split the process into two roles that already exist inside it, and let them be separated by
a network:

- **The board.** One, on the home Mac. Serves the API, the SSE stream, the web pages and
  the phone. Owns auth, audit, idempotency, the Host allowlist. Merges. Routes.
- **A collector.** One per machine, *including the home Mac*. Watches that machine's
  `roots` and Claude homes, composes cards, and actuates that machine's terminals.

**Today's single-machine setup becomes a board with one built-in local collector.** That is
the whole migration story, and it is why this is additive rather than a rewrite: the 1,384
tests keep testing the same code, reached the same way, with the network path absent.

### The collector dials OUT. The board never dials in.

This is the load-bearing decision.

The collector opens the connection to the board and keeps it: it POSTs its snapshots, and
holds a long-lived `GET` on which **commands come back down**. Orchestra already speaks
both ends of exactly this — it serves SSE (`server._stream`) and consumes it (the iOS
`EventStream`), so no new transport is invented.

Why this direction:

- **The work machine never listens.** No inbound port, no firewall exception, no
  `tailscale serve`, nothing reachable. It is a client. On a managed machine that is the
  difference between "a process that makes outbound connections" and "a service", and it is
  the honest answer to the security question this feature raises.
- The board stays the only listening surface, so the auth, rate limiting, audit and
  idempotency built for it keep applying to everything, unchanged.
- A collector behind NAT, a VPN, or a captive network just works.

### Identity: the bare worktree name stops being unique

`observer.py:1005` keys the board's cards by worktree name:

```python
cards = {c["name"]: c for c in state.get("worktrees", [])}
```

Two machines both holding a `ConfidAI2` collide, and `free_worktrees` (derived from those
names) collides with them. So:

- **A node id.** Generated once per collector and persisted; the hostname rides along as a
  *label* only, because hostnames change and are not unique.
- **Cards are keyed `<node>/<worktree>`**, and carry `node` as a field. `free_worktrees`
  becomes node-qualified.
- **Session ids need nothing.** They are UUIDs from Claude Code — already globally unique,
  which is why sessions merge for free.
- **Pids never cross a machine boundary.** They are node-local hints and stay that way.

This is a **breaking wire change** for `cards` keys, and it is the main compatibility cost.
Both clients are ours (the iOS app and `stream.js`), so it lands as one coordinated change —
but it must be done deliberately, not discovered.

### Actuation routes; refusals are relayed verbatim

`identity.resolve` re-resolves the address *at the instant it types* (ADR 0008), and that
guarantee is only meaningful on the machine holding the pid. So:

1. `POST /api/send` (or finish, dispatch, resume) reaches the board.
2. The board looks up the owning node from the card index.
3. It forwards over that node's command channel, carrying the **same idempotency key** end
   to end — `idem.py` already refuses a duplicate, and it must refuse it on the far side too,
   or a retry double-executes on a machine the client cannot see.
4. The collector runs the existing local path unchanged, and answers `{ok, message}`.
5. **The board relays `message` byte for byte.** These sentences are a wire contract: the
   iOS client keys `Actuation.outcome` on exact substrings such as
   `sitting in the composer, unsent`. The board may add *which node answered*; it may not
   rewrite what the node said.

A forwarded call needs its own deadline and an outcome distinct from a refusal — *"the node
did not answer"* is not *"the node said no"*, and the client's retry rules depend on telling
them apart (see `Actuation.mayOfferRetry`: only a clean refusal may be retried).

### What crosses the wire, and what does not

Transcript **content** does not. The corpus is ~5 GB per machine and growing ~1,000 files a
day. The collector composes locally — where kqueue, `st_dev`/`st_ino` and `mtime_ns` are real
and trustworthy — and ships only composed snapshots (~38 KB) and deltas (~7 KB).

Full-transcript reads are **forwarded on demand** to the owning node. This is cheap precisely
because `GET /api/v1/sessions/{sid}/messages` is already bounded and cursor-based (§9.11): one
bounded 512 KB window per page, never the whole file. The paging route built for the phone
turns out to be exactly the shape remote serving needs.

### A dark node must not look like a quiet one

When a collector stops reporting, its cards must **not** vanish. A disappearing card reads as
"all clear", which is the one lie this project refuses to tell. They go stale with a stated
age, exactly as `FRESHNESS.md` already treats a stale probe tier — *"node `work` last spoke
4m ago"* — and actuation against that node refuses with that sentence rather than timing out.

### The collector is not a dumb executor

The board→collector direction is the dangerous one (METHOD.md §7). Defence in depth: a
collector accepts commands only for worktrees under its own configured `roots`, and audits
every command it executes to its own local audit log. A compromised board cannot ask a
collector to type into something it was never watching.

## Why this also gives the multi-project board

`roots` is already a list (`config.py:32`), and the merged board is the union across nodes.
So "one board over all my projects" is a consequence of this change rather than a second
feature. What remains is presentation: grouping by node and by project, so a board covering
six repos on two machines stays legible. That is a UX problem, and a good one to have.

## Phasing

Each phase is useful alone and shippable alone.

| phase | what | risk |
|---|---|---|
| **0** | node identity, qualified card keys, one built-in local collector. No network at all. | the real refactor; entirely offline and testable |
| **1** | a collector process that dials out and ships snapshots; the board merges. **Read-only** across machines. | low, and this alone is the safest thing to put on a managed machine |
| **2** | the command channel: actuation routing, forwarded transcript reads, idempotency end to end | the interesting one |
| **3** | hardening: node-down semantics, collector allowlist + audit, reconnection/backoff, clock skew across nodes | |

Phase 0 is the one that must be right; everything after it is plumbing on top of a correct
identity model. Phase 1 is where the work machine becomes visible, and it is deliberately
read-only, because visibility carries none of the risk that actuation does.

## Alternatives rejected

| option | why not |
|---|---|
| **Two boards, one per machine** (works today, zero code) | genuinely useful as a stopgap and worth doing first to measure the need — but it is two fleets looked at separately, which is the thing the ask is trying to remove |
| **One board reading the other machine over a network mount** | config-only and very tempting. But `transcripts.py:126,132` key reads on `(path, st_dev, st_ino)` and treat a write as a miss unless `st_mtime_ns`, `st_dev` and `st_ino` all agree — exactly the fields SMB/NFS report unreliably. It would produce a board that is intermittently and silently wrong, which is worse than no board |
| **Board dials into each collector** | needs every machine to listen and be reachable, which is the opposite of what a managed work machine should be doing, and multiplies the exposed surface by the number of nodes |
| **Ship raw transcripts to the board and compose centrally** | 5 GB per node, growing daily, over a tailnet, to recompute what the node could compute locally for 5 % of a core |

## The open question that is not technical

Phase 2 puts agents running `--dangerously-skip-permissions` on a second machine, drivable
from a phone. On a personally-owned machine that is a choice. On an employer-managed one it
is also an EDR, device-management and acceptable-use question, and joining such a machine to
a personal tailnet is itself the kind of thing a security team notices. Phase 1 is read-only
by design so that the visibility can be had without settling that question first.
