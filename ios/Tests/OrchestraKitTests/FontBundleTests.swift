import CoreText
import Foundation
import Testing

/// The bundled-typeface contract, checked against the bytes on disk.
///
/// `UX.md` §9.4: **coverage is verified, not assumed.** `Font.custom` with a name
/// nothing resolves does not throw and does not draw tofu — it substitutes, and a
/// substituted face is invisible in review and obvious only on a phone. There are
/// three ways that goes wrong and all three are here:
///
/// 1. a `.ttf` listed in `UIAppFonts` that is not in `App/Fonts/`, or a `.ttf` in
///    `App/Fonts/` that nothing lists — either way the app asks for a face that
///    is not in the bundle;
/// 2. a face whose **PostScript** name is not what `UI/Typography.swift` asks
///    `UIFont(name:)` for. Two of Plex Mono's four are abbreviated
///    (`IBMPlexMono-Medm`, `IBMPlexMono-SmBld`), and a Plex version bump that
///    spelled them out would silently un-bundle the whole machine voice;
/// 3. a mark the app renders in a mono style that the face has no glyph for.
///    That is not hypothetical: `Δ` U+0394 and `✕` U+2715 were both in the
///    shipped strings and neither is in Plex Mono, which is why the dirty badge
///    now uses `∆` U+2206 and the close button an SF Symbol.
///
/// This suite reads `App/Fonts/` and `Orchestra-Info.plist` off the source tree
/// via `#filePath`, because they belong to the Xcode target and the SwiftPM
/// package deliberately does not build the app. That makes it a check on the
/// repository rather than on a built product, which is the level the mistake
/// lives at.
struct FontBundleTests {

    /// `ios/`, from this file's location — `ios/Tests/OrchestraKitTests/…`.
    static let iosRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // OrchestraKitTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // ios

    static let fontsDir = iosRoot.appendingPathComponent("App/Fonts")

    /// What `UI/Typography.swift`'s `PlexMono` asks `UIFont(name:)` for, keyed by
    /// the filename `UIAppFonts` lists. Duplicated here on purpose: this is the
    /// side of the contract the app cannot check for itself, and the app checks
    /// the other side at launch (`OrcFont.plexIsAvailable`).
    static let expected: [String: String] = [
        "IBMPlexMono-Regular.ttf": "IBMPlexMono",
        "IBMPlexMono-Medium.ttf": "IBMPlexMono-Medm",
        "IBMPlexMono-SemiBold.ttf": "IBMPlexMono-SmBld",
        "IBMPlexMono-Bold.ttf": "IBMPlexMono-Bold",
    ]

    /// Every non-ASCII mark the app renders in a mono token (`code`, `codeSm`,
    /// `meta`, `label`, `status`, `button`, `cardName`). Hand-maintained, which is
    /// the cost of not having a linter that can tell the two voices apart — but a
    /// list of nine that fails loudly beats a page of prose that does not.
    /// ASCII is not listed: a mono face missing `a` is not a failure mode.
    static let monoMarks = "—–·…↑↓✓×∆"

    private func psName(_ url: URL) throws -> String {
        let descriptors = try #require(
            CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor],
            "\(url.lastPathComponent) is not a font CoreText can read")
        let first = try #require(descriptors.first)
        return try #require(
            CTFontDescriptorCopyAttribute(first, kCTFontNameAttribute) as? String)
    }

    @Test("UIAppFonts and App/Fonts/ name the same four files")
    func plistMatchesDisk() throws {
        let plistURL = Self.iosRoot.appendingPathComponent("Orchestra-Info.plist")
        let raw = try Data(contentsOf: plistURL)
        let plist = try #require(
            try PropertyListSerialization.propertyList(from: raw, format: nil) as? [String: Any])
        let listed = try #require(plist["UIAppFonts"] as? [String],
                                  "Orchestra-Info.plist has no UIAppFonts array")

        #expect(Set(listed) == Set(Self.expected.keys))

        let onDisk = try FileManager.default
            .contentsOfDirectory(atPath: Self.fontsDir.path)
            .filter { $0.hasSuffix(".ttf") || $0.hasSuffix(".otf") }
        #expect(Set(onDisk) == Set(Self.expected.keys),
                "App/Fonts/ and UIAppFonts disagree — a face is unbundled or unused weight ships")

        // The OFL requires the licence to travel with the font, and the App Store
        // requires the OFL to be honoured. It is a resource in the same folder,
        // so it ships in the bundle.
        #expect(FileManager.default.fileExists(
            atPath: Self.fontsDir.appendingPathComponent("OFL.txt").path))
    }

    @Test("every face reports the PostScript name Typography asks for")
    func postScriptNames() throws {
        for (file, name) in Self.expected {
            let url = Self.fontsDir.appendingPathComponent(file)
            #expect(try psName(url) == name,
                    "\(file) reports a different PostScript name — Font.custom would substitute")
        }
    }

    @Test("every mark the app draws in mono has a real glyph in all four faces")
    func glyphCoverage() throws {
        for file in Self.expected.keys.sorted() {
            let url = Self.fontsDir.appendingPathComponent(file)
            let descriptors = try #require(
                CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor])
            let font = CTFontCreateWithFontDescriptor(try #require(descriptors.first), 12, nil)
            for mark in Self.monoMarks {
                let units = Array(String(mark).utf16)
                var glyphs = [CGGlyph](repeating: 0, count: units.count)
                let ok = CTFontGetGlyphsForCharacters(font, units, &glyphs, units.count)
                let code = String(format: "%04X", mark.unicodeScalars.first!.value)
                #expect(ok && !glyphs.contains(0),
                        "\(file) has no glyph for U+\(code) — Font.custom falls back per glyph, silently, to a face with other metrics")
            }
        }
    }

    /// The face is monospaced, which is the only reason a column of pids lines
    /// up without `.monospacedDigit()` (`UX.md` §9.3 forbids it for custom faces).
    @Test("Plex Mono advances every digit identically")
    func digitsAreTabular() throws {
        let url = Self.fontsDir.appendingPathComponent("IBMPlexMono-Regular.ttf")
        let descriptors = try #require(
            CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor])
        let font = CTFontCreateWithFontDescriptor(try #require(descriptors.first), 12, nil)
        var advances = Set<CGFloat>()
        for digit in "0123456789." {
            let units = Array(String(digit).utf16)
            var glyphs = [CGGlyph](repeating: 0, count: units.count)
            _ = CTFontGetGlyphsForCharacters(font, units, &glyphs, units.count)
            advances.insert(CTFontGetAdvancesForGlyphs(font, .horizontal, &glyphs, nil, 1))
        }
        #expect(advances.count == 1, "digits do not share one advance: \(advances)")
    }
}
