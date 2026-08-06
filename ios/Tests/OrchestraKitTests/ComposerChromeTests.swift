import Foundation
import Testing
@testable import OrchestraKit

/// The mission composer's toolbar, as a rule rather than as a screenshot.
///
/// Reported from a phone: *"there's a cancel and launch header button on the
/// launching screen. When the agent is already launching … it's definitely too
/// late to launch."* The toolbar was attached to the outer `Group`, so both
/// buttons rode through the whole dispatch: **Launch** rendered permanently
/// disabled (`canLaunch` is false while `dispatch != nil`) and **Cancel** called
/// `dismiss()` and nothing else — on a screen titled "Launching", next to a
/// mission that no button on this phone can stop.
struct ComposerChromeTests {

    static let refusal = DispatchRefusal(message: "pick a model and an effort first")
    static let result = DispatchResult(ok: true, message: "started mission-x")

    /// Still editing: exactly what it always was.
    @Test func withNoRunTheToolbarIsUnchanged() {
        let chrome = ComposerToolbar.forPhase(nil)
        #expect(chrome == .editing)
        #expect(chrome.leadingTitle == "Cancel")
        #expect(chrome.showsLaunch)
    }

    /// In flight: one neutral way off the screen, and **no Launch at all**. Not
    /// disabled — gone. A control that can never fire is not a control.
    @Test func aRunInFlightDropsLaunchAndRenamesCancel() {
        for phase in [ActionsStore.DispatchRun.Phase.launching, .running] {
            let chrome = ComposerToolbar.forPhase(phase)
            #expect(chrome == .closeOnly)
            #expect(chrome.showsLaunch == false)
            #expect(chrome.leadingTitle == "Close")
        }
    }

    /// Settled: the body already carries exactly one action per terminal phase
    /// ("Done", or "Back to the draft"), so the toolbar carries none. Two buttons
    /// that both leave — one of which also clears the run — is a choice with no
    /// meaning. Nobody is trapped: the sheet still dismisses interactively and
    /// every terminal phase has its own action in the body.
    @Test func aSettledRunLeavesTheDecisionToTheBody() {
        let terminal: [ActionsStore.DispatchRun.Phase] = [
            .finished(Self.result),
            .finished(DispatchResult(ok: false, message: "the pane died")),
            .refused(Self.refusal),
            .lost("no answer in 90 s"),
        ]
        for phase in terminal {
            let chrome = ComposerToolbar.forPhase(phase)
            #expect(chrome == ComposerToolbar.none)
            #expect(chrome.leadingTitle == nil)
            #expect(chrome.showsLaunch == false)
        }
    }

    /// **The two invariants, over every phase there is.** Once a run exists:
    /// Launch is never on screen, and the leading button is never called
    /// "Cancel" — because it cancels nothing, and there is no endpoint on this
    /// server that could (`/api/kill` does not exist).
    @Test func onceARunExistsNothingSaysCancelAndNothingSaysLaunch() {
        let every: [ActionsStore.DispatchRun.Phase] = [
            .launching, .running, .finished(Self.result), .refused(Self.refusal),
            .lost("no answer"),
        ]
        for phase in every {
            let chrome = ComposerToolbar.forPhase(phase)
            #expect(chrome.showsLaunch == false, "\(phase) still offered Launch")
            #expect(chrome.leadingTitle != "Cancel", "\(phase) still said Cancel")
        }
    }

    /// The rule reads the phase and nothing else, which is what lets it be
    /// checked here at all — `isTerminal` is the same partition seen from the
    /// store's side, and the two must not drift.
    @Test func theRuleAgreesWithTheStoresOwnIdeaOfTerminal() {
        let run = { (phase: ActionsStore.DispatchRun.Phase) in
            ActionsStore.DispatchRun(key: "k", job: nil, phase: phase, startedAt: Date(),
                                     mission: "m", worktree: nil, account: nil,
                                     model: "opus", effort: "max")
        }
        let phases: [ActionsStore.DispatchRun.Phase] = [
            .launching, .running, .finished(Self.result), .refused(Self.refusal),
            .lost("no answer"),
        ]
        for phase in phases {
            let settled = run(phase).isTerminal
            #expect((ComposerToolbar.forPhase(phase) == ComposerToolbar.none) == settled)
        }
    }
}
