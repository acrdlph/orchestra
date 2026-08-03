import Foundation

/// The demo fleet's clock, and the one rule that keeps the demo from looking
/// dead.
///
/// **Every timestamp in the demo payloads is written against a fixed fiction**
/// — `base`, 2027-01-15T08:00:00Z — and is moved onto the reader's own clock at
/// the instant the demo is loaded. A canned board with absolute epochs baked in
/// reads `3d ago` on every row within a week of shipping, and a board where
/// nothing has happened for three days is not a demonstration of a live fleet;
/// it is a screenshot of an abandoned one.
///
/// The rule is one sentence and it is deliberately not a list of key names:
/// **any number inside a 30-day window around `base` is a demo timestamp, and so
/// is any ISO-8601 string that parses to an instant inside it.** A key list is a
/// thing that goes stale the first time the server grows a field; the window
/// cannot, because nothing else on this wire is anywhere near 1.8 × 10⁹ — pids
/// are five or six digits, percentages and cpu are under 100, dirty counts under
/// a thousand, versions under a million. The band is wide enough to hold every
/// age the demo wants (seconds to days, and resets an hour and a half out) and
/// far enough from all of them that no pid can wander into it.
///
/// It runs over the JSON, **before** the decoder — so the demo still arrives at
/// `StreamFrame.decode` / `JSONDecoder` as bytes off a wire, through exactly the
/// path a real frame takes. A demo that bypasses the decoder is a demo of
/// nothing.
public enum DemoClock {
    /// The instant every timestamp in the demo payloads is written against:
    /// `2027-01-15T08:00:00Z`. A round number chosen far from any real capture in
    /// this repository, so a demo stamp can never be mistaken for one.
    public static let base: Double = 1_800_000_000

    /// How far either side of `base` a value is still a demo timestamp.
    public static let window: Double = 30 * 24 * 3600

    public static func isDemoInstant(_ epoch: Double) -> Bool {
        abs(epoch - base) <= window
    }

    /// How far the whole payload moves. Whole seconds, because `git.commit.ts`
    /// is an `Int` on the model side and a fractional double there is a
    /// `typeMismatch` that takes the entire board with it.
    public static func offset(now: Date) -> Double {
        now.timeIntervalSince1970.rounded() - base
    }

    /// Move every demo timestamp in `json` so its distance from `base` becomes
    /// its distance from `now`.
    public static func rewrite(_ json: Data, now: Date) throws -> Data {
        let object = try JSONSerialization.jsonObject(with: json,
                                                      options: [.fragmentsAllowed])
        let moved = shift(object, by: offset(now: now))
        return try JSONSerialization.data(withJSONObject: moved,
                                          options: [.fragmentsAllowed])
    }

    /// Convenience for the payload files, which all hold their JSON as a raw
    /// string literal rather than as a bundle resource.
    public static func rewrite(_ json: String, now: Date) throws -> Data {
        try rewrite(Data(json.utf8), now: now)
    }

    static func shift(_ value: Any, by delta: Double) -> Any {
        if let object = value as? [String: Any] {
            return object.mapValues { shift($0, by: delta) }
        }
        if let array = value as? [Any] {
            return array.map { shift($0, by: delta) }
        }
        if let number = value as? NSNumber {
            // A JSON `true` bridges to an NSNumber too. Its `doubleValue` is 1,
            // which is nowhere near the band, so it falls through unchanged and
            // keeps its boolean identity through re-serialisation.
            let x = number.doubleValue
            guard isDemoInstant(x) else { return number }
            return NSNumber(value: Int((x + delta).rounded()))
        }
        if let text = value as? String, let moved = shiftedISO(text, by: delta) {
            return moved
        }
        return value
    }

    /// The second representation of the same rule. `/api/chat` stamps every turn
    /// with an ISO-8601 string rather than an epoch (`ChatMessage.ts`), so the
    /// transcript would sit at a fixed 2027 wall clock while the board ticked.
    /// Returns nil for any string that is not an in-window instant, which is
    /// every other string in the payloads.
    static func shiftedISO(_ text: String, by delta: Double) -> String? {
        guard text.count >= 20, text.hasSuffix("Z"),
              let parsed = ChatMessage.parse(text),
              isDemoInstant(parsed.timeIntervalSince1970) else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: parsed.addingTimeInterval(delta))
    }
}
