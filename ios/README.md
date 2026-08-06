# orchestra for iOS — phases 1–5

A native SwiftUI client for the orchestra board.

* **Phase 1** got a token onto the phone and drew the Fleet list from a real
  server.
* **Phase 2** made the board **live**: one `GET /api/events` socket, deltas
  applied by a port of `stream.js`'s applier, ages animated locally off absolute
  timestamps, a connection state that is honest about staleness, a lifecycle that
  drops the stream on background and resyncs on foreground, and the read-only
  screens the IA calls for — worktree detail, session chat, limits, account
  detail, server.
* **Phase 3** made it **act**: reply to an agent (`/api/send`), launch a mission
  (`/api/dispatch`), the two-step closeout (`/api/finish`), and arm / disarm /
  manually fire an auto-resume (`/api/resume/*`). Every refusal is the server's
  own sentence, verbatim. Proven end to end on 2026-07-22: a message typed in the
  simulator reached a real agent on the Mac, the agent replied, and the app's
  transcript carried `✓✓ sent from this phone` on that exact turn.

* **Phase 4** turned push on: the app asks for authorization, registers its APNs
  token against the paired device (and re-registers when it rotates or the
  timezone moves), renders a preferences screen that writes the server's own
  preference store, deep-links a tap to the exact session it is about, and — the
  one that matters — answers an agent from the banner's inline reply, addressed by
  `sid` alone. Proven on 2026-07-23 against a real server and a booted simulator:
  registration reached the server (a token on file, `sandbox`, tz and app
  version); a `session.needs_answer` payload deep-linked to that session's
  conversation; and an inline reply reached `/api/send` and typed into the live
  agent (`{"ok": true, "message": "typed into Terminal (ttys010)"}`). See
  "Phase 4 — push" below for what only an APNs key, and only a physical device,
  can add.

* **Phase 5** gave the app a fleet of its own. orchestra is a client for a server
  the user runs on their own Mac, so opened with nothing paired it is a pairing
  screen and nothing else — and *"reviewer opened it, saw a screen it could not
  get past, rejected it"* is the standard way a companion app fails App Store
  guideline 2.1. `explore the demo fleet`, one tap from the first screen and in
  front of the Face ID gate, runs the whole product on six invented worktrees:
  the board, worktree detail, a real conversation, the branch map, usage limits,
  notification preferences. No server, no socket, no network, nothing written.
  Every mutation refuses in the server's own voice and every control stays
  visible while it does. See "Phase 5 — the demo fleet" below.

* **Phase 6** made the transcript **complete**. `/api/chat` is forty turns with
  every newline collapsed to a space, each one cut at 900 characters, no tool
  traffic at all, and a truncation the client could only infer from a trailing
  `…`. Beside it now sits `GET /api/v1/sessions/{sid}/messages` — the whole
  file, paged by byte offset, newlines intact, tool calls and results first
  class, machine text marked rather than dropped, `truncated` a real field and
  `chars` the true length. The phone half is a pushed reading screen that
  resolves completeness against readability the way a log viewer does:
  everything is present, structure decides what is open. See "Phase 6 — the full
  transcript" below.

* **Phase 7** let the phone hand an agent a **picture**. A screenshot picked in
  either composer is uploaded to the Mac and its absolute path is dropped into
  the message — which is what dragging a file into a `claude` session does, and
  the only thing an agent can actually read. The path is plain text in the draft
  and nothing else: the thumbnail strip is parsed back out of it, so deleting the
  path deletes the attachment, and the persistence that already existed carries it
  through a re-lock. A screenshot is sent **byte for byte**; a HEIC is transcoded
  because the far end cannot read one. Proven on 2026-08-06: a 1320×2868
  screenshot of this app's own board reached `~/.orchestra/uploads/` on a real
  Mac, and `cmp` says the file there IS the file that left. See "Phase 7 — a
  screenshot from the phone lands on the Mac" below.

## Build and run it — the only way this is verified

Everything below runs from a shell. No Xcode GUI, no Apple ID, no team.

```sh
# 1. the headless suites — models, transport classification, rules, formatters
cd ios && swift test                    # 336 tests, ~1 s, macOS, no simulator

# 2. the app
xcodebuild -project ios/Orchestra.xcodeproj -scheme Orchestra \
           -configuration Debug \
           -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' \
           -derivedDataPath /tmp/orc-dd build

# 3. put it on a simulator
xcrun simctl boot "iPhone 17 Pro Max"
xcrun simctl install booted /tmp/orc-dd/Build/Products/Debug-iphonesimulator/Orchestra.app

# 4. pair it against a real server, then LOOK at what it drew
python3 -m orchestra --port 4269 --tailnet          # in the engine checkout
curl -s -X POST -H 'Content-Type: application/json' -d '{}' \
     http://127.0.0.1:4269/api/v1/devices/pair/open | python3 -c 'import json,sys;print(json.load(sys.stdin)["url"])'
SIMCTL_CHILD_ORC_PAIR_URL='orc://p?h=…&p=4269&c=…' \
     xcrun simctl launch booted sh.orchestra.app
xcrun simctl io booted screenshot /tmp/board.png

# 5. every OTHER screen, without a finger
SIMCTL_CHILD_ORC_SCREEN=server                     xcrun simctl launch booted sh.orchestra.app
SIMCTL_CHILD_ORC_SCREEN=limits                     xcrun simctl launch booted sh.orchestra.app
SIMCTL_CHILD_ORC_SCREEN=limits:default             xcrun simctl launch booted sh.orchestra.app
SIMCTL_CHILD_ORC_SCREEN=wt:ConfidAI2               xcrun simctl launch booted sh.orchestra.app
SIMCTL_CHILD_ORC_SCREEN=chat:ConfidAI2/account2/<sid>  xcrun simctl launch booted sh.orchestra.app

# 6. drive it: cause a real change and watch the board move
touch ~/.claude-account2/projects/*/<sid>.jsonl     # → delta on the wire in ~1 s

# 7. phase 3 — every sheet, and a real send, without a finger
SIMCTL_CHILD_ORC_SCREEN=mission                     xcrun simctl launch booted sh.orchestra.app
SIMCTL_CHILD_ORC_SCREEN=mission:model               xcrun simctl launch booted sh.orchestra.app
SIMCTL_CHILD_ORC_SCREEN=mission:effort \
SIMCTL_CHILD_ORC_MISSION='a long mission…'          xcrun simctl launch booted sh.orchestra.app
SIMCTL_CHILD_ORC_SCREEN=finish:ConfidAi7            xcrun simctl launch booted sh.orchestra.app
SIMCTL_CHILD_ORC_SCREEN=resume:ConfidAi7/<sid>      xcrun simctl launch booted sh.orchestra.app
SIMCTL_CHILD_ORC_SCREEN=chat:ConfidAi7/account4/<sid> \
SIMCTL_CHILD_ORC_SEND='reply with exactly the words: the phone reached you' \
     xcrun simctl launch booted sh.orchestra.app
SIMCTL_CHILD_ORC_SCREEN=chat:ConfidAi7/account4/<sid> \
SIMCTL_CHILD_ORC_CHAT='half a reply, already typed'  xcrun simctl launch booted sh.orchestra.app
SIMCTL_CHILD_ORC_SCREEN=mission \
SIMCTL_CHILD_ORC_DISPATCH=running                    xcrun simctl launch booted sh.orchestra.app
#   ORC_CHAT     seeds THIS session's chat draft, once, at launch
#   ORC_DISPATCH renders the Launching screen: launching|running|finished|failed|refused|lost

# 8. phase 5 — the demo fleet, with no server anywhere
SIMCTL_CHILD_ORC_SCREEN=demo                       xcrun simctl launch booted sh.orchestra.app
SIMCTL_CHILD_ORC_SCREEN=demo:wt:search-index       …
SIMCTL_CHILD_ORC_SCREEN=demo:chat:search-index/main/9c1f4a2e-7b30-4c58-9a11-2d6e83f0b415  …
SIMCTL_CHILD_ORC_SCREEN=demo:limits                …
SIMCTL_CHILD_ORC_SCREEN=demo:map                   …
SIMCTL_CHILD_ORC_SCREEN=demo:mission               …
SIMCTL_CHILD_ORC_SCREEN=demo:finish:checkout-flow  …

# 9. phase 6 — the full transcript, and the taps a simulator has no finger for
SIMCTL_CHILD_ORC_SCREEN=transcript:ConfidAI/account6/<sid>  xcrun simctl launch booted sh.orchestra.app
SIMCTL_CHILD_ORC_SCREEN=demo:transcript:search-index/personal/9c1f4a2e-7b30-4c58-9a11-2d6e83f0b415 \
SIMCTL_CHILD_ORC_TRANSCRIPT=top,tools,all,noise,fail \
     xcrun simctl launch booted sh.orchestra.app
#   top   — every `load older`, to `— start of transcript —`
#   tools — every folded tool block, opened
#   all   — every `show all`, taken (a real /messages/at/ fetch each)
#   noise — the toolbar's `show system noise`
#   fail  — park on the first tool result the tool reported an error for
#   climb — SCROLL UP one viewport at a time (`climb:40` for forty steps) and
#           let the screen's own trigger fetch. Reports one line per step on
#           stdout; read it with `xcrun simctl launch --console-pty`:
#
#   ORC-CLIMB step=25 above=3313 content=13242 container=725 entries=158 \
#     visible=151 oldest=96920877 newest=103833827 cursor=96920877 more=true \
#     armed=true onscreen=12 anchor=97123793/0
#
#           `top` proves the CURSOR WALK and says nothing about the screen —
#           it never moves the scroll view. `climb` is the one that can see
#           whether a thumb could have reached any of what the walk fetched.
#           See "The defect a phone found: a loader that spun forever".
SIMCTL_CHILD_ORC_SCREEN=demo:resume:release-notes/a0539f74-2b6e-4d81-93cf-1e7a48d5c6b2  …

# 10. phase 7 — a screenshot from the phone lands on the Mac
SIMCTL_CHILD_ORC_SCREEN=chat:ConfidAI/account3/<sid> \
SIMCTL_CHILD_ORC_UPLOAD=/tmp/shot.png    xcrun simctl launch booted sh.orchestra.app
SIMCTL_CHILD_ORC_SCREEN=mission \
SIMCTL_CHILD_ORC_UPLOAD=/tmp/shot.png    …   # the same control, other composer
SIMCTL_CHILD_ORC_UPLOAD=picker           …   # the source dialog, not taken
SIMCTL_CHILD_ORC_UPLOAD=photos           …   # the system photo sheet
SIMCTL_CHILD_ORC_SCREEN=demo:chat:search-index/personal/9c1f4a2e-7b30-4c58-9a11-2d6e83f0b415 \
SIMCTL_CHILD_ORC_UPLOAD=/tmp/shot.png    …   # demo refuses, in the server's voice
#   A PATH reads that file and hands it to the SAME `UploadStore.attach` and the
#   same draft insert the picker's callback uses — the transcode, the size
#   precheck, the POST, the thumbnail strip and the write into the draft are all
#   the shipping code. `picker` and `photos` press the two presentations a tap
#   opens and a script otherwise cannot reach at all.

SIMCTL_CHILD_ORC_NO_PUSH=1               …   # suppress the notifications ASK
#   Not a feature seam — a way to SEE the app. The first paired launch puts
#   SpringBoard's "orchestra Would Like to Send You Notifications" over the
#   middle third of the screen, which is where the mission composer's attachment
#   strip lives, and there is no `ORC_SCREEN` that reaches a system alert:
#   `simctl` cannot tap and an accessibility click answers -25204 (re-measured
#   2026-08-06). It suppresses the ASK and nothing else — registration, the
#   router and the preferences screen are untouched.
```

**Face ID, without a face.** A paired build sits behind `BiometricGate`, and on a
fresh simulator with nothing enrolled that is a passcode sheet nothing can
answer. Two commands get past it, and the second is the only interaction in this
whole file that a *menu* can do and `simctl` cannot:

```sh
xcrun simctl spawn booted notifyutil -s com.apple.BiometricKit.enrollmentChanged 1
xcrun simctl spawn booted notifyutil -p com.apple.BiometricKit.enrollmentChanged
osascript -e 'tell application "Simulator" to activate' \
  -e 'tell application "System Events" to tell process "Simulator" to click menu item "Matching Face" of menu 1 of menu item "Face ID" of menu 1 of menu bar item "Features" of menu bar 1'
```

