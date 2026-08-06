import Foundation
import Observation

/// One image on its way to the Mac, and the thumbnails of the ones that got
/// there.
///
/// **App-level, and for `DraftStore`'s reason.** The biometric gate swaps the
/// whole paired subtree for `LockView` on every background, taking the composer
/// and every `@State` in it — so an upload in flight, and the small local
/// pictures the strip draws, must live somewhere the lock cannot reach. The
/// draft itself already does (`DraftStore`), and the path is *in* the draft, so
/// an attachment survives a re-lock for free. This store holds only the two
/// things that are not text: what is happening right now, and the pixels.
///
/// **It never invents a download.** A thumbnail is made from the local bytes the
/// user just picked, keyed by the path the server answered with. A path whose
/// image is not in the cache — a draft restored after a cold launch, an upload
/// from another device — draws a plain tile that says where the file is, which
/// is true, instead of fetching a picture back off a route that does not exist.
@MainActor
@Observable
public final class UploadStore {

    /// Where one upload has got to. There is at most one at a time on purpose:
    /// the control is a single button in a composer, and two concurrent uploads
    /// would need two progress bars to be honest about.
    public enum Phase: Equatable, Sendable {
        case idle
        /// Decoding, downscaling and re-encoding on this phone. Genuinely
        /// visible for a 12 MP HEIC, and it is not network time — saying
        /// "uploading" here would be the first small lie.
        case preparing
        /// Bytes on the wire, `0...1`, from `URLSession`'s own
        /// `didSendBodyData`.
        case sending(Double)
        /// **The server's sentence, verbatim** — or this phone's own, when it
        /// refused before sending. Non-blocking: the draft is untouched and the
        /// composer keeps working.
        case failed(String)
    }

    public private(set) var phase: Phase = .idle

    /// How many pictures are kept in memory. A composer shows a handful of
    /// attachments; twelve is comfortably past that, and each is a ~320 px JPEG
    /// (tens of kilobytes), so the whole cache is smaller than one screenshot.
    public static let maxThumbnails = 12

    private var thumbs: [String: Data] = [:]
    /// Least-recently-added first, so the bound evicts something deterministic.
    private var order: [String] = []

    private let client: OrchestraClient

    public init(client: OrchestraClient) {
        self.client = client
    }

    // MARK: - reading

    /// A small JPEG for this path, if this phone is the one that sent it.
    public func thumbnail(for path: String) -> Data? { thumbs[path] }

    public var isBusy: Bool {
        switch phase {
        case .preparing, .sending: true
        case .idle, .failed: false
        }
    }

    /// The failure sentence currently on screen, if any.
    public var failure: String? {
        if case .failed(let why) = phase { return why }
        return nil
    }

    /// Dismiss a failure. Nothing else clears it — a refusal stays until it is
    /// read, because it is the only record of why the picture is not attached.
    public func clearFailure() {
        if case .failed = phase { phase = .idle }
    }

    /// Say no, before anything was picked.
    ///
    /// The demo tap goes through here, and so do the three failures that happen
    /// on this phone rather than on the wire — an item the photo library could
    /// not materialise, a file that would not open. They land in the same place
    /// a server refusal does, because to the person holding the phone they are
    /// the same event: the picture did not attach, and here is why.
    public func refuse(_ sentence: String) {
        phase = .failed(sentence)
    }

    // MARK: - acting

