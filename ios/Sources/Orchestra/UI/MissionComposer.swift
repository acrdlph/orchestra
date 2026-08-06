import SwiftUI

/// The mission composer — the one screen in this app that spends money.
///
/// Three properties it is built around, all of them the server's:
///
/// 1. **Model and effort have no default and the server refuses to guess one.**
///    `start_dispatch` answers *"pick a model and an effort first — routing is
///    deterministic, nothing is chosen for you"* to any dispatch missing either.
///    So Launch stays disabled until both are set, and the disabled reason is
///    shown inline rather than only as a dimmed button — the app never sends a
///    request it already knows will bounce.
/// 2. **Placement is the server's.** `_pick_defaults` picks the cleanest free
///    worktree and the account with the most headroom for the chosen model.
///    `Auto` here sends `nil` and lets it; this client deliberately does **not**
///    mirror the picker, because `exclude_accounts` is set on the author's machine
///    and is exposed by no endpoint, so a mirror would name an account the server
///    will never choose and every dispatch would show a "picked X" correction.
/// 3. **There is no idempotency key and no way to add one** — see `Actuation`. So
///    the Launch button in the confirmation disables on tap and never re-enables,
///    and a timeout is rendered as "did it launch?", never as "failed".
///
/// **Nothing the user typed lives in this view.** The mission text and the four
/// choices are held by `DraftStore`, not by `@State`, because the biometric gate
/// replaces the whole paired subtree with `LockView` on every background — and
/// that takes the presented sheet and every `@State` inside it. See `DraftStore`.
public struct MissionComposer: View {
    @Bindable private var fleet: FleetStore
    @Bindable private var limits: LimitsStore
    @Bindable private var actions: ActionsStore
    @Bindable private var drafts: DraftStore
    /// The image upload. From the environment rather than the initialiser
    /// because this sheet is presented from `FleetView`, which is not a
    /// composition root; optional so a preview without one degrades to a
    /// composer with no paperclip.
    @Environment(UploadStore.self) private var uploads: UploadStore?
    @Environment(\.dismiss) private var dismiss

    /// The editor's caret, so an uploaded path lands where the user was typing.
    /// `TextEditor(text:selection:)` is iOS 18, which is this app's floor.
    @State private var caret: TextSelection?

    /// The editor's focus, held so it can be **cleared before a picker is
    /// presented**. See `OptionPickerSheet` for what a live keyboard did to the
    /// menu this replaced.
    @FocusState private var editorFocused: Bool
    /// Which of the four rows has its picker up. `nil` is none.
    @State private var picking: PickerField?
    @State private var confirming = false
    @State private var discarding = false
    @State private var forcing: DispatchRefusal?

    /// The four the desktop offers, which are the four `claude --model` takes.
    static let models = ["fable", "opus", "sonnet", "haiku"]
    /// The desktop's own effort list, with its own descriptions.
    static let efforts: [(String, String)] = [
        ("high", "simple task"),
        ("xhigh", "research / medium"),
        ("max", "hard feature"),
        ("ultracode", "hard feature · long-running"),
    ]

    /// Nil in every shipping path — see `DebugRoute`. `ORC_SCREEN=mission:model`
    /// presents that row's picker on launch, because a sheet inside a sheet is
    /// the one thing `xcrun simctl` can neither tap nor reach any other way, and
    /// the defect these pickers replace is one only a screenshot can prove gone.
    private let initialPicker: PickerField?

    public init(fleet: FleetStore, limits: LimitsStore, actions: ActionsStore,
                drafts: DraftStore, initialPicker: PickerField? = nil) {
        self.fleet = fleet
        self.limits = limits
        self.actions = actions
        self.drafts = drafts
        self.initialPicker = initialPicker
    }

    private var run: ActionsStore.DispatchRun? {
        #if DEBUG
        return actions.dispatch ?? debugRun
        #else
        return actions.dispatch
        #endif
    }

    /// Cancel + Launch, or Close, or neither — decided by the phase and by
    /// nothing else. The rule itself is in `Rules/ComposerChrome.swift`, where a
    /// test can reach it.
    private var toolbar: ComposerToolbar { ComposerToolbar.forPhase(run?.phase) }

