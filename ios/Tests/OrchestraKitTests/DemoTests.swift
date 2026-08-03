import Foundation
import Testing
@testable import OrchestraKit

/// The demo fleet — the App Store reviewer's entire experience of this product.
///
/// **This suite exists because the demo fails in exactly one place if it fails
/// at all: on a stranger's phone, during review, with nobody watching.** There is
/// no server behind it to notice, no log to read and no second chance. Everything
/// below is a literal in `Sources/Orchestra/Demo/`, which is precisely why it
/// must be decoded here rather than trusted: a comma dropped from a raw string
/// literal compiles.
///
/// It calls only public entry points and the same decode path the wire takes, so
/// it cannot pass by testing a stub.
struct DemoTests {

    // MARK: - It decodes, through the real decoder

    @Test func theSnapshotFrameDecodes() throws {
        let frame = try DemoFleet.frame(now: Date())
        #expect(frame.type == .snapshot)
        // A snapshot carries no `base` — the delta branch only. Getting this
        // wrong would make the applier treat it as a delta and gap forever.
        #expect(frame.base == nil)
        #expect(frame.order.count == 6)
        #expect(frame.cards.count == 6)
        #expect(frame.changedCards.count == 6, "no card in the demo is a removal")
        #expect(frame.removedCards.isEmpty)
        // Every name in `order` must have a card: `composed` skips the ones that
        // do not, and a typo would silently shrink the board.
        for name in frame.order {
            #expect(frame.changedCards[name] != nil, "order names \(name) with no card")
        }
        #expect(frame.freshness.oldest() != nil)
    }

    @Test func theWholeDemoWorldDecodes() throws {
        // The app calls `loadOrNil`, which swallows the error. This is the test
        // that makes that swallow safe.
        let payload = try DemoPayload.load(now: Date())
        #expect(payload.frame.order.count == 6)
        #expect(payload.limits.accounts.count == 3)
        #expect(payload.topology.groups.count == 1)
        #expect(payload.chats.count == 8)
        #expect(payload.side.hostname == DemoFleet.hostname)
        #expect(payload.side.resumes.count == 1)
        #expect(DemoPayload.loadOrNil() != nil)
    }

    // MARK: - Every status, and every section

    /// The board is a demonstration of triage, so every status the server can
    /// publish has to be on it — otherwise a reviewer sees three green rows and
    /// learns nothing about what the app is for.
    @Test func everySessionStatusIsRepresented() throws {
        let frame = try DemoFleet.frame(now: Date())
        let statuses = Set(frame.changedCards.values.flatMap { $0.sessions.map(\.status) })
        for status in [SessionStatus.working, .needsInput, .blocked,
                       .waiting, .limit, .ended] {
            #expect(statuses.contains(status), "no session is \(status.rawValue)")
        }
        // `.unknown` is the decode's widening case and must NOT appear: it would
        // mean a status string this build does not recognise, and the board
        // prints a warning line for it.
        #expect(!statuses.contains(.unknown))
    }

    @Test func everyBoardSectionIsRepresented() throws {
        let cards = try DemoFleet.frame(now: Date()).order
            .compactMap { try? DemoFleet.frame(now: Date()).changedCards[$0] }
            .compactMap { $0 }
        let sections = Set(cards.map { Triage.section(for: $0) })
        for section in BoardSection.allCases {
            #expect(sections.contains(section), "no card lands in \(section.title)")
        }
    }

    /// A free worktree exists so the headline's second line can name one —
    /// "N free" is what tells a reviewer the board answers "where can I start
    /// something", not only "who is stuck".
    @Test func theHeadlineNamesAFreeWorktree() throws {
        let cards = try boardCards()
        let headline = Triage.headline(cards)
        #expect(headline.text == "2 need you")
        #expect(headline.subhead.contains("1 free"))
        #expect(headline.tone == .needsYou)
        #expect(Triage.cardCounts(cards)[.free] == 1)
    }

    // MARK: - Ages are relative to NOW

