import Foundation

/// Every rule the full-transcript reader runs on, as values with no view, no
/// clock of their own and no I/O.
///
/// They live here and not in `UI/TranscriptView.swift` because `UI` is excluded
/// from the test target on purpose (it is `import SwiftUI` + `UIKit`, and the
/// palette resolves through `UIColor(dynamicProvider:)`, which does not exist on
/// macOS). A rule inside a `body` is a rule that can only be checked by looking
/// at a screenshot, and the two rules on this screen that are instantly
/// noticeable when wrong — *what is folded* and *when the view is allowed to
/// scroll under the reader's thumb* — are exactly the two nobody would notice
/// were wrong in a diff.
public enum TranscriptRules {

    // MARK: - What is open, and what is folded

    /// **`user` and `assistant` expanded; `tool_use` and `tool_result` folded.**
    ///
    /// This is the whole readability argument of the screen. A terminal dumps
    /// five hundred lines of a file read at you whether you wanted them or not;
    /// this offers them. Nothing is unreachable — a folded block is one tap from
    /// its full text, and the fold line states the size so the reader knows what
    /// they are choosing.
    ///
    /// `system` is expanded because a system entry is short by construction (a
    /// summary, a reminder, a `[image]` marker) and folding one line behind a
    /// tap buys nothing.
    public static func collapsedByDefault(_ role: TranscriptRole) -> Bool {
        role == .toolUse || role == .toolResult
    }

    /// **`meta` is hidden, and it is hidden rather than dropped.**
    ///
    /// The default read is the conversation: system reminders, harness text,
    /// thinking blocks and inlined subagent work are behind one toolbar toggle.
    /// The toggle is the contract — with it on, every byte the server sent is on
    /// screen, which is the half of the ask that says *"if I go down to that
    /// level, I want to know the details."*
    ///
    /// **A tool entry is never hidden by this**, because the server never marks
    /// one `meta`: a tool call is primary content. The one exception is a
    /// sidechain tool call, which the server marks `meta` with
    /// `why == .sidechain` — subagent work first, tool second — and which
    /// therefore rides the toggle like the rest of the noise.
    public static func isVisible(_ entry: TranscriptEntry, showMeta: Bool) -> Bool {
        showMeta || !entry.meta
    }

    public static func visible(_ entries: [TranscriptEntry],
                               showMeta: Bool) -> [TranscriptEntry] {
        showMeta ? entries : entries.filter { !$0.meta }
    }

    /// How many entries the toggle is currently hiding — said out loud, so
    /// "hidden" never reads as "not there".
    public static func hiddenCount(_ entries: [TranscriptEntry]) -> Int {
        entries.reduce(0) { $0 + ($1.meta ? 1 : 0) }
    }

    // MARK: - Truncation, stated in both numbers

    /// `cut at 4,000 of 12,431` — or nil when nothing was cut.
    ///
    /// **`truncated` is the only signal.** The old chat bubble inferred a cut
    /// from a trailing `…` and false-positived on every paragraph that ends in
    /// one; this route ships a real flag and appends no ellipsis at all, so
    /// there is nothing left to guess. Both numbers are stated because "show
    /// all" on an entry that turns out to be 200 KB is a different decision from
    /// "show all" on one that is 4,100.
    public static func cutLabel(_ entry: TranscriptEntry) -> String? {
        guard entry.truncated, entry.hiddenScalars > 0 else { return nil }
        return "cut at \(group(entry.text.unicodeScalars.count)) of \(group(entry.chars))"
    }

    /// Digit grouping without a locale's decimal comma turning a length into
    /// something that reads like a fraction. `Text(verbatim:)` is what stops
    /// SwiftUI localising it a second time.
    public static func group(_ n: Int) -> String {
        let s = String(n)
        guard s.count > 3 else { return s }
        var out = ""
        for (k, ch) in s.enumerated() {
            if k > 0, (s.count - k) % 3 == 0 { out.append(",") }
            out.append(ch)
        }
        return out
    }

    /// The server's own per-message cap, applied client-side.
    ///
    /// It exists for exactly one caller — the demo fleet, which has no server to
    /// apply it — and it is here rather than in `Demo/` so that the rule the
    /// demo obeys is the same value the tests pin against the real one. 4,000 on
    /// the paged route, 256 KB on `/at/` (`sessionlog.MAX_ENTRY_CHARS` /
    /// `MAX_ONE_CHARS`).
    public static let pagedCap = 4000
    public static let entryCap = 256 * 1024