`demo` is both a route and a **prefix**: `ORC_SCREEN=demo` lands on the demo
board, and `demo:<anything>` enters the demo and then lands exactly where the
bare route would. It exists because the screenshot job's whole subject — the
screen the store images and the review notes are about — otherwise needs a
finger.

`ORC_SEND` is the third `#if DEBUG` seam and the sharpest one: it takes text
through exactly `ChatStore.send` — the same call the arrow button makes — because
the gate for phase 3 is *something actually arrived at a real agent* and a
simulator cannot be typed into from a script. It is a way to press the button,
not a second way to send. `ORC_SCREEN=finish:` and `resume:` are the same idea
for sheets, which `xcrun simctl` has no other way to reach at all.

`ORC_SCREEN` is the second `#if DEBUG` seam and it exists for the same reason as
the first: **a phase ends with the app run and LOOKED at**, and `xcrun simctl`
can install, launch and screenshot but cannot tap. An accessibility-driven click
is not a way out either — System Events answers `-25204` without a permission
grant a headless run does not have. So every screen gets one scriptable way in,
pushing exactly the `FleetRoute` values a tap pushes, through exactly the same
`navigationDestination`.

`ORC_PAIR_URL` is a **`#if DEBUG` test seam**, and it exists because a simulator
has no camera and cannot be typed into from a script — `xcrun simctl openurl`
does reach the app, but iOS puts a system *"Open in orchestra?"* dialog in front
of it that needs a finger. It takes the same `PairingTicket` through the same
`PairingStore.pair` as the camera and the typed form. It is a way to press the
button, not a second way to pair.

## Shape

```
ios/
├── Package.swift              swift test over Sources/Orchestra minus UI
├── Orchestra.xcodeproj/       one app target, file-system-synchronised groups
├── Orchestra-Info.plist       ATS, camera, photo library, URL scheme
├── Orchestra.entitlements     keychain access — see "the second-launch bug"
├── App/                       composition + the two views that need UIKit
│   └── Fonts/                 IBM Plex Mono ×4 + OFL.txt — see below
└── Sources/Orchestra/
    ├── Model/    Wire · Enums · StreamFrame · Chat · Transcript · Limits
    │             Pairing · Upload
    ├── API/      OrchestraClient (actor) · EventStream · SSE · Endpoint
    │             TranscriptSource · OrchestraError · Keychain
    ├── Rules/    Triage · TranscriptRules · UploadRules
    ├── Media/    ImagePrep — sniff, downscale, transcode. ImageIO and
    │             CoreGraphics only, so `swift test` runs the real thing on
    │             macOS; NOT under UI, because the numbers are a rule
    ├── Format/   RelativeTime · TextRules
    ├── Demo/     DemoClock · DemoFleet · DemoLimits · DemoChat
    │             DemoTranscript · DemoTopology · DemoPayload · DemoCopy
    │             (NOT under UI — it is data and rules, so `swift test`
    │             decodes all of it)
    ├── Store/    FleetStore · FleetApplier · ChatStore · TranscriptStore
    │             LimitsStore · PairingStore · DraftStore · UploadStore
    │                                            (@MainActor @Observable)
    └── UI/       Palette · Typography · StatusStyle · ConnectionBar
                  FleetView · WorktreeDetailView · ChatView · TranscriptView
                  LimitsView · ServerView · ImageAttach · rows
```

**IBM Plex Mono is bundled now** — the brand face of the desktop board, not SF
Mono approximating it. **Four `.ttf`s and no more.** `UI/Typography.swift`
resolves the mono half of the ramp from `\.legibilityWeight`, so Regular and
SemiBold carry normal legibility and Medium and Bold carry the system Bold Text
setting — which `Font.custom(_:size:relativeTo:)` does not honour on its own, and
without which the machine voice would stay thin while the human voice went bold.
That mapping is the only reason four faces ship instead of two; no italic, and
none of Plex's other six weights, because each unused face is ~170 KB of download
nothing renders. Every token still passes `relativeTo:` with the default point
size of the text style it already used, so Dynamic Type is unchanged and so is
the size at every step. **`App/Fonts/` needs no `.pbxproj` edit** — `App/` is a
file-system-synchronised group, the copy phase flattens the folder, `UIAppFonts`
therefore lists bare basenames, and `OFL.txt` ships beside the faces because the
SIL Open Font License requires the licence to travel with the font.

**Two silent-failure modes are guarded rather than hoped about** (`UX.md` §9.4).
`Font.custom` with a name nothing resolves does not throw and does not draw tofu
— it substitutes, invisibly. So: the PostScript names are read off the shipped
files and two of the four are *abbreviated* (`IBMPlexMono-Medm`,
`IBMPlexMono-SmBld`, and Regular is bare `IBMPlexMono`), and `OrcFont.plexIsAvailable`
resolves all four through `UIFont(name:)` at launch — `assertionFailure` in
DEBUG, and in Release the **whole** ramp falls back to the system monospaced
design, never per glyph. And Plex Mono has no Greek block at all, so §9.4's claim
that `Δ` U+0394 is "covered" is simply wrong: the dirty badge now draws `∆`
U+2206 (same shape, actually present) and the close button an SF Symbol instead
of `✕` U+2715. `FontBundleTests` re-checks the filenames, the PostScript names
and the glyph coverage of every mark drawn in mono on every `swift test`.

**The receive path, end to end.** `OrchestraClient.openEvents` opens the socket
and hands `Data` chunks to `SSELineSplitter` → `SSEDecoder` → `StreamFrame` →
`FleetApplier` → `FleetStore` → the views. Everything that can be wrong in a way
no amount of tapping would reveal — the line splitter, the SSE state machine, the
delta rules, the staleness rule — is a value type with no I/O and no clock, and
is covered by the 29 tests phase 2 added.

**`FleetApplier` is a PORT of `stream.js`'s `Fleet`, not a second
interpretation.** That file is the browser's applier, it is tested against the
Python reference (`tests/test_stream_js.py`), and it is what the desktop board
runs today. Two appliers that disagree about one rule produce two boards that
disagree about the fleet, and the disagreement is invisible until it matters. So
every rule in `FleetApplier` names the lines of `stream.js` it comes from.

**One module, not IOS-APP.md §1.2's six.** The layering there is enforced by the
SwiftPM graph — `OrchestraCore` structurally cannot see `OrchestraStore` — and
that is the right shape. It is deliberately not bought yet: two build systems
over one source tree cannot both be right about `import` statements, and a
hand-written `.pbxproj` that references a local SwiftPM package is the most
fragile thing that could live in this directory. Directories carry the layering
for now and no file crosses one; splitting them into real targets is additive.

Swift 6 language mode, `SWIFT_STRICT_CONCURRENCY = complete`, and
`SWIFT_TREAT_WARNINGS_AS_ERRORS = YES` on both configurations. There is exactly
one `@unchecked Sendable` in the app (`SessionBox` in `QRScannerView.swift`) and
it exposes two methods AVFoundation documents as callable off the main queue.

## What the running server actually serves — where the documents are wrong

Modelled from a live nine-worktree fleet on 2026-07-22 (`GET /api/state`,
38,615 B; `GET /api/events` snapshot frame), not from `API.md`. Reported here
rather than fixed, per the house rules.

### The wire

