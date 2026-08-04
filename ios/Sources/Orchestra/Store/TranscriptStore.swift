import Foundation
import Observation

/// One session's WHOLE transcript, as much of it as is worth holding at once.
///
/// **The window is bounded and the cursors are bytes.** A transcript on the
/// machine this was built against is 103,839,151 bytes; nothing here may be a
/// function of the file's length. A page is "the messages ending at byte X",
/// `before` is exclusive so nothing arrives twice, and the store keeps a few
/// pages either side of what the reader is looking at and drops the rest.
///
/// **A compaction rewrites the file and voids every offset at once.** Every
/// answer carries `file: (dev, ino, size, mtime_ns)`; if `ino` or `dev` moves,
/// every cursor this store holds names bytes in a file that no longer exists,
/// and the only correct move is to throw them all away and reload the newest
/// page. `size`/`mtime_ns` are the cheap "did anything happen" beside it.
///
/// It polls on **`ChatStore`'s cadence and not a third one** — 5 s while the
/// file is growing, 15 s once it has gone quiet — and it polls only while the
/// screen is up, because the store is created by the view and dies with it.
@MainActor
@Observable
public final class TranscriptStore {
    /// The window, oldest first. Keyed by `(off, i)` everywhere: one assistant
    /// line carries thinking, prose and several tool calls, so `off` alone names
    /// a whole turn and would collapse it to one row.
    public private(set) var entries: [TranscriptEntry] = []
    /// False only once byte 0 has actually been reached — the only thing that
    /// may draw `— start of transcript —`.
    public private(set) var hasMoreBefore = true
    /// The `off` to pass as `?before=` for the next page back. Nil once the
    /// walk has finished.
    public private(set) var cursorBefore: Int?
    public private(set) var file: TranscriptFile?

    public private(set) var loadingNewest = false
    public private(set) var loadingOlder = false
    /// The server's own sentence, verbatim. These routes answer **200** for a
    /// refusal, so this is the only place a nameable failure shows up.
    public private(set) var serverError: String?
    public private(set) var transportError: OrchestraError?
    public private(set) var loadedAt: Date?

    /// The toolbar toggle. Off by default: the default read is the conversation.
    /// Nothing is unreachable — with it on, every byte the server sent is drawn.
    public var showMeta = false

    /// Tool blocks the reader has opened. Folded is the default for
    /// `tool_use`/`tool_result` and expanded for everything else
    /// (`TranscriptRules.collapsedByDefault`).
    public private(set) var openTools: Set<TranscriptEntry.ID> = []
    /// Blocks re-fetched uncapped from `/messages/at/{off}`, by id.
    public private(set) var fullText: [TranscriptEntry.ID: TranscriptEntry] = [:]
    public private(set) var expanding: Set<TranscriptEntry.ID> = []
    public private(set) var expandFailed: [TranscriptEntry.ID: String] = [:]

    /// New output that landed while the reader was scrolled up. The `↓ N new`
    /// pill, and nothing else: the view never moves on its own for this.
    public private(set) var unreadTail = 0
    /// The rare case — more happened between two polls than one page holds, so
    /// the count is not knowable and the pill says so instead of a wrong number.
    public private(set) var unreadTailIsGap = false
    /// Set when the file was rewritten under us. The screen says so once; it is
    /// not an error and there is nothing to retry.
    public private(set) var wasCompacted = false

    /// Bumped every time the view should put itself at the newest entry. A
    /// token rather than a bool because two consecutive appends must both
    /// scroll, and `onChange` needs something that actually changed.
    public private(set) var followToken = 0

    /// What the view last measured. **The whole auto-scroll rule reads this and
    /// nothing else** — see `TranscriptRules.follow`.
    public var readerAtBottom = true

    public let account: String
    public let sid: String

    private let source: any TranscriptSource
    private let limit: Int
    private var poll: Task<Void, Never>?
    /// When the file was last seen to grow. Drives the 5 s / 15 s choice.
    private var lastGrowth: Date?

