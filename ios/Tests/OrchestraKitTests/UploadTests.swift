import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import OrchestraKit

// The client half of `POST /api/v1/uploads`, pinned as five separate rules.
//
// The feature is "attach a screenshot to a message", and it is built on a single
// source of truth: **the uploaded path is plain text in the draft**. Everything
// visible follows from that — the thumbnail strip parses the draft, deleting the
// path deletes the attachment, and persistence is whatever `DraftStore` already
// does with a String. So the things that must not drift are all pure functions,
// and they are all here rather than in a screenshot.

/// `~/.orchestra/uploads/<YYYY-MM-DD>/<16 hex>.<ext>` — the shape the strip
/// reads back out of the draft.
struct UploadPathTests {

    /// The exact reply the live server gave on 2026-08-06, driven with curl.
    static let real = "/Users/achill/.orchestra/uploads/2026-08-06/c414cd0e204de974.png"

    @Test func aPathTheServerActuallyWroteIsRecognised() {
        #expect(UploadPath.isUpload(Self.real))
        #expect(UploadPath.paths(in: Self.real) == [Self.real])
    }

    /// **`jpeg` is the kind; `.jpg` is the extension.** They are different words
    /// in `uploads.KINDS`, and a rule that looked for `.jpeg` would never match a
    /// photo — which is every camera image this feature sends.
    @Test func everyExtensionTheServerWritesIsAccepted() {
        for ext in ["png", "jpg", "gif", "webp", "heic", "heif"] {
            let path = "/Users/x/.orchestra/uploads/2026-08-06/0123456789abcdef.\(ext)"
            #expect(UploadPath.isUpload(path), "\(ext) should be an upload path")
        }
        #expect(ImageSniff.Kind.jpeg.fileExtension == "jpg")
        #expect(UploadPath.isUpload(
            "/Users/x/.orchestra/uploads/2026-08-06/0123456789abcdef.jpeg") == false)
    }

    /// The name is sixteen LOWERCASE hex characters — the head of a sha256. Not
    /// fifteen, not seventeen, not upper case, which is not a name this server
    /// writes and therefore not one this rule claims.
    @Test func theNameShapeIsExact() {
        let stem = "/Users/x/.orchestra/uploads/2026-08-06/"
        #expect(UploadPath.isUpload(stem + "0123456789abcdef.png"))
        #expect(UploadPath.isUpload(stem + "0123456789abcde.png") == false)
        #expect(UploadPath.isUpload(stem + "0123456789abcdef0.png") == false)
        #expect(UploadPath.isUpload(stem + "0123456789ABCDEF.png") == false)
        #expect(UploadPath.isUpload(stem + "0123456789abcdeg.png") == false)
        #expect(UploadPath.isUpload(stem + "0123456789abcdef.txt") == false)
        #expect(UploadPath.isUpload(stem + "0123456789abcdef") == false)
    }

    @Test func theDayDirectoryIsADate() {
        let name = "/0123456789abcdef.png"
        for day in ["2026-08-06", "1999-12-31"] {
            #expect(UploadPath.isUpload("/Users/x/.orchestra/uploads/\(day)\(name)"))
        }
        for day in ["2026-8-6", "yesterday", "20260806", "2026-08-060", ""] {
            #expect(UploadPath.isUpload("/Users/x/.orchestra/uploads/\(day)\(name)") == false,
                    "\(day) is not a day directory")
        }
    }

    /// Relative paths, traversals and near misses in the two fixed components.
    @Test func onlyAnAbsolutePathUnderTheRealRootCounts() {
        let tail = "/uploads/2026-08-06/0123456789abcdef.png"
        #expect(UploadPath.isUpload("Users/x/.orchestra" + tail) == false)
        #expect(UploadPath.isUpload("/Users/x/../x/.orchestra" + tail) == false)
        #expect(UploadPath.isUpload("/Users/x/orchestra" + tail) == false)
        #expect(UploadPath.isUpload("/Users/x/.orchestra/upload/2026-08-06/0123456789abcdef.png") == false)
        // The home prefix itself is NOT checked: it is the server's home, this
        // phone cannot know it, and the tests on the Mac rebind it to a tmpdir.
        #expect(UploadPath.isUpload("/tmp/pytest-of-achill/t0/.orchestra" + tail))
    }

    /// A path written into a sentence. This is the case that decides whether the
    /// strip keeps the attachment once the user explains what it is.
    @Test func aPathInProseIsStillFound() {
        let p = Self.real
        let sentences = [
            "look at \(p) — the button is cut off",
            "see \(p), the label wraps",
            "`\(p)`",
            "(\(p))",
            "here: \(p).",
            "\(p)\nand also this",
        ]
        for text in sentences {
            #expect(UploadPath.paths(in: text) == [p], "not found in: \(text)")
        }
    }

    /// A token that merely *ends* with an upload-shaped suffix is not one. The
    /// rule tokenises on whitespace rather than matching a substring, so a path
    /// glued to something else is left alone.
    @Test func anUploadShapedSuffixInsideALongerTokenIsNotAPath() {
        #expect(UploadPath.paths(in: "prefix\(Self.real)").isEmpty)
        #expect(UploadPath.paths(in: "file://\(Self.real)").isEmpty)
    }

    /// Order preserved, duplicates collapsed — one tile per attachment even if
    /// the user pasted the same path twice.
    @Test func pathsComeBackInOrderAndOnlyOnce() {
        let a = "/Users/x/.orchestra/uploads/2026-08-06/aaaaaaaaaaaaaaaa.png"
        let b = "/Users/x/.orchestra/uploads/2026-08-06/bbbbbbbbbbbbbbbb.jpg"
        #expect(UploadPath.paths(in: "\(b) then \(a) then \(b)") == [b, a])
    }

    @Test func aDraftWithNoAttachmentHasNoPaths() {
        #expect(UploadPath.paths(in: "").isEmpty)
        #expect(UploadPath.paths(in: "just some words about /Users/x/foo.png").isEmpty)
    }
}

