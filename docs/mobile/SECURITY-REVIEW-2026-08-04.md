# Security review — 2026-08-04

The Tier 1 #2 review of the exposed surface: the auth/request guard, the
actuation layer, the idempotency store, the disk-prune path, and pairing /
identity. Read-only adversarial pass over the tree as merged that night
(post the send-submit, closeout-persistence, clean_scratch, disk, and
server-smalls work), tracing untrusted input — network body, agent transcripts,
git porcelain, `tailscale` output — to every shell, AppleScript, filesystem
unlink and auth decision it can reach.

This is the artifact the review itself noted was missing. Each finding carries
its disposition; the commit that closed it is named where one exists.

## Critical

**C1 — stored XSS at the board's own origin, via `esc()`-only escaping inside
inline `onclick` handlers. FIXED — `17b2734`.** `esc()` maps `'` → `&#39;`, which
the HTML parser decodes back to `'` before an inline handler body is compiled,
so a value dropped in as `'${esc(x)}'` breaks out of the JS string. The
attacker-chosen inputs that reached those handlers — a device **label** from the
pairing body (`pairing.claim`, no charset filter), a worktree / account
directory basename, the `/api/dispatch` model echo — could inject script at the
board origin, which `auth` treats as loopback-**admin**: self-pair off the live
code, revoke devices, `/api/send` into agents on `--dangerously-skip-permissions`,
dispatch. Closed by converting every inline handler on `index.html`, `pair.html`
and `limits.html` to `escArg` (JSON.stringify then esc, emitting its own quotes),
porting `escArg` into the two pages that lacked it, a cross-page lint asserting
no `on<event>="…'${…"` survives, Node-driven breakout tests through the real
shipped helpers, and a boundary label filter in `pairing.py` (strips `< > \ \``
and control chars; keeps quotes and `&`, which real names carry and the render
layer handles).

## High

**H1 — side-effecting GETs are outside the cross-site guard.** The CSRF
content-type check runs only for non-GET; a tag-initiated cross-site GET
(`<img>`, `<script>`) sends no `Origin`, so `/api/focus` (osascript / attaches a
terminal to a fleet agent), `/api/events` (holds an SSE slot; 32 exhaust
`sse_max_subscribers`; unaudited) and `/api/limits?refresh=1` (spawns cclimits)
are reachable from any page the user visits. *Disposition: delegated to the
server-side batch — require a `Sec-Fetch-Site` same-origin signal (a forbidden
header JS cannot forge) on the acting GETs, plus audit coverage for
`/api/events`.*

## Medium

- **M2 — `_under_admin` decides on the raw path.** `…/devices/self/../<id>/revoke`
  classifies as self-service because the `SELF_SUBTREE` carve-out matches the
  un-normalized path first. Latent (do_POST exact-matches today), but one router
  edit from live — the `/api/v1/devicesX` incident's twin. *Delegated: refuse
  `..`, `//`, `%2f` before the subtree test, fail-safe to admin-required.*
- **M3 — idempotency store unbounded and un-namespaced.** `Idempotency-Key` taken
  verbatim (no length cap), `_records` uncapped, `_save()` rewrites the whole
  file per begin/complete, and records key on the header alone — so a device can
  squat another's key or replay its stored response with an identical body.
  *Delegated: cap key length, bound the store, namespace the fingerprint by
  device.*

## Low — dispositions

- **L2 — advertise only a validated MagicDNS name.** *Delegated: require
  `^[a-z0-9][a-z0-9.-]*\.ts\.net$` inside `tailnet.dns_name` before advertising.*
- **L3 — validate `sid` in resume.** The resume path globs `*/{sid}.jsonl` with
  no charset check, unlike `/api/chat`. *Delegated: same `[0-9a-fA-F-]+` guard.*
- **L4 — a bare CR was typed as an early Return. FIXED — `5d244a7`.** The send
  collapsed `\n` runs but not a lone `\r`, which reached the terminal as a
  submit and split one message into two. Now collapses any CR/LF run.
- **L7 — strip CR/LF from curl `--config` values in `push.py`.** Safe today; a
  standing guard so a future `\n` in an interpolated value cannot become an
  arbitrary curl directive. *Delegated.*
- **L1 — `clean_scratch` writes one audit line per removed file (unbounded).**
  Accepted: evidence is not buried (`tail_lines` reads across segments) and the
  7-day floor bounds nothing here — volume only, behind an authenticated device.