    // The draft, read and written through the store. There is deliberately no
    // local mirror: a second copy is a second thing the lock can delete.
    private var mission: String { drafts.mission }
    private var worktree: String? { drafts.worktree }   // nil == Auto
    private var account: String? { drafts.account }     // nil == Auto
    private var model: String? { drafts.model }         // no default, by design
    private var effort: String? { drafts.effort }       // no default, by design

    public var body: some View {
        NavigationStack {
            Group {
                if let run {
                    DispatchProgressView(run: run) {
                        actions.clearDispatch()
                        dismiss()
                    } reopenDraft: {
                        restoreDraft(from: run)
                        actions.clearDispatch()
                    }
                } else {
                    editor
                }
            }
            .background(Palette.canvas.ignoresSafeArea())
            .navigationTitle(run == nil ? "New mission" : "Launching")
            .navigationBarTitleDisplayMode(.inline)
            // **The toolbar is a function of the run, not a constant.** It used
            // to be neither: Cancel and Launch stayed up through the whole
            // dispatch, where Launch could never fire again and Cancel could not
            // do what its name says. See `ComposerToolbar`.
            .toolbar {
                if let title = toolbar.leadingTitle {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(title) { dismiss() }
                            .foregroundStyle(Palette.textSecondary)
                    }
                }
                if toolbar.showsLaunch {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Launch") { confirming = true }
                            .foregroundStyle(canLaunch ? Palette.statusNeeds : Palette.textDisabled)
                            .disabled(!canLaunch)
                    }
                }
            }
            .task {
                if limits.report == nil { await limits.load() }
                // Through the same call the row's tap makes — including the
                // focus clear — so the seam presses the button rather than
                // being a second way to present a picker.
                if let initialPicker { present(initialPicker) }
            }
        }
        // The draft goes away the moment the server ACCEPTS the dispatch — a job
        // id is back, an agent is being started, and this server has no
        // idempotency key, so text that reappeared later would invite exactly the
        // double-fire `Actuation` cannot refuse. A refusal (no job) keeps the
        // draft: "Back to the draft" has to have a draft to go back to.
        .onChange(of: actions.dispatch?.job) { _, job in
            if job != nil { drafts.clear() }
        }
        // One sheet for all four rows. `item:` rather than four booleans, so two
        // pickers cannot be up at once and the row decides its own contents.
        .sheet(item: $picking) { field in
            OptionPickerSheet(title: field.title,
                              options: options(for: field),
                              selection: drafts.value(for: field.draftField)) { value in
                drafts.select(field.draftField, value)
                picking = nil
            }
        }
        .confirmationDialog("Discard this draft?", isPresented: $discarding,
                            titleVisibility: .visible) {
            Button("Discard", role: .destructive) { drafts.clear() }
            Button("Keep it", role: .cancel) {}
        } message: {
            Text("The text and the four choices go. Cancel keeps them — the next "
                 + "time you open the composer they come back.")
        }
        .sheet(isPresented: $confirming) {
            LaunchConfirmSheet(mission: mission, worktree: worktree, account: account,
                               model: model ?? "", effort: effort ?? "",
                               accountLimits: chosenAccountLimits) {
                confirming = false
                actions.launch(mission: WireText.collapsed(mission),
                               worktree: worktree, account: account,
                               model: model ?? "", effort: effort ?? "",
                               forceModel: false)
            } cancel: {
                confirming = false
            }
        }
        .onChange(of: forcingCandidate) { _, refusal in
            forcing = refusal
        }
        .sheet(item: $forcing) { refusal in
            ForceModelSheet(refusal: refusal) {
                actions.clearDispatch()
                forcing = nil
                actions.launch(mission: WireText.collapsed(mission),
                               worktree: worktree, account: account,
                               model: model ?? "", effort: effort ?? "",
                               forceModel: true)
            } useOpus: {
                actions.clearDispatch()
                forcing = nil
                drafts.select(.model, "opus")
                actions.launch(mission: WireText.collapsed(mission),
                               worktree: worktree, account: refusal.opusAccount,
                               model: "opus", effort: effort ?? "", forceModel: false)
            } cancel: {
                actions.clearDispatch()
                forcing = nil
            }
        }
    }

    /// The headroom dialog, promoted out of the run into its own sheet — at a
    /// **different detent** from the launch confirm, so muscle memory drilled on
    /// "Launch" cannot land on "use it anyway" (`UX.md` §7.3 rule 3).
    private var forcingCandidate: DispatchRefusal? {
        guard let run, case .refused(let refusal) = run.phase,
              refusal.needsDecision else { return nil }
        return refusal
    }

    private var canLaunch: Bool {
        !fleet.isDemo && !WireText.collapsed(mission).isEmpty
            && model != nil && effort != nil && actions.dispatch == nil
    }

    private var disabledReason: String? {
        // First, because it outranks every other reason and is the only one the
        // user cannot fix from this screen.
        if fleet.isDemo { return DemoCopy.refusal }
        if actions.dispatch != nil { return "a mission is already launching" }
        if WireText.collapsed(mission).isEmpty { return "the mission is empty" }
        if model == nil && effort == nil { return "pick a model and an effort" }
        if model == nil { return "pick a model" }
        if effort == nil { return "pick an effort" }
        return nil
    }

    /// **"Back to the draft" has to land on a draft.** The run kept its own copy
    /// of everything this composer sent it, and an editor emptied by a launch
    /// that then failed gets it back. The rule — and its one guard — is
    /// `DraftStore.restoreIfEmpty`.
    private func restoreDraft(from run: ActionsStore.DispatchRun) {
        drafts.restoreIfEmpty(mission: run.mission, worktree: run.worktree,
                              account: run.account, model: run.model, effort: run.effort)
    }

    private var chosenAccountLimits: AccountLimits? {
        guard let account else { return nil }
        // Join on `fb_label`, NEVER on `slug` — they differ routinely
        // (`slug: "default"` is `fb_label: "main"` on this fleet).
        return limits.report?.accounts.first { $0.label == account }
    }

    // MARK: - Editor

    private var editor: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.md) {
                TextEditor(text: missionText, selection: $caret)
                    .font(OrcFont.body)
                    .foregroundStyle(Palette.textPrimary)
                    .scrollContentBackground(.hidden)
                    .focused($editorFocused)
                    .frame(minHeight: 180)
                    .padding(Space.sm)
                    .background(Palette.sunken)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                        .stroke(Palette.control, lineWidth: 1))
                    .overlay(alignment: .topLeading) {
                        if mission.isEmpty {
                            Text("what should the agent do?")
                                .font(OrcFont.body)
                                .foregroundStyle(Palette.textDisabled)
                                .padding(Space.md)
                                .allowsHitTesting(false)
                        }
                    }
                // The same two views the chat composer uses, in the layout this
                // screen has: the strip and the status under the editor, the
                // paperclip beside the draft line. One implementation, so the
                // demo refusal, the size precheck and the insert rule cannot
                // drift between the two screens.
                if let uploads {
                    AttachmentStrip(uploads: uploads, text: missionText)
                }
                HStack(spacing: Space.md) {
                    if let uploads {
                        AttachButton(uploads: uploads, isDemo: fleet.isDemo,
                                     text: missionText, selection: $caret)
                    }
                    draftLine
                }

                pickers
                if let disabledReason {
                    Text(verbatim: "Launch is off: " + disabledReason)
                        .font(OrcFont.meta)
                        .foregroundStyle(Palette.statusLimit)
                }
                Text("placement is deterministic — the server picks the cleanest free "
                     + "worktree and the account with the most headroom. Model and "
                     + "effort are your call; nothing guesses difficulty.")
                    .font(OrcFont.meta)
                    .foregroundStyle(Palette.textTertiary)
            }
            .padding(Space.lg)
        }
    }

    /// The editor writes through the store, never into a `@State` the lock can
    /// delete. In-memory on every keystroke; on disk 500 ms later.
    private var missionText: Binding<String> {
        Binding(get: { drafts.mission }, set: { drafts.setMission($0) })
    }

    /// `draft saved`, the character count, and the one explicit way to throw a
    /// draft away.
    ///
    /// **Cancel keeps the text; only this discards it.** Losing a long mission to
    /// a mis-tapped Cancel is worse than a draft that outstays its welcome, so
    /// the toolbar's Cancel closes and keeps, and getting rid of it is a
    /// deliberate two-tap act that only appears when there is something to lose.
    private var draftLine: some View {
        HStack(spacing: Space.md) {
            if drafts.hasContent {
                Button { discarding = true } label: {
                    HStack(spacing: Space.xs) {
                        Image(systemName: "trash")
                        Text("discard draft")
                    }
                    .font(OrcFont.meta)
                    .foregroundStyle(Palette.textTertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("discard draft")
            }
            Spacer(minLength: 0)
            // Only once the write has actually landed — the debounce is 500 ms
            // and a label that says "saved" before it is a small lie.
            if drafts.hasContent, !drafts.isSaving {
                Text("draft saved")
                    .font(OrcFont.meta)
                    .foregroundStyle(Palette.textTertiary)
            }
            Text(verbatim: "\(mission.count) ch")
                .font(OrcFont.meta)
                .foregroundStyle(Palette.textDisabled)
        }
    }

    @ViewBuilder
    private var pickers: some View {
        VStack(spacing: 0) {
            pickerRow(.worktree, value: worktree ?? "Auto")
            Divider().overlay(Palette.hairline)
            pickerRow(.account, value: account ?? "Auto")
            Divider().overlay(Palette.hairline)
            pickerRow(.model, value: model ?? "— pick one —", missing: model == nil)
            Divider().overlay(Palette.hairline)
            pickerRow(.effort, value: effort ?? "— pick one —", missing: effort == nil)
        }
        .background(Palette.surface)
        .clipShape(RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
            .stroke(Palette.hairline, lineWidth: 1))
    }

    /// What each row offers. `nil` is `Auto` and is always first where the server
    /// will place for us; model and effort have no auto and no default, which is
    /// the server's own refusal mirrored.
    private func options(for field: PickerField) -> [PickerOption] {
        switch field {
        case .worktree:
            // The free list is the server's own `free_worktrees`, which is a
            // pure function of the cards. It is not re-derived here.
            return [PickerOption(value: nil, title: "Auto — the server picks",
                                 note: "the cleanest free worktree")]
                + (fleet.state?.freeWorktrees ?? []).map {
                    PickerOption(value: $0, title: $0)
                }
        case .account:
            return [PickerOption(value: nil, title: "Auto — most headroom",
                                 note: "the account with the most left for this model")]
                + (limits.report?.ranked ?? []).map {
                    PickerOption(value: $0.label, title: accountLabel($0))
                }
        case .model:
            return Self.models.map { PickerOption(value: $0, title: $0) }
        case .effort:
            return Self.efforts.map { PickerOption(value: $0.0, title: $0.0, note: $0.1) }
        }
    }

    private func accountLabel(_ item: AccountLimits) -> String {
        var label = item.label
        if let headroom = item.headroomPercent {
            label += " · \(Int(headroom.rounded()))% left"
        }
        if item.accountExhausted { label += " · exhausted" }
        else if item.reserveBlocked { label += " · below reserve" }
        return label
    }

    /// **Clear focus, then present.** The dismissal is the courtesy half — the
    /// sheet below is the fix — and it is one function so the row and the
    /// `ORC_SCREEN=mission:<row>` seam cannot drift apart.
    private func present(_ field: PickerField) {
        editorFocused = false
        picking = field
    }

    /// The row itself is unchanged — title left, current value and chevron right.
    /// **Only the presentation changed**: this was a `Menu`, and a menu is laid
    /// out into the space left around its anchor. Squeeze that space (a tall
    /// third-party keyboard below, the nav bar above, a long mission pushing the
    /// row down) and the menu becomes a ~20 pt sliver. So the tap now clears
    /// focus — putting the keyboard away — and presents a sheet, which the window
    /// lays out and no anchor can shrink.
    private func pickerRow(_ field: PickerField, value: String,
                           missing: Bool = false) -> some View {
        Button {
            present(field)
        } label: {
            HStack {
                Text(field.title)
                    .font(OrcFont.bodyCompact)
                    .foregroundStyle(Palette.textSecondary)
                Spacer()
                Text(verbatim: value)
                    .font(OrcFont.meta)
                    .foregroundStyle(missing ? Palette.statusLimit : Palette.textPrimary)
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(OrcFont.meta)
                    .foregroundStyle(Palette.textTertiary)
            }
            .padding(.horizontal, Space.md)
            .frame(minHeight: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(field.title), \(value)")
        .accessibilityHint("Double tap to choose")
    }
}

#if DEBUG
extension MissionComposer {
    /// `ORC_DISPATCH=launching|running|finished|failed|refused|lost` renders the
    /// **Launching** screen for a run that does not exist.
    ///
    /// It is the same kind of seam as `ORC_SCREEN` and `ORC_MISSION`, with one
    /// honest difference worth stating: those press a button, and this one does
    /// not — there is no button to press. Reaching this screen for real means
    /// spending an account's usage and starting an agent on somebody's Mac, and
    /// the demo fleet cannot reach it either (`canLaunch` is false in demo, and
    /// `ActionsStore.launch` answers `.refused` there by design). So the phase is
    /// injected, and everything downstream of it — the title, the toolbar rule,
    /// the body, the copy — is the real code reading a real `DispatchRun`.
    ///
    /// `actions.dispatch` always wins, so a real launch is never shadowed.
    var debugRun: ActionsStore.DispatchRun? {
        guard let raw = ProcessInfo.processInfo.environment["ORC_DISPATCH"]?.lowercased(),
              !raw.isEmpty else { return nil }
        let phase: ActionsStore.DispatchRun.Phase
        switch raw {
        case "launching":
            phase = .launching
        case "running":
            phase = .running
        case "finished":
            phase = .finished(DispatchResult(
                ok: true, message: "started mission-searchindex-214849 in search-index",
                session: "mission-searchindex-214849", worktree: "search-index",
                account: "main", model: model ?? "opus", effort: effort ?? "max",
                effortConfirmed: true, kickoffSent: true,
                attach: "tmux -L fleet attach -t mission-searchindex-214849"))
        case "failed":
            phase = .finished(DispatchResult(
                ok: false, message: "the pane died before the brief was typed"))
        case "refused":
            phase = .refused(DispatchRefusal(
                message: "pick a model and an effort first — routing is "
                    + "deterministic, nothing is chosen for you"))
        case "lost":
            phase = .lost("no answer in 90 s — the mission may be running")
        default:
            return nil
        }
        let job: String? = raw == "launching" ? nil : "d-8f21c4"
        return ActionsStore.DispatchRun(
            key: "orc-dispatch-seam", job: job, phase: phase,
            progress: raw == "launching" ? [] : [
                "① reserving search-index",
                "② starting tmux session mission-searchindex-214849",
                "  claude --dangerously-skip-permissions",
                "③ waiting for the prompt",
            ],
            startedAt: Date().addingTimeInterval(-9),
            mission: mission, worktree: worktree, account: account,
            model: model ?? "opus", effort: effort ?? "max")
    }
}
#endif

/// Which of the composer's four rows a picker belongs to. `Identifiable` because
/// one `.sheet(item:)` serves all four — four booleans would be four ways to
/// present two pickers at once.
public enum PickerField: String, Identifiable, CaseIterable, Sendable {
    case worktree, account, model, effort

    public var id: String { rawValue }

    var title: String {
        switch self {
        case .worktree: "Worktree"
        case .account: "Account"
        case .model: "Model"
        case .effort: "Effort"
        }
    }

    var draftField: DraftStore.Field {
        switch self {
        case .worktree: .worktree
        case .account: .account
        case .model: .model
        case .effort: .effort
        }
    }
}

extension DispatchRefusal: Identifiable {
    public var id: String { (message ?? "") + (model ?? "") }
}

/// The launch confirmation. `.height(SheetHeight.launch)`, Cancel bottom-most,
/// 24 pt of dead space between the two.
struct LaunchConfirmSheet: View {
    let mission: String
    let worktree: String?
    let account: String?
    let model: String
    let effort: String
    let accountLimits: AccountLimits?
    let launch: () -> Void
    let cancel: () -> Void

    /// Disables on tap and does not re-enable — see `PrimaryAction`.
    @State private var fired = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.md) {
                SheetHeader("Launch this mission?", symbol: "bolt.horizontal",
                            hue: Palette.statusNeeds)
                VStack(alignment: .leading, spacing: Space.xs) {
                    ConsequenceRow(worktree ?? "Auto — the cleanest free worktree",
                                   arrow: "folder", hue: Palette.statusFree)
                    ConsequenceRow(account.map { "[\($0)]" } ?? "Auto — most headroom",
                                   detail: accountLimits?.headroomPercent
                                       .map { "\(Int($0.rounded()))% left" },
                                   arrow: "person.crop.circle", hue: Palette.statusFree)
                    ConsequenceRow("\(model) · effort \(effort)", arrow: "cpu",
                                   hue: Palette.textPrimary)
                }
                Text("Spends that account's usage. The agent runs with "
                     + "--dangerously-skip-permissions and can run commands, "
                     + "commit and push.")
                    .font(OrcFont.bodyCompact)
                    .foregroundStyle(Palette.textSecondary)
                // The honest disclosure this server forces: there is no
                // idempotency key, so there is no undo and no safe retry.
                Text("There is no double-fire guard on the server: a second launch "
                     + "in the same worktree starts a second agent. This button "
                     + "fires once and does not come back.")
                    .font(OrcFont.meta)
                    .foregroundStyle(Palette.statusLimit)
                Text(TextTruncation.clip(WireText.collapsed(mission), to: 220))
                    .font(OrcFont.codeSm)
                    .foregroundStyle(Palette.textTertiary)

                PrimaryAction("Launch mission", symbol: "bolt.fill",
                              tint: Palette.statusNeeds, enabled: !fired) {
                    fired = true
                    launch()
                }
                ConsequenceGap()
                CancelAction(action: cancel)
            }
            .padding(Space.lg)
        }
        .background(Palette.surface.ignoresSafeArea())
        .presentationDetents([.height(SheetHeight.launch), .large])
        .presentationDragIndicator(.visible)
    }
}

