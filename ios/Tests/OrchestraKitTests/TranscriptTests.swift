import Foundation
import Testing
@testable import OrchestraKit

/// The full transcript: the wire shapes, the `(off, i)` identity, the cursor
/// walk, the compaction reset, the truncation arithmetic, and the two rules
/// nobody would notice were wrong in a diff — what is folded, and when the view
/// is allowed to move under the reader's thumb.
///
/// Everything here is literals and an explicit clock. The store is driven
/// through `DemoTranscriptFeed` and a stub source, both of which answer the same
/// `TranscriptSource` contract `OrchestraClient` does, so the paging walk under
/// test is the shipping one.
struct TranscriptDecodeTests {

    /// A whole page, in the exact shape `sessionlog.read_messages` writes.
    static let page = """
    {"ok": true, "sid": "ca1c96e9-0000-4000-8000-000000000001",
     "account": "account2", "format": "raw",
     "messages": [
       {"off": 103830650, "i": 0, "role": "user",
        "text": "make the catalogue reindex incremental",
        "truncated": false, "chars": 38,
        "ts": "2026-07-20T20:51:45.295Z", "meta": false, "model": null},
       {"off": 103831900, "i": 0, "role": "assistant",
        "text": "Reading the shard map first.", "truncated": false, "chars": 28,
        "ts": "2026-07-20T20:51:49.100Z", "meta": true, "model": "claude-fable-5",
        "why": "thinking"},
       {"off": 103831900, "i": 1, "role": "tool_use",
        "text": "{\\n  \\"file_path\\": \\"search/shardmap.py\\"\\n}",
        "truncated": false, "chars": 40, "ts": null, "meta": false,
        "model": "claude-fable-5",
        "tool": {"name": "Read", "id": "toolu_01", "ok": null}},
       {"off": 103834100, "i": 0, "role": "tool_result",
        "text": "line one\\nline two", "truncated": true, "chars": 12431,
        "ts": "2026-07-20T20:51:50.000Z", "meta": false, "model": null,
        "tool": {"name": null, "id": "toolu_01", "ok": false}}
     ],
     "has_more_before": true, "cursor_before": 103830650,
     "file": {"size": 103839151, "ino": 8812004, "dev": 16777233,
              "mtime_ns": 1784748313813000000}}
    """

    static func decode(_ json: String) throws -> TranscriptPage {
        try JSONDecoder().decode(TranscriptPage.self, from: Data(json.utf8))
    }

    @Test func aRealPageDecodesEveryFieldTheWireCarries() throws {
        let page = try Self.decode(Self.page)
        #expect(page.ok)
        #expect(page.error == nil)
        #expect(page.format == "raw")
        #expect(page.messages.count == 4)
        #expect(page.hasMoreBefore)
        #expect(page.cursorBefore == 103830650)
        #expect(page.file?.ino == 8812004)
        #expect(page.file?.dev == 16777233)
        #expect(page.file?.size == 103839151)
        #expect(page.file?.mtimeNs == 1784748313813000000)

        let user = page.messages[0]
        #expect(user.role == .user)
        #expect(user.meta == false)
        #expect(user.why == nil)
        #expect(user.tool == nil)
        #expect(user.model == nil)
        #expect(user.timestamp != nil)

        let thinking = page.messages[1]
        #expect(thinking.role == .assistant)
        #expect(thinking.meta)
        #expect(thinking.why == .thinking)
        #expect(thinking.model == "claude-fable-5")

        let call = page.messages[2]
        #expect(call.role == .toolUse)
        #expect(call.tool?.name == "Read")
        // `ok` is null on a call: nothing has come back yet, and `false` would
        // paint every in-flight tool as an error.
        #expect(call.tool?.ok == nil)
        // `ts` is genuinely null on this block, and nulling it must not throw.
        #expect(call.ts == nil)
        #expect(call.timestamp == nil)

        let result = page.messages[3]
        #expect(result.role == .toolResult)
        #expect(result.tool?.ok == false)
        // The matching `tool_use` fell outside the window: null, not a guess.
        #expect(result.tool?.name == nil)
        #expect(result.tool?.display == "tool")
        #expect(result.truncated)
    }

    /// **`(off, i)`, never `off`.** One assistant line carries thinking, prose
    /// and several tool calls; a `ForEach` keyed on the line collapses the lot.
    @Test func identityIsTheOffsetAndTheBlockIndex() throws {
        let page = try Self.decode(Self.page)
        let ids = Set(page.messages.map(\.id))
        #expect(ids.count == 4)
        #expect(page.messages[1].off == page.messages[2].off)
        #expect(page.messages[1].id != page.messages[2].id)
        #expect(page.messages[1].id < page.messages[2].id)
        #expect(page.messages[0].id < page.messages[1].id)
    }