    /// **The ceiling on what is held, and it is not the ceiling on what is
    /// readable.** Thirty pages of entries is already more than any reader will
    /// scroll through in a sitting, and holding an unbounded window is how a
    /// 100 MB transcript becomes a 100 MB app. Trimming only ever happens at the
    /// OLD end and only ever while the reader is at the newest entry, so nothing
    /// moves under a thumb; the top of the window then reports `has_more_before`
    /// again and scrolling up re-fetches it.
    static let maxEntries = 900

    public init(source: any TranscriptSource, account: String, sid: String,
                limit: Int = Endpoint.transcriptPageSize) {
        self.source = source
        self.account = account
        self.sid = sid
        self.limit = limit
    }

    // MARK: - Lifecycle

    public func start() {
        guard poll == nil else { return }
        poll = Task { [weak self] in
            await self?.loadNewest()
            while !Task.isCancelled {
                let period = self?.pollPeriod ?? ChatStore.restPeriod
                try? await Task.sleep(nanoseconds: UInt64(period * 1_000_000_000))
                if Task.isCancelled { return }
                await self?.tick()
            }
        }
    }

    public func stop() {
        poll?.cancel()
        poll = nil
    }

    /// 5 s while the transcript is being written, 15 s once it has gone quiet.
    var pollPeriod: TimeInterval {
        TranscriptRules.pollPeriod(lastGrowth: lastGrowth, now: Date())
    }

    // MARK: - Reads

    /// The newest page, from scratch. The screen opens on this.
    public func loadNewest() async {
        guard !loadingNewest else { return }
        loadingNewest = true
        defer { loadingNewest = false }
        do {
            let page = try await source.transcriptPage(account: account, sid: sid,
                                                       limit: limit, before: nil)
            applyNewest(page)
        } catch let error as OrchestraError {
            if case .cancelled = error { return }
            transportError = error
        } catch {
            transportError = ErrnoCause.classify(error)
        }
    }

    /// One page further back. Called by the top of the list coming into view.
    public func loadOlder() async {
        guard hasMoreBefore, !loadingOlder, let before = cursorBefore else { return }
        loadingOlder = true
        defer { loadingOlder = false }
        do {
            let page = try await source.transcriptPage(account: account, sid: sid,
                                                       limit: limit, before: before)
            applyOlder(page)
        } catch let error as OrchestraError {
            if case .cancelled = error { return }
            transportError = error
        } catch {
            transportError = ErrnoCause.classify(error)
        }
    }

    /// The live tail. **One small probe, then a page only if there is one to
    /// fetch.**
    ///
    /// The route pages backwards and has no `after=`, so following a live
    /// session means re-reading the newest page — which on a busy agent is a
    /// quarter of a megabyte every five seconds for output that has not changed.
    /// `limit=1` answers with the `file` identity for the price of one entry,
    /// and that identity is both halves of what this store needs: `ino`/`dev`
    /// say whether the offsets are still valid at all, and `size`/`mtime_ns` say
    /// whether there is anything new to ask for.
    public func tick() async {
        do {
            let probe = try await source.transcriptPage(account: account, sid: sid,
                                                        limit: 1, before: nil)
            guard probe.ok else {
                serverError = probe.error ?? "the server refused, without saying why"
                return
            }
            serverError = nil
            transportError = nil
            guard let now = probe.file else { return }
            if TranscriptRules.mustReload(previous: file, current: now) {
                wasCompacted = true
                resetWindow()
                await loadNewest()
                return
            }
            guard let known = file, now.grew(from: known) else {
                file = now
                return
            }
            lastGrowth = Date()
            let page = try await source.transcriptPage(account: account, sid: sid,
                                                       limit: limit, before: nil)
            applyTail(page)
        } catch let error as OrchestraError {
            if case .cancelled = error { return }
            transportError = error
        } catch {
            transportError = ErrnoCause.classify(error)
        }
    }

    /// Fetch one block uncapped. The `show all` button, and it actually fetches.
    public func expand(_ id: TranscriptEntry.ID) async {
        guard fullText[id] == nil, !expanding.contains(id) else { return }
        expanding.insert(id)
        expandFailed[id] = nil
        defer { expanding.remove(id) }
        do {
            let page = try await source.transcriptEntry(account: account, sid: sid,
                                                        off: id.off, i: id.i)
            applyEntry(page, for: id)
        } catch let error as OrchestraError {
            if case .cancelled = error { return }
            expandFailed[id] = error.headline
        } catch {
            expandFailed[id] = ErrnoCause.classify(error).headline
        }
    }

