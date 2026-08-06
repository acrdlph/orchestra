import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// What kind of image a blob of bytes is — **read from the bytes**, exactly the
/// way `uploads.sniff` reads them on the Mac.
///
/// It is duplicated here rather than trusted from the picker for the reason the
/// server gives: a declared type is a claim and magic bytes are a fact.
/// `PhotosPicker` hands out whatever the library holds, a share sheet hands out
/// whatever the sending app called it, and `.fileImporter` hands out whatever is
/// on disk. Sniffing locally is what lets this phone say *"that's a video"*
/// before it spends a tailnet round trip being told so.
public enum ImageSniff {

    /// The six the server writes, spelled as `uploads.KINDS` spells them.
    public enum Kind: String, Sendable, Equatable, CaseIterable {
        case png, jpeg, gif, webp, heic, heif

        /// The extension the SERVER will give this on disk. `jpeg` becomes
        /// `.jpg`, which is why the kind and the extension are separate words in
        /// `UploadPath` too.
        public var fileExtension: String { self == .jpeg ? "jpg" : rawValue }
    }

    /// `uploads.HEIF_BRANDS` — the ISO base-media brands that mean "a still",
    /// as opposed to the MP4/MOV family that shares the container.
    static let heifBrands: [String: Kind] = [
        "heic": .heic, "heix": .heic, "heim": .heic, "heis": .heic,
        "hevc": .heic, "hevx": .heic, "hevm": .heic, "hevs": .heic,
        "mif1": .heif, "mif2": .heif, "msf1": .heif, "miaf": .heif,
    ]

    /// Enough of the head to decide anything: the RIFF/WEBP pair ends at byte 12
    /// and the `ftyp` walk is separately bounded.
    static let headBytes = 64
    static let ftypScan = 512

    public static func kind(of data: Data) -> Kind? {
        let head = [UInt8](data.prefix(headBytes))
        if head.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return .png }
        if head.starts(with: [0xFF, 0xD8, 0xFF]) { return .jpeg }
        if head.starts(with: Array("GIF87a".utf8)) || head.starts(with: Array("GIF89a".utf8)) {
            return .gif
        }
        if head.count >= 12, Array(head[0..<4]) == Array("RIFF".utf8),
           Array(head[8..<12]) == Array("WEBP".utf8) { return .webp }
        return heifKind(data)
    }

    /// `heic` outranks `heif` when the box declares both — an edited iPhone still
    /// is `mif1`-major with `heic` further down the compatible list, and calling
    /// that `.heif` is a true statement no tool expects.
    static func heifKind(_ data: Data) -> Kind? {
        let bytes = [UInt8](data.prefix(ftypScan))
        guard bytes.count >= 12, Array(bytes[4..<8]) == Array("ftyp".utf8) else { return nil }
        var found: Set<Kind> = []
        // The box length is a number the SENDER controls, so the walk is bounded
        // by what actually arrived as well as by the declared size.
        let declared = Int(bytes[0]) << 24 | Int(bytes[1]) << 16 | Int(bytes[2]) << 8 | Int(bytes[3])
        let end = min(declared, bytes.count, ftypScan)
        var offsets = [8]
        var off = 16
        while off + 4 <= end { offsets.append(off); off += 4 }
        for start in offsets where start + 4 <= bytes.count {
            let brand = String(decoding: bytes[start..<start + 4], as: UTF8.self)
            if let kind = heifBrands[brand] { found.insert(kind) }
        }
        return found.contains(.heic) ? .heic : (found.isEmpty ? nil : .heif)
    }
}