    /// The house rule (`turn_ended`, ios/README wire finding 2): a missing
    /// optional must never throw. Every one of them is absent here at once.
    @Test func everyOptionalMayBeAbsentAtOnce() throws {
        let page = try Self.decode("""
        {"ok": true, "messages": [{"off": 12, "i": 0, "role": "system",
                                   "text": "…", "truncated": false, "chars": 1}]}
        """)
        #expect(page.ok)
        #expect(page.messages.count == 1)
        let m = page.messages[0]
        #expect(m.ts == nil)
        #expect(m.model == nil)
        #expect(m.why == nil)
        #expect(m.tool == nil)
        #expect(m.meta == false)
        #expect(page.file == nil)
        #expect(page.cursorBefore == nil)
        #expect(page.hasMoreBefore == false)
        #expect(page.off == nil)
    }

    /// `cursor_before` is null once byte 0 has been reached, and that is the one
    /// state that ends the walk.
    @Test func aNullCursorAndAFalseMoreEndTheWalk() throws {
        let page = try Self.decode("""
        {"ok": true, "messages": [], "has_more_before": false,
         "cursor_before": null, "file": {"size": 0, "ino": 1, "dev": 2,
                                          "mtime_ns": 3}}
        """)
        #expect(page.ok)
        #expect(page.hasMoreBefore == false)
        #expect(page.cursorBefore == nil)
    }

    /// **These routes answer 200 for a refusal.** A client that branched on the
    /// status line would render an empty transcript for a nameable failure.
    @Test func aRefusalIsABodyAndNotAStatus() throws {
        for word in ["unknown account work stuff", "transcript not found",
                     "need account & sid", "bad sid", "bad limit", "bad before",
                     "bad format", "unknown route", "no entry at that offset",
                     "bad off", "bad i"] {
            let page = try Self.decode("{\"ok\": false, \"error\": \"\(word)\"}")
            #expect(page.ok == false)
            #expect(page.error == word)
            #expect(page.messages.isEmpty)
        }
    }

    /// A role or a `why` this build has never heard of must render, not throw.
    @Test func anUnknownRoleAndAnUnknownReasonSurvive() throws {
        let page = try Self.decode("""
        {"ok": true, "messages": [{"off": 1, "i": 0, "role": "prophecy",
          "text": "x", "truncated": false, "chars": 1, "meta": true,
          "why": "brand-new-rule"}]}
        """)
        #expect(page.messages[0].role == .unknown)
        #expect(page.messages[0].role.label == "system")
        #expect(page.messages[0].why == .other("brand-new-rule"))
        #expect(page.messages[0].why?.label == "brand-new-rule")
    }

    /// The `/at/` route carries an `off` at the top level and no cursor.
    @Test func theUncappedRouteCarriesItsOwnOffset() throws {
        let page = try Self.decode("""
        {"ok": true, "sid": "s", "account": "a", "format": "raw", "off": 4096,
         "messages": [{"off": 4096, "i": 2, "role": "tool_result",
                       "text": "the whole file", "truncated": false,
                       "chars": 14, "tool": {"name": "Read", "id": "t", "ok": true}}],
         "file": {"size": 9, "ino": 1, "dev": 2, "mtime_ns": 3}}
        """)
        #expect(page.off == 4096)
        #expect(page.messages[0].id == TranscriptEntry.ID(off: 4096, i: 2))
        #expect(page.messages[0].tool?.ok == true)
    }
}

// MARK: - The rules

struct TranscriptRuleTests {

    static func entry(_ role: TranscriptRole, off: Int = 0, i: Int = 0,
                      text: String = "x", truncated: Bool = false,
                      chars: Int? = nil, meta: Bool = false,
                      why: MetaReason? = nil, tool: ToolRef? = nil) -> TranscriptEntry {
        TranscriptEntry(off: off, i: i, role: role, text: text,
                        truncated: truncated, chars: chars, meta: meta,
                        why: why, tool: tool)
    }

    /// **The readability argument, pinned.** Prose open, tool traffic folded.
    @Test func toolTrafficIsFoldedAndProseIsNot() {
        #expect(TranscriptRules.collapsedByDefault(.toolUse))
        #expect(TranscriptRules.collapsedByDefault(.toolResult))
        #expect(!TranscriptRules.collapsedByDefault(.user))
        #expect(!TranscriptRules.collapsedByDefault(.assistant))
        #expect(!TranscriptRules.collapsedByDefault(.system))
        #expect(!TranscriptRules.collapsedByDefault(.unknown))
    }

    /// `meta` is hidden by default and NOTHING is unreachable: the same list
    /// with the toggle on is the whole list.
    @Test func theNoiseFilterHidesAndNeverDrops() {
        let all = [Self.entry(.user),
                   Self.entry(.assistant, off: 1, meta: true, why: .thinking),
                   Self.entry(.system, off: 2, meta: true, why: .system),
                   Self.entry(.toolUse, off: 3,
                              tool: ToolRef(name: "Bash", id: "t", ok: nil)),
                   Self.entry(.toolResult, off: 4, meta: true, why: .sidechain,
                              tool: ToolRef(name: "Read", id: "u", ok: true))]
        let quiet = TranscriptRules.visible(all, showMeta: false)
        #expect(quiet.count == 2)
        // A tool entry is primary content and survives the filter…
        #expect(quiet.contains { $0.role == .toolUse })
        // …unless the server marked it `sidechain`, which outranks being a tool.
        #expect(!quiet.contains { $0.why == .sidechain })
        #expect(TranscriptRules.visible(all, showMeta: true).count == all.count)
        #expect(TranscriptRules.hiddenCount(all) == 3)
    }