    // MARK: - The seams the tests drive
    //
    // Every rule below is applied to a DECODED page and touches no network, so
    // the paging walk, the compaction reset, the tail merge and the follow
    // decision are all drivable from literals — which is where this house puts
    // its tests, and the only way the `.gap` branch is ever exercised at all.

    public func applyNewest(_ page: TranscriptPage) {
        guard page.ok else {
            serverError = page.error ?? "the server refused, without saying why"
            return
        }
        serverError = nil
        transportError = nil
        loadedAt = Date()
        if let f = page.file {
            if let known = file, !f.isSameFile(as: known) { wasCompacted = true }
            file = f
        }
        entries = page.messages
        hasMoreBefore = page.hasMoreBefore
        cursorBefore = page.cursorBefore
        unreadTail = 0
        unreadTailIsGap = false
        followToken &+= 1
    }

    public func applyOlder(_ page: TranscriptPage) {
        guard page.ok else {
            serverError = page.error ?? "the server refused, without saying why"
            return
        }
        serverError = nil
        transportError = nil
        if let f = page.file, let known = file, !f.isSameFile(as: known) {
            // The file was rewritten between the page we hold and this one.
            // Anything stitched on now would be somebody else's bytes.
            wasCompacted = true
            resetWindow()
            file = f
            return
        }
        if let f = page.file { file = f }
        entries = TranscriptRules.prepend(page.messages, to: entries)
        hasMoreBefore = page.hasMoreBefore
        // A page that picked nothing still moves the cursor — `_page` hands back
        // the oldest line start the read proved exists — so a run of pure
        // bookkeeping walks backwards instead of stalling on the same offset.
        cursorBefore = page.cursorBefore
    }

    public func applyTail(_ page: TranscriptPage) {
        guard page.ok else {
            serverError = page.error ?? "the server refused, without saying why"
            return
        }
        serverError = nil
        if let f = page.file {
            if let known = file, !f.isSameFile(as: known) {
                wasCompacted = true
                resetWindow()
                applyNewest(page)
                return
            }
            file = f
        }
        switch TranscriptRules.tail(window: entries, newest: page.messages) {
        case .unchanged:
            return
        case .appended(let fresh):
            entries += fresh
            note(TranscriptRules.follow(atBottom: readerAtBottom, appended: fresh.count))
            trimIfSafe()
        case .gap(let newest):
            // More happened between two polls than one page holds. Butting the
            // two ends together would draw a transcript that never existed.
            if readerAtBottom {
                entries = newest
                hasMoreBefore = true
                cursorBefore = page.cursorBefore
                followToken &+= 1
            } else {
                unreadTail = max(unreadTail, 1)
                unreadTailIsGap = true
            }
        }
    }

    public func applyEntry(_ page: TranscriptPage, for id: TranscriptEntry.ID) {
        guard page.ok else {
            expandFailed[id] = page.error ?? "the server refused, without saying why"
            return
        }
        guard let full = page.messages.first(where: { $0.id == id })
                ?? page.messages.first else {
            expandFailed[id] = "no entry at that offset"
            return
        }
        fullText[id] = full
    }

    private func note(_ follow: TranscriptRules.Follow) {
        switch follow {
        case .scrollToBottom:
            unreadTail = 0
            unreadTailIsGap = false
            followToken &+= 1
        case .offer(let n):
            unreadTail += n
        case .nothing:
            break
        }
    }

    /// The reader took the `↓ N new` pill. The entries were already appended —
    /// the pill is about where the VIEW is, never about what is held.
    public func takeTail() {
        unreadTail = 0
        unreadTailIsGap = false
        followToken &+= 1
    }

    /// Only ever at the old end, and only while the reader is at the newest
    /// entry — otherwise the content under their thumb moves.
    private func trimIfSafe() {
        guard readerAtBottom, entries.count > Self.maxEntries else { return }
        entries.removeFirst(entries.count - Self.maxEntries)
        hasMoreBefore = true
        cursorBefore = entries.first?.off
    }

