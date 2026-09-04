# Meeting corpus architecture

MyWhispr's workspace conversation answers from completed meeting recordings only.
Dictations, unfinished recordings, earlier AI answers, and the owner's questions are
not retrieval sources.

## Current data flow

```text
question + relevant follow-up + captured local clock
                         │
                         ▼
                 MeetingQueryPlan
             ┌───────────┴───────────┐
             ▼                       ▼
      topical lookup          exhaustive/comparison
   BM25 + dense retrieval     SQL date-filtered corpus
             │                       │
             └───────────┬───────────┘
                         ▼
             bounded MeetingEvidence[]
                         │
                         ▼
             local model + passage IDs
                         │
                         ▼
          validated answer + source controls
```

`MeetingPassageBuilder` groups complete speaker turns around a 1,400-character
target and overlaps one turn at boundaries. This preserves the speaker and timestamp
needed to inspect an answer. `AppDatabase.rebuildSearchIndex` is the single owner of
both the Library search projection and the meeting-passage projection; transcript
edits, speaker renames, title/summary changes, deletion, and migration all pass
through it.

`MeetingQueryPlanner` resolves supported relative and ISO dates against the captured
local clock before search, classifies exhaustive and comparison questions, and carries
only the immediately relevant question into a short follow-up. SQL applies time ranges
before either sparse or semantic ranking.

Generated title/summary metadata and transcript evidence have separate indexes. A
metadata match may select a meeting to read, but a generated summary can no longer
rank an arbitrary transcript passage as though it supported the answer. Topical search
combines SQLite BM25 and optional local embeddings with reciprocal-rank fusion, expands
adjacent passages for context, then admits at most three passages per meeting and twelve
overall within the configured context budget. The embedding cache is keyed by passage
text hash and the Ollama model digest; transcript edits invalidate it transactionally.
Missing vectors are filled in bounded background batches and Settings exposes the
exact progress. Until the first backfill finishes, answers explicitly disclose partial
semantic coverage while exact transcript search remains available.

An exhaustive or comparison query reads every passage in the SQL-filtered meeting set.
If that complete set cannot fit, the request fails explicitly and asks for a narrower
date range or larger context instead of returning a partial answer labelled as complete.
Admitted passages are grouped into one source per meeting before IDs are assigned, so
retrieval detail cannot create duplicate meeting cards. The prompt treats transcript content as untrusted evidence,
requires refusal when the evidence is insufficient, includes one captured local date,
time, and time zone, and requires exact source/passage citations such as `[S1:P2]`.
References outside the supplied evidence are rejected, and only cited passages are
snapshotted with the answer. A source card opens
on the meeting summary when one exists and can switch to the cited transcript passages;
each passage can reopen or play the meeting at its timestamp. Deleting a meeting
disables navigation but does not erase the answer's evidence or its immutable source
identity.

Conversation ownership is explicit: `ConversationScope.meeting(id)` and
`ConversationScope.allMeetings` are separate database aggregates. The schema keeps
their messages isolated, preserves pre-existing per-meeting conversations during
migration, and cascades a deleted meeting into its own conversation. Erasing all
content clears the workspace conversation but recreates its empty aggregate so the
next question works without a relaunch.

## Why search is hybrid

Retrieval-augmented generation works by giving generation an explicit external
evidence set rather than relying on model memory ([RAG paper](https://arxiv.org/abs/2005.11401)).
That does not require vectors. SQLite FTS5 already provides local tokenization,
BM25 ranking, and a transactional index in the database MyWhispr owns
([SQLite FTS5](https://www.sqlite.org/fts5.html)). Bounded passages also avoid the
well-documented degradation that occurs when relevant facts are buried in long
contexts ([Lost in the Middle](https://arxiv.org/abs/2307.03172)).

SQLite FTS5 remains the exact lexical lane for names, quotations, and product terms.
When an embedding model is selected, MyWhispr batches missing passage embeddings through
the configured local service and stores the vectors inside its own SQLite database
([Ollama embeddings](https://docs.ollama.com/capabilities/embeddings)). Reciprocal-rank
fusion combines lexical and semantic ranks without making their incompatible scores
pretend to share a scale.

## Evaluation path

Keep an anonymized set of real questions with expected meetings, passages, and facts.
Track meeting and passage recall, supported-claim precision, answer completeness,
correct abstention, and p50/p95 latency. Classify misses as multilingual semantics,
entity aliases, time parsing, ranking distractors, or corpus aggregation before adding
a reranker or another model stage.

## Known limits

- Semantic search is optional; exact-only search still misses synonyms and
  cross-language paraphrases when no embedding model is selected.
- Relative-date parsing currently covers today, yesterday, this/last week,
  this/last month, this quarter, and ISO dates in English and Russian.
- Large exhaustive scopes are rejected rather than map/reduced. A future hierarchical
  extraction path may preserve complete coverage without requiring one context window.
- Citation validation proves that a referenced passage exists in the supplied evidence;
  it does not itself prove semantic entailment.
- With exactly one detected microphone voice, version 1 retains the personal-app
  convention that it is `You`; this is not biometric identity.