| # | claim | what the server does |
|---|---|---|
| 1 | IOS-APP.md §3.3 — `background_shell` | the key is **`bg_shell`** (`transcripts.py:953`), and it is present ONLY when true, as is `tool_running` |
| 2 | IOS-APP.md §3.3 — `turnEnded: Bool` | **`turn_ended` is absent from the payload entirely on some sessions** (3 of 36 live). A non-optional `Bool` throws `keyNotFound` and takes the whole 38 KB board with it. This is the single sharpest edge on the wire |
| 3 | IOS-APP.md §3.3 lists `closeoutSentAt` and `cardRev` on `Worktree` | neither string appears anywhere in the server. There is no `card_rev` staleness token |
| 4 | IOS-APP.md §3.3 does not model `pending_bg_tools` | it is on every session and it feeds `busySignal` |
| 5 | task brief: SSE frame is `{type, v, base, at, order, cards, counts, other_procs, freshness}` | `base` is on the **delta** branch only; a snapshot has no `base` |
| 6 | task brief / API.md: `/api/state` is the board snapshot | `/api/state` and the SSE frame are **different shapes**. `/api/state` has `worktrees` (a list), `hostname`, `user`, `free_worktrees`, `resumes`, `generated_at` — and **no `v`, no `order`, no `freshness`**. The frame has `cards` (a dict), `order`, `v`, `freshness` — and none of the four `/api/state`-only terms. `delta_since`'s docstring is the authority and justifies each omission |
| 7 | UX.md §3.1.2 — five-valued `availability` | the server ships the legacy **four** (`free`/`attention`/`waiting`/`busy`). UX.md says so itself: *"a required change to API.md §10.2, not a description of it."* Not landed. `Rules/Triage.swift` derives the split client-side, against principle 3, and says so |
| 8 | UX.md §3.1.3 — `counts: {sessions: {...}, cards: {...}}` | `observer.py:245` writes six flat session-level keys and nothing else. The card tallies the headline needs are derived in `Triage.cardCounts` |
| 9 | UX.md §3.1.4 — the wire carries `activity_at` | it carries **`last_write_at`** (IOS-APP.md §0's alias table has this; UX.md does not) |
| 10 | UX.md §3.1.4 — `topic`/`last_user`/`last_assistant` may live only on a detail route | the live board carries all four prose fields, which is UX.md's own resolution (a). The row is built against that |
| 11 | IOS-APP.md §1.5 — "the server serves HTTPS on the tailnet… no blanket exception is needed" | superseded by ADR 0013: **plain HTTP, no TLS**, `"tls": false` in the pairing response. §1.5's whole ATS paragraph, its `NSExceptionMinimumTLSVersion` and its SPKI pinning are stale |
| 12 | `git.ahead`/`git.behind` | **null, not zero**, when a branch has no upstream — `# branch.ab` is absent from porcelain v2 rather than `+0 -0`. 2 of 9 live worktrees. `↑0` would be a measurement this client never made |
| 13 | `git.commit` | nullable |
| 14 | mutations need `Content-Type: application/json` | undocumented in the alias table; a POST without it is **415 `content_type_required`**, which is the CSRF guard. A Swift client that forgets it gets a status nothing in API.md explains |

### The stream, added in phase 2 — where the documents are further from the wire

Captured from a live `GET /api/events` on 2026-07-22 and decoded frame by frame.

| # | claim | what the server does |
|---|---|---|
| 15 | IOS-APP.md §5.1 — the stream opens with `event: hello` carrying `server_time`, `tick`, `hb`, `collector_ok`, `wake_gap`, `caps`, and repeats them in `event: hb` frames | **none of it exists.** `server._stream` writes exactly two things: `id: <v>` / `event: state` / `data: <envelope>`, and `: keepalive`. There is no hello, no heartbeat frame, no capability list, and no `event: intent`, `event: resync` or `bye`. Everything §5.1 builds on those fields — the derived freshness thresholds, `collector_stuck`, `mac_asleep`, the version gate, the capability matrix — has no trigger on this wire |
| 16 | IOS-APP.md §5.4 / §5.6 — `GET /api/meta` carries `server_time` and `contract` | **404.** `/api/meta`, `/api/hello`, `/api/stats` and `/api/v1/stream` are all 404 today. `observer.delta_since`'s own docstring points at `/api/stats` for `drift`/`sweep_ms`; that route is not in `server.do_GET`'s chain |
| 17 | UX.md §3.13 — the client receives `GET /api/v1/stream?since=<epoch>:<seq>` with field-addressed `ops`, an opaque cursor and a `dg` digest | the wire is `/api/events` with a bare integer version, `Last-Event-ID` as the cursor, and **card-level** deltas. §3.13's own text calls a card-level delta "not a delta"; it is what ships, and on this fleet it measures 7,675 B against a 38,193 B snapshot |
| 18 | the keepalive period is advertised so thresholds can be derived from it | `sse_keepalive_s` is a server config knob and **never reaches the wire**. The client carries the default (25 s) and says so in one place (`FleetStore.keepaliveS`) |
| 19 | a delta's `cards` values are cards | **a value can be `null`, and `null` means the worktree is GONE.** `delta_since` builds `{k: snap.cards.get(k) for k in keys}` over a ring of changed NAMES. Phase 1 modelled it as `[String: Worktree]`, which cannot decode `{"gone": null}` — so the one frame that says a worktree disappeared was the one frame the client threw away |
| 20 | `/api/limits.generated_at` is a timestamp like every other | it is an **ISO-8601 string** (straight out of `cclimits`) and `null` in demo mode, while `/api/state.generated_at` is a **float epoch**. Same key name, two types, on one API. `fetched_at` is the float and is what the "fetched 4m ago" line uses |
| 21 | `/api/chat` reports failure with a status code | it answers **200** with `{"ok": false, "error": "unknown account x"}`. A client trusting the HTTP line renders an empty conversation for a nameable failure |
| 22 | `/api/chat` decodes its query string | `server.do_GET` pulls the account out of the RAW path with `re.search(r"account=([^&]+)")` and never percent-decodes it, so a label containing a space or a `+` could never match `config.account_label`. Latent on this fleet — no label needs escaping — and it is why the client shows the server's refusal verbatim |
| 23 | UX.md §3.2 — `showing 4 of 6` comes from a server `session_count` | there is no such field, so a card truncated at `max_sessions` is indistinguishable from a complete one. The screen says nothing rather than a number it would have to guess |
| 24 | UX.md §3.4 — Activity is a tab | `GET /api/dispatchlog` returns `{"entries": []}` and the intent frames its rows are built from do not exist. The tab is not shipped; the two things it could say today live on the worktree and server screens |

### The mutations, added in phase 3 — where the documents are furthest from the wire

Driven with curl against `100.113.110.31:4269` on 2026-07-22: every refusal below
is a body a real server produced. `UX.md` §7 and `API.md` describe a mutation
contract this server does not have, and the gaps are not cosmetic — two of them
change what the app is allowed to do at all.

| # | claim | what the server does |
|---|---|---|
| 25 | UX.md §7.1 principle 2 — `Idempotency-Key` is *"a precondition for shipping dispatch and finish"*, and both must be **disabled** when the server lacks it | **there is no idempotency anywhere.** `server.do_POST` reads a JSON body, pulls named fields out, calls the module. No header is inspected, no `client_op_id` is stored, `GET /api/intents/{key}` is a 404, and `dispatch._jobs` is an in-memory dict of the last 20 jobs erased by a restart. Two identical `POST /api/dispatch` bodies launch **two** agents — the tmux name embeds `%H%M%S`, so any retry ≥1 s later gets a fresh name. See "the idempotency decision" below |
| 26 | a refusal is an HTTP status | **every mutation answers 200** and puts the outcome in the body as `{"ok": false, "message": …}`. `do_POST` writes `send_response(200)` unconditionally after the module returns. The ONE non-200 is **415 `content_type_required`** for a POST without `Content-Type: application/json`, which is the CSRF guard. A client that branches on the status line sees success for every refusal in the app |
| 27 | UX.md §3.3.2 — `/api/send` takes `expect_sid` and `idempotency_key`, routes through `deliver_text()` + `_proven_in_transcript()`, and returns **202** followed by `{"intent_id", "phase": "typed"/"delivered"/"failed"}` frames on `/api/events` | none of it exists. `/api/send` takes `{account, sid, worktree, text}` (plus an optional `pid` *hint*), types synchronously, and returns `{"ok", "message"}`. `expect_sid` is not read — though its intent IS enforced, inside `identity.resolve`, which re-resolves the address at the instant it types. `_proven_in_transcript` lives in `resume.py` and is called only by the resume daemon. So **`✓✓ delivered` is not available on this wire**, and the app tops out at `✓ typed` |
| 28 | **`ok: true` from `/api/send` means the message was submitted** | **on the Terminal/iTerm2 path it does not.** See "the send that types but does not submit" below — this is the sharpest thing phase 3 found |
| 29 | `ok: false` from `/api/send` means nothing was typed | on the **tmux** path it does not: `ok = rc1 == 0 and rc2 == 0` over two calls, `send-keys -l <text>` then `send-keys Enter`. The second failing leaves the message **in the composer, unsent**, and a retry would duplicate it. `Actuation.outcome(ofSend:)` classifies that as `ambiguous`, never as a clean refusal, and the UI refuses to offer a retry from it |
| 30 | `POST /api/dispatch` has one response shape | it has **two, with no shared field**: `{"job": "job-214849-1"}` on the accepted branch — no `ok` at all — or `{"ok": false, …}` refused. `DispatchStart` is a two-case enum for that reason |
| 31 | UX.md §4.3 — progress is `event: intent` frames off the stream | it is `GET /api/dispatch/status?job=…`, polled. The `①②③④⑤` lines are real and are rendered verbatim. An id the server has forgotten answers `{"ok": false, "error": "unknown job"}`, and it forgets on every restart |
| 32 | `effort_confirmed` is a boolean | **tri-state.** `_run_dispatch` leaves it `None` when no effort was asked for, `False` when `/effort` did not echo `set effort level` into the pane. A `?? false` renders "UNCONFIRMED ⚠" for a case where nothing was attempted |
| 33 | UX.md §4.3 / §7.2 — **Kill** (`POST /api/kill {session}`) is the way to stop an agent dispatched by accident | **`/api/kill` does not exist.** Neither does `/api/pasteboard`. `do_POST`'s whole chain is `reserve · resume/schedule · resume/cancel · send · finish · dispatch` plus the `/api/v1` pairing and device routes. So the app has no undo for a launch, and does not pretend to |
| 34 | ios/README finding 3 — *"`closeoutSentAt` … neither string appears anywhere in the server"* | **wrong, and it was the field phase 3 needed most.** The wire name is `closeout_sent`, written onto the card by `observer.py:228` from `finish._closeouts`, and present only while the card still has a live proc. Its presence IS the two-step state machine: present → `✕ close`, absent → `✓ finish`. Phase 2 checked for the camelCase name from IOS-APP.md and concluded the concept was missing. (`card_rev` genuinely does not exist) |
| 35 | UX.md §4.4 — Finish returns an `intent_id` immediately and phases stream (`fetching → checking → typing → brief_sent`) | it is **one synchronous call** that can exceed 60 s: `git fetch origin` (30 s timeout) + merge-base + `git status` + a full `claude_processes()` scan + osascript (10 s), all inside the request. There is no job id. The app gives it 120 s and shows an honest indeterminate elapsed counter, because a staged label on a call with no phases is a timed fiction |
| 36 | UX.md §4.4's outcome table lists six modes | `start_finish` returns **eight**: the six plus `nudge` (a stalled closeout gets the specifics typed at it) and `chat` (the agent is stuck on a question, so a typed nudge would collide with its open dialog and the user must be routed to chat instead). `mode` is also **absent entirely** on the early refusals — unknown worktree, no trunk ref, demo, and "a live process exists but its terminal can't be scripted" |
| 37 | UX.md §4.4 — `pending` carries an elapsed string | it carries `sent`, an **absolute epoch**, deliberately: an elapsed string computed on the Mac and read on a phone minutes later is dead on arrival. It also carries `left` (a short reason) and `files` (≤5 raw porcelain lines) |
| 38 | `finish._closeouts` survives | in-memory only. A restart drops it, the card stops reporting `closeout_sent`, and the button silently reverts to `✓ finish` — pressing which re-types the whole ~600-character brief at an agent that may be mid-closeout. `ActionsStore` remembers briefs **this phone** sent for 30 minutes and warns when the board stops reporting one while an agent is still live. It cannot see a brief sent from the desktop |
| 39 | resume arming needs an idempotency key | it is idempotent **by construction**: `_resumes` is a dict keyed `"{worktree}\|{sid}"`, so arming twice replaces. Driven twice; one schedule. This is the only mutation in the app with no disable-on-tap, and the only one where a retry is safe |
| 40 | `need_time` is an error | it is a **request for a time** — `{"ok": false, "need_time": true}` means no reset timestamp is known for this limit. The sheet expands its exact-time picker rather than showing a failure |
| 41 | a schedule on `/api/state` matches `ResumeSchedule` as modelled in phase 2 | it also carries `resets_at` and `created_at`, which nothing models yet. Harmless — but note that **schedules ride `/api/state` only**: `resume.py` is not watched by the observer, so arming moves no version and no frame can ever carry it. The app force-refreshes `/api/state` after every arm/disarm, or the sheet says "armed" and the board does not agree for up to 20 s |
| 42 | `GET /api/dispatch/status` validates its query | it matches with `re.search(r"job=([\w-]+)")`, so an empty id silently becomes `{"ok": false, "error": "no job"}` rather than a 400 |
| 43 | `_run_dispatch` cannot strand a job | it has **no `try`/`except`**, so a raise inside it leaves the job at `done: false, result: null` forever. The client's 90 s deadline is the only thing that ends that wait, and it ends it as "did it launch?", never as "failed" |

### The send that types but does not submit — the sharpest defect phase 3 found

> **Fixed on the server, 2026-08-04.** `terminal.send_to_process` now presses a
> separate bare Return after the text on all three hosts (the tmux path already
> half-did) and reports `typed and submitted (…)`; the failure case answers
> `ok: false` with the cross-host phrase `sitting in the composer, unsent`,
> which `Actuation.outcome` classifies as ambiguous — no retry offered. The
> account below is the *discovery*, kept as written; wire findings 28 and 29
> describe the pre-fix server.

`POST /api/send` to a Terminal.app-hosted agent answered:

```json
{"ok": true, "message": "typed into Terminal (ttys008)"}
```

The transcript never grew. Reading the Terminal tab back with AppleScript showed
why:

```
──────────────────────────────────────────────────────────── ultracode ─
❯ (orchestra connectivity probe — please ignore, no action needed)
────────────────────────────────────────────────────────────────────────
  ⏵⏵ bypass permissions on (shift+tab to cycle)
```

**The text was in the composer, unsubmitted.** `_SEND_TERMINAL` uses
`do script "<text>" in t`, which writes the text plus a newline in one burst —
and Claude Code's paste heuristic swallows that newline, exactly the
`[Pasted text #N]` failure that `dispatch.deliver_text` was written to defeat on
the tmux path. The osascript path does not use `deliver_text`. Falsified in both
directions: a subsequent bare `do script "" in t` — a Return with no text —
submitted it immediately.

So on the Terminal path, `ok: true` means *"AppleScript found the tab and wrote
to it"*, not *"the agent received your message"*. Reported, not fixed: it is a
server change (`terminal.send_to_process` needs a second `do script ""`, or the
osascript path needs its own proof-of-submission the way `deliver_text` has one),
and this directory does not touch the Python package.

**It also validates the client's receipt design rather than breaking it.** The app
never claims delivery it cannot see: `✓ typed` is the server's `ok`, and the
second tick is only ever earned by finding the message in the next `/api/chat`
poll. That look is **positive-only** — every one of the five known mismatch paths
(`UX.md` §3.3.2) is a false negative, so a message that is not found is never
reported as missing. On the Terminal probe the app would correctly have stopped
at `✓ typed`.

### The idempotency decision, stated rather than buried

`UX.md` §7.1 principle 2 says dispatch and finish must be **disabled** when the
server has no idempotency key. This server has none, and shipping a phase 3 that
cannot act is not a useful reading of that rule. So this build ships them with the
guard a client can actually enforce, and `Rules/Actuation.swift` names both holes
it cannot close:

| risk | covered? |
|---|---|
| the user taps Launch twice | **yes** — `InFlight` refuses the second, and the action button never re-enables (§7.4) |
| the app auto-retries a POST | **yes** — nothing in this app retries a mutation, ever. `Actuation.mayOfferRetry` returns true for exactly one outcome: a clean server refusal, which proves nothing happened |
| a timeout rendered as failure, and the user re-taps | **yes** — a timeout is `.indeterminate` and reads *"no answer in 90 seconds. A mission may already be running… a retry can start a SECOND agent in the same worktree."* A test asserts no indeterminate copy in the app contains the word "fail" |
| **URLSession retransmits under us** | **no.** Not app-configurable |
| **a second phone, or the desktop board** | **no.** A client-side lock is defeated by two clients — the exact case §7.1 principle 3 warns about |

The two open rows were the server's to close, and it has: `orchestra/idem.py`
persists a boot-tagged reservation write-ahead, so a retry that lands after
`./start.sh` restarted the server is refused rather than re-executed. Both
mutation requests now carry **`Idempotency-Key`** (a fresh client UUID per user
action) and **`Idempotency-Issued-At`** — `Endpoint.freshIdempotency()` mints
them and `urlRequest` sets them. Per tap, never per payload: retrying one action
replays the first answer, while launching the same brief again deliberately is a
second key and a second agent.

### Phase 3: the defect a screenshot found

**The composer sat underneath the connection bar.** Exactly the shape phase 2 hit
with the chat screen's read-only notice — a bottom-pinned control inside a
*pushed* navigation destination does not receive the `safeAreaInset` the tab
applied outside the `NavigationStack`, so it lays itself out against the screen.
Phase 2 dodged it by moving the notice to the top, which works for a caption and
is impossible for a text field. Everything compiled, the transcript rendered
perfectly, and the send button and its "newlines become spaces" footnote were
half-hidden behind `live v78`.

Fixed by **measuring** rather than assuming: `ConnectionBarModifier` reads the
bar's real height with `onGeometryChange` and publishes it as
`EnvironmentValues.bottomAccessoryHeight`; the composer and the worktree screen's
finish footer pad by it. A constant would have been wrong the first time the bar
grew its second line — which it does on every stale board.

### What phase 3 did NOT verify against a live server

Stated rather than implied, because an untested path that looks tested is the
failure this project keeps finding:

- **A real dispatch was never launched.** The refusal paths were driven for real
  (missing model/effort; `needs_decision` with its `can_opus` block), and the
  whole job → poll → terminal-result path was driven end to end using a worktree
  name that does not exist, so `_run_dispatch` ran and failed inside the thread at
  no cost. The success branch is modelled from `_run_dispatch`'s own `finish({…})`
  literal and is decode-tested, not launched.
- **`/api/finish` was driven only to its refusals.** A real closeout types a
  600-character brief at a live agent and can merge and push; step two's UI
  (`✕ close`, the self-clearing `pending` row) is built against `closeout_sent`
  and the `pending`/`chat`/`nudge` bodies, and has not been seen with a brief
  actually outstanding.
- **Arm / disarm was driven by curl, not by a tap.** The sheet renders and its
  fire semantics are stated; the round trip (`armed for 22:49` → visible in
  `/api/state.resumes` → `auto-resume disarmed`) was proven at the HTTP layer.

### ATS, measured rather than assumed

IOS-APP.md §1.5 states *"ATS domain exceptions do not apply to IP-address URLs."*
**On iOS 26 they do**, as an exact `NSExceptionDomains` key. This was not read, it
was falsified: deleting the `100.113.110.31` entry from `Orchestra-Info.plist` and
rebuilding turns the working board into
`NSURLErrorAppTransportSecurityRequiresSecureConnection` (-1022), and putting it
back restores it. The entry is load-bearing and the test that says so can fail.

Both forms are covered, because both are real addresses for the same Mac: `ts.net`
with subdomains for the MagicDNS name, and the raw tailnet IP because
`pairing._server_facts` advertises the address the server is **bound** to — so the
QR hands the phone an IP literal. The IP entry is the one line in this directory
that changes when Tailscale reassigns the address.

`NSAllowsArbitraryLoads` is never set. `NSAllowsLocalNetworking` does not help:
it covers `.local` and link-local, not the `100.64/10` CGNAT range.

## Final verification: the defect the app's own retries were hiding

Found on 2026-07-22 by revoking this phone's device on the real server and then
looking at what the app said. The board emptied — correct, a 401 clears `state`
rather than dimming it — the connection bar said `this device is no longer
paired` for about a second, and then the screen and the bar both settled on:

```
the server said 429
too many failed authentication attempts from 100.113.110.31; try again in 3s
```

`audit.log.jsonl` says why. Thirty refusals in twenty-six seconds, from one
phone, one per second, forever:

```
22:37:36 /api/state   device_revoked
22:37:37 /api/state   device_revoked
22:37:38 /api/state   device_revoked
…
```

`streamLoop` gets this right — `a token problem is not retried`, and it returns.
The **side fetch** was the half still hammering. `pump()` ticks every second and
`refreshSide` guarded on `sideAt`, which was assigned inside the `do` block,
*after* the `await`: only a SUCCESS ever advanced the window, so a fetch that
kept failing re-fired on every tick. That storm spends orchestra's 10/min per-IP
auth budget in about a second, and the 429 that follows overwrites the one
sentence that tells the user what to do. **The client's own retries hid the real
error.**

Two changes, both in `FleetStore`:

* the cadence clock is the last **attempt**, not the last success —
  `beginSideFetch(now:force:)` decides and records in one call, deliberately, so
  the rule and the write cannot drift apart;
* `.unauthorized` is not polled at all, matching the stream. `force` still wins,
  which is the retry arrow and pull-to-refresh.

Three mutations, each watched red: dropping the 401 clause, moving the clock back
onto the success path, and returning the polling period to 1 s. The first version
of the test was a pure predicate over `mayFetchSide` and it **did not catch the
second mutation** — the rule was pinned and the call site was not, which is
exactly the shape of the original defect. That is why `beginSideFetch` exists and
why the second test drives it against a store where nothing succeeds.

Re-driven against the real server with the auth budget drained: **3 refusals in
30 seconds**, and the screen reads

```
🔒 this device isn't paired
device 'iPhone 17 Pro Max' was revoked; pair again to get a new token
```

which is the server's own words and was there the whole time.

**What the same pass confirmed rather than broke.** A clean
`xcodebuild clean && build` with no source warning; 96 headless tests; fourteen
screens screenshotted and looked at, none blank; an untracked file created in
`ConfidAi6` moving the phone from no-Δ to `Δ1 uncommitted` and `v94 → v96` with
no interaction; a server killed mid-stream reading `reconnecting… (2) · showing
data from 6s ago` and then `orchestra isn't running · showing data from 31s ago`,
recovering by itself when the server came back **with its version reset 96 → 1**
(the cursor-ahead branch of `delta_since`, driven by accident and then on
purpose); one socket across background/foreground (`1 → 0 → 1`, same pid) with
`resyncs: 0`; `no upstream` rather than `↑0` on the two detached worktrees whose
`ahead`/`behind` are null; and `tailnet unreachable` distinguished from
`this build cannot reach that address` distinguished from `orchestra isn't
running` — three different failures, three different sentences.

One cosmetic note from the same sweep: the pairing fixture in
`Tests/OrchestraKitTests/DecodeTests.swift` carries a token-shaped string whose
device-id segment collides with a real (long-revoked) device in `devices.json`.
It is synthetic — its sha256 matches nothing in the registry and the live server
answers it 401 — but a fixture that looks like a credential is worth not writing.

## The composer, fixed by a phone

Two defects a user hit on a real device, in the one screen that spends money.
Both are the shape this project keeps finding: everything compiled, everything on
screen was correct, and the thing was broken in a way no simulator run had shown.

### 1. A `Menu` is laid out into the space around its anchor, and a tall keyboard takes that space

The four option rows (Worktree / Account / Model / Effort) were `Menu { … }
label: { … }`, inside a `ScrollView`, inside a `.sheet`. **UIKit lays a menu into
whatever region is left around its anchor.** In this screen that region is
squeezed from below by the keyboard and from above by the navigation bar, and the
anchor row itself sits lower the more mission text has been typed. Multiply those
together and it collapses.

Reproduced by the user, not hypothesised: *"the menu issue occurs when I have the
Wispr keyboard and I've granted it access to my keyboard."* A third-party
keyboard with **Full Access** is hosted out of process and adds its own toolbar
row above the standard layout, so it is materially taller than the stock one.
With that keyboard up and a long mission typed, the menu rendered as a **~20 pt
sliver pinned under the navigation bar** — one clipped option, scrollable only
with great care. With the stock keyboard there is usually just enough room, which
is exactly why it looked intermittent: keyboard height × scroll offset × text
length.

**The fix removes the dependency on anchor geometry rather than tuning it.**
Tapping a row clears the editor's `@FocusState` (the keyboard goes away) and
presents an `OptionPickerSheet` — a bottom sheet the *window* lays out, full
width, system detents, with nothing to be squeezed around. Each option is ≥44 pt,
shows a checkmark on the current selection, carries its description where it has
one, and **wraps instead of clipping**, which is what the account labels
(`work · 0% left · exhausted`) needed. One generic sheet serves all four rows;
the row's own design — title left, value and chevron right, amber `— pick one —`
for the two with no default — is untouched. Only the presentation changed.

Geometry independence here is **structural, not measured**: the sheet has no
anchor, so there is no region for a keyboard to shrink. What was measured is the
condition itself — a long mission with the software keyboard up, the four rows
squeezed into the band the old menu had to fit inside, and then the same code
path clearing focus and presenting a full-size sheet
(`11-keyboard-up.png` → `12-picker-over-keyboard.png`). A simulator cannot run
Wispr Flow, so the *taller* keyboard is the one variable still unproven on
hardware; the fix does not read keyboard height anywhere, which is the point.

### 2. The biometric gate deleted the draft, because the draft lived in `@State`

Open the composer, type a long mission, switch to another app (to start dictation
software, say), come back: the app re-locks behind Face ID — **correct, and
deliberately unchanged** — and after unlocking the sheet was gone and so was the
text. `RootView` swaps the entire paired subtree for `LockView` on `.background`,
and that takes the presented sheet and every `@State` inside it. Nothing was
persisted. `UX.md` §3.5 asked for a persisted draft and it had never been built.

`Store/DraftStore.swift` now holds the text, the four selections and the
composer's `isPresented`, outside the gated subtree, in `AppModel`:

* **debounced ~500 ms** on text change, so a 3,000-character mission is not
  re-encoded on every keystroke, and **flushed synchronously on `.background`**
  in `OrchestraApp`'s `scenePhase` handler, before anything is awaited — a
  suspended app can be killed with no further callback;
* **the sheet's `isPresented` binding is the store's**, so the composer
  re-presents itself when the subtree comes back after the unlock;
* **re-presented only within 24 h.** Beyond that the text is kept and restored
  the next time the composer is opened, but no sheet rises unbidden days later.
  An empty draft is never restored as an open sheet;
* **`UserDefaults`, not an App Group** — there is no second process to share it
  with (no share extension, no widget), and an entitlement bought for a reader
  that does not exist is one more thing this repo's ad-hoc signing has to carry.
  The comment in `DraftStore` says so, and names the day it changes.

**Cancel keeps the text; only two things clear it.** Losing a long mission to a
mis-tapped Cancel is worse than a draft that outstays its welcome, so Cancel
closes and keeps, and the next open restores. A draft goes away when the server
**accepts** a dispatch (a job id is back, an agent is starting, and this server
has no idempotency key — text that reappeared afterwards would invite the
double-fire nothing can refuse), and when the user taps **`discard draft`**, a
small affordance that appears next to the character count only when there is a
draft and asks once before it does it. A *refused* dispatch keeps the draft:
"Back to the draft" has to have a draft to go back to.

Twenty tests in `DraftTests.swift` drive the store against a throwaway
`UserDefaults` suite: the round trip, the debounce coalescing five keystrokes
into one write, both sides of the 24 h window, the kill-with-no-background
fallback, whitespace-is-not-content, the launch/cancel/discard split, and
`restoreIfEmpty` — the rule behind **"Back to the draft"**. That last one closes
a hole the clear-on-job rule opened: the draft goes the moment a job id comes
back, so a run that started and then *failed* left "Back to the draft" pointing
at an empty editor. `ActionsStore.DispatchRun` kept its own copy of all five
fields, and an empty composer gets them back — an empty one only, because a
mission the user has already started retyping outranks the record of the last
one. A *refused* dispatch never cleared anything (no job), so there it is a
no-op.

### Two more `#if DEBUG` seams, for the same reason as the first three

`ORC_SCREEN=mission:model` (also `worktree`, `account`, `effort`) presents that
row's picker on top of the composer, through the same `present(_:)` the row's tap
calls — because a **sheet inside a sheet** is something `xcrun simctl` can
neither tap nor otherwise reach, and a fix whose whole claim is "the picker is
full-size now" is one only a screenshot can settle. `ORC_MISSION=<text>` seeds
the draft through `DraftStore.setMission`, the same call the editor makes on
every keystroke, because the two things most worth looking at — a picker
presented over a LONG mission, and a draft surviving a background — both need
text on screen that no script can type.

### 3. The same defect, one screen along: the CHAT draft

Reported from a phone, in the same words as the mission one: *"When I input chat
into an agent conversation … and then go out of the app and do something else, or
I have to give permission to Wispr to allow it to enter into that text field, the
input that I had already entered is lost."* Same cause exactly — `ChatView` held
`@State private var draft` and it is a **pushed destination inside the gated
subtree**, so the re-lock takes the screen and everything on it. Same fix, same
machinery: `DraftStore` grew a second half rather than a second store.

* **Keyed by `sid` alone.** A sid is the CLI session's own v4 UUID (`DebugRoute`
  parses it as "a UUID with dashes"), unique across accounts and worktrees, so
  the account adds nothing to the key — and leaving it out is what makes one
  conversation carry one draft whether it was reached from the board or from the
  worktree screen. Sends are still addressed by `(account, sid)` because the
  *server* resolves a process that way (ADR 0008); which text belongs to which
  screen is a different question.
