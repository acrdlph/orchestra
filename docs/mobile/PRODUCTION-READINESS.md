# Production-readiness — what's built, and what's left

An honest ledger. "Built" means verified working on real hardware or by a test, not specced.
The app is genuinely useful today; this is the gap between *useful* and *something you'd trust
unattended for a year*.

## Built and proven

- **Backend:** continuous observer (~5% of a core), kqueue-driven, versioned immutable snapshots,
  SSE delta stream, per-device bearer auth, a tailnet bind that fails closed, the APNs pipeline
  (ES256 signature verified three ways, real HTTP/2 to Apple). 912 python tests + a 5,656-case
  characterization net.
- **App:** pairs over the tailnet (QR + token), live board via SSE deltas, acts (chat, dispatch,
  finish, resume), branch map, **real push received on a physical iPhone**, network-path awareness
  for weak links.
- **Auth to the server:** the app authenticates with a per-device token in the Keychain, revocable.

---

> **2026-08-04 — App Store push.** A night of hardening moved most of this list to done; each
> item below is marked. The app now archives, App-Store-signs and exports a validated `.ipa`
> (`ios/release.sh`), builds on an icon and asset catalog, and shows a self-contained demo fleet
> so App Review needs no Mac. What remains before Upload is two things only a person can do: the
> App Store Connect **Issuer ID** (the `.p8` key is already on the Mac) and creating the app
> record. See `docs/mobile/APPSTORE.md`.

## Tier 1 — Security & safety (do first; small, high-stakes)

The server types into terminals running `--dangerously-skip-permissions` and dispatches agents
that spend money. That raises the bar for everything that can reach it.

1. **Biometric gate on the app itself (Face ID / passcode).** **Built** (`App/BiometricGate.swift`,
   gating `RootView`, re-locks on `scenePhase`). One open policy call, flagged in
   `HANDOFF-tier1-security.md`: it fails **open** on a phone with no passcode set — deliberate, but
   the user should confirm they want that.
2. **A real security review of the exposed surface.** **Done** — a read-only adversarial review of
   the auth guard, the actuation layer (the tonight-modified osascript/tmux send and the
   `clean_scratch` deletion path), the disk-prune guards, and pairing/identity ran over the merged
   tree. Findings folded back the same night.
3. **Token scopes (`read` / `act` / `admin`).** *Not built — deliberately deferred* (`auth.py`
   reserves the design; a half-built scope ladder is worse than an honest absence). Today one
   token = full fleet control. A read-only device, or a fresh-biometric requirement for admin
   actions, is defense in depth.

## Tier 2 — Distribution & stability

