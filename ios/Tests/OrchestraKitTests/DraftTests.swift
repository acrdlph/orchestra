import Foundation
import Testing
@testable import OrchestraKit

/// The mission draft, and the one property it exists for: **it survives the
/// biometric gate.**
///
/// The defect this suite pins was found on a real phone. Open the composer, type
/// a long mission, switch to another app, come back — the gate re-locks (correct,
/// by design) and `RootView` replaces the whole paired subtree with `LockView`,
/// which tears down the presented sheet and every `@State` in it. Nothing was
/// persisted, so the text was gone. The fix is not to weaken the lock; it is to
/// hold the draft somewhere the lock cannot reach and to write it down.
///
/// Everything below drives the real `DraftStore` against a throwaway
/// `UserDefaults` suite, so nothing touches the real domain.
@MainActor
struct DraftTests {

    static func defaults(_ name: String = UUID().uuidString) -> UserDefaults {
        UserDefaults(suiteName: name)!
    }

    /// Write a draft straight into a defaults suite, the way a previous launch
    /// would have left it. This is how the 24 h window is driven without a test
    /// that waits a day.
    static func seed(_ draft: MissionDraft, into defaults: UserDefaults) {
        defaults.set(try! JSONEncoder().encode(draft), forKey: DraftStore.storageKey)
    }

    // MARK: - persistence

    /// A draft round-trips: text, all four selections, and the open sheet.
    @Test func aDraftRoundTripsThroughPersistence() {
        let d = Self.defaults()
        let store = DraftStore(defaults: d)
        store.setMission("Clean up the CI matrix. Drop py3.11 from the test grid.")
        store.select(.worktree, "ConfidAI-ci")
        store.select(.account, "main")
        store.select(.model, "opus")
        store.select(.effort, "xhigh")
        store.setComposerOpen(true)
        store.flush()

        let reloaded = DraftStore(defaults: d)
        #expect(reloaded.mission == "Clean up the CI matrix. Drop py3.11 from the test grid.")
        #expect(reloaded.worktree == "ConfidAI-ci")
        #expect(reloaded.account == "main")
        #expect(reloaded.model == "opus")
        #expect(reloaded.effort == "xhigh")
        #expect(reloaded.isComposerOpen, "the sheet was up when we lost it")
    }

    /// The four picker choices survive on their own — a draft with no text but a
    /// model and an effort chosen is still a draft, and is still restored.
    @Test func selectionsSurviveWithoutText() {
        let d = Self.defaults()
        let store = DraftStore(defaults: d)
        store.select(.model, "fable")
        store.select(.effort, "ultracode")

        let reloaded = DraftStore(defaults: d)
        #expect(reloaded.model == "fable")
        #expect(reloaded.effort == "ultracode")
        #expect(reloaded.hasContent, "chosen selections are content")
    }

    /// Deselecting back to `Auto` is a real choice and is persisted as one.
    @Test func autoIsPersistedAsNil() {
        let d = Self.defaults()
        let store = DraftStore(defaults: d)
        store.select(.worktree, "ConfidAI2")
        store.select(.worktree, nil)

        #expect(DraftStore(defaults: d).worktree == nil)
    }

    // MARK: - the debounce

    /// **The debounce coalesces; it does not merely delay.** A long mission is a
    /// few thousand characters and every keystroke would otherwise encode and
    /// write the whole blob. Five edits in a row must cost ONE write, and the
    /// write must carry the LAST edit.
    @Test func theDebounceCoalescesWrites() {
        let d = Self.defaults()
        let store = DraftStore(defaults: d)
        for text in ["C", "Cl", "Cle", "Clea", "Clean"] { store.setMission(text) }

        #expect(store.writes == 0, "nothing has been written yet — the timer is still running")
        #expect(store.isSaving, "and the composer says so rather than claiming 'draft saved'")
        // Nothing on disk yet: a relaunch at this instant sees no draft.
        #expect(DraftStore(defaults: d).mission == "")

        store.flush()
        #expect(store.writes == 1, "five keystrokes, one write")
        #expect(store.isSaving == false)
        #expect(DraftStore(defaults: d).mission == "Clean")
    }

