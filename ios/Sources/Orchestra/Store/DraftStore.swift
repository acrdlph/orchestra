import Foundation
import Observation

/// One mission draft, as it is written to disk.
///
/// A value type with no I/O and no clock: the two rules that decide whether a
/// composer comes back — *is there anything in it* and *was it put down recently
/// enough* — are pure functions over this struct, so both can be driven from a
/// test with three literals and no waiting.
public struct MissionDraft: Codable, Sendable, Equatable {
    /// How long after backgrounding the composer will still re-present itself.
    /// Past this the text is kept and the sheet is not. It lives on the value
    /// type, not on the store, so the rule below stays callable from anywhere.
    public static let representWindow: TimeInterval = 24 * 60 * 60

    public var mission: String
    public var worktree: String?
    public var account: String?
    public var model: String?
    public var effort: String?
    /// Whether the composer sheet was up. Persisted because the sheet's
    /// `isPresented` binding is the one piece of composer state that must
    /// **outlive the view**: the biometric gate swaps the whole paired subtree
    /// for `LockView` on every background, and that tears down every `@State`
    /// inside the presented sheet along with the sheet itself.
    public var isComposerOpen: Bool
    /// When this draft was last written.
    public var savedAt: Date
    /// When the app last went to the **background** holding this draft. The
    /// re-present window is measured from here, not from `savedAt`, because
    /// "how long ago did you put the phone down" is the question being asked.
    public var backgroundedAt: Date?

    public init(mission: String = "", worktree: String? = nil, account: String? = nil,
                model: String? = nil, effort: String? = nil,
                isComposerOpen: Bool = false, savedAt: Date = .distantPast,
                backgroundedAt: Date? = nil) {
        self.mission = mission
        self.worktree = worktree
        self.account = account
        self.model = model
        self.effort = effort
        self.isComposerOpen = isComposerOpen
        self.savedAt = savedAt
        self.backgroundedAt = backgroundedAt
    }

    /// Nothing worth restoring. Whitespace is not content — a composer holding
    /// three newlines is empty.
    public var isEmpty: Bool {
        mission.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && worktree == nil && account == nil && model == nil && effort == nil
    }

    /// Should a **relaunch** put this composer back on screen?
    ///
    /// Three conditions, and each one is a decision rather than a detail:
    ///
    /// 1. the sheet was open when we lost it — a draft the user had already
    ///    dismissed is restored the next time they open the composer, not forced
    ///    in front of them;
    /// 2. there is something in it — an empty composer is not worth re-presenting
    ///    and would read as a bug;
    /// 3. it was put down less than `window` ago. Beyond that the TEXT is still
    ///    kept (the next open restores it), but a sheet that rises unbidden days
    ///    later is not a rescue, it is a haunting.
    public func shouldRepresentComposer(now: Date,
                                        window: TimeInterval = MissionDraft.representWindow) -> Bool {
        guard isComposerOpen, !isEmpty else { return false }
        return now.timeIntervalSince(backgroundedAt ?? savedAt) < window
    }
}

/// The mission draft, persisted — `UX.md` §3.5's *"draft persists on a 500 ms
/// debounce; survives app kill and failed launch"*, which was listed as an open
/// item in `ios/README.md` and in `docs/mobile/PRODUCTION-READINESS.md` until now.
///
/// **Why this exists at all.** The composer held `@State private var mission`.
/// The biometric gate (`RootView`) shows `LockView` *in place of* the whole
/// paired subtree the moment the app leaves the foreground, so switching to
/// another app — to start dictation software, say — and coming back destroyed
/// the presented sheet and every `@State` in it. The user unlocked and their
/// mission was gone. The gate is right and stays exactly as it is; what was
/// wrong is that the draft lived somewhere the gate could delete.
///
/// **Why `UserDefaults` and not an App Group.** §3.5 says "the App Group",
/// because it also describes a share extension that would need to see the same
/// draft. There is no App Group in this build and no second process — no share
/// extension, no widget, no notification-service extension — so a group would be
/// an entitlement bought for a reader that does not exist, and one this repo's
/// ad-hoc simulator signing would have to carry. `UserDefaults.standard` is the
/// same store `PushStore` already uses for its mirror. The day a share extension
/// lands, the change is this one initialiser's argument.
///
/// **Why debounced.** A long mission is a few thousand characters and every
/// keystroke would otherwise encode and write the whole blob. The in-memory copy
/// is updated synchronously — that is what the editor renders — and the write is
/// coalesced behind a 500 ms timer, then **flushed immediately on background** so
/// nothing is lost to a kill iOS never warns about.
@MainActor
@Observable
public final class DraftStore {

    /// Which of the four picker fields a value belongs to.
    public enum Field: String, Sendable, CaseIterable {
        case worktree, account, model, effort
    }

    /// The one key. A single JSON blob rather than six keys, so a draft can
    /// never be half-written: the read either finds a whole draft or none.
    public static let storageKey = "sh.orchestra.mission-draft"

