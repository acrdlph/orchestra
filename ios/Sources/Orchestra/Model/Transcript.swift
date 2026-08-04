import Foundation

/// The full transcript, as `orchestra.sessionlog` puts it on the wire.
///
/// **This is the other reader, not a better `/api/chat`.** `ChatTranscript` is
/// the board's drawer: forty turns, every newline collapsed to a space, each one
/// cut at 900 characters, tool traffic absent entirely, and a truncation the
/// client can only INFER from a trailing `…`. It stays exactly as it is.
///
/// These two routes answer the other question — *what did the terminal show* —
/// and they answer it with the opposite policy:
///
/// * **newlines survive** (`format=raw` strips ANSI and nothing else);
/// * **tool calls and results are entries of their own**, paired on
///   `tool_use.id -> tool_result.tool_use_id`, so a result carries the tool's
///   NAME;
/// * **machine text is MARKED, never dropped** — `meta`, with `why` naming the
///   rule that fired — because the terminal showed it and the client, not the
///   server, decides what to collapse;
/// * **truncation is a real field.** `truncated` is the only signal, `chars` is
///   the true length, and **no ellipsis is appended** — so prose that genuinely
///   ends in `…` arrives `truncated: false` and the guess that
///   `ChatMessage.serverTruncated` has to make is not made here.
///
/// **It answers 200 for a failure**, like every other read on this server:
/// `{"ok": false, "error": "unknown account x"}`. `ok` is the status, not the
/// HTTP line.
public struct TranscriptPage: Sendable, Equatable, Decodable {
    public let ok: Bool
    /// The server's own sentence. One of `unknown account <name>`,
    /// `transcript not found`, `need account & sid`, `bad sid`, `bad limit`,
    /// `bad before`, `bad format`, `unknown route`, and — on the `/at/` route —
    /// `no entry at that offset`, `bad off`, `bad i`.
    public let error: String?
    public let sid: String?
    public let account: String?
    public let format: String?
    public let messages: [TranscriptEntry]
    /// False only when byte 0 was actually reached. It fires exactly once per
    /// walk backwards, and it is the only thing that may draw
    /// `— start of transcript —`.
    public let hasMoreBefore: Bool
    /// The `off` of the OLDEST message on this page, to be passed back as
    /// `?before=` — **exclusive**, so nothing duplicates and nothing is skipped.
    /// Null when byte 0 was reached.
    public let cursorBefore: Int?
    /// Present on `/messages/at/{off}` only: the offset that was read.
    public let off: Int?
    /// `(dev, ino, size, mtime_ns)`. See `TranscriptFile` — this is the whole
    /// compaction defence.
    public let file: TranscriptFile?

    public init(ok: Bool, error: String? = nil, sid: String? = nil,
                account: String? = nil, format: String? = nil,
                messages: [TranscriptEntry] = [], hasMoreBefore: Bool = false,
                cursorBefore: Int? = nil, off: Int? = nil,
                file: TranscriptFile? = nil) {
        self.ok = ok
        self.error = error
        self.sid = sid
        self.account = account
        self.format = format
        self.messages = messages
        self.hasMoreBefore = hasMoreBefore
        self.cursorBefore = cursorBefore
        self.off = off
        self.file = file
    }

    enum CodingKeys: String, CodingKey {
        case ok, error, sid, account, format, messages, off, file
        case hasMoreBefore = "has_more_before"
        case cursorBefore = "cursor_before"
    }

    /// **Every field is optional at the decoder, and that is the house rule, not
    /// caution.** `turn_ended` was absent from three sessions in a live board and
    /// a non-optional `Bool` took the whole 38 KB payload with it (ios/README,
    /// wire finding 2). The same shape here would empty a transcript screen for
    /// a field nobody reads.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ok = try c.decodeIfPresent(Bool.self, forKey: .ok) ?? false
        error = try c.decodeIfPresent(String.self, forKey: .error)
        sid = try c.decodeIfPresent(String.self, forKey: .sid)
        account = try c.decodeIfPresent(String.self, forKey: .account)
        format = try c.decodeIfPresent(String.self, forKey: .format)
        messages = try c.decodeIfPresent([TranscriptEntry].self, forKey: .messages) ?? []
        hasMoreBefore = try c.decodeIfPresent(Bool.self, forKey: .hasMoreBefore) ?? false
        cursorBefore = try c.decodeIfPresent(Int.self, forKey: .cursorBefore)
        off = try c.decodeIfPresent(Int.self, forKey: .off)
        file = try c.decodeIfPresent(TranscriptFile.self, forKey: .file)
    }
}

/// What makes a compaction DETECTABLE.
///
/// A transcript is append-only, so a byte offset stays valid — **until the CLI
/// compacts, which rewrites the file whole and voids every offset the client
/// holds at once.** `ino` and `dev` are the identity of the file behind the
/// path; if either moves, the cursors name bytes in a file that no longer
/// exists and the only correct response is to throw them away and reload the
/// newest page. `size` and `mtime_ns` are the cheap append cursor beside it —
/// "has anything happened", not "is this the same file".
public struct TranscriptFile: Sendable, Equatable, Decodable {
    public let size: Int
    public let ino: Int
    public let dev: Int
    public let mtimeNs: Int

