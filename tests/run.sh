#!/usr/bin/env bash
# tests/run.sh — run the kmod-profiler test suite.
#
# Requires bats-core. Install on Debian/Ubuntu: apt install bats
# Fedora/RHEL: dnf install bats
# Arch:        pacman -S bats
# macOS:       brew install bats-core

set -eu

if ! command -v bats >/dev/null 2>&1; then
    echo "Error: bats-core is not installed." >&2
    echo "  Debian/Ubuntu: sudo apt-get install bats" >&2
    echo "  Fedora/RHEL:   sudo dnf install bats" >&2
    echo "  Arch:          sudo pacman -S bats" >&2
    echo "  macOS:         brew install bats-core" >&2
    exit 1
fi

cd "$(dirname "$0")"

# Default to all tests. Pass specific files as arguments to run a subset.
if [ $# -eq 0 ]; then
    set -- *.bats
fi

exec bats "$@"
