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
    /// The picker's chosen target — the qualified card key `<node>/<worktree>`
    /// since ADR 0016 (the picker's values are `free_worktrees` entries, and
    /// the key is what `/api/dispatch` takes). A draft persisted before the
    /// split holds a bare name, which the server still reads as "the board's
    /// own node" — the safe reading, so old drafts keep working.
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

/// One session's half-written reply, as it is written to disk.
///
/// `savedAt` is **last-touched**, not first-typed: it is the LRU key and the age
/// the retention window is measured from, so it moves on every keystroke that
/// changes the text.
public struct ChatDraft: Codable, Sendable, Equatable {
    public var text: String
    public var savedAt: Date

    public init(text: String, savedAt: Date) {
        self.text = text
        self.savedAt = savedAt
    }

    /// Whitespace is not content — a composer holding three spaces is empty, and
    /// an empty draft is not kept.
    public var isEmpty: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// Every kept chat draft, and the two rules that stop them accumulating.
///
/// **Keyed by `sid` alone.** A sid is the CLI session's own UUID — the fleet
/// payload carries it as `"sid": "9c1f4a2e-7b30-4c58-9a11-2d6e83f0b415"`,
/// `DebugRoute` parses it as "a UUID with dashes", and the branch that renders a
/// conversation is `FleetRoute.chat(worktree:account:sid:)`. Two accounts cannot
/// mint the same v4 UUID, so account and worktree add nothing to the key — and
/// leaving them out is what makes the *same* conversation share one draft whether
/// it was reached from the board or from the worktree screen, which is the
/// behaviour a user expects from one conversation. Actuation still addresses a
/// send by `(account, sid)` because the SERVER resolves a process that way
/// (ADR 0008); that is a different question from which text belongs to which
/// screen.
///
/// **Bounded twice**, because `UserDefaults` is not a database and a fleet churns
/// through sessions: at most `maxKept` drafts, LRU by last-touched, and nothing
/// older than `lifetime`. Everything here is a pure function over the value, so
/// both bounds are driven from a test with literals and no clock.
public struct ChatDrafts: Codable, Sendable, Equatable {
    /// How many sessions' drafts are kept at once. Twenty is comfortably more
    /// than the number of live sessions this fleet has ever shown at once (the
    /// board's own busiest day is single digits), so the cap is a backstop
    /// against unbounded growth rather than something a user can feel.
    public static let maxKept = 20
    /// How long an untouched draft is kept. A week: long enough that "I typed
    /// it, got pulled away, came back tomorrow" always works, short enough that
    /// a phone is not still holding a half-written reply to an agent that
    /// finished a month ago.
    public static let lifetime: TimeInterval = 7 * 24 * 60 * 60

    public var bySession: [String: ChatDraft]

    public init(bySession: [String: ChatDraft] = [:]) {
        self.bySession = bySession
    }

    public func text(for sid: String) -> String { bySession[sid]?.text ?? "" }

    /// Put text in, then re-apply both bounds. Empty text **removes** the entry:
    /// a sent message must not leave a tombstone behind, and an empty draft is
    /// not a draft.
    public func setting(_ text: String, for sid: String, now: Date,
                        max: Int = maxKept, lifetime: TimeInterval = lifetime) -> ChatDrafts {
        var copy = self
        let draft = ChatDraft(text: text, savedAt: now)
        if draft.isEmpty {
            copy.bySession.removeValue(forKey: sid)
        } else {
            copy.bySession[sid] = draft
        }
        return copy.pruned(now: now, max: max, lifetime: lifetime)
    }

    public func clearing(_ sid: String) -> ChatDrafts {
        var copy = self
        copy.bySession.removeValue(forKey: sid)
        return copy
    }

