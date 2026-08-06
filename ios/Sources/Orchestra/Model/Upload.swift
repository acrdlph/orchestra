import Foundation

/// `POST /api/v1/uploads` — one image written to the Mac.
///
/// **Two entirely different bodies behind one 200**, and the exception is the
/// server's and is deliberate (`server.do_POST`): every other `/api/v1` route
/// answers a refusal with a real status because a Swift client has to branch on
/// it, and this one does not, because every refusal here is something *the
/// person holding the phone* has to fix — that was a video, that photo is too
/// big. What the app needs is a sentence to show, not a code to switch on. Real
/// statuses are kept for door failures the handler answers before this function
/// is reached: 401, 415 (no `Content-Type: application/json` — the CSRF guard),
/// 413 (over `uploads.max_body()`), 411, 400, 403, 429.
///
/// So it is modelled as two outcomes rather than one struct full of optionals,
/// the same way `DispatchStart` is: the call site must branch, and a `path` that
/// is `nil` half the time is a branch waiting to be forgotten.
public enum UploadReply: Sendable, Equatable, Decodable {
    /// The bytes are on the Mac and this is where. Handed to the composer, which
    /// puts the path into the draft as text and nothing more.
    case written(Upload)
    /// The server declined, in its own words. **Shown verbatim**, like every
    /// other refusal in this app.
    case refused(String)

    enum CodingKeys: String, CodingKey { case ok, error, message }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Absent `ok` reads as false. A body this client does not recognise is
        // not a success, and treating it as one would put a `nil` path into a
        // draft.
        if try c.decodeIfPresent(Bool.self, forKey: .ok) ?? false {
            self = .written(try Upload(from: decoder))
        } else {
            // `uploads._refuse` always writes `error`. `message` is read as a
            // fallback because the door failures above this layer use that key,
            // and a refusal with no sentence at all still has to say something.
            let sentence = try c.decodeIfPresent(String.self, forKey: .error)
                ?? c.decodeIfPresent(String.self, forKey: .message)
            self = .refused(sentence ?? "the server refused that upload and did not say why.")
        }
    }

    /// The path, or nil. For the one caller that only wants to know whether to
    /// touch the draft.
    public var path: String? {
        if case .written(let upload) = self { return upload.path }
        return nil
    }
}

/// The success half: an absolute path on the Mac, and the three facts about what
/// landed there.
public struct Upload: Sendable, Equatable, Decodable {
    /// `~/.orchestra/uploads/<YYYY-MM-DD>/<16 hex>.<ext>`, absolute and expanded.
    /// **The only thing the app does with it is put it in the message** — see
    /// `UploadPath`.
    public let path: String
    /// The DECODED size. Not what was sent (base64 is a third larger) and not
    /// what the picker reported.
    public let bytes: Int
    /// Sniffed from the magic bytes server-side; the name this client sent had
    /// no say in it. One of `png jpeg gif webp heic heif`.
    public let kind: String
    /// The name the SERVER chose — `sha256(bytes)[:16]` and the sniffed
    /// extension. Content-addressed, which is what makes a retry free: the same
    /// image uploaded twice lands on the same path and writes no second file.
    public let name: String

    public init(path: String, bytes: Int, kind: String, name: String) {
        self.path = path
        self.bytes = bytes
        self.kind = kind
        self.name = name
    }
}
