import Foundation

/// One request, with its deadline derived rather than guessed.
///
/// Timeouts are per-route because the routes are not alike: `/api/state` is a
/// 0.8 ms dict read off a background sweep and anything past a few seconds is a
/// transport problem, whereas a cold Network Extension tunnel needs time to wake
/// after foregrounding, which is why the floor is 5 s and not 2.
public struct Endpoint: Sendable {
    public enum Method: String, Sendable { case get = "GET", post = "POST" }

    public let method: Method
    public let path: String
    public let query: [URLQueryItem]
    public let body: Data?
    public let timeout: TimeInterval
    /// `/api/health` and `POST /api/v1/pair` are the server's only two exempt
    /// routes, and sending a token to them is pointless rather than harmful.
    /// Marking them keeps an unpaired app from looking like a broken paired one.
    public let requiresToken: Bool
    /// The wire-idempotency identity for THIS user action, or `nil` for a read.
    ///
    /// Minted once when the mutation is constructed (see `mutation` /
    /// `freshIdempotency`) and carried verbatim into every `urlRequest` built
    /// from this value, so a `URLSession`-level retry re-sends the **same** key
    /// and the server dedupes it rather than launching a second agent (API.md
    /// §4). A fresh user action mints a fresh key.
    public let idempotency: Idempotency?
    /// Whether every query value must be percent-encoded down to the unreserved
    /// set, rather than left to `URLComponents`.
    ///
    /// **`URLComponents.queryItems` does not encode `+`**, and the routes that
    /// read their query with Python's `parse_qs` decode a literal `+` as a
    /// space. A Claude-home label is user-chosen — `.claude-work stuff` is a
    /// directory somebody can make — so an account that contains a `+` would
    /// match nothing on the far side and the screen would show
    /// `unknown account …` for an account that exists. Space is handled by
    /// `URLComponents` (`%20`); `+` is not, which is why this is not "the
    /// default is fine". It is opt-in rather than global because the OLDER
    /// routes are read with `re.search` off the RAW path and never
    /// percent-decoded at all (ios/README wire finding 22) — encoding for those
    /// would break a case that works today.
    public let strictQueryEncoding: Bool

    /// `Idempotency-Key` (a client UUID) and `Idempotency-Issued-At` (a float
    /// epoch, the moment the user committed), the pair API.md §4.1 requires on
    /// every mutation. Bundled so the two are minted and travel together.
    public struct Idempotency: Sendable, Equatable {
        public let key: String
        public let issuedAt: Double
        public init(key: String, issuedAt: Double) {
            self.key = key
            self.issuedAt = issuedAt
        }
    }

    public init(method: Method, path: String, query: [URLQueryItem] = [],
                body: Data? = nil, timeout: TimeInterval, requiresToken: Bool,
                idempotency: Idempotency? = nil,
                strictQueryEncoding: Bool = false) {
        self.method = method
        self.path = path
        self.query = query
        self.body = body
        self.timeout = timeout
        self.requiresToken = requiresToken
        self.idempotency = idempotency
        self.strictQueryEncoding = strictQueryEncoding
    }

    /// A fresh idempotency identity for one user action. The key is minted here,
    /// once; reusing this `Endpoint` (a `URLSession` retry) re-sends it, and a
    /// new user action calls this again for a new key — never regenerate on
    /// retry (API.md §4.1). `issuedAt` is the client wall clock as a float
    /// epoch; it is NOT yet skew-corrected against the server's `at` (§6.5) —
    /// that correction lives above this layer.
    static func freshIdempotency() -> Idempotency {
        Idempotency(key: UUID().uuidString, issuedAt: Date().timeIntervalSince1970)
    }

    /// A POST that changes the world: a JSON body and a fresh idempotency key.
    /// Every mutation goes through here so none can forget either half.
    static func mutation(path: String, body: Data, timeout: TimeInterval,
                         requiresToken: Bool = true) -> Endpoint {
        Endpoint(method: .post, path: path, body: body, timeout: timeout,
                 requiresToken: requiresToken, idempotency: freshIdempotency())
    }

