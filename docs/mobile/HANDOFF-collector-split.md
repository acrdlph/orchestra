# Handoff — the collector split (ADR 0016), phases 0 → 3

**Give this file to a fresh session.** It is written to be the only thing that session needs
in order to start; everything else it must read is named below with a path.

---

## What you are building

One board that shows agents running on **more than one machine**. Today orchestra watches the
machine it runs on. The owner has a second, much more powerful computer and wants its agents on
the same board.

**Read `docs/mobile/adr/0016-the-collector-split.md` first, completely.** It is the design and it
is already decided — you are implementing it, not re-opening it. This handoff adds the working
instructions the ADR deliberately leaves out.

The one framing to keep in mind, because it prevents a whole class of wrong turn: **orchestra
itself is not the expensive thing.** The observer runs at about 5 % of a core. The expensive work
is the `claude` agents doing builds and test runs. You are not distributing orchestra; you are
letting orchestra *watch and drive agents that live on another machine*.

---

## The repo, in one screen

- **Python, stdlib only. No pip dependencies, ever.** There is a mechanical test that enforces
  this (`tests/test_zero_deps.py`) — it AST-walks every module against a named allowlist. If you
  find yourself wanting a library, you have taken a wrong turn.
- Tests are `unittest`: `python3 -m unittest discover -s tests`. **1,438 passing** as of this
  handoff. They must stay green at every commit, not just at the end.
- The iOS app is in `ios/` (`cd ios && swift test`, **290 passing**; plus `xcodebuild`). Swift 6
  strict concurrency and warnings-as-errors are on.
- CI runs both and is **green** — `.github/workflows/ci.yml` (Python, Linux, 3.11–3.14) and
  `ios.yml`. It was red for months before being fixed; do not let it go red again. Note the
  Python suite runs on **Linux** in CI and macOS locally: two tests once passed on one and failed
  on the other for platform reasons (inode reuse, and a golden that recorded the machine's own
  user name). If you add a test that touches inodes, filesystem identity, hostnames or users,
  assume the two platforms differ until you have proved they do not.
- Commit style: lowercase prefixes (`fix:` `harden:` `api:` `ios:` `docs:` `test:` `chore:`), a
  one-line what-and-why subject, a body explaining the mechanism. Merges as `merge: <thing>`.
- Every commit ends with:

  ```
  Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
  Claude-Session: <this session's URL>
  ```

### The house method (from `docs/mobile/METHOD.md` — read it)

- **The wire is the truth, not the document.** Where a doc and the running server disagree, the
  server wins and the doc gets corrected in the same commit. `ios/README.md` and `docs/mobile/API.md`
  both carry tables of "where the documents were wrong" — that is the culture, keep it.
- **A phase ends with the thing run and LOOKED at.** Not "it compiles". For the server that means
  curl against a real running instance and pasted output; for the app, screenshots you have
  actually viewed.
- **A rule with no test drifts back.** Put decisions in pure functions with tests, not in
  conditions buried in a loop or a view.
- **Watch every new test fail first.** A test that has never been red is a test that may be
  asserting nothing. Several real defects here were caught exactly this way.

---

## The phases

From ADR 0016. Each is useful and shippable alone. **Do them in order and commit at each gate** —
do not carry four phases of uncommitted work.

### Phase 0 — identity. The one that must be right.

Entirely offline: no networking, no second machine, no new process. This is the refactor that
makes everything after it possible.

- A **node identity** for the machine a server runs on: stable, human-meaningful, not the
  hostname alone (hostnames collide and change). Decide it, write it down, and make it
  configurable.
- **Cards stop being keyed by bare worktree name.** `observer.py` builds `{c["name"]: c}`, which
  collides the moment two machines each have a `ConfidAI2`; `free_worktrees` collides the same
  way. Cards become `<node>/<worktree>`. Find **every** place that assumes a bare name is a key —
  the observer, the delta ring, `stream.js`, `index.html`, `map.html`, and the iOS
  `FleetApplier`/`FleetStore`/routes.
- **Sessions need nothing.** They are UUIDs and already globally unique. Pids stay node-local and
  must never be treated as global.
- One built-in local collector, so the single-machine case goes through the same path the
  multi-machine case will.

**Gate:** all 1,438 Python and 290 Swift tests green; the board, map and phone behave exactly as
before on one machine; the qualified key proven by a test that puts two same-named worktrees from
two nodes on one board.

**This is a breaking wire change** and both clients are ours, so it lands coordinated: server,
web board and iOS app in the same phase.

