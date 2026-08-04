/// When the device-owner check may be *presented*, as a rule rather than as a
/// condition buried in a view's lifecycle.
///
/// This exists because of a defect found on a real phone: the screen was locked
/// and orchestra put up **"Enter iPhone passcode for Orchestra"** by itself.
/// `LAContext.evaluatePolicy` will draw over the lock screen quite happily, and
/// two ordinary paths reached it with nobody looking:
///
/// 1. the gate re-locks on the `.background` transition, so the lock screen is
///    swapped into the hierarchy **while the app is already backgrounded** — and
///    SwiftUI runs a `.task` on it, because the app switcher needs that
///    hierarchy rendered;
/// 2. `.active` is delivered while the device itself is still locked — a
///    raise-to-wake, or a banner, puts the frontmost app through the phase
///    without anyone unlocking anything.
///
/// The rule lives here, in a value with no UIKit and no clock, for the reason
/// every other rule in this directory does: the two conditions are cheap to
/// state and expensive to rediscover, and a rule with no test is a rule that
/// drifts back. `App/BiometricGate.swift` supplies the two facts and does what
/// this says.
public enum BiometricPolicy {

    /// What to do about an unlock prompt at this instant.
    ///
    /// `wait` is deliberately **not** a failure. The distinction is the whole
    /// design: the gate's `failed` phase suppresses auto-prompting (it means the
    /// user cancelled, or something needs their attention), so a
    /// "nobody is looking" refusal that landed there would leave a dead gate
    /// that only a manual tap could revive. `wait` leaves the gate cold, and the
    /// next genuine activation prompts normally.
    public enum Decision: Equatable, Sendable {
        case prompt
        case wait
    }

    /// - Parameters:
    ///   - needsUnlock: the gate is cold — not already unlocked, and not with an
    ///     evaluation in flight, and not sitting on a refusal the user made.
    ///   - appIsActive: the app is genuinely foreground-active. Separates "a
    ///     person is looking at us" from "we were woken behind a lock screen".
    ///   - protectedDataAvailable: false while the device itself is locked,
    ///     which is the half of the question activation alone cannot answer.
    public static func decide(needsUnlock: Bool,
                              appIsActive: Bool,
                              protectedDataAvailable: Bool) -> Decision {
        guard needsUnlock else { return .wait }
        return appIsActive && protectedDataAvailable ? .prompt : .wait
    }
}