    /// A cold tunnel wake-up is the thing this number exists to survive.
    public static let probeDeadline: TimeInterval = 5

    public static let health = Endpoint(method: .get, path: "/api/health",
                                        timeout: probeDeadline, requiresToken: false)

    public static let state = Endpoint(method: .get, path: "/api/state",
                                       timeout: 8, requiresToken: true)

    /// `GET /api/events` — the stream.
    ///
    /// **The timeout is 70 s and it is the most load-bearing number in this
    /// file.** `URLRequest.timeoutInterval` is not a deadline on the response;
    /// it is the maximum silence between packets. orchestra writes `: keepalive`
    /// only after `sse_keepalive_s` — **25 s** — of a composed view that has not
    /// changed, which on a quiet fleet is the only traffic on the socket. The
    /// board's normal request timeout is 10 s, so a stream opened on the normal
    /// session would be torn down by the phone every ten seconds of quiet,
    /// reconnected, torn down again — and the symptom is a board that looks
    /// perfect and burns a subscriber slot on a loop. 70 s is two keepalives
    /// plus slack, so a stream dies only when two consecutive keepalives are
    /// missed, which is a real death.
    public static let events = Endpoint(method: .get, path: "/api/events",
                                        timeout: 70, requiresToken: true)

    /// `GET /api/chat?account=&sid=` — the last 40 turns of one conversation.
    ///
    /// Identity-addressed like every other session-scoped route (ADR 0008): a
    /// pid does not appear, and could not be used if it did.
    public static func chat(account: String, sid: String) -> Endpoint {
        Endpoint(method: .get, path: "/api/chat",
                 query: [URLQueryItem(name: "account", value: account),
                         URLQueryItem(name: "sid", value: sid)],
                 timeout: 10, requiresToken: true)
    }

    // MARK: - The full transcript
    //
    // Two READS, and they are ordinary token-authenticated GETs: no
    // `Sec-Fetch-Site`, no idempotency key, nothing that makes them acting
    // requests. Like `/api/chat` they answer **200 for a refusal**, with the
    // reason in `{"ok": false, "error": …}` — a status-line-only client renders
    // an empty transcript for a nameable failure.

    /// **The page size, and it is deliberately not the server's default 60.**
    ///
    /// A transcript entry here is not a chat turn: it can be a 4,000-character
    /// tool result, and sixty of those is a quarter-megabyte page decoded on the
    /// main thread of a phone for one screenful of reading. Thirty is two
    /// comfortable screens of scroll-up at a time, and paging again costs one
    /// bounded 512 KB window on the server (~4 ms measured against a 103 MB
    /// transcript).
    public static let transcriptPageSize = 30

    /// `GET /api/v1/sessions/{sid}/messages` — one page of the whole transcript,
    /// newest first, walking backwards by byte offset.
    ///
    /// `before` is a byte offset and is **exclusive**: the line at `before`
    /// belongs to the page the caller already holds. Absent, the read ends at
    /// the file's size, which is the newest page.
    ///
    /// The deadline is generous because the server may have to grow its window
    /// past a single 1.2 MB line before it can answer at all.
    public static func sessionMessages(account: String, sid: String,
                                       limit: Int = transcriptPageSize,
                                       before: Int? = nil,
                                       format: String = "raw") -> Endpoint {
        var query = [URLQueryItem(name: "account", value: account),
                     URLQueryItem(name: "limit", value: String(limit)),
                     URLQueryItem(name: "format", value: format)]
        if let before { query.append(URLQueryItem(name: "before", value: String(before))) }
        return Endpoint(method: .get, path: "/api/v1/sessions/\(sid)/messages",
                        query: query, timeout: 20, requiresToken: true,
                        strictQueryEncoding: true)
    }

