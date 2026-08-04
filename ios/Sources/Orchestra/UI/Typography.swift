import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// The four bundled faces of IBM Plex Mono, by the name `UIFont(name:)` answers
/// to — which is the **PostScript** name, not the filename and not the style.
///
/// **Two of the four are abbreviated, and that is the trap this enum exists to
/// close.** `IBMPlexMono-Medium.ttf` reports `IBMPlexMono-Medm`;
/// `IBMPlexMono-SemiBold.ttf` reports `IBMPlexMono-SmBld`; Regular has no suffix
/// at all and is plain `IBMPlexMono`. Ask for `"IBMPlexMono-Medium"` and
/// `Font.custom` does not fail, it *substitutes* — silently, in the system face,
/// with different metrics, in a build that reviews clean. Every name here was
/// read back off the shipped `.ttf` with `CTFontDescriptorCopyAttribute`, and
/// `FontBundleTests` re-reads them on every `swift test` so a font upgrade that
/// renames a face fails the suite rather than the screen.
enum PlexMono: String, CaseIterable, Sendable {
    /// `code`, `codeSm`, `meta` at normal legibility.
    case regular = "IBMPlexMono"
    /// The same three with Bold Text on.
    case medium = "IBMPlexMono-Medm"
    /// `cardName`, `label`, `status`, `button` at normal legibility.
    case semiBold = "IBMPlexMono-SmBld"
    /// The same four with Bold Text on.
    case bold = "IBMPlexMono-Bold"
}

/// The type ramp of `UX.md` §9.3 — eleven tokens, two voices.
///
/// **Mono is for machine tokens; SF for human language.** Worktree name, branch,
/// commit hash, `[account]`, model, pid, tty, ages, countdowns, `↑ahead`,
/// `∆dirty`, counts, status words, badges, buttons — all mono, and mono is now
/// **IBM Plex Mono**, the face the desktop board has always used. Topic,
/// `last_assistant`, `last_user`, chat, control labels — all SF Pro, because a
/// paragraph of prose is not a machine token and §9.3 keeps the two voices apart.
///
/// **A token is a `case`, not a `Font`, and `.font(_:)` is overloaded on it.**
/// That is the whole reason 224 call sites did not change when the face did:
/// `Font.custom(_:size:relativeTo:)` returns a value that cannot see the
/// environment, so the Bold Text mapping below has to happen *inside a view*.
/// `View.font(_ token: OrcFont)` is that view — it reads `\.legibilityWeight`
/// and hands SwiftUI a resolved `Font`. Call sites still read `.font(OrcFont.meta)`.
///
/// **Bold Text is honoured, and it costs the two extra faces.**
/// `Font.custom(_:size:relativeTo:)` does *not* respond to
/// `UIAccessibility.isBoldTextEnabled` — with Bold Text on, an unresolved custom
/// face leaves the SF human voice bold and the entire mono machine voice thin:
/// worktree names, every status word, every badge, every button, every timestamp.
/// That is not "no benefit", it is the hierarchy inverted by the setting that
/// exists to preserve it. So §9.3's table is implemented literally:
///
/// | token | `.regular` | `.bold` |
/// |---|---|---|
/// | `code`, `codeSm`, `meta` | Regular | **Medium** |
/// | `cardName`, `label`, `status`, `button` | SemiBold | **Bold** |
///
/// **Everything uses `relativeTo:`.** A fixed-size initialiser does not
/// participate in Dynamic Type at all, and at AX5 a fixed 12 pt `meta` would
/// render larger than the 20 pt `title` above it — the hierarchy inverted by the
/// setting that exists to preserve it. Each mono token passes the *default point
/// size of the text style it maps to*, so at the default content size Plex
/// renders at exactly the size SF Mono did before it, and every step of Dynamic
/// Type scales from there.
///
/// **`.monospacedDigit()` is still not used** (§9.3): it applies a font-feature
/// descriptor a custom face may not expose, with known cases of resolving to the
/// system font. Plex Mono is monospaced by construction — every digit, and every
/// other glyph, is one 600/1000 em advance — so tabular figures are what a pid
/// column already gets. The `Text(verbatim:)` around every number stays: it is
/// there to stop `Text(1234)` from localising a pid into `1.234`, which is a
/// separate bug from the one a font fixes.
///
/// **Two marks moved, because §9.4's warning turned out to be about this app.**
/// The shipped `.ttf`s were read with `CTFontGetGlyphsForCharacters` and Plex
/// Mono has no Greek block at all — so `Δ` U+0394, which §9.4 lists as "basic
/// Greek; covered", is **not** covered, and the dirty badge would have drawn its
/// delta from a proportional fallback inside a mono column. The dirty count now
/// uses `∆` U+2206 INCREMENT, which Plex does carry and which is the same
/// drawing. `✕` U+2715 on the close button is not covered either and became the
/// `xmark` SF Symbol, which is what §9.4 asks for anyway. Everything else the
/// app renders in a mono style — `— · … ↑ ↓ ✓ × –` and ASCII — is covered, and
/// `FontBundleTests` asserts exactly that list against all four faces.
public enum OrcFont: Sendable {
    /// headline numbers only. Sans at display size because proportional figures
    /// read better than tabular mono digits at 34 pt.
    case display
    /// sheet titles, section heads
    case title
    /// worktree name
    case cardName
    /// mission composer, chat bubbles
    case body
    /// topic, last_assistant, last_user, notes
    case bodyCompact
    /// branch, path, attach commands, progress lines
    case code
    /// commit subject, session identifiers
    case codeSm
    /// age, model, tty, etime, %cpu
    case meta
    /// UPPERCASE micro-labels
    case label
    /// status words and availability badges. **12 pt, not the desktop's 10** —
    /// the densest and most-glanced element in the app; on a phone it goes up.
    case status
    /// all button labels
    case button

