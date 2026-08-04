import Foundation

/// The demo fleet's full transcript — `GET /api/v1/sessions/{sid}/messages`,
/// canned.
///
/// **It serves the wire's contract, not a simpler one.** `DemoTranscriptFeed`
/// is a `TranscriptSource` like `OrchestraClient` is, and it answers with byte
/// offsets, an exclusive `before`, a real `has_more_before`, a `file` identity
/// and the same per-message 4,000-character cap — so a reviewer scrolling the
/// demo drives `TranscriptStore`'s actual paging, folding and truncation code.
/// A demo that bypasses the rule under test is a demo of nothing, which is what
/// `DemoClock` says about the decoder and is true twice over here.
///
/// The fixture below holds each block's **full** text (the shape `/messages/at/`
/// answers with, uncapped); the feed applies the cap when it pages. That is why
/// one entry — a 4.6 KB file read — arrives `truncated: true` with a real
/// `chars`, and why tapping `show all` on it fetches something that was not
/// already on screen.
///
/// Every session on the demo board has a full log. The four the fixture does
/// not write out by hand are derived from `DemoChat`'s own turns, so the button
/// never lands on `transcript not found` for a session a reviewer can tap.
public enum DemoTranscript {
    /// The sid the hand-written transcript belongs to — the search-index
    /// session whose chat drawer is the one `DemoChat` opens on a question.
    public static let richSid = "9c1f4a2e-7b30-4c58-9a11-2d6e83f0b415"

    /// Decoded through the REAL decoder, with `DemoClock` moving every `ts` onto
    /// the reader's own clock first — the same path a real page takes.
    public static func entries(now: Date = Date()) throws -> [TranscriptEntry] {
        try JSONDecoder().decode([TranscriptEntry].self,
                                 from: DemoClock.rewrite(json, now: now))
    }

    /// The whole demo world's transcripts: the hand-written one, plus one
    /// derived from every other canned conversation.
    public static func feed(now: Date = Date()) throws -> DemoTranscriptFeed {
        var byId: [String: [TranscriptEntry]] = [richSid: try entries(now: now)]
        for (sid, chat) in try DemoChat.all(now: now) where byId[sid] == nil {
            byId[sid] = derive(chat)
        }
        return DemoTranscriptFeed(bySid: byId)
    }

    /// A chat drawer's turns as transcript entries.
    ///
    /// **Honest about what it is.** `/api/chat` has already destroyed the
    /// newlines and cut each turn at 900 characters, so a full log derived from
    /// one carries no tool traffic and no structure the drawer did not have —
    /// which is exactly what a demo of a session nobody hand-wrote should show,
    /// rather than invented depth.
    static func derive(_ chat: ChatTranscript) -> [TranscriptEntry] {
        chat.messages.enumerated().map { index, m in
            TranscriptEntry(off: startOff + index * 1024, i: 0,
                            role: m.role == .you ? .user : .assistant,
                            text: m.text, truncated: false, chars: nil, ts: m.ts,
                            meta: false, model: nil, why: nil, tool: nil)
        }
    }

    static let startOff = 8431006