    /// `GET /api/v1/sessions/{sid}/messages/at/{off}` — one LINE, uncapped.
    ///
    /// The affordance behind `show all`. The cap here is 256 KB instead of
    /// 4,000 characters, `?i=` picks one block out of the line, and `truncated`
    /// still ships because a quarter-megabyte tool result is not hypothetical.
    public static func sessionEntry(account: String, sid: String, off: Int,
                                    i: Int? = nil, format: String = "raw") -> Endpoint {
        var query = [URLQueryItem(name: "account", value: account),
                     URLQueryItem(name: "format", value: format)]
        if let i { query.append(URLQueryItem(name: "i", value: String(i))) }
        return Endpoint(method: .get, path: "/api/v1/sessions/\(sid)/messages/at/\(off)",
                        query: query, timeout: 25, requiresToken: true,
                        strictQueryEncoding: true)
    }

    /// `GET /api/topology` — the branch map.
    ///
    /// **The legacy route, because it is the only one that exists.** `API.md`
    /// §9.7's `GET /api/v1/topology` (with `worktree_id`, `subject_short`, an
    /// `axis` block and a `dropped[]`) is not served — `server.py:335` routes
    /// `/api/topology` alone, to `gitrepo.cached_topology`. Server-side it is ~90
    /// git subprocesses behind a 30 s TTL (`gitrepo.TOPO_TTL_S`), so this is
    /// fetched on appear and on pull-to-refresh, NEVER on a timer (§5.11). The
    /// deadline is generous because a cold cache pays the full sweep.
    public static let topology = Endpoint(method: .get, path: "/api/topology",
                                          timeout: 20, requiresToken: true)

    /// `GET /api/limits`. Without `refresh=1` this is a cache read and is fast;
    /// `refresh=1` shells out to `cclimits` for EVERY account under a 90 s
    /// server-side timeout, which is why this build never sends it. See
    /// `LimitsStore`.
    public static let limits = Endpoint(method: .get, path: "/api/limits",
                                        timeout: 15, requiresToken: true)

    /// The claim. `Content-Type: application/json` is not optional here: the
    /// server refuses any mutation without it with a **415
    /// `content_type_required`**, which is the CSRF guard — a JSON body forces a
    /// preflight this server never answers.
    public static func pair(code: String, label: String, platform: String) throws -> Endpoint {
        let payload: [String: String] = ["code": code, "label": label, "platform": platform]
        let body = try JSONSerialization.data(withJSONObject: payload)
        return Endpoint(method: .post, path: "/api/v1/pair", body: body,
                        timeout: probeDeadline, requiresToken: false)
    }

    // MARK: - The mutations
    //
    // Every one of them is a POST with a JSON body, and the body is not
    // decoration: a mutation without `Content-Type: application/json` is refused
    // **415 `content_type_required`** before it reaches a handler. That is the
    // CSRF guard, verified by sending one without.
    //
    // Each now carries an `Idempotency-Key` (a fresh client UUID) and
    // `Idempotency-Issued-At`, the client half of the wire-idempotency contract
    // the server ships (API.md §4): a retry of the SAME request — a `URLSession`
    // resend, a background relaunch — replays the stored result instead of
    // launching a second agent in the worktree. The key is minted once, when the
    // mutation is built (`mutation`), and is stable for the life of that value;
    // a new user action builds a new mutation and so mints a new key.

    /// `POST /api/send` — type into an agent's terminal.
    ///
    /// **Addressed by `sid` + `account`, and the pid is not sent at all.** Not
    /// merely "not required": `identity.resolve` treats a pid as a hint and
    /// cross-checks it against the session it names, so sending one can only ever
    /// turn a working request into `identity_gone`. `worktree` rides along as a
    /// second assertion the server checks for free — the qualified card key
    /// `<node>/<worktree>` since ADR 0016 (every acting route accepts it in this
    /// existing parameter; a bare name still means "the board's own node", but
    /// this client always sends the key).
    ///
    /// The deadline is 25 s because the osascript path has a 10 s subprocess
    /// timeout inside a `claude_processes()` scan that can itself take seconds.
    public static func send(account: String, sid: String, worktree: String,
                            text: String) throws -> Endpoint {
        let payload: [String: String] = ["account": account, "sid": sid,
                                         "worktree": worktree, "text": text]
        return mutation(path: "/api/send",
                        body: try JSONSerialization.data(withJSONObject: payload),
                        timeout: 25)
    }