/// Putting the path into the draft, and taking it back out.
struct DraftAttachmentTests {

    static let path = "/Users/achill/.orchestra/uploads/2026-08-06/c414cd0e204de974.png"

    /// An empty composer: the path and a trailing space, caret past both, so the
    /// next keystroke starts a sentence rather than extending the extension.
    @Test func intoAnEmptyDraftItIsThePathAndASpace() {
        let out = DraftAttachment.inserting(Self.path, into: "")
        #expect(out.text == Self.path + " ")
        #expect(out.caret == out.text.count)
    }

    /// No caret: appended. This is the fallback the brief allows, and it has to
    /// be right because it is what an unfocused composer gets.
    @Test func withNoCaretItAppends() {
        let out = DraftAttachment.inserting(Self.path, into: "what is wrong here?")
        #expect(out.text == "what is wrong here? \(Self.path) ")
    }

    /// **It never fuses with a neighbour, and never doubles a space.**
    @Test func separatorsAreAddedOnlyWhereTheyAreMissing() {
        // caret mid-word, on both sides: a space goes in on both sides.
        let a = DraftAttachment.inserting(Self.path, into: "lookhere", at: 4)
        #expect(a.text == "look \(Self.path) here")
        // caret after an existing space: no second one on the left.
        let b = DraftAttachment.inserting(Self.path, into: "look here", at: 5)
        #expect(b.text == "look \(Self.path) here")
        // caret before an existing space: no second one on the right.
        let c = DraftAttachment.inserting(Self.path, into: "look here", at: 4)
        #expect(c.text == "look \(Self.path) here")
        // at the very start of text that already begins with a space.
        let d = DraftAttachment.inserting(Self.path, into: " here", at: 0)
        #expect(d.text == "\(Self.path) here")
    }

    @Test func theCaretLandsPastEverythingInserted() {
        let out = DraftAttachment.inserting(Self.path, into: "lookhere", at: 4)
        let caretIsAt = out.text.index(out.text.startIndex, offsetBy: out.caret)
        #expect(out.text[caretIsAt...] == "here")
    }

