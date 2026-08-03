# Privacy policy — orchestra

**Applies to:** the orchestra iOS app (`sh.orchestra.app`) and the orchestra
server (`github.com/acrdlph/orchestra`).
**Last updated:** 2026-08-04.

## the short version

**We collect nothing.** There is no orchestra account, no orchestra server, no
analytics, no advertising, no tracking, and no third-party SDK anywhere in the
app. The developer has no way to see your data and does not want it.

orchestra is a client for a server **you** run, on **your** Mac, reachable only
over **your** private Tailscale network. Your prompts, your agents' replies,
your repository names and your usage numbers stay on hardware you own.

## what the app talks to

Exactly two things, and neither of them is ours.

**1. your Mac.** The app's only API peer is the orchestra server running on your
own machine, at your own tailnet address, which you gave the app yourself by
scanning a QR code shown on that machine. There is no fallback endpoint, no
relay, no "cloud sync", and no address the app will reach for on its own.

**2. Apple's push service (APNs).** When an agent needs you, the notification is
composed and sent **by your Mac**, using an APNs key held on your Mac, and
handed to Apple for delivery to your phone. Apple's own privacy policy governs
that hop. The developer is not a party to it and never sees a payload, a token,
or a delivery record.

By default a push payload carries **structural identifiers only** — a status
glyph, a worktree name, a session id, a count — and never the text of a prompt
or a reply. The prose you see when you expand the notification is fetched by the
app from your own Mac over your own tailnet. If you would rather have the detail
text in the payload itself, there is a setting for it (Notifications → "on the
lock screen"); it is off by default, and turning it on means that text transits
Apple's servers like any other notification.

## what is stored, and where

| what | where it lives | who can read it |
|---|---|---|
| Your device's bearer token | the iOS **Keychain** on your phone | your phone; the app |
| A SHA-256 hash of that token, the device label you typed, its APNs push token, its time zone, the app version, and a `last_seen` timestamp | `devices.json` on **your Mac**, mode `0600` | you |
| Which mutations were requested against the server, and when | `audit.log.jsonl` on **your Mac**, mode `0600` — never the body of a message or a mission brief | you |
| Everything else — transcripts, repository state, usage figures | files on **your Mac** that already existed before orchestra read them | you |
| The address you paired with, and your notification preferences | the app's own container on your phone (`UserDefaults`), removed when you delete the app | your phone |
| The board itself | held in memory while the app is running; re-read from your Mac each time | your phone |

Nothing in that table is transmitted to the developer, because there is nowhere
for it to be transmitted to.

## App Store "App Privacy" — why it says *Data Not Collected*

Apple defines "collect" as transmitting data off the device in a way that allows
**the developer or the developer's third-party partners** to access it. Neither
happens here: the developer runs no server and has no partners, and the machine
your phone talks to is one you own and administer. Data written to your own Mac
by software you run yourself is not the developer's collection, so the honest
answer is *Data Not Collected*, and that is the answer given.

## permissions the app asks for

- **Camera** — only to scan the pairing QR code displayed on your Mac. No image
  is stored or sent anywhere, and the camera is never opened for anything else.
- **Face ID / Touch ID** — a local lock on the board, because the app can type
  into terminals on your Mac. `LocalAuthentication` returns a yes or a no; no
  biometric data is read by the app, stored by the app, or leaves your phone.
  Your passcode works where biometrics do not.
- **Notifications** — so your Mac can tell you an agent is waiting. Decline it
  and everything else still works.
- **Local network** — declared for the connection to your Mac over Tailscale.

## no tracking, no analytics, no ads

- No advertising, no ad identifier, no IDFA, no ad network.
- No analytics or attribution SDK. Nothing counts your taps.
- No crash-reporting SDK. If a crash report reaches the developer at all, it is
  because *you* enabled Apple's "Share With App Developers" setting on your own
  device, under Apple's own consent and aggregation, with nothing in this app
  involved.
- **Zero third-party dependencies.** The app's Swift package manifest declares
  none, and the Xcode project links no external framework. The binary is Apple
  frameworks and orchestra's own code.

## children

orchestra is a tool for software developers, rated 4+ because it contains no
objectionable content. It is not directed at children, and it collects no data
from anyone of any age.

## security

- Your phone authenticates to your Mac with a **per-device bearer token**, held
  in the iOS Keychain, stored only as a hash on the Mac, and revocable from the
  Mac at any time (`python3 -m orchestra --revoke-device <id>`).
- Pairing uses a **single-use code that expires in 120 seconds**. The QR carries
  the code, not the token, so a photograph of your screen is worthless a minute
  later.
- The server binds **loopback by default** and refuses to bind wider unless a
  device is registered; it refuses `0.0.0.0` outright.
- The link between phone and Mac is encrypted by **Tailscale (WireGuard)**.
  Tailscale is a separate product with [its own privacy
  policy](https://tailscale.com/privacy-policy); orchestra does not send it your
  data, it simply runs over the network you have already set up.

Delete the app and the token goes with it. Revoke the device on the Mac and the
phone can no longer reach anything, whatever it still holds.

## changes

This policy lives in the repository. Its history is the changelog: any edit is a
commit at
[github.com/acrdlph/orchestra](https://github.com/acrdlph/orchestra/commits/main/PRIVACY.md).

## contact

Questions, corrections, or anything here that turns out not to be true:
open an issue at
[github.com/acrdlph/orchestra/issues](https://github.com/acrdlph/orchestra/issues).
