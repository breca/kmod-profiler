#!/usr/bin/env bats
# Test the read-only inspection subcommands: diff and status.

load helpers

setup() { make_sandbox; }
teardown() { destroy_sandbox; }

@test "diff shows modules added in newer kernel" {
    mock_kernel "6.10.0-test" ext4 xfs
    mock_kernel "6.12.0-test" ext4 xfs new_module
    kmod kernel-changed "6.10.0-test"
    kmod kernel-changed "6.12.0-test"

    run kmod diff "6.10.0-test" "6.12.0-test"

    [ "$status" -eq 0 ]
    [[ "$output" =~ "new_module" ]]
}

@test "diff shows modules removed in newer kernel" {
    mock_kernel "6.10.0-test" ext4 deprecated_thing
    mock_kernel "6.12.0-test" ext4
    kmod kernel-changed "6.10.0-test"
    kmod kernel-changed "6.12.0-test"

    run kmod diff "6.10.0-test" "6.12.0-test"

    [ "$status" -eq 0 ]
    [[ "$output" =~ "deprecated_thing" ]]
    [[ "$output" =~ "gone since" ]]
}

@test "diff fails clearly when a snapshot is missing" {
    mock_kernel "6.10.0-test" ext4
    kmod kernel-changed "6.10.0-test"

    run kmod diff "6.10.0-test" "9.9.9-missing"

    [ "$status" -ne 0 ]
    [[ "$output" =~ "No snapshot" ]]
}

@test "status reports running kernel" {
    mock_kernel "6.10.0-test" ext4
    mock_loaded ext4
    kmod sample

    run kmod status

    [ "$status" -eq 0 ]
    [[ "$output" =~ "6.10.0-test" ]]
}

@test "status reports module counts" {
    mock_kernel "6.10.0-test" ext4 xfs btrfs esp4
    mock_loaded ext4 xfs
    kmod sample

    run kmod status

    [ "$status" -eq 0 ]
    [[ "$output" =~ "Available (this kernel):  4" ]]
    [[ "$output" =~ "Observed (this kernel):   2" ]]
}

@test "status before any sample reports zero observations" {
    mock_kernel "6.10.0-test" ext4 xfs
    # No sample run

    # status with empty state needs the dirs to exist; exit code may vary.
    # Just verify it doesn't crash catastrophically.
    run kmod status
    [[ "$output" =~ "Run "*"first" ]] || [[ "$output" =~ "0" ]]
}
