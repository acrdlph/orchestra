import Foundation

/// `GET /api/chat?account=&sid=`, canned — one transcript per session on the
/// demo board.
///
/// **Every session on the demo board has one**, and that is the point: the chat
/// screen is the one the App Store review notes have to explain (it is why the
/// age rating declares no messaging), so a reviewer who taps any row must land on
/// a conversation rather than on an empty state. The two that matter most — the
/// session that NEEDS ANSWER and the one that is BLOCKED — end on the agent's own
/// question, so the screen shows what the app is for.
///
/// The payload is shaped exactly like the server's, including the three
/// properties `ChatMessage` documents and this codebase had to learn:
///
/// * `role` is **`you`**, not `user` — the server's own spelling;
/// * turns arrive as **one run-on paragraph** (`transcripts._clean` destroys
///   newlines), so nothing here contains one either;
/// * `ts` is an **ISO-8601 string**, nullable — and it is moved onto the
///   reader's clock by the same `DemoClock` rule that moves the board's epochs,
///   so the transcript and the row above it agree about when things happened.
///
/// Slash-commanded turns are absent, as they are on the real wire (`_real_prompt`
/// filters them), so this is not a complete record — exactly like the real one.
public enum DemoChat {
    /// One session's conversation, or nil for a sid the demo does not know.
    public static func transcript(sid: String, now: Date = Date()) throws -> ChatTranscript? {
        try all(now: now)[sid]
    }

    public static func all(now: Date = Date()) throws -> [String: ChatTranscript] {
        try JSONDecoder().decode([String: ChatTranscript].self,
                                 from: DemoClock.rewrite(json, now: now))
    }

