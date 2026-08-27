# Word-boundary-independent vocabulary matching

- Date: 2026-08-28
- Status: implemented
- Report: a configured `posthog` entry did not repair Parakeet output such as `post hoc` or `post hog`.

## User outcome

Words and expressions entered under **Your Words** are restored even when the speech model inserts or removes lexical whitespace. Corrections keep surrounding words and punctuation intact and remain conservative when two configured outcomes are equally supported.

## Problem class and mechanism

The shared vocabulary corrector required a configured term and transcript candidate to have the same word count. That treated ASR word boundaries as semantic evidence even though speech recognition routinely invents or removes them.

The same mechanism affected compact product names such as `posthog`, `glitchtip`, and `n8n`, plus the reverse case where a configured multiword expression such as `Claude Code` arrives merged. `Vaultwarden` becoming `World Warden` is a different phonetic-distance case and remains outside the conservative edit threshold.

## Invariant

A configured expression's identity ignores lexical whitespace. Only the strongest compatible visible edits are applied: lower edit distance wins, then a source span explaining more words wins. Equal evidence that produces different text is left unchanged; equal evidence producing the same edit is applied once. Matches never cross punctuation, and selected edits compose without depending on mutation order.

## Chosen design

The shared `VocabularyCorrector` enumerates immutable compact-form candidates, removes same-term supersets already explained by better interior evidence, converts each candidate into its exact normalized half-open token edit, resolves overlaps by evidence priority and visible outcome, and applies compatible edits right-to-left.

This keeps the policy in the existing owner used by both engines and both workflows. It also makes insertions, deletions, boundary merges, boundary splits, ambiguity, and equivalent overlapping evidence explicit parts of one model.

## Alternatives rejected

- Removing **Your Words** was rejected because it eliminates an intended user capability instead of restoring it.
- Merely allowing a one-token term to inspect two transcript words was rejected as a `posthog`-specific patch that leaves reverse merges and other boundary shapes broken.
- A greedy compact matcher was rejected after it consumed neighboring words (`a post hog` became `posthog`).
- Weighted interval plans keyed by candidate identity were rejected because different plans can produce the same visible transcript and because cumulative candidate sets carried avoidable copy-on-write cost.
- Configured-key length as a global priority was rejected because it guessed between equally close alternatives such as `PostHog` and `PostHogs`.
- Closed replacement ranges were rejected because they cannot represent insertion points and allowed equivalent insertions to apply twice.

## Adversarial result and reversal trigger

The patch detector returned `STRUCTURAL` after challenging containment, ambiguity, equivalent outputs, insertion/deletion/identity effects, transitive conflicts, priority, occupancy, and right-to-left index safety. Earlier `PATCH` verdicts supplied the regressions above; each became a permanent test.

Revisit the implementation if production-sized meeting transcripts show candidate normalization to be material in profiles: exact visible-effect normalization currently costs `O(C × N)` for `C` eligible non-identity candidates over `N` transcript tokens. Optimize that representation without weakening the invariant or replacing proof with greedy local behavior.