    /// `POST /api/dispatch` — launch a mission. **Spends real money.**
    ///
    /// `model` and `effort` are both required and the server says so rather than
    /// guessing (*"pick a model and an effort first — routing is deterministic,
    /// nothing is chosen for you"*). `worktree` and `account` are optional and
    /// `nil` means "you pick" — the server's `_pick_defaults` is the only picker,
    /// and the client does not mirror it. A chosen `worktree` is the qualified
    /// card key (the picker's values come from `free_worktrees`, which carries
    /// keys since ADR 0016).
    ///
    /// Returns fast — the work runs on a background thread — so the deadline is
    /// short. It is the POLL that waits.
    public static func dispatch(mission: String, worktree: String?, account: String?,
                                model: String, effort: String,
                                forceModel: Bool) throws -> Endpoint {
        var payload: [String: Any] = ["mission": mission, "model": model,
                                      "effort": effort, "force_model": forceModel]
        if let worktree { payload["worktree"] = worktree }
        if let account { payload["account"] = account }
        return mutation(path: "/api/dispatch",
                        body: try JSONSerialization.data(withJSONObject: payload),
                        timeout: 20)
    }

    /// `GET /api/dispatch/status?job=…`. A read, and safe to repeat.
    ///
    /// The server matches the job id with `re.search(r"job=([\w-]+)")`, so an
    /// empty id silently becomes `{"ok": false, "error": "no job"}` rather than a
    /// 400 — driven live.
    public static func dispatchStatus(job: String) -> Endpoint {
        Endpoint(method: .get, path: "/api/dispatch/status",
                 query: [URLQueryItem(name: "job", value: job)],
                 timeout: 10, requiresToken: true)
    }

    /// `POST /api/finish` — the closeout. `worktree` is the qualified card key;
    /// the server's door splits it and hands the bare name to the unchanged
    /// local path (NODES.md §4).
    ///
    /// **120 s**, and that is measured off the server's own worst case rather
    /// than chosen: `start_finish` runs `git fetch origin` (30 s timeout), a
    /// merge-base, a `git status`, a full `claude_processes()` scan and an
    /// osascript send (10 s), all synchronously inside the request.
    public static func finish(worktree: String) throws -> Endpoint {
        let payload: [String: String] = ["worktree": worktree]
        return mutation(path: "/api/finish",
                        body: try JSONSerialization.data(withJSONObject: payload),
                        timeout: 120)
    }

    /// `POST /api/resume/schedule` — arm or re-arm an auto-resume.
    ///
    /// `worktree` is the qualified card key; the schedule comes back on
    /// `/api/state.resumes` under `"<node>/<worktree>|{sid}"`. Keyed by
    /// worktree+sid server-side, so this is the one mutation in the app that is
    /// genuinely idempotent: arming twice replaces.
    ///
    /// Exactly one of `dueAt` (an absolute epoch the user picked) and
    /// `resetsAt` + `delayS` should be meaningful. Sending `resetsAt: nil` with
    /// no `dueAt` gets `{"ok": false, "need_time": true}`, which is a request for
    /// a time, not a failure.
    public static func resumeSchedule(worktree: String, sid: String, account: String,
                                      delayS: Double?, resetsAt: Double?,
                                      dueAt: Double?) throws -> Endpoint {
        var payload: [String: Any] = ["worktree": worktree, "sid": sid,
                                      "account": account]
        if let delayS { payload["delay_s"] = delayS }
        if let resetsAt { payload["resets_at"] = resetsAt }
        if let dueAt { payload["due_at"] = dueAt }
        return mutation(path: "/api/resume/schedule",
                        body: try JSONSerialization.data(withJSONObject: payload),
                        timeout: 15)
    }