    private func resetWindow() {
        entries = []
        hasMoreBefore = true
        cursorBefore = nil
        openTools = []
        fullText = [:]
        expandFailed = [:]
        unreadTail = 0
        unreadTailIsGap = false
    }

    // MARK: - What the view asks

    /// The window with the `meta` filter applied. The only list the view draws.
    public var visible: [TranscriptEntry] {
        TranscriptRules.visible(entries, showMeta: showMeta)
    }

    /// How many entries the toggle is hiding right now. Said out loud on the
    /// screen so "hidden" never reads as "not there".
    public var hiddenByFilter: Int {
        showMeta ? 0 : TranscriptRules.hiddenCount(entries)
    }

    public func isOpen(_ entry: TranscriptEntry) -> Bool {
        TranscriptRules.collapsedByDefault(entry.role)
            ? openTools.contains(entry.id)
            : true
    }

    public func toggle(_ entry: TranscriptEntry) {
        guard TranscriptRules.collapsedByDefault(entry.role) else { return }
        if openTools.contains(entry.id) {
            openTools.remove(entry.id)
        } else {
            openTools.insert(entry.id)
        }
    }

    /// The text to draw: the uncapped block if `show all` has been taken, the
    /// paged one otherwise.
    public func text(for entry: TranscriptEntry) -> String {
        fullText[entry.id]?.text ?? entry.text
    }

    #if DEBUG
    /// `ORC_TRANSCRIPT=noise,tools,all,top` — the taps a simulator has no finger
    /// for.
    ///
    /// The same kind of seam as `ORC_SCREEN` and `ORC_SEND`, and it exists for
    /// the same reason: this screen's whole subject is what happens when you
    /// *open* a folded block or *take* the `show all` offer, `xcrun simctl` can
    /// screenshot but cannot tap, and the house gate is that a phase ends with
    /// the thing LOOKED at. Each word presses exactly the control a thumb would
    /// — `toggle`, `expand`, `showMeta` — never a second path into the state.
    ///
    /// * `noise` — the toolbar's `show system noise`
    /// * `tools` — every folded tool block, opened
    /// * `all`   — every `show all`, taken (a real `/at/` fetch each)
    /// * `top`   — every `load older`, until `— start of transcript —`
    public func applyDebugSeam(_ raw: String) async {
        let words = Set(raw.lowercased().split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) })
        if words.contains("top") {
            var guardrail = 0
            while hasMoreBefore && guardrail < 50 {
                await loadOlder()
                guardrail += 1
            }
        }
        if words.contains("noise") { showMeta = true }
        if words.contains("tools") {
            for entry in entries where TranscriptRules.collapsedByDefault(entry.role) {
                if !openTools.contains(entry.id) { toggle(entry) }
            }
        }
        if words.contains("all") {
            for entry in entries where entry.truncated {
                await expand(entry.id)
            }
        }
    }

    /// `ORC_TRANSCRIPT=fail` — park on the first tool result the tool reported
    /// an error for, which is the one row a screenshot cannot otherwise reach
    /// and the one whose colour rule (`ok == false`) has no other witness.
    public var debugFirstFailure: TranscriptEntry.ID? {
        let raw = ProcessInfo.processInfo.environment["ORC_TRANSCRIPT"]?.lowercased() ?? ""
        guard raw.split(separator: ",")
            .map({ $0.trimmingCharacters(in: .whitespaces) }).contains("fail")
        else { return nil }
        return visible.first { $0.role == .toolResult && $0.tool?.ok == false }?.id
    }

    /// Whether the debug seam asked to be parked at the oldest entry rather than
    /// the newest.
    public static func debugWantsTop(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        (environment["ORC_TRANSCRIPT"]?.lowercased().split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? []).contains("top")
    }
    #endif

    /// Whether this entry still has bytes the reader has not been offered.
    /// False once `/at/` has answered — even if the 256 KB ceiling cut it
    /// again, because there is no third route to offer.
    public func isCut(_ entry: TranscriptEntry) -> Bool {
        guard fullText[entry.id] == nil else { return false }
        return entry.truncated
    }
}