/// `needs_decision` — the reserve dialog, at its own detent.
///
/// The server's message names the number (*"best is [work] at 12% left, below its
/// 20% reserve"*), so it is shown verbatim and not paraphrased.
struct ForceModelSheet: View {
    let refusal: DispatchRefusal
    let force: () -> Void
    let useOpus: () -> Void
    let cancel: () -> Void

    @State private var fired = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.md) {
                SheetHeader("No headroom for that model", symbol: "gauge.with.dots.needle.0percent",
                            hue: Palette.statusLimit)
                ServerSays(refusal.text, tone: .refusal)
                if refusal.canOpus, let opusAccount = refusal.opusAccount {
                    PrimaryAction("Start with opus — [\(opusAccount)]"
                                  + (refusal.opusLeft.map { ", \(Int($0.rounded()))% left" } ?? ""),
                                  symbol: "play.fill",
                                  tint: Palette.statusWorking, enabled: !fired) {
                        fired = true
                        useOpus()
                    }
                } else {
                    Text(refusal.account.map { "[\($0)] has no opus headroom either." }
                         ?? "No account has opus headroom either.")
                        .font(OrcFont.bodyCompact)
                        .foregroundStyle(Palette.textTertiary)
                }
                ConsequenceGap()
                SecondaryAction("Use \(refusal.model ?? "it") anyway — into the reserve",
                                symbol: "flag.fill", tint: Palette.statusLimit,
                                enabled: !fired) {
                    fired = true
                    force()
                }
                CancelAction(action: cancel)
            }
            .padding(Space.lg)
        }
        .background(Palette.surface.ignoresSafeArea())
        // Deliberately NOT `SheetHeight.launch`: consecutive sheets in one chain
        // never share a detent, so a thumb aimed at "Launch mission" cannot land
        // on "use it anyway".
        .presentationDetents([.height(SheetHeight.forceModel), .large])
        .presentationDragIndicator(.visible)
    }
}