    /// Tracking for the two uppercase tokens, as a fraction of the RENDERED
    /// size. A constant computed from the shipped size means an 11 pt label at
    /// AX5 carries .03em instead of .08em — the tracking vanishing exactly where
    /// "uppercase mono without tracking reads as a wall" bites hardest.
    public static let uppercaseTracking = 0.08

    /// **The guard of `UX.md` §9.4, and the reason it is a whole-face decision.**
    ///
    /// `Font.custom` with a name nothing resolves does not throw and does not
    /// draw tofu — it substitutes, glyph by glyph, from a face with different
    /// metrics and a different weight, and the result looks *almost* right in a
    /// screenshot. The one thing that must never happen is half the ramp in Plex
    /// and half in something else, so the check is all-or-nothing: if any one of
    /// the four faces fails to resolve, **every** mono token falls back to the
    /// system monospaced design — which is exactly what this file shipped before
    /// Plex, honours Bold Text on its own, and cannot fall back per glyph.
    ///
    /// Loud in DEBUG (`assertionFailure` — a missing face is a packaging bug and
    /// a packaging bug should stop the build that made it), graceful in Release
    /// (`ENABLE_NS_ASSERTIONS = NO`; the app draws in SF Mono rather than not at
    /// all). Evaluated once, on first use — which on this app is the pairing
    /// screen's first label, a few milliseconds after `UIAppFonts` has done its
    /// work. `OrchestraApp` pokes it at launch so the DEBUG trap fires there.
    public static let plexIsAvailable: Bool = {
        #if canImport(UIKit)
        let missing = PlexMono.allCases.filter { UIFont(name: $0.rawValue, size: 12) == nil }
        guard missing.isEmpty else {
            let names = missing.map(\.rawValue).joined(separator: ", ")
            assertionFailure("""
                IBM Plex Mono did not resolve: \(names). Check that App/Fonts/ \
                carries all four .ttf files and that Orchestra-Info.plist's \
                UIAppFonts lists every one of them. Falling back to the system \
                monospaced face for the whole ramp.
                """)
            return false
        }
        return true
        #else
        return false
        #endif
    }()