    /// `POST /api/resume/cancel`. Idempotent: a second cancel answers
    /// `{"ok": false, "message": "nothing armed for this session"}`, which is a
    /// statement about the world and not an error.
    ///
    /// **Cancel is not an abort.** If `fire_resume` is already executing, the pop
    /// removes the key and the side effect still happens. The sheet says so.
    public static func resumeCancel(worktree: String, sid: String) throws -> Endpoint {
        let payload: [String: String] = ["worktree": worktree, "sid": sid]
        return mutation(path: "/api/resume/cancel",
                        body: try JSONSerialization.data(withJSONObject: payload),
                        timeout: 15)
    }

    // MARK: - Uploads

    /// `POST /api/v1/uploads` — one image from this phone, written to the Mac.
    ///
    /// **Not a `mutation`, and the missing `Idempotency-Key` is the point.** The
    /// route is deliberately absent from `idem.MUTATION_ROUTES` because it does
    /// not need one: the server names the file `sha256(bytes)[:16]`, so a retry
    /// of the same image lands on the same path and writes no second file
    /// (`uploads.py` rule 2). That is exactly the property a key would buy,
    /// without the server storing a copy of the response for an hour. Sending one
    /// anyway would be harmless and would also be a claim about a contract that
    /// is not there.
    ///
    /// `Content-Type: application/json` still is not optional — it is the CSRF
    /// guard, and `urlRequest` sets it for any endpoint with a body.
    /// `strictQueryEncoding` does not apply: there is no query, this is a body.
    ///
    /// `name` is a hint the server **discards**. It rides because a client
    /// naturally has one and it costs a few bytes of the envelope; it never
    /// reaches a filesystem and never decides an extension.
    ///
    /// The deadline is 60 s because the body can be ten megabytes over a tunnel
    /// and `timeoutInterval` is the inter-packet idle timer rather than a whole-
    /// transfer cap — a phone on a slow uplink is still making progress.
    public static func upload(base64 data: String, name: String?) throws -> Endpoint {
        var payload: [String: String] = ["data": data]
        if let name = UploadBudget.clip(name) { payload["name"] = name }
        return Endpoint(method: .post, path: "/api/v1/uploads",
                        body: try JSONSerialization.data(withJSONObject: payload),
                        timeout: 60, requiresToken: true)
    }

    // MARK: - Push

    /// `POST /api/v1/devices/self/push` — register (or re-register) this device's
    /// APNs token.
    ///
    /// **`read`-scoped, not admin**, deliberately: a phone registers its OWN
    /// token, which rotates on every reinstall and iCloud restore, and gating
    /// that behind the Mac-only admin scope would make push structurally
    /// impossible on a phone. The device is identified by the token it presents
    /// (`Handler.device`), never by a path parameter, so this can only ever write
    /// the caller's own endpoint.
    ///
    /// `tzOffsetMin` rides here rather than on the settings route because quiet
    /// hours are evaluated in the device's zone and iOS gives no background
    /// callback for a timezone change — so it is re-sent on every registration,
    /// which is every foreground that finds the token changed or unconfirmed.
    public static func registerPush(token: String, environment: String,
                                    tzOffsetMin: Int, appVersion: String?,
                                    settings: [String: Any]?) throws -> Endpoint {
        var payload: [String: Any] = ["backend": "apns", "token": token,
                                      "environment": environment,
                                      "tz_offset_min": tzOffsetMin]
        if let appVersion { payload["app_version"] = appVersion }
        if let settings { payload["settings"] = settings }
        return mutation(path: "/api/v1/devices/self/push",
                        body: try JSONSerialization.data(withJSONObject: payload),
                        timeout: probeDeadline)
    }

    /// `GET /api/v1/push/status` — is push configured, what did the last send
    /// return, is THIS device registered. The one read the settings screen makes.
    public static let pushStatus = Endpoint(method: .get, path: "/api/v1/push/status",
                                            timeout: probeDeadline, requiresToken: true)