* **Bounded at both ends**, because a fleet churns through sessions and
  `UserDefaults` is not a database: at most **20** drafts, evicted LRU by
  last-touched, and nothing kept longer than **7 days**. Both bounds are pure
  functions on `ChatDrafts` and are re-applied on load and on every edit. Empty
  and whitespace-only text removes its entry rather than leaving a tombstone.
* **One blob under one key**, for the same reason the mission is one blob: a key
  per session would leave a key per dead session behind, which is the growth the
  bounds exist to prevent.
* **Cleared only by a send that is proved to have left.** `ChatStore.send`
  answers an `Outgoing.State?`, and `didLeave` is true for exactly `typed`
  (`rc == 0` from a real tty) and `inTranscript`. `refused`, `ambiguous`, `lost`
  and a nil (the send was never attempted) all **keep** the text and put it back
  in the field: at that moment the composer holds the only copy the user has, and
  the outgoing bubble that also shows it dies with the screen at the next re-lock.
  A duplicate is a nuisance; a deleted paragraph is gone.
* One real bug fell out of writing that rule: on the *success* path `send` used
  to `return outbox.last?.state`, and the strongest outcome — the message sighted
  in the transcript, which **removes** the bubble — left that nil, the same value
  the function returns when it refuses to send at all. It now reads back by id
  and treats a missing bubble as `inTranscript`.

