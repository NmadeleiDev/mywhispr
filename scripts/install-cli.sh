#!/bin/zsh
set -euo pipefail

# Builds and atomically installs the standalone `mywhispr` command.
#
# The default is deliberately user-owned: it needs no sudo and does not mutate a
# Homebrew-managed directory. Override only for packaging or an isolated test:
#
#   MYWHISPR_INSTALL_DIR=/some/bin ./scripts/install-cli.sh

project_root="${0:A:h:h}"
developer_dir="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
install_dir="${MYWHISPR_INSTALL_DIR:-$HOME/.local/bin}"
destination="$install_dir/mywhispr"

case "$install_dir" in
    ""|/|"$HOME")
        print -u2 -r -- "Refusing unsafe install directory: $install_dir"
        exit 2
        ;;
esac

export DEVELOPER_DIR="$developer_dir"

swift build -c release --package-path "$project_root"
binary_directory="$(swift build -c release --package-path "$project_root" --show-bin-path)"
binary_path="$binary_directory/MyWhispr"

if [[ ! -x "$binary_path" ]]; then
    print -u2 -r -- "Release binary was not produced: $binary_path"
    exit 1
fi

mkdir -p "$install_dir"
temporary="$install_dir/.mywhispr.$$.tmp"
trap 'rm -f -- "$temporary"' EXIT INT TERM
install -m 0755 "$binary_path" "$temporary"
mv -f "$temporary" "$destination"
trap - EXIT INT TERM

print -r -- "$destination"

case ":$PATH:" in
    *":$install_dir:"*) ;;
    *) print -u2 -r -- "Warning: add $install_dir to PATH before invoking mywhispr." ;;
esac