    /// **Idempotent.** The upload is content-addressed, so a retry over a flaky
    /// tailnet answers with the same path — and a second tile for one image
    /// would be the app disagreeing with itself.
    @Test func insertingTheSamePathTwiceChangesNothing() {
        let once = DraftAttachment.inserting(Self.path, into: "before ", at: 7)
        let twice = DraftAttachment.inserting(Self.path, into: once.text, at: 3)
        #expect(twice.text == once.text)
        // A different upload still goes in.
        let other = "/Users/achill/.orchestra/uploads/2026-08-06/ffffffffffffffff.jpg"
        let both = DraftAttachment.inserting(other, into: once.text)
        #expect(UploadPath.paths(in: both.text) == [Self.path, other])
    }

    @Test func anOutOfRangeCaretClamps() {
        #expect(DraftAttachment.inserting(Self.path, into: "abc", at: 99).text
                == "abc \(Self.path) ")
        #expect(DraftAttachment.inserting(Self.path, into: "abc", at: -5).text
                == "\(Self.path) abc")
    }

    /// **The crash, as a test.** The first real upload driven from a simulator
    /// took the app down with `EXC_BREAKPOINT` in
    /// `_StringGuts.validateInclusiveSubscalarIndex_5_7`: SwiftUI's
    /// `TextSelection` hands back a `String.Index` belonging to whatever the
    /// field's text was when the selection was made, the draft had since been
    /// hydrated from `DraftStore`, and measuring an index past the end of a
    /// string is not a wrong answer — it is a trap.
    @Test func aCaretFromAnotherStringIsNoCaretRatherThanACrash() {
        let was = "a draft that was much longer than this one, once upon a time"
        let stale = was.index(was.startIndex, offsetBy: 55)
        #expect(DraftAttachment.caret(at: stale, in: "short") == nil)
        // And an insert given that selection still works — it appends.
        let caret = DraftAttachment.caret(at: stale, in: "short")
        #expect(DraftAttachment.inserting(Self.path, into: "short", at: caret).text
                == "short \(Self.path) ")
    }

    /// An index that IS inside the string is measured, foreign or not — that is
    /// the case the caret exists for, and the bounds check must not eat it.
    @Test func anInBoundsIndexIsStillACaret() {
        let text = "look here"
        #expect(DraftAttachment.caret(at: text.startIndex, in: text) == 0)
        #expect(DraftAttachment.caret(at: text.endIndex, in: text) == 9)
        let twin = "0123456789"
        #expect(DraftAttachment.caret(at: twin.index(twin.startIndex, offsetBy: 4),
                                      in: text) == 4)
    }

    /// Removal takes the path **and one adjacent space**, so pulling the middle
    /// attachment out of three does not leave a gap behind.
    @Test func removingTakesTheSeparatorWithIt() {
        let a = "/Users/x/.orchestra/uploads/2026-08-06/aaaaaaaaaaaaaaaa.png"
        let b = "/Users/x/.orchestra/uploads/2026-08-06/bbbbbbbbbbbbbbbb.png"
        let c = "/Users/x/.orchestra/uploads/2026-08-06/cccccccccccccccc.png"
        let text = "\(a) \(b) \(c) look"
        #expect(DraftAttachment.removing(b, from: text) == "\(a) \(c) look")
        #expect(DraftAttachment.removing(a, from: text) == "\(b) \(c) look")
        #expect(DraftAttachment.removing(c, from: text) == "\(a) \(b) look")
    }

    @Test func removingTheOnlyAttachmentLeavesTheProse() {
        #expect(DraftAttachment.removing(Self.path, from: "\(Self.path) ") == "")
        #expect(DraftAttachment.removing(Self.path, from: "look at \(Self.path)") == "look at")
        #expect(DraftAttachment.removing(Self.path, from: "\(Self.path) look") == "look")
        #expect(DraftAttachment.removing(Self.path, from: "a \(Self.path) b") == "a b")
    }

    /// Every occurrence, and a no-op when there is none.
    @Test func removingIsTotalAndSafe() {
        let text = "\(Self.path) and again \(Self.path)"
        #expect(UploadPath.paths(in: DraftAttachment.removing(Self.path, from: text)).isEmpty)
        #expect(DraftAttachment.removing(Self.path, from: "nothing here") == "nothing here")
    }

    /// **Insert then remove is the identity on the attachment**, which is the
    /// whole promise of "the text is the only model": nothing else has to be
    /// cleaned up.
    @Test func insertThenRemoveLeavesNoTrace() {
        for draft in ["", "why is this broken", "a b c "] {
            let after = DraftAttachment.inserting(Self.path, into: draft)
            #expect(UploadPath.paths(in: after.text) == [Self.path])
            let back = DraftAttachment.removing(Self.path, from: after.text)
            #expect(UploadPath.paths(in: back).isEmpty)
        }
    }
}

