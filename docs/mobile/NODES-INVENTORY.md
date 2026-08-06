# The Phase 0 inventory — every place a bare worktree name is an identity

**This is Phase 0's specification.** ADR 0016 decides that a card's identity
becomes `<node>/<worktree>`; this file is the enumeration of every site that
assumption touches, produced *before* any of them was edited (the handoff's
opening move), by five parallel readers over the Python, the web boards, the
Swift client, the docs and the tests — then adversarially checked by three
completeness critics. 300 sites. `docs/mobile/NODES.md` holds the design the
sites are resolved against; the per-site note below says what Phase 0 does
there.

Legend — `role`: how the bare name (or path / hostname / pid) is load-bearing
at that site. `key` dict/map key · `lookup` equality selection · `wire-field`
travels on the wire · `route-param` selects in a request · `dedup-key` /
`push-id` dedupe or notification identity · `dom-id` / `ui-id` client
reconciliation identity · `audit-key` written to a log and matched later ·
`path-key` keyed by node-local path · `machine-field` hostname/user ·
`pid` pid treated beyond its node · `sort-key` uniqueness tiebreak ·
`test` a test pinning one of the above · `display-ambiguous` display today,
identity nearby.

Sites marked *stays* are node-local composition: they live inside one
machine's collector and never cross a node boundary, so they keep bare names
by design (NODES.md §4).


## The engine (observer, gitrepo, finish)  (28 sites)


### `orchestra/finish.py`

- **:121** [key] `_closeouts = {}`
  — The two-step flag map is keyed by bare worktree name and read board-side by collect_state; its keys must live in the same namespace as the card key (qualified, or node-local with the observer doing the qualified join) — in the split this map belongs to the collector.
- **:179** [key] `_closeouts.setdefault(name, ts)`
  — CLOSEOUT_STATE persists bare names on disk; whatever namespace _closeouts adopts, the loader needs a migration rule for pre-split entries (drop or requalify) so a restart cannot resurrect a flag onto the wrong node's card.
- **:243** [dedup-key] `_finish_locks = {}                 # worktree name -> threading.Lock`
  — One-finish-in-flight is enforced per bare name; two nodes' same-named worktrees must not share a lock, so the lock key must be the qualified key (board-side) or the map must be per-collector (node-local, where bare stays correct).
- **:392** [audit-key] `worktree=wt_name, path=rel[:200])`
  — The scratch-deletion audit record names the worktree bare; ADR 0016 has each collector audit to its own local log, so bare stays unambiguous node-locally — but Phase 0 (one process) should add the node id to the record so later merged reading stays attributable.
- **:427** [lookup] `return {"worktree": wt_name, "tmux": p.get("tmux_target"), "tty": p.get("tty")}`
  — This address is re-resolved by identity.resolve against wt["name"]/wt["path"] on the machine holding the pid — it must carry the NODE-LOCAL bare name (resolution is node-local by design), so the route boundary must strip the node qualifier before finish runs.
- **:471** [lookup] `wt = next((w for w in gitrepo.discover_worktrees() if w["name"] == wt_name), None)`
  — The route-param resolution: /api/finish's worktree selector arrives here — Phase 0 must resolve the qualified key to (node, local name) at the board/route layer and hand this equality test the local bare name only.
- **:507** [lookup] `reaped = dispatch.reap_dead_sessions(wt_name)`
  — Fleet-session reaping is keyed by the bare name passed onward to dispatch (tmux session naming is node-local); correct as long as this call always runs on the owning node — the qualified→local strip must happen upstream of start_finish.
- **:650** [lookup] `out = dispatch.start_dispatch(brief, worktree=wt_name,`
  — The closeout dispatch selects its target worktree by bare name; same rule — dispatch is node-local actuation, so it must receive the local name after board-side routing by qualified key.

### `orchestra/gitrepo.py`

- **:67** [key] `wts.append({"name": p.name, "path": str(p), "git": str(git_root)})`
  — The origin of the bare name: discovery is genuinely node-local, so `name` stays the local label here, and Phase 0 must decide where the qualified key is minted from it (at card composition/publish) rather than qualifying every internal consumer of this dict.
- **:190** [path-key] `key = origin if rc == 0 and origin else "local:" + w["path"]`
  — The topology group key falls back to a bare local path, which is node-ambiguous the moment topology is served for more than one node — the fallback needs the node id in it (origin-URL groups genuinely span nodes and may stay).
- **:227** [wire-field] `"worktree": w["name"], "branch": br or "?",`
  — map.html uses this field as a join key into the state's cards (byName[b.worktree]) and as the focus/finish button argument, so it must carry the qualified key (or a node field beside it) to keep the join unambiguous.
- **:258** [wire-field] `br("orbital-api", "feat/webhook-retries", 68, 0.35, 14, 6, 12,`
  — demo_topology's worktree labels must match demo_state's qualified card keys or the demo map view's byName join silently breaks.

### `orchestra/observer.py`

- **:220** [wire-field] `**w,`
  — The card spreads the discovery dict verbatim, so `name` is the wire identity clients key on (index.html data-wt); Phase 0 adds a `node` field and the qualified key here while `name` demotes to a node-local label.
- **:246** [lookup] `ts = finish._closeouts.get(c["name"])`
  — This lookup joins the composed card to the closeout flag by bare name; Phase 0 must keep the two in one namespace — either _closeouts adopts the qualified key, or this reads the card's node-local name field while the card's published key is qualified.
- **:250** [pid] `matched = {p["pid"] for c in cards for p in c["live_procs"]}`
  — stays — node-local composition (one collect_state runs on one machine; this pid set never crosses a node).
- **:261** [sort-key] `cards.sort(key=lambda c: (severity(c), c["name"].lower()))`
  — The bare name is the uniqueness tiebreak of the board's triage order; the tiebreak must become the qualified key so two nodes' same-named cards order deterministically.
- **:280** [machine-field] `"hostname": os.uname().nodename,`
  — hostname becomes a per-node LABEL riding beside the persisted node id (ADR 0016: hostnames change and are not unique); the top-level singular field must become node-scoped.
- **:281** [machine-field] `"user": getpass.getuser(),`
  — user is per-machine and must move into the node identity block alongside hostname rather than stay a board-global singular field.
- **:283** [wire-field] `"free_worktrees": [c["name"] for c in cards if c["availability"] == "free"],`
  — index.html reads this list as dispatch targets, so it must carry qualified keys (ADR 0016 says free_worktrees becomes node-qualified) — a bare name here dispatches to whichever node wins the collision.
- **:555** [key] `name — which the rest of the app already treats as impossible, `_closeouts``
  — Snapshot.cards documents duplicate names as impossible and silently collapses them into one dict entry — exactly the multi-node collision; the invariant must be restated for qualified keys and the collapse behavior removed as a safety valve.
- **:854** [pid] `pids = {p["pid"] for c in snap.cards.values() for p in c.get("live_procs", [])}`
  — The kqueue exit-watch set is read from the published snapshot; once the snapshot can hold merged (foreign) cards, this must draw only from the local collector's own composition or it arms EVFILT_PROC on another machine's pids.
- **:1005** [key] `cards = {c["name"]: c for c in state.get("worktrees", [])}`
  — THE site ADR 0016 names: publish must key cards by <node>/<worktree> — with a bare name, two nodes' ConfidAI2 cards overwrite each other in this dict.
- **:1042** [key] `self._hist.append((self._version, tuple(changed)))`
  — The 512-version delta ring stores card names as the changed-key vocabulary (and delta_since treats an unknown key as a card DELETE), so ring entries, _dcards, and the diff at lines 1039-40 must all move to the qualified key atomically with publish.
- **:1191** [wire-field] `"order": list(snap.cards),`
  — The snapshot frame's `order` and `cards` object keys are the client's reconciliation ids (stream.js patches its dict by them); they become qualified keys — this is the breaking wire change the ADR calls out.
- **:1199** [wire-field] `"cards": {k: snap.cards.get(k) for k in keys},   # None = removed`
  — Delta frames name changed cards by key with None meaning delete; the keys become qualified, and a client holding bare-name state across the change must be forced onto the full-snapshot resync path (version bump / cursor invalidation).
- **:1381** [wire-field] `return {"name": name, "path": "/demo/" + name, "git_root": "",`
  — demo_state fabricates cards with bare names and no node; it must fabricate a demo node id and qualified keys so demo mode exercises the exact wire shape (its docstring promise).
- **:1417** [machine-field] `"generated_at": now, "hostname": "starbase", "user": "you",`
  — Demo hostname/user must move to the same node-identity shape the real payload adopts, or demo mode stops matching the wire.
- **:1419** [wire-field] `"free_worktrees": ["voyager-cli", "lander-docs"],`
  — Demo free_worktrees must carry the same qualified keys as the demo cards so the derive-check clients perform (stream.js derives free from cards) still agrees.

## The acting layer (server routes, dispatch, resume, terminal, identity, idem, uploads, auth, pairing)  (35 sites)


### `orchestra/auth.py`

- **:1423** [display-ambiguous] `method=method, path=path[:200], outcome="allow")`
  — No code change — the audited path deliberately embeds the wire's worktree selector as the addressed identity, so audit lines become node-unambiguous the moment the wire address itself is qualified.

### `orchestra/dispatch.py`

- **:119** [lookup] `r["alive"] = r.get("session") in live`
  — Stays in Phase 0 — the alive check matches log rows against THIS machine's tmux sessions; before dispatch logs merge across nodes each row needs a node so foreign rows are never matched against local tmux.
- **:131** [key] `_wt_reservations = {}              # worktree name -> epoch when the hold expires`
  — The §5.6 resource lock is board-level: key reservations by the node-qualified card key so two nodes' same-named worktrees can never share (or steal) one in-flight hold.
- **:179** [lookup] `free = [w for w in state["worktrees"]         if w["availability"] == "free" and w["name"] not in reserved]…`
  — The auto-pick is the free_worktrees consumer ADR 0016 names: it must subtract reservations from and return the node-qualified key, not the bare name.
- **:370** [route-param] `if worktree and not _reserve_worktree(worktree):`
  — The wire `worktree` selector from POST /api/dispatch becomes node-qualified and is used verbatim as the reservation key here.
- **:375** [dedup-key] `job_id = "job-" + time.strftime("%H%M%S") + f"-{_job_seq[0]}"`
  — Stays in Phase 0 (one process), but job ids are per-process mints that collide across nodes — they key _jobs/_store, /api/dispatch/status selection, and notify's dispatch.*|{jid} dedupe keys, so they must become node-scoped before dispatch routes to collectors.