    /// Drop the empty, drop the stale, then keep the `max` most recently
    /// touched. Ties break on the key so the result is deterministic — a rule
    /// that evicts a different draft on every run is a rule nobody can test.
    public func pruned(now: Date, max: Int = maxKept,
                       lifetime: TimeInterval = lifetime) -> ChatDrafts {
        var kept = bySession.filter { _, draft in
            !draft.isEmpty && now.timeIntervalSince(draft.savedAt) < lifetime
        }
        guard kept.count > max else { return ChatDrafts(bySession: kept) }
        let doomed = kept
            .sorted { lhs, rhs in
                lhs.value.savedAt == rhs.value.savedAt
                    ? lhs.key > rhs.key
                    : lhs.value.savedAt > rhs.value.savedAt
            }
            .dropFirst(max)
            .map(\.key)
        for key in doomed { kept.removeValue(forKey: key) }
        return ChatDrafts(bySession: kept)
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
///
/// **It holds the chat composer's text too, and for exactly the same reason.**
/// `ChatView` is a pushed destination inside the gated subtree, so the lock takes
/// its `@State private var draft` the same way it took the mission — a user who
/// left the app to grant a dictation app permission came back to an empty field.
/// Same store, same debounce, same background flush; the only differences are
/// that chat drafts are keyed by `sid` (see `ChatDrafts`) and that there is no
/// re-present question to answer, because a pushed screen is where you left it.
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
    /// The chat drafts, also one blob — a key per session would leave a key per
    /// dead session behind, which is the unbounded growth `ChatDrafts` exists to
    /// prevent. One blob means eviction actually removes something.
    public static let chatStorageKey = "sh.orchestra.chat-drafts"

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
    /// The same count for the chat blob, kept separate so neither composer's
    /// debounce can be proved by the other one's traffic.
    public private(set) var chatWrites = 0

    private let defaults: UserDefaults
    private let debounce: Duration
    private var savedAt: Date
    private var pending: Task<Void, Never>?
    /// Every session's half-written reply. Pruned on load, and again on every
    /// edit, so the bound holds no matter which end it is pushed from.
    private var chats: ChatDrafts
    private var pendingChat: Task<Void, Never>?
    /// Whether the in-memory chat map differs from what is on disk. It gates the
    /// write so that `flush()` — which the mission composer calls on every picker
    /// choice — does not re-encode the chat blob for nothing.
    private var chatDirty = false

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
        // Chat drafts are pruned as they are read, so a phone that was off for a
        // fortnight comes back holding nothing rather than holding everything.
        // The clean-up is written down lazily — the next edit or flush carries
        // it — because a launch is not a reason to touch the disk.
        let storedChats = Self.loadChats(from: defaults) ?? ChatDrafts()
        self.chats = storedChats.pruned(now: now)
        self.chatDirty = self.chats != storedChats
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

    /// Every kept chat draft. Read by tests and by nothing else — a screen only
    /// ever wants its own session's text.
    public var chatDrafts: ChatDrafts { chats }

    /// This session's half-written reply, or `""`. Never nil: the composer wants
    /// a String and "no draft" and "an empty draft" are the same thing to it.
    public func chatDraft(for sid: String) -> String { chats.text(for: sid) }

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

    /// One session's composer, on every keystroke. Same shape as `setMission`:
    /// in memory now, on disk in 500 ms, on disk **immediately** if the app
    /// backgrounds first.
    public func setChatDraft(_ text: String, for sid: String, now: Date = Date()) {
        guard text != chats.text(for: sid) else { return }
        chats = chats.setting(text, for: sid, now: now)
        chatDirty = true
        scheduleChatSave()
    }

    /// **The message left the phone.** Called from exactly one place — the send
    /// path, and only on the outcome that proves the keystrokes were accepted
    /// (`Outgoing.State.didLeave`). A refusal, an ambiguous send and a lost one
    /// all keep the draft, because at that point the composer holds the only
    /// copy of what the user wrote.
    public func clearChatDraft(for sid: String) {
        guard chats.bySession[sid] != nil else { return }
        chats = chats.clearing(sid)
        chatDirty = true
        flushChat()
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

    /// Put a dispatch's own copy of the draft back, but **only into an empty
    /// composer**.
    ///
    /// `clear()` runs the moment a job id comes back, which is right — this
    /// server has no idempotency key and text that reappeared afterwards would
    /// invite a double-fire. The cost of it is that a run which started and then
    /// FAILED leaves "Back to the draft" pointing at an empty editor, with the
    /// mission lost to a launch that did not work. `ActionsStore.DispatchRun`
    /// kept every field the composer sent it, so that is what comes back.
    ///
    /// The guard is the whole rule: a draft the user has already started typing
    /// again outranks the record of the one before it, and a refusal (which never
    /// cleared anything, because a refusal has no job) is a no-op here.
    @discardableResult
    public func restoreIfEmpty(mission: String, worktree: String?, account: String?,
                               model: String?, effort: String?) -> Bool {
        guard !hasContent else { return false }
        self.mission = mission
        self.worktree = worktree
        self.account = account
        self.model = model
        self.effort = effort
        flush()
        return true
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

    private func scheduleChatSave() {
        pendingChat?.cancel()
        pendingChat = Task { [weak self, debounce = self.debounce] in
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled else { return }
            self?.persistChats()
        }
    }

    /// Write whatever is in hand, now, cancelling any pending debounce. Both
    /// composers: `flushForBackground` goes through here, and the app has one
    /// chance to write before iOS suspends it.
    public func flush(at now: Date = Date()) {
        pending?.cancel()
        pending = nil
        persist(at: now)
        flushChat()
    }

    /// The chat half on its own, for the two callers that only touched a chat
    /// draft and have no reason to re-encode the mission.
    public func flushChat() {
        pendingChat?.cancel()
        pendingChat = nil
        persistChats()
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

    /// Write the chat blob **only if it changed**. `flush()` is called on every
    /// picker choice in the mission composer; without this gate a user who never
    /// opened a chat would still pay an encode-and-write per tap.
    private func persistChats() {
        pendingChat = nil
        guard chatDirty else { return }
        chatDirty = false
        chatWrites += 1
        guard let data = try? JSONEncoder().encode(chats) else { return }
        defaults.set(data, forKey: Self.chatStorageKey)
    }

    private static func load(from defaults: UserDefaults) -> MissionDraft? {
        guard let data = defaults.data(forKey: storageKey) else { return nil }
        return try? JSONDecoder().decode(MissionDraft.self, from: data)
    }

    private static func loadChats(from defaults: UserDefaults) -> ChatDrafts? {
        guard let data = defaults.data(forKey: chatStorageKey) else { return nil }
        return try? JSONDecoder().decode(ChatDrafts.self, from: data)
    }
}
