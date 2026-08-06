import Foundation

/// An uploaded image is **a path in the draft text, and nothing else**.
///
/// `POST /api/v1/uploads` writes the bytes to the Mac and answers with an
/// absolute path; the app puts that path into the message it was already
/// writing, because that is exactly what dragging a file into a `claude` session
/// does — the CLI reads the bytes off disk itself. So there is no attachment
/// object here, no chip carrying a parallel representation, and no second thing
/// to persist: the draft is one String, the send path types a String, and the
/// reader at the far end reads a path.
///
/// Everything a composer wants to *show* about an attachment is therefore
/// derived from that String by the two rules in this file — which is why they
/// live outside `UI`, where `swift test` can reach them. Delete the path from
/// the text and the attachment is gone, with no bookkeeping anywhere that could
/// disagree.
public enum UploadPath {

    /// The extensions `uploads.KINDS` writes. Note `jpeg` becomes **`.jpg`** on
    /// disk — the kind and the extension are not the same word, and a rule that
    /// looked for `.jpeg` would never match a photo.
    public static let extensions: Set<String> = ["png", "jpg", "gif", "webp", "heic", "heif"]

    /// Characters trimmed off either end of a token before it is tested.
    ///
    /// A path written into prose is routinely followed by a comma or a full stop
    /// (*"see /Users/…/49cecdb0.png, the button is cut off"*) and routinely
    /// wrapped in brackets or backticks. Trimming these is what stops the strip
    /// silently losing an attachment the moment the user writes a sentence around
    /// it. `.` is safe to trim: the extension it would eat into is preceded by
    /// three or four more characters, so `x.png.` trims to `x.png` and `x.png`
    /// trims to itself.
    static let fences = CharacterSet(charactersIn: "`\"'()[]{}<>,;:!?.")

    /// Is this token a path this server generated?
    ///
    /// The shape is `uploads.py`'s, component for component:
    /// `<home>/.orchestra/uploads/<YYYY-MM-DD>/<16 lowercase hex>.<ext>`. The
    /// home prefix is deliberately **not** checked — it is the *server's* home
    /// and this phone has no way to know it, and the tests rebind `UPLOAD_ROOT`
    /// to a tmpdir. The last four components are the whole identity.
    public static func isUpload(_ token: String) -> Bool {
        guard token.hasPrefix("/"), !token.contains("..") else { return false }
        let parts = token.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count >= 4 else { return false }
        let n = parts.count
        guard parts[n - 4] == ".orchestra", parts[n - 3] == "uploads" else { return false }
        return isDay(parts[n - 2]) && isName(parts[n - 1])
    }

    /// `uploads.DAY_RE` — `^\d{4}-\d{2}-\d{2}$`, and nothing looser. A day
    /// directory is the unit retention walks, so "looks like a date" is the test,
    /// not "parses as one".
    static func isDay(_ s: Substring) -> Bool {
        guard s.count == 10 else { return false }
        for (i, c) in s.enumerated() {
            if i == 4 || i == 7 {
                guard c == "-" else { return false }
            } else {
                guard c.isASCII, c.isNumber else { return false }
            }
        }
        return true
    }

    /// `uploads.NAME_RE` — sixteen **lowercase** hex characters (the head of a
    /// sha256 of the bytes) and one of the six extensions. Upper-case hex is not
    /// a name this server writes, so it is not one this rule claims.
    static func isName(_ s: Substring) -> Bool {
        guard let dot = s.lastIndex(of: ".") else { return false }
        let stem = s[s.startIndex..<dot]
        let ext = String(s[s.index(after: dot)...])
        guard stem.count == 16, extensions.contains(ext) else { return false }
        return stem.allSatisfy { $0.isASCII && ($0.isNumber || ("a"..."f").contains($0)) }
    }

    /// Every upload path in this draft, in the order they appear, **without
    /// duplicates** — the strip shows one tile per attachment even if the user
    /// pasted the same path twice.
    public static func paths(in text: String) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for hit in hits(in: text) where !seen.contains(hit.path) {
            seen.insert(hit.path)
            out.append(hit.path)
        }
        return out
    }

    /// One occurrence: the path, and where it sits in the text **measured in
    /// Characters**, which is the unit a caret is in.
    struct Hit: Equatable {
        let path: String
        let range: Range<Int>
    }

    /// Every occurrence, duplicates included, left to right.
    ///
    /// Tokenised on whitespace and then fenced-trimmed, rather than matched with
    /// a regex over the whole string, because that is the only reading under
    /// which a path is a *word*: a substring match would happily find an upload
    /// path inside a longer path that merely ends with one.
    static func hits(in text: String) -> [Hit] {
        let chars = Array(text)
        var out: [Hit] = []
        var i = 0
        while i < chars.count {
            guard !chars[i].isWhitespace else { i += 1; continue }
            var j = i
            while j < chars.count, !chars[j].isWhitespace { j += 1 }
            var lo = i, hi = j
            while lo < hi, isFence(chars[lo]) { lo += 1 }
            while hi > lo, isFence(chars[hi - 1]) { hi -= 1 }
            if lo < hi {
                let token = String(chars[lo..<hi])
                if isUpload(token) { out.append(Hit(path: token, range: lo..<hi)) }
            }
            i = j
        }
        return out
    }

    private static func isFence(_ c: Character) -> Bool {
        c.unicodeScalars.allSatisfy { fences.contains($0) }
    }
}

