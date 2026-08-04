import SwiftUI

/// Which session's full log to open. A value, so the push is something a script
/// can press as well as a thumb (`FleetRoute` is a value for the same reason).
public struct TranscriptTarget: Hashable, Sendable {
    public let worktree: String
    public let account: String
    public let sid: String

    public init(worktree: String, account: String, sid: String) {
        self.worktree = worktree
        self.account = account
        self.sid = sid
    }
}

/// The whole transcript — everything the terminal showed, on a phone.
///
/// The ask this screen answers, in the user's words: *"I want to see just as
/// much on the phone as one can see in a real terminal window with Claude Code
/// running… I want to be able to scroll through the entire output. Ideally we
/// make it still kind of pleasant to look at."*
///
/// Two requirements in tension — **completeness** (nothing unreachable) and
/// **readability** (a raw terminal dump on a 6" screen is unreadable). It is
/// resolved the way a good log viewer resolves it: *everything is present,
/// structure decides what is open.*
///
/// * `user` and `assistant` prose is **expanded** — that is the substance.
/// * `tool_use` / `tool_result` are **folded** to one dense line carrying the
///   argument you recognise the call by and the size of what is behind it. A
///   terminal dumps five hundred lines of a file read at you; this offers them.
/// * `meta` — system reminders, harness text, thinking, inlined subagent work —
///   is **hidden behind one toolbar toggle**, and the strip under the title says
///   how many entries the toggle is holding, so hidden never reads as absent.
/// * An expanded tool block **does not wrap**: command output and code are
///   column-aligned and wrapping destroys the alignment that makes them
///   readable. Each one is its own horizontally scrollable container. **The page
///   itself never scrolls sideways.**
///
/// **A pushed screen, not a mode of `ChatView`.** `ChatView` is the acting
/// surface — composer, receipts, refusal copy — and it is proven; this is a
/// reading surface that wants the whole screen height, its own bottom-anchored
/// scroll and its own filter. Cramming both into one layout re-invites the exact
/// `safeAreaInset` defect a bottom-pinned control inside a pushed destination
/// has already caused twice in this project.
public struct TranscriptView: View {
    private let target: TranscriptTarget
    @State private var store: TranscriptStore
    /// The connection strip's real height. Nothing here is bottom-pinned except
    /// the `↓ N new` pill, and the pill is exactly the kind of thing that ends
    /// up underneath the strip if it assumes the safe area it is not given.
    @Environment(\.bottomAccessoryHeight) private var accessoryHeight

    public init(target: TranscriptTarget, source: any TranscriptSource) {
        self.target = target
        _store = State(initialValue: TranscriptStore(source: source,
                                                     account: target.account,
                                                     sid: target.sid))
    }

