import Foundation

/// `GET /api/limits`, canned.
///
/// **`generated_at` is `null`, and that is not laziness.** It is the wire case
/// `ios/README.md` finding 20 records: `/api/limits.generated_at` is an ISO-8601
/// string straight out of `cclimits` on the real path and **null in demo mode**,
/// while `/api/state.generated_at` is a float epoch — the same key name, two
/// types, on one API. The demo payload is honest about which of the two it is,
/// and the screen says so out loud rather than printing orchestra's own fetch
/// clock as if `cclimits` had stamped it.
///
/// The three accounts are the three states this screen exists to distinguish:
/// room to work, a model cap that is nearly out but blocks nothing, and an
/// account genuinely exhausted and under its reserve — which is the one the
/// board's limited card is parked on, so the two screens agree.
public enum DemoLimits {
    public static func report(now: Date = Date()) throws -> LimitsReport {
        try JSONDecoder().decode(LimitsReport.self,
                                 from: DemoClock.rewrite(json, now: now))
    }

    static let json = #"""
    {
      "available": true,
      "error": null,
      "fetched_at": 1799999640,
      "generated_at": null,
      "accounts": [
        {
          "slug": "default",
          "fb_label": "main",
          "email": "dev@example.com",
          "plan": "max_20x",
          "config_dir": "~/.claude",
          "ok": true,
          "error": null,
          "headroom_percent": 68.0,
          "reserve_percent": 20,
          "reserve_blocked": false,
          "limits": [
            {
              "label": "session",
              "group": "session",
              "percent": 24.0,
              "remaining_percent": 76.0,
              "model_scoped": false,
              "exhausted_now": false,
              "resets_at": 1800008100
            },
            {
              "label": "weekly",
              "group": "weekly",
              "percent": 32.0,
              "remaining_percent": 68.0,
              "model_scoped": false,
              "exhausted_now": false,
              "resets_at": 1800302400
            },
            {
              "label": "weekly (opus)",
              "group": "weekly",
              "percent": 81.0,
              "remaining_percent": 19.0,
              "model_scoped": true,
              "exhausted_now": false,
              "resets_at": 1800302400
            }
          ]
        },
        {
          "slug": "work",
          "fb_label": "work",
          "email": "dev+work@example.com",
          "plan": "max_5x",
          "config_dir": "~/.claude-work",
          "ok": true,
          "error": null,
          "headroom_percent": 41.0,
          "reserve_percent": 20,
          "reserve_blocked": false,
          "limits": [
            {
              "label": "session",
              "group": "session",
              "percent": 59.0,
              "remaining_percent": 41.0,
              "model_scoped": false,
              "exhausted_now": false,
              "resets_at": 1800003300
            },
            {
              "label": "weekly",
              "group": "weekly",
              "percent": 47.0,
              "remaining_percent": 53.0,
              "model_scoped": false,
              "exhausted_now": false,
              "resets_at": 1800302400
            },
            {
              "label": "weekly (opus)",
              "group": "weekly",
              "percent": 100.0,
              "remaining_percent": 0.0,
              "model_scoped": true,
              "exhausted_now": true,
              "resets_at": 1800302400
            }
          ]
        },
        {
          "slug": "spare",
          "fb_label": "spare",
          "email": "dev+spare@example.com",
          "plan": "pro",
          "config_dir": "~/.claude-spare",
          "ok": true,
          "error": null,
          "headroom_percent": 0.0,
          "reserve_percent": 15,
          "reserve_blocked": true,
          "limits": [
            {
              "label": "session",
              "group": "session",
              "percent": 12.0,
              "remaining_percent": 88.0,
              "model_scoped": false,
              "exhausted_now": false,
              "resets_at": 1800001800
            },
            {
              "label": "weekly",
              "group": "weekly",
              "percent": 100.0,
              "remaining_percent": 0.0,
              "model_scoped": false,
              "exhausted_now": true,
              "resets_at": 1800005400
            }
          ]
        }
      ]
    }
    """#
}
