import Foundation

/// The delta applier — a direct port of `stream.js`'s `Fleet`, and deliberately
/// a port rather than a second interpretation.
///
/// `stream.js` is the browser's applier, it is tested against the Python
/// reference (`tests/test_stream_js.py`), and it is what the desktop board runs
/// today. Two appliers that disagree about one rule would produce two boards
/// that disagree about the fleet, and the disagreement would be invisible until
/// it mattered. So every rule below names the line of `stream.js` it comes from.
///
/// It is a `struct` with no I/O and no clock: everything that can be wrong in a
/// way no amount of tapping would reveal lives here, and it is all reachable
/// from a test with three literals.
public struct FleetApplier: Sendable, Equatable {
    public enum Outcome: Sendable, Equatable {
        case applied
        /// Frames were missed. The caller reconnects; nothing here was mutated.
        case gap
    }

    /// `nil` = holding nothing a delta may be applied to. Not `0` — version 0 is
    /// a value the server could in principle publish, and a sentinel that
    /// collides with a legal value is the bug this is shaped to avoid.
    public private(set) var version: Int?
    /// Keyed `<node>/<worktree>` — the frame's own keys (ADR 0016).
    public private(set) var cards: [String: Worktree] = [:]
    public private(set) var order: [String] = []
    public private(set) var counts = Counts()
    public private(set) var otherProcs: [OtherProc] = []
    /// Node id -> `{label, hostname, user}`; whole on every frame (`stream.js`
    /// `this.nodes = f.nodes || {}`) — the fourth bump term: a node can appear
    /// with zero cards, and a board must be able to name every node its cards
    /// reference (NODES.md §6).
    public private(set) var nodes: [String: NodeInfo] = [:]
    public private(set) var freshness = Freshness()
    /// The frame's own `at` — the collector's tick, in SERVER time.
    public private(set) var at: Double?

    public init() {}

    public mutating func reset() {
        version = nil
        cards = [:]
        order = []
        counts = Counts()
        otherProcs = []
        nodes = [:]
        freshness = Freshness()
        at = nil
    }

    /// One frame in.
    ///
    /// **The gap test is `base`, and only `base`** (`stream.js` lines 51–66). It
    /// is tempting to check `v == version + 1` and call anything else a lost
    /// frame — but the server waits on the version and *then* asks for a delta,
    /// so publishes landing in between are coalesced into one frame whose `v`
    /// jumps by more than one. A client testing `v` would resync on every busy
    /// moment, which on a fleet mid-turn is a reconnect loop. `base` is the
    /// cursor the server actually resumed from, so `base == version` is exactly
    /// the question "did I see everything before this?".
    ///
    /// A gap mutates NOTHING. Half-applying a frame we are about to throw away
    /// only makes the thrown-away state harder to reason about.
    public mutating func apply(_ frame: StreamFrame) -> Outcome {
        switch frame.type {
        case .delta:
            guard let held = version, frame.base == held else { return .gap }
            for (key, card) in frame.cards {
                if let card {
                    cards[key] = card
                } else {
                    cards[key] = nil        // null = the worktree is gone
                }
            }
        case .snapshot:
            cards = frame.changedCards      // a snapshot REPLACES
        }
        // `order`, never the key order of `cards` (`stream.js` lines 81–88).
        // A delta names only what moved, so patching a dictionary leaves every
        // unchanged card at its old position and a card that just flipped to
        // `needs_input` would never sort to the top. The fallback is for a frame
        // with no `order` at all — a server older than this file.
        order = frame.order.isEmpty ? Array(cards.keys).sorted() : frame.order
        counts = frame.counts
        // Whole on every frame, because a loose claude process bumps the version
        // with no card changing (`observer.delta_since` says why).
        otherProcs = frame.otherProcs
        // Whole on every frame too — the fourth bump term (ADR 0016): a node
        // can appear with zero cards, and a board must be able to name every
        // node its cards reference (`stream.js` `this.nodes = f.nodes || {}`;
        // the frame's lenient decode is the `|| {}`).
        nodes = frame.nodes
        freshness = frame.freshness
        at = frame.at
        version = frame.v
        return .applied
    }

    /// A full `/api/state` body in — used when there is no stream to trust.
    ///
    /// **It leaves `version` nil deliberately** (`stream.js` `load()`): that
    /// payload carries no version, so a delta applied on top of it would be
    /// applied to an unknown base. The next delta gaps, and the gap is what
    /// fetches an authoritative snapshot.
    public mutating func seed(_ state: FleetState) {
        // Keyed by the qualified card key, exactly as `stream.js` derives it
        // (`var k = cardKey(wts[i])`) — a bare name here collides the moment
        // two nodes each hold a `ConfidAI2`, and a name-keyed dictionary would
        // silently drop one of them.
        cards = Dictionary(state.worktrees.map { ($0.key, $0) },
                           uniquingKeysWith: { first, _ in first })
        order = state.worktrees.map(\.key)
        counts = state.counts
        otherProcs = state.otherProcs
        nodes = state.nodes
        at = state.generatedAt
        version = nil
    }

    /// The `/api/state` shape the UI already renders, rebuilt from frames.
    ///
    /// `free_worktrees` is DERIVED and not sent (`stream.js` `composed()`): it
    /// is exactly `[cardKey(card) for card if availability == "free"]` —
    /// QUALIFIED keys, matching the server's own `free_worktrees`, because a
    /// bare name here would dispatch to whichever node won the collision. On
    /// the wire it would be a second copy that can disagree with the first.
    public func composed(side: FleetSide) -> FleetState? {
        guard let at else { return nil }
        // `order` first, `cards` never: the dictionary's key order is arbitrary,
        // and a key in `order` with no card is a frame we are mid-way through
        // — skipped rather than faked.
        let worktrees = order.compactMap { cards[$0] }
        return FleetState(generatedAt: at,
                          hostname: side.hostname,
                          user: side.user,
                          counts: counts,
                          freeWorktrees: worktrees.filter { $0.availability == .free }.map(\.key),
                          worktrees: worktrees,
                          otherProcs: otherProcs,
                          resumes: side.resumes,
                          nodes: nodes,
                          boardNode: side.node)
    }
}

/// The things no frame carries, and the honest reason the stream is not
/// zero requests (`stream.js` `refresh()`).
///
/// * `resumes` lives in `resume.py`, which the observer does not watch at all —
///   arming one moves no version, so it could not ride the stream however the
///   frame were shaped.
/// * `hostname` / `user` are constant for the life of the server process — they
///   still mean THE BOARD HOST after the split (NODES.md §3).
/// * `node` is the board host's own node id (`/api/state`'s top-level `node`) —
///   also constant, and the client's only honest way to tell local from remote.
public struct FleetSide: Sendable, Equatable {
    public var hostname: String
    public var user: String
    public var node: String
    public var resumes: [String: ResumeSchedule]

    public init(hostname: String = "", user: String = "", node: String = "",
                resumes: [String: ResumeSchedule] = [:]) {
        self.hostname = hostname
        self.user = user
        self.node = node
        self.resumes = resumes
    }

    public init(_ state: FleetState) {
        hostname = state.hostname
        user = state.user
        node = state.boardNode
        resumes = state.resumes
    }
}