    /// `chars - text` in the server's own units, and both numbers on screen.
    @Test func theTruncationArithmeticIsScalarsAndStatesBothNumbers() {
        let cut = Self.entry(.toolResult, text: String(repeating: "a", count: 4000),
                             truncated: true, chars: 12431)
        #expect(cut.hiddenScalars == 8431)
        #expect(TranscriptRules.cutLabel(cut) == "cut at 4,000 of 12,431")

        // **Never inferred from a trailing `…`.** Real prose ends in one and
        // arrives `truncated: false`; the old chat bubble's guess would call
        // this cut and be wrong.
        let whole = Self.entry(.assistant, text: "and then it stopped…",
                               truncated: false)
        #expect(whole.hiddenScalars == 0)
        #expect(TranscriptRules.cutLabel(whole) == nil)

        // Grapheme clusters are not code points. `text.count` here is 2; the
        // server counted 3 scalars, so `.count` would invent a one-character cut.
        let emoji = Self.entry(.assistant, text: "e\u{301}\u{1F600}",
                               truncated: false, chars: 3)
        #expect(emoji.hiddenScalars == 0)
    }

    /// The client-side restatement of the server's cap, which is what the demo
    /// fleet runs on.
    @Test func theCapIsTheServersAndTheFlagIsReal() {
        let long = Self.entry(.toolResult, text: String(repeating: "x", count: 4708))
        let capped = TranscriptRules.cap(long, at: TranscriptRules.pagedCap)
        #expect(capped.text.unicodeScalars.count == 4000)
        #expect(capped.chars == 4708)
        #expect(capped.truncated)
        // **No ellipsis is ever appended.** That is the whole reason `truncated`
        // is trustworthy.
        #expect(!capped.text.hasSuffix("…"))

        let short = TranscriptRules.cap(Self.entry(.user, text: "hello"),
                                        at: TranscriptRules.pagedCap)
        #expect(!short.truncated)
        #expect(short.chars == 5)
    }

    /// The folded line names the call by the argument a human recognises it by —
    /// and it still does when the JSON was cut mid-value.
    @Test func aFoldedToolLineNamesTheCall() {
        let read = Self.entry(.toolUse, text: "{\n  \"file_path\": \"search/shardmap.py\"\n}",
                              tool: ToolRef(name: "Read", id: "t", ok: nil))
        #expect(TranscriptRules.toolSummary(read) == "search/shardmap.py")

        let bash = Self.entry(.toolUse, text: "{\n  \"command\": \"pytest -q\",\n  \"description\": \"run\"\n}",
                              tool: ToolRef(name: "Bash", id: "t", ok: nil))
        #expect(TranscriptRules.toolSummary(bash) == "pytest -q")

        // Cut mid-value: what was read is still the best summary there is.
        let cut = Self.entry(.toolUse, text: "{\n  \"command\": \"pytest tests/ -q --dur",
                             truncated: true, chars: 9000,
                             tool: ToolRef(name: "Bash", id: "t", ok: nil))
        #expect(TranscriptRules.toolSummary(cut) == "pytest tests/ -q --dur")

        // A result has no arguments, so its fold is its first line of output.
        let result = Self.entry(.toolResult, text: "\n41 passed in 4.12s\nrest",
                                tool: ToolRef(name: "Bash", id: "t", ok: true))
        #expect(TranscriptRules.toolSummary(result) == "41 passed in 4.12s")

        // Prose is never summarised — it is shown.
        #expect(TranscriptRules.toolSummary(Self.entry(.assistant, text: "hi")) == "")
    }

    @Test func theLineBudgetGrowsThePageRatherThanNestingAScrollView() {
        let text = (1...120).map { "line \($0)" }.joined(separator: "\n")
        let (shown, more) = TranscriptRules.budgeted(text)
        #expect(TranscriptRules.lineCount(shown) == TranscriptRules.expandedLineBudget)
        #expect(more == 120 - TranscriptRules.expandedLineBudget)
        // Under the budget, nothing is held back and no button is offered.
        let short = "a\nb\nc"
        #expect(TranscriptRules.budgeted(short) == (short, 0))
    }

    /// **The rule people notice immediately when it is wrong.**
    @Test func theViewMovesOnlyWhenTheReaderIsAlreadyAtTheBottom() {
        #expect(TranscriptRules.follow(atBottom: true, appended: 3) == .scrollToBottom)
        #expect(TranscriptRules.follow(atBottom: false, appended: 3) == .offer(3))
        // Nothing arrived: nothing happens, in either position.
        #expect(TranscriptRules.follow(atBottom: true, appended: 0) == .nothing)
        #expect(TranscriptRules.follow(atBottom: false, appended: 0) == .nothing)
    }