- **L5 — `MAX_TRACKED_PEERS` fails closed into a lockout** past 4096 actively
  failing peers. Accepted: needs 4096 distinct sources behind WireGuard; the
  board is immune (loopback-no-header sits above the budget).
- **L6 — a device can forge its own push telemetry / store ~256 KB of JSON in
  its own settings.** Accepted as cosmetic + minor self-DoS; the device can only
  affect its own registry row.
- **L8 — `s.limit.worst` / `data-until` / `data-since` interpolated raw** — all
  from local cclimits / transcript parsing, not the network. Watch if a source
  ever becomes remote.

## Confirmed safe (traced, not assumed)

The obvious places for a critical, and why they hold:

- **Constant-time token compare.** `hmac.compare_digest` on `token_sha256`, and
  the sha256 is computed even for an unknown device id — no device-id oracle,
  unknown and wrong-secret share one path. `parse_bearer` rejects non-ASCII and
  validates the id's length/alphabet.
- **The guard seam is unskippable** — `parse_request` runs before any `do_*`,
  including `/api/events`' early return and methods that don't exist.
- **Router and guard share one predicate** (`auth.admin`, not `startswith`), so
  `/api/v1/devicesX/<id>/revoke` cannot drift open — proven by a test that the
  victim device is still unrevoked after the probe.
- **Host allowlist kills DNS rebinding** (measured: `Host: evil.com` → 403),
  ordered after `same_origin` so only the agreeing-on-a-foreign-name case
  reaches it.
- **CSRF guard holds on every mutation** — `text/plain` → 415, a JSON POST
  forces a preflight answered 415 with no CORS header, so the browser never
  sends it.
- **Loopback trust is not a bypass** — a loopback request with a bad token is
  refused, not laundered to anonymous.
- **`_osa_escape` is sound** (empirically: an escape-attempt payload came back a
  literal string, created no file; a raw newline/CR stays inside the AppleScript
  literal). The unescaped `tty` is never client-supplied — it comes from `ps`,
  and the client's `tty` is only a corroborator compared against it. tmux
  session/socket names are `shlex.quote`d before `_osa_escape`.
- **No shell anywhere** — no `shell=True`, `os.system`, `eval`, `exec`,
  `pickle`; every subprocess is an argv list. `tmux send-keys -l --` /
  `set-buffer --` end option parsing.
- **`clean_scratch`** — `git clean` never invoked, `-x` never passed; only `??`
  entries are candidates and one non-`??` refuses the whole clean; `-z` splits on
  NUL so a newline in a filename cannot forge an entry; containment is checked on
  the resolved parent and the leaf symlink is removed as a link, never followed;
  `git_root` comes from `discover_worktrees`, never the wire; every removal is
  audited.
- **`disk` cannot reach `~/.claude*`** — `_ours` requires our parent + base +
  stamp shape, `_user_data` refuses any `.claude` component on the resolved
  path, and even bypassed, `os.unlink` removes the link not the target;
  `prune_logs` is the only unlink site and the 7-day floor is not a config key.
- **`idem`** — fingerprint is `sha256(canonical_json(payload)+method+route)`, so
  key reuse with a different body is 422; the reservation persists before the
  side effect; `BOOT_ID` distinguishes a restart (never re-executed) from a
  concurrent duplicate; first completion wins.
- **Pairing / push** — peer range checked before the code; single-use, 120 s,
  per-IP and aggregate caps; code never logged or echoed. `Creds.host()` is a
  fixed-default dict lookup (device `environment` can't reach the URL);
  `APNsSink.send` re-validates the device token against `TOKEN_RE` before writing
  the curl config. `qr.svg` emits only integer path data from a boolean matrix —
  `innerHTML = data.svg` reaches no attacker text.

## Second-pass wants

1. A mechanical lint over all five pages: every `${}` inside an `innerHTML`
   template must go through `esc`/`escArg`/`encodeURIComponent` or be
   `Number()`-coerced. (C1's regression test is the start of this.)
2. `notify.py` / `push.py` proper — only the two subprocess paths were traced.
3. A theoretical TOCTOU in `_clean_scratch` (`realpath` then `os.remove` re-resolves);
   `os.unlink(base, dir_fd=…)` would close it. Attacker already has write access
   to that worktree, so rated theoretical.
4. `observer.py` / `transcripts.py` — out of scope, and where agent-authored text
   is first parsed into the fields C1 exploited.
