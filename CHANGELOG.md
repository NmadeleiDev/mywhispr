# Changelog

All notable changes to MyWhispr will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and the project intends to follow [Semantic Versioning](https://semver.org/) once
the public API and release process stabilize.

## [Unreleased]

## [0.3.0] - 2026-09-04

### Added

- A persistent Home conversation for asking questions across every completed
  meeting, with date-aware query planning, bounded transcript evidence, and
  durable source cards that open the cited recording.
- Optional multilingual semantic meeting search through local Ollama or
  OpenAI-compatible embedding models, fused with SQLite full-text search and
  indexed incrementally in the background.
- Passage-level answer citations with persisted evidence snapshots, summary and
  transcript source views, and playback from each cited timestamp.
- Microphone-only meeting capture when Mac audio is unavailable, plus automatic
  removal of accidental recordings shorter than ten seconds.

### Changed

- Reworked the main window around dedicated Home and Library destinations, a
  clearer meeting/dictation split, and an all-meetings composer that remains
  available throughout a conversation.
- Applied speaker separation to both microphone and Mac-audio tracks, with
  collision-free speaker names and chronological transcript merging.
- Made local model discovery connection-specific and exposed semantic-index
  readiness in AI settings.

### Fixed

- Replaced persistent, layout-shifting status banners with accessible floating
  notifications that dismiss automatically and remain visible longer for warnings
  and failures.
- Prevented cancelled transcription jobs and stale model-catalog requests from
  publishing late results into newer work.
- Scoped note-generation status to the meeting that owns it and preserved the
  selected meeting surface during ordinary SwiftUI refreshes.
- Made stopping an in-progress meeting discard its provisional database record
  and retained audio consistently.

## [0.2.0] - 2026-08-31

### Added

- Configurable output language for generated meeting notes, including an option
  to follow the transcript language.
- LLM-generated recording titles saved with summaries and displayed throughout
  meeting history.
- Native rendering for Markdown tables and common model-generated mathematical
  notation in meeting summaries.

### Fixed

- Scoped summary-generation progress and cancellation to the recording that owns
  the request instead of showing activity on every meeting.
- Preserved table rows, alignment, currency, and common symbols when rendering
  model-generated Markdown.

### Project

- Open-source project documentation, community standards, issue forms, pull
  request guidance, and macOS continuous integration.
- MIT licensing for the application and CLI.

## [0.1.0] - 2026-08-28

### Added

- Native macOS menu-bar dictation with focused-control insertion, history,
  configurable shortcuts, vocabulary correction, and local retention controls.
- Dual-track microphone/system-audio meeting recording, offline transcription,
  speaker diarization, full-text search, editing, synchronized playback, and
  recovery from interrupted processing.
- FluidAudio and WhisperKit model catalog with independent dictation and meeting
  profiles.
- Optional Ollama and OpenAI-compatible rewriting, meeting summaries, and
  transcript-grounded conversational questions.
- Scriptable local audio transcription CLI with text and JSON output.