/// Putting an upload path into a draft, and taking it back out.
///
/// Both are pure functions over `(text, path)` because both have to be right in
/// two composers with different editors, and a rule that can only be checked by
/// looking at a screenshot is a rule that drifts. The caret is an offset in
/// **Characters** — SwiftUI hands out `String.Index`, but a rule that took one
/// could not be written down in a test with three literals.
public enum DraftAttachment {

    /// The text after the insert, and where the caret should end up.
    public struct Result: Equatable, Sendable {
        public let text: String
        public let caret: Int
        public init(text: String, caret: Int) {
            self.text = text
            self.caret = caret
        }
    }

    /// A caret offset from a `String.Index` the composer handed us — or `nil`,
    /// which means append.
    ///
    /// **This exists because the naive version crashed the app**, on the first
    /// real upload driven from a simulator (`EXC_BREAKPOINT` in
    /// `_StringGuts.validateInclusiveSubscalarIndex_5_7`, 2026-08-06).
    ///
    /// SwiftUI's `TextSelection` carries a `String.Index`, and a `String.Index`
    /// belongs to **the string it was made from**. The selection the field
    /// reports and the text the binding currently holds are two different values
    /// in every case where one moved and the other has not caught up — a draft
    /// hydrated from `DraftStore` on appear is exactly that case — and measuring
    /// a foreign index whose offset is past the end of the string is not a wrong
    /// answer, it is a trap.
    ///
    /// Comparing indices is safe (it compares raw bits and validates nothing);
    /// measuring is not. So the bounds are checked with comparisons, and only an
    /// index this string could actually contain is measured. A mid-grapheme
    /// index inside the bounds is fine — `distance` resolves it — so the only
    /// thing rejected here is the one thing that would crash.
    public static func caret(at index: String.Index, in text: String) -> Int? {
        guard index >= text.startIndex, index <= text.endIndex else { return nil }
        return text.distance(from: text.startIndex, to: index)
    }

    /// Insert `path` at `caret`, or append when there is no caret to speak of.
    ///
    /// Three properties, and each is something a user would otherwise have to
    /// fix by hand:
    ///
    /// * **it never fuses with a neighbour.** A space goes in before unless the
    ///   character to the left is already whitespace (or there is nothing to the
    ///   left), and after on the same rule — so `look at|this` becomes
    ///   `look at /…/x.png this` rather than `look at/…/x.pngthis`, and a draft
    ///   that already had a space does not get two.
    /// * **it is idempotent.** A path already in this draft is not added again:
    ///   the retry of a flaky upload lands on the same content-addressed path
    ///   (`uploads.py` rule 2), and a second tile for one image would be the
    ///   app disagreeing with itself.
    /// * **the caret lands past everything inserted**, including the trailing
    ///   space, so the next keystroke continues the sentence instead of gluing
    ///   itself to the extension.
    public static func inserting(_ path: String, into text: String,
                                 at caret: Int? = nil) -> Result {
        let chars = Array(text)
        guard !UploadPath.paths(in: text).contains(path) else {
            return Result(text: text, caret: caret ?? chars.count)
        }
        let at = min(max(caret ?? chars.count, 0), chars.count)
        let lead = at > 0 && !chars[at - 1].isWhitespace ? " " : ""
        let trail = at == chars.count || !chars[at].isWhitespace ? " " : ""
        let inserted = lead + path + trail
        var out = chars
        out.insert(contentsOf: Array(inserted), at: at)
        return Result(text: String(out), caret: at + inserted.count)
    }

    /// Take `path` out again — **every occurrence**, and one adjacent space with
    /// each, so removing the middle attachment of three does not leave a double
    /// space behind. This is what the tile's ✕ does, and it is the only removal
    /// there is: the text is the attachment.
    public static func removing(_ path: String, from text: String) -> String {
        var chars = Array(text)
        for hit in UploadPath.hits(in: text).reversed() where hit.path == path {
            var lo = hit.range.lowerBound, hi = hit.range.upperBound
            // Eat the separator on the side that has one, preferring the left so
            // that text before the path keeps the space it was written with.
            if lo > 0, chars[lo - 1].isWhitespace, hi < chars.count, chars[hi].isWhitespace {
                lo -= 1
            } else if lo == 0, hi < chars.count, chars[hi].isWhitespace {
                hi += 1
            } else if hi == chars.count, lo > 0, chars[lo - 1].isWhitespace {
                lo -= 1
            }
            chars.removeSubrange(lo..<hi)
        }
        return String(chars)
    }
}

