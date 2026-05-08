#!/usr/bin/env bats
# Test the `kernel-changed` and `rescan` subcommands — the resilience layer.

load helpers

setup() { make_sandbox; }
teardown() { destroy_sandbox; }

@test "kernel-changed creates a snapshot for a new kernel" {
    mock_kernel "6.12.0-test" ext4 xfs new_module

    kmod kernel-changed "6.12.0-test"

    assert_file_exists "$KMOD_PROFILER_STATE/snapshots/6.12.0-test"
    assert_file_contains "$KMOD_PROFILER_STATE/snapshots/6.12.0-test" "^new_module$"
}

@test "kernel-changed marks new modules with grace timestamps" {
    # First, observe something on an existing kernel
    mock_kernel "6.10.0-test" ext4
    mock_loaded ext4
    kmod sample

    # Now a new kernel arrives with different modules
    mock_kernel "6.12.0-test" ext4 brand_new_thing

    kmod kernel-changed "6.12.0-test"

    # brand_new_thing should be in the grace file (it's new to all-observed),
    # but ext4 should NOT (it was already observed).
    assert_file_contains "$KMOD_PROFILER_STATE/grace" "^brand_new_thing	"
    assert_file_not_contains "$KMOD_PROFILER_STATE/grace" "^ext4	"
}

@test "kernel-changed refreshes the live blacklist if it exists" {
    mock_kernel "6.10.0-test" ext4 esp4
    mock_loaded ext4
    kmod sample
    export KMOD_GRACE_SECONDS=0
    kmod generate

    # Simulate having previously applied
    cp "$KMOD_PROFILER_STATE/generated-blacklist.conf" "$KMOD_LIVE_BLACKLIST"

    # Now a kernel update brings in a new vulnerable module
    mock_kernel "6.10.0-test" ext4 esp4 esp6
    age_grace "esp6" 99999999  # pretend its grace expired
    kmod kernel-changed "6.10.0-test"

    # The live blacklist should have been refreshed
    assert_file_contains "$KMOD_LIVE_BLACKLIST" "^blacklist esp4$"
    assert_file_contains "$KMOD_LIVE_BLACKLIST" "^blacklist esp6$"
}

@test "kernel-changed handles upgrade for non-running kernel" {
    # We're running 6.10.0, but 6.12.0 just got installed
    mock_kernel "6.10.0-test" ext4
    mock_kernel "6.12.0-test" ext4 xfs
    mock_loaded ext4
    kmod sample

    kmod kernel-changed "6.12.0-test"

    # Snapshot exists for the not-yet-running kernel
    assert_file_exists "$KMOD_PROFILER_STATE/snapshots/6.12.0-test"
    # Grace entries for new modules
    assert_file_contains "$KMOD_PROFILER_STATE/grace" "^xfs	"
}

@test "kernel-changed is idempotent on the same kernel" {
    mock_kernel "6.10.0-test" ext4 xfs
    mock_loaded ext4
    kmod sample

    kmod kernel-changed "6.10.0-test"
    local first_grace; first_grace=$(cat "$KMOD_PROFILER_STATE/grace")

    sleep 1
    kmod kernel-changed "6.10.0-test"
    local second_grace; second_grace=$(cat "$KMOD_PROFILER_STATE/grace")

    # Re-running should preserve original timestamps, not bump them
    [ "$first_grace" = "$second_grace" ]
}

@test "rescan finds new kernel directories without requiring an explicit hook call" {
    # Initial state: only 6.10.0 known
    mock_kernel "6.10.0-test" ext4
    mock_loaded ext4
    kmod sample

    # Someone drops in a new kernel directory (e.g., manual install)
    mock_kernel "6.12.0-test" ext4 xfs

    kmod rescan

    assert_file_exists "$KMOD_PROFILER_STATE/snapshots/6.12.0-test"
    assert_file_contains "$KMOD_PROFILER_STATE/grace" "^xfs	"
}

@test "rescan detects drift in an existing kernel snapshot" {
    mock_kernel "6.10.0-test" ext4
    mock_loaded ext4
    kmod sample

    # Now a DKMS module gets dropped into the existing kernel's tree
    mkdir -p "$KMOD_LIB_MODULES/6.10.0-test/extra"
    : > "$KMOD_LIB_MODULES/6.10.0-test/extra/nvidia.ko.zst"

    kmod rescan

    # Snapshot should be refreshed
    assert_file_contains "$KMOD_PROFILER_STATE/snapshots/6.10.0-test" "^nvidia$"
    # Grace entry for the new module
    assert_file_contains "$KMOD_PROFILER_STATE/grace" "^nvidia	"
}

@test "rescan is a no-op when nothing has changed" {
    mock_kernel "6.10.0-test" ext4
    mock_loaded ext4
    kmod sample

    local before; before=$(stat -c %Y "$KMOD_PROFILER_STATE/snapshots/6.10.0-test")
    sleep 1
    kmod rescan
    local after; after=$(stat -c %Y "$KMOD_PROFILER_STATE/snapshots/6.10.0-test")

    # Snapshot file mtime should not have changed (no rewrite)
    [ "$before" = "$after" ]
}