4. **TestFlight.** **Ready to press.** `ios/release.sh` archives, App-Store-signs (Apple
   Distribution, store profile minted from Xcode's team session) and exports a validated `.ipa`
   with `aps-environment=production` — proven end to end tonight short of the upload itself. Upload
   needs the ASC Issuer ID and an app record (browser, one-time). The OTA-install path
   (`HANDOFF-remote-ota-install.md`) stays the "install while travelling" alternative.
5. **App icon + asset catalog.** **Built** — `App/Assets.xcassets` with the light/dark/tinted
   `AppIcon`, `AccentColor`, and a `LaunchBackground` the launch screen uses; rendered
   reproducibly by `ios/icon/render_icon.swift`. Looked at on the home screen.
6. **iOS CI.** **Built** — `.github/workflows/ios.yml` runs `swift test` + a simulator
   `xcodebuild` on macos-26, warnings-as-errors honoured, its own concurrency group.
7. **Bundle IBM Plex Mono.** **Done.** Four faces (Regular / Medium / SemiBold / Bold, ~680 KB)
   ship in `ios/App/Fonts/` with `OFL.txt`; `UI/Typography.swift` resolves them from
   `\.legibilityWeight`, so Bold Text moves the machine voice a weight instead of leaving it thin.
   No call site changed. `Font.custom` substitutes silently for a face that will not resolve, so
   the app checks all four with `UIFont(name:)` at launch — `assertionFailure` in DEBUG, and in
   Release the whole ramp (never a single glyph) falls back to the system monospaced design.
   Two marks moved because Plex has no glyph for them: `Δ` U+0394 → `∆` U+2206, `✕` U+2715 → the
   `xmark` SF Symbol. Verified by looking at the pairing screen, the live board and the server
   screen on an iPhone 17 Pro Max simulator, plus `FontBundleTests` on every `swift test`.

## Tier 3 — The phone superpowers (specced in UX.md, not built)

8. **Home Screen / Lock Screen widget** — "who needs me" at a glance without opening the app.
9. **Live Activity** — a running mission on the lock screen, updating live.
9b. **The full log.** **Built** — `GET /api/v1/sessions/{sid}/messages` (`sessionlog.py`,
    API.md §9.11) serves the transcript newline-intact, tool calls and results included, with a
    real `truncated` flag and byte-offset paging that never reads a 100 MB file whole; the phone
    renders it in `UI/TranscriptView.swift` with prose open, tool traffic folded, noise behind a
    toggle, and a `show all` that actually fetches. This is what `/api/chat`'s 900-character cut
    could never be, and it closes the "show full that fetches nothing" defect on the chat screen.
9c. **Composer draft persistence** (UX.md §3.5). **Built** — `Store/DraftStore.swift`, debounced
    and flushed on background, so the mission survives the biometric re-lock that tears the
    paired subtree down, and an app kill. It re-presents the sheet within 24 h.
10. **Notification polish** — snooze, quiet-hours UI, per-event-type preferences and thread-id
    grouping **shipped** (`Model/PushSettings.swift`, `/api/v1/push/mute`); a post-wake
    suppression now stops a lid-open buzzing the phone with the night's backlog
    (`notify.py`). Left: a server route to *read back* stored preferences, and the notification
    service extension (cosmetic now that the server stamps the reply category).

## Tier 4 — Backend loose ends (from the README open-items table)

11. **`resumes` don't ride the stream.** They live in `resume.py`, which the observer doesn't
    watch, so a stream-only client (the phone) learns about auto-resume changes via a side poll,
    not the delta stream. Fine today; name it before it surprises someone. *(The serial-fire
    hazard beside it — one slow tmux resume delaying every other due schedule — is closed:
    `resume_loop` now fires each due key on its own thread, exactly-once preserved by a claim set.)*
12. **Transcript-corpus retention.** ~~There's a backup job; there is no pruning.~~ **Half done,
    and the other half is not orchestra's to do.** *Corrected:* there is no backup job and no
    derived copy — `transcripts.py` is read-only end to end, so the ~1,000 files/day (4.9 GB
    across 7 homes here, oldest 193 days) are the **user's own** `~/.claude*/projects`. A
    program that watches your transcripts must not delete them, so what shipped is the report:
    `disk.py` says what the corpus costs at startup and every `disk_report_h`, and warns past
    `disk_warn_gb` / under `disk_free_gb` free — which is the number that predicts the incident
    (a full disk stops an agent writing its `.jsonl`; see `stale_alive_s`). Deleting from it
    stays a decision the user makes at their own shell. **Built:** rotation for the two logs
    orchestra *does* own (`audit.log.jsonl`, `dispatch.log.jsonl`), with a hard 7-day floor
    under any segment and an audit line per batch. **Left:** nothing, unless the user wants an
    opt-in corpus policy — which needs their explicit sign-off before any `rm`.
13. **The four UX back-ports (UX.md Appendix E).** **Done** — `--accent-2` → `#EDB9AC`, every
    tint fill to α 0.12, data off `--muted-2` onto `--muted`, and the ended row on a darker ground
    instead of `opacity: .55`, across all five web pages.

---

## Suggested order

Tier 1 is a few days and removes the scariest gaps — **start with the biometric gate.** Tier 2
makes it something you can keep on your phone without a cable. Tier 3 is where it starts feeling
like a product rather than a tool. Tier 4 is housekeeping that can trail the rest.

Nothing here blocks daily use over the tailnet with the phone in your own pocket — it is the list
that turns "works for me" into "safe to leave running."
