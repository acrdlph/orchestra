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