The field itself keeps its `@State`, hydrated from the store on appear and
written through on every change. That is deliberate and it is the one difference
from the mission composer, which binds straight to the store: assigning a
`TextField`'s bound String from outside moves the caret to the end, and this
screen only ever needs the text from outside once — on the appear that follows
the unlock.

`ChatDraftTests` (17 tests) covers the round trip, two sids not colliding, the
debounce, the background flush carrying both composers, the LRU cap, both sides
of the 7-day window, and the send ladder: `typed` clears, `refused` does not.

### 4. Cancel and Launch stayed on the Launching screen

Also reported from a phone: *"there's a cancel and launch header button on the
launching screen … I'm not sure if it's too late to cancel, but it's definitely
too late to launch."* Both halves were true. The `.toolbar` was attached to the
outer `Group`, so both buttons rode through the whole dispatch:

* **Launch was a dead control** — `canLaunch` is false while `dispatch != nil`,
  so from the instant the mission was confirmed it rendered permanently disabled.
* **"Cancel" was a lie of labelling.** It called `dismiss()` and nothing else. It
  did not stop the mission and it *cannot*: `/api/kill` does not exist (row 33
  below), so this app has no undo for a launch. A button labelled Cancel on a
  screen titled "Launching" reads as "stop this".

`Rules/ComposerChrome.swift` makes the toolbar a function of the run's phase —
outside `UI`, because `UI` is excluded from the test target and a toolbar rule
that can only be checked by looking at a screenshot is one that drifts.

| phase | leading | trailing |
| --- | --- | --- |
| no run — editing | `Cancel` (keeps the draft) | `Launch` |
| `launching`, `running` | `Close` | — |
| `finished`, `refused`, `lost` | — | — |

In flight, the body says in words what Close does not do: *"Closing this doesn't
stop the mission, and nothing on this phone can — there is no kill switch on the
server. Attach on the Mac."* In a **terminal** phase the toolbar carries nothing
at all, because the body already carries exactly one action per phase (`Done`, or
`Back to the draft`) and two buttons that both leave — one of which also clears
the run — is a choice with no meaning. Nobody is trapped: the sheet still
dismisses interactively, and every terminal phase has its own action on screen.

### Two more `#if DEBUG` seams: `ORC_CHAT` and `ORC_DISPATCH`

```sh
SIMCTL_CHILD_ORC_SCREEN=demo:chat:search-index/main/<sid> \
SIMCTL_CHILD_ORC_CHAT='half a reply, already typed'  xcrun simctl launch booted sh.orchestra.app
SIMCTL_CHILD_ORC_SCREEN=demo:mission \
SIMCTL_CHILD_ORC_DISPATCH=running                    xcrun simctl launch booted sh.orchestra.app
#   ORC_DISPATCH = launching | running | finished | failed | refused | lost
```

`ORC_CHAT=<text>` seeds the chat composer for whichever session `ORC_SCREEN=chat:`
is about to open, through the same `DraftStore.setChatDraft` the field calls on
every keystroke. It runs **once, at launch, in `AppModel`** and deliberately not
in `ChatView`: the thing being verified is that the field survives its view being
destroyed and rebuilt, and a seam that re-seeded on every appear would paint the
restore it is supposed to prove. Seeded once, everything after it — the lock, a
background, a cold relaunch with no seed at all — is the real path.

`ORC_DISPATCH=<phase>` renders the **Launching** screen for a run that does not
exist. It is the one seam that does not press a button, and the reason is worth
stating: reaching that screen for real means spending an account's usage and
starting an agent on somebody's Mac, and the demo fleet cannot reach it either
(`canLaunch` is false in demo, and `ActionsStore.launch` answers `.refused`
there by design). Only the phase is injected; the title, the toolbar rule, the
body and the copy are the real code reading a real `DispatchRun`, and
`actions.dispatch` always wins, so a real launch is never shadowed.

## Phase 2: three defects found by RUNNING it, not by reading

All three had the same shape — everything compiled, everything on screen was
correct, and the thing was quietly broken.

**`AsyncLineSequence` drops empty lines, and an empty line is how SSE ends an
event.** The obvious transport is `URLSession.AsyncBytes.lines`. Built that way,
the app held a healthy ESTABLISHED socket, received every byte of every frame,
and **never dispatched one** — the connection strip read `connecting…` forever
while `lsof` on the Mac showed the stream open and the server showed the snapshot
written. `AsyncLineSequence`'s iterator only yields when its buffer is non-empty,
so the blank line between frames is silently swallowed, and in SSE that blank
line is not whitespace, it is the dispatch instruction. Falsified directly
against the live server:

```
A. .lines over the first 3 lines — blank line delivered? false
B. byte-wise: 38229 bytes, 4 lines, 1 blank, in 349 ms
```

Byte-at-a-time over `AsyncBytes` restores the semantics and costs 349 ms per
38 KB frame — an async `next()` per byte. So the transport is a
`URLSessionDataDelegate` handing whole `Data` chunks to `SSELineSplitter`, which
is what `IOS-APP.md` §2.1 says ("delegate-based, deliberately") without saying
why. This is the why.

**`finishTasksAndInvalidate` leaks the socket; the stream needs
`invalidateAndCancel`.** Backgrounding cancels the consuming `Task`, which runs
the `defer` that tears the session down — and `finishTasksAndInvalidate` *waits
for outstanding tasks to finish*, which for a stream is never. Measured with
`lsof -nP -iTCP:4269` across the app's own lifecycle:

```
                    before          after
foreground             1              1
backgrounded           1   ← leak     0
re-foregrounded        2   ← leak     1
after 3 cycles         —              1
```

Every leak burns one of the server's 32 subscriber slots for a client that is not
there, which is the exact failure `stop()` exists to prevent.

**A foreground resume threw its own cursor away.** `resume()` restarts the stream
*and* forces a `/api/state` fetch, so there is always a window where the link is
`.connecting` and a good version is still held. `stream.js` seeds whenever the
stream is not live, and on a browser that is close enough; on a phone it nils the
version (a `/api/state` body carries none), the server answers our
`Last-Event-ID` with a delta, the delta has no base to land on — gap, resync, and
a full 38 KB snapshot for a resume that should have cost one delta. The
diagnostics screen is what showed it: `resyncs: 1` after three
background/foreground cycles, `0` after the fix. The rule is now a pure function,
`FleetStore.maySeed`, and the mutation that restores `stream.js`'s simpler
version is caught by a test.

And two more that only a screenshot could have found, both on views that
compiled, rendered, and were wrong: a dark vertical seam down the right edge of
every session row (a `.background` on the disclosure chevron covers the glyph's
own height, and the canvas shows through above and below it), and the chat
screen's read-only notice sitting UNDER the connection bar (a bottom-pinned row
inside a **pushed** navigation destination does not receive the `safeAreaInset`
the tab applied outside the `NavigationStack` — two attempts to fix it in place
failed the same way, so the notice moved to the top, where it is read anyway).

## Phase 1: two defects found by looking, not by reading

Both are the shape METHOD.md is about — everything on screen was correct.

**The second-launch bug.** The app paired against the real server, drew the real
board, and came back to the pairing screen on the next launch. A target built
with `CODE_SIGNING_ALLOWED = NO` carries no entitlements, so it has no keychain
access group and `SecItemAdd` answers `errSecMissingEntitlement`. The token was
never written; only the *second* launch could see it. Fixed with ad-hoc signing
(`CODE_SIGN_IDENTITY = "-"`) plus `Orchestra.entitlements`, and verified by
pairing, terminating, relaunching with no seam, and watching the board come back.

**Every pid had a decimal point in it.** `Text("\(n)")` resolves to the
`LocalizedStringKey` overload, which formats the interpolated integer through the
locale — pid `34115` rendered as `34.115`. A pid is an identifier, not a
quantity, and neither is a commit count in a mono column. Every numeric literal
in the UI is now `Text(verbatim:)`.

## Measured, driving the real fleet

* **A `touch` on a watched transcript reached the phone in 1.27 s** — touch at
  `1784748313.813`, `delta v=72 base=71 cards=['ConfidAI2']` on the wire at
  `1784748315.081`. The board's two session rows swapped (the server re-sorts by
  freshness) and the top row went `19m` → `3s` with no interaction, no
  pull-to-refresh and no poll.
* **A live agent's own write did the same**, unprompted: `v73 → v74`, one card,
  `17m` → `28s` on screen.
* **A delta is 7,675 B against a 38,193 B snapshot** on this nine-worktree fleet
  — 20 %, and it carries one card out of nine.
* **Not every write is fast.** A touch on an older transcript on the same card
  produced nothing for 16 s, then arrived on the ordinary sweep. The ~1 s figure
  is the kqueue-watched path; a file the watcher is not holding an fd for falls
  back to the cadence. Worth knowing before promising "~1 s" as a flat number.

## Open, and deliberately not done in this phase

- **The Activity tab.** See wire finding 24: no data source exists. Phase 3 makes
  this more visible rather than less — a dispatch is now startable from the phone
  and its history lives only in `ActionsStore` for as long as the app is alive.
  `GET /api/dispatchlog` returns `{"entries": []}` on this fleet.
- **Kill.** There is no endpoint (finding 33), so there is no way to stop a
  mission from the phone. The launch confirmation says so rather than promising an
  undo that does not exist.
- **`force_model` was never exercised against a real reserve.** The sheet exists
  and is wired; the only `needs_decision` reachable without spending was a
  nonexistent account, whose `can_opus` was false.
- ~~**Draft persistence.**~~ **Built** — see "The composer, fixed by a phone" below.
  `UX.md` §3.5's App Group is deliberately still `UserDefaults`: there is no
  second process to share it with yet.
- **Share extension, `orchestra://mission?text=`, Live Activities.** All of §3.5
  and §8.3's surfaces are additive and none is load-bearing. The share extension
  is the one that would turn `DraftStore`'s `UserDefaults` into an App Group.
- **The branch map** (`UX.md` §5) and `/api/topology`.
- **Clock skew.** Every relative label is `device now` minus a server instant, and
  nothing corrects for skew. `IOS-APP.md` §5.4 samples it from
  `/api/meta.server_time`, which is a 404; `/api/health.time` is the one honest
  source on this server and wiring it is additive.
- **Push.** No APNs key exists and only the account holder can make one. Nothing
  here is load-bearing on it: it lands as a registration call and a delegate.
- **Real modules.** See "Shape".
- **The Asset Catalog.** `Palette` resolves all four variants of every token in
  one `UIColor(dynamicProvider:)`, which keeps UX.md §9.1's actual property (no
  ternary at any call site, so Contrast+ cannot be applied 60 %). A catalog is
  still the better home because it reaches widgets and notification content,
  which render out of process.
- ~~**IBM Plex Mono.**~~ **Done** — four faces bundled in `App/Fonts/`, Bold Text
  resolved from `\.legibilityWeight`, and the per-glyph failure §9.4 warns about
  closed by a whole-face guard and a coverage test. See "Shape". No call site
  changed, exactly as this entry predicted.
