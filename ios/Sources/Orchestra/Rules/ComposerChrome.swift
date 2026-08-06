import Foundation

/// What the mission composer's toolbar offers, as a pure function of the run.
///
/// **The defect this encodes was reported from a phone:** *"there's a cancel and
/// launch header button on the launching screen. When the agent is already
/// launching, I'm not sure if we need that cancel and launch anymore. I'm not
/// sure if it's too late to cancel, but it's definitely too late to launch."*
///
/// Both halves were true.
///
/// * **Launch was a dead control.** `canLaunch` is false while `dispatch != nil`,
///   so from the instant the mission was confirmed the button rendered
///   permanently disabled — a control that can never be pressed, sitting in the
///   corner the eye goes to first.
/// * **"Cancel" was a lie of labelling.** It called `dismiss()` and nothing else.
///   It did not stop the mission and it *cannot*: there is no kill endpoint on
///   this server (`ios/README.md` row 33 — `/api/kill` does not exist), so the
///   app has no undo for a launch and does not pretend to. A button labelled
///   Cancel on a screen titled "Launching" reads as "stop this", which is the one
///   thing it does not do.
///
/// The rule lives here, outside `UI`, because `UI` is excluded from the test
/// target and a toolbar rule that can only be checked by looking at a screenshot
/// is a rule that drifts.
public enum ComposerToolbar: Sendable, Equatable {
    /// Still editing. Cancel keeps the draft; Launch spends money. Unchanged.
    case editing
    /// A dispatch is in flight. One neutral way off the screen and nothing else
    /// — the leading button is **Close**, not Cancel, and the body says in words
    /// that closing does not stop anything.
    case closeOnly
    /// The run has settled. The body already carries exactly one action for each
    /// terminal phase (`Done`, or `Back to the draft`), so the toolbar carries
    /// none: two buttons that both leave, one of which also clears the run and
    /// one of which does not, is a choice with no meaning to the user. The sheet
    /// is still interactively dismissible, so nobody is trapped.
    case none

    /// The one call site's decision, from the phase of the current run — `nil`
    /// when there is no run at all.
    public static func forPhase(_ phase: ActionsStore.DispatchRun.Phase?) -> ComposerToolbar {
        guard let phase else { return .editing }
        switch phase {
        case .launching, .running: return .closeOnly
        case .finished, .refused, .lost: return .none
        }
    }

    /// The leading button's title, or nil for no leading button. **Never
    /// "Cancel" once a run exists**, in any phase.
    public var leadingTitle: String? {
        switch self {
        case .editing: "Cancel"
        case .closeOnly: "Close"
        case .none: nil
        }
    }

    /// Whether Launch is on screen at all. It is a control, not a decoration:
    /// the moment it can never fire, it goes.
    public var showsLaunch: Bool { self == .editing }
}