    public init(size: Int, ino: Int, dev: Int, mtimeNs: Int) {
        self.size = size
        self.ino = ino
        self.dev = dev
        self.mtimeNs = mtimeNs
    }

    enum CodingKeys: String, CodingKey {
        case size, ino, dev
        case mtimeNs = "mtime_ns"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        size = try c.decodeIfPresent(Int.self, forKey: .size) ?? 0
        ino = try c.decodeIfPresent(Int.self, forKey: .ino) ?? 0
        dev = try c.decodeIfPresent(Int.self, forKey: .dev) ?? 0
        mtimeNs = try c.decodeIfPresent(Int.self, forKey: .mtimeNs) ?? 0
    }

    /// **Both halves, never just the inode.** An inode number is unique per
    /// device, not globally, and a Claude home on an external volume or a
    /// container mount is a different `dev` with a colliding `ino` — which is
    /// exactly the case where holding the old offsets renders somebody else's
    /// bytes.
    public func isSameFile(as other: TranscriptFile) -> Bool {
        ino == other.ino && dev == other.dev
    }

    /// Whether anything was appended. The cheap "is there new output" check that
    /// costs one small request instead of a page.
    public func grew(from other: TranscriptFile) -> Bool {
        size != other.size || mtimeNs != other.mtimeNs
    }
}

/// One block of one JSONL line.
///
/// **A line is not a message and the id is `(off, i)`.** One `assistant` entry
/// carries thinking, prose and several `tool_use` blocks; one `user` entry
/// carries several `tool_result`s. `off` alone names the line, so a `ForEach`
/// keyed on it collapses an entire turn into one row and SwiftUI reuses the
/// wrong view for the rest.
public struct TranscriptEntry: Sendable, Equatable, Decodable, Identifiable {
    /// The byte offset of the JSONL line this block came from.
    public let off: Int
    /// The block's index **within that line**, counted over blocks and not over
    /// emitted messages — so `(off, i)` names the same thing in `raw` and in
    /// `clean`, and `?i=` on the uncapped route opens the block that was tapped.
    public let i: Int
    public let role: TranscriptRole
    /// Newlines PRESERVED in `format=raw`. Cut at 4,000 characters on the paged
    /// route and at 256 KB on `/at/` — **with no ellipsis appended**.
    public let text: String
    /// **The only truncation signal there is.** Never infer from a trailing `…`:
    /// real prose ends in one and arrives `false`.
    public let truncated: Bool
    /// The true length before any cut, in the same units the server counted:
    /// Python's `len(str)`, which is Unicode scalars. See `hiddenScalars`.
    public let chars: Int
    /// ISO-8601 with a `Z`, straight off the entry, and nullable.
    public let ts: String?
    /// May be dimmed or collapsed. **Never dropped** — the terminal showed it.
    public let meta: Bool
    public let model: String?
    /// Present only when `meta` is true, and it names the rule that fired.
    public let why: MetaReason?
    /// Present only on `tool_use` / `tool_result`.
    public let tool: ToolRef?

    /// `(off, i)`. A struct rather than a string so a test cannot pass a
    /// plausible-looking id that names nothing.
    public struct ID: Hashable, Sendable, Comparable {
        public let off: Int
        public let i: Int
        public init(off: Int, i: Int) {
            self.off = off
            self.i = i
        }
        public static func < (a: ID, b: ID) -> Bool {
            a.off == b.off ? a.i < b.i : a.off < b.off
        }
    }

    public var id: ID { ID(off: off, i: i) }

    public init(off: Int, i: Int, role: TranscriptRole, text: String,
                truncated: Bool = false, chars: Int? = nil, ts: String? = nil,
                meta: Bool = false, model: String? = nil,
                why: MetaReason? = nil, tool: ToolRef? = nil) {
        self.off = off
        self.i = i
        self.role = role
        self.text = text
        self.truncated = truncated
        self.chars = chars ?? text.unicodeScalars.count
        self.ts = ts
        self.meta = meta
        self.model = model
        self.why = why
        self.tool = tool
    }

    enum CodingKeys: String, CodingKey {
        case off, i, role, text, truncated, chars, ts, meta, model, why, tool
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        off = try c.decodeIfPresent(Int.self, forKey: .off) ?? 0
        i = try c.decodeIfPresent(Int.self, forKey: .i) ?? 0
        role = TranscriptRole(try c.decodeIfPresent(String.self, forKey: .role) ?? "")
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        truncated = try c.decodeIfPresent(Bool.self, forKey: .truncated) ?? false
        chars = try c.decodeIfPresent(Int.self, forKey: .chars) ?? 0
        ts = try c.decodeIfPresent(String.self, forKey: .ts)
        meta = try c.decodeIfPresent(Bool.self, forKey: .meta) ?? false
        model = try c.decodeIfPresent(String.self, forKey: .model)
        why = (try c.decodeIfPresent(String.self, forKey: .why)).map(MetaReason.init)
        tool = try c.decodeIfPresent(ToolRef.self, forKey: .tool)
    }