    /// A compaction rewrites the file and voids every offset at once — and
    /// **both halves of the identity are compared**, because an inode is unique
    /// per device and not globally.
    @Test func anInodeOrADeviceMoveForcesAReload() {
        let a = TranscriptFile(size: 100, ino: 7, dev: 16, mtimeNs: 1)
        #expect(!TranscriptRules.mustReload(previous: a, current: a))
        // Growth is not a rewrite.
        #expect(!TranscriptRules.mustReload(
            previous: a, current: TranscriptFile(size: 900, ino: 7, dev: 16, mtimeNs: 9)))
        #expect(TranscriptRules.mustReload(
            previous: a, current: TranscriptFile(size: 100, ino: 8, dev: 16, mtimeNs: 1)))
        #expect(TranscriptRules.mustReload(
            previous: a, current: TranscriptFile(size: 100, ino: 7, dev: 17, mtimeNs: 1)))
        // Nothing to compare yet is not a reason to throw the window away.
        #expect(!TranscriptRules.mustReload(previous: nil, current: a))
        #expect(a.grew(from: TranscriptFile(size: 90, ino: 7, dev: 16, mtimeNs: 1)))
        #expect(!a.grew(from: a))
    }

    /// The live tail, including the case a naive append gets silently wrong.
    @Test func theTailMergeKnowsContiguityFromAHole() {
        let window = [Self.entry(.user, off: 10), Self.entry(.assistant, off: 20)]

        #expect(TranscriptRules.tail(window: window, newest: []) == .unchanged)
        #expect(TranscriptRules.tail(window: window, newest: window) == .unchanged)

        let grown = window + [Self.entry(.assistant, off: 30)]
        #expect(TranscriptRules.tail(window: window, newest: grown)
                == .appended([Self.entry(.assistant, off: 30)]))

        // The newest page reaches back into what we hold by one entry: still
        // contiguous, and only the genuinely new ones are appended.
        let overlapping = [Self.entry(.assistant, off: 20), Self.entry(.user, off: 40)]
        #expect(TranscriptRules.tail(window: window, newest: overlapping)
                == .appended([Self.entry(.user, off: 40)]))

        // Nothing in common and everything newer: a hole. Butting the two ends
        // together would draw a transcript that never existed.
        let disjoint = [Self.entry(.user, off: 900), Self.entry(.assistant, off: 910)]
        #expect(TranscriptRules.tail(window: window, newest: disjoint) == .gap(disjoint))

        // An empty window has nothing to be contiguous WITH.
        #expect(TranscriptRules.tail(window: [], newest: disjoint) == .gap(disjoint))
    }

    @Test func prependingAnOlderPageNeverDuplicates() {
        let window = [Self.entry(.user, off: 10), Self.entry(.assistant, off: 20)]
        let older = [Self.entry(.user, off: 1), Self.entry(.user, off: 10)]
        let merged = TranscriptRules.prepend(older, to: window)
        #expect(merged.map(\.off) == [1, 10, 20])
        #expect(Set(merged.map(\.id)).count == merged.count)
    }

    /// **`ChatStore`'s two numbers, not a third pair.**
    @Test func theCadenceIsTheChatScreensOwn() {
        let now = Date()
        #expect(TranscriptRules.pollPeriod(lastGrowth: nil, now: now) == 15)
        #expect(TranscriptRules.pollPeriod(lastGrowth: now, now: now) == 5)
        #expect(TranscriptRules.pollPeriod(lastGrowth: now.addingTimeInterval(-119),
                                           now: now) == 5)
        #expect(TranscriptRules.pollPeriod(lastGrowth: now.addingTimeInterval(-121),
                                           now: now) == 15)
        // Read from `ChatStore`, so an edit there moves both screens at once.
        #expect(TranscriptRules.pollPeriod(lastGrowth: nil, now: now)
                == ChatStore.restPeriod)
        #expect(TranscriptRules.pollPeriod(lastGrowth: now, now: now)
                == ChatStore.activePeriod)
    }

    @Test func digitGroupingIsNotALocalesDecimalComma() {
        #expect(TranscriptRules.group(0) == "0")
        #expect(TranscriptRules.group(999) == "999")
        #expect(TranscriptRules.group(4000) == "4,000")
        #expect(TranscriptRules.group(103839151) == "103,839,151")
    }
}

// MARK: - The endpoints

struct TranscriptEndpointTests {

    static let base = URL(string: "http://100.113.110.31:4269")!

    static func url(_ endpoint: Endpoint) throws -> String {
        try endpoint.urlRequest(base: base, token: "t").url?.absoluteString ?? ""
    }

