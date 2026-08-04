# Morning handoff — orchestra to the App Store

Written 2026-08-04, end of an overnight run. The app is engineering-complete for
submission. **The only things left need you and the Apple account** — everything
buildable is built, tested, and committed on `main`.

---

## Do this in the morning (≈20 minutes, all in the browser + one command)

1. **Apple Developer Program** — confirm the membership is active
   (`developer.apple.com` → Membership). It also owns the APNs key already on
   the Mac.
2. **Create the app record** — App Store Connect → Apps → **＋** → New App:
   - Platform iOS, Name **orchestra** (fallbacks if taken:
     `orchestra — agent fleet`, then `orchestra fleet board` — see
     `APPSTORE.md` §name), bundle id **sh.orchestra.app**, SKU anything
     (e.g. `orchestra-ios`), primary language English.
3. **Get the ASC Issuer ID** — App Store Connect → Users and Access →
   **Integrations** → App Store Connect API. Copy the **Issuer ID** (a UUID at
   the top). The API key file `AuthKey_CD844NVH3M.p8` is already at
   `~/.appstoreconnect/private_keys/`.
4. **Upload the build:**
   ```sh
   ASC_ISSUER_ID=<the-uuid-from-step-3> ios/release.sh upload
   ```
   This archives, App-Store-signs, exports, and hands the `.ipa` to App Store
   Connect. Watch **TestFlight → processing** (a few minutes). A tested
   release-candidate `.ipa` from tonight is already at `ios/dist/Orchestra.ipa`
   if you want to upload that exact one instead (`xcrun altool --upload-app -f
   ios/dist/Orchestra.ipa -t ios --apiKey CD844NVH3M --apiIssuer <uuid>`).
5. **Fill the listing** — copy the counted fields from `docs/mobile/APPSTORE.md`
   (name, subtitle, promo text, description, keywords, category Developer Tools).
   Screenshots: upload the five in `docs/mobile/appstore-screenshots/` (they are
   the required 6.9" size). Privacy policy URL:
   `https://github.com/acrdlph/orchestra/blob/main/PRIVACY.md`. App Privacy:
   **Data Not Collected** (the reasoning is `APPSTORE.md` §privacy). Export
   compliance is already answered in the build (`ITSAppUsesNonExemptEncryption`
   = false).
6. **Review notes** — paste `APPSTORE.md` §7 verbatim (it tells the reviewer to
   tap **explore the demo fleet** on the first screen — no Mac needed — and
   explains the ATS exception). Fill in the one placeholder: a contact email.
7. TestFlight internal test on your own phone first, then submit for review.

That's the whole path. Nothing else blocks it.

---

## One thing worth knowing before you pair your real phone

The server now advertises its **MagicDNS name** in the pairing QR (not the raw
tailnet IP), because a store-distributed build's ATS covers `ts.net` and cannot
carry your specific IP. **A phone paired before tonight stored the IP and should
re-pair once** to pick up the name. Your tailnet has MagicDNS on (verified), so
this just works; a tailnet with MagicDNS off would need it enabled.

---

## What landed tonight (47 commits on `main`)

**Suites green:** 1317 Python tests, 189 Swift tests. Debug + Release build
clean (warnings-as-errors); the release `.ipa` verified — v1.0, Apple
Distribution, `aps-environment=production`, `get-task-allow=false`.

Distribution
- App icon + asset catalog (light/dark/tinted), reproducible from
  `ios/icon/render_icon.swift`.
- `ios/release.sh` — archive → App-Store-sign → export → validate → upload.
- iOS CI (`.github/workflows/ios.yml`): `swift test` + simulator build on push.
- IBM Plex Mono bundled (brand face; caught + fixed a silent glyph fallback).
- The in-app **demo fleet** so App Review needs no Mac (27 tests, 10 screens
  looked at). Store screenshots shot from it.
- App Store metadata pack (`APPSTORE.md`) + `PRIVACY.md` + in-app privacy links.
- MagicDNS advertising, version-from-project fix, launch-screen colour.

Stability / your two requests
- The **send that typed but never submitted** — fixed on all three terminal
  hosts, with honest wording the app classifies correctly.
- **Finish cleans leftovers/scratch** (your note) — opt-in `clean_scratch`,
  refuses anything but untracked files, never touches tracked or `.gitignore`d.
- Closeout + dispatch-job state now survives a restart.
- Post-wake push suppression (a lid-open no longer buzzes the night's backlog).
- Disk report + log rotation (the corpus is your own transcripts — it reports,
  never deletes).
- Server smalls: query-decode, dispatch-status 400, security headers, parallel
  resumes, web-board idempotency, a launchd keep-alive template, dependency
  police tests.
- UX Appendix E: the four desktop contrast/colour corrections.

Security — a full adversarial review ran over the merged tree
(`docs/mobile/SECURITY-REVIEW-2026-08-04.md`). It found a **critical stored XSS**
at the board origin (a device label / worktree name could inject script, which
the server treats as loopback-admin). **Fixed**, plus a cross-page lint and
Node-driven breakout tests so it can't regress. Every other finding (H1 CSRF gap
on acting GETs, M2 admin-path normalization, M3 idempotency caps, and four lows)
is closed and tested, or accepted with a stated reason. Nothing open.

---

## Open decisions (not blockers — your call, someday)

- **Biometric gate fails *open* on a phone with no passcode set**
  (`App/BiometricGate.swift`) — deliberate, but confirm you want that.
- **Disk**: the Mac had ~13.5 GB free of 494 GB tonight; your own `~/.claude*`
  corpus is ~4.9 GB / 35k files. orchestra now *reports* it (`--disk-report`)
  but will never delete your transcripts. An opt-in policy needs your sign-off.
- **L3 sid charset** is the superset `[0-9A-Za-z-]+` (not strict hex) so the
  test suite's non-hex sid stand-ins keep working — noted in the review if you
  want strict hex + a test rewrite.

---

## If you want to keep the server always-on

`contrib/sh.orchestra.server.plist` is a launchd template — see the README's
"Keeping it running (launchd, macOS)" section. It fails closed at boot until
Tailscale is up and `KeepAlive` retries.