    /// And the timer really does fire on its own — the flush above is the
    /// background path, not the only path.
    @Test func aDebouncedWriteLandsWithoutAFlush() async throws {
        let d = Self.defaults()
        let store = DraftStore(defaults: d, debounce: .milliseconds(20))
        store.setMission("typed and then left alone")
        #expect(store.writes == 0)

        try await Task.sleep(for: .milliseconds(400))
        #expect(store.writes == 1)
        #expect(DraftStore(defaults: d).mission == "typed and then left alone")
    }

    /// Re-setting the same text is not an edit and does not schedule a write —
    /// SwiftUI hands the same value back more often than a keystroke happens.
    @Test func anUnchangedMissionIsNotAWrite() {
        let store = DraftStore(defaults: Self.defaults())
        store.setMission("same")
        store.flush()
        let after = store.writes
        store.setMission("same")
        #expect(store.isSaving == false)
        store.flush()
        #expect(store.writes == after + 1, "the flush itself writes; the no-op edit did not queue one")
    }

    // MARK: - what clears a draft, and what does not

    /// **A launch clears it.** The moment the server accepts a dispatch a job id
    /// exists and an agent is being started; this server has no idempotency key,
    /// so text that reappeared later would invite the double-fire nothing can
    /// refuse.
    @Test func aLaunchClearsTheDraft() {
        let d = Self.defaults()
        let store = DraftStore(defaults: d)
        store.setMission("ship the thing")
        store.select(.model, "opus")
        store.select(.effort, "max")
        store.setComposerOpen(true)

        store.clear()

        #expect(store.mission == "")
        #expect(store.model == nil)
        #expect(store.effort == nil)
        #expect(store.hasContent == false)
        // The sheet is deliberately left up: it is showing the dispatch's own
        // progress, and yanking it away would take the server's answer with it.
        #expect(store.isComposerOpen)
        // And it is gone from disk, not just from memory.
        let reloaded = DraftStore(defaults: d)
        #expect(reloaded.mission == "")
        #expect(reloaded.isComposerOpen == false, "an empty draft is never restored as an open sheet")
    }

    /// **Cancel keeps the text.** Losing a long mission to a mis-tapped Cancel is
    /// worse than a draft that outstays its welcome, so closing the composer is
    /// not discarding it — the next open brings it back.
    @Test func cancellingTheComposerKeepsTheText() {
        let d = Self.defaults()
        let store = DraftStore(defaults: d)
        store.setMission("a long mission worth keeping")
        store.setComposerOpen(true)

        store.setComposerOpen(false)          // Cancel, or a swipe down

        #expect(store.mission == "a long mission worth keeping")
        let reloaded = DraftStore(defaults: d)
        #expect(reloaded.mission == "a long mission worth keeping")
        #expect(reloaded.isComposerOpen == false, "kept, but not forced back up")
    }

    // MARK: - "Back to the draft"

    /// **A launch that failed gives the mission back.**
    ///
    /// The draft goes the instant a job id exists, so by the time a run reaches
    /// `finished(ok: false)` the composer is empty — and "Back to the draft" used
    /// to land there, with the user's mission spent on a launch that did not
    /// work. The run carried its own copy of all five fields; this is it coming
    /// home.
    @Test func aFailedRunPutsTheDraftBack() {
        let d = Self.defaults()
        let store = DraftStore(defaults: d)
        store.setMission("ship the reindex")
        store.select(.model, "opus")
        store.select(.effort, "max")
        store.clear()                                   // the job id came back
        #expect(store.hasContent == false)

        let restored = store.restoreIfEmpty(mission: "ship the reindex",
                                            worktree: "search-index", account: nil,
                                            model: "opus", effort: "max")

        #expect(restored)
        #expect(store.mission == "ship the reindex")
        #expect(store.worktree == "search-index")
        #expect(store.account == nil, "Auto is a real choice and comes back as one")
        #expect(store.model == "opus")
        #expect(store.effort == "max")
        #expect(DraftStore(defaults: d).mission == "ship the reindex")
    }

