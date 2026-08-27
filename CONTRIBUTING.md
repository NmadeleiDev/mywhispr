# Contributing to MyWhispr

Thank you for helping make private, local speech-to-text better on macOS.
Contributions of code, tests, documentation, bug reports, and product ideas are
welcome.

## Before opening an issue

- Search existing issues to avoid duplicates.
- Use the bug report form for reproducible defects and the feature request form
  for product proposals.
- Do not publish vulnerabilities or sensitive recordings in an issue. Follow
  [SECURITY.md](SECURITY.md) instead.
- Remove names, transcript content, file paths, and other private information from
  logs and screenshots.

## Development setup

MyWhispr currently requires an Apple silicon Mac with macOS 26 or newer and full
Xcode 26.6 or newer.

```sh
git clone https://github.com/NmadeleiDev/mywhispr.git
cd mywhispr
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
./scripts/build-app.sh
open dist/MyWhispr.app
```

If Xcode has a versioned application name, change `DEVELOPER_DIR` accordingly.
The standalone Command Line Tools are not enough for this package's test suite.

To exercise the CLI:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift run MyWhispr --help
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift run MyWhispr --version
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift run MyWhispr transcribe /path/to/audio.wav
```

The first real transcription may download a speech model. Use audio you have the
right to process and never commit recordings, transcripts, databases, downloaded
models, or credentials.

## Making a change

1. Create a focused branch from `main`.
2. Reproduce the problem or establish the missing behavior before editing.
3. Keep responsibilities in their existing owning layer. Improve a shared
   abstraction when needed instead of creating a second implementation of the
   same concept.
4. Add or update tests for observable behavior and important error paths.
5. Update the README, CLI help, notices, or changelog when user-visible behavior
   changes.
6. Run the complete validation below and exercise the changed flow through the
   real app or CLI.

Do not add a package from memory alone. Verify its current stable release,
maintenance status, macOS/Swift compatibility, license, and security advisories,
then explain why the dependency is preferable to a small local implementation.
Pin Swift packages consistently with the existing manifest.

## Code conventions

- Use Swift 6 strict concurrency. Treat isolation warnings as design problems,
  especially around realtime audio callbacks.
- Keep realtime callbacks `@Sendable` and free of main-actor access, allocation,
  disk I/O, and blocking work.
- Put user-visible language in the user's vocabulary; do not leak persistence or
  infrastructure terms into the interface.
- Preserve local-first behavior. Cloud transcription, telemetry, and mandatory
  accounts contradict the project's core contract.
- Keep failures explicit and recoverable. Do not silently replace failed work with
  plausible output.
- Match existing formatting and naming. The project intentionally has no
  repository-wide formatter that rewrites unrelated files.
- Include attribution in `Sources/MyWhispr/Resources/ThirdPartyNotices.txt` when
  adapting code or adding licensed assets.

## Validation

Run from the repository root:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
./scripts/build-app.sh
dist/MyWhispr.app/Contents/MacOS/MyWhispr --version
dist/MyWhispr.app/Contents/MacOS/MyWhispr --help
```

Then smoke-test the surface you changed:

- **Dictation:** focus an ordinary text field, dictate, and verify insertion as
  well as the copy fallback where relevant.
- **Meetings:** record both microphone and playing system audio, stop, wait for
  processing, and verify transcript, speakers, search, and playback.
- **CLI:** transcribe a small supported audio fixture and verify stdout, stderr,
  exit status, and JSON when applicable.
- **Local AI:** use a loopback test server or local model and verify timeout,
  cancellation, context-limit, and streaming behavior affected by the change.

Tests that require microphone, Accessibility, System Audio Recording, a model
download, or a local model server are not suitable as unattended CI gates. Keep
their pure logic covered by automated tests and report the manual run in the pull
request.

## Pull requests

Keep a pull request focused on one coherent outcome. Explain:

- the user-visible problem and resulting behavior;
- important design decisions and compatibility effects;
- exact automated commands and results;
- the real app or CLI journey used for the smoke test;
- any permissions, models, or local services needed to reproduce it.

All pull requests must pass CI and the [Code of Conduct](CODE_OF_CONDUCT.md).
Submission of a contribution means you agree to license it under the repository's
[MIT License](LICENSE).