    @Test func thePagedRouteCarriesItsCursorAndItsFormat() throws {
        let first = try Self.url(.sessionMessages(account: "account2",
                                                  sid: "ca1c-96e9"))
        #expect(first.contains("/api/v1/sessions/ca1c-96e9/messages?"))
        #expect(first.contains("account=account2"))
        #expect(first.contains("limit=30"))
        #expect(first.contains("format=raw"))
        #expect(!first.contains("before="))

        let older = try Self.url(.sessionMessages(account: "account2",
                                                  sid: "ca1c-96e9",
                                                  before: 103830650))
        #expect(older.contains("before=103830650"))
    }

    @Test func theUncappedRouteAddressesOneBlock() throws {
        let one = try Self.url(.sessionEntry(account: "account2", sid: "s", off: 4096, i: 2))
        #expect(one.contains("/api/v1/sessions/s/messages/at/4096?"))
        #expect(one.contains("i=2"))
        let whole = try Self.url(.sessionEntry(account: "account2", sid: "s", off: 4096))
        #expect(!whole.contains("i="))
    }

    /// **A Claude-home label is a directory name somebody chose**, and
    /// `URLComponents.queryItems` does not encode `+` — which `parse_qs` on the
    /// far side turns into a space. Both of these would name an account that
    /// does not exist.
    @Test func theAccountIsPercentEncodedDownToTheUnreservedSet() throws {
        let spaced = try Self.url(.sessionMessages(account: "work stuff", sid: "s"))
        #expect(spaced.contains("account=work%20stuff"))
        let plussed = try Self.url(.sessionMessages(account: "a+b", sid: "s"))
        #expect(plussed.contains("account=a%2Bb"))
        #expect(!plussed.contains("account=a+b"))
        let ampersand = try Self.url(.sessionMessages(account: "a&b=c", sid: "s"))
        #expect(ampersand.contains("account=a%26b%3Dc"))
        // Non-ASCII survives too.
        #expect(Endpoint.encodeQueryComponent("café") == "caf%C3%A9")
        #expect(Endpoint.encodeQueryComponent("a-b_c.d~e") == "a-b_c.d~e")
    }

    /// A read: no idempotency key, no body, no `Content-Type`.
    @Test func theTranscriptReadsAreReads() throws {
        for endpoint in [Endpoint.sessionMessages(account: "a", sid: "s"),
                         Endpoint.sessionEntry(account: "a", sid: "s", off: 0)] {
            #expect(endpoint.method == .get)
            #expect(endpoint.idempotency == nil)
            #expect(endpoint.body == nil)
            #expect(endpoint.requiresToken)
            #expect(endpoint.timeout <= OrchestraClient.sessionResourceTimeout)
            let request = try endpoint.urlRequest(base: Self.base, token: "t")
            #expect(request.value(forHTTPHeaderField: "Idempotency-Key") == nil)
            #expect(request.value(forHTTPHeaderField: "Content-Type") == nil)
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer t")
        }
    }

    /// The routes that were already here must not change shape: they are read
    /// off the RAW path with `re.search` and never percent-decoded.
    @Test func theOlderRoutesKeepTheirLooseEncoding() throws {
        let chat = Endpoint.chat(account: "account2", sid: "s")
        #expect(chat.strictQueryEncoding == false)
        #expect(try Self.url(chat).contains("account=account2"))
    }
}

// MARK: - The store

@MainActor
struct TranscriptStoreTests {

    /// A source that answers from a scripted list of pages, and counts what it
    /// was asked for — so a walk that loops, skips or duplicates is visible.
    final class Stub: TranscriptSource, @unchecked Sendable {
        var pages: [TranscriptPage] = []
        var entries: [TranscriptPage] = []
        private(set) var befores: [Int?] = []
        private(set) var limits: [Int] = []

        func transcriptPage(account: String, sid: String, limit: Int,
                            before: Int?) async throws -> TranscriptPage {
            befores.append(before)
            limits.append(limit)
            return pages.isEmpty ? TranscriptPage(ok: true) : pages.removeFirst()
        }

        func transcriptEntry(account: String, sid: String, off: Int,
                             i: Int?) async throws -> TranscriptPage {
            entries.isEmpty ? TranscriptPage(ok: false, error: "no entry at that offset")
                            : entries.removeFirst()
        }
    }

    static func store(_ source: any TranscriptSource,
                      limit: Int = 30) -> TranscriptStore {
        TranscriptStore(source: source, account: "account2",
                        sid: "9c1f4a2e-7b30-4c58-9a11-2d6e83f0b415", limit: limit)
    }

    static func demo() throws -> DemoTranscriptFeed {
        try DemoTranscript.feed(now: Date())
    }

    /// **The whole walk, against the canned transcript, driven by the shipping
    /// store.** In order, no duplicates, and it stops — which is the property a
    /// byte cursor exists to have.
    @Test func theCursorWalkAssemblesInOrderAndTerminates() async throws {
        let store = Self.store(try Self.demo())
        await store.loadNewest()
        #expect(!store.entries.isEmpty)
        #expect(store.hasMoreBefore)

        var guardrail = 0
        while store.hasMoreBefore && guardrail < 50 {
            await store.loadOlder()
            guardrail += 1
        }
        #expect(guardrail < 50)                       // it terminated
        #expect(!store.hasMoreBefore)                 // byte 0 was reached
        #expect(store.cursorBefore == nil)

        let ids = store.entries.map(\.id)
        #expect(Set(ids).count == ids.count)          // nothing arrived twice
        #expect(ids == ids.sorted())                  // and nothing out of order

        // And it is the whole transcript, not a prefix of it.
        let all = try DemoTranscript.entries(now: Date())
        #expect(store.entries.count == all.count)
    }