    /// `POST /api/v1/devices/self/settings` — the per-type rules, quiet hours,
    /// privacy and nudge. Only these four keys are accepted; `set_push`'s
    /// allow-list drops anything else.
    public static func pushSettings(body: [String: Any]) throws -> Endpoint {
        mutation(path: "/api/v1/devices/self/settings",
                 body: try JSONSerialization.data(withJSONObject: body),
                 timeout: probeDeadline)
    }

    /// `POST /api/v1/push/mute` — a hard snooze, `minutes` from now, capped
    /// server-side at a week.
    public static func pushMute(minutes: Double) throws -> Endpoint {
        mutation(path: "/api/v1/push/mute",
                 body: try JSONSerialization.data(withJSONObject: ["minutes": minutes]),
                 timeout: probeDeadline)
    }

    /// `POST /api/v1/push/test` — the real thing end to end: composes a
    /// notification, signs a real JWT, does the real HTTP/2 POST. Without a
    /// `.p8` it cannot complete the 200, and it says precisely which piece is
    /// missing — which is the whole point of a test button.
    ///
    /// **A factory, not a `static let`** — because it is a mutation and so must
    /// carry a fresh `Idempotency-Key` per tap. A single stored key would make
    /// the server *replay* the first test's stored body on every later tap and
    /// send no second notification, which defeats a test button. Each press is a
    /// new user action and mints a new key.
    public static func pushTest() -> Endpoint {
        mutation(path: "/api/v1/push/test", body: Data("{}".utf8), timeout: 15)
    }

    /// `POST /api/send`, addressed by `sid` ALONE — the inline-reply path.
    ///
    /// A notification carries no account (`notify.compose` never puts one on the
    /// wire) and does not need to: `identity.resolve` resolves a bare sid to the
    /// live process, and an account would only ever be a corroborator it does not
    /// have. `worktree` rides along when the payload had one, as a second
    /// assertion the server checks for free. This is the same route the chat
    /// composer uses; it simply omits the field it cannot know.
    public static func reply(sid: String, worktree: String?, text: String) throws -> Endpoint {
        var payload: [String: Any] = ["sid": sid, "text": text]
        if let worktree, !worktree.isEmpty { payload["worktree"] = worktree }
        return mutation(path: "/api/send",
                        body: try JSONSerialization.data(withJSONObject: payload),
                        timeout: 25)
    }

    /// RFC 3986 unreserved only — `A-Z a-z 0-9 - . _ ~`. Everything else becomes
    /// `%XX`, including space, `+`, `&`, `=`, `#` and every non-ASCII byte,
    /// which is the only encoding `urllib.parse.parse_qs` reverses exactly.
    static func encodeQueryComponent(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    func urlRequest(base: URL, token: String?) throws -> URLRequest {
        guard var comps = URLComponents(url: base.appendingPathComponent(path),
                                        resolvingAgainstBaseURL: false) else {
            throw OrchestraError.decoding("could not build a URL for \(path)")
        }
        if !query.isEmpty {
            if strictQueryEncoding {
                comps.percentEncodedQueryItems = query.map {
                    URLQueryItem(name: Self.encodeQueryComponent($0.name),
                                 value: $0.value.map(Self.encodeQueryComponent))
                }
            } else {
                comps.queryItems = query
            }
        }
        guard let url = comps.url else {
            throw OrchestraError.decoding("could not build a URL for \(path)")
        }
        var req = URLRequest(url: url)
        req.httpMethod = method.rawValue
        req.timeoutInterval = timeout
        req.httpBody = body
        if body != nil {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if requiresToken, let token, !token.isEmpty {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let idempotency {
            req.setValue(idempotency.key, forHTTPHeaderField: "Idempotency-Key")
            // A float epoch with a fixed '.' — `String(format:)` uses the C
            // locale, so this never becomes "1,78e9" on a comma-decimal phone.
            req.setValue(String(format: "%.3f", idempotency.issuedAt),
                         forHTTPHeaderField: "Idempotency-Issued-At")
        }
        req.setValue("orchestra-ios", forHTTPHeaderField: "User-Agent")
        // Never let a URL cache answer for a board. The whole product is
        // "is this true right now".
        req.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        return req
    }
}
