# tests/helpers.bash
# Shared test infrastructure for kmod-profiler.

# Path to the script under test (resolved relative to the repo root).
KMOD_SCRIPT="${BATS_TEST_DIRNAME}/../sbin/kmod-profiler"

# Per-test sandbox directory; recreated fresh for each test by setup().
make_sandbox() {
    SANDBOX="$(mktemp -d "${BATS_TMPDIR}/kmod-test.XXXXXX")"
    export SANDBOX

    # Override every external path the script touches.
    export KMOD_PROFILER_STATE="$SANDBOX/state"
    export KMOD_PROC_MODULES="$SANDBOX/proc-modules"
    export KMOD_LIB_MODULES="$SANDBOX/lib-modules"
    export KMOD_LIVE_BLACKLIST="$SANDBOX/etc-modprobe.d/zz-kmod-profiler.conf"
    export KMOD_KERNEL_VERSION="6.10.0-test"
    export KMOD_GRACE_SECONDS="${KMOD_GRACE_SECONDS:-604800}"

    mkdir -p "$KMOD_LIB_MODULES" "$(dirname "$KMOD_LIVE_BLACKLIST")"
    : > "$KMOD_PROC_MODULES"
}

destroy_sandbox() {
    if [ -n "${SANDBOX:-}" ] && [ -d "$SANDBOX" ]; then
        rm -rf "$SANDBOX"
    fi
}

# Run the script under test. Captures stdout/stderr in $output and exit code in $status,
# the standard bats pattern via `run`.
kmod() {
    "$KMOD_SCRIPT" "$@"
}

# Create a fake kernel directory with the named modules. Module names may
# include hyphens; they will be written as the actual filename. Files are
# created with the .ko.zst suffix to exercise extension-stripping.
mock_kernel() {
    local kver="$1"; shift
    local subdir="$KMOD_LIB_MODULES/$kver/kernel/test"
    mkdir -p "$subdir"
    for mod in "$@"; do
        : > "$subdir/${mod}.ko.zst"
    done
}

# Replace fake /proc/modules with a list of currently-loaded modules.
mock_loaded() {
    : > "$KMOD_PROC_MODULES"
    for mod in "$@"; do
        # Format mirrors the real /proc/modules: name size refcnt dependents state addr
        printf '%s 1024 0 - Live 0x0\n' "$mod" >> "$KMOD_PROC_MODULES"
    done
}

# Pretend we're running a different kernel version.
set_kernel() {
    export KMOD_KERNEL_VERSION="$1"
}

# Backdate a module's grace timestamp by N seconds (i.e., "this module has
# been in grace for N seconds already"). Useful for testing grace expiry
# without sleeping.
age_grace() {
    local mod="$1" age_seconds="$2"
    local grace_file="$KMOD_PROFILER_STATE/grace"
    [ -f "$grace_file" ] || return 0
    local now; now=$(date +%s)
    local target=$((now - age_seconds))
    awk -F'\t' -v m="$mod" -v t="$target" \
        'BEGIN{OFS="\t"} $1==m {$2=t} {print}' \
        "$grace_file" > "$grace_file.tmp"
    mv "$grace_file.tmp" "$grace_file"
}

# Convenience assertions
assert_file_exists() {
    [ -f "$1" ] || {
        echo "Expected file to exist: $1"
        return 1
    }
}

assert_file_contains() {
    local file="$1" pattern="$2"
    grep -q -- "$pattern" "$file" || {
        echo "Expected $file to contain: $pattern"
        echo "--- File contents: ---"
        cat "$file"
        echo "----------------------"
        return 1
    }
}

assert_file_not_contains() {
    local file="$1" pattern="$2"
    if grep -q -- "$pattern" "$file"; then
        echo "Expected $file NOT to contain: $pattern"
        echo "--- File contents: ---"
        cat "$file"
        echo "----------------------"
        return 1
    fi
}