- **:531** [lookup] `wt = next((w for w in gitrepo.discover_worktrees() if w["name"] == worktree), None)`
  — discover_worktrees is node-local: after the board routes on the node half, this equality must match the node-local remainder (or a qualified name once discover carries node).
- **:604** [audit-key] `_append_log(session=name, worktree=worktree, account=account, model=model,             effort=effort, missi…`
  — Dispatch-log rows (also L551) should record the qualified worktree or a node field so a board-served log stays attributable once entries can come from more than one machine.
- **:615** [wire-field] `"session": name, "worktree": worktree, "account": account,`
  — The dispatch result's `worktree` (also L559) is consumed by clients and by notify's job projection — it must carry the qualified key so event/card attribution matches the new card index.
- **:672** [lookup] `return f"{kind}-{session_slug(worktree)}{stamp}"`
  — Stays — node-local composition (tmux session names live on the machine that minted them; reap_dead_sessions' slug match is further guarded by pane_dead, but the slug should be built from the node-local name, never the qualified one).
- **:698** [lookup] `if not m or m.group(1) != slug:`
  — reap_dead_sessions selects a worktree's tmux sessions by equality against session_slug(worktree) (slug bound at :695); mint (session_name, inventoried at :672) and reap must both receive the node-LOCAL bare name — a board-passed qualified "<node>/<wt>" slugs to "node-wt", never matches "mission-wt-*", and dead sessions silently stop being reaped.

### `orchestra/idem.py`

- **:100** [dedup-key] `canon = json.dumps(payload, sort_keys=True) return hashlib.sha256((canon + method + route).encode()).hexdig…`
  — No structural change: the fingerprint hashes whatever payload the mutation routes carry, so once wire worktree fields are qualified the key binds to the qualified intent automatically — but tests pinning fingerprints re-pin, and Phase 2 must relay this same key to the collector unmodified (ADR 0016 step 3).

### `orchestra/identity.py`

- **:83** [lookup] `return next((w for w in gitrepo.discover_worktrees()              if name in (w["name"], w["path"])), None)`
  — _worktree_named matches bare name or node-local path — define resolve's contract as node-local after routing: strip/accept this node's own qualified prefix and refuse another node's, so a qualified address can never silently miss.
- **:147** [lookup] `if worktree and wt and worktree not in (wt["name"], wt["path"]):`
  — This sid-path corroborator equality must tolerate the qualified form, or the moment clients send qualified names every send is refused GONE ("session is in X, not node/X").
- **:181** [lookup] `wt = _worktree_named(worktree)`
  — The place-addressed arm resolves the client's worktree name against local worktrees — same node-strip contract as _worktree_named.

### `orchestra/pairing.py`

- **:439** [machine-field] `"hostname": socket.gethostname(),`
  — Pairing's server facts describe the board machine to the phone — with node identity landing, expose the board's node id here and demote hostname to the label ADR 0016 says it is.

### `orchestra/resume.py`

- **:48** [key] `_resumes = {}                  # "worktree|sid" -> schedule dict`
  — The schedule/dedup key becomes "<node-qualified worktree>|sid" to match the card key; _firing and notify's resume.*|{key} dedupe keys follow it mechanically.
- **:99** [key] `_resumes[f"{r['worktree']}|{r['sid']}"] = r`
  — Persisted schedules in resume.schedule.json must round-trip the qualified name — migrate or deliberately invalidate old bare-name entries on first load after the change.
- **:115** [wire-field] `return {k: dict(r) for k, r in _resumes.items()}`
  — resume_public rides on /api/state keyed by the composite; both web boards and the iOS client parse these keys, so they change inside the same coordinated breaking wire change as cards.
- **:119** [test] `return {"orbital-web|demo-limit-1": {     "worktree": "orbital-web", "sid": "demo-limit-1", ...`
  — Demo data must mint the qualified key/field form so --demo renders under the new scheme and pins the new wire shape.
- **:177** [route-param] `key = f"{worktree}|{sid}"`
  — The wire `worktree` from POST /api/resume/schedule composes the schedule key verbatim — it must arrive node-qualified (and be validated as such once the format lands).
- **:190** [route-param] `key = f"{worktree}|{sid}"`
  — cancel_resume must compose the identical qualified key or an armed schedule becomes uncancellable from the client.
- **:200** [lookup] `card = next((w for w in state["worktrees"] if w["name"] == worktree), None)`
  — _session_on_board selects the card by bare name from board state — must look up by the node-qualified card key once cards are keyed <node>/<worktree>.
- **:426** [pid] `res = terminal.send_to_process(     proc["pid"], msg, sid=sid, account=account, worktree=worktree,     tmux…`
  — Stays in Phase 0 (one node), but the pid/tmux/tty here come off board state — once cards span nodes, fire_resume must route to the owning node rather than resolving a foreign pid against the local process table.
- **:432** [lookup] `wt = next((w for w in gitrepo.discover_worktrees() if w["name"] == worktree), None)`
  — Same as dispatch L531: node-local discover — match the node-local remainder of the qualified key after routing.

### `orchestra/server.py`

- **:409** [wire-field] `body = json.dumps({**observer.cached_state(),                    "resumes": resume.resume_public()}).encode()`
  — /api/state serves both the cards map and the resumes map — the two key formats change together in the one coordinated wire change both clients absorb.
- **:413** [pid] `m = re.search(r"pid=(\d+)", self.path)`
  — Stays — the pid on /api/focus (and in /api/send's payload) is already only a hint checked by identity.resolve; ADR 0016 keeps pids node-local, so no Phase 0 change beyond the address it corroborates becoming qualified.
- **:418** [route-param] `worktree=q.get("wt"), cwd=q.get("cwd"),`
  — GET /api/focus's wt= selector must carry the node-qualified key; the handler routes on the node half and hands the node-local remainder to the local resolver.
- **:977** [route-param] `payload.get("worktree"), payload.get("sid"),`
  — POST /api/resume/schedule's worktree selector becomes node-qualified end to end.
- **:982** [route-param] `result = resume.cancel_resume(payload.get("worktree"), payload.get("sid"))`
  — POST /api/resume/cancel's worktree selector becomes node-qualified end to end.
- **:992** [route-param] `worktree=payload.get("worktree"), cwd=payload.get("cwd"),`
  — POST /api/send's worktree address becomes node-qualified; in Phase 2 the board looks up the owning node from the card index here before forwarding (cwd is node-local too).
- **:996** [route-param] `payload.get("worktree") or "",`
  — POST /api/finish's worktree selector becomes node-qualified (finish.start_finish then needs the node-local name for its git work).
- **:1000** [route-param] `payload.get("mission"), payload.get("worktree") or None,`
  — POST /api/dispatch's worktree selector becomes node-qualified; a null selector makes the pick, which must itself return a qualified key.

### `orchestra/terminal.py`

- **:295** [lookup] `proc, refusal = identity.resolve(pid, **ident)`
  — Stays node-local (both verbs act on the machine holding the pid); Phase 0 must guarantee the worktree ident reaching this call is the node-local form, with the node component consumed by the router above.

### `orchestra/uploads.py`

- **:385** [path-key] `return {"ok": True, "path": str(dest), "bytes": len(raw), "kind": kind,`
  — Stays in Phase 0 (one Mac); the returned absolute path is readable only on this node — before agents span machines the upload must land on, or be scoped to, the node whose agent will read the path.

## Notifications (notify, push payloads)  (10 sites)


### `orchestra/notify.py`

- **:166** [key] `cards = {c["name"]: c for c in snapshot.get("worktrees", [])}`
  — The dict-snapshot fallback must key cards exactly as observer.py:1005 will (the qualified key) — it is the same collision, duplicated.
- **:168** [key] `worktrees[name] = card.get("availability")`
  — The projection's worktrees map is the diff key for worktree.free edges — qualified keys keep two nodes' same-named worktrees from collapsing into one availability cell.
- **:180** [wire-field] `"worktree": name,`
  — Event.worktree inherits this projection value — it must be the qualified key so events, push payloads and thread-ids attribute to the right node's card.
- **:199** [key] `res[key] = {"status": r.get("status"), "worktree": r.get("worktree"),`
  — The projection's resumes map is keyed by the bare "worktree|sid" resume key and diffed by that key at :360 to detect armed/fired/failed edges; it inherits correctness only once resume.py mints node-qualified "<node>/<wt>|sid" keys, so the inventory must own this pass-through.
- **:246** [wire-field] `worktree: str = None`
  — The durable Event record (served by /api/v1/events, persisted in events.log.json) links to a card by this field — qualified going forward, and the client match must tolerate old bare-name events still in the retained log or the log epoch must bump.
- **:366** [dedup-key] `emit("resume.armed", f"resume.armed|{key}", worktree=r["worktree"],`
  — resume.armed/fired/failed dedupe keys (also :369, :372) embed the bare "worktree|sid" key, so two nodes' same-named worktrees collapse to one push condition today; Phase 0 must make the embedded key node-qualified (it follows automatically once resume.py qualifies, and the one-time key change re-arms conditions across the upgrade).
- **:388** [dedup-key] `emit("worktree.free", f"worktree.free|{name}", worktree=name)`
  — worktree.free's dedupe key — also the /api/v1/events/open withdrawal key and the would-be apns-collapse-id — must embed the qualified name or two nodes' frees dedupe/withdraw against each other.
- **:687** [push-id] `"thread-id": f"{server}|{event.worktree or '—'}",`
  — The notification thread id groups the lock screen by worktree — the qualified name (or an explicit node component) keeps two nodes' same-named worktrees in separate threads.
- **:709** [wire-field] `"wt": event.worktree,`
  — The push payload's wt is what the phone navigates and reconciles by — it becomes the qualified card key in the same coordinated change as cards.
- **:1357** [machine-field] `server = getpass.getuser()`
  — The Service's server name (the thread-id namespace and test-push identity) is the Mac's username — Phase 0's persisted node identity should own this label instead of getuser().

## The web board (stream.js, index.html)  (30 sites)


### `index.html`

- **:422** [route-param] `onclick="focusPid(${p.pid}, ${escArg(addr({ wt, cwd, tmux: p.tmux, tty: p.tty }))})"`
  — The /api/focus address carries `wt=` as a bare name (fed `w.name` at lines 430 and 632; fetched at line 768 with pid leading the query) — the address gains a node component so the board routes to the owning collector, with pid demoted to a node-local hint.
- **:517** [key] `let SCHED = {};   // armed auto-resumes, keyed `worktree|sid` (from /api/state)`
  — Wire dict keyed by bare worktree name + sid (server side identical, resume.py:48); the key composed at line 998 and looked up at 999/1052 must become `<node>/<worktree>|sid` on both ends together.
- **:520** [machine-field] `$("brandUser").textContent = `${st.user || "you"}@fleet`;`
  — The board header renders the single machine's user; with per-node identity the state's top-level user/hostname become per-node fields and this brand line must name the board (or the node set), not one collector — inventory caught map/limits/guide brandUser but not index.html's.
- **:524** [key] `REG[`${w.name}|${s.sid}`] = { s, procs: w.live_procs, wt: w.name };`
  — Key REG by the qualified card key (also composed inline at line 596's openChat arg) and store `node` beside `wt`, because every actuation body below reads REG[..].wt back as its wire address.
- **:543** [display-ambiguous] `<div class="sub" title="${esc(freeNames.join(", "))}">${esc(freeNames.join(", ") || "none — everything busy…`
  — free_worktrees arrives node-qualified — render node-grouped or qualified labels so two nodes' identically-named free worktrees are distinguishable in the tile.
- **:545** [machine-field] `<div class="sub">claude processes on ${esc(st.hostname)}</div>`
  — The live-agents tile sums live_procs + other_procs across what will be several nodes under one hostname caption (st.user likewise at line 520's brandUser) — caption must enumerate node labels instead of one hostname.
- **:594** [dom-id] `<button class="abtn resume" data-key="${esc(w.name)}|${esc(s.sid)}" data-until="${s.limit.resets_at}">▶ res…`
  — data-key is read back at line 957 as the REG lookup key — must carry the qualified key so the resume click resolves the right node's session.
- **:596** [dom-id] `<button class="abtn" onclick="openChat(${escArg(`${w.name}|${s.sid}`)})">✉ chat</button>`
  — The chat button mints the REG key from the bare name — must mint `qualifiedKey|sid` in lockstep with REG's construction at :524, or the chat drawer opens the wrong node's same-named worktree.
- **:607** [lookup] `const finArmed = window._armFinish && window._armFinish.wt === w.name && Date.now() < window._armFinish.until;`
  — The finish-arm latch compares a value written from data-wt (:904/:907) against the wire card's name — both sides must become the qualified key together or arming one node's card visually arms its twin on the other node.
- **:635** [dom-id] `<button class="abtn finish ${finArmed ? "armed" : ""}" data-wt="${esc(w.name)}" ${w.closeout_sent ? 'data-c…`
  — data-wt drives the arm/confirm equality (lines 607, 904: `_armFinish.wt === wt`) and is POSTed verbatim as /api/finish `{worktree: wt}` (line 919) — must become the qualified key (or node+name pair) end to end or a same-named card on another node shows armed and finish is ambiguous.
- **:659** [path-key] `st.other_procs.map(p => `<div>⌁ <button class="pidbtn" onclick="focusPid(${p.pid}, ${escArg(addr({ cwd: p.c…`
  — The loose-processes strip is board-level and addresses by cwd (a node-local path — two machines can hold identical paths) with pid on the wire — other_procs entries must carry node and the focus address must include it.
- **:694** [dom-id] `el.dataset.wt = w.name;`
  — The keyed per-card DOM reconciler (names/want/have at 683-703), cardRects movement tracking (line 729), and the click-shield toast naming `card.dataset.wt` (line 753) all key on the bare name — dataset.wt must become the qualified key or two nodes' same-named cards share one element and rewrite each other every frame.
- **:879** [wire-field] `worktree: chatCtx.wt, tmux: p.tmux || null, tty: p.tty || null };`
  — chatAddr's `worktree` selector goes into the /api/send body (line 867, with pid riding as hint) — chatCtx must carry node from REG and the body must be node-qualified so the board forwards to the owning collector under the same idempotency key.
- **:897** [key] `const FIN_PENDING = {};`
  — Refused-close registry keyed by bare name (read 613, delete 623, write 932 from dataset.wt) — key by the qualified card key at all three sites.
- **:919** [wire-field] `body: JSON.stringify({ worktree: wt }) });`
  — POST /api/finish from the board's finish button sends the bare data-wt value; Phase 0 must send the node-qualified id (map.html's identical POST at :449 is inventoried, this one is not).
- **:969** [wire-field] `worktree: r.wt, tmux: t.tmux || null, tty: t.tty || null }, "continue");`
  — 'continue' typed at the wrong node's same-named worktree is an injected instruction — the resume-click send body must carry node (from REG) alongside worktree.
- **:998** [key] `const key = `${w.name}|${s.sid}`;  (schedControls → SCHED[key])`
  — schedControls mints the SCHED lookup key from the bare name; it must match the server's new qualified `worktree|sid` resume key or every armed auto-resume chip vanishes from the card that armed it.
- **:1029** [wire-field] `return { worktree: r.wt, sid: r.s.sid, account: r.s.account,`
  — POST /api/resume/schedule (and cancel at line 1043) select by bare worktree + sid — bodies gain node, and the server's schedule-store keys become node-qualified to match.
- **:1043** [wire-field] `const res = await apiResume("cancel", { worktree: r.wt, sid: r.s.sid });`
  — The resume-cancel body sends REG's bare wt; must carry the qualified id in step with resumeBody (:1029, inventoried) or disarm silently cancels nothing.
- **:1128** [path-key] `const base = (dir || "").split("/").pop();`
  — Account labels derive from node-local config-dir paths and become the dispatch/reserve account selector (option values at 1184, POSTed at 1334) — stays in Phase 0 (one local collector), but flag: accounts are per-node Claude homes and the selector needs node scope when limits merge (Phase 1+).
- **:1144** [display-ambiguous] `return free.length ? free[0].name : null;  (ruleBasedAutoPick)`
  — The composer's auto-pick preview claims to mirror _pick_defaults exactly; once the free set spans nodes the mirror must reproduce the board-level rule and show the qualified name, or the previewed placement is a lie.
- **:1152** [lookup] `...all.map(n => ({ v: n, t: n + (frees.includes(n) ? " · free" : "") }))];`
  — Membership test against free_worktrees by bare name and option values ARE bare names (the auto-pick preview at 1144 likewise returns `free[0].name`, mirroring backend _pick_defaults) — values become qualified keys, the includes() compares them, and the mirrored routing rule goes node-aware.
- **:1260** [lookup] `const keys = Object.keys(REG).filter(k => REG[k].wt === wt);`
  — chatKeyForWorktree selects a session by bare-name equality on REG[..].wt — must match on the qualified identity or the dispatch drawer opens chat on another node's same-named worktree.
- **:1281** [audit-key] `const key = e.alive ? chatKeyForWorktree(e.worktree) : null;`
  — Dispatch-log records carry `worktree` as a bare name and are later matched by it to live sessions — log entries gain node, matching uses the qualified key, and pre-migration rows without node need a stated fallback.
- **:1334** [wire-field] `body: JSON.stringify({ mission, worktree: $("mWt").value, account: $("mAcct").value,`
  — /api/dispatch's `worktree` selector is the picker's bare-name value — must be node-qualified so a mission lands on the intended node's worktree.

### `stream.js`

- **:70** [key] `for (var k in f.cards) {   if (!Object.prototype.hasOwnProperty.call(f.cards, k)) continue;   if (f.cards[k…`
  — The delta frame's `cards` dict keys ARE card identity; the applier is key-opaque so no code change here, but the wire contract under it changes to `<node>/<worktree>` keys and the resync/gap semantics must be re-pinned against qualified keys.
- **:88** [wire-field] `this.order = f.order || Object.keys(this.cards);`
  — `order` entries must become the same qualified keys as `cards` in lockstep; bonus: `<node>/<worktree>` keys are never integer-like, retiring the JSON.parse key-hoisting hazard the comment above this line documents (update that comment).
- **:106** [key] `this.cards[wts[i].name] = wts[i]; this.order.push(wts[i].name);`
  — THE collision site: seed() keys cards by bare `name` from /api/state, so two nodes' ConfidAI2 clobber each other — must key by the node-qualified identity (a `key` field or `node+"/"+name` on each worktree object) so poll-seeded state and stream frames use identical keys.
- **:131** [wire-field] `if (wts[j].availability === "free") free.push(wts[j].name);`
  — free_worktrees is derived from bare names (the exact derivation ADR 0016 names as colliding) — push the qualified key so the derived list matches the server's node-qualified free_worktrees.
- **:272** [machine-field] `side = { user: d.user, hostname: d.hostname, resumes: d.resumes || {} };`
  — user/hostname are singleton machine fields (composed back into state() at lines 135-136) — they become node-scoped labels (board node's, or a per-node map), and the `resumes` dict keys' worktree half becomes node-qualified (server keys them `worktree|sid`, resume.py:48).

## The map and the other pages  (11 sites)


### `guide.html`

- **:282** [machine-field] `.then(s => { document.getElementById("brandUser").textContent = `${s.user || "you"}@fleet`; })`
  — Display only, but consumes the machine-singular `user` field — becomes the board node's label (guide prose's `mission-<worktree>-<time>` tmux names stay node-local: tmux sockets never cross machines).

### `limits.html`

- **:264** [wire-field] `body: JSON.stringify({ account: label, percent: Number(percent) }) });`
  — stays — node-local composition in Phase 0 (limits are the board machine's own accounts); flag for Phase 1+: account labels (and the a.config_dir path shown at 244) are per-node namespaces, so the /api/reserve selector needs node scope when limits merge across nodes.
- **:283** [machine-field] `fetch("/api/state").then(r => r.json()).then(s => { $("brandUser").textContent = `${s.user || "you"}@fleet`…`
  — s.user is a singleton machine field — becomes the board node's label.

### `map.html`

- **:234** [key] `if (state) for (const w of state.worktrees) byName[w.name] = w;`
  — Cross-payload join index: /api/topology branches are joined to /api/state cards by bare name (statusOf(byName[b.worktree]) at 316/348/373, tipFocus at 422) — with two nodes this paints one node's card status onto the other node's branch; both payloads must carry and join on the qualified id.
- **:315** [key] `const key = `b:${b.worktree}`; lookup[key] = b;`
  — Hit-target registry keyed `b:<bare name>` (riders repeat it at 347), written as data-key at 342/364 and read back via dataset at 399/457-459 — the name half becomes the node-qualified id.
- **:316** [lookup] `const st = statusOf(byName[b.worktree]);`
  — The topology→state join by bare name (same expression at :270 and :348, and tipHTML at :373): topology's worktree values and the cards' keys must move to the qualified form together, or every tip on a colliding name renders the wrong node's status — inventory has only byName's construction at :234.
- **:347** [key] `const key = `b:${b.worktree}`; lookup[key] = b;   // raw key; see branches above`
  — The riders' half of the tooltip registry (the branches' half at :315 is inventoried; tests/test_fixes_web.py:238 pins exactly 2 occurrences) — both must key on the qualified worktree id.
- **:422** [lookup] `const wt = byName[wtName];  (tipFocus)`
  — tipFocus resolves the actuation target by bare name before building the wt= focus address — the onclick arg (:462) and this lookup must carry the qualified id so focus lands on the right node's terminal.
- **:434** [route-param] `const r = await fetch(`/api/focus?pid=${pid}&${ident}`);`
  — tipFocus builds ident as `{wt: wtName, tmux, tty}` (line 430) with pid leading — the address gains node so the board routes to the owning collector; pid stays a node-local hint.
- **:449** [wire-field] `body: JSON.stringify({ worktree: wtName }) });`
  — tipFinish POSTs a bare name as the /api/finish selector — body carries node+worktree (or the qualified key).
- **:477** [machine-field] `$("brandUser").textContent = `${state.user || "you"}@fleet`;`
  — state.user is a singleton machine field — becomes the board node's label once the payload is per-node.

## The iOS app  (76 sites)


### `ios/App/DebugRoute.swift`

- **:119** [route-param] `return .worktree(parts[1])`
  — ORC_SCREEN=wt:<name> seams must accept the qualified key so the screenshot gate can reach a node-qualified card.
- **:125** [route-param] `let fields = parts[1].split(separator: "/", maxSplits: 2).map(String.init)`
  — chat/transcript/resume seams split on "/" — a "<node>/<worktree>" key breaks the field split; Phase 0 must pick a qualified-key separator that survives these parsers (or re-spec the seams).

### `ios/Sources/Orchestra/API/Endpoint.swift`

- **:237** [wire-field] `let payload: [String: String] = ["account": account, "sid": sid,                                          "…`
  — POST /api/send's `worktree` assertion must be the node-qualified key so the board can corroborate against the right node's card (sid stays the primary address).
- **:259** [wire-field] `if let worktree { payload["worktree"] = worktree }`
  — POST /api/dispatch's `worktree` genuinely SELECTS a worktree by bare name; must become node-qualified or dispatch on a two-node board is ambiguous.
- **:284** [wire-field] `let payload: [String: String] = ["worktree": worktree]`
  — POST /api/finish is addressed by worktree name ALONE — the single most identity-load-bearing bare name on this wire; must carry the qualified key.
- **:302** [dedup-key] `var payload: [String: Any] = ["worktree": worktree, "sid": sid,                                       "acco…`
  — resume/schedule's idempotency-by-construction key is "{worktree}|{sid}" server-side; the worktree component must be node-qualified end to end.
- **:319** [dedup-key] `let payload: [String: String] = ["worktree": worktree, "sid": sid]`
  — resume/cancel pops the same "{worktree}|{sid}" key; same qualification.
- **:400** [wire-field] `if let worktree, !worktree.isEmpty { payload["worktree"] = worktree }`
  — The inline-reply path forwards the notification's `wt` as a corroborating selector; must forward whatever qualified form the push payload carries.

### `ios/Sources/Orchestra/Demo/DemoFleet.swift`

- **:40** [test] `public static let needsAnswerWorktree = "search-index"`
  — The demo address constants (also limitWorktree :47, freeWorktree :48) are looked up as card keys and route params by DemoTests and debug routes — they must become the qualified demo keys.
- **:75** [test] `"order": ["search-index", "payments-webhook", "checkout-flow",`
  — The demo frame's `order`/`cards` keys (and the "release-notes|<sid>" resumes key at line 487) are bare names; they must move to the qualified form the applier will require, or the reviewer's board goes blank.
- **:78** [test] `"cards": {     "search-index": {`
  — The demo frame's cards dict is keyed by bare names (inventory caught only "order" at :75); Phase 0 must rewrite these keys to the qualified form since the demo goes through the real applier, or loadDemo blanks the reviewer's board.
- **:487** [test] `"release-notes|a0539f74-2b6e-4d81-93cf-1e7a48d5c6b2": {`
  — The demo resumes dict mirrors resume.py's `worktree|sid` key with a bare name; it must adopt the qualified key so the demo's armed-resume row keeps joining its card.

### `ios/Sources/Orchestra/Demo/DemoTopology.swift`

- **:37** [test] `"worktree": "search-index",`
  — The demo topology's worktree values (:37–:97) join the demo board by name in FleetView:458/BranchMap; they must change in lockstep with DemoFleet's card keys or the demo map renders every branch unplaced.

### `ios/Sources/Orchestra/Model/Actions.swift`

- **:227** [wire-field] `public let worktree: String?  (DispatchResult)`
  — The dispatch result's worktree names where the mission landed; Phase 0 must ship it node-qualified (or add a node field) — decoded today, consumed nowhere, so this is wire-contract alignment only.

### `ios/Sources/Orchestra/Model/Push.swift`

- **:83** [push-id] `self.dedupeKey = userInfo["dedupe_key"] as? String`
  — Lock-screen collapse key is server-composed "ev|wt|sid|n" with a bare wt component (pinned in PushTests:33); its wt half must be node-qualified or two nodes' events collapse into each other.
- **:87** [wire-field] `self.worktree = userInfo["wt"] as? String`
  — The APNs `wt` field addresses a worktree for deep links and reply corroboration; Phase 0's server must emit the qualified key here and the client resolve it as such.
- **:138** [wire-field] `return PushReplyTarget(sid: sid, worktree: worktree)`
  — Inline-reply target forwards `wt` into POST /api/send; forwards the qualified form verbatim (PushStore:276 is the send site).

### `ios/Sources/Orchestra/Model/StreamFrame.swift`

- **:32** [wire-field] `public let order: [String]`
  — `order` rides every frame as a list of card keys; becomes a list of qualified keys in lockstep with `cards`.
- **:46** [wire-field] `public let cards: [String: Worktree?]`
  — Frame `cards` dict keys are the wire card keys (null = removed); Phase 0 ships them node-qualified — decoder shape survives but every consumer of the keys changes meaning.
- **:92** [key] `public var removedCards: [String] {         cards.filter { $0.value == nil }.map(\.key)`
  — Removal names are frame keys; qualified keys flow through unchanged once the wire moves.

### `ios/Sources/Orchestra/Model/Topology.swift`

- **:64** [lookup] `Set(groups.flatMap { $0.branches.map(\.worktree) })`
  — mappedWorktrees set differenced against board names to find dropped cards; both sides must use the same qualified key.
- **:115** [ui-id] `public var id: String { worktree }`
  — TopoBranch's Identifiable id is the bare name; a merged multi-node topology needs node-qualified branch ids or map rows collide.

### `ios/Sources/Orchestra/Model/Wire.swift`

- **:32** [machine-field] `public let hostname: String     public let user: String`
  — hostname/user describe THE machine; Phase 0 makes them per-node labels riding each node's cards (hostname is a label, never an id per ADR), so the single top-level pair becomes a node list.
- **:35** [wire-field] `public let freeWorktrees: [String]`
  — ADR 0016 makes `free_worktrees` node-qualified; decode as qualified keys (or {node, name} pairs) so the dispatch picker posts an unambiguous target.
- **:39** [dedup-key] `/// Keyed `"{worktree}|{sid}"` with a literal pipe (`resume.py:68`).     public let resumes: [String: Resum…`
  — The server-side resume key's worktree half must be node-qualified (or keyed by sid alone, which is already unique); client key reconstruction at ResumeSheet:49 must match.
- **:108** [ui-id] `public var id: String { name }`
  — Identifiable id must become the node-qualified key (node + "/" + name); two nodes' identical names otherwise collapse ForEach rows and animations on the board.
- **:114** [wire-field] `/// The card key. `discover_worktrees` dedupes by absolute path, so two roots ... public let name: String`
  — Worktree gains a `node` field and the card key becomes "<node>/<worktree>"; `name` reverts to a label while the qualified key becomes the identity everywhere below.
- **:454** [pid] `public struct LiveProc ... public var id: Int32 { pid }`
  — stays — node-local composition (only ever enumerated inside one card, which belongs to one node).
- **:505** [pid] `public struct OtherProc ... public var id: Int32 { pid }`
  — other_procs merged from N nodes makes pid a colliding board-level id; qualify the Identifiable id with the owning node (pids stay node-local hints, never cross-machine identities).
- **:539** [wire-field] `public struct ResumeSchedule ... public let worktree: String`
  — `worktree` here is equality-matched against card names board-wide (FleetView:469, WorktreeDetailView:56, ResumeSheet:80); it must carry the node-qualified key or a separate node field.

### `ios/Sources/Orchestra/Rules/Actuation.swift`

- **:191** [key] `case finish(worktree: String)`
  — The InFlight lock key for finish is the bare name — two nodes' same-named worktrees would share one lock (over-locking); carry the qualified key.
- **:192** [key] `case resume(worktree: String, sid: String)`
  — Same lock-key qualification for resume (sid alone would also suffice since sids are unique).

### `ios/Sources/Orchestra/Rules/BranchMap.swift`

- **:173** [ui-id] `public var id: String { branch.worktree }`
  — Row identity = bare name; qualify with node alongside TopoBranch.id.
- **:211** [lookup] `.map { Row(branch: $0, section: sections[$0.worktree], now: now) }`
  — The topology→board section join by bare name; joins on the qualified key once both payloads carry it.
- **:236** [sort-key] `: $0.branch.worktree.localizedCaseInsensitiveCompare($1.branch.worktree) == .orderedAscending`
  — Name breaks ties 'so the order is stable across refreshes' — with duplicate bare names the order is no longer deterministic; tiebreak on the qualified key.

### `ios/Sources/Orchestra/Store/ActionsStore.swift`

- **:48** [wire-field] `public let worktree: String?`
  — DispatchRun.worktree is the stored dispatch target that MissionComposer:230 restores into the draft and re-POSTs on relaunch — it must hold the node-qualified id (or nil for Auto) or a post-Phase-0 relaunch addresses a bare name the server no longer resolves.
- **:96** [key] `public private(set) var finishes: [String: FinishRun] = [:]`
  — Finish runs are keyed by bare worktree; two nodes closing same-named worktrees share one slot — key by the qualified card key.
- **:110** [audit-key] `public private(set) var briefsSentLocally: [String: Date] = [:]`
  — The 30-min brief memory is a local record later matched by name (line 352); key it by qualified key or the restart detector fires on the wrong node's card.
- **:117** [key] `public private(set) var resumeNotices: [String: ResumeReply] = [:]`
  — Notices keyed "{worktree}|{sid}" — worktree half must be the qualified key so a notice renders under the right node's sheet.
- **:352** [lookup] `guard let sent = briefsSentLocally[card.name],`
  — serverForgotBrief matches the memory by bare card name; switch to the card's qualified id.
- **:365** [dedup-key] `public static func resumeKey(worktree: String, sid: String) -> String {         "\(worktree)|\(sid)"`
  — Client-side mirror of the server's pipe key; must compose the node-qualified worktree identically to whatever the server ships, or ResumeSheet:49's direct dict lookup misses.

### `ios/Sources/Orchestra/Store/ChatStore.swift`

- **:122** [wire-field] `public let worktree: String`
  — Carried into every /api/send body (line 284) as the server's cross-check; becomes the qualified key threaded from the route.

### `ios/Sources/Orchestra/Store/DraftStore.swift`

- **:17** [wire-field] `public var worktree: String?`
  — A persisted dispatch target by bare name, replayed into /api/dispatch days later; persist the qualified key and invalidate drafts whose key no longer resolves.

### `ios/Sources/Orchestra/Store/FleetApplier.swift`

- **:26** [key] `public private(set) var cards: [String: Worktree] = [:]`
  — The delta applier's card dictionary is keyed by bare name today; keys become "<node>/<worktree>" — this is the client half of the ADR's breaking wire change.
- **:63** [key] `for (name, card) in frame.cards {                 if let card {                     cards[name] = card`
  — Delta merge/removal by frame key; works unchanged once frame keys are qualified, but the card's own id must equal the dict key or a delta patches one identity while SwiftUI tracks another.
- **:96** [key] `cards = Dictionary(state.worktrees.map { ($0.name, $0) },                            uniquingKeysWith: { fi…`
  — Seeding keys by bare name and `uniquingKeysWith` silently DROPS one of two same-named cards — exactly the cross-node collision; seed by the qualified key so nothing is dropped.
- **:98** [key] `order = state.worktrees.map(\.name)`
  — `order` entries are card keys; must become the qualified keys (and the line-78 fallback `Array(cards.keys).sorted()` then sorts qualified keys).
- **:116** [lookup] `let worktrees = order.compactMap { cards[$0] }`
  — Order→card lookup: correct once both sides carry qualified keys; a mixed state (qualified order, bare cards) silently blanks the board, so the change must be atomic.
- **:121** [key] `freeWorktrees: worktrees.filter { $0.availability == .free }.map(\.name),`
  — Derived free list must be built from qualified keys (map the card's qualified id, not `.name`), mirroring the server's node-qualified `free_worktrees`.
- **:136** [machine-field] `public struct FleetSide ... public var hostname: String     public var user: String`
  — The side-fetch cache of hostname/user assumes one machine; becomes per-node metadata (or the board's own label) once collectors multiply.

### `ios/Sources/Orchestra/Store/TopologyStore.swift`

- **:111** [lookup] `return boardWorktrees.filter { !mapped.contains($0) }`
  — Dropped-worktree difference over bare names; a node-A card whose name matches a node-B branch would wrongly read as mapped — difference over qualified keys.

### `ios/Sources/Orchestra/UI/BranchMapView.swift`

- **:62** [lookup] `MapDetailSheet(branch: branch, group: group(of: branch),                            info: board[branch.work…`
  — Sheet's board join by bare name (also line 158's row join and line 104's group-of predicate); all move to the qualified key.
- **:64** [route-param] `onOpenWorktree(branch.worktree)`
  — Map→board navigation pushes FleetRoute.worktree with the bare name; push the qualified key.
- **:104** [lookup] `store.topology?.groups.first { $0.branches.contains { $0.worktree == branch.worktree } }`
  — group(of:) selects a topology group by bare-name equality; both sides must compare the qualified worktree id once topology and board carry it, or two nodes' same-named branches land in the wrong group's sheet.
- **:158** [lookup] `MapRowView(row: row, trunkTs: grp.trunkTs, axis: axis, info: board[row.branch.worktree], now: now)`
  — A second board-join lookup the inventory missed (it has only the sheet's board[branch.worktree] at :62); the row's status/section colouring joins by bare name and must use the qualified key with the FleetView:458 dictionary.

### `ios/Sources/Orchestra/UI/ChatView.swift`

- **:99** [lookup] `fleet.state?.worktrees.first { $0.name == worktree }`
  — canSend gate selects the card by bare name; qualified key.

### `ios/Sources/Orchestra/UI/FinishSheet.swift`

- **:45** [lookup] `fleet.state?.worktrees.first { $0.name == worktree }`
  — The finish sheet re-reads its card by bare name every pass (the two-step state machine hangs off this); moves to the qualified key with the route.

### `ios/Sources/Orchestra/UI/FleetRoute.swift`

- **:10** [route-param] `case worktree(String)`
  — Navigation destination addresses a card by bare name; the route value must become the qualified key (it is what WorktreeDetailView looks the card up with).
- **:20** [route-param] `case chat(worktree: String, account: String, sid: String)`
  — Chat route's worktree component feeds ChatStore's wire assertion and titles; becomes the qualified key (sid stays the real address).

### `ios/Sources/Orchestra/UI/FleetView.swift`

- **:133** [route-param] `case .worktree(let name):                     WorktreeDetailView(name: name, store: store, actions: actions,`
  — The destination hands the route's bare name to the detail screen as its lookup key; passes the qualified key after Phase 0.
- **:142** [lookup] `boardWorktrees: store.state?.worktrees.map(\.name) ?? []) { name in                         path.append(.wo…`
  — The map's dropped-by-difference list and its open-worktree callback both traffic in bare names; both become qualified keys.
- **:210** [lookup] `if let card = store.state?.worktrees.first(where: { $0.name == name }),`
  — Push deep-link resolution selects a card by the payload's bare `wt`; must match on the qualified key once `wt` is qualified (or resolve by sid first and take its card).
- **:269** [route-param] `NavigationLink(value: FleetRoute.worktree(card.name)) {`
  — Board card tap routes by bare name; push the card's qualified id.
- **:458** [key] `out[card.name] = MapBoardInfo(`
  — The board→map join dict is keyed by bare name; key by qualified id and give the map the same key on its side.
- **:469** [lookup] `$0.worktree == card.name && $0.status == "pending"`
  — Resume schedules are matched to a card by bare-name equality across the whole board; compare node-qualified values.

### `ios/Sources/Orchestra/UI/MissionComposer.swift`

- **:352** [wire-field] `+ (fleet.state?.freeWorktrees ?? []).map {                     PickerOption(value: $0, title: $0)`
  — Picker values come straight from `free_worktrees` and go straight into the dispatch body; once qualified, display the bare name + node label but post the qualified key.

### `ios/Sources/Orchestra/UI/ResumeSheet.swift`

- **:44** [lookup] `fleet.state?.worktrees.first { $0.name == worktree }?`
  — Live-session refresh selects the card by bare name; qualified key.
- **:49** [dedup-key] `fleet.state?.resumes[ActionsStore.resumeKey(worktree: worktree, sid: session.sid)]`
  — Direct dict lookup reconstructing the server's "{worktree}|{sid}" key — the one place the client depends on the exact composed key string; must match the server's qualified form byte for byte.
- **:80** [lookup] `return earliest.sid == session.sid && earliest.worktree == worktree ? nil : earliest`
  — firingBlocker compares bare worktree names across ALL resumes on the board; two nodes' same-named worktrees conflate — compare qualified values.

### `ios/Sources/Orchestra/UI/ServerView.swift`

- **:173** [machine-field] `Row("name", fleet.state?.hostname ?? profile?.hostname ?? "—")             Row("user", fleet.state?.user ??…`
  — The Server screen renders THE machine's hostname/user; becomes a per-node listing (board host + N collector nodes with labels and last-spoke ages).

### `ios/Sources/Orchestra/UI/WorktreeDetailView.swift`

- **:51** [lookup] `store.state?.worktrees.first { $0.name == name }`
  — The detail screen re-selects its card from every frame by bare name; the screen's identity parameter and this predicate move to the qualified key.
- **:56** [lookup] `.filter { $0.worktree == name && $0.status == "pending" }`
  — Resume rows selected by bare-name equality; qualified comparison.
- **:156** [key] `&& !actions.isBusy(.finish(worktree: name), now: now)) {`
  — Lock probe keyed by bare name; follows the InFlight.Key qualification.
- **:348** [route-param] `NavigationLink(value: FleetRoute.chat(worktree: card.name, account: session.account, sid: session.sid))`
  — Build the chat route from the card's qualified key, not card.name, so ChatView:99's card lookup and the /api/send worktree assertion resolve the right node's card — the inventory has the route declaration (FleetRoute:20) and FleetView's constructions but not this one.
- **:406** [wire-field] `Task { await actions.resumeNow(worktree: card.name, session: session) }`
  — resumeNow threads card.name into the /api/send body and the notice key; must pass the qualified key.
- **:421** [lookup] `if let reply = actions.notice(worktree: card.name, sid: session.sid) {`
  — Notice lookup composes the pipe key from the bare name; qualified key.

## iOS demo data and tests  (11 sites)


### `ios/Tests/OrchestraKitTests/ActionTests.swift`

- **:344** [test] `store.noteBriefSent("wt", at: now.addingTimeInterval(-60))`
  — Restart-detector test matches briefsSentLocally by bare card name; retarget to qualified keys with the store (lines 134-136 pin the per-worktree InFlight lock the same way).

### `ios/Tests/OrchestraKitTests/BranchMapTests.swift`

- **:40** [test] `#expect(g.branches.map(\.worktree).contains("ConfidAI3"))`
  — This suite explicitly pins (lines 34-36) that the map join key is the bare worktree NAME 'because both payloads come from the same discover_worktrees' — that rationale dies with the split; re-pin the qualified join.

### `ios/Tests/OrchestraKitTests/DecodeTests.swift`

- **:34** [test] `#expect(state.freeWorktrees.count == 6)`
  — Fixture-pinned free list; the captured /api/state and snapshot-frame fixtures need re-capture (or a compat re-scrub) with qualified keys.

### `ios/Tests/OrchestraKitTests/DemoTests.swift`

- **:155** [test] `cards[DemoFleet.needsAnswerWorktree]?`
  — Pins the applier's cards dict keyed by bare demo name (also cards.first{$0.name==…} at :128, notice/arm addressing at :316,:373–382); these assertions move with the qualified demo keys.
- **:241** [test] `#expect(state.hostname == DemoFleet.hostname)`
  — Pins the single-machine hostname side-fact; moves with the per-node hostname/user model.
- **:245** [test] `#expect(state.freeWorktrees == [DemoFleet.freeWorktree])`
  — Pins free_worktrees as bare names; becomes the node-qualified list per ADR 0016.
- **:433** [test] `let card = try #require(payload.frame.changedCards[DemoFleet.limitWorktree])`
  — Pins the delta frame's changedCards keyed by bare name — the delta address space pin that must switch to the qualified key.

### `ios/Tests/OrchestraKitTests/FixesAPITests.swift`

- **:32** [test] `("send", try .send(account: "a", sid: "s", worktree: "w", text: "hi")),`
  — Pins the mutation bodies' `worktree` params (send/finish/resumeSchedule/resumeCancel/reply); update literals when the params carry qualified keys.

### `ios/Tests/OrchestraKitTests/PushTests.swift`

- **:33** [test] `"dedupe_key": "session.needs_answer|ConfidAI2|ca1c96e9|3",`
  — Pins the collapse-key format with a bare worktree component; must pin the node-qualified form when notify.compose changes (line 78 pins `wt` == "ConfidAI2" likewise).

### `ios/Tests/OrchestraKitTests/StreamTests.swift`

- **:230** [test] `#expect(applier.cards[target]?.availability == .attention)`
  — Applier tests index `cards` by names taken from the fixture's `order`; fixture keys and these lookups move together to qualified keys (also lines 246-256 removal, 328 order, 355 free set).
- **:355** [test] `#expect(Set(composed.freeWorktrees) == Set(board.freeWorktrees))`
  — Pins the derived free list against the fixture's bare-name list; both fixtures gain qualified entries in the same commit.

## Python tests and goldens  (40 sites)


### `tests/characterize.py`

- **:209** [path-key] `snap["match_worktree"] = [ {"in": name, "out": _safe(mod, "match_worktree", name, prefixes)} …]`
  — Stays — node-local composition: munge/match_worktree map transcript project dirs to local paths inside one collector; golden only re-records if the function signature changes.
- **:422** [test] `state = mod.collect_state()   # …the wire payload's shape (state_payload golden)`
  — The state_payload golden pins the whole /api/state shape — worktrees[].name, free_worktrees, envelope keys — so Phase 0's node field/qualified keys change the golden: re-record in the same commit (test_characterization.py's procedure).
- **:439** [machine-field] `for machine_key in ("user", "hostname"): … state[machine_key] = f"<{machine_key.upper()}>"`
  — The golden normalises but pins the presence of user/hostname envelope keys; Phase 0's node-identity restructure must extend the normalisation (node id is random per install) or the golden goes red on every machine again.

### `tests/test_auth.py`

- **:822** [test] `"POST", "/api/finish", body=json.dumps({"worktree": "x"}),`
  — Auth guard tests exercise the finish route with bare-name bodies; update alongside the route's addressing change (mechanics of the guard itself are unaffected).

### `tests/test_events.py`

- **:245** [test] `self.assertEqual(set(data["cards"]), {"alpha", "beta"})`
  — Pins the SSE snapshot frame's cards dict keyed by bare name (delta frames at 266, 320, 691 likewise); frames carry qualified keys after Phase 0.

### `tests/test_fixes_actuate.py`

- **:136** [test] `self.assertIn("w1", fb.dispatch._wt_reservations)   # held before spawn`
  — Pins the accept-path dispatch reservation keyed by bare name — the auto-pick subtraction and double-dispatch guard; must key on the qualified id at the board.
- **:338** [test] `fb._resumes["wt|s1"] = {"worktree": "wt", "sid": "s1", … } ; fb.save_resumes()`
  — Pins resume.schedule.json persisted under "worktree|sid" keys (load/save round-trip, firing at "alpha|s1"); the store's key format changes with the schedule identity.

### `tests/test_fixes_finish.py`

- **:103** [test] `self.assertEqual(blob, {"closeouts": {"wt": 1000.0}})`
  — Pins the persisted finish.closeouts.json keyed by bare name; the persisted key must be re-keyed (or explicitly node-local) and rehydration re-pinned.
- **:363** [test] `killed = self.reap("wt", ["mission-wt-120000"],`
  — TestReapDeadSessions (:355-391) pins the slug equality between the worktree argument and tmux session names ("mission-wt-120000" vs "wt", negative case "mission-other-120000"); Phase 0 must decide and pin here that reap receives the node-local bare name, not the qualified key.

### `tests/test_fixes_idem.py`

- **:101** [dedup-key] `PAY = {"mission": "land the branch", "worktree": "alpha"}`
  — The idempotency fingerprint hashes a body whose worktree selector is a bare name; when the selector becomes node-qualified every fingerprint changes, and ADR 0016 requires the same key to be honoured end-to-end across the forward.

### `tests/test_fixes_observer.py`

- **:189** [test] `self.assertEqual(snap.cards["alpha"]["git"]["dirty"], 2)   # the NEW data`
  — Pins Observer.publish's name-keyed snap.cards lookups (also :210, :221, :246, with the state_with fixture at :162-167); assertions must key on "<node>/alpha" once card identity is qualified — this file is absent from the inventory.

### `tests/test_fixes_push.py`

- **:132** [test] `cards = {"wt": {"name": "wt", "availability": "busy",`
  — Pins notify.project reading snapshot.cards keyed by bare worktree name (also :140, :147); fixtures must move to node-qualified card keys with the node field alongside — this file is absent from the inventory.
- **:463** [test] `worktrees={"wt": "free"})`
  — Pins the Notifier's projection worktrees map keyed by bare name through observe()/derive (the sess() helper at :51 also stamps worktree="wt" into session projections); fixture keys become node-qualified in Phase 0.

### `tests/test_fixes_web.py`

- **:238** [dom-id] `self.assertEqual(src.count("const key = `b:${b.worktree}`;"), 2)`
  — Pins map.html's tip/finish registry keyed `b:<bare worktree name>` read back from dataset; the registry key must become the node-qualified id along with the topology payload.

### `tests/test_integration.py`

- **:227** [test] `card = next(w for w in st["worktrees"] if w["name"] == "myapp")`
  — Selects cards from the wire payload by bare name (also 308); harmless per-node today, but assertions move to the qualified key when the payload re-keys.
- **:343** [test] `fb._closeouts["gone-wt"] = time.time() - 30     # no card at all`
  — Pins closeout reaping matched against cards by bare name (317-354); matching moves to the card's qualified key.
- **:898** [test] `self.assertEqual(fb.collect_state()["free_worktrees"], ["myapp"])`
  — Pins the free_worktrees shape end-to-end ('what /api/dispatch picks from'); the dangerous-direction test must assert the node-qualified id after Phase 0.
- **:1498** [test] `self.assertEqual(br["worktree"], "app")`
  — Pins topology branches carrying the bare worktree name as the board join; gains a node-qualified worktree_id alongside.

### `tests/test_notify.py`

- **:80** [test] `self.assertEqual(p["worktrees"], {"wt": "free"})`
  — Pins notify.project's worktree projection keyed by bare name — the diff domain for worktree.free edges; must key on the qualified id (also derive tests at 196-210).
- **:166** [test] `p1 = proj(resumes={"wt|s1": {"status": "pending", **base}})`
  — Pins resume-edge derivation over "worktree|sid" keys; keys become node-qualified with the schedule store.
- **:389** [test] `self.assertEqual(c["payload"]["aps"]["thread-id"], "studio-mac|ConfidAI-auth")`
  — Pins the thread-id grouping scheme {server}|{bare name}; changes with the UX §8.5 thread-id decision.

### `tests/test_observer.py`

- **:97** [test] `self.assertEqual(list(snap.cards), ["alpha"])`
  — Pins Snapshot.cards keyed by bare name; flips to the qualified key when publish() re-keys (dozens of cards["alpha"] lookups in this file follow the same change).
- **:239** [test] `self.assertEqual(set(d["cards"]), {"alpha"})      # beta never changed`
  — Pins delta_since's cards dict (delta ring contents) keyed by bare name — the delta machinery's dictionary keys change to qualified ids (also lines 231, 254, 320, 343).
- **:330** [test] `assert set(self.cards) == set(f["order"]), ( f"the frame's order names {sorted(f['order'])}…")`
  — The Python reference applier (the transcription of stream.js Fleet.apply) reconciles cards against `order` by name; it must apply and compare qualified keys.
- **:454** [test] `for field, value in [("hostname", "elsewhere"), ("user", "someone"), ("free_worktrees", ["alpha"]), …]`
  — Pins that hostname/user/free_worktrees ride collect_state's top level outside the version diff; Phase 0 restructures these envelope fields (node identity, qualified free list) and the pinned term list must be revisited.
- **:788** [test] `self.assertEqual(tuple(o._hist)[-1][1], ("alpha",))`
  — Pins the changed-key ring recording bare names; ring entries become qualified keys.
- **:1178** [test] `self.assertEqual(st["free_worktrees"], [])`
  — Pins the free_worktrees shape off the real compose path; expected values become qualified ids (also test_integration.py:815/895/898).
- **:1221** [test] `fb._closeouts["alpha"] = ts = time.time() - 30   # no live procs`
  — Pins finish._closeouts keyed by bare name; the closeout map (and its card advertisement) re-keys or stays collector-local with the card key qualified at assembly.

### `tests/test_orchestra.py`

- **:1166** [test] `self.assertEqual(self.addressed[0]["worktree"], "wt")`
  — Pins finish briefs addressed by bare worktree name + pane (ADR 0008); the address stays collector-local but the board-to-collector form gains the node.
- **:1204** [test] `fb._closeouts["wt"] = _t.time() - 120                 # briefed 2m ago`
  — Pins the two-step closeout state keyed by bare name throughout the finish tiers (1204-1310); re-keys with the card identity.
- **:1516** [test] `res = fb.send_to_process(4242, "hi", sid="s-alpha", worktree="alpha")`
  — Pins send's identity guard taking a bare worktree name as containment hint plus a pid hint; both stay node-local, but the wire form the board forwards must name the node.
- **:2302** [test] `self.assertIn("free_worktrees", st)`
  — Pins the demo /api/state envelope carrying free_worktrees; demo data must gain the same node-qualified shape as live (API §15 parity).
- **:2355** [test] `self.assertIn("resumes", st) … all("due_at" in r for r in st["resumes"].values())`
  — Pins /api/state shipping resumes as a dict (keyed "worktree|sid" per API.md:3735); the wire dict's keys change or the legacy view stays single-node.
- **:2361** [route-param] `data=json.dumps({"worktree": "w", "sid": "s", "account": "a"}).encode(),   (POST /api/resume/schedule)`
  — Pins the resume-schedule wire body selecting a worktree by bare name; the selector must become node-qualified (or resolve via sid, which is already unique).
- **:2371** [route-param] `data=json.dumps({"worktree": "orbital-api"}).encode(),   (POST /api/finish)`
  — Pins /api/finish addressing by bare name on the wire (also 2396-2400 forwarding to start_finish(wt)); the board must resolve a node-qualified target before forwarding.
- **:2407** [pid] `d = self._post("/api/send", {"pid": 999999, "text": "hi"}) … assertEqual(d["error"], fb.UNADDRESSED)`
  — Pins that a bare pid on the wire is refused — the right direction; keep, and ensure the refusal also covers a pid arriving with a node it does not belong to.
- **:2427** [route-param] `self._get("/api/focus?pid=7&wt=feat%2Fx&tmux=sess%3A0.1&tty=ttys003")`
  — Pins the `wt=` query parameter carrying the bare worktree name through the router into focus/send identity; the parameter becomes node-qualified (the literal `wt=` case the inventory brief names).

### `tests/test_stream_js.py`

- **:56** [test] `state: fleet.state({ user: "u", hostname: "h", resumes: {} })`
  — Pins that stream.js composes hostname/user from a side fetch into the rendered state; the side-channel fields become board+node identity.
- **:104** [test] `"free_worktrees": [c["name"] for c in wts if c["availability"] == "free"]`
  — Pins free_worktrees as derived from bare card names in the shipped JS applier's view; derivation switches to qualified keys.
- **:274** [test] `self.assertEqual(set(st), {"generated_at", "hostname", "user", "counts",   "free_worktrees", "worktrees", "…`
  — Pins the singular hostname/user state shape, bare free_worktrees (`["gamma"]` at 277), and card fixtures keyed by bare name (77, 102-115) — fixtures and assertions must be rewritten to node-qualified keys as part of the same coordinated change.

## Documents (corrected in the same commit as the wire)  (59 sites)


### `docs/mobile/API.md`

- **:46** [route-param] `| `POST /api/finish {worktree}` | **`POST /api/v1/worktrees/{wid}/finish`** |`
  — The legacy finish body selects a worktree by bare name; Phase 0 must resolve it against the local node's cards only (legacy stays the built-in collector's view) while the v1 route adopts a node-qualified wid.
- **:53** [path-key] `| `sid` | **`session.id`**; `wid` is `wt_<12 hex>`, never the worktree name |`
  — wid is a hash of an abspath, which is node-local; the doc must redefine wid as derived from (node, abspath) or as node-prefixed, or two machines with the same path collide.
- **:522** [machine-field] `"server": { "host": "100.113.110.31", "port": 4299, "hostname": "MacBookPro", … }   (pairing response)`
  — Stays — this names the board itself, which remains one machine; unaffected by node identity beyond possibly advertising the board's node id.
- **:693** [key] `| `dispatch` | `worktree:<wid>` — **resolved synchronously in the accept path, before the 202** | the op's …`
  — Board-side resource locks `worktree:<wid>` (and finish at line 694) must key on the node-qualified wid so two nodes' identical paths cannot share a lock.
- **:729** [pid] `"pid": 41234,   (in the `expect` object, §5.2)`
  — expect.pid stays a node-local assertion; the contract must state it is compared on the owning node, never used by the board as an identity.
- **:874** [wire-field] `free                        array of free worktree ids               LEAF`
  — `free` (and `order`, line 875) become arrays of node-qualified worktree ids; free_worktrees is exactly the collision ADR 0016 names.
- **:875** [wire-field] `order                       array of worktree ids, server sort order LEAF`
  — The order leaf's entries are wids (sha1 of a node-local abspath — two machines can hold identical paths, §7.1's own dedupe argument); Phase 0 must make its entries node-qualified ids, and the single board-wide (severity, name.lower()) total order becomes a merge across nodes' cards (also the 'order' example at API.md:1507).
- **:883** [key] `acct/<label>                one account's headroom summary           descend`
  — Account labels are per-machine Claude homes; decide whether `acct/<label>` merges across nodes (same Anthropic account) or becomes node-scoped — currently undefined.
- **:884** [key] `r/<wid>|<sid>               one auto-resume schedule                 descend`
  — The resume-schedule delta address embeds the node-local wid; the composite must become node-qualified along with wid.
- **:888** [path-key] `**`wid`** is `wt_` + 12 hex of `sha1(abspath)`. It is **not** the worktree name: `discover_worktrees` dedup…`
  — §7.1's wid derivation must fold in the node id (e.g. sha1(node + abspath) or a `<node>/<wid>` address) — abspath alone is only unique within one machine.
- **:897** [sort-key] `The server re-sorts cards by `(severity, name.lower())` and sessions by `(4.5 if handed_to else rank[status…`
  — The card sort's name tiebreak stops being total when two nodes hold the same name; the tiebreak must become (severity, name.lower(), node) or the qualified key.
- **:1115** [machine-field] `"collector_ok": true,   (GET /api/v1/health)`
  — One boolean describes one collector; health must report per-node collector health (also §6.2 line 813, hello line 1579, hb line 1604).
- **:1169** [machine-field] `"server": {"hostname": "achills-macbook-pro", "user": "achill"},`
  — meta's server block becomes the board's identity plus a nodes list; hostname/user become per-node labels riding a persisted node id.
- **:1280** [machine-field] `"server": {"hostname": "achills-macbook-pro", "user": "achill", "mode": "live", "api": "1.0"},`
  — /api/v1/state's envelope must split board identity from node identity: cards carry `node`, and hostname/user move to a per-node block keyed by node id.
- **:1286** [machine-field] `"srv": { … "collector_ok": true, "on_battery": false, "last_tick_at": 1784636692.641, "wake_gap": 0.0, … }`
  — The srv delta entity (§7.1 'srv server-level scalars', shipped whole in every full state payload) carries one machine's collector facts — collector_ok, on_battery, last_tick_at, wake_gap; with one board over N collectors these must become per-node (a node-keyed structure or fields of a node entity), since ADR 0016's dark-node rule needs each collector's health and staleness stated separately.
- **:1296** [wire-field] `"free": ["wt_88bc4d1e0a72"],`
  — The free list (and `order`, line 1297) must carry node-qualified ids — this is the breaking wire change ADR 0016 declares.
- **:1395** [key] `"resume_id": "wt_9911aabb2233|4f2c88e1-7a30-4c19-9e88-1d2b3c4d5e6f",`
  — resume_id embeds the node-local wid; qualify the wid half (sid half is already globally unique).
- **:1431** [pid] `"other": [ {"pid": 51221, "uptime_s": 8123, "tty": "ttys011", "host": "Cursor", "cwd": "/Users/achill/scrat…`
  — `other` entries are identified only by pid/tty/cwd — all node-local; each entry must carry `node` and pid stays a hint, never a key.
- **:1436** [key] `"id": "wt_9911aabb2233|4f2c88e1-…", "worktree_id": "wt_9911aabb2233", "worktree": "ConfidAI3",`
  — resumes[].id and worktree_id become node-qualified; `worktree` stays a display label.
- **:1580** [machine-field] `"wake_gap":0.0,"collector_ok":true,"max_age_s":300,  (the hello frame, GET /api/v1/stream)`
  — hello's wake_gap/collector_ok (and its tick cadence, which §6.2 defines as 'the collector's generated_at' recency) describe a single machine's collector; the merged stream's hello must scope them per node or drop them in favour of a per-node entity, or a sleeping work machine reads as board-wide trouble.
- **:1604** [machine-field] `"tick":10.0,"hb":25.0,"collector_ok":true,"wake_gap":0.0,"on_battery":false}  (the hb heartbeat frame)`
  — The heartbeat's collector_ok/wake_gap/on_battery are one machine's health riding a board-level frame; they must become per-node so a dark collector goes stale-with-a-stated-age (ADR 0016) instead of flipping one global health bit for the whole board.
- **:1837** [key] `handle = "tmux:<sock or 'default'>:<session:win.pane>" | "tty:<tty>:<int(first_seen_at)>" | "pid:<pid>:<int…`
  — Every handle form is node-local (tmux socket, tty, pid) yet ag_id is a board-level route key — the handle must be salted with the node id or ag_id becomes node-scoped.
- **:1872** [display-ambiguous] `"repo": "ConfidAI",   (topology group key)`
  — Topology groups by repo name; decide whether same-named repos on two nodes merge into one group (probably yes, as one logical repo) or split per node — today it is undefined.
- **:1878** [path-key] `"worktree_id": "wt_3f9a2b1c7d04", "worktree": "ConfidAI-ci-cleanup",   (topology branches[])`
  — topology branches[].worktree_id must be the node-qualified id so the client's join back to cards survives two nodes.
- **:2009** [key] `**`label` is the join key** into `session.account` and into every write endpoint.`
  — Account label is a per-machine join key; Phase 0 must state whether labels are node-scoped or merged, since both machines will have a `main`.
- **:2122** [route-param] `| `account` | string, **required** | — | Claude-home label, percent-decoded … | (GET /api/v1/sessions/{sid}…`
  — The account param names a Claude home on one machine; once reads are forwarded (Phase 2) the board routes by sid to the owning node and account is resolved there — document it as node-local.
- **:2336** [wire-field] `"target": {"session_id": "9d4db7b2-…", "agent_id": "ag_7c21f0a9b3de", "worktree_id": "wt_3f9a2b1c7d04"}`
  — Op targets (also 2505, 2715, 2794) must carry node-qualified worktree_id/agent ids so a client can address the right node's card from an op record.
- **:2574** [display-ambiguous] `"attach": "tmux -L fleet attach -t mission-orbital-web-121030",`
  — The attach command is only runnable on the owning machine; once nodes exist the result must say which node (ADR 0016 allows the board to add which node answered).
- **:2621** [audit-key] `"worktree_id": "wt_88bc4d1e0a72", "worktree": "orbital-web",   (GET /api/v1/dispatches entries)`
  — Dispatch-log records are later matched for reconciliation; entries must record the node-qualified worktree_id (name stays display).
- **:3035** [wire-field] `"worktree_id": "wt_3f9a2b1c7d04", "worktree": "ConfidAI-ci-cleanup",   (event records, §9.22)`
  — Events drive deep links and withdrawal; worktree_id in event records becomes node-qualified.
- **:3211** [display-ambiguous] `> …worktree names are typically client or product names. … If that matters, hash worktree names with a per-…`
  — The privacy note concedes worktree names ride collapse/thread ids through APNs; the Phase 0 thread-id scheme must decide what the node-qualified form leaks.
- **:3249** [dedup-key] `{"key": "wt_3f9a2b1c7d04", "minutes": 15}   (POST /api/v1/push/snooze)`
  — Snooze keys select a worktree for suppression; they must accept the node-qualified id or a snooze on one node silences its twin on the other.
- **:3735** [key] `legacy has … no `resumes` array (it is a dict keyed "worktree|sid" with a literal pipe)`
  — The frozen legacy /api/state ships resumes keyed by BARE NAME|sid; Phase 0 must either scope the legacy surface to the board's own node or consciously break the §16.1 byte-stability freeze.
- **:3741** [pid] `| `GET /api/focus?pid=` | `POST /api/v1/agents/{ag_id}/focus` | legacy is a **GET with a side effect** …`
  — Legacy focus selects an agent by raw pid on the wire; must stay board-node-local only — a pid must never route across nodes.
- **:3742** [pid] `| `POST /api/send {pid, text}` | … | legacy addresses by pid only, verifies only that *some* claude process…`
  — Legacy send's pid addressing is meaningful only on the machine holding the pid; scope it to the local node and keep v1 session-addressed.

### `docs/mobile/ARCHITECTURE.md`

- **:69** [dom-id] `**The refresh discipline is genuinely good.** Per-card DOM keyed by worktree name…`
  — Documents today's board DOM reconciliation by bare name; Phase 0 makes `dataset.wt` the node-qualified key (see FRESHNESS I18) and this description must follow.
- **:265** [path-key] `Worktrees key on `blake2b(abspath)`, not on the basename — … two roots each holding a `ConfidAI` dir produc…`
  — The 'durable identity' principle must be extended: abspath is only unique per node, so the key becomes (node, abspath) — the doc's identity principle 3 needs the node folded in.
- **:865** [key] `| `dispatch` | `worktree:<wt_id>`, acquired **synchronously in the accept path**, held for the op's life | …`
  — The accept-path reservation lock must key on the node-qualified wt_id once the board fronts N collectors.
- **:1184** [path-key] `w/<wid> … w/<wid>/s/<sid> … r/<wid>|<sid>   (delta address space)`
  — The delta address grammar's `<wid>` segment becomes node-qualified everywhere; same coordinated change as API.md §7.1.
- **:1193** [sort-key] ``collect_state` re-sorts cards by `(severity, name.lower())` (L826)…`
  — Same tiebreak defect as API.md:897 — add node to the sort key so order stays deterministic across same-named cards.
- **:1365** [pid] ``pid` here is **an assertion, not an address** — the request is routed by `sid` or `agent_id` … and the pid…`
  — Stays — already the right model; Phase 0 only needs to record that the pid clause is evaluated on the owning node.

### `docs/mobile/ENGINE.md`

- **:414** [key] `pane:<sock>/<target>   ·   tty:/dev/ttys004   ·   wt:voyager-cli   (target_key lease grammar)`
  — Stays node-local as an actuation lease inside one collector; only the board-level lock (API §4.6) needs node qualification.
- **:567** [key] `cards:      dict     # worktree name -> card  (today's collect_state shape)`
  — The Snapshot's card map — the exact structure ADR 0016 cites at observer.py:1005 — must key on the node-qualified id, not the bare name.
- **:580** [audit-key] `target:     str      # STABLE identity: "wt:voyager-cli" / "sid:<uuid>"`
  — Intent/idempotency records target worktrees as `wt:<bare name>`; the target grammar must become `wt:<node>/<worktree>` (sids stay bare).
- **:843** [dedup-key] `| push dedup set | LRU 512 `(target, transition)` pairs, persisted (§10) |`
  — The push dedup pair uses the name-based target; on a merged board it must dedupe on (node-qualified target, transition) or one node's edge suppresses the other's.
- **:1218** [key] `for name, card in snap.cards.items():  was = (prev.get(name) or {}).get("status") … push(name, now_, card)`
  — The notifier's transition diff iterates and compares by bare name; with two nodes a same-named card's edge is mis-diffed — diff on the qualified key.

### `docs/mobile/FRESHNESS.md`

- **:904** [wire-field] `"order": ["api", "web", "docs"],   // server owns severity(); the client NEVER sorts`
  — The frame's order array is bare names; becomes node-qualified keys — clients apply it verbatim, so this is part of the coordinated wire change.
- **:907** [wire-field] `"free_worktrees": ["docs"],`
  — free_worktrees on every frame is bare names and feeds dispatch targeting; becomes node-qualified.
- **:913** [key] `"git": {"api": {"at": 1753113598.9, "ok": true, "stale": false}}   (signals map)`
  — Per-worktree signal freshness is keyed by bare name; the signals map must key on the qualified id, and signals themselves become per-node.
- **:916** [wire-field] `{"kind": "attention", "wt": "api", "sid": "9b8ef2d1-…", "from": "working", "to": "needs_input", …}   (trans…`
  — transitions[].wt is a bare name and is called 'already the right shape' for the push payload (line 1331); it must carry the node-qualified key.
- **:1291** [dom-id] `assert `[...grid.children].map(el=>el.dataset.wt)` always equals the server's `order``
  — DOM reconciliation equates dataset.wt with order entries; both sides switch to the node-qualified key together.
- **:1298** [path-key] `I18 **The card key is unique.** … the snapshot ships a stable `key` (the worktree path); `dataset.wt` becom…`
  — I18's fix (path as key) is still node-local; Phase 0 supersedes it with the node-qualified key — two machines can hold identical paths.
- **:1299** [ui-id] `I19 … render A with session S, then B without S; assert `REG['wt|S']` is undefined`
  — The board's REG registry keys on bare-name|sid; becomes qualified-key|sid.

### `docs/mobile/UX.md`

- **:1389** [machine-field] `{ "hostname": "studio-mac", "user": "achill", … "config": { "roots": ["/Users/achill/Downloads"], … } }   (…`
  — hello's hostname/user/roots all describe one machine; Phase 0 introduces the node id and roots/config become per-node facts.
- **:1423** [key] `…orphaning the schedule key `"{worktree}|{sid}"` and any session-level deep link.`
  — The resume schedule key embeds the bare worktree name (also §10 item 2, line 3155); the name half must become node-qualified.
- **:1576** [lookup] `| worktree name | identity; the join key into the board |   (map row anatomy)`
  — The map row's join into the board must move from name to the node-qualified key; the name stays the label.
- **:2040** [dedup-key] ``limit_hit` deduped per `(account, group)` once per episode`
  — Account labels are per-node; the dedup tuple needs the node (or a decision that accounts merge across nodes).
- **:2059** [push-id] `"thread-id": "studio-mac|ConfidAI-auth",`
  — Notification thread grouping is {server}|{bare name} (restated line 2073); the worktree half must be node-qualified or two nodes' same-named worktrees thread together.
- **:2062** [push-id] `"o": { "server": "studio-mac", "wt": "ConfidAI-auth", "sid": "9b8ef2d1-…", "acct": "work", … }`
  — The push payload's `o.wt` identifier (which routes the tap) must become the node-qualified key, and `o.server` should become/carry the node id rather than a hostname.


## What the readers ruled out, on the record

Node-local composition that keeps bare names (verified, not merely skipped):
`transcripts.scan_sessions`' worktree-PATH-keyed maps; the cwd-prefix matches
in observer/transcripts/finish; `watcher.py`'s path/fd sets; `procs.py`'s
pid+generation memos; `status.py` (pure policy); `hooks.py` (sid-keyed; the
hook POSTs to loopback, i.e. the machine-local collector after the split);
pid↔session pairing *inside one card* on every client; `chat.py` and
`ChatDrafts` (sid-keyed; sids are UUIDs); `push.py` (opaque transport);
`pair.html` and pairing's `hostname` (they describe the BOARD host, which
stays singular); dispatch job ids (board-minted, board-scoped).

## Rulings the inventory forced (now in NODES.md)

1. **Account labels are a third identity axis** — node-local like worktree
   names, colliding the same way. Phase 0/1: the account↔limits join stays
   collector-local, labels remain per-node display labels, and cross-node
   account identity is explicitly deferred (NODES.md §10).
2. **The kqueue exit-watch set** (`Observer._live_pids`) reads the published
   snapshot; once the snapshot can hold merged cards it must filter to the
   local node or it arms `EVFILT_PROC` on another machine's pids.
3. **Persisted bare-name state**: `resume.schedule.json` is requalified with
   the local node id on load (its keys ride the wire); `finish.closeouts.json`
   and `dispatch.jobs.json` stay bare (never leave the node); `events.log.json`
   keeps its history untouched — an open condition re-derives once under its
   new dedupe key, accepted in NODES.md §8.
4. **The iOS debug deep-link** (`DebugRoute` `chat:<wt>/<account>/<sid>`)
   splits on `/`; with a qualified key it must split from the right (account
   labels and sids cannot contain `/`).
5. **index.html cross-source key agreement**: values written from the DOM
   (`dataset.wt`, `_armFinish.wt`, `FIN_PENDING`) are compared against wire
   names — writers and readers flip to qualified keys in the same commit.
6. **The map topology join** is the one place two payloads (`/api/topology`
   and `/api/state`) must change key format simultaneously, on web AND phone
   AND in both demo datasets.