/// What this client refuses to put on the wire, and why — decided **before** a
/// fourteen-megabyte request is fired at a Mac over a tailnet.
///
/// The server caps this route twice (`uploads.py` rule 4): `server.do_POST`
/// reads the `Content-Length` and answers **413** above `uploads.max_body()`,
/// and `uploads.receive` refuses the decoded length above `upload_max_mb`. Both
/// are correct and neither is a good user experience from a phone on a tunnel:
/// the phone would spend the whole upload before being told. So the same
/// arithmetic is done here, on the value, and the refusal is local and instant.
///
/// It is arithmetic and not a guess — `bodyBytes` is the exact byte count of the
/// JSON this client will send, so the two ends agree to the byte.
public enum UploadBudget {

    /// `upload_max_mb`'s default, in bytes — the cap on ONE image, decoded.
    ///
    /// A **default**, and the client says so when it refuses: the knob is on the
    /// Mac, and a user photographing a whiteboard at 48 MP can raise it. A
    /// client that hard-refused at 10 MB would be lying about a limit it does
    /// not own, so this bound is only ever used to avoid a doomed request — a
    /// server with a bigger knob still answers a bigger upload if one gets sent.
    public static let maxImageBytes = 10 * 1024 * 1024

    /// `uploads.ENVELOPE_SLACK` — the room the server leaves for the JSON around
    /// the base64.
    public static let envelopeSlack = 4096

    /// `uploads._b64_len` — 4 characters out per 3 bytes in, padded.
    public static func encodedLength(ofRawBytes n: Int) -> Int { (n + 2) / 3 * 4 }

    /// `uploads.max_body()` — **13,985,112 bytes** at the default knob, and the
    /// number `server.do_POST` compares the `Content-Length` against.
    public static var maxBodyBytes: Int {
        encodedLength(ofRawBytes: maxImageBytes) + envelopeSlack
    }

    /// The longest `name` hint this client will send. The server discards it
    /// entirely (`uploads.receive`: *"an optional hint and is discarded"*), so
    /// its only job is to stay small enough that the envelope can never eat the
    /// slack the cap was computed with.
    public static let maxNameBytes = 128

    /// The exact size of the body this client will POST for `n` raw bytes.
    ///
    /// The envelope is measured rather than estimated: `{"data":"…","name":"…"}`
    /// with a name that may contain a quote, a backslash or an emoji, all of
    /// which JSON escaping lengthens. Everything but the base64 itself is short,
    /// so measuring it costs nothing and removes the last place the two ends
    /// could disagree.
    public static func bodyBytes(rawBytes n: Int, name: String?) -> Int {
        encodedLength(ofRawBytes: n) + envelopeBytes(name: name)
    }

    /// `{"data":"","name":"<escaped>"}`, or `{"data":""}` with no hint.
    static func envelopeBytes(name: String?) -> Int {
        var object: [String: String] = ["data": ""]
        if let name = clip(name) { object["name"] = name }
        guard let data = try? JSONSerialization.data(withJSONObject: object) else {
            // Unreachable — a dictionary of two Strings always encodes — but a
            // fallback that OVER-estimates is the safe direction for a cap.
            return 32 + (name?.utf8.count ?? 0) * 6
        }
        return data.count
    }

    /// The hint, trimmed to something that cannot matter. Never a path — only
    /// the last component — because a filename is all a hint could ever be and
    /// the directories above it are this phone's business.
    public static func clip(_ name: String?) -> String? {
        guard var name = name?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty else { return nil }
        if let slash = name.lastIndex(of: "/") { name = String(name[name.index(after: slash)...]) }
        while name.utf8.count > maxNameBytes { name.removeLast() }
        return name.isEmpty ? nil : name
    }

    /// `nil` if this will fit; otherwise the sentence to show, in the app's own
    /// voice because the server never got to write one.
    ///
    /// Both caps are checked. The decoded one is the knob the user can change and
    /// is named as such; the body one is a consequence of it and can only bind
    /// if a caller sent a hint longer than `maxNameBytes`, but it is checked
    /// because `server.do_POST` checks it and an unchecked cap is a 413 nobody
    /// predicted.
    public static func refusal(rawBytes: Int, name: String? = nil) -> String? {
        guard rawBytes > 0 else {
            return "that file is empty — there are no bytes to send."
        }
        let body = bodyBytes(rawBytes: rawBytes, name: name)
        guard rawBytes > maxImageBytes || body > maxBodyBytes else { return nil }
        return "that image is \(megabytes(rawBytes)) even after this phone shrank "
            + "it, over the \(megabytes(maxImageBytes)) one upload carries. Pick a "
            + "smaller image, or raise upload_max_mb on the Mac."
    }

    /// One decimal, always — `1.0 MB`, never `1 MB` — so two sizes in one
    /// sentence line up and the reader can tell which is bigger at a glance.
    public static func megabytes(_ bytes: Int) -> String {
        String(format: "%.1f MB", Double(bytes) / 1_048_576)
    }
}