    /// A page is whole LINES, so it may return fewer than `limit` — and the walk
    /// must not read that as the end.
    @Test func aShortPageIsNotTheEndOfTheWalk() async throws {
        let feed = try Self.demo()
        let page = try await feed.transcriptPage(
            account: "a", sid: DemoTranscript.richSid, limit: 30, before: nil)
        #expect(page.ok)
        #expect(page.messages.count <= 30)
        #expect(page.hasMoreBefore)
        #expect(page.cursorBefore == page.messages.first?.off)
    }

    /// The first page opens the screen at the newest entry.
    @Test func theFirstPageEntitlesTheViewToMove() async throws {
        let store = Self.store(try Self.demo())
        let before = store.followToken
        await store.loadNewest()
        #expect(store.followToken > before)
    }

    /// **A compaction voids every offset**, so the window is dropped whole and
    /// the newest page is re-read rather than paged into a file that is gone.
    @Test func anInodeChangeDropsTheWindowAndReloads() async throws {
        let stub = Stub()
        let old = TranscriptFile(size: 100, ino: 7, dev: 16, mtimeNs: 1)
        let new = TranscriptFile(size: 40, ino: 99, dev: 16, mtimeNs: 2)
        stub.pages = [
            TranscriptPage(ok: true,
                           messages: [TranscriptRuleTests.entry(.user, off: 10),
                                      TranscriptRuleTests.entry(.assistant, off: 20)],
                           hasMoreBefore: true, cursorBefore: 10, file: old),
            // the probe, on a rewritten file
            TranscriptPage(ok: true, messages: [], hasMoreBefore: false, file: new),
            // the reload
            TranscriptPage(ok: true,
                           messages: [TranscriptRuleTests.entry(.user, off: 0)],
                           hasMoreBefore: false, cursorBefore: nil, file: new),
        ]
        let store = Self.store(stub)
        await store.loadNewest()
        #expect(store.entries.count == 2)

        await store.tick()
        #expect(store.wasCompacted)
        #expect(store.entries.map(\.off) == [0])
        #expect(store.file?.ino == 99)
        // The reload asked for the NEWEST page — no stale cursor went out.
        #expect(stub.befores == [nil, nil, nil])
    }

    /// The cheap check: nothing appended means no page is fetched at all.
    @Test func aQuietTranscriptCostsOneSmallProbe() async throws {
        let stub = Stub()
        let file = TranscriptFile(size: 100, ino: 7, dev: 16, mtimeNs: 1)
        stub.pages = [
            TranscriptPage(ok: true,
                           messages: [TranscriptRuleTests.entry(.user, off: 10)],
                           hasMoreBefore: false, file: file),
            TranscriptPage(ok: true,
                           messages: [TranscriptRuleTests.entry(.user, off: 10)],
                           hasMoreBefore: false, file: file),
        ]
        let store = Self.store(stub)
        await store.loadNewest()
        await store.tick()
        #expect(stub.limits == [30, 1])       // the page, then a one-entry probe
        #expect(store.entries.count == 1)
    }

    /// New output while the reader is at the newest entry follows; the same
    /// output while they are reading history does not move them at all.
    @Test func newOutputFollowsOnlyWhenTheReaderIsAtTheBottom() async throws {
        func drive(atBottom: Bool) -> TranscriptStore {
            let store = Self.store(Stub())
            store.applyNewest(TranscriptPage(
                ok: true, messages: [TranscriptRuleTests.entry(.user, off: 10)],
                hasMoreBefore: false,
                file: TranscriptFile(size: 1, ino: 7, dev: 16, mtimeNs: 1)))
            store.readerAtBottom = atBottom
            let token = store.followToken
            store.applyTail(TranscriptPage(
                ok: true,
                messages: [TranscriptRuleTests.entry(.user, off: 10),
                           TranscriptRuleTests.entry(.assistant, off: 20),
                           TranscriptRuleTests.entry(.assistant, off: 30)],
                hasMoreBefore: false,
                file: TranscriptFile(size: 9, ino: 7, dev: 16, mtimeNs: 2)))
            #expect(store.entries.count == 3)       // held either way
            #expect(store.followToken == (atBottom ? token + 1 : token))
            return store
        }

        let followed = drive(atBottom: true)
        #expect(followed.unreadTail == 0)

        let reading = drive(atBottom: false)
        #expect(reading.unreadTail == 2)
        #expect(!reading.unreadTailIsGap)

        // The pill moves the view and nothing else — the entries were already
        // there.
        let token = reading.followToken
        reading.takeTail()
        #expect(reading.unreadTail == 0)
        #expect(reading.followToken == token + 1)
    }