    /// How much of this block is not on screen, in the server's own units.
    ///
    /// **`unicodeScalars.count`, not `count`.** `chars` is Python's `len(text)`
    /// and `text[:cap]` is a code-point slice; Swift's `String.count` counts
    /// grapheme clusters, so an emoji or a combining accent would make a
    /// complete entry look short by several characters and invent a cut that
    /// never happened.
    public var hiddenScalars: Int {
        max(0, chars - text.unicodeScalars.count)
    }

    public var timestamp: Date? { ts.flatMap(ChatMessage.parse) }

    /// Whether this block is a tool call or its result. **Tool entries are never
    /// `meta`** — they are primary content, and the server marks them so.
    public var isTool: Bool { role == .toolUse || role == .toolResult }
}

/// The five roles `sessionlog._role` emits, plus the one this client keeps for a
/// role a future CLI invents. An unknown role renders as `system` rather than
/// throwing the page away.
public enum TranscriptRole: String, Sendable, Equatable, CaseIterable {
    case user
    case assistant
    case toolUse = "tool_use"
    case toolResult = "tool_result"
    case system
    /// Not on the wire. A role this build does not know.
    case unknown = ""

    public init(_ raw: String) {
        self = TranscriptRole(rawValue: raw) ?? .unknown
    }

    /// What the entry's header says. `unknown` says the server's word would be
    /// better than a guess, but there is no word to say — so it reads as the
    /// harness, which is where every unrecognised entry has always come from.
    public var label: String {
        switch self {
        case .user: "you"
        case .assistant: "agent"
        case .toolUse: "tool"
        case .toolResult: "result"
        case .system, .unknown: "system"
        }
    }
}

/// Why an entry is `meta` — the rule that fired, as the server named it.
///
/// **`sidechain` outranks everything.** `_entry_messages` resolves the
/// precedence server-side (`sidechain` → `isMeta` → `system`), so a sidechain
/// `tool_result` is subagent work first and a tool result second, and that is
/// the fact a client collapses on.
public enum MetaReason: Sendable, Equatable, Hashable {
    /// Subagent work, inlined into the main transcript.
    case sidechain
    case isMeta
    case machineText
    case thinking
    case system
    case summary
    case attachment
    /// The block was an image; the text is the literal `[image]`.
    case image
    /// A reason this build does not know. Kept verbatim so a screen can still
    /// name it rather than pretending the entry has no reason.
    case other(String)

    public init(_ raw: String) {
        switch raw {
        case "sidechain": self = .sidechain
        case "isMeta": self = .isMeta
        case "machine-text": self = .machineText
        case "thinking": self = .thinking
        case "system": self = .system
        case "summary": self = .summary
        case "attachment": self = .attachment
        case "image": self = .image
        default: self = .other(raw)
        }
    }

    /// The wire's own spelling.
    public var raw: String {
        switch self {
        case .sidechain: "sidechain"
        case .isMeta: "isMeta"
        case .machineText: "machine-text"
        case .thinking: "thinking"
        case .system: "system"
        case .summary: "summary"
        case .attachment: "attachment"
        case .image: "image"
        case .other(let s): s
        }
    }

    /// A word for a header line, in this app's voice.
    public var label: String {
        switch self {
        case .sidechain: "subagent"
        case .isMeta: "harness"
        case .machineText: "machine text"
        case .thinking: "thinking"
        case .system: "system"
        case .summary: "summary"
        case .attachment: "attachment"
        case .image: "image"
        case .other(let s): s
        }
    }
}

/// The tool a `tool_use` called, or that a `tool_result` came back from.
public struct ToolRef: Sendable, Equatable, Decodable {
    /// **Nullable, and a null is not a defect.** A `tool_result` whose matching
    /// `tool_use` fell outside the read window has no name the server can prove,
    /// and it says null rather than inventing one. A screen says `tool`.
    public let name: String?
    public let id: String?
    /// `nil` on a `tool_use` — nothing has come back yet. On a `tool_result`,
    /// `false` means the tool reported an error (`is_error`, or the
    /// `<tool_use_error>` marker inside the body).
    public let ok: Bool?

    public init(name: String?, id: String?, ok: Bool?) {
        self.name = name
        self.id = id
        self.ok = ok
    }

    enum CodingKeys: String, CodingKey { case name, id, ok }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        id = try c.decodeIfPresent(String.self, forKey: .id)
        ok = try c.decodeIfPresent(Bool.self, forKey: .ok)
    }

    /// What to call it on screen. Never a guess — see `name`.
    public var display: String { name ?? "tool" }
}
