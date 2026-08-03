#!/bin/sh
# Build (and optionally upload) the App Store Connect release of orchestra.
#
#   ios/release.sh              # archive + export → ios/dist/Orchestra.ipa
#   ios/release.sh upload       # the same, then hand the .ipa to App Store
#                               # Connect via the ASC API key
#
# What it leans on, all verified on this Mac on 2026-08-04:
#   * the Apple Distribution certificate for team 4K738RNZAA in the keychain;
#   * Xcode's saved team session, which `-allowProvisioningUpdates` uses to
#     mint/refresh the "iOS Team Store Provisioning Profile: sh.orchestra.app"
#     (it did so tonight — no profile file is managed by hand, none expires
#     in a drawer);
#   * for `upload`: an App Store Connect API key in
#     ~/.appstoreconnect/private_keys/AuthKey_<ID>.p8 plus its Issuer ID —
#     the one credential that lives only in the browser
#     (appstoreconnect.apple.com → Users and Access → Integrations).
#
# The upload lands in TestFlight processing; the app record for
# sh.orchestra.app must exist in App Store Connect first (creating it is a
# two-minute browser task — the API cannot create app records).
#
# Version discipline: MARKETING_VERSION / CURRENT_PROJECT_VERSION live in the
# project and only there (ExportOptions.plist sets
# manageAppVersionAndBuildNumber=false). Apple refuses a build number it has
# already seen for a version — bump CURRENT_PROJECT_VERSION in
# Orchestra.xcodeproj/project.pbxproj (both configurations) before re-uploading.
set -eu

cd "$(dirname "$0")"

MODE="${1:-build}"
API_KEY_ID="${ASC_KEY_ID:-CD844NVH3M}"
ISSUER_ID="${ASC_ISSUER_ID:-}"

ARCHIVE=dist/Orchestra.xcarchive
EXPORT=dist

echo "① archive (Release, device, automatic signing)"
xcodebuild archive \
    -project Orchestra.xcodeproj -scheme Orchestra -configuration Release \
    -destination 'generic/platform=iOS' \
    -archivePath "$ARCHIVE" \
    DEVELOPMENT_TEAM=4K738RNZAA \
    CODE_SIGN_STYLE=Automatic \
    CODE_SIGN_IDENTITY="Apple Development" \
    -allowProvisioningUpdates -quiet

echo "② export → $EXPORT/Orchestra.ipa (re-signs with Apple Distribution + the store profile)"
xcodebuild -exportArchive \
    -archivePath "$ARCHIVE" \
    -exportOptionsPlist ExportOptions.plist \
    -exportPath "$EXPORT" \
    -allowProvisioningUpdates -quiet

plutil -extract 'Orchestra\.ipa.0.entitlements.aps-environment' raw \
    "$EXPORT/DistributionSummary.plist" | grep -qx production || {
    echo "refusing: the exported ipa is not signed for production push" >&2
    exit 1
}
echo "   signed: Apple Distribution · aps-environment=production ✓"

[ "$MODE" = upload ] || { echo "done — $EXPORT/Orchestra.ipa (run with 'upload' to send it)"; exit 0; }

[ -n "$ISSUER_ID" ] || {
    echo "upload needs ASC_ISSUER_ID — the UUID next to your API keys at" >&2
    echo "appstoreconnect.apple.com → Users and Access → Integrations" >&2
    echo "(the key file AuthKey_${API_KEY_ID}.p8 is already in ~/.appstoreconnect/private_keys)" >&2
    exit 2
}

echo "③ upload to App Store Connect (key $API_KEY_ID)"
xcrun altool --upload-app -f "$EXPORT/Orchestra.ipa" -t ios \
    --apiKey "$API_KEY_ID" --apiIssuer "$ISSUER_ID"
echo "done — watch TestFlight processing in App Store Connect"
