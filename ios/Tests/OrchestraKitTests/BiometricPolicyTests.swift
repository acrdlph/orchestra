import Foundation
import Testing
@testable import OrchestraKit

/// The gate that put a passcode sheet on a LOCKED phone, pinned as a rule.
///
/// Every case here is a real state the app reaches; the two that matter are the
/// ones that used to prompt at nobody, and the fact that refusing is `wait` and
/// not a failure.
@Suite("biometric prompt policy")
struct BiometricPolicyTests {

    @Test func aForegroundAppOnAnUnlockedDevicePrompts() {
        #expect(BiometricPolicy.decide(needsUnlock: true,
                                       appIsActive: true,
                                       protectedDataAvailable: true) == .prompt)
    }

    /// Defect path 1: `lock()` runs on the `.background` transition, the lock
    /// screen is swapped into the hierarchy while the app is backgrounded, and
    /// SwiftUI runs its `.task`. The app is not active — nobody is looking.
    @Test func aBackgroundedAppNeverPrompts() {
        #expect(BiometricPolicy.decide(needsUnlock: true,
                                       appIsActive: false,
                                       protectedDataAvailable: true) == .wait)
    }

    /// Defect path 2: `.active` arrives while the DEVICE is still locked — a
    /// raise-to-wake or a banner. Activation alone cannot tell you a person got
    /// past the lock screen; protected data can.
    @Test func anActiveAppOnALockedDeviceNeverPrompts() {
        #expect(BiometricPolicy.decide(needsUnlock: true,
                                       appIsActive: true,
                                       protectedDataAvailable: false) == .wait)
    }

    @Test func aBackgroundWakeBehindALockedScreenNeverPrompts() {
        #expect(BiometricPolicy.decide(needsUnlock: true,
                                       appIsActive: false,
                                       protectedDataAvailable: false) == .wait)
    }

    /// A gate that is already unlocked, already evaluating, or sitting on a
    /// refusal the user made is not cold, and must not be re-prompted however
    /// good the conditions look.
    @Test func aGateThatDoesNotNeedUnlockingIsLeftAlone() {
        #expect(BiometricPolicy.decide(needsUnlock: false,
                                       appIsActive: true,
                                       protectedDataAvailable: true) == .wait)
    }

    /// The distinction the whole design rests on: refusing is `wait`, which
    /// leaves the gate cold so the next real activation prompts. If this ever
    /// becomes a failure-shaped outcome, the gate stops auto-prompting and only
    /// a manual tap revives it.
    @Test func refusingIsWaitingRatherThanFailing() {
        let refusals = [
            BiometricPolicy.decide(needsUnlock: true, appIsActive: false,
                                   protectedDataAvailable: true),
            BiometricPolicy.decide(needsUnlock: true, appIsActive: true,
                                   protectedDataAvailable: false),
        ]
        #expect(refusals.allSatisfy { $0 == .wait })
        // and the type offers no third, failure-shaped case to drift into
        #expect(BiometricPolicy.Decision.wait != BiometricPolicy.Decision.prompt)
    }
}
