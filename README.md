# MyWhispr

MyWhispr is a native macOS 26 utility for private, local dictation and meeting
transcription. Hold Right Command, speak, and release to insert text into the
focused app. Meeting recordings keep microphone and system audio locally and
are transcribed after the meeting with speaker separation.

## Workflows

- **Dictation:** hold Right Command, speak, and release. MyWhispr captures the
  original focused control, transcribes locally, then inserts through the
  Accessibility API. If focus changes or the control is secure, the result is
  copied instead. Clipboard paste is a compatibility fallback and restores the
  previous clipboard contents when the receiving app leaves them untouched.
- **Meetings:** press Control–Option–Command–M to start or stop. Microphone and
  system output are stored as separate local tracks, transcribed after stop,
  diarized, de-duplicated for acoustic echo, and indexed for search. A track
  with no signal is skipped rather than failing the meeting, so a solo recording
  with nothing playing on the Mac still produces a transcript.
- **Independent models:** dictation and meetings have separate engine, model,
  and language settings. The defaults are FluidAudio Parakeet TDT v3 for
  responsive dictation and WhisperKit's compact Large v3 model for long-form
  meetings. Each model's download size is stated before it is downloaded.
- **One vocabulary:** names, jargon, and product names are a single app-wide
  list rather than one per workflow. Close misses are rewritten back to the
  given spelling in both dictation and meetings; short entries must match
  exactly, and an entry equally close to two others is left alone.
- **Recent dictations:** Option–Command–V summons a palette of what was said
  recently and inserts the chosen line at the cursor. Control–Option–Command–O
  opens the main window.
- **Ask a meeting questions:** a finished meeting has a Transcript / Ask switch.
  Ask sends the whole transcript — with speakers and timestamps — to your local
  model and answers from it, as a conversation that is kept with the meeting.
  Answers stream as they are written and can be stopped, keeping what arrived.
  Because the model must hold the entire meeting, MyWhispr asks Ollama for a
  context window large enough for it, up to a ceiling you set; when a meeting
  will not fit, it says so instead of letting the server silently drop the
  beginning.
- **Local AI (optional):** faithful speech-to-text is the default. Rewriting,
  meeting summaries, and meeting questions can use Ollama or a loopback
  OpenAI-compatible endpoint. LAN endpoints require a separate explicit setting.

Failed dictation audio is retained for 24 hours for recovery. Completed
dictation audio is removed immediately; dictation text retention defaults to
30 days. Meeting tracks, transcripts, edits, titles, summaries, and the
questions asked about a meeting remain in `~/Library/Application
Support/MyWhispr` until deleted in the app. Questions are deleted with their
meeting and are not part of the search index — searching meetings searches what
was said, not what you asked.

## Requirements

- Apple silicon Mac running macOS 26 or newer
- Xcode 26.6 or newer
- Microphone and Accessibility permissions. Input Monitoring is **not**
  required: Accessibility alone authorises the event tap that watches the
  dictation key. Meetings additionally need System Audio Recording.
- Optional: Ollama, LM Studio, or another local OpenAI-compatible server for
  rewriting, meeting summaries, and questions about a meeting. Answering
  questions loads the whole transcript, so a model with a large context window
  is worth having: roughly 8K tokens per half hour of speech.

## Build

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
./scripts/build-app.sh
open dist/MyWhispr.app
```

## Command line

The same executable can transcribe an existing audio file without launching the
menu-bar application. WAV, CAF, AIFF, MP3, M4A, FLAC, and Ogg-family inputs are
decoded locally; `.ogg` may contain Vorbis, Opus, or FLAC audio.

```sh
# Install or update the global user-level command in ~/.local/bin.
./scripts/install-cli.sh

# Fast default model; prints only the transcript to stdout.
mywhispr transcribe recording.ogg

# A specific multilingual WhisperKit model with structured output.
mywhispr recording.m4a --model small --language auto --format json

# The packaged app exposes the identical command.
dist/MyWhispr.app/Contents/MacOS/MyWhispr transcribe recording.ogg
```

On success the command writes only the transcript to stdout (or the requested
JSON document), with no progress output, so it can be used directly in scripts.
Errors go to stderr and return a nonzero exit status. Run `mywhispr --help` for
every engine, model, and output option. Models are downloaded on first use
exactly as they are in the app. The installer copies a fresh release build rather
than linking into `.build`, so `swift package clean` does not break the global
command; rerun it whenever MyWhispr is updated.

`DEVELOPER_DIR` is needed when `xcode-select` points at the Command Line Tools,
whose Swift driver does not find the bundled `Testing` framework.

The build script signs with the first identity it finds — `CODESIGN_IDENTITY`,
then Developer ID, then Apple Development, then any valid identity — and falls
back to ad-hoc with a warning. Prefer a real identity, even a self-signed one:
an ad-hoc signature's designated requirement is its own code hash, so macOS
treats every rebuild as a different application and every TCC permission has to
be granted again. Model downloads are explicit; transcription remains on-device
after a model is installed.

## Architecture

The app is a Swift 6.3 SwiftUI/AppKit executable under strict concurrency. The
only SwiftUI scene is the menu-bar extra; every window is owned by an AppKit
coordinator, because a menu-bar app can launch with no window and a global
hotkey arrives with no SwiftUI environment in reach. Realtime audio callbacks
are `@Sendable` and touch no main-actor state, so an isolation mistake is a
compile error rather than a crash mid-recording. Core Audio process taps record
system output without changing the selected output device. AVAudioEngine records
the microphone. GRDB owns the SQLite store and FTS5 index. FluidAudio provides
Parakeet, SenseVoice, and offline diarization; WhisperKit provides configurable
Whisper-family models and incremental long-form decoding.

The app intentionally has no cloud transcription path, account system, or
telemetry. See `Sources/MyWhispr/Resources/ThirdPartyNotices.txt` for dependency
and adapted-source attribution.