    public private(set) var mission: String = ""
    public private(set) var worktree: String?
    public private(set) var account: String?
    public private(set) var model: String?
    public private(set) var effort: String?
    /// The sheet's `isPresented`, held here so the lock teardown cannot destroy
    /// it. Written through `setComposerOpen` — see `FleetView`.
    public private(set) var isComposerOpen = false
    public private(set) var backgroundedAt: Date?
    /// True between an edit and the debounced write landing. The composer shows
    /// `draft saved` only when this is false, because a label that says "saved"
    /// 400 ms before the write is a small lie this codebase does not tell.
    public private(set) var isSaving = false
    /// Writes actually made to `UserDefaults`. Diagnostic, and the thing a test
    /// asserts on to prove the debounce **coalesces** rather than merely delays.
    public private(set) var writes = 0

    private let defaults: UserDefaults
    private let debounce: Duration
    private var savedAt: Date
    private var pending: Task<Void, Never>?

    /// `now` is injected so the 24 h window can be driven in a test without a
    /// test that waits 24 hours.
    public init(defaults: UserDefaults = .standard,
                debounce: Duration = .milliseconds(500),
                now: Date = Date()) {
        self.defaults = defaults
        self.debounce = debounce
        let stored = Self.load(from: defaults) ?? MissionDraft()
        self.mission = stored.mission
        self.worktree = stored.worktree
        self.account = stored.account
        self.model = stored.model
        self.effort = stored.effort
        self.savedAt = stored.savedAt
        self.backgroundedAt = stored.backgroundedAt
        // The only place the restore rule is applied to a COLD launch. An
        // expired or empty draft keeps its text and loses its sheet.
        self.isComposerOpen = stored.shouldRepresentComposer(now: now)
    }

    // MARK: - reading

    /// The whole draft as one value — what gets written, and what a test reads.
    public var draft: MissionDraft {
        MissionDraft(mission: mission, worktree: worktree, account: account,
                     model: model, effort: effort, isComposerOpen: isComposerOpen,
                     savedAt: savedAt, backgroundedAt: backgroundedAt)
    }

    /// Is there anything here worth keeping? Drives the `discard draft`
    /// affordance, which is shown only when there is a draft to discard.
    public var hasContent: Bool { !draft.isEmpty }

    public func value(for field: Field) -> String? {
        switch field {
        case .worktree: worktree
        case .account: account
        case .model: model
        case .effort: effort
        }
    }

    // MARK: - writing

    /// The editor's every keystroke. In-memory synchronously; on disk in 500 ms.
    public func setMission(_ text: String) {
        guard text != mission else { return }
        mission = text
        scheduleSave()
    }

    /// One of the four pickers. Discrete and rare, so it is written at once
    /// rather than debounced — there is no keystroke storm to coalesce, and a
    /// choice is exactly the kind of thing a user expects to have stuck.
    public func select(_ field: Field, _ value: String?) {
        switch field {
        case .worktree: worktree = value
        case .account: account = value
        case .model: model = value
        case .effort: effort = value
        }
        flush()
    }

    /// The composer sheet opened or closed. **Closing keeps the text** — see
    /// `clear()` for the two places a draft actually goes away.
    public func setComposerOpen(_ open: Bool) {
        guard open != isComposerOpen else { return }
        isComposerOpen = open
        flush()
    }

    /// Forget the draft. Called from exactly two places:
    ///
    /// * **a dispatch the server accepted** — a job id came back, an agent is
    ///   being started, and text that reappeared afterwards would invite the
    ///   double-fire this server has no idempotency key to refuse;
    /// * **an explicit discard** — the affordance next to the character count.
    ///
    /// It deliberately does **not** close the composer: discarding empties the
    /// fields in place, and a launch leaves the sheet up showing its progress.
    public func clear() {
        mission = ""
        worktree = nil
        account = nil
        model = nil
        effort = nil
        flush()
    }

    // MARK: - lifecycle

    /// The app is going to the background. Write **now** — a suspended app can
    /// be killed with no further callback — and stamp the timestamp the
    /// re-present window is measured from.
    public func flushForBackground(now: Date = Date()) {
        backgroundedAt = now
        flush(at: now)
    }

    /// The app came back. The in-memory `isComposerOpen` survived (this store is
    /// owned by `AppModel`, which the lock does not touch), so the sheet
    /// re-presents itself as soon as the gate lets the subtree back. The only
    /// thing left to decide is whether it has been too long.
    public func foregrounded(now: Date = Date()) {
        guard isComposerOpen, let since = backgroundedAt else { return }
        if now.timeIntervalSince(since) >= MissionDraft.representWindow {
            setComposerOpen(false)
        }
    }

    // MARK: - persistence

    private func scheduleSave() {
        isSaving = true
        pending?.cancel()
        pending = Task { [weak self, debounce = self.debounce] in
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled else { return }
            self?.persist(at: Date())
        }
    }

    /// Write whatever is in hand, now, cancelling any pending debounce.
    public func flush(at now: Date = Date()) {
        pending?.cancel()
        pending = nil
        persist(at: now)
    }

    private func persist(at now: Date) {
        pending = nil
        isSaving = false
        savedAt = now
        writes += 1
        guard let data = try? JSONEncoder().encode(draft) else { return }
        // 0600-equivalent is not available for a defaults domain; nothing here
        // is a credential — it is the user's own prose and four picker choices.
        defaults.set(data, forKey: Self.storageKey)
    }

    private static func load(from defaults: UserDefaults) -> MissionDraft? {
        guard let data = defaults.data(forKey: storageKey) else { return nil }
        return try? JSONDecoder().decode(MissionDraft.self, from: data)
    }
}
