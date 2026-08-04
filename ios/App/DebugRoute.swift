#if DEBUG
import Foundation

/// A launch-time screen selector, and it is the same kind of seam as
/// `ORC_PAIR_URL` and it exists for the same reason.
///
/// **A simulator has no camera and cannot be typed into from a script.** The
/// house rule for this project is that a phase ends with the app built, run, and
/// LOOKED at — because a view that compiles and renders blank is the silent
/// failure this codebase keeps finding. `xcrun simctl` can install, launch and
/// screenshot; it cannot tap. And an accessibility-driven click needs a
/// permission grant that a headless run does not have (System Events answers
/// `-25204`).
///
/// So every screen gets one way to be reached without a finger:
///
/// ```
/// SIMCTL_CHILD_ORC_SCREEN=limits              xcrun simctl launch booted sh.orchestra.app
/// SIMCTL_CHILD_ORC_SCREEN=server              …
/// SIMCTL_CHILD_ORC_SCREEN=wt:ConfidAI2        …
/// SIMCTL_CHILD_ORC_SCREEN=chat:ConfidAI2/account2/ca1c96e9-…  …
/// ```
///
/// It is `#if DEBUG`, it reads an environment variable a Release build cannot
/// see, and it pushes exactly the destinations a tap pushes — the same
/// `FleetRoute` values, through the same `navigationDestination`. It is a way to
/// press the button, not a second way to navigate.
enum DebugRoute: Equatable {
    case fleet
    /// The demo fleet's board. `ORC_SCREEN=demo` — and, because a screenshot run
    /// needs the demo's *other* screens too, `demo:` is also a PREFIX:
    /// `demo:wt:search-index`, `demo:chat:…`, `demo:limits`, `demo:map` each
    /// enter the demo and then land exactly where the bare route would.
    /// `demoRequested` reads the prefix; `parse` strips it, so every route below
    /// keeps one spelling.
    case demo
    case limits
    case server
    /// The notification preferences, pushed on the Server stack. `ORC_SCREEN=
    /// notifications` — the only way a script reaches a screen behind a tap.
    case notifications
    /// The branch map, pushed on the Fleet stack. `ORC_SCREEN=map` — the only way
    /// `xcrun simctl` reaches a pushed destination that has no camera and no tap.
    case map
    case worktree(String)
    case chat(worktree: String, account: String, sid: String)
    /// A `cclimits` slug — the key `/api/limits` uses, which is NOT always
    /// orchestra's own account label.
    case account(String)
    /// The mission composer, opened on launch, optionally with one of its four
    /// option pickers already presented — `mission`, `mission:model`,
    /// `mission:effort`, `mission:worktree`, `mission:account`.
    ///
    /// The picker half was added for the same reason the composer half was:
    /// **a sheet inside a sheet cannot be tapped from a script**, and the defect
    /// these pickers were rebuilt to fix (a `Menu` collapsing to a ~20 pt sliver
    /// when a tall third-party keyboard squeezed its anchor region) is one that
    /// only a screenshot can prove is gone.
    case mission(picker: String?)
    /// A worktree with its finish sheet already presented. Same destination and
    /// same sheet a tap presents; the only difference is what pressed it.
    case finish(String)
    /// A worktree with the auto-resume sheet presented for one session.
    case resume(worktree: String, sid: String)

    static func fromEnvironment(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> DebugRoute? {
        guard let raw = environment["ORC_SCREEN"], !raw.isEmpty else { return nil }
        return parse(raw)
    }

    /// Whether this launch asked for the demo fleet. Read by `AppModel.start()`,
    /// which enters the demo before anything renders — so a screenshot run lands
    /// on the demo board with no finger, exactly as `ORC_PAIR_URL` lands a real
    /// one.
    static func demoRequested(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        guard let raw = environment["ORC_SCREEN"]?.lowercased() else { return false }
        return raw == "demo" || raw.hasPrefix("demo:")
    }

    static func parse(_ raw: String) -> DebugRoute? {
        var raw = raw
        if raw.lowercased().hasPrefix("demo:") {
            raw = String(raw.dropFirst("demo:".count))
        }
        let parts = raw.split(separator: ":", maxSplits: 1).map(String.init)
        switch parts.first?.lowercased() {
        case "demo": return .demo
        case "fleet": return .fleet
        case "limits":
            guard parts.count == 2, !parts[1].isEmpty else { return .limits }
            return .account(parts[1])
        case "server": return .server
        case "notifications", "push": return .notifications
        case "map": return .map
        case "mission":
            guard parts.count == 2, !parts[1].isEmpty else { return .mission(picker: nil) }
            return .mission(picker: parts[1].lowercased())
        case "finish":
            guard parts.count == 2, !parts[1].isEmpty else { return nil }
            return .finish(parts[1])
        case "resume":
            guard parts.count == 2 else { return nil }
            let fields = parts[1].split(separator: "/", maxSplits: 1).map(String.init)
            guard fields.count == 2 else { return nil }
            return .resume(worktree: fields[0], sid: fields[1])
        case "wt", "worktree":
            guard parts.count == 2, !parts[1].isEmpty else { return nil }
            return .worktree(parts[1])
        case "chat":
            guard parts.count == 2 else { return nil }
            // `worktree/account/sid` — the sid is a UUID with dashes and the
            // account can be anything, so the split is bounded rather than
            // greedy and the sid keeps whatever is left.
            let fields = parts[1].split(separator: "/", maxSplits: 2).map(String.init)
            guard fields.count == 3 else { return nil }
            return .chat(worktree: fields[0], account: fields[1], sid: fields[2])
        default:
            return nil
        }
    }

    /// Which tab the route lives on.
    var tab: Int {
        switch self {
        case .demo, .fleet, .map, .worktree, .chat, .mission, .finish, .resume: 0
        case .limits, .account: 1
        case .server, .notifications: 2
        }
    }

    /// Whether the Server tab should push its notifications screen on appear.
    var showsNotificationSettings: Bool { self == .notifications }

    /// What the Limits tab should push, if anything.
    var accountSlug: String? {
        if case .account(let slug) = self { return slug }
        return nil
    }

    /// Which sheet the pushed worktree screen should present on appear.
    var worktreeSheet: WorktreeSheet? {
        switch self {
        case .finish: .finish
        case .resume(_, let sid): .resume(sid: sid)
        default: nil
        }
    }

    /// Whether this route opens the mission composer, and which picker (if any)
    /// it should present on top of it.
    var opensComposer: Bool {
        if case .mission = self { return true }
        return false
    }

    var composerPicker: PickerField? {
        if case .mission(let picker) = self, let picker { return PickerField(rawValue: picker) }
        return nil
    }

    /// What the Fleet tab should push, if anything.
    var fleetRoute: FleetRoute? {
        switch self {
        case .map: .map
        case .worktree(let name): .worktree(name)
        case .chat(let w, let a, let s): .chat(worktree: w, account: a, sid: s)
        case .finish(let name): .worktree(name)
        case .resume(let w, _): .worktree(w)
        case .demo, .fleet, .limits, .server, .notifications, .account, .mission: nil
        }
    }
}
#endif