/// A dispatch in flight, and then whatever it became.
///
/// The progress lines are the server's `①②③④⑤`, **rendered verbatim**, with the
/// two-space-prefixed sub-lines indented as sub-lines. They come from
/// `GET /api/dispatch/status?job=…` on a 1.5 s poll — there is no intent frame on
/// this wire, so a poll is what there is.
struct DispatchProgressView: View {
    let run: ActionsStore.DispatchRun
    let done: () -> Void
    let reopenDraft: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.md) {
                header
                if !run.progress.isEmpty {
                    VStack(alignment: .leading, spacing: Space.xxs) {
                        ForEach(Array(run.progress.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(OrcFont.code)
                                .foregroundStyle(line.hasPrefix("  ") ? Palette.textTertiary
                                                                      : Palette.textSecondary)
                                .padding(.leading, line.hasPrefix("  ") ? Space.lg : 0)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(Space.md)
                    .background(Palette.sunken)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
                }
                body(for: run.phase)
            }
            .padding(Space.lg)
        }
    }

    @ViewBuilder
    private var header: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            ConsequenceRow("\(run.model) · effort \(run.effort)", arrow: "cpu",
                           hue: Palette.textPrimary)
            ConsequenceRow(run.worktree ?? "auto", arrow: "folder", hue: Palette.statusFree)
            if let job = run.job {
                ConsequenceRow(job, arrow: "number", hue: Palette.textTertiary)
            }
        }
    }

    /// What the toolbar's **Close** does not do, said once, where it is being
    /// read. The screen used to offer a button called Cancel here, which reads as
    /// "stop this" — and there is nothing on this phone that stops a mission:
    /// `/api/kill` does not exist, so the honest thing is to say so and name the
    /// one thing that does work.
    private var noStopping: some View {
        Text("Closing this doesn't stop the mission, and nothing on this phone "
             + "can — there is no kill switch on the server. Attach on the Mac.")
            .font(OrcFont.meta)
            .foregroundStyle(Palette.statusLimit)
    }

    @ViewBuilder
    private func body(for phase: ActionsStore.DispatchRun.Phase) -> some View {
        switch phase {
        case .launching:
            HonestProgress(since: run.startedAt, caption: "asking the server")
            noStopping
        case .running:
            HonestProgress(since: run.startedAt, caption: "launching")
            Text("Typically 10–20 s: a tmux session, then claude boots, then the "
                 + "effort command, then the brief.")
                .font(OrcFont.meta)
                .foregroundStyle(Palette.textTertiary)
            noStopping
        case .finished(let result):
            ServerSays(result.text, tone: result.ok ? .ok : .refusal)
            if result.ok {
                if result.effortConfirmed == false {
                    // Tri-state on purpose: nil means no effort was asked for.
                    ServerSays("the effort command was not confirmed in the pane — "
                               + "attach and check before trusting it",
                               tone: .unknown)
                }
                if result.kickoffSent == false {
                    ServerSays("the kickoff brief was not confirmed — attach and "
                               + "press Enter", tone: .unknown)
                }
                if let attach = result.attach {
                    VStack(alignment: .leading, spacing: Space.xxs) {
                        Text("attach")
                            .font(OrcFont.label)
                            .orcTracking(11)
                            .foregroundStyle(Palette.textTertiary)
                        Text(attach)
                            .font(OrcFont.codeSm)
                            .foregroundStyle(Palette.statusFree)
                            .textSelection(.enabled)
                    }
                }
                Text("It appears on the board in about 30 seconds.")
                    .font(OrcFont.meta)
                    .foregroundStyle(Palette.textTertiary)
            }
            ConsequenceGap()
            PrimaryAction(result.ok ? "Done" : "Back to the draft",
                          tint: result.ok ? Palette.statusWorking : Palette.statusFree) {
                result.ok ? done() : reopenDraft()
            }
        case .refused(let refusal):
            // A clean refusal: nothing launched, so a second attempt is safe and
            // is the user's to make. This is the ONLY phase that says so.
            ServerSays(refusal.text, tone: .refusal)
            ConsequenceGap()
            PrimaryAction("Back to the draft", tint: Palette.statusFree) { reopenDraft() }
        case .lost(let why):
            // Never "failed", and never a retry button. `UX.md` §7.4 — rendering
            // a timeout as failure is the most dangerous message available here,
            // because the agent was very likely launched.
            SheetHeader("Did it launch?", symbol: "questionmark.diamond",
                        hue: Palette.statusLimit)
            ServerSays(why, tone: .unknown)
            ConsequenceGap()
            PrimaryAction("Done", tint: Palette.textTertiary) { done() }
        }
    }
}
