#!/bin/zsh
set -euo pipefail

# Builds dist/MyWhispr.app.
#
# Signing identity matters more than it looks. macOS ties Microphone, Accessibility,
# and Input Monitoring grants to the app's code signature. An ad-hoc signature *is*
# the content hash, so every rebuild produces a different identity and macOS treats
# the result as a brand new app with no permissions — the grants silently stop
# applying and the stale rows pile up in System Settings.
#
# A real certificate gives the bundle a stable designated requirement (team +
# bundle id), so permissions granted once survive every later build.
#
# Identity resolution, in order:
#   1. $CODESIGN_IDENTITY, if set
#   2. the first Developer ID Application certificate in the keychain
#   3. the first Apple Development certificate in the keychain
#   4. ad-hoc, with a loud warning

project_root="${0:A:h:h}"
configuration="${CONFIGURATION:-release}"
developer_dir="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
output_root="$project_root/dist"
app_root="$output_root/MyWhispr.app"

export DEVELOPER_DIR="$developer_dir"

resolve_identity() {
    if [[ -n "${CODESIGN_IDENTITY:-}" ]]; then
        print -r -- "$CODESIGN_IDENTITY"
        return
    fi
    # Bare `local name` declarations print `name=''` in zsh, and this function's
    # stdout *is* its return value, so every declaration must carry an initialiser
    # or the identity string ends up with shell noise prepended to it.
    local available=""
    available="$(security find-identity -v -p codesigning 2>/dev/null || true)"
    local match=""
    # Preferred names first, so a distribution certificate wins over a development
    # one when both are installed.
    for pattern in "Developer ID Application" "Apple Development" "Mac Developer"; do
        # `|| true` is load-bearing: grep exits non-zero when a pattern is absent,
        # and pipefail would abort the whole build on a perfectly normal "no such
        # certificate installed".
        match="$(print -r -- "$available" | grep -F "$pattern" | head -1 | sed -E 's/.*"(.*)".*/\1/' || true)"
        if [[ -n "$match" ]]; then
            print -r -- "$match"
            return
        fi
    done
    # Otherwise take whatever valid code-signing identity exists — typically a
    # self-signed local certificate, which serves the same purpose here: a stable
    # identity so macOS keeps this app's permissions across rebuilds.
    match="$(print -r -- "$available" | grep -E '^[[:space:]]+[0-9]+\)' | head -1 | sed -E 's/.*"(.*)".*/\1/' || true)"
    if [[ -n "$match" ]]; then
        print -r -- "$match"
        return
    fi
    print -r -- "-"
}

identity="$(resolve_identity)"

swift build -c "$configuration" --package-path "$project_root"
binary_path="$(swift build -c "$configuration" --package-path "$project_root" --show-bin-path)/MyWhispr"

rm -rf "$app_root"
mkdir -p "$app_root/Contents/MacOS" "$app_root/Contents/Resources"
cp "$binary_path" "$app_root/Contents/MacOS/MyWhispr"
cp "$project_root/Config/Info.plist" "$app_root/Contents/Info.plist"

resource_bundle="$(dirname "$binary_path")/MyWhispr_MyWhispr.bundle"
if [[ -d "$resource_bundle" ]]; then
    cp -R "$resource_bundle" "$app_root/Contents/Resources/"
fi

# The SwiftPM resource bundle carries no executable, so it is not code and cannot
# be signed on its own — the app's signature seals it as a resource. (`--deep` would
# try anyway, which is one of several reasons it is deprecated.)
sign_flags=(--force --sign "$identity" --entitlements "$project_root/Config/MyWhispr.entitlements")
if [[ "$identity" == "Developer ID Application"* ]]; then
    # Required for notarization; harmless locally.
    sign_flags+=(--options runtime --timestamp)
else
    sign_flags+=(--timestamp=none)
fi
codesign "${sign_flags[@]}" "$app_root"

if [[ "$identity" == "-" ]]; then
    print -r -- ""
    print -r -- "⚠️  Signed ad-hoc — macOS permissions will reset on every rebuild."
    print -r -- "   Create a certificate (Xcode ▸ Settings ▸ Accounts ▸ add your Apple ID,"
    print -r -- "   then Manage Certificates ▸ + ▸ Apple Development), and this script will"
    print -r -- "   pick it up automatically on the next build."
    print -r -- ""
else
    print -r -- "Signed with: $identity"
fi

codesign --verify --strict "$app_root"
print -r -- "$app_root"
