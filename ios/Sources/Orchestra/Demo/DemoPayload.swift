import Foundation

/// Everything the demo fleet is made of, decoded once, at the instant the user
/// asks for it.
///
/// One value, built in one place, because the alternative is four screens each
/// decoding their own copy against their own `Date()` — and then the board says
/// a session wrote 12 seconds ago while its own transcript says four minutes.
/// `startedAt` is the single clock every payload here was rewritten against.
///
/// Nothing in it is fetched, cached or written to disk. It exists for as long as
/// the demo is on screen and is dropped whole when the user leaves.
public struct DemoPayload: Sendable {
    /// The instant every age in here was computed from.
    public let startedAt: Date
    /// The three fields no frame carries — `hostname`, `user`, `resumes`.
    public let side: FleetSide
    /// The board itself, as an `event: state` snapshot frame.
    public let frame: StreamFrame
    public let limits: LimitsReport
    public let topology: Topology
    /// Keyed by `sid`, exactly as `/api/chat` is addressed.
    public let chats: [String: ChatTranscript]
    /// The full transcript behind every one of those conversations, served
    /// through the same `TranscriptSource` the real client implements — so the
    /// demo's `⌗ full log` drives the real paging, folding and truncation code
    /// rather than a second reader written for a reviewer.
    public let transcripts: DemoTranscriptFeed

    public init(startedAt: Date, side: FleetSide, frame: StreamFrame,
                limits: LimitsReport, topology: Topology,
                chats: [String: ChatTranscript],
                transcripts: DemoTranscriptFeed) {
        self.startedAt = startedAt
        self.side = side
        self.frame = frame
        self.limits = limits
        self.topology = topology
        self.chats = chats
        self.transcripts = transcripts
    }

    /// Decode the whole demo world against one clock.
    ///
    /// Throwing, because a payload that does not decode is a defect and a caller
    /// that cannot say which one is a defect that ships. `DemoTests` calls this
    /// form; the app calls `loadOrNil`.
    public static func load(now: Date = Date()) throws -> DemoPayload {
        DemoPayload(startedAt: now,
                    side: try DemoFleet.side(now: now),
                    frame: try DemoFleet.frame(now: now),
                    limits: try DemoLimits.report(now: now),
                    topology: try DemoTopology.topology(now: now),
                    chats: try DemoChat.all(now: now),
                    transcripts: try DemoTranscript.feed(now: now))
    }

    /// The app's door. Every payload is a compile-time literal and `swift test`
    /// pins that all of them decode, so this cannot be nil in a shipped build —
    /// but a `try!` in front of a reviewer is not a trade worth making.
    public static func loadOrNil(now: Date = Date()) -> DemoPayload? {
        try? load(now: now)
    }

    public func chat(sid: String) -> ChatTranscript? { chats[sid] }
}