    static let json = #"""
    [
      {
        "role": "user",
        "text": "put the incremental reindex behind a flag and measure it against the full pass",
        "ts": "2027-01-15T07:20:00.000Z",
        "meta": false,
        "model": null,
        "off": 8431006,
        "i": 0
      },
      {
        "role": "system",
        "text": "<system-reminder>\nThe user opened this session from a worktree with uncommitted changes in search/index/. Do not revert them.\n</system-reminder>",
        "ts": "2027-01-15T07:20:00.000Z",
        "meta": true,
        "model": null,
        "why": "system",
        "off": 8431596,
        "i": 0
      },
      {
        "role": "assistant",
        "text": "The measurement is the only baseline that exists, so it goes first. A full pass is ~4m12s wall and holds the write lock for 38s of it — the lock is the number that matters, because a warm search during a rebuild is the actual requirement. If the incremental path cannot hold the lock for under a second there is no point shipping it behind a flag either.",
        "ts": "2027-01-15T07:21:00.000Z",
        "meta": true,
        "model": "claude-fable-5",
        "why": "thinking",
        "off": 8432252,
        "i": 0
      },
      {
        "role": "assistant",
        "text": "Starting from the measurement, since the current pass is the only baseline we have: a full reindex is 4m12s and holds the write lock for 38s of it. I'll build the incremental path behind SEARCH_INCREMENTAL_REINDEX and run both against the same fixture set.",
        "ts": "2027-01-15T07:21:00.000Z",
        "meta": false,
        "model": "claude-fable-5",
        "off": 8432252,
        "i": 1
      },
      {
        "role": "tool_use",
        "text": "{\n  \"file_path\": \"search/index/shardmap.py\"\n}",
        "ts": "2027-01-15T07:21:08.000Z",
        "meta": false,
        "model": "claude-fable-5",
        "tool": {
          "name": "Read",
          "id": "toolu_01aReadShardmap",
          "ok": null
        },
        "off": 8433374,
        "i": 0
      },
      {
        "role": "tool_result",
        "text": "     1\timport hashlib\n     2\timport json\n     3\timport logging\n     4\timport os\n     5\timport threading\n     6\tfrom dataclasses import dataclass, field\n     7\tfrom pathlib import Path\n     8\t\n     9\tlog = logging.getLogger(__name__)\n    10\t\n    11\tSHARD_COUNT = 96\n    12\tLOCK_TIMEOUT_S = 45.0\n    13\t\n    14\t\n    15\t@dataclass\n    16\tclass Shard:\n    17\t    index: int\n    18\t    path: Path\n    19\t    doc_count: int = 0\n    20\t    dirty: bool = False\n    21\t    write_log_position: int = 0\n    22\t    checksum: str = \"\"\n    23\t\n    24\t    def fingerprint(self) -> str:\n    25\t        h = hashlib.sha256()\n    26\t        h.update(str(self.index).encode())\n    27\t        h.update(str(self.doc_count).encode())\n    28\t        h.update(str(self.write_log_position).encode())\n    29\t        return h.hexdigest()[:16]\n    30\t\n    31\t\n    32\t@dataclass\n    33\tclass ShardMap:\n    34\t    root: Path\n    35\t    shards: list = field(default_factory=list)\n    36\t    _lock: threading.RLock = field(default_factory=threading.RLock)\n    37\t\n    38\t    @classmethod\n    39\t    def load(cls, root: Path) -> \"ShardMap\":\n    40\t        m = cls(root=root)\n    41\t        manifest = root / \"shardmap.json\"\n    42\t        if not manifest.exists():\n    43\t            log.info(\"no shard map at %s; building from scratch\", manifest)\n    44\t            return m.rebuild_full()\n    45\t        raw = json.loads(manifest.read_text())\n    46\t        for entry in raw.get(\"shards\", []):\n    47\t            m.shards.append(Shard(\n    48\t                index=entry[\"index\"],\n    49\t                path=root / entry[\"path\"],\n    50\t                doc_count=entry.get(\"doc_count\", 0),\n    51\t                write_log_position=entry.get(\"write_log_position\", 0),\n    52\t                checksum=entry.get(\"checksum\", \"\"),\n    53\t            ))\n    54\t        return m\n    55\t\n    56\t    def rebuild_full(self) -> \"ShardMap\":\n    57\t        # THE 38-SECOND PATH. Holds the write lock for the whole walk\n    58\t        # because every shard is re-derived from the corpus, not from the\n    59\t        # write log. This is what the incremental path replaces.\n    60\t        with self._lock:\n    61\t            self.shards = []\n    62\t            for i in range(SHARD_COUNT):\n    63\t                path = self.root / f\"shard-{i:03d}.idx\"\n    64\t                shard = Shard(index=i, path=path)\n    65\t                shard.doc_count = _count_documents(path)\n    66\t                shard.checksum = shard.fingerprint()\n    67\t                self.shards.append(shard)\n    68\t            self._write_manifest()\n    69\t        return self\n    70\t\n    71\t    def rebuild_incremental(self, log_position: int) -> list:\n    72\t        # Only the shards a write actually landed in. On the fixture\n    73\t        # corpus that is 7 of 96, and the lock is held for 0.4s.\n    74\t        touched = []\n    75\t        with self._lock:\n    76\t            for shard in self.shards:\n    77\t                if shard.write_log_position >= log_position:\n    78\t                    continue\n    79\t                shard.doc_count = _count_documents(shard.path)\n    80\t                shard.checksum = shard.fingerprint()\n    81\t                shard.write_log_position = log_position\n    82\t                touched.append(shard.index)\n    83\t            self._write_manifest()\n    84\t        return touched\n    85\t\n    86\t    def _write_manifest(self) -> None:\n    87\t        payload = {\n    88\t            \"version\": 3,\n    89\t            \"shard_count\": len(self.shards),\n    90\t            \"shards\": [\n    91\t                {\n    92\t                    \"index\": s.index,\n    93\t                    \"path\": s.path.name,\n    94\t                    \"doc_count\": s.doc_count,\n    95\t                    \"write_log_position\": s.write_log_position,\n    96\t                    \"checksum\": s.checksum,\n    97\t                }\n    98\t                for s in self.shards\n    99\t            ],\n   100\t        }\n   101\t        tmp = self.root / \"shardmap.json.tmp\"\n   102\t        tmp.write_text(json.dumps(payload, indent=2))\n   103\t        os.replace(tmp, self.root / \"shardmap.json\")\n   104\t\n   105\t\n   106\tdef _count_documents(path: Path) -> int:\n   107\t    if not path.exists():\n   108\t        return 0\n   109\t    total = 0\n   110\t    with path.open(\"rb\") as fh:\n   111\t        for line in fh:\n   112\t            if line.startswith(b\"\\x00doc\"):\n   113\t                total += 1\n   114\t    return total\n   115\t\n   116\t\n   117\tdef _corpus_paths(root: Path):\n   118\t    for dirpath, _dirnames, filenames in os.walk(root):\n   119\t        for name in sorted(filenames):\n   120\t            if name.endswith(\".idx\"):\n   121\t                yield Path(dirpath) / name\n",
        "ts": "2027-01-15T07:21:09.000Z",
        "meta": false,
        "model": null,
        "tool": {
          "name": "Read",
          "id": "toolu_01aReadShardmap",
          "ok": true
        },
        "off": 8433931,
        "i": 0
      },
      {
        "role": "assistant",
        "text": "`rebuild_full` is the 38-second path and it is 38 seconds because it re-derives every one of the 96 shards from the corpus. The write log already knows which shards moved — nothing reads it.",
        "ts": "2027-01-15T07:22:30.000Z",
        "meta": false,
        "model": "claude-fable-5",
        "off": 8439151,
        "i": 0
      },
      {
        "role": "tool_use",
        "text": "{\n  \"pattern\": \"write_log_position\",\n  \"path\": \"search/\"\n}",
        "ts": "2027-01-15T07:22:40.000Z",
        "meta": false,
        "model": "claude-fable-5",
        "tool": {
          "name": "Grep",
          "id": "toolu_02Grep",
          "ok": null
        },
        "off": 8439853,
        "i": 0
      },
      {
        "role": "tool_result",
        "text": "search/index/shardmap.py:21:    write_log_position: int = 0\nsearch/index/shardmap.py:77:                if shard.write_log_position >= log_position:\nsearch/index/shardmap.py:81:                shard.write_log_position = log_position\nsearch/index/writer.py:143:        self.write_log_position += 1\nsearch/index/writer.py:210:    def log_position(self) -> int:\ntests/test_reindex.py:88:           touched = m.rebuild_incremental(corpus.log_position())\n",
        "ts": "2027-01-15T07:22:41.000Z",
        "meta": false,
        "model": null,
        "tool": {
          "name": "Grep",
          "id": "toolu_02Grep",
          "ok": true
        },
        "off": 8440423,
        "i": 0
      },
      {
        "role": "tool_use",
        "text": "{\n  \"command\": \"pytest tests/test_reindex.py -x -q\",\n  \"description\": \"run the reindex suite\"\n}",
        "ts": "2027-01-15T07:26:02.000Z",
        "meta": false,
        "model": "claude-fable-5",
        "tool": {
          "name": "Bash",
          "id": "toolu_03BashFail",
          "ok": null
        },
        "off": 8441385,
        "i": 0
      },
      {
        "role": "tool_result",
        "text": "============================= test session starts ==============================\nplatform darwin -- Python 3.12.4, pytest-8.2.0, pluggy-1.5.0\nrootdir: /Users/dev/search-index\ncollected 41 items\n\ntests/test_reindex.py ................F                                  [ 41%]\n\n=================================== FAILURES ===================================\n______________ test_incremental_survives_a_write_during_rebuild ________________\n\n    def test_incremental_survives_a_write_during_rebuild():\n        corpus = fixture_corpus(shards=96)\n        m = ShardMap.load(corpus.root)\n        with concurrent_writer(corpus, shard=17):\n>           touched = m.rebuild_incremental(corpus.log_position())\nE           AssertionError: shard 17 reports doc_count=1204, corpus has 1205\nE           assert 1204 == 1205\n\ntests/test_reindex.py:88: AssertionError\n=========================== short test summary info ============================\nFAILED tests/test_reindex.py::test_incremental_survives_a_write_during_rebuild\n<tool_use_error>1 failed, 16 passed in 3.41s</tool_use_error>\n",
        "ts": "2027-01-15T07:26:06.000Z",
        "meta": false,
        "model": null,
        "tool": {
          "name": "Bash",
          "id": "toolu_03BashFail",
          "ok": false
        },
        "off": 8441992,
        "i": 0
      },
      {
        "role": "assistant",
        "text": "That is the concurrent case, and it is a real defect rather than a flaky fixture: the rebuild reads the write-log position once, so a write that lands mid-walk is dropped until the next pass. Reading it before and after, and re-running any shard whose position moved, closes it.",
        "ts": "2027-01-15T07:26:20.000Z",
        "meta": false,
        "model": "claude-fable-5",
        "off": 8443575,
        "i": 0
      },
      {
        "role": "tool_use",
        "text": "{\n  \"file_path\": \"search/index/shardmap.py\",\n  \"old_string\": \"        touched = []\\n        with self._lock:\",\n  \"new_string\": \"        touched = []\\n        with self._lock:\\n            before = log_position\"\n}",
        "ts": "2027-01-15T07:27:00.000Z",
        "meta": false,
        "model": "claude-fable-5",
        "tool": {
          "name": "Edit",
          "id": "toolu_04Edit",
          "ok": null
        },
        "off": 8444365,
        "i": 0
      },
      {
        "role": "tool_result",
        "text": "The file search/index/shardmap.py has been updated. Here is the result:\n    69\t        return self\n    70\t\n    71\t    def rebuild_incremental(self, log_position: int) -> list:\n    72\t        # Only the shards a write actually landed in, and the log\n    73\t        # position is read TWICE: once before the walk and once after,\n    74\t        # so a write that lands mid-rebuild re-runs its shard instead\n    75\t        # of being dropped until the next pass.\n    76\t        touched = []\n    77\t        with self._lock:\n    78\t            before = log_position\n    79\t            for shard in self.shards:\n",
        "ts": "2027-01-15T07:27:01.000Z",
        "meta": false,
        "model": null,
        "tool": {
          "name": "Edit",
          "id": "toolu_04Edit",
          "ok": true
        },
        "off": 8445089,
        "i": 0
      },
      {
        "role": "user",
        "text": "does it stay correct if two writes hit the same shard while the reindex is running",
        "ts": "2027-01-15T07:36:00.000Z",
        "meta": false,
        "model": null,
        "off": 8446206,
        "i": 0
      },
      {
        "role": "user",
        "text": "<system-reminder>Plan mode is off. toolu_04Edit completed.</system-reminder>",
        "ts": "2027-01-15T07:36:01.000Z",
        "meta": true,
        "model": null,
        "why": "machine-text",
        "off": 8446800,
        "i": 0
      },
      {
        "role": "assistant",
        "text": "Two writes to one shard is the same case as one, as long as the position is compared rather than counted. The test should write twice to shard 17 and assert the doc count once.",
        "ts": "2027-01-15T07:36:30.000Z",
        "meta": true,
        "model": "claude-fable-5",
        "why": "thinking",
        "off": 8447388,
        "i": 0
      },
      {
        "role": "assistant",
        "text": "It does now — it did not. I've sent a subagent at the concurrency fixtures while I finish the position check.",
        "ts": "2027-01-15T07:36:30.000Z",
        "meta": false,
        "model": "claude-fable-5",
        "off": 8447388,
        "i": 1
      },
      {
        "role": "tool_use",
        "text": "{\n  \"subagent_type\": \"general-purpose\",\n  \"description\": \"concurrency fixtures\",\n  \"prompt\": \"Write fixtures that drive two concurrent writes into one shard during a rebuild.\"\n}",
        "ts": "2027-01-15T07:36:40.000Z",
        "meta": false,
        "model": "claude-fable-5",
        "tool": {
          "name": "Task",
          "id": "toolu_05Task",
          "ok": null
        },
        "off": 8448185,
        "i": 0
      },
      {
        "role": "assistant",
        "text": "Reading tests/conftest.py for the existing corpus fixture before adding a concurrent writer.",
        "ts": "2027-01-15T07:37:00.000Z",
        "meta": true,
        "model": "claude-fable-5",
        "why": "sidechain",
        "off": 8448874,
        "i": 0
      },
      {
        "role": "tool_use",
        "text": "{\n  \"file_path\": \"tests/conftest.py\"\n}",
        "ts": "2027-01-15T07:37:02.000Z",
        "meta": true,
        "model": "claude-fable-5",
        "why": "sidechain",
        "tool": {
          "name": "Read",
          "id": "toolu_06SubRead",
          "ok": null
        },
        "off": 8449478,
        "i": 0
      },
      {
        "role": "tool_result",
        "text": "     1\timport pytest\n     2\t\n     3\t@pytest.fixture\n     4\tdef fixture_corpus(tmp_path):\n     5\t    return build_corpus(tmp_path, shards=96)\n",
        "ts": "2027-01-15T07:37:03.000Z",
        "meta": true,
        "model": null,
        "why": "sidechain",
        "tool": {
          "name": "Read",
          "id": "toolu_06SubRead",
          "ok": true
        },
        "off": 8450028,
        "i": 0
      },
      {
        "role": "tool_result",
        "text": "Added tests/test_reindex_concurrent.py with a concurrent_writer context manager and three cases: one write, two writes to one shard, and a write that lands after the walk has passed the shard.",
        "ts": "2027-01-15T07:44:12.000Z",
        "meta": false,
        "model": null,
        "tool": {
          "name": "Task",
          "id": "toolu_05Task",
          "ok": true
        },
        "off": 8450681,
        "i": 0
      },
      {
        "role": "tool_use",
        "text": "{\n  \"command\": \"pytest tests/ -q\",\n  \"description\": \"full suite after the position fix\"\n}",
        "ts": "2027-01-15T07:45:00.000Z",
        "meta": false,
        "model": "claude-fable-5",
        "tool": {
          "name": "Bash",
          "id": "toolu_07BashPass",
          "ok": null
        },
        "off": 8451385,
        "i": 0
      },
      {
        "role": "tool_result",
        "text": "============================= test session starts ==============================\nplatform darwin -- Python 3.12.4, pytest-8.2.0, pluggy-1.5.0\nrootdir: /Users/dev/search-index\ncollected 41 items\n\ntests/test_reindex.py .........................................          [100%]\n\n============================== 41 passed in 4.12s ==============================\n",
        "ts": "2027-01-15T07:45:05.000Z",
        "meta": false,
        "model": null,
        "tool": {
          "name": "Bash",
          "id": "toolu_07BashPass",
          "ok": true
        },
        "off": 8451986,
        "i": 0
      },
      {
        "role": "assistant",
        "text": "The shard map now rebuilds from the write log rather than from a full scan, so a reindex touches only the shards a write actually landed in. On the fixture corpus that is 7 shards out of 96, and the lock is held for 0.4s instead of 38s.",
        "ts": "2027-01-15T07:51:00.000Z",
        "meta": false,
        "model": "claude-fable-5",
        "off": 8452855,
        "i": 0
      },
      {
        "role": "tool_use",
        "text": "{\n  \"command\": \"python -m bench.reindex --compare --runs 3\"\n}",
        "ts": "2027-01-15T07:51:30.000Z",
        "meta": false,
        "model": "claude-fable-5",
        "tool": {
          "name": "Bash",
          "id": "toolu_08Bench",
          "ok": null
        },
        "off": 8453603,
        "i": 0
      },
      {
        "role": "tool_result",
        "text": "full pass          incremental\n-----------------  -----------------\n4m12.331s          0m03.914s\n4m09.882s          0m03.771s\n4m14.006s          0m04.102s\n-----------------  -----------------\nlock held  38.4s   lock held  0.41s\nshards     96/96   shards      7/96\n",
        "ts": "2027-01-15T07:53:44.000Z",
        "meta": false,
        "model": null,
        "tool": {
          "name": "Bash",
          "id": "toolu_08Bench",
          "ok": true
        },
        "off": 8454176,
        "i": 0
      },
      {
        "role": "tool_use",
        "text": "{\n  \"file_path\": \"docs/search-reindex.md\",\n  \"content\": \"# Reindex\\n\\nTwo paths, one flag.\\n\"\n}",
        "ts": "2027-01-15T07:54:00.000Z",
        "meta": false,
        "model": "claude-fable-5",
        "tool": {
          "name": "Write",
          "id": "toolu_09Write",
          "ok": null
        },
        "off": 8454952,
        "i": 0
      },
      {
        "role": "tool_result",
        "text": "File created successfully at docs/search-reindex.md",
        "ts": "2027-01-15T07:54:01.000Z",
        "meta": false,
        "model": null,
        "tool": {
          "name": "Write",
          "id": "toolu_09Write",
          "ok": true
        },
        "off": 8455559,
        "i": 0
      },
      {
        "role": "system",
        "text": "Reindex made incremental behind SEARCH_INCREMENTAL_REINDEX; lock time 38s -> 0.4s; concurrency defect found and fixed.",
        "ts": "2027-01-15T07:54:30.000Z",
        "meta": true,
        "model": null,
        "why": "summary",
        "off": 8456122,
        "i": 0
      },
      {
        "role": "user",
        "text": "good. what is left",
        "ts": "2027-01-15T07:55:00.000Z",
        "meta": false,
        "model": null,
        "off": 8456752,
        "i": 0
      },
      {
        "role": "user",
        "text": "[image]",
        "ts": "2027-01-15T07:55:02.000Z",
        "meta": true,
        "model": null,
        "why": "image",
        "off": 8457282,
        "i": 0
      },
      {
        "role": "tool_use",
        "text": "{\n  \"command\": \"git diff --stat\"\n}",
        "ts": "2027-01-15T07:56:00.000Z",
        "meta": false,
        "model": "claude-fable-5",
        "tool": {
          "name": "Bash",
          "id": "toolu_10Stat",
          "ok": null
        },
        "off": 8457801,
        "i": 0
      },
      {
        "role": "tool_result",
        "text": " search/index/shardmap.py            | 34 ++++++++++---\n search/index/writer.py              |  6 ++-\n tests/test_reindex_concurrent.py    | 96 +++++++++++++++++++++++\n docs/search-reindex.md              | 41 +++++++++++\n 4 files changed, 171 insertions(+), 6 deletions(-)\n",
        "ts": "2027-01-15T07:56:01.000Z",
        "meta": false,
        "model": null,
        "tool": {
          "name": "Bash",
          "id": "toolu_10Stat",
          "ok": true
        },
        "off": 8458347,
        "i": 0
      },
      {
        "role": "system",
        "text": "<task-notification>The nightly full pass is still scheduled at 03:00 and has not been touched.</task-notification>",
        "ts": "2027-01-15T07:58:00.000Z",
        "meta": true,
        "model": null,
        "why": "attachment",
        "off": 8459133,
        "i": 0
      },
      {
        "role": "assistant",
        "text": "Only the nightly full pass. It costs 4m12s of lock-free work every night and, with the incremental path correct, it is a safety net rather than a mechanism. Before I delete it: keep it as a safety net, or remove it outright?",
        "ts": "2027-01-15T07:59:13.000Z",
        "meta": false,
        "model": "claude-fable-5",
        "off": 8459759,
        "i": 0
      }
    ]
    """#
}

/// A canned transcript that answers the two real routes.
///
/// The page walk is the server's, restated: **whole lines only** (a block's
/// `(off, i)` identity is meaningless if half a line can arrive), `before`
/// exclusive, `has_more_before` false only when the oldest line was actually
/// reached, and `cursor_before` the `off` of the oldest line returned.
public struct DemoTranscriptFeed: TranscriptSource, Sendable {
    let bySid: [String: [TranscriptEntry]]

    public init(bySid: [String: [TranscriptEntry]]) {
        self.bySid = bySid
    }

    /// One identity per sid, stable for the life of the demo — so the store's
    /// compaction check runs and finds nothing, which is the correct answer for
    /// a file that is not being rewritten.
    func file(for entries: [TranscriptEntry]) -> TranscriptFile {
        TranscriptFile(size: (entries.last?.off ?? 0) + 512,
                       ino: 8_812_004, dev: 16_777_233,
                       mtimeNs: 1_800_000_000_000_000_000)
    }

    public func transcriptPage(account: String, sid: String, limit: Int,
                               before: Int?) async throws -> TranscriptPage {
        guard let all = bySid[sid] else {
            return TranscriptPage(ok: false, error: "transcript not found")
        }
        let capped = all.map { TranscriptRules.cap($0, at: TranscriptRules.pagedCap) }
        let eligible = before.map { cut in capped.filter { $0.off < cut } } ?? capped
        // Group by line, then take whole lines from the end until `limit` is met.
        var lines: [[TranscriptEntry]] = []
        for entry in eligible {
            if lines.last?.first?.off == entry.off {
                lines[lines.count - 1].append(entry)
            } else {
                lines.append([entry])
            }
        }
        var picked: [[TranscriptEntry]] = []
        var count = 0
        for line in lines.reversed() {
            if !picked.isEmpty && count + line.count > limit { break }
            picked.insert(line, at: 0)
            count += line.count
        }
        let messages = picked.flatMap { $0 }
        let more = picked.count < lines.count
        return TranscriptPage(ok: true, sid: sid, account: account, format: "raw",
                              messages: messages, hasMoreBefore: more,
                              cursorBefore: more ? messages.first?.off : nil,
                              file: file(for: all))
    }

    public func transcriptEntry(account: String, sid: String, off: Int,
                                i: Int?) async throws -> TranscriptPage {
        guard let all = bySid[sid] else {
            return TranscriptPage(ok: false, error: "transcript not found")
        }
        let line = all.filter { $0.off == off && (i == nil || $0.i == i) }
        guard !line.isEmpty else {
            return TranscriptPage(ok: false, error: "no entry at that offset")
        }
        return TranscriptPage(ok: true, sid: sid, account: account, format: "raw",
                              messages: line.map {
                                  TranscriptRules.cap($0, at: TranscriptRules.entryCap)
                              },
                              hasMoreBefore: false, cursorBefore: nil, off: off,
                              file: file(for: all))
    }
}