    /// More happened between two polls than a page holds. The count is not
    /// knowable, so the pill says so rather than a wrong number.
    @Test func aHoleInTheTailIsNeverStitchedShut() async throws {
        let store = Self.store(Stub())
        let file = TranscriptFile(size: 1, ino: 7, dev: 16, mtimeNs: 1)
        store.applyNewest(TranscriptPage(
            ok: true, messages: [TranscriptRuleTests.entry(.user, off: 10)],
            hasMoreBefore: false, cursorBefore: nil, file: file))
        store.readerAtBottom = false
        store.applyTail(TranscriptPage(
            ok: true, messages: [TranscriptRuleTests.entry(.assistant, off: 90_000)],
            hasMoreBefore: true, cursorBefore: 90_000,
            file: TranscriptFile(size: 99, ino: 7, dev: 16, mtimeNs: 2)))
        #expect(store.unreadTailIsGap)
        #expect(store.entries.map(\.off) == [10])   // nothing was butted on
        // At the bottom the same hole is resolved by adopting the newest page,
        // and the top of the window honestly reports that there is more above.
        store.readerAtBottom = true
        store.applyTail(TranscriptPage(
            ok: true, messages: [TranscriptRuleTests.entry(.assistant, off: 90_000)],
            hasMoreBefore: true, cursorBefore: 90_000,
            file: TranscriptFile(size: 100, ino: 7, dev: 16, mtimeNs: 3)))
        #expect(store.entries.map(\.off) == [90_000])
        #expect(store.hasMoreBefore)
        #expect(store.cursorBefore == 90_000)
    }

    /// The refusal is a body, and the screen shows the server's own sentence.
    @Test func aRefusedPageIsSaidInTheServersWords() async throws {
        let stub = Stub()
        stub.pages = [TranscriptPage(ok: false, error: "unknown account work stuff")]
        let store = Self.store(stub)
        await store.loadNewest()
        #expect(store.serverError == "unknown account work stuff")
        #expect(store.entries.isEmpty)
    }

    /// **`show all` fetches.** That is the whole difference from the chat
    /// drawer's `show full`, which only un-clamps a `lineLimit`.
    @Test func showAllReplacesTheCutTextWithTheWholeThing() async throws {
        let store = Self.store(try Self.demo())
        await store.loadNewest()
        var guardrail = 0
        while store.hasMoreBefore && guardrail < 50 {
            await store.loadOlder()
            guardrail += 1
        }
        guard let cut = store.entries.first(where: { $0.truncated }) else {
            Issue.record("the demo transcript must carry a truncated entry")
            return
        }
        #expect(store.isCut(cut))
        #expect(store.text(for: cut).unicodeScalars.count == TranscriptRules.pagedCap)
        await store.expand(cut.id)
        #expect(!store.isCut(cut))
        #expect(store.text(for: cut).unicodeScalars.count == cut.chars)
        #expect(store.expandFailed[cut.id] == nil)
    }

    /// Folding is per role, and the toggle only ever moves a tool block.
    @Test func onlyToolBlocksFoldAndTheToggleOnlyMovesThem() async throws {
        let store = Self.store(Stub())
        let prose = TranscriptRuleTests.entry(.assistant, off: 1)
        let call = TranscriptRuleTests.entry(.toolUse, off: 2,
                                             tool: ToolRef(name: "Bash", id: "t", ok: nil))
        store.applyNewest(TranscriptPage(ok: true, messages: [prose, call],
                                         hasMoreBefore: false))
        #expect(store.isOpen(prose))
        #expect(!store.isOpen(call))
        store.toggle(call)
        #expect(store.isOpen(call))
        store.toggle(prose)
        #expect(store.isOpen(prose))        // prose was never foldable
        store.toggle(call)
        #expect(!store.isOpen(call))
    }

    @Test func theNoiseToggleChangesWhatTheViewDraws() async throws {
        let store = Self.store(try Self.demo())
        await store.loadNewest()
        #expect(store.hiddenByFilter > 0)
        #expect(store.visible.count < store.entries.count)
        #expect(store.visible.allSatisfy { !$0.meta })
        store.showMeta = true
        #expect(store.visible.count == store.entries.count)
        #expect(store.hiddenByFilter == 0)
    }
}

// MARK: - The demo fleet

struct DemoTranscriptTests {

    static func all() throws -> [TranscriptEntry] {
        try DemoTranscript.entries(now: Date())
    }

    /// It decodes through the REAL decoder, on the reader's own clock.
    @Test func theCannedTranscriptDecodesAndIsOnTodaysClock() throws {
        let entries = try Self.all()
        #expect(entries.count > 30)
        let stamps = entries.compactMap(\.timestamp)
        #expect(stamps.count == entries.count)
        let age = Date().timeIntervalSince(stamps.last!)
        #expect(age > -60 && age < 24 * 3600)
        // In file order, with `(off, i)` unique.
        #expect(entries.map(\.id) == entries.map(\.id).sorted())
        #expect(Set(entries.map(\.id)).count == entries.count)
    }