/// Getting a picture off this phone and onto that Mac, at a size and in a format
/// the reader on the other end can actually use.
///
/// **Screenshots are the case this is built around**, and the requirement they
/// impose is legibility of 11-point UI text after the round trip. Two numbers
/// carry it, and both are chosen rather than inherited:
///
/// * **`longEdgeCap` = 3024 px.** Every current iPhone screenshot is shorter than
///   this on its long edge — 2796 (15/17 Pro Max), 2868 (16 Pro Max), 2622
///   (16 Pro), 2556 (15/16), 2532 — so **a screenshot is never resampled**.
///   Resampling is what destroys small text; a cap that sits above the tallest
///   screenshot means the question never arises. Above the cap (a 12 MP camera
///   photo is 4032 on its long edge) the picture is a scene rather than a screen,
///   and 3024 px still reads a whiteboard across a room.
/// * **`jpegQuality` = 0.9.** High enough that 8-bit type on a flat background
///   keeps its edges; low enough that a 3024 px frame is ~1–2 MB rather than the
///   ~9 MB a 1.0 baseline encode costs.
///
/// **And the format rule, which matters more than either number.** The four
/// formats the reader at the far end accepts are PNG, JPEG, GIF and WebP; HEIC
/// is not among them, and the server deliberately does not transcode. So:
///
/// * a PNG, JPEG, GIF or WebP that is already within budget is sent **byte for
///   byte**. An iOS screenshot is a PNG, so the primary case never touches a
///   lossy encoder at all — the pixels that arrive on the Mac are the pixels that
///   were on the screen. Re-encoding it could only lose something.
/// * a HEIC or HEIF is **always** transcoded, because that is the whole reason
///   this file exists: iPhones shoot HEIC by default and the far end cannot read
///   one.
/// * anything over the cap in either pixels or bytes is transcoded down until it
///   fits, and if the bottom rung still does not fit, it is refused **locally**
///   with a sentence rather than fired at the Mac to be refused there.
public enum ImagePrep {

    /// The long edge above which a picture is downscaled. See the type comment —
    /// this number is above every iPhone screenshot on purpose.
    public static let longEdgeCap = 3024

    /// The JPEG quality of the transcode.
    public static let jpegQuality = 0.9

    /// The rungs, tried in order, first fit wins. Only reached by an image that
    /// is over budget at the top rung — a 48 MP camera frame, a panorama, a
    /// stitched screenshot. Each step down is a real step: half the pixels or a
    /// visible quality drop, so the ladder terminates quickly instead of
    /// grinding through twenty near-identical encodes.
    public static let ladder: [(longEdge: Int, quality: Double)] = [
        (longEdgeCap, jpegQuality), (2048, 0.85), (1600, 0.8), (1280, 0.7),
    ]

    /// Formats that are passed through untouched when they fit: exactly the four
    /// the reader at the far end accepts.
    public static let readableAsIs: Set<ImageSniff.Kind> = [.png, .jpeg, .gif, .webp]

    /// GIF is passed through on its **byte** budget alone, ignoring the pixel
    /// cap, because the alternative is worse than a big file: a transcode takes
    /// frame zero and silently drops the animation. An over-budget GIF is refused
    /// and said so, rather than quietly turned into a still.
    public static let animated: Set<ImageSniff.Kind> = [.gif]

    /// What will happen to a picture, decided from three facts and no pixels —
    /// so the decision itself is testable without an image.
    public enum Decision: Equatable, Sendable {
        /// Send these exact bytes. Nothing is decoded, nothing is re-encoded.
        case passthrough
        /// Decode, scale the long edge to at most this, re-encode as JPEG.
        case transcode(longEdge: Int, quality: Double)
        /// Do not send. The sentence is what the person holding the phone reads.
        case refuse(String)
    }

    public static func decide(kind: ImageSniff.Kind?, bytes: Int, longEdge: Int?) -> Decision {
        guard let kind else {
            return .refuse("that is not an image this server writes to disk — only "
                           + "PNG, JPEG, GIF, WebP and HEIC/HEIF are accepted.")
        }
        let fits = UploadBudget.refusal(rawBytes: bytes) == nil
        if animated.contains(kind) {
            guard fits else {
                return .refuse("that animation is \(UploadBudget.megabytes(bytes)), over "
                               + "the \(UploadBudget.megabytes(UploadBudget.maxImageBytes)) "
                               + "one upload carries — and shrinking a GIF here would "
                               + "send one frame of it, not the animation.")
            }
            return .passthrough
        }
        if readableAsIs.contains(kind), fits, let longEdge, longEdge <= longEdgeCap {
            return .passthrough
        }
        return .transcode(longEdge: ladder[0].longEdge, quality: ladder[0].quality)
    }

    /// What came out, and what was done to it — the second half is what the
    /// composer puts under the thumbnail, because *"1.3 MB JPEG, 3024 px"* is the
    /// only way a user can tell whether their screenshot survived.
    public struct Prepared: Sendable, Equatable {
        public let data: Data
        public let kind: ImageSniff.Kind
        public let pixels: (width: Int, height: Int)?
        /// False when the bytes are the ones that came off the picker.
        public let transcoded: Bool

        public init(data: Data, kind: ImageSniff.Kind,
                    pixels: (width: Int, height: Int)?, transcoded: Bool) {
            self.data = data
            self.kind = kind
            self.pixels = pixels
            self.transcoded = transcoded
        }

