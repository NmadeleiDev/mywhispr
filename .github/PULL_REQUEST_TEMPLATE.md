## What changed

<!-- Describe the user-visible problem and the resulting behavior. -->

## Why this design

<!-- Explain important choices, alternatives, compatibility effects, and any new dependency. -->

## Verification

<!-- List exact commands and results, then describe the real app or CLI smoke-test journey. -->

- [ ] `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`
- [ ] `./scripts/build-app.sh`
- [ ] Packaged CLI `--version` and `--help` smoke test
- [ ] Changed behavior exercised through the real app or CLI

## Checklist

- [ ] The change is focused and does not discard unrelated work.
- [ ] Tests cover the new behavior and important failure paths.
- [ ] User-facing documentation and CLI help are updated where needed.
- [ ] No recording, transcript, database, model, credential, or personal path is committed.
- [ ] New or changed dependencies were checked for current support, compatibility, license, and security advisories.
- [ ] Third-party attribution is updated where needed.
- [ ] I agree to license this contribution under the MIT License.