    /// Everything the screen has to be able to draw is in there.
    @Test func theCannedTranscriptCarriesEveryShapeTheScreenRenders() throws {
        let entries = try Self.all()

        // A line that expands into more than one block — the reason the id is
        // `(off, i)` at all.
        let byOff = Dictionary(grouping: entries, by: \.off)
        #expect(byOff.values.contains { $0.count > 1 })

        // A tool_use / tool_result pair, matched on the tool id.
        let calls = entries.filter { $0.role == .toolUse }
        let results = entries.filter { $0.role == .toolResult }
        #expect(!calls.isEmpty)
        #expect(!results.isEmpty)
        #expect(results.contains { r in calls.contains { $0.tool?.id == r.tool?.id } })
        #expect(calls.allSatisfy { $0.tool?.ok == nil })

        // An error result.
        #expect(results.contains { $0.tool?.ok == false })

        // One entry longer than the paged cap, so `show all` has something to
        // fetch.
        #expect(entries.contains { $0.text.unicodeScalars.count > TranscriptRules.pagedCap })

        // Meta, with more than one reason — including the one that outranks
        // being a tool.
        #expect(entries.contains { $0.meta && $0.why == .thinking })
        #expect(entries.contains { $0.meta && $0.why == .sidechain })
        #expect(entries.contains { $0.meta && $0.why == .system })
        #expect(entries.contains { $0.why == .image && $0.text == "[image]" })
        // Tool entries are primary content unless the server said otherwise.
        #expect(calls.contains { !$0.meta })
    }

    /// **Every session a reviewer can tap has a full log.** The button must
    /// never land on `transcript not found`.
    @Test func everySessionOnTheDemoBoardHasAFullLog() async throws {
        let now = Date()
        let feed = try DemoTranscript.feed(now: now)
        let chats = try DemoChat.all(now: now)
        for sid in chats.keys {
            let page = try await feed.transcriptPage(account: "personal", sid: sid,
                                                     limit: 30, before: nil)
            #expect(page.ok, "no full log for \(sid)")
            #expect(!page.messages.isEmpty)
            #expect(page.file != nil)
        }
        // And a sid nobody knows is refused in the server's own words.
        let missing = try await feed.transcriptPage(account: "personal", sid: "nope",
                                                    limit: 30, before: nil)
        #expect(missing.ok == false)
        #expect(missing.error == "transcript not found")
    }

    /// **The demo carries a turn the SERVER cut**, because the affordance for
    /// one is the thing this phase fixed and a reviewer has to be able to see
    /// it. `/api/chat` cuts at 900 characters and appends a `…`, so one canned
    /// turn does exactly that — and the full log for the same session holds the
    /// whole thing, which is the point being made.
    @Test func theDemoChatCarriesATurnTheServerCut() throws {
        let chats = try DemoChat.all(now: Date())
        let cut = chats.values.flatMap(\.messages).filter(\.serverTruncated)
        #expect(!cut.isEmpty, "no demo turn shows the server-cut affordance")
        #expect(cut.allSatisfy { !$0.isMine }, "only an agent turn is ever cut")
        // Nothing the transcript screen renders infers truncation this way — it
        // has a real flag — so the guess stays confined to `/api/chat`.
        #expect(chats[DemoTranscript.richSid]?.messages.last?.serverTruncated == false)
    }

    /// The whole demo world still loads, with the transcript feed on it.
    @Test func theDemoPayloadCarriesTheTranscripts() throws {
        let payload = try DemoPayload.load(now: Date())
        #expect(!payload.chats.isEmpty)
        #expect(payload.transcripts.bySid.count == payload.chats.count)
    }

    /// `before` is exclusive on the demo feed exactly as it is on the wire.
    @Test func theDemoFeedsCursorIsExclusive() async throws {
        let feed = try DemoTranscript.feed(now: Date())
        let first = try await feed.transcriptPage(account: "a", sid: DemoTranscript.richSid,
                                                  limit: 30, before: nil)
        let cursor = try #require(first.cursorBefore)
        let second = try await feed.transcriptPage(account: "a", sid: DemoTranscript.richSid,
                                                   limit: 30, before: cursor)
        #expect(second.messages.allSatisfy { $0.off < cursor })
        #expect(Set(first.messages.map(\.id))
                    .isDisjoint(with: Set(second.messages.map(\.id))))
        #expect(second.hasMoreBefore == false)
        #expect(second.cursorBefore == nil)
    }
}

// `DebugRoute` lives in `App/` and `TranscriptTarget` in `UI/`, and neither is
// in this test target — `Package.swift` builds `Sources/Orchestra` minus `UI`,
// and `App/` is the Xcode target's alone. So the `ORC_SCREEN=transcript:` seam
// is exercised the only way it can be: by launching the app with it and
// screenshotting what it landed on, which is what the seam exists for.
