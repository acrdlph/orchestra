# Phase 2 — the command channel. Written up, deliberately not built.

**2026-08-06.** Phases 0 and 1 of ADR 0016 are built, gated and committed: one
board watches many machines, read-only. This memo is the third thing the brief
asked for — what Phase 2 *would* involve, so the decision to build it can be
made by the person whose decision it is. Nothing below is started.

## What Phase 2 is

Today every button that types at an agent — send, finish, dispatch, resume,
focus — works only for the board's own node: the door (`node.local_name`)
refuses a foreign node's card by name. Phase 2 makes those buttons work for
remote cards: the board routes the command to the owning collector, the
collector runs the same local actuation path it always had, and the answer
comes back. Concretely, with the pieces already in place:

1. **The channel.** The collector adds a long-lived `GET` to its dial-out —
   the board pushes commands down it, the collector answers on a second POST.
   Orchestra already speaks both ends of this transport (it serves SSE and
   the iOS client consumes it); the work machine still listens on nothing.
   The board gains a per-node command queue behind that GET.
2. **Routing at the door.** `node.local_name`'s refusal branch becomes the
   routing branch: look up the owning node from the card key, enqueue,
   await. The seam was cut in Phase 0 precisely so this is a branch, not a
   rewrite.
3. **Idempotency end to end.** The client's `Idempotency-Key` travels with
   the forwarded command; the collector's own `idem` store refuses the
   duplicate on the far side too — otherwise a retry double-executes on a
   machine the client cannot see (ADR 0016's own requirement).
4. **Answers relayed byte for byte.** The refusal sentences are a wire
   contract (`Actuation.outcome` keys on exact substrings — "sitting in the
   composer, unsent"). The board may add *which node answered*; it may not
   rewrite what the node said.
5. **Two failure shapes, kept distinct.** *"The node said no"* (a clean
   refusal, may offer retry) is not *"the node did not answer"* (a deadline,
   must not auto-retry — the command may have landed). A forwarded call needs
   its own deadline and its own error code; the client's retry rules depend
   on telling them apart.
6. **Forwarded transcript reads.** `GET /api/v1/sessions/{sid}/messages` is
   already bounded and cursor-based (one 512 KB window per page) — the board
   forwards the page request to the owning node over the same channel. This
   is the cheap half.
7. **Collector-side defence (from the ADR).** A collector accepts commands
   only for worktrees under its own configured `roots`, and audits every
   command it executes to its own local log. A compromised board cannot type
   into something the collector was never watching.

One open sub-question found while building Phase 1, recorded so it is not
rediscovered: `/api/v1/uploads` answers with an absolute path **on the board's
disk** — a picture pasted to a *remote* agent needs the bytes forwarded to the
owning node first, or the path is unreadable where the agent runs.

Sizing, honestly: the transport exists at both ends, idempotency exists at
both ends, identity resolution exists on the node. Phase 2 is mostly plumbing
plus the discipline around the two failure shapes — comparable in effort to
Phase 1, smaller than Phase 0. Phase 3's hardening (a dedicated collector
credential and allowlist, real backoff, clock skew) should land with or
before it; actuation raises the stakes on all three.

## The question that is not a technical one

Phase 2 puts agents running `--dangerously-skip-permissions` on the second
machine, drivable from a phone. On a personally-owned machine that is a
choice. On an employer-managed machine it is an endpoint-security,
device-management and acceptable-use question — and joining such a machine to
a personal tailnet is itself the kind of thing a security team notices.
Phase 1 was kept read-only precisely so the visibility could be had without
settling this.

Before a go/no-go, the questions that decide it:

- **Whose machine is the second machine?** If employer-managed: is Claude
  Code sanctioned on it, is `--dangerously-skip-permissions` within
  acceptable use, and is membership in a personal tailnet compatible with
  its device management?
- **Who would be accountable** for a keystroke typed into that machine from
  a phone at 3am — and is the collector's local audit log (Phase 3) enough
  for them?
- **Is remote *reading* enough for now?** Phase 1 already shows the work
  machine's agents on the board and the phone; the marginal value of Phase 2
  is acting without walking over. That trade is yours to price.

If the answer is go: Phase 3's credential hardening first, then the channel,
gated exactly like Phases 0 and 1 — every rule a test, every new test watched
red, the wire driven for real before it is believed.
