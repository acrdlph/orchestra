import Foundation

/// The board the app shows when it has no Mac to show — the App Store
/// reviewer's whole experience of this product.
///
/// **Why it exists.** orchestra is a client for a server the user runs on their
/// own machine. Opened with nothing paired it is a pairing screen and nothing
/// else, and "reviewer opened it, saw an empty screen, rejected it" is the
/// standard way a companion app fails guideline 2.1. So the app carries one
/// fleet of its own.
///
/// **Why it is a string literal and not a bundle resource.** `Package.swift`
/// builds `Sources/Orchestra` as one target with warnings as errors, and a stray
/// non-source file in that tree is a build problem rather than a resource. A
/// literal is also the only form `swift test` can decode without a bundle — and
/// this payload has to be *tested*, because a demo board that fails to decode
/// fails on the reviewer's phone and nowhere else.
///
/// **Why it is a frame and not a hand-built `[Worktree]`.** It goes in as bytes
/// through `StreamFrame.decode` and `FleetApplier.apply`, which is the exact path
/// a real `event: state` frame takes. A demo assembled from Swift initialisers
/// would render a board no wire could produce, and every field this codebase
/// learned the hard way — `turn_ended` absent rather than false, `ahead`/`behind`
/// null rather than zero, `tool_running` present only when true — would be
/// silently un-exercised. This payload deliberately carries all three.
///
/// **Ages.** Every timestamp is written against `DemoClock.base` and moved onto
/// the reader's clock at load. See `DemoClock`.
///
/// The fleet itself is invented: six worktrees of a fictional storefront, one
/// card in each of the board's five sections, and every session status the
/// server can publish represented at least once.
public enum DemoFleet {
    public static let hostname = "studio-mini"
    public static let user = "dev"

    // The addresses a seam, a test, or the chat lookup needs to name. Session
    // ids are the only thing in this app that addresses anything, so they are
    // constants rather than strings copied into four files.
    public static let needsAnswerWorktree = "search-index"
    public static let needsAnswerAccount = "main"
    public static let needsAnswerSid = "9c1f4a2e-7b30-4c58-9a11-2d6e83f0b415"
    public static let blockedSid = "b430e7c9-51d2-4f8a-b6e3-70c95a1d8226"
    public static let workingSid = "4f6a1d08-9e77-42b1-a530-cc81f7b2e934"
    public static let waitingSid = "7d2e9105-6c48-4a3b-8e10-fd39b64c02a7"
    public static let limitSid = "a0539f74-2b6e-4d81-93cf-1e7a48d5c6b2"
    public static let limitWorktree = "release-notes"
    public static let freeWorktree = "design-tokens"

    /// The snapshot frame, decoded by the same call `FleetStore.runStream` makes.
    public static func frame(now: Date = Date()) throws -> StreamFrame {
        try StreamFrame.decode(DemoClock.rewrite(frameJSON, now: now))
    }

    /// The three things no frame carries (`FleetSide`). `hostname` and `user` are
    /// two strings; `resumes` is a real payload and is decoded like one, because
    /// an armed auto-resume is one of the states the board is for.
    public static func side(now: Date = Date()) throws -> FleetSide {
        let data = try DemoClock.rewrite(resumesJSON, now: now)
        let resumes = try JSONDecoder().decode([String: ResumeSchedule].self, from: data)
        return FleetSide(hostname: hostname, user: user, resumes: resumes)
    }

    // MARK: - The payloads
    //
    // Shaped against `Tests/OrchestraKitTests/Fixtures/snapshot-frame.json` — a
    // real nine-worktree capture — key for key. The names, prose and numbers are
    // invented; the SHAPE is not.

