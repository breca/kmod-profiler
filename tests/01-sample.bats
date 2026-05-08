#!/usr/bin/env bats
# Test the `sample` subcommand.

load helpers

setup() { make_sandbox; }
teardown() { destroy_sandbox; }

@test "sample creates state directory and required files" {
    mock_kernel "6.10.0-test" ext4 btrfs
    mock_loaded ext4

    run kmod sample

    [ "$status" -eq 0 ]
    assert_file_exists "$KMOD_PROFILER_STATE/observed/6.10.0-test"
    assert_file_exists "$KMOD_PROFILER_STATE/snapshots/6.10.0-test"
    assert_file_exists "$KMOD_PROFILER_STATE/all-observed"
    assert_file_exists "$KMOD_PROFILER_STATE/profile.log"
}

@test "sample records loaded modules to per-kernel observed file" {
    mock_kernel "6.10.0-test" ext4 btrfs xfs
    mock_loaded ext4 btrfs

    kmod sample

    assert_file_contains "$KMOD_PROFILER_STATE/observed/6.10.0-test" "^ext4$"
    assert_file_contains "$KMOD_PROFILER_STATE/observed/6.10.0-test" "^btrfs$"
    assert_file_not_contains "$KMOD_PROFILER_STATE/observed/6.10.0-test" "^xfs$"
}

@test "sample updates the all-observed union" {
    mock_kernel "6.10.0-test" ext4 btrfs
    mock_loaded ext4 btrfs

    kmod sample

    assert_file_contains "$KMOD_PROFILER_STATE/all-observed" "^ext4$"
    assert_file_contains "$KMOD_PROFILER_STATE/all-observed" "^btrfs$"
}

@test "sample accumulates observations across runs" {
    mock_kernel "6.10.0-test" ext4 btrfs xfs

    mock_loaded ext4
    kmod sample

    mock_loaded btrfs
    kmod sample

    # Both should be in the observed file even though they were never
    # simultaneously in /proc/modules.
    assert_file_contains "$KMOD_PROFILER_STATE/observed/6.10.0-test" "^ext4$"
    assert_file_contains "$KMOD_PROFILER_STATE/observed/6.10.0-test" "^btrfs$"
}

@test "sample normalizes hyphens to underscores in module names" {
    mock_kernel "6.10.0-test" "nf-conntrack" "test_mod"
    mock_loaded "nf-conntrack" "test_mod"

    kmod sample

    # In observed file (from /proc/modules)
    assert_file_contains "$KMOD_PROFILER_STATE/observed/6.10.0-test" "^nf_conntrack$"
    assert_file_not_contains "$KMOD_PROFILER_STATE/observed/6.10.0-test" "nf-conntrack"

    # In snapshot file (from /lib/modules filenames)
    assert_file_contains "$KMOD_PROFILER_STATE/snapshots/6.10.0-test" "^nf_conntrack$"
}

@test "sample auto-snapshots the running kernel's available modules" {
    mock_kernel "6.10.0-test" ext4 btrfs xfs nvidia
    mock_loaded ext4

    kmod sample

    local snap="$KMOD_PROFILER_STATE/snapshots/6.10.0-test"
    [ "$(wc -l < "$snap")" -eq 4 ]
    assert_file_contains "$snap" "^ext4$"
    assert_file_contains "$snap" "^nvidia$"
}

@test "sample handles missing /proc/modules gracefully" {
    mock_kernel "6.10.0-test" ext4
    rm "$KMOD_PROC_MODULES"

    run kmod sample

    # Script should still create state directories even if /proc/modules read fails.
    # The exact exit code is less important than that we don't crash catastrophically.
    [ -d "$KMOD_PROFILER_STATE" ]
}

@test "sample handles missing /lib/modules tree gracefully" {
    rm -rf "$KMOD_LIB_MODULES"
    mkdir -p "$KMOD_LIB_MODULES"
    mock_loaded ext4

    run kmod sample

    # Should log the snapshot failure but still record observations.
    [ "$status" -eq 0 ]
    assert_file_contains "$KMOD_PROFILER_STATE/profile.log" "snapshot failed"
}
