# App Store submission pack — orchestra for iOS

Everything App Store Connect asks for, written out and ready to paste. Bundle id
`sh.orchestra.app`, deployment target iOS 18.0, one app target, zero third-party
dependencies (`ios/Package.swift` declares `dependencies: []`, and the `.pbxproj`
references no Swift package and no embedded framework — the binary links Apple
frameworks only).

Screenshots are **not** in this document; they are a separate job.

Two hard blockers are named in [before you can submit at all](#before-you-can-submit-at-all).
Read that section first — one of them is a one-line `Info.plist` entry that is
correct for this Mac and wrong for every other user's.

---

## 1. name, and whether we can have it

### the name we want

**`orchestra`** — 9 of the 30 characters App Store Connect allows.

### what the store actually contains today

Searched the US storefront (iTunes Search API, `entity=software`, 43 results;
plus a manual look at the near-misses). **No app is listed under the exact name
`orchestra` or `Orchestra`.** The nearest neighbours:

| listed name | seller | category |
|---|---|---|
| `Orchestra / orch.so` | Orch Inc. | Productivity |
| `The Orchestra` | NatureGuides Ltd. | Music |
| `Orchestra Studio` | ORCHESTRA STUDIO | Music |
| `i-Orchestra` | Lee Cheng | Music |
| `Orchestra PS` | Tareq Ajloni | Shopping |
| `Spatial Orchestra` | TCW | Music |

Also present: a *developer* (seller) named "Orchestra", `id1201785742`. A seller
name is a separate namespace from an app name and does not block us.

`Orchestra / orch.so` is the interesting one — a productivity app that appended
its domain to the word, which is the classic tell that plain `Orchestra` was
already unavailable to them, *or* that they wanted the domain in the title. We
cannot tell which from outside.

### the caveat that matters

**A public search cannot prove the name is free.** App names are reserved the
moment an app *record* is created in App Store Connect, the reservation holds
while the app is unreleased, and reserved names never appear in App Store
search. The only authoritative test is typing `orchestra` into the "Name" field
when creating the app record: App Store Connect either accepts it or says *"The
App Name you entered is already being used."*

So: **try `orchestra` first, in App Store Connect, before doing anything else.**
It costs one minute and it decides the rest of the metadata.

### fallbacks, in order of preference

| # | name | chars | notes |
|---|---|---|---|
| 1 | `orchestra` | 9 | first choice |
| 2 | `orchestra — agent fleet` | 23 | em dash; reads as a subtitle, keeps the word first, and the extra words are indexed for search |
| 3 | `orchestra fleet board` | 21 | no punctuation to get mangled; "board" is the product's own word for the main screen |

Do **not** put "Claude Code" in the app name. It is Anthropic's trademark and a
name containing another company's mark is a routine 5.2.1 rejection. Referring
to it *factually in the description* ("shows the Claude Code agents running on
your Mac") is a different thing and is normally fine — see
[risks](#8-known-rejection-risks-and-the-answer-to-each).

The **home-screen name** (`CFBundleDisplayName`, already `orchestra`) has no
uniqueness requirement and does not need to change even if the store name does.

---

## 2. the text fields

### subtitle (max 30)

```
mission control for agents
```
26 characters.

Alternates, all within 30:

| subtitle | chars |
|---|---|
| `watch your agent fleet run` | 26 |
| `your agent fleet, on your Mac` | 29 |
| `the board for your agents` | 25 |

### promotional text (max 170)

Editable at any time without shipping a build — use it for whatever is newest.

```
Your agents are running on your Mac. orchestra shows which one is working,
which one is waiting on you, and which one hit a limit — and lets you answer
from your phone.
```
168 characters as one paragraph — the line breaks above are for reading only,
and the em dash is one character. There are 2 characters of headroom, so any
edit here needs re-counting.

### description (max 4000)

Paste as plain text. The App Store does not render Markdown — the section labels
below are plain lines, not headings, and there are no asterisks.

```
orchestra shows the Claude Code agents running on your own Mac.

You're running several agents at once, in different worktrees, on different
accounts. One is working. One is waiting for an answer you never gave it. One
quietly hit a usage limit an hour ago and has been parked ever since. orchestra
puts all of them on one board on your phone, sorted so the one that needs you is
at the top.

ONE BOARD
Every worktree is a card: branch, uncommitted files, ahead/behind, last commit,
live processes, and every recent session tagged with its account, model, age and
three lines of context — the last thing you told it, the last thing it said, the
latest subagent report. Colour carries the state: green is working, orange needs
you, yellow is a usage limit, cyan is free. The header names the worktrees that
are free, so "where does the next agent go?" is answered before you ask.

ANSWER FROM ANYWHERE
Open a session and the conversation is there, read from the agent's own
transcript. Type a reply and it is typed into that agent's terminal on your Mac.
When an agent asks you something, the notification carries a reply box — answer
from the banner without opening the app.

START WORK
Describe a mission and orchestra routes it: the cleanest free worktree, the
account with the most headroom for the model you chose. Your words are passed to
the agent verbatim, never rewritten. Model and effort are yours to pick —
nothing guesses how hard your mission is.

FINISH WORK
One button does exactly as much closeout as is left: brief the agent, verify the
landing, park the worktree back on the trunk.

SEE THE LIMITS
Every account side by side — headroom, per-limit usage bars, reset countdowns,
and which account has room for the next agent. An agent parked on an exhausted
account says so, instead of pretending it is waiting for you. Arm an auto-resume
and it continues itself the moment the limit clears.

THE MAP
Every branch at its true git position: where it left the trunk, how far its tip
has run, how far behind it has fallen. A tip short of the right edge is a branch
that stopped moving.

HOW IT CONNECTS
orchestra talks to exactly one machine: your Mac, over your own Tailscale
network. There is no orchestra account and no server of ours anywhere in the
path. Pairing is a QR code shown on your Mac; the code it carries is good for
120 seconds and once only. The device token it mints is stored in your iPhone's
Keychain and can be revoked from the Mac at any time. Face ID unlocks the board.

WHAT YOU NEED
• a Mac running the orchestra server — it is open source and installs nothing
  (python3 standard library only): github.com/acrdlph/orchestra
• Tailscale on the Mac and the phone
• Claude Code agents worth watching

NO MAC HANDY?
Tap "explore the demo fleet" on the first screen. The entire app runs on
fictional data — every screen, every colour, every state — with no server, no
pairing and no network.

orchestra is free, has no ads, no accounts, no analytics and no in-app
purchases. Claude and Claude Code are trademarks of Anthropic; orchestra is an
independent project and is not affiliated with or endorsed by Anthropic.
```

### keywords (max 100 characters, comma-separated, no spaces)

Apple already indexes the app name and subtitle — do not repeat words from
either. `agents`, `mission`, `control`, `orchestra` are therefore spent.

```
worktree,git,branch,tailscale,tailnet,terminal,tmux,fleet,coding,devtools,monitor,dashboard,remote
```
98 characters.

Note on `claude`: it would be the single highest-traffic keyword here and it is
also the one that can get the metadata rejected — Apple's keyword rules forbid
trademarked terms you do not own, and it is enforced unevenly. The set above
deliberately omits it. If you want to try it, put it in **last** so a metadata
rejection costs one edit and no build —
`worktree,git,branch,tailscale,tailnet,terminal,tmux,fleet,coding,devtools,dashboard,claude`
(90 chars, `monitor` and `remote` dropped to make room). Expect it to be the
thing that gets flagged.

### what's new (max 4000) — for 1.0

```
First release.
```

---

## 3. categorisation, URLs, and the rest of the App Information page

| field | value |
|---|---|
| **Primary category** | Developer Tools |
| **Secondary category** | Productivity *(optional; Utilities is the alternative — Productivity is the better neighbourhood for a "board you check")* |
| **Support URL** | `https://github.com/acrdlph/orchestra` |
| **Marketing URL** | *(optional — leave empty until there is a page that is not the repo. Pointing it at the same repo adds nothing and Apple does not mind an empty field.)* |
| **Privacy Policy URL** | `https://github.com/acrdlph/orchestra/blob/main/PRIVACY.md` |
| **Copyright** | `2026 acrdlph` |
| **Price** | Free |
| **Availability** | All territories |
| **Content rights** | Does not contain, show, or access third-party content |
| **Sign-in required** | No |
| **Contact for review** | your name, email and phone — Apple uses it if the review stalls |
| **Bundle ID** | `sh.orchestra.app` |
| **SKU** | `orchestra-ios` *(internal only; never shown)* |
| **Version** | `1.0` — bump `MARKETING_VERSION` from `0.1` before archiving |
| **Licence** | MIT (server and app) |

The privacy policy URL is **required for every app**, including apps that
collect nothing (guideline 5.1.1). It is also required to be reachable *from
inside the app* — see [before you can submit at all](#before-you-can-submit-at-all).

---

## 4. age rating — 4+

The questionnaire was overhauled in 2025; the tiers are now **4+, 9+, 13+, 16+,
18+** (12+ and 17+ are gone), and the new questionnaire has been mandatory since
31 January 2026. Answer the current one, not the one you remember.

### content questions

Every content question — violence, sexual content, profanity, horror, gambling,
alcohol/tobacco/drugs, medical/treatment information, mature/suggestive themes —
is **None**. There is no such content and none can appear: the app renders git
metadata, process state, usage numbers, and text from the user's own machine.

### capabilities questions — the ones that need thought

| question | answer | why |
|---|---|---|
| **Messaging and Chat** | **No** | The app has a screen called "chat", and a reviewer will see it. It is not interpersonal messaging: it is a keyboard attached to a terminal on the user's own Mac. There is no other user at the far end, no directory, no way to reach any human. Say this explicitly in the review notes so the "No" is not read as a miss. |
| **User-Generated Content** | **No** | Nothing is submitted to, hosted by, or redistributed from any service. The only text displayed is the user's own prompts and their own agents' replies, read from files on their own Mac. No feed, no discovery, no content from strangers, nothing shared. |
| **Social Media / social feed** | **No** | (July 2026 addition.) No feed, no follows, no amplification of anyone's content. |
| **Unrestricted Web Access** | **No** | There is no browser and no web view — no `WKWebView`, no `SFSafariViewController`. The single `openURL` call in the app opens iOS Settings so the user can change the notification permission. |
| **In-app controls / parental controls** | Not applicable | No purchases, no content feed, no communication to gate. |
| **AI / generative content** | Disclose accurately | Text shown in the chat screen is produced by an AI agent the *user themselves* is running on their own machine, on their own account, from their own prompts. It is not a chatbot the app provides and there is no model call anywhere in the app. This does not raise the rating on its own, but Apple's current guidance is that AI-surfaced content counts toward how often sensitive content can appear — the honest framing is "displays output from the user's own local tooling", and it belongs in the review notes too. |
| **Advertising** | None | |
| **In-app purchases** | None | |
| **Gambling / contests** | No | |
| **Frequent/Intense anything** | No | |

**Result: 4+ in every storefront.**

---

## 5. App Privacy — the questionnaire, answered

### the answer

> **Data Not Collected.**

Select "No" to *"Do you or your third-party partners collect data from this
app?"* and the section is complete.

### why that is the accurate answer, not the convenient one

Apple defines it precisely:

> "Collect" refers to transmitting data off the device in a way that allows
> **you and/or your third-party partners** to access it for a period longer than
> what is necessary to service the transmitted request in real time.

Three things follow, and each one has to hold:

1. **There are no third-party partners.** The binary links Apple frameworks
   only — `ios/Package.swift` declares `dependencies: []` and the Xcode project
   references no Swift package and no embedded framework. No analytics SDK, no
   crash SDK, no attribution SDK, no ad SDK. Nothing to disclose on anyone
   else's behalf.
2. **The developer operates no server.** The app has exactly one network peer:
   an HTTP server the *user* runs on their *own* Mac, at their *own* tailnet
   address, which they typed into the app themselves by scanning their own QR
   code. There is no orchestra backend, no hosted endpoint, no telemetry
   destination. Data reaching that server has not been transmitted anywhere
   "you… can access it" — the developer cannot reach the user's Mac and has no
   credential for it.
3. **APNs is Apple, not us.** Push notifications originate on the user's own
   Mac, which holds the developer's APNs key, and are handed to Apple for
   delivery. That is the delivery mechanism Apple itself provides and requires;
   the developer never sees a payload, a token, or a delivery record.

### the nuance you asked about: the push token and device name on the user's Mac

When a device pairs and enables push, the user's own Mac stores, in
`devices.json` on that Mac: a device label the user typed, the SHA-256 of the
device token, the APNs device token, the phone's time zone, the app version, and
a `last_seen` timestamp.

That is real data about a device. It is still **not "collected"** under Apple's
definition, for one reason that is worth stating in one sentence so it can be
repeated verbatim if Apple ever asks:

> The data never reaches the developer or any partner of the developer — it is
> written to a file on hardware the user owns, administers, and can delete,
> by software the user runs themselves.

This is the same posture as any self-hosted client (an SSH client, a
self-hosted media client, a home-automation client): the app talks to *your*
server, so *your* server's storage is not the developer's collection.

**Recommendation: answer "Data Not Collected", and do not over-declare.**
Declaring "Identifiers → Device ID" here would be *inaccurate in the other
direction* — it would tell users on the product page that a device identifier is
being collected by the developer, which is false, and Apple's nutrition label is
supposed to describe what the *developer* does. Over-declaration is not a safe
default; it is a different wrong answer.

What makes this defensible is that it is **written down publicly** in `PRIVACY.md`
and in the review notes, so the claim and the reasoning are on the record before
anyone asks.

### the conditions under which this answer stops being true

Re-open this section the day any of these happens:

- a crash-reporting, analytics or attribution SDK is added (then: Diagnostics,
  and probably Identifiers);
- orchestra ever ships a hosted relay, an account system, or a "sign in with"
  anything (then: nearly everything);
- the app itself starts sending anything to a developer-controlled endpoint —
  including a "check for updates" ping that carries an identifier;
- push composition moves off the user's Mac.

### the one thing that is *not* a disclosure

Crash reports that arrive in Xcode Organizer come from the user opting in to
Apple's own "Share With App Developers" diagnostics setting, and they are
Apple's collection under Apple's own consent, not the app's. Nothing in the app
gathers them. Same for App Store Connect's App Analytics. No declaration.

---

## 6. export compliance

| App Store Connect question | answer |
|---|---|
| Does your app use encryption? | **No non-exempt encryption.** Set `ITSAppUsesNonExemptEncryption` to `false` in `Orchestra-Info.plist` so the question is answered once, in the build, and never asked again per-upload. |
| Does it qualify for an exemption? | Yes — OS-provided encryption only. |
| Upload CCATS / self-classification report? | Not required. |
| France declaration | Not applicable (no non-exempt encryption). |

### the justification, in full

The app **implements no cryptography of its own.** There is no bundled crypto
library, no custom cipher, no key exchange written in Swift.

- **Keychain.** The per-device bearer token is stored with `SecItem*` — Apple's
  own keychain, i.e. encryption built into the operating system. Exempt.
- **The wire.** This is the part that reads oddly, so state it plainly: the app
  speaks **plain HTTP**, not HTTPS, to the user's Mac. Confidentiality on that
  link comes from **WireGuard**, provided by the Tailscale app — a *separate*
  application the user installs, with its own developer and its own export
  status. No encryption code ships in this binary for that path.
- **APNs.** TLS to Apple's push service is performed by the user's Mac (the
  push sender), not by the iOS app, and by iOS itself on the receiving side.

So every use of encryption associated with this app is either built into the
operating system or lives in someone else's binary. `false` is the accurate
answer, and it is worth being accurate: the declaration is a US export
regulation matter, not a review-flow annoyance, and a wrong `false` is a
regulatory problem rather than a rejection.

Add to `ios/Orchestra-Info.plist`:

```xml
<key>ITSAppUsesNonExemptEncryption</key>
<false/>
```

---

## 7. review notes — paste into "Notes" in App Store Connect

This is the most important field in the whole submission. orchestra is a
companion app for a server the reviewer does not have, and the entire outcome
turns on the reviewer finding the demo mode in the first ten seconds. Guideline
2.1 (App Completeness) is the single largest source of unresolved rejections,
and "reviewer opened it, saw an empty screen, rejected it" is the standard way a
companion app fails.

The "Notes" field holds **4000 characters**. The block below is **3,938** — it
fits, with room for your email address and nothing else. Do not add to it
without counting.

```
HOW TO REVIEW THIS WITHOUT A MAC  <- please start here

orchestra is a client for a server the user runs on their own Mac, so it shows
nothing until paired. For review, it ships a full demo.

On the very first screen, below the pairing options, tap:
    "explore the demo fleet"

The whole app then runs on built-in fictional data: the board, worktree detail,
chat with an agent, the branch map, usage limits, notification preferences. No
server, no pairing, no network, no Tailscale, no camera. It is the complete
feature set, and it sits before the Face ID gate, so biometrics never block
you. Nothing in demo mode leaves the device.

WHAT THIS APP IS

Developers run several AI coding agents (Claude Code) in parallel on their Mac,
each in its own git worktree. The free, open-source orchestra server watches
them and publishes a live board: https://github.com/acrdlph/orchestra

This app is a client for that board: which agent is working, which is waiting
for an answer, which has hit a usage limit - and reply to one, start a task, or
close one out, from the phone. No orchestra account, no sign-in, no backend of
ours; the app talks to exactly one machine, the user's own Mac, over the user's
own Tailscale (WireGuard VPN) network. Nothing to log in to, so no demo account
exists.

WHY THERE IS AN APP TRANSPORT SECURITY EXCEPTION

The link to that Mac is a Tailscale tunnel - mutually authenticated and
encrypted at the network layer before any HTTP is spoken - so the server does
not also terminate TLS. The exception is scoped as narrowly as iOS permits:

- NSAllowsArbitraryLoads is NOT set. ATS stays fully enforced everywhere else.
- Only NSExceptionAllowsInsecureHTTPLoads, only for the Tailscale namespace
  (*.ts.net) and the tailnet address the user's own server advertises.
- NSAllowsLocalNetworking does not cover this: it is for .local and link-local,
  not the 100.64.0.0/10 range Tailscale assigns.

Plaintext is therefore possible only inside a private tunnel between two
devices the same person owns, never on the public internet. The decision is
public, with the rejected alternatives:
https://github.com/acrdlph/orchestra/blob/main/docs/mobile/adr/0013-plain-http-over-the-tailnet.md

Auth is a per-device bearer token from a single-use 120-second pairing code,
stored hashed on the Mac, held in the iOS Keychain, revocable from the Mac.

PERMISSIONS

- Camera: only to scan the pairing QR shown on the user's own Mac. Unused in
  demo mode; no image is stored or transmitted.
- Face ID: a local lock on the paired board, because the app can type into
  terminals on that Mac. LocalAuthentication returns yes/no; no biometric data
  is read, stored or sent. Passcode fallback works.
- Notifications: the user's own Mac is the push sender, so not testable in demo
  mode.
- Local Network: for the Tailscale-routed connection to that Mac.

THE "CHAT" SCREEN

The age rating declares no messaging and no user-generated content; this screen
is why that needs a sentence. The far end is a command-line program on the
user's own Mac, under their own account: no directory, no other user, no way to
reach another human, nothing submitted to or hosted by any service. The text is
the user's own prompts and their own local tool's replies, read from files on
that machine; the app makes no model calls of its own.

PRIVACY, PURCHASES

The app collects nothing: no analytics, no advertising, no tracking, no
third-party SDK of any kind - the Swift package manifest declares zero
dependencies and the binary links Apple frameworks only. App Privacy is
declared "Data Not Collected":
https://github.com/acrdlph/orchestra/blob/main/PRIVACY.md

Push payloads carry structural identifiers only by default - a status glyph, a
worktree name, a session id - never transcript text.

Free app: no in-app purchases, subscriptions, paywalls, purchase links or
accounts. MIT licence.

Anything you want demonstrated live: <your email>.
```

Replace `<your email>` before submitting. Keep the whole block — Apple reviewers
read these, and the ATS paragraph in particular pre-empts the exact question
they would otherwise send back as a rejection. The demo-mode instruction is
first on purpose: it is the sentence that decides the review.

If you need to add anything, use the **Attachment** field on the same page
rather than growing the notes past 4000.

---

## 8. known rejection risks, and the answer to each

| # | guideline | the risk | mitigation |
|---|---|---|---|
| 1 | **2.1 App Completeness** | Reviewer opens the app, has no Mac, sees a pairing screen, cannot proceed, rejects. **This is the likeliest failure by a wide margin.** | The demo fleet entry point must be on the *first* screen, visible without scrolling, and must not be behind the Face ID gate. Review notes name it in the first instruction. Offer a demo video proactively. |
| 2 | **4.2 Minimum Functionality** | "This is a remote control for another app." | It is not thin: live board, chat, dispatch, closeout, limits, branch map, push with inline reply. The demo mode is also the proof — the app has enough content to stand up with no server at all. If challenged, the answer is that it is a client for the user's own server, like an SSH or self-hosted-media client. |
| 3 | **ATS / 2.5.x** | `NSExceptionAllowsInsecureHTTPLoads` triggers a request for justification. | Answered pre-emptively in the review notes, with the public ADR. Scoped exception only, `NSAllowsArbitraryLoads` never set. |
| 4 | **5.1.1 Privacy** | Missing privacy policy URL, or no in-app link to it. | `PRIVACY.md` at the repo root; URL in App Store Connect; **and** an in-app link (see blockers). |
| 5 | **5.2.1 / 4.1 Trademark** | "Claude Code" in the name or keywords. | Not in the name. Not in the keywords by default. Factual compatibility mention in the description plus an explicit non-affiliation line at the end. |
| 6 | **2.3.x Accurate Metadata** | Screenshots showing a fleet the reviewer cannot reproduce. | Take screenshots from demo mode so the store images and the reviewer's experience are the same thing. (Handled by the screenshot job — tell them.) |
| 7 | **3.1.1 IAP** | None — free app, no purchase surface anywhere. | Stated in the notes. |
| 8 | **2.5.1 Private API** | None used. | — |

---

## before you can submit at all

> **2026-08-04 — cleared.** Every engineering blocker below is done. What is
> left is the two things only a person with the account can do: **buy/confirm
> the Apple Developer membership** and **create the app record + enter the ASC
> Issuer ID** (§9). The `.p8` key is already on the Mac; `ios/release.sh upload`
> does the rest.

### blocker 1 — the ATS exception hard-coded one tailnet address — FIXED

The plist no longer pins any IP; it ships only the `ts.net` exception. The
server advertises the Mac's **MagicDNS name** wherever the phone is handed an
address (`pairing.advertised` / `tailnet.dns_name`), which that one exception
covers for every user. A tailnet with MagicDNS switched off pairs by IP and a
store build refuses it by design — the supported path is Tailscale's default.
(ADR-0013 addendum.)

### blocker 2 — no app icon — FIXED

`ios/App/Assets.xcassets` carries the 1024×1024 `AppIcon` (light/dark/tinted),
`AccentColor`, and a `LaunchBackground` the launch screen uses. Rendered
reproducibly by `ios/icon/render_icon.swift`, looked at on the home screen.

### the rest — all done

| item | state |
|---|---|
| Apple Developer Program membership | **still required of you** — $99/yr; also owns the APNs key |
| `MARKETING_VERSION` | **`1.0`** on both configurations |
| `ITSAppUsesNonExemptEncryption` | **`false`** in the plist (§6), so the encryption question never reappears |
| in-app privacy policy link | **done** — an ABOUT block on the Server screen links `PRIVACY.md` and the source (5.1.1) |
| demo fleet entry point | **done** — `explore the demo fleet` on the pairing screen, above the Face ID gate; 27 tests |
| screenshots | **done** — the 6.9" set in `docs/mobile/appstore-screenshots/`, shot from demo mode |
| launch screen | **fixed** — `UIColorName` is `LaunchBackground` (the canvas token), no white flash |
| iOS CI | **done** — `.github/workflows/ios.yml`, `swift test` + simulator build on push |
| release/upload pipeline | **done** — `ios/release.sh` archives, App-Store-signs, exports a validated production-push `.ipa`, and uploads given `ASC_ISSUER_ID` |

---

## 9. the submission checklist, in order

Do these in sequence. Steps 1–2 are the ones that can invalidate later work.

**phase 0 — decide the name**

1. **Apple Developer Program**: enrolled, agreements signed, tax and banking
   complete in App Store Connect (even for a free app, the Paid Apps agreement
   being unsigned blocks nothing here, but the *free* agreement must be active).
2. **Create the app record** — App Store Connect → Apps → **+** → New App.
   - Platform: iOS
   - **Name: `orchestra`** ← the moment of truth. Rejected as taken? Fall back
     to `orchestra — agent fleet`, then `orchestra fleet board`, and update the
     subtitle so the two do not repeat words.
   - Primary language: English (U.S.)
   - **Bundle ID: `sh.orchestra.app`** — must already exist as an explicit App ID
     in Certificates, Identifiers & Profiles, with **Push Notifications**
     enabled (you already have the APNs key) and **Keychain Sharing** matching
     `Orchestra.entitlements`
   - SKU: `orchestra-ios`
   - User Access: Full Access

**phase 1 — fix the blockers**

3. Server advertises the MagicDNS name in the pairing QR; delete the hard-coded
   IP from `NSExceptionDomains` (blocker 1).
4. Add the app icon asset catalogue, including the 1024×1024 (blocker 2).
5. Add `ITSAppUsesNonExemptEncryption = false`.
6. Add the in-app privacy policy link.
7. Bump `MARKETING_VERSION` to `1.0`; set `CURRENT_PROJECT_VERSION` to `1`.
8. Merge the demo fleet entry point and confirm the label is exactly
   `explore the demo fleet`.

**phase 2 — fill in App Store Connect (do this before uploading; it is slow and
does not need a build)**

9. **App Information**: subtitle, categories, content rights, age rating
   questionnaire (§4).
10. **Pricing and Availability**: Free, all territories.
11. **App Privacy**: "Data Not Collected" (§5), plus the privacy policy URL.
    *App Privacy must be complete before a build can be submitted for review —
    it is a common last-minute surprise.*
12. **Version 1.0 page**: description, promotional text, keywords, support URL,
    copyright, review notes (§7), contact information.

**phase 3 — build and upload**

13. Archive a Release build: `xcodebuild -project ios/Orchestra.xcodeproj
    -scheme Orchestra -configuration Release -destination 'generic/platform=iOS'
    -archivePath /tmp/orc.xcarchive archive`, then export and upload with
    `xcrun altool` / `xcrun notarytool`'s App Store sibling, or Transporter.
14. Wait for processing (minutes to an hour). Confirm the build appears under
    TestFlight with no "Missing Compliance" warning — if that warning appears,
    step 5 did not take.

**phase 4 — TestFlight, internal first**

15. **Internal testing**: add yourself (and anyone with an App Store Connect
    role) — up to 100 internal testers, **no Beta App Review**, build available
    within minutes. Install on a real iPhone.
16. **Actually test the two things a simulator cannot prove**: a real push from
    your Mac arriving on the device with a working inline reply, and pairing by
    scanning the QR with the camera. Builds expire after 90 days.
17. **External testing** (optional but recommended before review): create an
    external group. The first build of each version needs **Beta App Review** —
    currently running roughly 2–7 days. This is a cheap dress rehearsal for the
    real review with the same notes, and a Beta App Review rejection costs you
    nothing publicly.

**phase 5 — submit**

18. Attach screenshots (6.9" required) — from demo mode.
19. Version 1.0 → **Add for Review** → **Submit for Review**.
20. Release option: **Manually release this version** for a first submission, so
    approval does not immediately publish while you are asleep.
21. If rejected: reply in Resolution Center with specifics rather than
    resubmitting blindly. Most companion-app rejections are "we could not test
    it" and are answered by pointing at the demo mode — which is why §7 leads
    with it.

---

## 10. field-length reference

Verified against the text in §2.

| field | limit | ours |
|---|---|---|
| App name | 30 | 9 (`orchestra`) |
| Subtitle | 30 | 26 |
| Promotional text | 170 | 168 |
| Keywords | 100 | 98 |
| Description | 4000 | 3,149 |
| What's New | 4000 | 14 |
| Review notes | 4000 | **3,938** — 62 characters of headroom, and `<your email>` still has to become a real address. If anything else has to go in, cut `THE "CHAT" SCREEN` first and keep the demo-mode and ATS paragraphs whole. |

---

## sources

- [App privacy details on the App Store — Apple Developer](https://developer.apple.com/app-store/app-privacy-details/)
- [App Review Guidelines — Apple Developer](https://developer.apple.com/app-store/review/guidelines/)
- [Updated age ratings in App Store Connect — Apple Developer News](https://developer.apple.com/news/?id=ks775ehf)
- [Age rating questionnaire now includes social media questions — Apple Developer News](https://developer.apple.com/news/?id=tlur8uvi)
- [NSExceptionAllowsInsecureHTTPLoads — Apple Developer Documentation](https://developer.apple.com/documentation/bundleresources/information-property-list/nsexceptionallowsinsecurehttploads)
- [Manage app privacy — App Store Connect Help](https://www.developer.apple.com/help/app-store-connect/manage-app-information/manage-app-privacy)
- [TestFlight — Apple Developer](https://developer.apple.com/testflight/)
- [Orchestra / orch.so on the App Store](https://apps.apple.com/us/app/orchestra-orch-so/id6463155213)
- [Can two apps have the same name on the App Store? — PTKD](https://ptkd.com/journal/can-two-apps-have-the-same-name-app-store)
- [ITSAppUsesNonExemptEncryption: App Store export compliance, decoded — OrbitKit](https://orbitkit.io/blog/app-store-export-compliance-encryption/)