    /// Prepare `raw`, send it, and answer with the path the server wrote — or
    /// `nil`, having put the reason in `phase`.
    ///
    /// **The draft is never this function's business.** It returns a path and the
    /// composer decides where it goes, so a failed upload cannot lose a word of
    /// what the user was writing.
    ///
    /// `isDemo` is passed in rather than held, because this store has no demo
    /// data of its own and a flag kept in two places is a flag that goes stale.
    /// The refusal lives here rather than only on the button so that the
    /// guarantee is in the store and the disabled control is merely the
    /// courtesy — the same split `ChatStore.send` uses.
    @discardableResult
    public func attach(_ raw: Data, name: String?, isDemo: Bool) async -> String? {
        guard !isDemo else {
            phase = .failed(DemoCopy.refusal)
            return nil
        }
        guard !isBusy else { return nil }
        phase = .preparing

        let prepared: ImagePrep.Prepared
        do {
            // Off the main actor: a 12 MP HEIC decode plus a JPEG encode is a
            // few hundred milliseconds, and the board is still drawing.
            prepared = try await Task.detached(priority: .userInitiated) {
                try ImagePrep.prepare(raw)
            }.value
        } catch let refused as ImagePrep.Refused {
            phase = .failed(refused.reason)
            return nil
        } catch {
            phase = .failed("this phone could not read that file as an image.")
            return nil
        }

        // The encoded-size precheck. The server would refuse this too — twice —
        // but not until the phone had pushed fourteen megabytes through a tunnel
        // to be told so.
        if let why = UploadBudget.refusal(rawBytes: prepared.data.count, name: name) {
            phase = .failed(why)
            return nil
        }

        phase = .sending(0)
        let body = prepared.data.base64EncodedString()
        do {
            let reply = try await client.upload(base64: body, name: name) { [weak self] fraction in
                Task { @MainActor in self?.report(fraction) }
            }
            switch reply {
            case .refused(let sentence):
                // Verbatim. `uploads._refuse` writes sentences for the person
                // holding the phone, and paraphrasing one would throw away the
                // remedy it contains.
                phase = .failed(sentence)
                return nil
            case .written(let upload):
                remember(thumbnailOf: prepared.data, for: upload.path)
                phase = .idle
                return upload.path
            }
        } catch let error as OrchestraError {
            phase = .failed(Self.sentence(for: error))
            return nil
        } catch {
            phase = .failed("the upload did not reach the Mac.")
            return nil
        }
    }

    /// Progress only ever moves forward, and only while sending. A late callback
    /// arriving after the response has landed must not put a spinner back on a
    /// composer that is already done.
    private func report(_ fraction: Double) {
        guard case .sending(let current) = phase, fraction > current else { return }
        phase = .sending(fraction)
    }

    /// A door failure, in one line a composer can put under a text field.
    ///
    /// `OrchestraError.guidance` is written for a full-screen failure view and is
    /// two or three sentences long; this is the same information at the size the
    /// composer has. **415 and 413 are named specifically** because they are the
    /// two this route can produce that no other route can, and a bare
    /// "the server said 415" would send somebody looking in the wrong place.
    nonisolated static func sentence(for error: OrchestraError) -> String {
        switch error {
        case .http(413, _):
            "the Mac refused that upload as too large before reading it — "
                + "upload_max_mb decides, and it is set on the Mac."
        case .http(415, _):
            "the Mac refused the upload's content type. This is a bug in this "
                + "build, not something you can fix from the phone."
        case .http(let status, let refusal):
            refusal?.message ?? "the Mac answered \(status) to that upload."
        case .cancelled:
            "that upload was cancelled."
        default:
            error.headline + " — " + error.guidance
        }
    }

    // MARK: - the thumbnail cache

    /// Keep a small local picture for `path`. Bounded, oldest first.
    private func remember(thumbnailOf data: Data, for path: String) {
        guard thumbs[path] == nil, let small = ImagePrep.thumbnailJPEG(data) else { return }
        thumbs[path] = small
        order.append(path)
        while order.count > Self.maxThumbnails {
            let doomed = order.removeFirst()
            thumbs.removeValue(forKey: doomed)
        }
    }

    /// Put a picture in the cache without sending anything. The `#if DEBUG`
    /// upload seam and the tests are the only callers.
    public func cache(_ data: Data, for path: String) {
        remember(thumbnailOf: data, for: path)
    }
}