    /// **And it never overwrites.** A refusal never cleared the draft in the
    /// first place (a refusal has no job), and a user who has already started
    /// typing the next mission outranks the record of the last one.
    @Test func aRestoreNeverOverwritesADraftThatIsStillThere() {
        let store = DraftStore(defaults: Self.defaults())
        store.setMission("something else, typed since")

        let restored = store.restoreIfEmpty(mission: "the old mission", worktree: nil,
                                            account: nil, model: "haiku", effort: "high")

        #expect(restored == false)
        #expect(store.mission == "something else, typed since")
        #expect(store.model == nil)
    }

    /// A draft with no text but a model chosen is content too, and is not
    /// overwritten either.
    @Test func aRestoreRespectsSelectionsAsContent() {
        let store = DraftStore(defaults: Self.defaults())
        store.select(.model, "sonnet")
        #expect(store.restoreIfEmpty(mission: "the old mission", worktree: nil,
                                     account: nil, model: "opus", effort: "max") == false)
        #expect(store.model == "sonnet")
    }

    // MARK: - the 24 h re-present window

    /// Backgrounded an hour ago: the composer comes back with its text. This is
    /// the reported defect, from the other side.
    @Test func theComposerRepresentsItselfWithinTheWindow() {
        let now = Date()
        let d = Self.defaults()
        Self.seed(MissionDraft(mission: "half a mission", model: "opus",
                               isComposerOpen: true, savedAt: now.addingTimeInterval(-3600),
                               backgroundedAt: now.addingTimeInterval(-3600)), into: d)

        let store = DraftStore(defaults: d, now: now)
        #expect(store.isComposerOpen)
        #expect(store.mission == "half a mission")
    }

    /// Just inside the window, and just outside it. The far side keeps the TEXT
    /// and loses the SHEET — a composer that rises unbidden two days later is not
    /// a rescue.
    @Test func bothSidesOfTheTwentyFourHourWindow() {
        let now = Date()
        let justInside = MissionDraft(mission: "still warm", isComposerOpen: true,
                                      savedAt: now,
                                      backgroundedAt: now.addingTimeInterval(-(24 * 3600) + 60))
        let justOutside = MissionDraft(mission: "cold", isComposerOpen: true,
                                       savedAt: now,
                                       backgroundedAt: now.addingTimeInterval(-(24 * 3600) - 60))
        #expect(justInside.shouldRepresentComposer(now: now))
        #expect(justOutside.shouldRepresentComposer(now: now) == false)

        let d = Self.defaults()
        Self.seed(justOutside, into: d)
        let store = DraftStore(defaults: d, now: now)
        #expect(store.isComposerOpen == false)
        #expect(store.mission == "cold", "the text is kept — the next open restores it")
        #expect(store.hasContent)
    }

    /// A draft written by an app that was killed while in the FOREGROUND has no
    /// `backgroundedAt`; the window is then measured from the write itself.
    @Test func aKillWithNoBackgroundFallsBackToTheWriteTime() {
        let now = Date()
        let killed = MissionDraft(mission: "killed mid-type", isComposerOpen: true,
                                  savedAt: now.addingTimeInterval(-120))
        #expect(killed.shouldRepresentComposer(now: now))

        let stale = MissionDraft(mission: "killed last week", isComposerOpen: true,
                                 savedAt: now.addingTimeInterval(-7 * 24 * 3600))
        #expect(stale.shouldRepresentComposer(now: now) == false)
    }

    /// A live app suspended for more than a day comes back to a closed composer.
    /// The in-memory flag survived the lock; the window is what expires it.
    @Test func aForegroundAfterTooLongClosesTheComposer() {
        let store = DraftStore(defaults: Self.defaults())
        store.setMission("typed yesterday")
        store.setComposerOpen(true)
        let wentAway = Date().addingTimeInterval(-(25 * 3600))
        store.flushForBackground(now: wentAway)

        store.foregrounded(now: wentAway.addingTimeInterval(3600))
        #expect(store.isComposerOpen, "an hour later it is still the same session")

        store.foregrounded(now: Date())
        #expect(store.isComposerOpen == false)
        #expect(store.mission == "typed yesterday")
    }

    /// **An empty draft is never restored as an open sheet** — in every shape of
    /// empty, including whitespace, which is not content.
    @Test func anEmptyDraftIsNotRestoredAsAnOpenSheet() {
        let now = Date()
        for mission in ["", "   ", "\n\n  \n"] {
            let empty = MissionDraft(mission: mission, isComposerOpen: true, savedAt: now)
            #expect(empty.isEmpty)
            #expect(empty.shouldRepresentComposer(now: now) == false)

            let d = Self.defaults()
            Self.seed(empty, into: d)
            #expect(DraftStore(defaults: d, now: now).isComposerOpen == false)
        }
    }

    /// A draft the user had already dismissed is not forced back up on the next
    /// launch either — it waits for the composer to be opened.
    @Test func aClosedComposerIsNotReopenedByARelaunch() {
        let now = Date()
        let d = Self.defaults()
        Self.seed(MissionDraft(mission: "saved for later", isComposerOpen: false,
                               savedAt: now), into: d)

        let store = DraftStore(defaults: d, now: now)
        #expect(store.isComposerOpen == false)
        #expect(store.mission == "saved for later")
    }

    /// Backgrounding writes immediately — a suspended app can be killed with no
    /// further callback, so a 500 ms debounce still in flight is a lost mission.
    @Test func backgroundingFlushesAndStampsTheClock() {
        let d = Self.defaults()
        let store = DraftStore(defaults: d)
        store.setMission("typed, then straight to another app")
        #expect(store.writes == 0)

        let when = Date()
        store.flushForBackground(now: when)

        #expect(store.writes == 1)
        #expect(store.backgroundedAt == when)
        #expect(DraftStore(defaults: d).mission == "typed, then straight to another app")
    }

    /// Nothing on disk is not a crash and not a draft.
    @Test func anEmptyDomainIsAnEmptyDraft() {
        let store = DraftStore(defaults: Self.defaults())
        #expect(store.mission == "")
        #expect(store.hasContent == false)
        #expect(store.isComposerOpen == false)
        #expect(DraftStore.Field.allCases.allSatisfy { store.value(for: $0) == nil })
    }

    /// Garbage in the domain is ignored rather than fatal — a draft is a
    /// convenience and must never be able to stop the app from launching.
    @Test func anUndecodableDraftIsIgnored() {
        let d = Self.defaults()
        d.set(Data([0xFF, 0x00, 0xFF]), forKey: DraftStore.storageKey)
        let store = DraftStore(defaults: d)
        #expect(store.mission == "")
        #expect(store.isComposerOpen == false)
    }
}

