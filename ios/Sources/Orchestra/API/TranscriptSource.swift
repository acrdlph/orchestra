import Foundation

/// Where a transcript page comes from.
///
/// **One protocol, two implementations, and the demo is not the second one you
/// would expect.** `OrchestraClient` is the real wire. `DemoTranscriptFeed` is a
/// canned transcript that serves the SAME contract — byte-offset cursors,
/// exclusive `before`, `has_more_before`, the 4,000-character cap applied per
/// message, a `file` identity — so the demo drives the real paging code in
/// `TranscriptStore` rather than a second, simpler path written for a reviewer.
/// A demo that bypasses the rule under test is a demo of nothing (`DemoClock`
/// says the same about the decoder).
///
/// It is also what makes the store testable without a socket: the third
/// implementation lives in the test target and answers with literals.
public protocol TranscriptSource: Sendable {
    /// `GET /api/v1/sessions/{sid}/messages`. `before` is a byte offset and is
    /// **exclusive**; nil means the newest page.
    func transcriptPage(account: String, sid: String, limit: Int,
                        before: Int?) async throws -> TranscriptPage
    /// `GET /api/v1/sessions/{sid}/messages/at/{off}?i=` — one block, uncapped
    /// to 256 KB.
    func transcriptEntry(account: String, sid: String, off: Int,
                         i: Int?) async throws -> TranscriptPage
}

extension OrchestraClient: TranscriptSource {
    public func transcriptPage(account: String, sid: String, limit: Int,
                               before: Int?) async throws -> TranscriptPage {
        try await sessionMessages(account: account, sid: sid, limit: limit,
                                  before: before)
    }

    public func transcriptEntry(account: String, sid: String, off: Int,
                                i: Int?) async throws -> TranscriptPage {
        try await sessionEntry(account: account, sid: sid, off: off, i: i)
    }
}
