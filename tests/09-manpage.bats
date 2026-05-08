#!/usr/bin/env bats
# Test the man page: linting, content, install-target behavior.

load helpers

setup() { make_sandbox; }
teardown() { destroy_sandbox; }

REPO_ROOT="${BATS_TEST_DIRNAME}/.."

@test "man page exists" {
    [ -f "${REPO_ROOT}/man/kmod-profiler.8" ]
}

@test "man page has correct title header" {
    # The .TH line contains "KMOD" and "PROFILER" with section 8.
    # Don't try to match across the groff hyphen escape — just check both halves.
    local page="${REPO_ROOT}/man/kmod-profiler.8"
    grep -q '^\.TH KMOD' "$page"
    grep -q 'PROFILER 8' "$page"
}

@test "man page has all required sections" {
    local page="${REPO_ROOT}/man/kmod-profiler.8"
    grep -q '^\.SH NAME' "$page"
    grep -q '^\.SH SYNOPSIS' "$page"
    grep -q '^\.SH DESCRIPTION' "$page"
    grep -q '^\.SH COMMANDS' "$page"
    grep -q '^\.SH ENVIRONMENT' "$page"
    grep -q '^\.SH FILES' "$page"
    grep -q '^\.SH EXAMPLES' "$page"
    grep -q '^\.SH SEE ALSO' "$page"
    grep -q '^\.SH COPYRIGHT' "$page"
}

@test "man page documents every subcommand" {
    if ! command -v mandoc >/dev/null 2>&1; then
        skip "mandoc not installed"
    fi
    # mandoc renders bold via backspace overstrike (e.g. "s\bsa\bam\bmp\bpl\ble\be").
    # Strip backspace-overstrike pairs with sed so we get plain text.
    local rendered
    rendered=$(mandoc -T utf8 "${REPO_ROOT}/man/kmod-profiler.8" | sed 's/.\x08//g')
    for cmd in sample status generate apply kernel-changed rescan diff; do
        echo "$rendered" | grep -q -- "$cmd" || {
            echo "Subcommand '$cmd' not in rendered man page output"
            return 1
        }
    done
}

@test "man page documents every environment variable" {
    local page="${REPO_ROOT}/man/kmod-profiler.8"
    for var in KMOD_PROFILER_STATE KMOD_PROC_MODULES KMOD_LIB_MODULES \
               KMOD_LIVE_BLACKLIST KMOD_KERNEL_VERSION KMOD_GRACE_SECONDS; do
        grep -q "$var" "$page" || {
            echo "Environment variable '$var' not documented in man page"
            return 1
        }
    done
}

@test "man page lints clean with mandoc" {
    if ! command -v mandoc >/dev/null 2>&1; then
        skip "mandoc not installed"
    fi
    run mandoc -T lint -W warning "${REPO_ROOT}/man/kmod-profiler.8"
    [ "$status" -eq 0 ]
    [ -z "$output" ] || {
        echo "Lint output:"
        echo "$output"
        return 1
    }
}

@test "man page renders without errors" {
    if ! command -v mandoc >/dev/null 2>&1; then
        skip "mandoc not installed"
    fi
    run mandoc -T utf8 "${REPO_ROOT}/man/kmod-profiler.8"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "KMOD-PROFILER" ]]
    [[ "$output" =~ "kmod-profiler" ]]
}

@test "make install installs the man page" {
    cd "$REPO_ROOT"
    INSTALL_ROOT="$SANDBOX/install-root"
    make install DESTDIR="$INSTALL_ROOT" PREFIX=/usr UNITDIR=/usr/lib/systemd/system >/dev/null

    # Either compressed or uncompressed depending on whether gzip was available
    [ -f "$INSTALL_ROOT/usr/share/man/man8/kmod-profiler.8.gz" ] || \
    [ -f "$INSTALL_ROOT/usr/share/man/man8/kmod-profiler.8" ]
}

@test "make uninstall removes the man page" {
    cd "$REPO_ROOT"
    INSTALL_ROOT="$SANDBOX/install-root"
    make install   DESTDIR="$INSTALL_ROOT" PREFIX=/usr UNITDIR=/usr/lib/systemd/system >/dev/null
    make uninstall DESTDIR="$INSTALL_ROOT" PREFIX=/usr UNITDIR=/usr/lib/systemd/system >/dev/null

    [ ! -f "$INSTALL_ROOT/usr/share/man/man8/kmod-profiler.8" ]
    [ ! -f "$INSTALL_ROOT/usr/share/man/man8/kmod-profiler.8.gz" ]
}