/// The CHAT draft, and the identical defect one screen along.
///
/// Reported the same way the mission one was: *"When I input chat into an agent
/// conversation … and then go out of the app … or I have to give permission to
/// Wispr to allow it to enter into that text field, the input that I had already
/// entered is lost."* Same cause exactly — `ChatView` held `@State private var
/// draft` and the biometric gate replaces the whole paired subtree on every
/// background, taking the pushed screen and everything on it. Same fix: the text
/// lives in `DraftStore`, keyed by session, and the lock cannot reach it.
///
/// What is different from the mission draft, and is pinned below: there is one
/// draft **per sid**, and the set of them is **bounded** at both ends.
@MainActor
struct ChatDraftTests {

    static func defaults(_ name: String = UUID().uuidString) -> UserDefaults {
        UserDefaults(suiteName: name)!
    }

    static let sid = "9c1f4a2e-7b30-4c58-9a11-2d6e83f0b415"
    static let otherSid = "27b8e5d3-04ac-4e19-8f77-b1c0a92d6e40"

    // MARK: - it survives

    /// **The reported defect, from the other side.** Typed, then the process
    /// goes away — which is strictly worse than the lock, since the lock only
    /// destroys the view — and the text is still there for the next reader.
    @Test func aChatDraftRoundTripsThroughPersistence() {
        let d = Self.defaults()
        let store = DraftStore(defaults: d)
        store.setChatDraft("hold off on the migration until the index rebuild lands",
                           for: Self.sid)
        store.flushChat()

        let reloaded = DraftStore(defaults: d)
        #expect(reloaded.chatDraft(for: Self.sid)
                == "hold off on the migration until the index rebuild lands")
    }

    /// **Two conversations never share a composer.** The key is the sid alone —
    /// a v4 UUID minted by the CLI, unique across accounts and worktrees — so
    /// the same session reached from the board and from the worktree screen is
    /// one draft, and two different sessions are two.
    @Test func twoSessionsDoNotCollide() {
        let d = Self.defaults()
        let store = DraftStore(defaults: d)
        store.setChatDraft("answer for the reindex agent", for: Self.sid)
        store.setChatDraft("answer for the flaky-test agent", for: Self.otherSid)
        store.flushChat()

        let reloaded = DraftStore(defaults: d)
        #expect(reloaded.chatDraft(for: Self.sid) == "answer for the reindex agent")
        #expect(reloaded.chatDraft(for: Self.otherSid) == "answer for the flaky-test agent")
        #expect(reloaded.chatDraft(for: "a-session-nobody-typed-into") == "")
    }

    /// An unknown session is an empty String and never a nil the composer has to
    /// think about.
    @Test func anUnknownSessionIsAnEmptyDraft() {
        #expect(DraftStore(defaults: Self.defaults()).chatDraft(for: Self.sid) == "")
    }

    // MARK: - the debounce and the flush

    /// Same debounce as the mission, proved the same way: five keystrokes, one
    /// write, and the write carries the last one.
    @Test func theChatDebounceCoalescesWrites() {
        let d = Self.defaults()
        // A debounce long enough that only the flush can have written — the
        // assertion is about coalescing, and it should not be able to lose a
        // race with the test machine.
        let store = DraftStore(defaults: d, debounce: .seconds(30))
        for text in ["r", "re", "res", "rest", "resta"] {
            store.setChatDraft(text, for: Self.sid)
        }
        #expect(store.chatWrites == 0, "the timer is still running")
        #expect(DraftStore(defaults: d).chatDraft(for: Self.sid) == "")

        store.flushChat()
        #expect(store.chatWrites == 1, "five keystrokes, one write")
        #expect(DraftStore(defaults: d).chatDraft(for: Self.sid) == "resta")
    }

    /// And the chat timer fires on its own — the flush is the background path,
    /// not the only path.
    @Test func aDebouncedChatWriteLandsWithoutAFlush() async throws {
        let d = Self.defaults()
        let store = DraftStore(defaults: d, debounce: .milliseconds(20))
        store.setChatDraft("typed and then left alone", for: Self.sid)
        #expect(store.chatWrites == 0)

        try await Task.sleep(for: .milliseconds(400))
        #expect(store.chatWrites == 1)
        #expect(DraftStore(defaults: d).chatDraft(for: Self.sid) == "typed and then left alone")
    }

    /// Backgrounding writes both composers at once — a suspended app can be
    /// killed with no further callback, and the chat draft is the one this
    /// defect was reported about.
    @Test func backgroundingFlushesTheChatDraftToo() {
        let d = Self.defaults()
        let store = DraftStore(defaults: d)
        store.setMission("a mission in progress")
        store.setChatDraft("a reply in progress", for: Self.sid)

        store.flushForBackground(now: Date())

        #expect(store.writes == 1)
        #expect(store.chatWrites == 1)
        let reloaded = DraftStore(defaults: d)
        #expect(reloaded.mission == "a mission in progress")
        #expect(reloaded.chatDraft(for: Self.sid) == "a reply in progress")
    }

    /// The mission composer calls `flush()` on every picker tap. That must not
    /// re-encode a chat blob nothing has touched.
    @Test func aMissionFlushDoesNotWriteAnUntouchedChatBlob() {
        let store = DraftStore(defaults: Self.defaults())
        store.setMission("something")
        store.flush()
        store.select(.model, "opus")
        #expect(store.writes >= 2)
        #expect(store.chatWrites == 0)
    }

    // MARK: - what clears a draft, and what does not

    /// **A message that left clears its draft.** `✓ typed` is `rc == 0` from a
    /// real tty, and `✓✓` is that plus a sighting in the transcript: at that
    /// point the conversation itself holds the text and the composer must not.
    @Test func aSentMessageClearsThatSessionsDraft() {
        let d = Self.defaults()
        let store = DraftStore(defaults: d)
        store.setChatDraft("continue with the incremental path", for: Self.sid)
        store.setChatDraft("untouched", for: Self.otherSid)

        // Exactly the rule `ChatView.send` applies to `ChatStore.send`'s answer.
        let outcome: Outgoing.State? = .typed("typed into Terminal (ttys008)")
        #expect(outcome?.didLeave == true)
        if outcome?.didLeave == true { store.clearChatDraft(for: Self.sid) }

        #expect(store.chatDraft(for: Self.sid) == "")
        #expect(store.chatDraft(for: Self.otherSid) == "untouched",
                "one send does not empty another conversation")
        // And gone from disk, not just from memory.
        #expect(DraftStore(defaults: d).chatDraft(for: Self.sid) == "")
    }

    /// **A refused send keeps it, and that is the whole point.** The server said
    /// no, nothing left the phone, and the composer is holding the only copy of
    /// what the user wrote. The outgoing bubble that also shows it dies with the
    /// screen the next time the gate re-locks; the draft is what survives.
    @Test func aRefusedSendDoesNotClearTheDraft() {
        let d = Self.defaults()
        let store = DraftStore(defaults: d)
        store.setChatDraft("this is the only copy", for: Self.sid)

        let outcome: Outgoing.State? = .refused("that session moved to another account")
        #expect(outcome?.didLeave == false)
        if outcome?.didLeave == true { store.clearChatDraft(for: Self.sid) }

        #expect(store.chatDraft(for: Self.sid) == "this is the only copy")
        store.flushChat()
        #expect(DraftStore(defaults: d).chatDraft(for: Self.sid) == "this is the only copy")
    }

    /// The full ladder. Only the two outcomes that PROVE the keystrokes were
    /// accepted clear anything; `ambiguous` and `lost` do not, because a
    /// duplicate is a nuisance and a deleted message is gone.
    @Test func onlyProvenDeliveryClearsADraft() {
        #expect(Outgoing.State.typed("sent via tmux").didLeave)
        #expect(Outgoing.State.inTranscript("sent via tmux").didLeave)
        #expect(Outgoing.State.refused("no terminal").didLeave == false)
        #expect(Outgoing.State.ambiguous("it may have half-landed").didLeave == false)
        #expect(Outgoing.State.lost("no answer").didLeave == false)
        #expect(Outgoing.State.sending.didLeave == false)
        // `ChatStore.send` answers nil when it refuses to send at all — an empty
        // message, or one already in flight. Nothing left, so nothing clears.
        let refusedOutright: Outgoing.State? = nil
        #expect((refusedOutright?.didLeave ?? false) == false)
    }

    /// Emptying the field is not a draft. It removes the entry outright rather
    /// than leaving an empty tombstone under the sid forever.
    @Test func anEmptiedComposerRemovesItsEntry() {
        let store = DraftStore(defaults: Self.defaults())
        store.setChatDraft("half a thought", for: Self.sid)
        #expect(store.chatDrafts.bySession[Self.sid] != nil)

        store.setChatDraft("", for: Self.sid)
        #expect(store.chatDrafts.bySession[Self.sid] == nil)
        #expect(store.chatDraft(for: Self.sid) == "")
    }

    /// Whitespace is not content, here as everywhere else in this store.
    @Test func whitespaceIsNotADraft() {
        let store = DraftStore(defaults: Self.defaults())
        store.setChatDraft("   \n ", for: Self.sid)
        #expect(store.chatDrafts.bySession.isEmpty)
    }

    // MARK: - the bounds

    /// **The cap, and which one it drops.** A fleet churns through sessions and
    /// `UserDefaults` is not a database, so at most `maxKept` drafts are kept and
    /// the one evicted is the least recently TOUCHED.
    @Test func theCapKeepsTheMostRecentlyTouched() {
        let now = Date()
        var drafts = ChatDrafts()
        for i in 0..<10 {
            drafts = drafts.setting("draft \(i)", for: "sid-\(i)",
                                    now: now.addingTimeInterval(TimeInterval(i)), max: 3)
        }
        #expect(drafts.bySession.count == 3)
        #expect(drafts.text(for: "sid-9") == "draft 9")
        #expect(drafts.text(for: "sid-8") == "draft 8")
        #expect(drafts.text(for: "sid-7") == "draft 7")
        #expect(drafts.text(for: "sid-6") == "", "the oldest touch is the one that goes")
    }

    /// Touching an old draft saves it: LRU is by last write, not by first.
    @Test func typingIntoAnOldDraftSavesItFromEviction() {
        let now = Date()
        var drafts = ChatDrafts()
        drafts = drafts.setting("oldest", for: "a", now: now, max: 2)
        drafts = drafts.setting("middle", for: "b", now: now.addingTimeInterval(10), max: 2)
        // Back to `a` — now the most recent — then a third session arrives.
        drafts = drafts.setting("oldest, edited", for: "a",
                                now: now.addingTimeInterval(20), max: 2)
        drafts = drafts.setting("newest", for: "c", now: now.addingTimeInterval(30), max: 2)

        #expect(drafts.text(for: "a") == "oldest, edited")
        #expect(drafts.text(for: "c") == "newest")
        #expect(drafts.text(for: "b") == "", "untouched the longest")
    }

    /// **The age window.** A week, measured from the last keystroke: long enough
    /// that "I typed it, got pulled away, came back tomorrow" always works, short
    /// enough that a phone is not still holding a reply to an agent that finished
    /// last month. Both sides of the boundary.
    @Test func bothSidesOfTheRetentionWindow() {
        let now = Date()
        let lifetime = ChatDrafts.lifetime
        let drafts = ChatDrafts(bySession: [
            "fresh": ChatDraft(text: "yesterday", savedAt: now.addingTimeInterval(-86_400)),
            "justInside": ChatDraft(text: "just inside",
                                    savedAt: now.addingTimeInterval(-lifetime + 60)),
            "justOutside": ChatDraft(text: "just outside",
                                     savedAt: now.addingTimeInterval(-lifetime - 60)),
        ])

        let kept = drafts.pruned(now: now)
        #expect(kept.text(for: "fresh") == "yesterday")
        #expect(kept.text(for: "justInside") == "just inside")
        #expect(kept.text(for: "justOutside") == "")
    }

    /// The bounds are applied when the store LOADS, so a phone that was off for a
    /// fortnight comes back holding nothing rather than holding everything.
    @Test func staleDraftsAreDroppedOnLoad() {
        let d = Self.defaults()
        let now = Date()
        let stale = ChatDrafts(bySession: [
            Self.sid: ChatDraft(text: "typed a month ago",
                                savedAt: now.addingTimeInterval(-30 * 86_400)),
            Self.otherSid: ChatDraft(text: "typed this morning",
                                     savedAt: now.addingTimeInterval(-3600)),
        ])
        d.set(try! JSONEncoder().encode(stale), forKey: DraftStore.chatStorageKey)

        let store = DraftStore(defaults: d, now: now)
        #expect(store.chatDraft(for: Self.sid) == "")
        #expect(store.chatDraft(for: Self.otherSid) == "typed this morning")

        // And the clean-up is written down — lazily, on the next flush, because a
        // launch is not a reason to touch the disk.
        store.flushChat()
        #expect(DraftStore(defaults: d, now: now).chatDrafts.bySession.count == 1)
    }

    /// The cap holds through the store as well as through the value type.
    @Test func theStoreCannotGrowPastTheCap() {
        let store = DraftStore(defaults: Self.defaults())
        for i in 0...(ChatDrafts.maxKept + 5) {
            store.setChatDraft("draft \(i)", for: "sid-\(i)",
                               now: Date().addingTimeInterval(TimeInterval(i)))
        }
        #expect(store.chatDrafts.bySession.count == ChatDrafts.maxKept)
        #expect(store.chatDraft(for: "sid-0") == "", "the first typed is the first dropped")
        #expect(store.chatDraft(for: "sid-\(ChatDrafts.maxKept + 5)")
                == "draft \(ChatDrafts.maxKept + 5)")
    }

    /// Garbage in the domain is ignored rather than fatal, here too.
    @Test func anUndecodableChatBlobIsIgnored() {
        let d = Self.defaults()
        d.set(Data([0xFF, 0x00, 0xFF]), forKey: DraftStore.chatStorageKey)
        let store = DraftStore(defaults: d)
        #expect(store.chatDrafts.bySession.isEmpty)
        #expect(store.chatDraft(for: Self.sid) == "")
    }
}
