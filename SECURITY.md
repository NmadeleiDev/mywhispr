# Security policy

## Supported versions

MyWhispr is pre-1.0. Security fixes are made on the latest `main` branch and will
be included in the next published version. Older commits and locally modified
builds are not maintained as separate release lines.

| Version | Supported |
| --- | --- |
| Latest `main` | Yes |
| Older snapshots | No |

## Reporting a vulnerability

Do not open a public issue for a suspected vulnerability.

Use GitHub's private vulnerability reporting flow:

<https://github.com/NmadeleiDev/mywhispr/security/advisories/new>

Include the affected commit or version, macOS version, attack prerequisites,
reproduction steps or a proof of concept, expected impact, and any suggested
mitigation. Remove unrelated private audio, transcripts, model-server prompts,
tokens, and local file paths from the report.

The maintainers will acknowledge a complete report as soon as practical, verify
the issue, coordinate a fix and disclosure, and credit the reporter unless they
prefer to remain anonymous. Please allow time for a patched version to be prepared
before publishing details.

## Security boundaries

MyWhispr processes microphone audio, system audio, transcripts, Accessibility
targets, and optional local-AI traffic. Reports are particularly useful for:

- unintended network transmission or bypass of loopback/LAN restrictions;
- exposure of retained audio, transcripts, or local model-server content;
- unsafe handling of untrusted audio files or model responses;
- Accessibility misuse or insertion into the wrong focused control;
- command-line argument, file-path, database, or Markdown injection;
- dependency or model-supply-chain compromise.

The project does not operate a cloud service or receive users' recordings.