/// The encoded-size precheck — refuse locally rather than push fourteen
/// megabytes through a tunnel to be refused there.
struct UploadBudgetTests {

    /// `uploads._b64_len` — 4 characters out per 3 bytes in, padded.
    @Test func theEncodedLengthMatchesTheServersArithmetic() {
        for raw in [0, 1, 2, 3, 4, 70, 999, 1_048_576] {
            let expected = Data(repeating: 0x41, count: raw).base64EncodedString().count
            #expect(UploadBudget.encodedLength(ofRawBytes: raw) == expected, "\(raw) bytes")
        }
    }

    /// **13,985,112** — `uploads.max_body()` at the default `upload_max_mb: 10`,
    /// and the number `server.do_POST` compares the `Content-Length` against
    /// before it reads a byte. Read off the running server.
    @Test func theBodyCapIsTheServersOwnNumber() {
        #expect(UploadBudget.maxImageBytes == 10 * 1024 * 1024)
        #expect(UploadBudget.envelopeSlack == 4096)
        #expect(UploadBudget.maxBodyBytes == 13_985_112)
    }

    /// **The precheck agrees with the body that will actually be sent, to the
    /// byte.** This is the assertion that makes the local refusal trustworthy:
    /// `bodyBytes` is not an estimate, it is the length of the JSON
    /// `Endpoint.upload` builds.
    @Test func thePredictedBodyIsTheRealBody() throws {
        for (raw, name) in [(70, "IMG_0421.PNG"), (3, nil), (100_000, "a \"quoted\" 📷.heic"),
                            (12_345, String(repeating: "x", count: 400))] as [(Int, String?)] {
            let bytes = Data(repeating: 0x2A, count: raw)
            let endpoint = try Endpoint.upload(base64: bytes.base64EncodedString(), name: name)
            let body = try #require(endpoint.body)
            #expect(body.count == UploadBudget.bodyBytes(rawBytes: raw, name: name),
                    "\(raw) bytes named \(name ?? "nothing")")
        }
    }

    @Test func whatFitsIsNotRefusedAndWhatDoesNotIs() {
        #expect(UploadBudget.refusal(rawBytes: 70) == nil)
        #expect(UploadBudget.refusal(rawBytes: UploadBudget.maxImageBytes) == nil)
        let over = try! #require(UploadBudget.refusal(rawBytes: UploadBudget.maxImageBytes + 1))
        // The sentence names both numbers and the knob, because the person
        // holding the phone cannot change the limit and the person at the Mac can.
        #expect(over.contains("10.0 MB"))
        #expect(over.contains("upload_max_mb"))
        #expect(try! #require(UploadBudget.refusal(rawBytes: 0)).contains("empty"))
    }

    /// The `name` hint is clipped to something that cannot eat the envelope
    /// slack the cap was computed with — and it is never a path.
    @Test func theNameHintIsClippedAndIsNeverAPath() {
        #expect(UploadBudget.clip("/private/var/tmp/IMG_0421.PNG") == "IMG_0421.PNG")
        #expect(UploadBudget.clip("   ") == nil)
        #expect(UploadBudget.clip(nil) == nil)
        let long = try! #require(UploadBudget.clip(String(repeating: "z", count: 4000)))
        #expect(long.utf8.count <= UploadBudget.maxNameBytes)
    }

    /// A hint at its maximum still leaves the whole body inside the server's cap
    /// for an image at the decoded maximum — which is the only way the two caps
    /// can both be satisfied at once.
    @Test func aMaximalNameStillFitsInsideTheServersBodyCap() {
        let name = String(repeating: "é", count: UploadBudget.maxNameBytes / 2)
        #expect(UploadBudget.bodyBytes(rawBytes: UploadBudget.maxImageBytes, name: name)
                <= UploadBudget.maxBodyBytes)
    }
}