- **A device build.** Simulator only. A real device needs a team in a gitignored
  `Signing.xcconfig`; that is the one thing here that needs the paid account.

## Phase 4 — push

Registration, per-event preferences, deep links, and inline reply from the
banner. The server pipeline (`push.py`, `notify.py`) shipped in phase 2; this is
the phone half.

### What it does

* **Registration.** On first pair the app asks for authorization
  (`.alert/.sound/.badge`), registers for a remote token, and POSTs it to
  `/api/v1/devices/self/push` with the environment (read from the embedded
  provisioning profile's `aps-environment`, `sandbox` on a simulator), the
  device's tz offset, and the app version. It re-registers on foreground —
  cheap, and it is how a rotated token and a moved timezone reach the server,
  since iOS gives no background callback for either. `PushStore` is pure (no
  UIKit); `PushController` is the `UNUserNotificationCenter` adapter.
* **Inline reply — the point of the feature.** The `ORC_REPLY` category carries a
  `UNTextInputNotificationAction`; answering it calls `/api/send` addressed by
  **`sid` alone**. The payload never carried an account and does not need one:
  `identity.resolve` resolves a bare sid to the live process. Not `.foreground` —
  the whole value is answering without opening the app.
* **Deep links.** A tap deposits a `PushDeepLink` in `PushRouter`; `RootView`
  selects the Fleet tab and `FleetView` resolves the account (absent from the
  payload) from the live board by sid and pushes the exact conversation. The
  link is HELD while the board loads, so a cold-launch tap still lands on the
  chat rather than settling for the board.
* **Preferences.** `NotificationSettingsView` (reached from the Server tab) edits
  per-event rules, quiet hours, privacy and the nudge interval, and writes
  `/api/v1/devices/self/settings`. Defaults mirror `EVENT_TYPES[…]["default"]`
  exactly — your-turn, auto-resume-armed and worktree-freed are OFF, pinned by a
  test.

### Drive it without a finger — the `#if DEBUG` seams

A simulator cannot tap a permission dialog, a notification banner, or a reply
field, so — exactly like `ORC_SEND`/`ORC_SCREEN` — each path has a seam that
presses the same button the OS presses, through the same `PushStore` /
`PushController` the delegate uses.

```sh
# 1. registration reaches the server (synthetic token, real POST)
SIMCTL_CHILD_ORC_PUSH_TOKEN=$(python3 -c "print('facefeed'*8)") \
  xcrun simctl launch booted sh.orchestra.app
#   → devices.json gains push.{token,environment:sandbox,tz_offset_min,app_version}

# 2. a tap deep-links to the exact session
SIMCTL_CHILD_ORC_PUSH='{"ev":"session.needs_answer","wt":"ConfidAI2",
  "sid":"<sid>","level":"P1","aps":{"alert":{"title":"…","subtitle":"…"}}}' \
  xcrun simctl launch booted sh.orchestra.app
#   → lands on that session's ChatView

# 3. an inline reply reaches the agent, by sid alone
SIMCTL_CHILD_ORC_PUSH='{…same…}' \
SIMCTL_CHILD_ORC_PUSH_ACTION=reply \
SIMCTL_CHILD_ORC_PUSH_REPLY='yes, ship it' \
  xcrun simctl launch booted sh.orchestra.app
#   → POST /api/send {sid,text}; server types into the live terminal

# the preferences screen, and provisional auth so a launch does not stall on the prompt
SIMCTL_CHILD_ORC_PUSH_PROVISIONAL=1 SIMCTL_CHILD_ORC_SCREEN=notifications \
  xcrun simctl launch booted sh.orchestra.app
```

### Where the documents and the server disagree — reported, per METHOD §4

Modelled from a live `notify.compose` and driven against `100.113.110.31:4269`
on 2026-07-23.

| # | claim | what the server does |
|---|---|---|
| P1 | the payload carries a `category`, or `API.md` §9.23's `expect_sid`/`intent_id`/`phase` | `notify.compose` emits **none of them**. The `aps` has `alert`, `interruption-level`, `thread-id`, `mutable-content:1`, `content-available:1`, `sound`; the body has `ev`, `event_id`, `dedupe_key`, `at`, `wt`, `sid`, `level`, `counts`. **No `category`** — and iOS decides the inline-reply field from `aps.category` at delivery. So the app DERIVES it (`PushMessage.categoryID` → `ORC_REPLY` for `needs_answer`/`blocked`, else `ORC_INFO`) and it must be STAMPED onto the notification before the banner shows: by the notification-service extension (`mutable-content:1` is set for exactly this) or by a one-line server addition (`aps["category"]`). Until one of those lands, a real push shows no reply button. The app half is complete and drives correctly for any payload carrying the category. |
| P2 | the push payload carries an account for the reply | it carries `sid` and `wt`, **never an account**. Inline reply is `POST /api/send {sid, text}` (worktree as a free corroborator); `identity.resolve` resolves the bare sid. Driven live: `{"ok": true, "message": "typed into Terminal (ttys010)"}`. |
| P3 | a device can read back its stored preferences | **no route returns them.** `GET /api/v1/push/status` answers the pipeline's health and a `registered` bool — nothing about rules or quiet hours. The settings screen opens on the app's **local mirror** of the last save and says so; every save POSTs the full set and adopts the server's echo. |
| P4 | `/api/v1/devices/self/push` is device-self-service on every running server | a server that PREDATES the `SELF_SUBTREE` auth fix refuses it **403 `admin_local_only`** to any token (observed on a server started before the fix; a restart cleared it). The app maps 403 → a registration failure carrying the server's own sentence, so a stale server is diagnosable rather than a silent dead token. |
| P5 | `/api/v1/push/test` answers `{ok, message}` | it answers `{ok, backend, status, apns_id, reason, environment, message, health}`. The app reads `message` — e.g. `"no answer · apns_key_path is not set — the .p8 auth key file…"`, a working transport naming the one missing credential. |
| P6 | `/api/v1/push/status` names a missing key as `"no APNs key configured"` | the live sink is more specific: `"apns_key_path is not set — the .p8 auth key file downloaded from developer.apple.com"`. The app shows whatever `problems[]` says, verbatim. |

### What only a device — or a key — can add, and what a simulator cannot show

- **Apple's own delivery.** No `.p8` exists (only the account holder can make
  one — `docs/mobile/APNS-SETUP.md`), so `/push/test` correctly stops at "no
  key". Everything up to Apple accepting the token is proven.
- **A real remote token.** The simulator's `registerForRemoteNotifications` does
  not mint one here; registration was proven with a synthetic token through the
  identical `PushStore.register` path, stored by the server. A device build needs
  the `aps-environment` entitlement and the Push Notifications capability, which
  ride the provisioning profile — the paid-account items, gated exactly like the
  device-signing note above. They are deliberately NOT in the shared
  `Orchestra.entitlements`, because an `aps-environment` entitlement breaks the
  ad-hoc simulator signing this repo builds with.
- **The banner presentation itself.** `xcrun simctl push` delivers the payload,
  but iOS suppresses PRESENTATION until notification authorization is granted —
  and on the iOS 26 simulator that cannot be scripted: the authorization prompt
  appears even for `.provisional`, and the Simulator exposes no accessible window
  to tap "Allow" (no `idb`/`cliclick`, System Events sees zero windows). This is
  the same wall the `ORC_*` seams exist to climb, so the notification-handling
  path — deep link and inline reply — is driven through the delegate's own code
  by the seams above and verified against the real server, which proves
  everything except the pixels of the banner. The authorization request itself is
  screenshotted (the real system prompt fires on launch).

## Phase 5 — the demo fleet

`docs/mobile/APPSTORE.md` §8 row 1 names the likeliest rejection by a wide
margin: a reviewer with no Mac opens a companion app, sees a pairing screen,
cannot proceed. The answer is one tap on the first screen — **`explore the demo
fleet`**, that exact string, because the review notes and the screenshot job both
name it.

### What it is, and what it is deliberately not

* **It is the real app, told a different board.** The canned payload goes in as
  *bytes* through `StreamFrame.decode` → `FleetApplier.apply` → `FleetStore`,
  which is the exact path an `event: state` frame off the socket takes. Chat goes
  through `ChatStore.load` and renders `ChatBubble`; limits go through
  `LimitsReport`'s decoder; the map through `Topology`'s. There is no second
  rendering anywhere, and `free_worktrees` on the demo board is *derived by the
  applier* from the cards — a test asserts that, because it is the cheapest proof
  the frame really went through it.
* **It is Swift string literals, not a bundle resource.** `Package.swift` builds
  `Sources/Orchestra` as one target with warnings as errors, and a stray
  non-source file in that tree is a build problem rather than a resource. A
  literal is also the only form `swift test` can decode without a bundle — and
  this payload *must* be tested, because a demo board that fails to decode fails
  on a stranger's phone, during review, with nobody watching.
* **It is not a smaller app.** Every mutation — send, dispatch, finish, arm,
  disarm, resume-now, push preferences — is **visible and disabled with the
  reason attached**, never hidden. A reviewer is here to see that the app can act
  on a fleet.
* **Nothing is ever faked.** Refusals come from the *stores*, not only from the
  views: `ChatStore.send` returns `.refused`, `ActionsStore.launch` produces the
  `.refused` dispatch phase (the only one that means *nothing was launched*), and
  the three resume paths share one refusal. The disabled button is the courtesy;
  the store is the guarantee. A test asserts no demo copy carries a `✓`.

### The two rules that make it not look dead

**Ages are rewritten at load.** Every timestamp in the payloads is written
against a fixed fiction — `DemoClock.base`, 2027-01-15T08:00:00Z — and moved onto
the reader's own clock the instant the demo opens. A canned board with absolute
epochs baked in reads `3d ago` on every row within a week of shipping, and a
board where nothing has happened for three days is not a demonstration of a live
fleet. The rule is deliberately not a list of key names: **any number inside a
30-day window around `base` is a demo timestamp, and so is any ISO-8601 string
that parses to an instant inside it.** A key list goes stale the first time the
server grows a field; the window cannot, because nothing else on this wire is
near 1.8 × 10⁹ — pids are six digits, percentages and cpu under 100, dirty counts
under a thousand. Two consequences worth stating: rewritten instants are **whole
seconds** (`git.commit.ts` is an `Int` and a fractional double there is a
`typeMismatch` that takes the whole board with it), and JSON booleans bridge to
`NSNumber` but sit nowhere near the band, so they pass through with their
identity intact. Both are pinned by tests.

**The connection bar gets its own state.** `LinkState.demo` is a real case, not a
borrowed `.live` — `live v82` over a canned board is precisely the lie the whole
strip exists to prevent. It reads `demo fleet · nothing here is real`, `isLive`
is false, the version chip and the retry arrow are gone, and in their place is
`leave the demo`. `staleness` returns `.fresh` for it forever, because every
other non-live state dims the board past the silence budget — correct for a dead
socket, and it would tell a reviewer the app is broken.

### The gate, and the way out

The demo sits **in front of** the biometric gate: it has no token, no server and
nothing to protect, and App Review's device has no enrolled face. `RootView`
tests `pairing.isPaired` **first**, and that ordering is the guarantee — even if
something handed the app both states at once, a real board still lands in the
gated branch. The gate on the paired board is untouched.

Two ways out, on every tab: `leave the demo` on the connection strip, and the
board's overflow menu (where `Unpair this device` lives on a real board). The
Server tab's destructive button becomes `leave the demo and pair your Mac`,
because that is where somebody looks for "how do I connect a real Mac". And the
demo never blocks the real flow: scanning the Mac's QR with the system camera
while the demo is open drops the demo and pairs.

### The fleet itself

Six worktrees of a fictional storefront — `search-index`, `payments-webhook`,
`checkout-flow`, `api-gateway`, `release-notes`, `design-tokens` — one card in
each of the board's five sections, all six session statuses, ages from nine
seconds to twenty-two hours, and a conversation for every one of the eight
sessions. It also carries, on purpose, the three wire edges this client learned
the hard way, so the demo exercises the fixes rather than a happy path: a session
with **no `turn_ended` key at all**, a worktree with **null `ahead`/`behind`**
(rendered `no upstream`, never `↑0`), and `tool_running` present only when true.
The limited card and the exhausted account on the Limits screen name the *same*
reset instant, and the armed auto-resume is due a minute after it — a test pins
both, because a demo that teaches a wrong join is worse than no demo.

### The defect a screenshot found, again