    static let json = #"""
    {
      "9c1f4a2e-7b30-4c58-9a11-2d6e83f0b415": {
        "ok": true,
        "error": null,
        "messages": [
          {"role": "you", "text": "put the incremental reindex behind a flag and measure it against the full pass", "ts": "2027-01-15T07:20:00.000Z"},
          {"role": "agent", "text": "Starting from the measurement, since the current pass is the only baseline we have: a full reindex is 4m12s and holds the write lock for 38s of it. I'll build the incremental path behind SEARCH_INCREMENTAL_REINDEX and run both against the same fixture set.", "ts": "2027-01-15T07:21:00.000Z"},
          {"role": "agent", "text": "The shard map now rebuilds from the write log rather than from a full scan, so a reindex touches only the shards a write actually landed in. On the fixture corpus that is 7 shards out of 96, and the lock is held for 0.4s instead of 38s.", "ts": "2027-01-15T07:35:00.000Z"},
          {"role": "you", "text": "does it stay correct if two writes hit the same shard while the reindex is running", "ts": "2027-01-15T07:36:00.000Z"},
          {"role": "agent", "text": "It does now — it did not. The first version read the write log once and rebuilt from that snapshot, so a write that landed mid-rebuild was dropped until the next pass. It reads the log position before and after and re-runs any shard whose position moved; the test that catches the old behaviour is in test_reindex_concurrent.py.", "ts": "2027-01-15T07:51:00.000Z"},
          {"role": "you", "text": "good. what is left", "ts": "2027-01-15T07:55:00.000Z"},
          {"role": "agent", "text": "Only the nightly full pass. It costs 4m12s of lock-free work every night and, with the incremental path correct, it is a safety net rather than a mechanism. Before I delete it: keep it as a safety net, or remove it outright?", "ts": "2027-01-15T07:59:13.000Z"}
        ]
      },

      "27b8e5d3-04ac-4e19-8f77-b1c0a92d6e40": {
        "ok": true,
        "error": null,
        "messages": [
          {"role": "you", "text": "before changing anything, measure the pass we already have", "ts": "2027-01-15T04:05:00.000Z"},
          {"role": "agent", "text": "Measured on the fixture corpus, three runs: 4m12s, 4m09s, 4m14s. The write lock is held for 38s of each — the shard map rebuild, not the indexing. Notes are in docs/search-reindex.md with the raw timings.", "ts": "2027-01-15T04:13:40.000Z"}
        ]
      },

      "b430e7c9-51d2-4f8a-b6e3-70c95a1d8226": {
        "ok": true,
        "error": null,
        "messages": [
          {"role": "you", "text": "reproduce the double charge first, then fix it", "ts": "2027-01-15T07:27:00.000Z"},
          {"role": "agent", "text": "Reading the retry path. The budget is stored per worker process, so two workers replaying the same event each get a fresh budget and both call capture. That would explain a duplicate without any provider-side fault.", "ts": "2027-01-15T07:50:00.000Z"},
          {"role": "agent", "text": "I can reproduce it against the replay harness, but the harness wants PROVIDER_SANDBOX_KEY and I cannot read it from this environment. Paste it here, or tell me to skip the replay and rely on the unit test that fakes the second worker.", "ts": "2027-01-15T07:57:52.000Z"}
        ]
      },

      "4f6a1d08-9e77-42b1-a530-cc81f7b2e934": {
        "ok": true,
        "error": null,
        "messages": [
          {"role": "you", "text": "guest checkout, end to end, and don't touch the payment step", "ts": "2027-01-15T07:18:00.000Z"},
          {"role": "agent", "text": "Payment step untouched. The order gets a claim token at creation; signing up later with the same email attaches the order to the new account. Two things I want checked in parallel, so I have sent subagents at them: the token expiry rules, and whether the address form can be reused as-is.", "ts": "2027-01-15T07:22:00.000Z"},
          {"role": "agent", "text": "Subagent: the claim token should outlive the session cookie, or a closed tab loses the order. Adopting that — token is 30 days, cookie stays at session.", "ts": "2027-01-15T07:56:00.000Z"},
          {"role": "agent", "text": "Rewriting the order summary while they finish. It currently assumes an account exists in three places.", "ts": "2027-01-15T07:59:51.000Z"}
        ]
      },

      "e18c5b62-3a0d-47f6-9c24-58ba0d71ff03": {
        "ok": true,
        "error": null,
        "messages": [
          {"role": "you", "text": "write fixtures for the cart before we start on checkout", "ts": "2027-01-15T00:22:00.000Z"},
          {"role": "agent", "text": "Done — an empty cart, a single line, a twenty-line cart, and one with a line whose product has since been deleted, which is the case the old fixtures never had.", "ts": "2027-01-15T00:40:00.000Z"}
        ]
      },

      "7d2e9105-6c48-4a3b-8e10-fd39b64c02a7": {
        "ok": true,
        "error": null,
        "messages": [
          {"role": "you", "text": "make the 429s say when to retry", "ts": "2027-01-15T06:40:00.000Z"},
          {"role": "agent", "text": "Every 429 now carries RateLimit-Limit, RateLimit-Remaining, RateLimit-Reset and a Retry-After, taken from the same window the limiter decided on rather than recomputed at the edge, so the header can never disagree with the refusal.", "ts": "2027-01-15T07:44:00.000Z"},
          {"role": "agent", "text": "Contract test covers all three windows — per-second, per-minute and the burst bucket. Anything else on the gateway, or shall I close this out?", "ts": "2027-01-15T07:53:48.000Z"}
        ]
      },

      "a0539f74-2b6e-4d81-93cf-1e7a48d5c6b2": {
        "ok": true,
        "error": null,
        "messages": [
          {"role": "you", "text": "no bullet points that just restate the commit subject", "ts": "2027-01-15T06:55:00.000Z"},
          {"role": "agent", "text": "Agreed — a note is worth writing only if it says what changed for someone using the thing. Six of the eleven entries are rewritten that way; the other five are genuinely internal and I would drop them rather than pad them.", "ts": "2027-01-15T07:10:00.000Z"},
          {"role": "agent", "text": "Stopping here: this account is out of weekly usage. The draft is saved in NOTES-1.4.md and nothing is committed.", "ts": "2027-01-15T07:14:00.000Z"}
        ]
      },

      "6cb17e40-8d95-4f23-b70a-24e9c3081d5f": {
        "ok": true,
        "error": null,
        "messages": [
          {"role": "agent", "text": "Merged and pushed. Every bespoke pixel value is gone; the two scales live in tokens.json and the linter fails a raw value in a style file.", "ts": "2027-01-14T10:00:00.000Z"}
        ]
      }
    }
    """#
}
