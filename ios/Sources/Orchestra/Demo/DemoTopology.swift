import Foundation

/// `GET /api/topology`, canned — the branch map behind the board's toolbar.
///
/// It is here because the map is one tap from the demo board and a reviewer will
/// take that tap. A screen that renders a transport failure is worse than no
/// screen: it is the app failing in front of the person deciding whether it
/// works.
///
/// The shape is the **legacy** one `gitrepo.branch_topology` really writes —
/// `fork_ts`/`tip_ts` rather than `_at`, `worktree` rather than `worktree_id`, no
/// `axis`, no `role`, no `dropped[]` — matching `Model/Topology.swift`'s findings
/// rather than `UX.md` §5.3, plus the post-split `node` on every branch
/// (ADR 0016): the map joins the board by `<node>/<worktree>`, and the demo's
/// node is `starbase`, matching `DemoFleet`. One group, because a demo with two
/// origins would be demonstrating a coincidence.
///
/// The server clamps `fork_ts` to `min(fork_ts, tip_ts)` before it serialises
/// (`gitrepo.py:228`), so no fork here sits right of its own tip.
public enum DemoTopology {
    public static func topology(now: Date = Date()) throws -> Topology {
        try JSONDecoder().decode(Topology.self,
                                 from: DemoClock.rewrite(json, now: now))
    }

    static let json = #"""
    {
      "generated_at": 1799999940,
      "groups": [
        {
          "repo": "storefront",
          "base": "origin/main",
          "trunk_ts": 1799999400,
          "trunk_commits": [1799999400, 1799997000, 1799993400, 1799988000,
                            1799979000, 1799965800, 1799950000, 1799930000,
                            1799900000],
          "branches": [
            {
              "worktree": "search-index",
              "node": "starbase",
              "branch": "perf/incremental-reindex",
              "fork_ts": 1799979000,
              "tip_ts": 1799996820,
              "ahead": 2,
              "behind": 0,
              "dirty": 3,
              "hash": "6b41d0e7a",
              "subject": "perf(search): reindex only the shards a write actually touched",
              "commits": [1799996820, 1799991200]
            },
            {
              "worktree": "payments-webhook",
              "node": "starbase",
              "branch": "fix/webhook-retries",
              "fork_ts": 1799988000,
              "tip_ts": 1799992600,
              "ahead": 3,
              "behind": 1,
              "dirty": 11,
              "hash": "0af93c21",
              "subject": "fix(webhooks): the retry budget is per endpoint, not per process",
              "commits": [1799992600, 1799990900, 1799989400]
            },
            {
              "worktree": "checkout-flow",
              "node": "starbase",
              "branch": "feat/guest-checkout",
              "fork_ts": 1799965800,
              "tip_ts": 1799999520,
              "ahead": 5,
              "behind": 4,
              "dirty": 6,
              "hash": "d72c4b9e1",
              "subject": "feat(checkout): a guest order carries a claim token for later sign-up",
              "commits": [1799999520, 1799994100, 1799985300, 1799977000, 1799968800]
            },
            {
              "worktree": "api-gateway",
              "node": "starbase",
              "branch": "chore/rate-limit-headers",
              "fork_ts": 1799992800,
              "tip_ts": 1799992800,
              "ahead": 1,
              "behind": 0,
              "dirty": 0,
              "hash": "3e59f08",
              "subject": "chore(gateway): emit RateLimit-* headers on every 429",
              "commits": [1799992800]
            },
            {
              "worktree": "release-notes",
              "node": "starbase",
              "branch": "docs/release-1-4",
              "fork_ts": 1799950000,
              "tip_ts": 1799983800,
              "ahead": 2,
              "behind": 6,
              "dirty": 1,
              "hash": "aa17be2c",
              "subject": "docs: draft the 1.4 notes from the merged pull request titles",
              "commits": [1799983800, 1799961000]
            },
            {
              "worktree": "design-tokens",
              "node": "starbase",
              "branch": "design/token-pass",
              "fork_ts": 1799900000,
              "tip_ts": 1799908200,
              "ahead": 0,
              "behind": 8,
              "dirty": 0,
              "hash": "5c0b8d34f",
              "subject": "design: one scale for spacing, one for radius, nothing bespoke",
              "commits": [1799908200]
            }
          ]
        }
      ]
    }
    """#
}