`ORC_SCREEN=demo:limits` **landed on the board.** The tab seam
(`tab = route.tab`) sat below the new `guard !model.isDemo` in the paired view's
`.task`, so entering the demo returned before the tab was ever selected.
Everything compiled, the demo was correct, and the one seam the screenshot job
depends on quietly did nothing. Moved above the guard. The same run found the
connection strip truncating its own sentence to `nothing here is re…` — the one
line on that bar that has to be readable — fixed by letting the demo caption take
two lines, which the bar already handles because its height is *measured*.

### Not done in phase 5, and honest about it

- **`docs/mobile/APPSTORE.md` is not updated by this branch.** It does not exist
  in this worktree (it lands from another branch), and §7's review-notes block is
  a counted 3,938 characters — editing it blind would break the count. The
  feature matches what §7 already promises: the entry point is on the first
  screen, below the pairing options, labelled exactly `explore the demo fleet`,
  and it sits before the Face ID gate.
- **Pairing *from inside* the demo has no in-place form.** Leaving the demo is
  one tap and restores the real pairing screen intact, and a QR scanned by the
  system camera pairs straight through — so the demo never blocks the real flow.
  What it does not have is a pairing form rendered over the demo board, which
  would be a second copy of the one screen that must not have two.
- **Push cannot be demonstrated at all**, and the notification preferences say
  so: the sender is the user's own Mac. The screen renders in full and every
  control on it is disabled with the refusal at the top.

### Not done, and honest about it

- **The notification-service extension.** `IOS-APP.md` §1.2 lists
  `OrchestraNotificationService`; it is the sanctioned home for stamping the
  `ORC_REPLY` category onto a payload (finding P1) and for enriching a
  `structural` body from `/api/v1/events/<id>` over the tailnet. It is a new
  Xcode target — a hand-edited `.pbxproj`, the most fragile change in this
  directory (`Package.swift`) — and it is additive, so it is left for its own
  step rather than risked against a green build whose gate is "xcodebuild
  succeeds". The app registers the category and handles the reply today; the
  extension (or the one-line server `aps["category"]`) is what makes the reply
  field appear on a production push.
- **A settings read-back route, quiet-hours DST correctness beyond the offset,
  and the widget / Live Activity surfaces of `IOS-APP.md` §1.2** — all additive.

## Phase 6 — the full transcript

The ask, in the user's words: *"I want to see just as much on the phone as one
can see in a real terminal window with Claude Code running. If I go down to that
level, I want to know the details. I want to be able to scroll through the
entire output. Ideally we make it still kind of pleasant to look at."*

### What it does

A **pushed reading screen** (the `full log` button in the chat screen's
toolbar), not a mode of `ChatView`. `ChatView` is the acting surface — composer,
receipts, refusal copy — and it is proven; this wants the whole screen height,
its own bottom-anchored scroll and its own filter, and a second bottom-pinned
control inside a pushed destination is the defect this project has already hit
twice.