### Phase 1 — a read-only collector

- A collector process that **dials out** to the board and holds the connection, POSTing snapshots
  and receiving nothing that acts. The remote machine **never listens on a port** — that is the
  security property that makes this acceptable at all, and it must not be quietly traded away for
  convenience.
- The board merges snapshots from N collectors into one board.
- Node-down semantics from the ADR: a collector that stops reporting leaves its cards **stale with
  a stated age**, never vanishing. A disappeared card reads as "all clear", which is the one lie
  this project refuses to tell.

**Gate:** two servers on one machine (different roots, different node ids) merged onto one board,
driven for real and screenshotted; then, if the owner has set it up, a genuine second machine.

### Phase 2 — the command channel

Actuation routing, forwarded transcript reads, idempotency end to end. **Do not start this without
the owner's explicit go-ahead** — see "the question that is not yours to answer" below.

### Phase 3 — hardening

Node-down semantics, collector allowlist and audit, reconnection and backoff, clock skew across
nodes.

---

## The question that is not yours to answer

Phase 2 puts agents running with permissions deliberately skipped on a second machine, drivable
from a phone. If that machine is employer-managed, it is an endpoint-security, device-management
and acceptable-use question — and joining such a machine to a personal tailnet is itself the kind
of thing a security team notices.

**Phase 1 is read-only precisely so the visibility can be had without settling that.** Build 0 and
1. Stop at the Phase 2 boundary, write up what it would involve, and ask. Do not decide it for
them.

---

## Traps, paid for already

- **Do not network-mount the other machine's files into `roots`.** It is a one-line config change
  and it is wrong: `transcripts.py` keys reads on `(path, st_dev, st_ino)` and treats a write as a
  miss unless `st_mtime_ns`, `st_dev` and `st_ino` all agree — exactly the fields SMB and NFS
  report unreliably. You would get a board that is intermittently and silently wrong, which is the
  failure this project exists to prevent.
- **A remote browser cannot reach the board.** See commit `86cb447`: `index.html` never sends an
  `Authorization` header, and the token is refused as a query parameter and as a cookie. Do not
  "fix" this by loosening auth.
- **Actuation is irreducibly local.** `terminal.py` drives `tmux send-keys` and AppleScript, and
  `identity.resolve` re-resolves a live pid *at the instant it types*. None of that survives a
  machine boundary — which is why the collector owns actuation for its own machine and the board
  only routes.
- **Two individually-correct changes can be jointly fatal.** This happened twice in one night: a
  Host allowlist (correct) plus advertising a MagicDNS name (correct) made pairing impossible,
  because the server advertised a name it then refused to answer to. When you add an identity
  concept, ask what *else* keys on identity. The invariant that fixed it — *everything advertised
  must be answerable* — is pinned in `tests/test_pairing.py`; add its sibling for nodes.
- **Never `git checkout <file>` to undo a mutation test** while you have uncommitted work in that
  file. It silently reverts your fix along with the mutation. Commit first, then mutate.
- **If you build the iOS app: build from your own worktree with an explicit `-derivedDataPath`,
  and confirm your code is in `Orchestra.app/Orchestra.debug.dylib`** (`nm` / `strings`) before
  believing anything about behaviour. The main executable is only a launcher stub. This has cost
  three agents hours.
- **Disk is tight** (~24 GB free of 460 GB, and the transcript corpus is ~5 GB and growing). Clean
  up build directories and simulators you create.

---

## Running it

There is a live server on `127.0.0.1:4242`, bound to the tailnet, started with
`python3 -m orchestra --tailnet`. Real transcripts are under `~/.claude*/projects/`; the largest
is ~103 MB, so **never read one whole** — `docs/mobile/TRANSCRIPT-FORMAT.md` explains the tail-read
discipline. Use a spare port for your own instances and stop them when done.

Useful reading, in order: ADR 0016 · `docs/mobile/ARCHITECTURE.md` · `docs/mobile/ENGINE.md` ·
`orchestra/observer.py` · `orchestra/server.py` · `docs/mobile/API.md` §2–3 · the ADRs 0001, 0005,
0006, 0012, 0013, 0014, 0015.

## Suggested opening move

Read ADR 0016 and `observer.py`, then produce a written inventory of **every place a bare worktree
name is used as an identity** across Python, `stream.js`, the two HTML boards and the Swift client
— before changing any of them. That inventory is Phase 0's real specification, and it is the thing
most likely to be incomplete if you start editing first.