    /// The token resolved against the accessibility setting that changes it.
    /// `weight` is `\.legibilityWeight`, which is `.bold` exactly when the system
    /// Bold Text switch is on.
    func resolved(_ weight: LegibilityWeight?) -> Font {
        let heavy = weight == .bold
        switch self {
        // The human voice. `Font.system` honours Bold Text by itself, so these
        // four never consult `heavy`.
        case .display:     return .system(.largeTitle, design: .default).weight(.semibold)
        case .title:       return .system(.title3, design: .default).weight(.semibold)
        case .body:        return .system(.body, design: .default)
        case .bodyCompact: return .system(.subheadline, design: .default)
        // The machine voice. The sizes are the default point sizes of the text
        // styles these tokens have always used, so the switch to Plex changes
        // the face and nothing else. (`button` is 16 because `.callout` is 16;
        // §9.3's table says 15, and the shipped build has always drawn 16.)
        case .cardName:    return Self.mono(17, .headline, semibold: true, heavy: heavy)
        case .code:        return Self.mono(15, .subheadline, semibold: false, heavy: heavy)
        case .codeSm:      return Self.mono(13, .footnote, semibold: false, heavy: heavy)
        case .meta:        return Self.mono(12, .caption, semibold: false, heavy: heavy)
        case .label:       return Self.mono(11, .caption2, semibold: true, heavy: heavy)
        case .status:      return Self.mono(12, .caption, semibold: true, heavy: heavy)
        case .button:      return Self.mono(16, .callout, semibold: true, heavy: heavy)
        }
    }

    private static func mono(_ size: CGFloat, _ style: Font.TextStyle,
                             semibold: Bool, heavy: Bool) -> Font {
        guard plexIsAvailable else {
            // The pre-Plex definitions, verbatim. No `heavy` branch here on
            // purpose: the system face applies Bold Text itself, and bumping the
            // weight on top of that would double-apply it.
            let system = Font.system(style, design: .monospaced)
            return semibold ? system.weight(.semibold) : system
        }
        let face: PlexMono = semibold ? (heavy ? .bold : .semiBold)
                                      : (heavy ? .medium : .regular)
        return .custom(face.rawValue, size: size, relativeTo: style)
    }
}

/// Spacing — 4 pt base, seven steps (`UX.md` §9.5).
public enum Space {
    public static let xxs: CGFloat = 2
    public static let xs: CGFloat = 4
    public static let sm: CGFloat = 8
    public static let md: CGFloat = 12
    public static let lg: CGFloat = 16
    public static let xl: CGFloat = 24
    public static let xxl: CGFloat = 32
}

/// Radii (`UX.md` §9.5). `.continuous` throughout.
public enum Radius {
    /// chips, badges, pills
    public static let xs: CGFloat = 5
    /// rows, bubbles, fields
    public static let sm: CGFloat = 8
    /// cards, tiles
    public static let md: CGFloat = 12
    /// sheets, toasts
    public static let lg: CGFloat = 16
}

extension View {
    /// `.font(OrcFont.meta)` — the same call site as before the face changed.
    ///
    /// This overload sits beside SwiftUI's `font(_ font: Font?)` and is picked
    /// only for an `OrcFont` argument, so `.font(.system(size: 40))` on the five
    /// SF Symbol call sites still reaches SwiftUI's. It exists because the token
    /// cannot be resolved outside a view: Bold Text arrives as
    /// `\.legibilityWeight`, and reading it here is also what makes SwiftUI
    /// re-render these views when the user flips the switch in Settings.
    public func font(_ token: OrcFont) -> some View {
        modifier(OrcFontModifier(token: token))
    }

    /// Uppercase micro-label styling, with tracking that scales with the
    /// rendered point size rather than being frozen at the shipped one.
    func orcTracking(_ size: CGFloat) -> some View {
        tracking(size * OrcFont.uppercaseTracking)
    }
}

private struct OrcFontModifier: ViewModifier {
    @Environment(\.legibilityWeight) private var legibilityWeight
    let token: OrcFont

    func body(content: Content) -> some View {
        content.font(token.resolved(legibilityWeight))
    }
}