    static let frameJSON = #"""
    {
      "type": "snapshot",
      "v": 214,
      "at": 1799999998,
      "order": ["search-index", "payments-webhook", "checkout-flow",
                "api-gateway", "release-notes", "design-tokens"],
      "cards": {
        "search-index": {
          "name": "search-index",
          "path": "/Users/dev/code/storefront/search-index",
          "git": {
            "branch": "perf/incremental-reindex",
            "commit": {
              "hash": "6b41d0e7a",
              "ts": 1799996820,
              "subject": "perf(search): reindex only the shards a write actually touched"
            },
            "dirty": 3,
            "ahead": 2,
            "behind": 0
          },
          "sessions": [
            {
              "id": "9c1f4a2e",
              "sid": "9c1f4a2e-7b30-4c58-9a11-2d6e83f0b415",
              "account": "main",
              "last_write_at": 1799999953,
              "cwd": "/Users/dev/code/storefront/search-index",
              "subdir": null,
              "branch": "perf/incremental-reindex",
              "model": "fable-5",
              "pending_tools": [],
              "pending_workflows": 0,
              "pending_bg_agents": 0,
              "pending_bg_tools": 0,
              "topic": "make the catalogue reindex incremental so search stays up during a deploy",
              "last_assistant": "The incremental path is in and the shard map rebuilds from the write log. Before I delete the nightly full pass: keep it as a safety net, or remove it outright?",
              "last_user": "put the incremental reindex behind a flag and measure it against the full pass",
              "subagent_said": null,
              "subagents_active": false,
              "turn_ended": true,
              "pid": 41822,
              "pid_certain": true,
              "status": "needs_input",
              "status_src": "observed",
              "hooked": true
            },
            {
              "id": "27b8e5d3",
              "sid": "27b8e5d3-04ac-4e19-8f77-b1c0a92d6e40",
              "account": "main",
              "last_write_at": 1799986420,
              "cwd": "/Users/dev/code/storefront/search-index",
              "subdir": null,
              "branch": "perf/incremental-reindex",
              "model": "sonnet-4-6",
              "pending_tools": [],
              "pending_workflows": 0,
              "pending_bg_agents": 0,
              "pending_bg_tools": 0,
              "topic": "read the current reindex job and write down what it costs",
              "last_assistant": "Measured: a full pass is 4m12s and holds a write lock for 38s of it. Notes are in docs/search-reindex.md.",
              "last_user": "before changing anything, measure the pass we already have",
              "subagent_said": null,
              "subagents_active": false,
              "turn_ended": true,
              "pid": null,
              "pid_certain": false,
              "status": "ended"
            }
          ],
          "live_procs": [
            {
              "pid": 41822,
              "cpu": 0.4,
              "etime": "01:12:44",
              "tty": "ttys006",
              "host": "tmux -L fleet",
              "account": "main",
              "tmux": "fleet:search-index",
              "reachable": true,
              "subdir": null
            }
          ],
          "availability": "attention"
        },

        "payments-webhook": {
          "name": "payments-webhook",
          "path": "/Users/dev/code/storefront/payments-webhook",
          "git": {
            "branch": "fix/webhook-retries",
            "commit": {
              "hash": "0af93c21",
              "ts": 1799992600,
              "subject": "fix(webhooks): the retry budget is per endpoint, not per process"
            },
            "dirty": 11,
            "ahead": null,
            "behind": null
          },
          "sessions": [
            {
              "id": "b430e7c9",
              "sid": "b430e7c9-51d2-4f8a-b6e3-70c95a1d8226",
              "account": "work",
              "last_write_at": 1799999872,
              "cwd": "/Users/dev/code/storefront/payments-webhook/workers",
              "subdir": "workers",
              "branch": "fix/webhook-retries",
              "model": "opus-4-8",
              "pending_tools": ["Bash"],
              "pending_workflows": 0,
              "pending_bg_agents": 0,
              "pending_bg_tools": 0,
              "topic": "a provider replay is charging some orders twice",
              "last_assistant": "I can reproduce it, but the replay harness wants the sandbox key and I can't read it from here. Paste it, or tell me to skip the replay and trust the unit test.",
              "last_user": "reproduce the double charge first, then fix it",
              "subagent_said": null,
              "subagents_active": false,
              "turn_ended": false,
              "pid": 41977,
              "pid_certain": true,
              "status": "blocked",
              "tool_running": true
            }
          ],
          "live_procs": [
            {
              "pid": 41977,
              "cpu": 1.9,
              "etime": "00:22:08",
              "tty": "ttys011",
              "host": "Terminal",
              "account": "work",
              "tmux": null,
              "reachable": true,
              "subdir": "workers"
            }
          ],
          "availability": "attention"
        },

        "checkout-flow": {
          "name": "checkout-flow",
          "path": "/Users/dev/code/storefront/checkout-flow",
          "git": {
            "branch": "feat/guest-checkout",
            "commit": {
              "hash": "d72c4b9e1",
              "ts": 1799999520,
              "subject": "feat(checkout): a guest order carries a claim token for later sign-up"
            },
            "dirty": 6,
            "ahead": 0,
            "behind": 4
          },
          "sessions": [
            {
              "id": "4f6a1d08",
              "sid": "4f6a1d08-9e77-42b1-a530-cc81f7b2e934",
              "account": "main",
              "last_write_at": 1799999991,
              "cwd": "/Users/dev/code/storefront/checkout-flow",
              "subdir": null,
              "branch": "feat/guest-checkout",
              "model": "fable-5",
              "pending_tools": ["Edit"],
              "pending_workflows": 0,
              "pending_bg_agents": 2,
              "pending_bg_tools": 0,
              "topic": "let people buy without an account, and let them claim the order afterwards",
              "last_assistant": "Two subagents are out: one on the claim-token expiry rules, one on the address form. I'm rewriting the order summary while they run.",
              "last_user": "guest checkout, end to end, and don't touch the payment step",
              "subagent_said": "the claim token should outlive the session cookie, or a closed tab loses the order",
              "subagents_active": true,
              "turn_ended": false,
              "pid": 42104,
              "pid_certain": true,
              "status": "working",
              "tool_running": true
            },
            {
              "id": "e18c5b62",
              "sid": "e18c5b62-3a0d-47f6-9c24-58ba0d71ff03",
              "account": "work",
              "last_write_at": 1799973600,
              "cwd": "/Users/dev/code/storefront/checkout-flow",
              "subdir": null,
              "branch": "feat/guest-checkout",
              "model": "haiku-4-5-20251001",
              "pending_tools": [],
              "pending_workflows": 0,
              "pending_bg_agents": 0,
              "pending_bg_tools": 0,
              "topic": null,
              "last_assistant": "Done — the cart fixtures now cover an empty cart, a single line and the twenty-line case.",
              "last_user": "write fixtures for the cart before we start on checkout",
              "subagent_said": null,
              "subagents_active": false,
              "turn_ended": true,
              "pid": null,
              "pid_certain": false,
              "status": "ended"
            }
          ],
          "live_procs": [
            {
              "pid": 42104,
              "cpu": 12.6,
              "etime": "00:41:19",
              "tty": "ttys004",
              "host": "tmux -L fleet",
              "account": "main",
              "tmux": "fleet:checkout-flow",
              "reachable": true,
              "subdir": null
            }
          ],
          "availability": "busy"
        },

        "api-gateway": {
          "name": "api-gateway",
          "path": "/Users/dev/code/storefront/api-gateway",
          "git": {
            "branch": "chore/rate-limit-headers",
            "commit": {
              "hash": "3e59f08",
              "ts": 1799992800,
              "subject": "chore(gateway): emit RateLimit-* headers on every 429"
            },
            "dirty": 0,
            "ahead": 1,
            "behind": 0
          },
          "sessions": [
            {
              "id": "7d2e9105",
              "sid": "7d2e9105-6c48-4a3b-8e10-fd39b64c02a7",
              "account": "work",
              "last_write_at": 1799999628,
              "cwd": "/Users/dev/code/storefront/api-gateway",
              "subdir": null,
              "branch": "chore/rate-limit-headers",
              "model": "sonnet-4-6",
              "pending_tools": [],
              "pending_workflows": 0,
              "pending_bg_agents": 0,
              "pending_bg_tools": 0,
              "topic": "tell clients when to come back instead of just refusing them",
              "last_assistant": "Every 429 now carries RateLimit-Limit, -Remaining, -Reset and a Retry-After, and the contract test covers all three windows. Anything else on the gateway, or shall I close this out?",
              "last_user": "make the 429s say when to retry",
              "subagent_said": null,
              "subagents_active": false,
              "turn_ended": true,
              "pid": 42011,
              "pid_certain": true,
              "status": "waiting"
            }
          ],
          "live_procs": [
            {
              "pid": 42011,
              "cpu": 0.0,
              "etime": "02:05:53",
              "tty": "ttys009",
              "host": "Terminal",
              "account": "work",
              "tmux": null,
              "reachable": true,
              "subdir": null
            }
          ],
          "availability": "attention"
        },

        "release-notes": {
          "name": "release-notes",
          "path": "/Users/dev/code/storefront/release-notes",
          "git": {
            "branch": "docs/release-1-4",
            "commit": {
              "hash": "aa17be2c",
              "ts": 1799983800,
              "subject": "docs: draft the 1.4 notes from the merged pull request titles"
            },
            "dirty": 1,
            "ahead": 0,
            "behind": 0
          },
          "sessions": [
            {
              "id": "a0539f74",
              "sid": "a0539f74-2b6e-4d81-93cf-1e7a48d5c6b2",
              "account": "spare",
              "last_write_at": 1799997240,
              "cwd": "/Users/dev/code/storefront/release-notes",
              "subdir": null,
              "branch": "docs/release-1-4",
              "model": "opus-4-8",
              "pending_tools": [],
              "pending_workflows": 0,
              "pending_bg_agents": 0,
              "pending_bg_tools": 0,
              "topic": "turn the 1.4 merge log into notes a person would actually read",
              "last_assistant": "Six of the eleven entries are rewritten. Stopping here — this account is out of weekly usage.",
              "last_user": "no bullet points that just restate the commit subject",
              "subagent_said": null,
              "subagents_active": false,
              "turn_ended": true,
              "pid": 42230,
              "pid_certain": false,
              "status": "limit",
              "limit": {
                "worst": "weekly",
                "group": "weekly",
                "resets_at": 1800005400
              }
            }
          ],
          "live_procs": [
            {
              "pid": 42230,
              "cpu": 0.0,
              "etime": "01:34:02",
              "tty": "ttys012",
              "host": "tmux -L fleet",
              "account": "spare",
              "tmux": "fleet:release-notes",
              "reachable": true,
              "subdir": null
            }
          ],
          "availability": "waiting"
        },

        "design-tokens": {
          "name": "design-tokens",
          "path": "/Users/dev/code/storefront/design-tokens",
          "git": {
            "branch": "design/token-pass",
            "commit": {
              "hash": "5c0b8d34f",
              "ts": 1799908200,
              "subject": "design: one scale for spacing, one for radius, nothing bespoke"
            },
            "dirty": 0,
            "ahead": 0,
            "behind": 0
          },
          "sessions": [
            {
              "id": "6cb17e40",
              "sid": "6cb17e40-8d95-4f23-b70a-24e9c3081d5f",
              "account": "main",
              "last_write_at": 1799920800,
              "cwd": "/Users/dev/code/storefront/design-tokens",
              "subdir": null,
              "branch": "design/token-pass",
              "model": "",
              "pending_tools": [],
              "pending_workflows": 0,
              "pending_bg_agents": 0,
              "pending_bg_tools": 0,
              "topic": null,
              "last_assistant": "Merged and pushed. Every bespoke pixel value is gone; the two scales are in tokens.json.",
              "last_user": null,
              "subagent_said": null,
              "subagents_active": false,
              "pid": null,
              "pid_certain": false,
              "status": "ended"
            }
          ],
          "live_procs": [],
          "availability": "free"
        }
      },
      "counts": {
        "working": 1,
        "needs_input": 1,
        "limit": 1,
        "blocked": 1,
        "waiting": 1,
        "ended": 3
      },
      "other_procs": [
        {
          "pid": 39004,
          "cpu": 0.0,
          "etime": "02:41:12",
          "tty": null,
          "host": "Terminal",
          "cwd": "/Users/dev/code/scratch"
        }
      ],
      "freshness": {
        "worktrees": 1799999997,
        "procs": 1799999998,
        "transcripts": 1799999998,
        "git": 1799999991
      }
    }
    """#

    /// `/api/state.resumes` — keyed `"{worktree}|{sid}"` with a literal pipe
    /// (`resume.py:68`). One armed resume, on the limited card, due a minute
    /// after that account's weekly limit resets.
    ///
    /// `message` is **null**, which is an ordinary wire state and the right one
    /// here: `ResumeSheet` renders a non-null message through `ServerSays` with
    /// an `.ok` tick, and a green ✓ on a demo screen reads as a receipt for
    /// something that happened. Nothing in the demo may read as a receipt.
    static let resumesJSON = #"""
    {
      "release-notes|a0539f74-2b6e-4d81-93cf-1e7a48d5c6b2": {
        "worktree": "release-notes",
        "sid": "a0539f74-2b6e-4d81-93cf-1e7a48d5c6b2",
        "account": "spare",
        "model": "opus",
        "delay_s": null,
        "status": "pending",
        "due_at": 1800005460,
        "attempts": 0,
        "message": null
      }
    }
    """#
}