        public static func == (lhs: Prepared, rhs: Prepared) -> Bool {
            lhs.data == rhs.data && lhs.kind == rhs.kind
                && lhs.transcoded == rhs.transcoded
                && lhs.pixels?.width == rhs.pixels?.width
                && lhs.pixels?.height == rhs.pixels?.height
        }

        /// `1.3 MB · JPEG · 3024×2268`, or the passthrough's own numbers.
        public var note: String {
            var parts = [UploadBudget.megabytes(data.count), kind.rawValue.uppercased()]
            if let pixels { parts.append("\(pixels.width)×\(pixels.height)") }
            parts.append(transcoded ? "recompressed" : "sent as-is")
            return parts.joined(separator: " · ")
        }
    }

    /// Refused before anything left the phone. `reason` is the whole message and
    /// is shown verbatim, the same way a server refusal is.
    public struct Refused: Error, Equatable, Sendable {
        public let reason: String
        public init(_ reason: String) { self.reason = reason }
    }

    /// The one call the composer makes. Pure, synchronous and off the main actor
    /// by virtue of being `nonisolated` — the caller runs it on a detached task,
    /// because a 12 MP HEIC decode is a few hundred milliseconds and the board
    /// keeps drawing.
    public static func prepare(_ data: Data) throws -> Prepared {
        let kind = ImageSniff.kind(of: data)
        let size = pixelSize(of: data)
        switch decide(kind: kind, bytes: data.count, longEdge: size.map { max($0.0, $0.1) }) {
        case .refuse(let why):
            throw Refused(why)
        case .passthrough:
            // `kind` is non-nil on this branch — `decide` refuses when it is not.
            return Prepared(data: data, kind: kind ?? .png, pixels: size, transcoded: false)
        case .transcode:
            return try transcode(data)
        }
    }

    /// Down the ladder until it fits. Every rung is a real re-encode, so the
    /// number that is compared against the cap is the number that will be sent.
    static func transcode(_ data: Data) throws -> Prepared {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0 else {
            throw Refused("this phone could not read that file as an image — it may "
                          + "be damaged, or it may not be a picture at all.")
        }
        var last: Refused?
        for rung in ladder {
            guard let image = thumbnail(source, maxPixel: rung.longEdge),
                  let encoded = encodeJPEG(image, quality: rung.quality) else {
                last = Refused("this phone could not re-encode that image to JPEG.")
                continue
            }
            if let why = UploadBudget.refusal(rawBytes: encoded.count) {
                last = Refused(why)
                continue
            }
            return Prepared(data: encoded, kind: .jpeg,
                            pixels: (image.width, image.height), transcoded: true)
        }
        throw last ?? Refused("that image could not be made small enough to send.")
    }

    /// The pixel dimensions without decoding the pixels — one header read.
    /// Orientation-independent, because the caller only ever asks for the long
    /// edge and a rotation does not change which edge is longer.
    public static func pixelSize(of data: Data) -> (Int, Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return (w, h)
    }

    /// A decoded image whose long edge is at most `maxPixel`.
    ///
    /// **`kCGImageSourceCreateThumbnailWithTransform` is not optional here.** A
    /// camera photo carries its rotation in EXIF rather than in the pixels, and a
    /// thumbnail taken without applying it lands on the Mac sideways — which for
    /// a photographed whiteboard is the difference between readable and not.
    /// ImageIO never upscales, so a picture already under the cap comes back at
    /// its own size and the only thing that happens to it is the re-encode.
    static func thumbnail(_ source: CGImageSource, maxPixel: Int) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    static func encodeJPEG(_ image: CGImage, quality: Double) -> Data? {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out as CFMutableData,
                                                          UTType.jpeg.identifier as CFString,
                                                          1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [
            kCGImageDestinationLossyCompressionQuality: quality,
        ] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }

    /// A small JPEG for the composer's thumbnail strip.
    ///
    /// **Made from the LOCAL bytes the user picked**, never fetched back from the
    /// Mac — there is no download route and inventing one to redraw a picture the
    /// phone is already holding would be a second source of truth for the same
    /// pixels. Kept small because the cache lives in memory beside a draft.
    public static func thumbnailJPEG(_ data: Data, maxPixel: Int = 320) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              let image = thumbnail(source, maxPixel: maxPixel) else { return nil }
        return encodeJPEG(image, quality: 0.8)
    }
}