    public var body: some View {
        content
            .background { Palette.canvas.ignoresSafeArea() }
            .navigationTitle("full log")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 0) {
                        Text(verbatim: "full log · [\(target.account)]")
                            .font(OrcFont.status)
                            .foregroundStyle(Palette.textPrimary)
                        Text(verbatim: String(target.sid.prefix(8)))
                            .font(OrcFont.meta)
                            .foregroundStyle(Palette.textTertiary)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) { noiseToggle }
            }
            .task { store.start() }
            .onDisappear { store.stop() }
    }

    /// **Off by default, and it says what it is doing in words.** An icon alone
    /// is not enough for a control whose whole job is "there is more here than
    /// you can see" — the strip below the title carries the state as text so a
    /// screenshot can be read as easily as the screen.
    private var noiseToggle: some View {
        Button {
            store.showMeta.toggle()
        } label: {
            Image(systemName: store.showMeta ? "eye.fill" : "eye.slash")
                .font(OrcFont.button)
                .foregroundStyle(store.showMeta ? Palette.statusFree : Palette.textTertiary)
        }
        .accessibilityLabel(store.showMeta ? "hide system noise" : "show system noise")
    }

    @ViewBuilder
    private var content: some View {
        VStack(spacing: 0) {
            strip
            Divider().overlay(Palette.hairline)
            if let message = store.serverError {
                refusal(message)
            } else if let error = store.transportError, store.entries.isEmpty {
                FailureView(error: error) { Task { await store.loadNewest() } }
            } else if store.entries.isEmpty && store.loadingNewest {
                ProgressView().tint(Palette.textTertiary).padding(Space.xl)
                Spacer()
            } else if store.entries.isEmpty {
                ContentUnavailableView("nothing to show",
                                       systemImage: "text.alignleft",
                                       description: Text("this transcript has no entry "
                                                         + "carrying text — the CLI's own "
                                                         + "bookkeeping lines are not "
                                                         + "messages and the terminal "
                                                         + "never drew them either"))
            } else {
                log
            }
        }
    }

    /// What is on screen and what is not. Both facts, always.
    private var strip: some View {
        HStack(spacing: Space.sm) {
            Text(verbatim: "raw · \(TranscriptRules.group(store.entries.count)) loaded")
                .font(OrcFont.meta)
                .foregroundStyle(Palette.textTertiary)
            if store.wasCompacted {
                Text("· transcript was rewritten, reloaded")
                    .font(OrcFont.meta)
                    .foregroundStyle(Palette.statusLimit)
                    .lineLimit(1)
            }
            Spacer(minLength: Space.xs)
            Text(noiseLabel)
                .font(OrcFont.meta)
                .foregroundStyle(store.showMeta ? Palette.statusFree : Palette.textDisabled)
        }
        .padding(.horizontal, Space.lg)
        .padding(.vertical, Space.sm)
    }

    private var noiseLabel: String {
        if store.showMeta { return "system noise: on" }
        let hidden = store.hiddenByFilter
        return hidden > 0
            ? "system noise: off · \(TranscriptRules.group(hidden)) hidden"
            : "system noise: off"
    }

    // MARK: - The log

    private var log: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Space.md) {
                    topMarker(proxy)
                    // Keyed on `(off, i)` and never on `off`: one assistant line
                    // carries thinking, prose and several tool calls, and a
                    // `ForEach` keyed on the line would draw one row for the lot
                    // and reuse the wrong view for the rest.
                    ForEach(store.visible) { entry in
                        TranscriptRow(entry: entry,
                                      open: store.isOpen(entry),
                                      text: store.text(for: entry),
                                      cut: store.isCut(entry),
                                      fetching: store.expanding.contains(entry.id),
                                      failure: store.expandFailed[entry.id],
                                      onToggle: { store.toggle(entry) },
                                      onShowAll: { Task { await store.expand(entry.id) } })
                        .id(entry.id)
                    }
                    // **The scroll target carries the inset, and it has to be
                    // the target rather than a `.padding` on the stack.**
                    // A PUSHED destination does not receive the
                    // `safeAreaInset` the tab applied outside the
                    // `NavigationStack` — the defect that put the composer
                    // under the connection strip in phase 3 — so something
                    // here has to hold the strip's height. Put on the LazyVStack
                    // as padding it sits BELOW this anchor, `scrollTo(.bottom)`
                    // stops with the anchor at the viewport's edge, and the
                    // newest entry ends up behind the strip anyway: a
                    // screenshot showed exactly that. Measured, not assumed —
                    // the strip grows a second line on a stale board.
                    Color.clear
                        .frame(height: Space.md + accessoryHeight)
                        .id("bottom")
                }
                .padding(.horizontal, Space.lg)
                .padding(.top, Space.md)
            }
            .scrollIndicators(.hidden)
            // The only measurement the follow rule reads. `visibleRect.maxY` is
            // the bottom of what is on screen; within one comfortable line of
            // the content's end counts as being at the newest entry.
            .onScrollGeometryChange(for: Bool.self) { geo in
                geo.visibleRect.maxY >= geo.contentSize.height - Space.xxl
            } action: { _, atBottom in
                store.readerAtBottom = atBottom
            }
            // Bumped by the store exactly when the reader is entitled to be
            // moved: the first page, a compaction reload, new output while they
            // were already at the bottom, or the pill being taken. Never on a
            // poll that found something while they were reading history.
            .onChange(of: store.followToken) { _, _ in
                Task { await toBottom(proxy) }
            }
            .task {
                store.readerAtBottom = true
                await toBottom(proxy)
            }
            #if DEBUG
            // `ORC_TRANSCRIPT=noise,tools,all,top` — see
            // `TranscriptStore.applyDebugSeam`. It presses the same controls a
            // thumb would, because a simulator has no thumb and this screen's
            // subject is what opening one reveals.
            .task {
                guard let raw = ProcessInfo.processInfo.environment["ORC_TRANSCRIPT"],
                      !raw.isEmpty else { return }
                // Let the first page land, so the seam presses controls that
                // exist rather than an empty list.
                for _ in 0..<40 where store.entries.isEmpty {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
                await store.applyDebugSeam(raw)
                if let failure = store.debugFirstFailure {
                    try? await Task.sleep(nanoseconds: 800_000_000)
                    for _ in 0..<4 {
                        proxy.scrollTo(failure, anchor: .top)
                        try? await Task.sleep(nanoseconds: 200_000_000)
                    }
                } else if TranscriptStore.debugWantsTop() {
                    // After `toBottom`'s last pass, so the two are not fighting
                    // over the same scroll view.
                    try? await Task.sleep(nanoseconds: 800_000_000)
                    for _ in 0..<4 {
                        proxy.scrollTo("top", anchor: .top)
                        try? await Task.sleep(nanoseconds: 200_000_000)
                    }
                } else {
                    await toBottom(proxy)
                }
            }
            #endif
            .overlay(alignment: .bottom) { pill }
        }
    }

    /// Put the newest entry on screen — **and mean it.**
    ///
    /// One `scrollTo` is not enough here and that is a property of `LazyVStack`,
    /// not a timing guess: rows below the viewport have never been laid out, so
    /// the scroll view is working from ESTIMATED heights and lands short of the
    /// true bottom by however much it mis-estimated. The rows it then
    /// materialises change the content size under the scroll it just finished.
    /// A screenshot of this screen opened five rows above its newest entry,
    /// which is exactly what "a view that compiles and is quietly wrong" looks
    /// like. Re-asking after each layout pass converges; the passes are cheap
    /// and a no-op once it has arrived.
    private func toBottom(_ proxy: ScrollViewProxy) async {
        for delay in [0, 120, 260, 500] {
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000)
            }
            proxy.scrollTo("bottom", anchor: .bottom)
        }
    }

    /// The top of the window: what is above it, or the fact that nothing is.
    @ViewBuilder
    private func topMarker(_ proxy: ScrollViewProxy) -> some View {
        if store.hasMoreBefore {
            HStack(spacing: Space.sm) {
                ProgressView().controlSize(.mini).tint(Palette.textDisabled)
                Text("loading older…")
                    .font(OrcFont.meta)
                    .foregroundStyle(Palette.textDisabled)
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, Space.sm)
            .onAppear {
                Task {
                    // **Hold the reading position across the prepend**, and
                    // "the bottom" is a reading position like any other.
                    // SwiftUI keeps the offset from the TOP, so a page landing
                    // above the reader slides the line they were on down the
                    // screen by a page's worth — which on the FIRST page (this
                    // marker is briefly on screen before the open-at-the-bottom
                    // scroll lands, so the second page is prefetched at once)
                    // left the screen opening halfway up its own transcript.
                    // A screenshot found that; nothing else would have.
                    let wasAtBottom = store.readerAtBottom
                    let anchor = store.visible.first?.id
                    await store.loadOlder()
                    if wasAtBottom {
                        await toBottom(proxy)
                    } else if let anchor {
                        proxy.scrollTo(anchor, anchor: .top)
                    }
                }
            }
        } else {
            Text("— start of transcript —")
                .font(OrcFont.meta)
                .foregroundStyle(Palette.textDisabled)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, Space.sm)
                .id("top")
        }
    }

    /// **The reader is never yanked.** New output while they are scrolled up
    /// into history is offered, not applied — this is the one interaction on
    /// this screen that is instantly noticeable when it is wrong.
    @ViewBuilder
    private var pill: some View {
        if store.unreadTail > 0 {
            Button {
                store.takeTail()
            } label: {
                Text(verbatim: store.unreadTailIsGap
                     ? "↓ new output"
                     : "↓ \(TranscriptRules.group(store.unreadTail)) new")
                    .font(OrcFont.status)
                    .foregroundStyle(Palette.canvas)
                    .padding(.horizontal, Space.md)
                    .padding(.vertical, Space.sm)
                    .background(Palette.statusFree)
                    .clipShape(Capsule())
            }
            .padding(.bottom, Space.md + accessoryHeight)
            .transition(.opacity)
        }
    }

    private func refusal(_ message: String) -> some View {
        VStack(spacing: Space.sm) {
            Image(systemName: "exclamationmark.bubble")
                .font(.system(size: 32))
                .foregroundStyle(Palette.statusNeeds)
            // Verbatim, always. `unknown account …`, `transcript not found`,
            // `bad sid` — the server's own words are the bug report.
            Text(message)
                .font(OrcFont.bodyCompact)
                .foregroundStyle(Palette.textSecondary)
                .multilineTextAlignment(.center)
            Text(verbatim: "\(target.account) · \(target.sid.prefix(8))")
                .font(OrcFont.meta)
                .foregroundStyle(Palette.textDisabled)
        }
        .padding(Space.xl)
        .frame(maxHeight: .infinity)
    }
}