/// Both wire bodies behind the route's single 200.
struct UploadWireTests {

    /// **The exact success body from the live server**, 2026-08-06, driven with
    /// curl against `127.0.0.1:4242`.
    @Test func theSuccessBodyDecodes() throws {
        let json = #"""
        {"ok": true, "path": "/Users/achill/.orchestra/uploads/2026-08-06/c414cd0e204de974.png", "bytes": 70, "kind": "png", "name": "c414cd0e204de974.png"}
        """#
        let reply = try JSONDecoder().decode(UploadReply.self, from: Data(json.utf8))
        guard case .written(let upload) = reply else {
            Issue.record("expected a written upload, got \(reply)")
            return
        }
        #expect(upload.path == "/Users/achill/.orchestra/uploads/2026-08-06/c414cd0e204de974.png")
        #expect(upload.bytes == 70)
        #expect(upload.kind == "png")
        #expect(upload.name == "c414cd0e204de974.png")
        // The path the server wrote is a path the strip will find.
        #expect(UploadPath.isUpload(upload.path))
    }

    /// **A refusal is a 200 with `ok: false`** and the reason is a sentence for
    /// the person holding the phone, not a code. Every one of these is written
    /// verbatim by `uploads._refuse`.
    @Test func everyRefusalSentenceSurvivesVerbatim() throws {
        let sentences = [
            "that is not an image this server writes to disk — it arrived as a PDF, and only PNG, JPEG, GIF, WebP and HEIC/HEIF are accepted.",
            "that image is 12.4 MB, over the 10 MB limit this server writes (upload_max_mb).",
            "the `data` field is not valid base64 — send the file's bytes base64-encoded, with nothing else in the string.",
            "that upload decoded to zero bytes.",
        ]
        for sentence in sentences {
            let body = try JSONSerialization.data(
                withJSONObject: ["ok": false, "error": sentence])
            let reply = try JSONDecoder().decode(UploadReply.self, from: body)
            #expect(reply == .refused(sentence))
            #expect(reply.path == nil)
        }
    }

    /// A body this client does not recognise is **not** a success. An absent
    /// `ok` reading as true would put a nil path into somebody's draft.
    @Test func anUnrecognisedBodyIsARefusalRatherThanASuccess() throws {
        let reply = try JSONDecoder().decode(UploadReply.self, from: Data("{}".utf8))
        guard case .refused(let why) = reply else {
            Issue.record("an empty body must not decode as a success")
            return
        }
        #expect(!why.isEmpty)
        // `message` is read as a fallback, because the door failures above this
        // layer use that key.
        let fallback = try JSONDecoder().decode(
            UploadReply.self, from: Data(#"{"ok": false, "message": "nope"}"#.utf8))
        #expect(fallback == .refused("nope"))
    }

    /// The route, as `server.do_POST` matches it.
    @Test func theEndpointIsTheRouteTheServerSpells() throws {
        let endpoint = try Endpoint.upload(base64: "aGk=", name: "x.png")
        #expect(endpoint.path == "/api/v1/uploads")
        #expect(endpoint.method == .post)
        #expect(endpoint.requiresToken)
        #expect(endpoint.strictQueryEncoding == false)   // a body, not a query
        #expect(endpoint.query.isEmpty)
        let request = try endpoint.urlRequest(base: URL(string: "http://127.0.0.1:4242")!,
                                              token: "tok")
        // The CSRF guard. Without it the server answers 415 before a handler runs.
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer tok")
        #expect(request.url?.absoluteString == "http://127.0.0.1:4242/api/v1/uploads")
    }

    /// **No `Idempotency-Key`, deliberately.** The route is absent from
    /// `idem.MUTATION_ROUTES` because the filename is the content's own digest:
    /// a retry lands on the same path and writes no second file. Sending a key
    /// would be a claim about a contract that is not there.
    @Test func theUploadCarriesNoIdempotencyKeyOnPurpose() throws {
        let endpoint = try Endpoint.upload(base64: "aGk=", name: nil)
        #expect(endpoint.idempotency == nil)
        let request = try endpoint.urlRequest(base: URL(string: "http://h")!, token: "t")
        #expect(request.value(forHTTPHeaderField: "Idempotency-Key") == nil)
        #expect(request.value(forHTTPHeaderField: "Idempotency-Issued-At") == nil)
    }

    /// The body is the two documented keys and nothing else, and `name` is
    /// omitted rather than sent empty.
    @Test func theBodyIsDataAndAnOptionalName() throws {
        let with = try #require(try Endpoint.upload(base64: "aGk=", name: "IMG.PNG").body)
        let a = try #require(try JSONSerialization.jsonObject(with: with) as? [String: String])
        #expect(a == ["data": "aGk=", "name": "IMG.PNG"])
        let without = try #require(try Endpoint.upload(base64: "aGk=", name: "  ").body)
        let b = try #require(try JSONSerialization.jsonObject(with: without) as? [String: String])
        #expect(b == ["data": "aGk="])
    }

    /// The two door failures only this route can produce get named sentences.
    /// "the server said 415" would send somebody looking in the wrong place.
    @Test func theDoorFailuresAreNamedRatherThanNumbered() {
        #expect(UploadStore.sentence(for: .http(status: 413, refusal: nil))
                    .contains("upload_max_mb"))
        #expect(UploadStore.sentence(for: .http(status: 415, refusal: nil))
                    .contains("bug in this build"))
        #expect(UploadStore.sentence(for: .serverStopped).contains("./start.sh"))
    }
}

/// What the phone does to the pixels before they leave — and the one thing it
/// must never do to a screenshot.
struct ImagePrepTests {

    /// Every current iPhone screenshot, long edge first. The legibility
    /// requirement lives on this list.
    static let screenshots: [(String, Int, Int)] = [
        ("iPhone 17 Pro Max / 15 Pro Max", 1290, 2796),
        ("iPhone 16 Pro Max", 1320, 2868),
        ("iPhone 16 Pro", 1206, 2622),
        ("iPhone 15 / 16", 1179, 2556),
        ("iPhone 13 / 14", 1170, 2532),
        ("iPhone SE", 750, 1334),
    ]

    // MARK: - sniffing, exactly as `uploads.sniff` does it

    @Test func theTypeComesFromTheBytes() {
        #expect(ImageSniff.kind(of: Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])) == .png)
        #expect(ImageSniff.kind(of: Data([0xFF, 0xD8, 0xFF, 0xE0])) == .jpeg)
        #expect(ImageSniff.kind(of: Data("GIF87a…".utf8)) == .gif)
        #expect(ImageSniff.kind(of: Data("GIF89a…".utf8)) == .gif)
        #expect(ImageSniff.kind(of: Data("RIFF1234WEBPVP8 ".utf8)) == .webp)
        // RIFF alone is also WAV and AVI — the form type at byte 8 is the test.
        #expect(ImageSniff.kind(of: Data("RIFF1234WAVEfmt ".utf8)) == nil)
        #expect(ImageSniff.kind(of: Data()) == nil)
        #expect(ImageSniff.kind(of: Data("%PDF-1.7".utf8)) == nil)
    }

    /// HEIC is not one magic number — it is the brands in the `ftyp` box, and
    /// `heic` outranks `heif` when both are declared (an edited iPhone still is
    /// `mif1`-major with `heic` further down the compatible list).
    @Test func heifIsReadOutOfTheBrandList() {
        #expect(ImageSniff.kind(of: ftyp(major: "heic")) == .heic)
        #expect(ImageSniff.kind(of: ftyp(major: "mif1")) == .heif)
        #expect(ImageSniff.kind(of: ftyp(major: "mif1", compatible: ["mif1", "heic"])) == .heic)
        // The MP4/MOV family shares the container and is not a still.
        #expect(ImageSniff.kind(of: ftyp(major: "isom", compatible: ["isom", "mp42"])) == nil)
        #expect(ImageSniff.kind(of: ftyp(major: "qt  ")) == nil)
        #expect(ImageSniff.kind(of: ftyp(major: "avif")) == nil)
    }

    /// An `ftyp` box with a declared length the caller controls. The walk must
    /// be bounded by what actually arrived, not by what the box claims.
    @Test func aLyingFtypLengthCannotWalkPastTheData() {
        var bytes = Data([0xFF, 0xFF, 0xFF, 0xFF])      // a four-gigabyte box
        bytes.append(Data("ftyp".utf8))
        bytes.append(Data("heic".utf8))
        #expect(ImageSniff.kind(of: bytes) == .heic)
    }

    // MARK: - the decision, without any pixels

    /// **The rule this whole feature is judged on.** A screenshot is a PNG and
    /// its long edge is under the cap, so it is sent byte for byte: no resample,
    /// no lossy encoder, the pixels that arrive are the pixels that were on the
    /// screen.
    @Test func everyIPhoneScreenshotIsSentUntouched() {
        for (device, w, h) in Self.screenshots {
            #expect(max(w, h) <= ImagePrep.longEdgeCap,
                    "\(device) is \(max(w, h)) px, over the \(ImagePrep.longEdgeCap) px cap — it would be resampled and its UI text degraded")
            let decision = ImagePrep.decide(kind: .png, bytes: 900_000, longEdge: max(w, h))
            #expect(decision == .passthrough, "\(device) would not be sent as-is")
        }
    }

    /// The four formats the reader at the far end accepts pass through; **HEIC
    /// never does**, which is the entire reason this file exists — an iPhone
    /// shoots HEIC by default and the server deliberately does not transcode.
    @Test func heicIsAlwaysTranscodedAndTheReadableFourAreNot() {
        for kind in [ImageSniff.Kind.png, .jpeg, .webp] {
            #expect(ImagePrep.decide(kind: kind, bytes: 900_000, longEdge: 2796) == .passthrough,
                    "\(kind) is readable as-is")
        }
        for kind in [ImageSniff.Kind.heic, .heif] {
            #expect(ImagePrep.decide(kind: kind, bytes: 900_000, longEdge: 2796)
                    == .transcode(longEdge: ImagePrep.longEdgeCap, quality: ImagePrep.jpegQuality),
                    "\(kind) must not be sent as-is")
        }
    }

    /// Over the cap in pixels, or over it in bytes: transcoded either way.
    @Test func aCameraFrameIsDownscaledAndAHugePngIsRecompressed() {
        // 12 MP, 4032 on the long edge.
        #expect(ImagePrep.decide(kind: .jpeg, bytes: 3_500_000, longEdge: 4032)
                == .transcode(longEdge: 3024, quality: 0.9))
        // Under the pixel cap, over the byte cap.
        #expect(ImagePrep.decide(kind: .png, bytes: 11 * 1024 * 1024, longEdge: 2000)
                == .transcode(longEdge: 3024, quality: 0.9))
        // Dimensions this phone could not read: transcode rather than guess.
        #expect(ImagePrep.decide(kind: .png, bytes: 900_000, longEdge: nil)
                == .transcode(longEdge: 3024, quality: 0.9))
    }

    /// A GIF is passed through on its byte budget alone and **refused rather
    /// than flattened** when it does not fit — shrinking one here would send
    /// frame zero and silently drop the animation.
    @Test func anAnimationIsNeverSilentlyTurnedIntoAStill() {
        #expect(ImagePrep.decide(kind: .gif, bytes: 900_000, longEdge: 8000) == .passthrough)
        guard case .refuse(let why) = ImagePrep.decide(kind: .gif, bytes: 11 * 1024 * 1024,
                                                       longEdge: 400) else {
            Issue.record("an over-budget GIF must be refused, not transcoded")
            return
        }
        #expect(why.contains("frame"))
    }

    /// Bytes that are not one of the six: refused here, in the same words the
    /// server would have used, without spending the round trip.
    @Test func somethingThatIsNotAnImageIsRefusedBeforeItIsSent() {
        guard case .refuse(let why) = ImagePrep.decide(kind: nil, bytes: 10, longEdge: nil) else {
            Issue.record("a non-image must be refused")
            return
        }
        #expect(why.contains("PNG, JPEG, GIF, WebP and HEIC/HEIF"))
    }

    // MARK: - the real thing, with real pixels

    /// A screenshot-sized PNG comes back **byte-identical**. Not "close": the
    /// same `Data`, because nothing decoded it.
    @Test func aScreenshotSizedPngIsReturnedByteForByte() throws {
        let png = try Self.encode(Self.chart(width: 1290, height: 2796), as: .png)
        let out = try ImagePrep.prepare(png)
        #expect(out.data == png)
        #expect(out.kind == .png)
        #expect(out.transcoded == false)
        #expect(out.pixels?.width == 1290)
        #expect(out.pixels?.height == 2796)
        #expect(out.note.contains("sent as-is"))
    }

    /// A 12 MP camera frame is downscaled to the cap and re-encoded, and the
    /// result actually fits.
    @Test func aTwelveMegapixelFrameIsDownscaledToTheCap() throws {
        let jpeg = try Self.encode(Self.chart(width: 4032, height: 3024), as: .jpeg)
        let out = try ImagePrep.prepare(jpeg)
        #expect(out.transcoded)
        #expect(out.kind == .jpeg)
        #expect(ImageSniff.kind(of: out.data) == .jpeg)
        let size = try #require(ImagePrep.pixelSize(of: out.data))
        #expect(max(size.0, size.1) == ImagePrep.longEdgeCap)
        // Aspect preserved: 4032×3024 is 4:3.
        #expect(abs(Double(size.0) / Double(size.1) - 4.0 / 3.0) < 0.01)
        #expect(UploadBudget.refusal(rawBytes: out.data.count) == nil)
    }

    /// Bytes that are not an image at all: refused with a sentence, never a
    /// crash and never a silent empty upload.
    @Test func rubbishIsRefusedWithASentence() {
        #expect(throws: ImagePrep.Refused.self) {
            try ImagePrep.prepare(Data("#!/bin/sh\necho hello\n".utf8))
        }
        #expect(throws: ImagePrep.Refused.self) {
            try ImagePrep.prepare(Data())
        }
    }

    /// The thumbnail the strip draws is made from the **local** bytes, is small,
    /// and is itself a readable image.
    @Test func theStripsThumbnailIsMadeLocallyAndIsSmall() throws {
        let png = try Self.encode(Self.chart(width: 1290, height: 2796), as: .png)
        let thumb = try #require(ImagePrep.thumbnailJPEG(png))
        #expect(ImageSniff.kind(of: thumb) == .jpeg)
        let size = try #require(ImagePrep.pixelSize(of: thumb))
        #expect(max(size.0, size.1) == 320)
        #expect(thumb.count < png.count)
    }

    // MARK: - fixtures

    /// An `ftyp` box with a real declared length.
    private func ftyp(major: String, compatible: [String] = []) -> Data {
        var body = Data("ftyp".utf8)
        body.append(Data(major.utf8))
        body.append(Data([0, 0, 0, 0]))             // minor version
        for brand in compatible { body.append(Data(brand.utf8)) }
        let size = UInt32(body.count + 4)
        var out = Data([UInt8(size >> 24), UInt8((size >> 16) & 0xFF),
                        UInt8((size >> 8) & 0xFF), UInt8(size & 0xFF)])
        out.append(body)
        return out
    }

    /// A synthetic picture with fine detail, so a downscale is measurable rather
    /// than a flat colour that survives anything.
    static func chart(width: Int, height: Int) -> CGImage {
        let space = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                            bytesPerRow: 0, space: space,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        // One-pixel rules every four pixels — the highest frequency the image can
        // carry, which is exactly what a resample destroys first.
        for y in stride(from: 0, to: height, by: 4) {
            ctx.fill(CGRect(x: 0, y: y, width: width, height: 1))
        }
        return ctx.makeImage()!
    }

    static func encode(_ image: CGImage, as type: UTType) throws -> Data {
        let out = NSMutableData()
        let made = CGImageDestinationCreateWithData(out as CFMutableData,
                                                    type.identifier as CFString, 1, nil)
        let dest = try #require(made)
        let options = [kCGImageDestinationLossyCompressionQuality: 0.95] as CFDictionary
        CGImageDestinationAddImage(dest, image, options)
        #expect(CGImageDestinationFinalize(dest))
        return out as Data
    }
}