Two requirements in tension — **completeness** (nothing unreachable) and
**readability** (a raw terminal dump on a 6" screen is unreadable) — resolved
the way a good log viewer resolves it: *everything is present, structure decides
what is open.*

* `user` / `assistant` prose is **expanded**; `tool_use` / `tool_result` are
  **folded** to one dense line carrying the argument you recognise the call by
  and the size of what is behind it (`Read  search/index/shardmap.py · 4,708 ch`).
  A terminal dumps five hundred lines of a file read at you; this offers them.
* `meta` — system reminders, harness text, thinking blocks, inlined subagent
  work — is **hidden behind one toolbar toggle**, off by default, and the strip
  under the title says how many entries the toggle is holding, so hidden never
  reads as absent.
* A 3 pt left rail carries the role colour in the board's own language: `user`
  cyan, `assistant` sage, `tool_use` amber, `tool_result` grey, `system`/`meta`
  disabled and dimmed. Body in IBM Plex Mono, Dynamic Type throughout.
* An expanded tool block **does not wrap** — command output, diffs and code are
  column-aligned and wrapping destroys the alignment that makes them readable —
  so each one is its own horizontally scrollable container. **The page itself
  never scrolls sideways.**
* **Truncation is stated in both numbers and the button fetches.**
  `· cut at 4,000 of 12,431 — show all` re-reads the line from
  `/messages/at/{off}?i=` with a 256 KB ceiling instead of 4,000 characters.
  The chat drawer's `show full` only ever un-clamped a `lineLimit` on text the
  server had already dropped; it is now offered ONLY for text that merely looks
  long, and a bubble the server cut offers `open the full log` instead.
* Opens at the newest entry; scrolling up loads older by `cursor_before` about a
  screen before the reader runs out of window, holds their line still to the
  point while the page lands, and stops at `— start of transcript —` when byte 0
  was actually reached. The trigger is a pure rule (`TranscriptRules.topReach`)
  and it disarms itself on every fetch, because the first version of this screen
  put the reader back on its own tripwire — see "The defect a phone found: a
  loader that spun forever".
* **Auto-scroll only when the reader is already at the bottom.** Scrolled up
  into history, new output is offered as a `↓ N new` pill and the view does not
  move. It is a pure function (`TranscriptRules.follow`) with a test, because it
  is the one interaction people notice immediately when it is wrong.

### Driven against the real wire, on a 103 MB transcript

`python3 -m orchestra --port 4297`, a real device token, and
`~/.claude-account6/projects/…/60971837-….jsonl` — **103,839,151 bytes**:

```
page  1:  30 msgs  cursor=103647926  more=True
page  2:  30 msgs  cursor=103494098  more=True
page  4:   8 msgs  cursor=98377448   more=True     <- fewer than `limit`
page  8:  12 msgs  cursor=90024343   more=True
...
12 pages, 294 unique messages, ordered=True, 0.22 s total
```

* **A page returns fewer than `limit` and that is normal, not the end.** Four of
  twelve pages did (8, 22, 12, 12) — a page takes whole LINES only, because
  `cursor_before` is a byte offset and half a line has no offset to name. A
  client that reads a short page as "we are done" stops mid-transcript with no
  error anywhere.
* No duplicates and no gaps across the whole walk: `before` is exclusive.
* `/messages/at/{off}?i=` returned the same message uncapped — 4,923 characters
  against the paged route's 4,000 — with `truncated: false`.
* Every refusal string the client branches on was produced for real:
  `unknown account nope`, `need account & sid`, `bad limit`, `bad before`,
  `bad format`, `no entry at that offset` — all of them **200**, like
  `/api/chat`.
* Over 685 real messages the wire emitted exactly three key sets and no
  surprises: `tool` present on 512, `why` on 109, neither on 64. `tool.name` is
  genuinely `null` on the wire (a result whose call fell outside the read
  window) and `tool.ok` is genuinely `null` on every call — the two nullables
  that would have been easiest to model as non-optional and wrong.

### What the wire does that the brief did not predict

| # | claim | what the server does |
|---|---|---|
| 44 | `mtime_ns` is a timestamp like any other on this wire | it is ~1.78 x 10^18 — nanoseconds, not seconds. It fits `Int64` with room, but it is 10^9 times the epoch every other clock here uses, and a `Double`-typed model would lose exactly the low digits that make it a change detector |
| 45 | a Claude-home label needs no escaping | this ROUTE percent-decodes (`_query` -> `parse_qs`), unlike `/api/chat`'s raw-path `re.search` (finding 22) — so it is the first route where the client MUST encode, and `URLComponents.queryItems` is not enough: it leaves `+` literal and `parse_qs` reads a literal `+` as a space. `Endpoint.strictQueryEncoding` encodes down to the RFC 3986 unreserved set for these two routes only, because encoding the OLDER routes would break the case that works today |

### The two defects a screenshot found

Both compiled, both rendered, both were quietly wrong.

**The screen opened five rows above its newest entry.** One `scrollTo` is not
enough with a `LazyVStack`: rows below the viewport have never been laid out, so
the scroll view works from ESTIMATED heights and lands short, then materialises
the rows that change the content size under the scroll it just finished. It is
now re-asked after each layout pass (`TranscriptView.toBottom`), which converges
and is a no-op once it has arrived. The same bug had a second face: the top
marker is briefly on screen during the first layout, so page two is prefetched
at once, and the prepend used to restore the OLD top — putting a freshly opened
transcript halfway up itself.

**The newest entry sat under the connection strip.** The third time this project
has hit the same shape: a pushed navigation destination does not receive the
`safeAreaInset` the tab applied outside the `NavigationStack`. And the obvious
fix was wrong too — `.padding(.bottom, accessoryHeight)` on the `LazyVStack`
sits BELOW the scroll anchor, so `scrollTo(.bottom)` stops with the anchor at
the viewport edge and the last entry is behind the strip anyway. The inset has
to BE the anchor: the bottom spacer is `Space.md + accessoryHeight` tall.

### The defect a phone found: a loader that spun forever

> *"when i scroll up to the top of the full log, it keeps 'loading older …' but
> they dont seem to actually appear"*

**Everything upstream of the screen was correct.** A real 103 MB transcript
walked twenty pages over the wire with the cursor advancing every time,
`has_more_before` true throughout and not one empty page; every page carried
visible (non-`meta`) content — 29/30, 30/30, 27/30, 5/8; `TranscriptRules.prepend`
deduped and prepended in order; `TranscriptStore.applyOlder` moved `entries`,
`hasMoreBefore` and `cursorBefore` correctly. **Pages arrived. The reader could
not get to them.**

The trigger was an `.onAppear` on the `loading older…` row, which is the first
child of the `LazyVStack`, and the restore that followed the fetch was
`proxy.scrollTo(store.visible.first?.id, anchor: .top)` — the oldest entry the
window ALREADY held, which is the row immediately below that same trigger. So
every user-driven load put the reader back **on the tripwire**, with the page
that had just arrived stacked above the viewport, and the next flick upwards
tripped it again before a line of it could be read. Worse, once parked there the
marker never left the lazy stack's realisation window either, so `.onAppear`
stopped firing at all: the loader kept saying `loading older…` — that row said it
whenever there was more file behind it, in flight or not — and nothing more was
ever fetched.

**Measured, not reasoned about.** `ORC_TRANSCRIPT=climb` drives the scroll view
itself, one viewport per step, through the same `ScrollPosition` the restore
writes; it calls no paging API. Forty steps up the same 103 MB transcript, same
build, same server, the only difference being which trigger was compiled in:

| | pages fetched | entries held | oldest byte reached | longest run pinned to one row |
|---|---|---|---|---|
| `.onAppear` + boundary restore | **1** | 60 → 98 | 103,494,098 → 98,377,448 | **29 of 40 steps**, `above=12`, anchor `98378118/0` every time |
| geometry trigger + point restore | **4** | 60 → 158 | 103,494,098 → 96,920,877 | 1 |

Sixty steps with the fix: **17 pages, 60 → 427 entries, back from byte
103,494,098 to byte 67,003,779 — 36.5 MB of the file walked, the oldest offset
strictly decreasing at every load**, and 53 distinct entries at the top of the
screen across 61 samples. The old trigger's own numbers are the bug report: the
same `above`, the same anchor, twenty-nine times running, while the row said
`loading older…`.

**Three changes, and the rule is a value.**

* **The trigger is scroll geometry, not a row's lifecycle.**
  `TranscriptRules.topReach(offsetFromTop:armed:hasMoreBefore:loading:)` is a
  pure function with eleven tests. It fires a page **900 pt before** the top —
  so the fetch overlaps the reading instead of interrupting it — **disarms
  itself when it fires**, and re-arms only on evidence the reader consumed what
  arrived: either 2,200 pt clear of the top (the page that landed is between
  them and it) or hard against the top. `rearmMargin > prefetchMargin` is the
  hysteresis; the second leg is not a loophole in the first but the case the old
  screen was refusing to answer, because a page can be eight entries of folded
  tool traffic and "travel 2,200 pt clear" is then something the reader cannot
  do. Ten of the seventeen pages in the sixty-step climb came through that leg.
* **The restore is in points, not rows** — iOS 18's `ScrollPosition.scrollTo(y:)`
  against the content-height delta. A reader is generally in the MIDDLE of an
  entry (an assistant turn here is routinely taller than the phone), so "scroll
  to the row that used to be at the top" is exact only at a row boundary, which
  is precisely the position the old trigger produced and precisely what made it
  re-fire. Measured across four landings: asked for `above` 509 / 827 / 0 / 893
  and got 509 / 839 / 0 / 893 back — **the reader's line held to about 12 pt.**
  The baseline is re-banked on every scroll event until the window actually
  grows, because a `LazyVStack` revises `contentSize` by ±1,500 pt on its own as
  it realises rows and a stale baseline would measure that churn as page height.
* **The marker says what is true.** `loading older…` only while a fetch is in
  flight; `↑ older output above` otherwise; `— start of transcript —` at byte 0.
  A reader who has genuinely stalled must not see what a reader who is waiting
  sees — that identity is half of why this took a phone to find.

**What did not change, and was re-driven to prove it:** the screen still opens at
the newest entry (the first page's prefetch fires during the opening layout and
is still resolved by going to the bottom, not by holding a position); the
`↓ N new` pill still offers new output rather than applying it; and the
`top`/`tools`/`all`/`noise`/`fail` seams still press what they pressed.

### The live tail, finally watched against a file that grows

`ORC_TRANSCRIPT` and a synthetic session assembled from real records (rewritten
`sessionId`, appended to while the screen was open) close the gap this document
listed as open. Both halves, on a real server:

* **Scrolled up at `— start of transcript —`**, three messages appended: the
  window went 20 → 23 entries, the pill read **`↓ 3 new`**, and the screen did
  not move a pixel — the same rows, in the same places, before and after.
* **At the newest entry**, three more appended: they arrived at the bottom with
  no pill, exactly as `TranscriptRules.follow` says they should.

### One deliberate deviation from the design spec

The spec asks for an expanded tool block to have "a bounded height and its own
vertical scroll". It has the bounded height and the horizontal scroll; the
vertical half is a **line budget** instead (40 lines, with
`chevron.down  320 more lines` to lift it). A bounded vertical scroll view
nested inside the page's own vertical scroll captures the gesture on iOS and
traps a thumb inside a code block — the reader's scroll simply stops working,
which is worse on a phone than any amount of length. Growing the page and
letting the page's one scroll view carry it reaches the same bytes with no
gesture conflict, and the horizontal axis — the one the page must never have —
is still the block's own.

### Not done, and honest about it

- **`format=clean` is never requested.** The screen asks for `raw` always,
  because newlines are the entire point of it. `clean` is on the wire and the
  client can send it; nothing in the UI offers it, because "the same text with
  its structure removed" is not a reading mode anybody wants here.
- **No search, no jump-to-time, no share.** A 103 MB transcript is exactly where
  "find the line where it broke" is worth having, and the route has no `after=`
  or `q=` to build it on: a client-side search can only see the pages it holds,
  which would be a search that silently means "search what you scrolled past".
  It wants a server-side one.
- **The live tail is a poll of the newest page, not a stream.** The route pages
  BACKWARDS only, so following a live session means re-reading the newest page.
  The cost is kept honest by probing with `limit=1` first and fetching a real
  page only when `file.size` moved. A hole — more output between two polls than
  one page holds — is detected (`TranscriptRules.tail` -> `.gap`) and never
  stitched shut; the pill says `new output` rather than a count it cannot know.
  The `.gap` branch is still only ever driven by a test — producing one needs
  more output between two polls than a thirty-entry page holds.
- **A compaction was never observed live.** The inode/dev reset is driven by a
  test and by the store's own seam, not by a real `/compact`.
- **The bounded window trims only at the old end and only while the reader is at
  the newest entry**, so a reader parked in the middle of a very long transcript
  holds every page they walked. 900 entries is the ceiling; nothing evicts under
  a thumb. A sixty-step climb reached 427 held entries, so the trim itself has
  still not been observed — it needs a reader who walks back 900 entries and then
  returns to the newest one.
- ~~**The live tail was never watched against a growing file.**~~ **Watched** —
  see "The live tail, finally watched against a file that grows". What was
  appended was real records with a rewritten `sessionId`, not a live agent
  typing, so the *cadence* under a busy agent (the 5 s branch, the `.gap`
  detection) is still only pinned by tests.

## Phase 7 — a screenshot from the phone lands on the Mac

> *"we should also be able to upload images through the launch and chat
> dialogues. I often have to send screenshots… the intuitive solution would be to
> have this file get uploaded to a specific folder on the machine where the
> orchestra backend is running, and then give the path to that file in the chat.
> That's how images are usually inserted into Claude sessions — when I drag an
> image from my desktop into a Claude session in a terminal, it just takes the
> path of the image."*

The server half shipped first (`orchestra/uploads.py`): `POST /api/v1/uploads`
takes base64 in a JSON body, sniffs the type from the magic bytes, names the file
`sha256(bytes)[:16]` and writes it to `~/.orchestra/uploads/<YYYY-MM-DD>/`. This
is the phone half.

### The path is the attachment, and there is nothing else

**The uploaded path goes into the draft as plain text.** Not an attachment
object, not a chip carrying a parallel representation. One source of truth, and
everything falls out of it:

* the draft persistence already stores text, so an attachment survives
  backgrounding and the Face ID re-lock exactly like the words around it;
* the send path already types text;
* Claude Code reads a path off disk, which is what dragging a file into a
  terminal session does.

The thumbnail strip is therefore **derived by parsing the draft**
(`Rules/UploadRules.swift` — `UploadPath.paths`), and deleting the path from the
text deletes the attachment with no bookkeeping anywhere that could disagree. A
separate attachment model would have needed separate persistence, separate
serialisation and separate syncing with the text — three new ways to lose the
user's screenshot.

The tiles are drawn from the **local** image the user picked, cached in memory by
path (`Store/UploadStore.swift`, twelve entries). A path whose picture is not in
the cache — a draft restored after a cold launch — draws a plain tile with the
file's name on it. There is no download route and none was invented.

### The two numbers, and why a screenshot is never resampled

Screenshots are the use case, and the requirement they impose is that 11 pt UI
text survives the round trip. `Sources/Orchestra/Media/ImagePrep.swift`:

| knob | value | why |
|---|---|---|
| `longEdgeCap` | **3024 px** | above *every* current iPhone screenshot's long edge — 2796 (15/17 Pro Max), 2868 (16 Pro Max), 2622 (16 Pro), 2556, 2532 — so a screenshot is never resampled. Resampling is what destroys small text; a cap that sits above the tallest screenshot means the question never arises. A 12 MP camera frame (4032 long) is a scene rather than a screen, and 3024 px still reads a whiteboard |
| `jpegQuality` | **0.9** | edges on 8-bit type survive; a 3024 px frame lands at ~1–2 MB instead of the ~9 MB a 1.0 baseline encode costs |

**And the format rule, which matters more than either number.** PNG, JPEG, GIF
and WebP are exactly the four the reader at the far end accepts, so one of those
that is already inside budget is sent **byte for byte**. An iOS screenshot is a
PNG, so the primary case never touches a lossy encoder at all. HEIC and HEIF are
*always* transcoded — that is the whole reason the file exists, since iPhones
shoot HEIC by default and the server deliberately does not transcode. Anything
over the cap in pixels or bytes goes down a four-rung ladder until it fits; if
the bottom rung still does not, it is refused **locally**, with a sentence.

An animated GIF is passed through on its byte budget alone, ignoring the pixel
cap, and refused rather than shrunk when it does not fit: a transcode would take
frame zero and silently drop the animation.

### Proven against the real server, 2026-08-06

A 1320×2868 screenshot **of this app's own board**, taken with
`xcrun simctl io booted screenshot`, uploaded from the simulator's chat composer
through the live server on `127.0.0.1:4242`:

```
$ shasum -a 256 /tmp/orc-src-screenshot.png
e081f7c1df0b35e60352aac458b9cb2d019467c20bae3bc09889f2c54e5d9b05

$ ls -l ~/.orchestra/uploads/2026-08-06/
-rw-------  1 achill  staff  580735  e081f7c1df0b35e6.png

$ cmp /tmp/orc-src-screenshot.png ~/.orchestra/uploads/2026-08-06/e081f7c1df0b35e6.png
        # (no output — byte-identical)

$ tail -1 audit.log.jsonl
{"at": 1786014958.9, "bytes": 580735, "device": "1b98a7ce", "duplicate": false,
 "event": "upload", "kind": "png", "name": "e081f7c1df0b35e6.png",
 "peer": "100.113.110.31"}
```

The filename **is** the digest of the source file, which is the passthrough
proving itself: the content-addressed name could not match unless the bytes did.
The path `/Users/achill/.orchestra/uploads/2026-08-06/e081f7c1df0b35e6.png` was
in the composer's text field a moment later, with a thumbnail above it.

The **transcode** path was driven with a HEIC of the same screenshot
(`sips -s format heic`). It came back 1320×2868 — the long edge is under the cap,
so no resample — as a 431,932-byte JPEG. Cropped to the densest small text on the
board (11 pt IBM Plex Mono pids and paths in `OTHER AGENTS`) and blown up 2× with
nearest-neighbour, the transcoded JPEG and the original PNG are indistinguishable
glyph for glyph.

Also driven live: the progress bar (**`uploading 26%`**, from `URLSession`'s own
`didSendBodyData`, an 8.6 MB PNG through a deliberately rate-limited proxy), and
a real server refusal shown verbatim — *"the upload could not be written to
/tmp/orc-scratch-home/.orchestra/uploads/2026-08-06: Not a directory."* — with
the draft untouched beside it.

### Decisions worth stating

- **No `Idempotency-Key`, deliberately.** The route is absent from
  `idem.MUTATION_ROUTES` because it does not need one: the filename is the
  content's own digest, so a retry lands on the same path and writes no second
  file. That is exactly the property a key would buy, without the server storing
  a response for an hour. `Endpoint.upload` is therefore **not** built through
  `Endpoint.mutation`, and `FixesAPITests.mutations()` excludes it by name.
- **The size is checked before the request, not after.** `UploadBudget` does the
  server's own arithmetic — `(n + 2) / 3 * 4 + envelope` — and `bodyBytes` is
  pinned by a test against the actual body `Endpoint.upload` builds. The cap is
  **13,985,112 bytes** at the default `upload_max_mb: 10`. A 14 MB request is
  never fired at a Mac over a tunnel to be told 413.
- **No camera source.** `PhotosPicker` and `.fileImporter` only. A simulator has
  no camera, so nothing about a camera path could be verified the way the rest of
  this app is — and leaving it out keeps `NSCameraUsageDescription` true as
  written (it still only mentions the pairing QR). `NSPhotoLibraryUsageDescription`
  is new; there is no `NSPhotoLibraryAddUsageDescription` because this app only
  ever reads a picture, never writes one back.
- **Demo refuses at the tap**, before a picker opens, in `DemoCopy.refusal`'s own
  words, with the paperclip still visible — a reviewer is here to see that the app
  can attach a picture. `UploadStore.attach` refuses too: the control is the
  courtesy, the store is the guarantee.

### The crash a simulator found

The first real upload took the app down: `EXC_BREAKPOINT` in
`_StringGuts.validateInclusiveSubscalarIndex_5_7`. SwiftUI's `TextSelection`
carries a `String.Index`, and a `String.Index` belongs to **the string it was made
from** — the selection the field reports and the text the binding holds are two
different values whenever one has moved and the other has not, which is exactly
what a draft hydrated from `DraftStore` on appear does. Measuring a foreign index
whose offset is past the end is not a wrong answer, it is a trap.

Comparing indices is safe; measuring is not. `DraftAttachment.caret` bounds-checks
with comparisons and returns `nil` — *append* — for anything it cannot measure.
It lives in `Rules/` rather than in the view because a rule that crashed once
belongs where a test can reach it (`aCaretFromAnotherStringIsNoCaretRatherThanACrash`).

### Not done, and honest about it

- **The caret restore is best effort.** The insert goes in at the caret when
  SwiftUI reports one, and the selection is written back past what was inserted;
  but assigning a bound `String` is itself what moves a caret to the end, and
  whether the write takes is SwiftUI's business. Every path falls back to
  *append*, which is the behaviour the empty-composer and end-of-text cases —
  i.e. almost all of them — produce anyway.
- **The photo library was never picked from by a finger.** `ORC_UPLOAD=photos`
  presents the system sheet and it was looked at; choosing a real asset, and with
  it `PhotosPickerItem.loadTransferable` against an iCloud-Photos-optimised
  original, needs a device.
- **The camera and a real HEIC off a real sensor.** The HEIC that was transcoded
  end to end was made with `sips`, not shot by a phone. The brand table
  (`mif1`-major stills, depth-effect photos) is pinned by tests, not by a camera.
- **413 and 415 have named sentences but were not driven.** The client's own
  precheck makes 413 unreachable without a server whose `upload_max_mb` is lower
  than this build's default, and 415 would be a bug in this build.