/// One entry, one card.
///
/// A **3 pt left rail** carries the role colour in the app's existing language,
/// so the transcript reads like the board: `user` cyan (the human voice, as
/// everywhere), `assistant` sage (the agent working), `tool_use` amber (an
/// action, caution), `tool_result` hairline (output, not authored),
/// `system`/`meta` disabled (noise).
struct TranscriptRow: View {
    let entry: TranscriptEntry
    let open: Bool
    let text: String
    let cut: Bool
    let fetching: Bool
    let failure: String?
    let onToggle: () -> Void
    let onShowAll: () -> Void

    /// The line budget on an expanded tool block, lifted by a tap that says how
    /// many lines are behind it. See `TranscriptRules.expandedLineBudget` for
    /// why this is not a nested scroll view.
    @State private var lifted = false

    private var hue: Color {
        switch entry.role {
        case .user: Palette.statusFree
        case .assistant: Palette.statusWorking
        case .toolUse: Palette.statusLimit
        case .toolResult: Palette.hairline
        case .system, .unknown: Palette.textDisabled
        }
    }

    /// The rail is the identity of the row, so a `tool_result` gets a visible
    /// one rather than the 1.26:1 hairline the palette reserves for borders.
    private var railHue: Color {
        entry.role == .toolResult ? Palette.controlStrong : hue
    }

