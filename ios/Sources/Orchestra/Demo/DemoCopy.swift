import Foundation

/// Every sentence the demo fleet says about itself, in one place.
///
/// **The rule that shapes all of it: never claim something the app did not do.**
/// The paired app's whole receipt design is built on showing the server's own
/// words verbatim and never rendering a timeout as a failure; a demo that
/// answered a tap with a fake `✓ typed` would undo that in one screen. So every
/// mutation path in demo mode refuses, in the server's own voice — short,
/// lower-case, and it names the remedy — and the controls stay **visible and
/// disabled with the reason attached** rather than hidden, because the reviewer
/// is here to see that the app can act, not to be shown a smaller app.
public enum DemoCopy {
    /// The pairing screen's entry point. **This exact string is in the App Store
    /// review notes and in the screenshot job**; it is not a label to reword.
    public static let entryPoint = "explore the demo fleet"

    /// One line under it, so the tap is not a mystery.
    public static let entryPointNote =
        "A canned fleet, invented for this screen. No server, no network, "
        + "read-only."

    /// What the connection bar says instead of `live v82`. A demo board rendered
    /// behind the live caption would be the one lie the whole bar exists to
    /// prevent.
    public static let link = "demo fleet · nothing here is real"

    /// The one sentence every refused mutation says.
    public static let refusal = "this is the demo fleet — pair your Mac to act"

    /// The way out, on the board's menu and on the connection bar.
    public static let exit = "leave the demo"

    /// The Server tab's block, where "what am I connected to" has the honest
    /// answer "nothing".
    public static let notConnected = "not connected to anything"

    public static let banner =
        "Every worktree, agent, transcript and number here is invented and lives "
        + "in this app. Nothing is sent anywhere, and nothing can be changed."

    /// Shown where a real pairing would start, so leaving the demo is offered at
    /// the point the user wants it rather than only where it was entered.
    public static let pairInstead = "leave the demo and pair your Mac"
}