    public static func cap(_ entry: TranscriptEntry, at cap: Int) -> TranscriptEntry {
        let scalars = Array(entry.text.unicodeScalars)
        guard scalars.count > cap else {
            return TranscriptEntry(off: entry.off, i: entry.i, role: entry.role,
                                   text: entry.text, truncated: false,
                                   chars: scalars.count, ts: entry.ts,
                                   meta: entry.meta, model: entry.model,
                                   why: entry.why, tool: entry.tool)
        }
        var head = String.UnicodeScalarView()
        head.append(contentsOf: scalars[0..<cap])
        return TranscriptEntry(off: entry.off, i: entry.i, role: entry.role,
                               text: String(head), truncated: true,
                               chars: scalars.count, ts: entry.ts,
                               meta: entry.meta, model: entry.model,
                               why: entry.why, tool: entry.tool)
    }

    // MARK: - The folded line

    /// `Read  ios/Sources/…/ChatView.swift · 12,431 ch` — one dense line for a
    /// folded tool block.
    ///
    /// A `tool_use`'s text is `json.dumps(input, indent=2)`, which is the right
    /// thing expanded and useless folded, so the fold shows the ONE argument a
    /// human recognises the call by: the path it read, the command it ran, the
    /// pattern it searched for. The key order is the order a reader would scan.
    /// Anything unrecognised falls back to the first non-structural line, and an
    /// empty input to nothing at all — never to a fabricated summary.
    ///
    /// A `tool_result` has no arguments, so its fold shows its **first line of
    /// output**, which is what a terminal would have put at the top of the dump
    /// and is the one line that says whether the rest is worth opening.
    public static func toolSummary(_ entry: TranscriptEntry) -> String {
        if entry.role == .toolResult {
            for line in entry.text.split(separator: "\n", omittingEmptySubsequences: true) {
                let t = line.trimmingCharacters(in: .whitespaces)
                // **A rule of banners, not of blank lines.** Test runners and
                // diff tools open with `======` and `------`, which is a line
                // with no information in it at all — folding a 4 KB result
                // behind `================` tells the reader nothing about
                // whether it is worth opening.
                guard t.contains(where: { $0.isLetter || $0.isNumber }) else { continue }
                return oneLine(t)
            }
            return ""
        }
        guard entry.role == .toolUse else { return "" }
        let keys = ["file_path", "path", "notebook_path", "command", "pattern",
                    "query", "url", "prompt", "description"]
        for key in keys {
            if let value = jsonStringValue(entry.text, key: key) {
                return oneLine(value)
            }
        }
        for line in entry.text.split(separator: "\n", omittingEmptySubsequences: true) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t == "{" || t == "}" || t.isEmpty { continue }
            return oneLine(t)
        }
        return ""
    }

    /// A top-level `"key": "value"` out of the indented JSON a `tool_use`
    /// carries. Deliberately a scan and not a `JSONSerialization` round trip:
    /// the text may be **cut at 4,000 characters**, so it is regularly not valid
    /// JSON at all, and a parser that throws on the truncated case would leave
    /// exactly the biggest calls without a summary.
    static func jsonStringValue(_ json: String, key: String) -> String? {
        guard let range = json.range(of: "\"\(key)\":") else { return nil }
        var rest = json[range.upperBound...].drop { $0 == " " }
        guard rest.first == "\"" else { return nil }
        rest = rest.dropFirst()
        var out = ""
        var escaped = false
        for ch in rest {
            if escaped {
                switch ch {
                case "n": out.append("\n")
                case "t": out.append("\t")
                case "\\": out.append("\\")
                case "\"": out.append("\"")
                default: out.append(ch)
                }
                escaped = false
                continue
            }
            if ch == "\\" { escaped = true; continue }
            if ch == "\"" { return out }
            out.append(ch)
        }
        // Unterminated — the entry was cut mid-value. What was read is still the
        // best summary there is, and saying it is better than saying nothing.
        return out.isEmpty ? nil : out
    }

    /// One line, and bounded — but generously.
    ///
    /// **The truncating is SwiftUI's job, not this function's.** A `Text` in the
    /// fold row already truncates in the middle at the width it actually has,
    /// and a value cut here to 52 characters first produced *two* ellipses in
    /// one line (`Write fixtures tha…co…uring a rebuild.`), which reads as
    /// corruption. This limit exists only so that a pathological input — a
    /// `Write` call's whole file content on one line — cannot hand the layout a
    /// 200 KB string to measure.
    public static func oneLine(_ raw: String, limit: Int = 120) -> String {
        let flat = raw.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .joined(separator: " ")
        guard flat.count > limit else { return flat }
        // The head is the part that identifies a path or a command; the tail is
        // the part that identifies a file. Keep both.
        let head = flat.prefix(limit - 20)
        let tail = flat.suffix(16)
        return "\(head)…\(tail)"
    }

    /// `4,312 ch` — the size of a folded block, in the same units the server
    /// counted. For a truncated block it is the TRUE size, not what arrived.
    public static func sizeLabel(_ entry: TranscriptEntry) -> String {
        "\(group(max(entry.chars, entry.text.unicodeScalars.count))) ch"
    }

    /// How many lines an expanded tool block draws before it offers the rest.
    ///
    /// **Not a scroll view inside a scroll view.** A bounded, vertically
    /// scrolling container nested in the page's own vertical scroll captures the
    /// gesture on iOS and traps a thumb inside a code block — the reader's
    /// scroll simply stops working, which is worse than any amount of length.
    /// So an expanded block grows the PAGE, up to a budget, and the budget lifts
    /// on a tap that says how many lines are behind it. Horizontal scrolling is
    /// still the block's own, because that is the axis the page must never have.
    public static let expandedLineBudget = 40

    public static func lineCount(_ text: String) -> Int {
        text.isEmpty ? 0 : text.split(separator: "\n", omittingEmptySubsequences: false).count
    }

    /// The first `budget` lines, and how many were left behind.
    public static func budgeted(_ text: String,
                                budget: Int = expandedLineBudget) -> (shown: String, more: Int) {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count > budget else { return (text, 0) }
        return (lines[0..<budget].joined(separator: "\n"), lines.count - budget)
    }

    // MARK: - Paging

    /// Prepend an older page to the window: **older first, no duplicates, and
    /// the order the file has.**
    ///
    /// `before` is exclusive server-side, so a correct walk never produces a
    /// duplicate at all — the dedupe is here because a compaction, a retry or a
    /// double-tap on `load older` are all cheaper to survive than to prevent, and
    /// a duplicated `(off, i)` in a `ForEach` is a runtime warning and a wrong
    /// screen rather than a wrong number.
    public static func prepend(_ older: [TranscriptEntry],
                               to window: [TranscriptEntry]) -> [TranscriptEntry] {
        guard !older.isEmpty else { return window }
        let held = Set(window.map(\.id))
        return older.filter { !held.contains($0.id) } + window
    }

    /// What a freshly-fetched newest page means for the window we hold.
    public enum Tail: Equatable, Sendable {
        /// Nothing on that page we do not already have.
        case unchanged
        /// These are new, and they continue the window we hold.
        case appended([TranscriptEntry])
        /// The newest page does not touch the window: more happened between two
        /// polls than one page holds. Everything between is real and unread, and
        /// the only honest moves are to reload from the newest page or to say so
        /// — never to butt the two ends together as if they were contiguous.
        case gap([TranscriptEntry])
    }

    /// **The live tail, and the one case a naive append gets silently wrong.**
    ///
    /// The route pages BACKWARDS only — there is no `after=` — so following a
    /// live session means re-reading the newest page and working out how it
    /// relates to what is already on screen. Overlap proves contiguity; no
    /// overlap proves a hole.
    public static func tail(window: [TranscriptEntry],
                            newest: [TranscriptEntry]) -> Tail {
        guard !newest.isEmpty else { return .unchanged }
        guard let last = window.last else { return .gap(newest) }
        let held = Set(window.map(\.id))
        let fresh = newest.filter { !held.contains($0.id) && $0.id > last.id }
        if fresh.isEmpty { return .unchanged }
        // Contiguous exactly when the new page reaches back into what we hold.
        let overlaps = newest.contains { held.contains($0.id) }
            || (newest.first.map { $0.id <= last.id } ?? false)
        return overlaps ? .appended(fresh) : .gap(newest)
    }

    /// **A compaction voids every offset at once.** Both halves of the identity
    /// are compared: an inode is unique per device, not globally.
    public static func mustReload(previous: TranscriptFile?,
                                  current: TranscriptFile?) -> Bool {
        guard let previous, let current else { return false }
        return !current.isSameFile(as: previous)
    }

    // MARK: - Reaching backwards

    /// What the top of the window should do at this scroll position.
    public struct TopReach: Equatable, Sendable {
        /// Whether the trigger is armed **after** this event.
        public let armed: Bool
        /// Whether to fetch one older page now.
        public let load: Bool

        public init(armed: Bool, load: Bool) {
            self.armed = armed
            self.load = load
        }
    }

    /// **The tripwire that asks for an older page — and the rule that stops it
    /// fighting the restore that follows it.**
    ///
    /// A user on a real phone reported exactly the failure this rule exists to
    /// prevent: *"when i scroll up to the top of the full log, it keeps 'loading
    /// older …' but they dont seem to actually appear."* Nothing was wrong with
    /// the server, the cursor walk or the filter — pages arrived, carried visible
    /// content, and were prepended correctly. What was wrong was **where the
    /// reader was put afterwards**.
    ///
    /// The trigger used to be an `.onAppear` on the `loading older…` row, which
    /// sits at the very top of the list, and the restore that followed a load
    /// scrolled to `visible.first` — the oldest entry the window ALREADY held,
    /// which is the row immediately below that same trigger. So every user-driven
    /// load parked the reader back on the tripwire with the page that had just
    /// arrived stacked above the viewport, and the next flick upwards tripped it
    /// again before a line of it could be read. The loader spins, the window
    /// grows, and nothing older ever reaches the screen.
    ///
    /// So the trigger is a value driven by **scroll geometry** rather than by a
    /// row's lifecycle, and it carries one bit of memory:
    ///
    /// * **it fires early** — `prefetchMargin` before the top, so the page is on
    ///   its way while the reader still has content in front of them;
    /// * **it disarms the instant it fires**, because the restore that follows
    ///   lands the reader near the top of the window by construction, and a
    ///   trigger that re-fires there is a trigger fighting its own restore;
    /// * **it re-arms only on evidence the reader consumed what arrived** —
    ///   either they are `rearmMargin` clear of the top (the page that landed is
    ///   between them and it), or they are hard against the top, which after a
    ///   restore means they scrolled through the whole of it.
    ///
    /// `rearmMargin > prefetchMargin` is the hysteresis and it is what makes
    /// "consumed" mean anything: re-arming at the distance the trigger fires at
    /// would let one point of drift fire a second load.
    ///
    /// The arrival leg is not a loophole in the first: a page that adds less than
    /// `prefetchMargin` of height cannot be "scrolled through" in any meaningful
    /// sense, and refusing to fetch again there is how the old defect looked from
    /// the reader's side — a spinner at the top of a list that will not grow.
    /// Reaching the top of the window with more file behind it is always a
    /// request for more, and it is answered.
    public static func topReach(offsetFromTop: Double,
                                armed: Bool,
                                hasMoreBefore: Bool,
                                loading: Bool,
                                prefetch: Double = prefetchMargin,
                                rearm: Double = rearmMargin,
                                arrival: Double = arrivalMargin) -> TopReach {
        // Byte 0 is on screen: there is nothing above to ask for, and the
        // trigger's state is left exactly as it was found.
        guard hasMoreBefore else { return TopReach(armed: armed, load: false) }
        var armed = armed
        if !armed, offsetFromTop >= rearm || offsetFromTop <= arrival { armed = true }
        guard armed, !loading, offsetFromTop <= prefetch else {
            return TopReach(armed: armed, load: false)
        }
        return TopReach(armed: false, load: true)
    }

    /// How far short of the top of the window a page is asked for — about one
    /// screen on a phone, so the fetch overlaps the reading rather than
    /// interrupting it.
    public static let prefetchMargin: Double = 900
    /// How far clear of the top the reader must travel for the trigger to arm
    /// again. Deliberately more than twice `prefetchMargin`: it is the distance
    /// a page has to be worth before the next one is asked for.
    public static let rearmMargin: Double = 2200
    /// "Hard against the top." A few points, not zero, because a scroll view at
    /// rest at its top edge does not always report exactly 0.
    public static let arrivalMargin: Double = 8

    // MARK: - Following

    /// What the view is allowed to do when new entries land at the bottom.
    public enum Follow: Equatable, Sendable {
        /// The reader is at the newest entry; keep them there.
        case scrollToBottom
        /// The reader has scrolled up to read. **Leave them exactly where they
        /// are** and offer the new output as a pill they can take.
        case offer(Int)
        case nothing
    }

    /// **Auto-scroll only if the reader is already at the bottom.**
    ///
    /// The one interaction on this screen that people notice immediately when it
    /// is wrong: a reader three pages up in a tool result, yanked to the newest
    /// line every five seconds because an agent is working. It is a pure
    /// function of two facts precisely so that it can be pinned by a test rather
    /// than by a video of a thumb.
    public static func follow(atBottom: Bool, appended: Int) -> Follow {
        guard appended > 0 else { return .nothing }
        return atBottom ? .scrollToBottom : .offer(appended)
    }

    // MARK: - Cadence

    /// **`ChatStore`'s cadence, not a third one.**
    ///
    /// 5 s while the transcript is being written, 15 s once it has gone quiet —
    /// the same two numbers and the same two-minute active window the chat
    /// screen already polls on, read from `ChatStore` so the two cannot drift
    /// apart in a later edit. The trigger differs because the evidence differs:
    /// chat is "a send is unsettled", and here it is "the file grew", which is
    /// the only thing a reader of a transcript is waiting for.
    public static func pollPeriod(lastGrowth: Date?, now: Date) -> TimeInterval {
        guard let lastGrowth,
              now.timeIntervalSince(lastGrowth) < ChatStore.activeWindow
        else { return ChatStore.restPeriod }
        return ChatStore.activePeriod
    }
}