    private var glyph: String {
        switch entry.role {
        case .user: "person.fill"
        case .assistant: "cpu"
        case .toolUse: "wrench.adjustable"
        case .toolResult: "text.append"
        case .system, .unknown: "gearshape"
        }
    }

    private var title: String {
        entry.isTool ? (entry.tool?.display ?? "tool") : entry.role.label
    }

    var body: some View {
        HStack(alignment: .top, spacing: Space.md) {
            Rectangle()
                .fill(railHue)
                .frame(width: 3)
                .clipShape(Capsule())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Space.xs) {
                header
                bodyContent
                footer
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .opacity(entry.meta ? 0.72 : 1)
    }

    private var header: some View {
        HStack(spacing: Space.sm) {
            Image(systemName: glyph)
                .font(OrcFont.meta)
                .foregroundStyle(hue)
                .accessibilityHidden(true)
            Text(verbatim: title)
                .font(OrcFont.status)
                .foregroundStyle(hue)
            if entry.role == .toolResult, let ok = entry.tool?.ok {
                Image(systemName: ok ? "checkmark" : "xmark")
                    .font(OrcFont.meta)
                    .foregroundStyle(ok ? Palette.statusWorking : Palette.statusNeeds)
                    .accessibilityLabel(ok ? "succeeded" : "failed")
            }
            if let why = entry.why {
                Text(verbatim: why.label)
                    .font(OrcFont.meta)
                    .foregroundStyle(Palette.textDisabled)
                    .lineLimit(1)
            }
            Spacer(minLength: Space.xs)
            if let stamp = entry.timestamp {
                Text(RelativeTime.clock(stamp))
                    .font(OrcFont.meta)
                    .foregroundStyle(Palette.textDisabled)
            }
        }
    }

    @ViewBuilder
    private var bodyContent: some View {
        if TranscriptRules.collapsedByDefault(entry.role) {
            if open {
                Button(action: { onToggle(); lifted = false }) {
                    HStack(spacing: Space.xs) {
                        Image(systemName: "chevron.down")
                        Text(verbatim: TranscriptRules.sizeLabel(entry))
                    }
                    .font(OrcFont.meta)
                    .foregroundStyle(Palette.textTertiary)
                }
                .buttonStyle(.plain)
                block
            } else {
                foldLine
            }
        } else {
            // Prose, and it wraps. Mono, because this screen is the terminal's
            // own record and the face is the point of it — but wrapped, because
            // a paragraph is not column-aligned and a reader should not have to
            // scroll sideways through a sentence.
            Text(text)
                .font(OrcFont.code)
                .foregroundStyle(entry.meta ? Palette.textTertiary : Palette.textSecondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// `Read  search/index/shardmap.py · 4,708 ch  ›`
    private var foldLine: some View {
        Button(action: onToggle) {
            HStack(spacing: Space.sm) {
                let summary = TranscriptRules.toolSummary(entry)
                if !summary.isEmpty {
                    Text(verbatim: summary)
                        .font(OrcFont.codeSm)
                        .foregroundStyle(Palette.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Text(verbatim: "· " + TranscriptRules.sizeLabel(entry))
                    .font(OrcFont.meta)
                    .foregroundStyle(Palette.textDisabled)
                    .lineLimit(1)
                    .layoutPriority(1)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(OrcFont.meta)
                    .foregroundStyle(Palette.textDisabled)
            }
            .padding(.vertical, Space.xs)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("open \(title) output, \(TranscriptRules.sizeLabel(entry))")
    }

    /// **Does not wrap, and scrolls on its own axis.** Command output, diffs and
    /// code are column-aligned; wrapping them destroys the alignment that makes
    /// them readable at all. The container is horizontal-only on purpose — a
    /// bounded vertical scroll nested inside the page's vertical scroll captures
    /// the gesture on iOS and traps a thumb inside a code block, so length is
    /// handled by a line budget that the reader lifts instead.
    @ViewBuilder
    private var block: some View {
        let budget = lifted
            ? (text, 0)
            : TranscriptRules.budgeted(text)
        VStack(alignment: .leading, spacing: Space.xs) {
            ScrollView(.horizontal, showsIndicators: true) {
                Text(budget.0)
                    .font(OrcFont.codeSm)
                    .foregroundStyle(entry.tool?.ok == false
                                     ? Palette.statusNeeds
                                     : Palette.textSecondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: true)
                    .padding(Space.sm)
            }
            .background(Palette.sunken)
            .clipShape(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                .stroke(Palette.hairline, lineWidth: 1))
            if budget.1 > 0 {
                // An SF Symbol rather than `▾`: IBM Plex Mono has no geometric
                // shapes block, and `Font.custom` does not fail on a missing
                // glyph — it substitutes one from a face with different metrics,
                // silently, inside a mono row (`UX.md` §9.4).
                Button { lifted = true } label: {
                    HStack(spacing: Space.xs) {
                        Image(systemName: "chevron.down")
                        Text(verbatim: "\(TranscriptRules.group(budget.1)) more lines")
                    }
                    .font(OrcFont.meta)
                    .foregroundStyle(Palette.statusFree)
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// The truncation footer — **both numbers, and a button that fetches.**
    ///
    /// The chat drawer's `show full` only un-clamps a `lineLimit` on text the
    /// server already cut, so the missing characters stay missing. Here
    /// `truncated` is a real field, `chars` is the true length, and `show all`
    /// re-reads the line from `/messages/at/{off}?i=` uncapped.
    @ViewBuilder
    private var footer: some View {
        if let label = TranscriptRules.cutLabel(entry), cut {
            HStack(spacing: Space.sm) {
                Text(verbatim: "· " + label)
                    .font(OrcFont.meta)
                    .foregroundStyle(Palette.statusLimit)
                if fetching {
                    ProgressView().controlSize(.mini).tint(Palette.textTertiary)
                } else {
                    Button("show all", action: onShowAll)
                        .font(OrcFont.meta)
                        .foregroundStyle(Palette.statusFree)
                }
                Spacer(minLength: 0)
            }
        }
        if let failure {
            Text(verbatim: failure)
                .font(OrcFont.meta)
                .foregroundStyle(Palette.statusNeeds)
        }
    }
}
