# Local delivery rule

- After every source or UI change, do not stop at `swift build`. Run the relevant
  tests, rebuild the visible application with `./scripts/build-app.sh`, relaunch
  `dist/MyWhispr.app`, and verify that the running process comes from that bundle.
- Preserve the existing signing identity so macOS permissions survive rebuilds.
- Follow the repository and host safety rules when a relaunch requires ending an
  existing app process.