    /// **The defect this whole clock exists to prevent**: a canned board with
    /// absolute epochs baked in reads `3d ago` on every row a week after
    /// shipping, and a board where nothing has happened for three days is not a
    /// demonstration of a live fleet.
    @Test func agesAreRewrittenRelativeToNow() throws {
        let now = Date(timeIntervalSince1970: 1_900_000_000)   // nowhere near `base`
        let cards = try boardCards(now: now)
        let sessions = cards.flatMap(\.sessions)
        #expect(!sessions.isEmpty)
        for session in sessions {
            let age = now.timeIntervalSince(session.lastWrite)
            #expect(age >= 0, "\(session.shortID) writes in the future")
            #expect(age < 2 * 24 * 3600,
                    "\(session.shortID) is \(age)s old — the epochs were not rewritten")
        }
        // Seconds to hours, spread — not eight rows all saying the same thing.
        let ages = sessions.map { now.timeIntervalSince($0.lastWrite) }
        #expect(ages.min()! < 30, "nothing on the board is fresh")
        #expect(ages.max()! > 3600, "nothing on the board is old")
    }

    @Test func theFrameAndItsProbesAreSecondsOld() throws {
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let frame = try DemoFleet.frame(now: now)
        #expect(now.timeIntervalSince1970 - frame.at < 60)
        let oldest = try #require(frame.freshness.oldest())
        #expect(now.timeIntervalSince1970 - oldest < 60)
    }

    /// The limit that resets in the future must still be in the future, and the
    /// armed auto-resume must still be after it — the two are the same story on
    /// two screens and a broken rewrite would put one of them in the past.
    @Test func futureInstantsStayInTheFuture() throws {
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let cards = try boardCards(now: now)
        let limited = try #require(cards.first { $0.name == DemoFleet.limitWorktree })
        let resets = try #require(limited.sessions.first?.limit?.resets)
        #expect(resets > now)
        #expect(resets.timeIntervalSince(now) < 3 * 3600)

        let side = try DemoFleet.side(now: now)
        let schedule = try #require(side.resumes.values.first)
        let due = try #require(schedule.due)
        #expect(due > resets, "the auto-resume must fire after the limit lifts")
    }

    /// The transcript is stamped with ISO-8601 strings rather than epochs, so it
    /// gets the same treatment or the chat screen sits at a 2027 wall clock
    /// while the row above it ticks.
    @Test func transcriptTimestampsMoveTooAndAgreeWithTheBoard() throws {
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let payload = try DemoPayload.load(now: now)
        let transcript = try #require(payload.chat(sid: DemoFleet.needsAnswerSid))
        let stamps = transcript.numbered.compactMap(\.timestamp)
        #expect(stamps.count == transcript.messages.count, "a turn lost its ts")
        for stamp in stamps {
            #expect(now.timeIntervalSince(stamp) >= 0)
            #expect(now.timeIntervalSince(stamp) < 2 * 24 * 3600)
        }
        // The session's own last write and the last turn of its conversation are
        // the same event on two screens.
        let cards = payload.frame.changedCards
        let session = try #require(cards[DemoFleet.needsAnswerWorktree]?
            .sessions.first { $0.sid == DemoFleet.needsAnswerSid })
        let lastTurn = try #require(stamps.last)
        #expect(abs(session.lastWrite.timeIntervalSince(lastTurn)) < 90)
    }

    // MARK: - The clock's rule itself

    @Test func onlyInBandNumbersMove() {
        let delta: Double = 1000
        // A pid, a cpu percentage, a dirty count, a version — none of them is a
        // timestamp and none may move.
        for untouched in [41822.0, 12.6, 11.0, 214.0, 0.0, -1.0] {
            let out = DemoClock.shift(NSNumber(value: untouched), by: delta) as? NSNumber
            #expect(out?.doubleValue == untouched)
        }
        let stamp = DemoClock.base - 47
        let moved = try? #require(DemoClock.shift(NSNumber(value: stamp), by: delta) as? NSNumber)
        #expect(moved?.doubleValue == stamp + delta)
    }

    /// A JSON `true` bridges to `NSNumber`. If the shift touched it, the payload
    /// would come back with `1` where `pid_certain` should be and the decoder
    /// would throw.
    @Test func booleansSurviveTheRewrite() throws {
        let json = #"{"a": true, "b": false, "ts": 1800000000, "pid": 41822}"#
        let out = try DemoClock.rewrite(json, now: Date(timeIntervalSince1970: 1_900_000_000))
        let object = try #require(try JSONSerialization.jsonObject(with: out) as? [String: Any])
        #expect(object["a"] as? Bool == true)
        #expect(object["b"] as? Bool == false)
        #expect(object["pid"] as? Int == 41822)
        let ts = try #require(object["ts"] as? Double)
        #expect(ts == 1_900_000_000)
    }

    /// `git.commit.ts` is an `Int` on the model side. A fractional double there
    /// is a `typeMismatch` that takes the whole board down, so every rewritten
    /// instant is whole seconds.
    @Test func rewrittenInstantsAreWholeSeconds() throws {
        let now = Date(timeIntervalSince1970: 1_900_000_000.734)
        let cards = try boardCards(now: now)
        for card in cards {
            guard let commit = card.git.commit else { continue }
            #expect(commit.ts > 0)
        }
        #expect(cards.compactMap { $0.git.commit }.count == 6)
    }

    @Test func outOfBandISOStringsAreLeftAlone() {
        #expect(DemoClock.shiftedISO("perf/incremental-reindex", by: 10) == nil)
        #expect(DemoClock.shiftedISO("2019-04-01T10:00:00.000Z", by: 10) == nil)
        #expect(DemoClock.shiftedISO("2027-01-15T08:00:00.000Z", by: 0) != nil)
    }

    // MARK: - The wire edges this payload deliberately carries

    /// `turn_ended` is ABSENT from some sessions on the real wire — 3 of 36 live
    /// — and a non-optional `Bool` there throws `keyNotFound` and takes the whole
    /// board with it. The demo carries the case so the demo exercises the fix.
    @Test func thePayloadCarriesTheWireEdgesThatBrokeThisClientBefore() throws {
        let cards = try boardCards()
        let sessions = cards.flatMap(\.sessions)
        #expect(sessions.contains { $0.turnEnded == nil },
                "no session omits turn_ended — the sharpest edge on this wire")
        #expect(cards.contains { !$0.git.hasUpstream },
                "no worktree has null ahead/behind — `↑0` is not the same fact")
        #expect(sessions.contains { $0.toolRunning },
                "tool_running is present only when true; carry one")
        #expect(sessions.contains { $0.hooked })
        #expect(sessions.contains { $0.statusObserved })
        #expect(sessions.contains { $0.busySignal != nil })
        #expect(sessions.contains { $0.topic == nil },
                "topic is nil on 5 of 36 live sessions")
    }

    // MARK: - It goes through the real applier and the real store

    @MainActor
    @Test func theDemoLoadsThroughTheApplierAndIsNotLive() throws {
        let store = FleetStore(client: OrchestraClient())
        let payload = try DemoPayload.load(now: Date())
        store.loadDemo(payload)

        // Composed by `FleetApplier`, not assembled by hand.
        let state = try #require(store.state)
        #expect(state.worktrees.count == 6)
        #expect(state.hostname == DemoFleet.hostname)
        #expect(state.user == DemoFleet.user)
        // `free_worktrees` is DERIVED by the applier from the cards. If this is
        // right, the frame really went through it.
        #expect(state.freeWorktrees == [DemoFleet.freeWorktree])
        #expect(state.resumes.count == 1)
        #expect(store.framesApplied == 1)
        #expect(store.version == 214)
        #expect(store.unknownStatuses == 0)
        #expect(store.groups.count == BoardSection.allCases.count)

        #expect(store.isDemo)
        #expect(store.link == .demo)
        #expect(!store.link.isLive, "a canned board must never claim to be live")
        #expect(store.link.isDemo)
        #expect(store.link.caption == DemoCopy.link)
    }

    /// A demo board must not dim. Every other non-live link state goes `.stale`
    /// once the board passes the silence budget — correct for a dead socket, and
    /// it would tell a reviewer the app is broken.
    @MainActor
    @Test func theDemoBoardNeverGoesStale() throws {
        let store = FleetStore(client: OrchestraClient())
        let now = Date()
        store.loadDemo(try DemoPayload.load(now: now))
        #expect(store.staleness(now: now) == .fresh)
        #expect(store.staleness(now: now.addingTimeInterval(600)) == .fresh)
        // The rule is the link state's, not a special case for one clock.
        #expect(!store.staleness(now: now.addingTimeInterval(86_400)).isStale)
    }

    @MainActor
    @Test func leavingTheDemoLeavesNothingBehind() throws {
        let store = FleetStore(client: OrchestraClient())
        store.loadDemo(try DemoPayload.load(now: Date()))
        store.exitDemo()
        #expect(!store.isDemo)
        #expect(store.demo == nil)
        #expect(store.state == nil)
        #expect(store.version == nil)
        #expect(store.link == .idle)
        #expect(store.framesApplied == 0)
        #expect(store.staleness(now: Date()) == .absent)
    }

    // MARK: - Read-only honesty

    @Test func theRefusalIsTheServersOwnKindOfSentence() {
        #expect(DemoCopy.refusal == "this is the demo fleet — pair your Mac to act")
        #expect(DemoCopy.link == "demo fleet · nothing here is real")
        // The App Store review notes and the screenshot job both name this
        // string exactly. It is not a label to reword.
        #expect(DemoCopy.entryPoint == "explore the demo fleet")
        // The refusal is the server's own kind of sentence: it opens lower-case,
        // it is one line, and it names the remedy rather than only the problem.
        #expect(DemoCopy.refusal.first?.isLowercase == true)
        #expect(DemoCopy.refusal.split(separator: "\n").count == 1)
        #expect(DemoCopy.refusal.contains("pair"))
        for line in [DemoCopy.refusal, DemoCopy.link, DemoCopy.banner,
                     DemoCopy.notConnected, DemoCopy.entryPointNote,
                     DemoCopy.entryPoint, DemoCopy.exit, DemoCopy.pairInstead] {
            #expect(!line.isEmpty)
            // No receipt marks anywhere in demo copy: `✓`/`✓✓` are earned by a
            // real server answering, and nothing here ever will.
            #expect(!line.contains("✓"))
        }
    }

    /// The composer stays on screen and the store still refuses. The disabled
    /// button is the courtesy; this is the guarantee.
    @MainActor
    @Test func sendingInTheDemoIsRefusedAndNothingIsFaked() async throws {
        let payload = try DemoPayload.load(now: Date())
        let chat = ChatStore(client: OrchestraClient(),
                             worktree: DemoFleet.needsAnswerWorktree,
                             account: DemoFleet.needsAnswerAccount,
                             sid: DemoFleet.needsAnswerSid,
                             demo: payload.chat(sid: DemoFleet.needsAnswerSid))
        #expect(chat.isDemo)
        await chat.load()
        #expect(chat.messages.count == 7)
        #expect(chat.serverError == nil)
        #expect(chat.transportError == nil)
        // The last turn is the agent's question — the whole reason this session
        // is the one a reviewer is pointed at.
        #expect(chat.messages.last?.isMine == false)
        #expect(chat.messages.last?.text.hasSuffix("?") == true)

        let outcome = await chat.send("ship it")
        #expect(outcome == .refused(DemoCopy.refusal))
        #expect(chat.outbox.count == 1)
        // Never `.typed`, never `.inTranscript` — a fake receipt here would undo
        // the one property the whole receipt design has.
        if case .refused(let why) = chat.outbox[0].state {
            #expect(why == DemoCopy.refusal)
        } else {
            Issue.record("a demo send produced \(chat.outbox[0].state)")
        }
        #expect(chat.messages.count == 7, "the transcript must not grow")
    }

    @MainActor
    @Test func everyMutationRefusesWithTheSameSentence() async throws {
        let actions = ActionsStore(client: OrchestraClient())
        actions.enterDemo()
        #expect(actions.isDemo)

        actions.launch(mission: "do the thing", worktree: "checkout-flow",
                       account: "main", model: "fable", effort: "high",
                       forceModel: false)
        let run = try #require(actions.dispatch)
        // `.refused` is the ONLY dispatch phase that means nothing was launched.
        if case .refused(let refusal) = run.phase {
            #expect(refusal.text == DemoCopy.refusal)
            #expect(!refusal.ok)
            #expect(!refusal.needsDecision, "this is not the reserve dialog")
        } else {
            Issue.record("a demo dispatch produced \(run.phase)")
        }

        actions.finish(worktree: "checkout-flow", step: .brief)
        let finish = try #require(actions.finishes["checkout-flow"])
        if case .settled(let reply) = finish.phase {
            #expect(!reply.ok)
            #expect(reply.message == DemoCopy.refusal)
        } else {
            Issue.record("a demo finish produced \(finish.phase)")
        }
        #expect(actions.briefsSentLocally.isEmpty,
                "a refused brief was never sent and must not be remembered")

        await actions.armResume(worktree: DemoFleet.limitWorktree, sid: DemoFleet.limitSid,
                                account: "spare", delayS: 60, resetsAt: nil, dueAt: nil)
        let armed = try #require(actions.notice(worktree: DemoFleet.limitWorktree,
                                                sid: DemoFleet.limitSid))
        #expect(!armed.ok)
        #expect(armed.text == DemoCopy.refusal)

        actions.clearNotice(worktree: DemoFleet.limitWorktree, sid: DemoFleet.limitSid)
        await actions.cancelResume(worktree: DemoFleet.limitWorktree, sid: DemoFleet.limitSid)
        #expect(actions.notice(worktree: DemoFleet.limitWorktree,
                               sid: DemoFleet.limitSid)?.ok == false)
    }

    @MainActor
    @Test func leavingClearsEveryRefusalTheDemoProduced() async throws {
        let actions = ActionsStore(client: OrchestraClient())
        actions.enterDemo()
        actions.launch(mission: "x", worktree: nil, account: nil,
                       model: "fable", effort: "high", forceModel: false)
        actions.finish(worktree: "checkout-flow", step: .brief)
        actions.exitDemo()
        #expect(!actions.isDemo)
        #expect(actions.dispatch == nil)
        #expect(actions.finishes.isEmpty)
        #expect(actions.resumeNotices.isEmpty)
    }

    // MARK: - Limits and chat, through their own decoders

    @Test func theLimitsReportDecodesAndIsHonestAboutGeneratedAt() throws {
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let report = try DemoLimits.report(now: now)
        #expect(report.available)
        #expect(report.error == nil)
        // `/api/limits.generated_at` is null in demo mode on the real server too
        // — the wire case `ios/README.md` finding 20 records. The screen says so
        // rather than printing orchestra's fetch clock as cclimits' stamp.
        #expect(report.generatedAt == nil)
        let fetched = try #require(report.fetched)
        #expect(now.timeIntervalSince(fetched) < 3600)

        #expect(report.ranked.first?.label == "main", "most headroom sorts first")
        let spare = try #require(report.accounts.first { $0.slug == "spare" })
        #expect(spare.accountExhausted)
        #expect(spare.reserveBlocked)
        // A model cap that is out blocks only that model — collapsing that is an
        // explicit anti-goal in the server, so the demo carries the case.
        let work = try #require(report.accounts.first { $0.slug == "work" })
        #expect(!work.accountExhausted)
        #expect(work.exhausted.contains { $0.modelScoped })
        // The slug and the label disagree on one account, which is the whole
        // reason `fb_label` exists.
        #expect(report.accounts.contains { $0.slug != $0.label })
    }

    /// The limited card and the exhausted account are the same fact on two
    /// screens, and they have to agree or the demo teaches a wrong join.
    @Test func theLimitedCardAndTheExhaustedAccountAgree() throws {
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let payload = try DemoPayload.load(now: now)
        let card = try #require(payload.frame.changedCards[DemoFleet.limitWorktree])
        let session = try #require(card.sessions.first)
        #expect(session.status == .limit)
        #expect(session.handedTo == nil, "a handed-off limit is not actionable")
        let account = try #require(payload.limits.accounts.first { $0.label == session.account })
        #expect(account.accountExhausted)
        let weekly = try #require(account.limits.first { $0.exhaustedNow && !$0.modelScoped })
        #expect(abs((weekly.resetsAt ?? 0) - (session.limit?.resetsAt ?? -1)) < 1,
                "the card and the limits screen must name the same reset")
    }

    @Test func everySessionOnTheBoardHasAConversation() throws {
        let payload = try DemoPayload.load(now: Date())
        let sids = payload.frame.changedCards.values.flatMap { $0.sessions.map(\.sid) }
        #expect(sids.count == 8)
        for sid in sids {
            let transcript = try #require(payload.chat(sid: sid),
                                          "no canned transcript for \(sid)")
            #expect(transcript.ok)
            #expect(!transcript.messages.isEmpty)
            // The server's own spelling. `user` would render every turn as
            // somebody else's.
            #expect(transcript.messages.allSatisfy { $0.role != .other })
        }
        // Positions are stamped at decode, not by the server — `numbered` is
        // what makes a `ForEach` stable.
        let numbered = try #require(payload.chat(sid: DemoFleet.blockedSid)).numbered
        #expect(numbered.map(\.index) == Array(0..<numbered.count))
    }

    @Test func theBranchMapDecodesAndPlacesEveryWorktree() throws {
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let payload = try DemoPayload.load(now: now)
        let group = try #require(payload.topology.groups.first)
        #expect(group.branches.count == 6)
        #expect(payload.topology.mappedWorktrees == Set(payload.frame.order))
        // The server clamps `fork_ts` to `min(fork_ts, tip_ts)` before it
        // serialises, so no fork may sit right of its own tip.
        for branch in group.branches {
            #expect(branch.forkTs <= branch.tipTs, "\(branch.worktree) forks after its tip")
            #expect(now.timeIntervalSince(branch.tip) < 2 * 24 * 3600)
        }
        #expect(now.timeIntervalSince(group.trunk) < 3600)
    }

    // MARK: - helpers

    private func boardCards(now: Date = Date()) throws -> [Worktree] {
        let frame = try DemoFleet.frame(now: now)
        return frame.order.compactMap { frame.changedCards[$0] }
    }
}

#if DEBUG
/// The `ORC_SCREEN=demo` seam. `DebugRoute` lives in `App/`, which the test
/// target cannot see — this pins the shape of the contract the seam has to keep,
/// so a change to the parser has one place that argues with it.
struct DemoSeamCopyTests {
    @Test func theSeamNameIsStable() {
        #expect(DemoCopy.exit == "leave the demo")
        #expect(DemoCopy.pairInstead.contains("pair"))
    }
}
#endif
