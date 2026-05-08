#!/usr/bin/env bats
# Test the `generate` subcommand.

load helpers

setup() { make_sandbox; }
teardown() { destroy_sandbox; }

@test "generate emits both blacklist and install directives per module" {
    mock_kernel "6.10.0-test" ext4 esp4
    mock_loaded ext4
    kmod sample

    # Force grace expiry for all modules so esp4 is actually blacklisted
    export KMOD_GRACE_SECONDS=0
    kmod generate

    local out="$KMOD_PROFILER_STATE/generated-blacklist.conf"
    assert_file_contains "$out" "^blacklist esp4$"
    assert_file_contains "$out" "^install esp4 /bin/false$"
}

@test "generate does not blacklist observed modules" {
    mock_kernel "6.10.0-test" ext4 esp4
    mock_loaded ext4
    kmod sample
    export KMOD_GRACE_SECONDS=0

    kmod generate

    local out="$KMOD_PROFILER_STATE/generated-blacklist.conf"
    assert_file_not_contains "$out" "^blacklist ext4$"
}

@test "generate respects all-observed across kernels" {
    mock_kernel "6.10.0-test" ext4 xfs
    mock_loaded ext4 xfs
    kmod sample

    # Switch to a different kernel where we never observed xfs loaded
    set_kernel "6.12.0-test"
    mock_kernel "6.12.0-test" ext4 xfs
    mock_loaded ext4
    kmod sample

    export KMOD_GRACE_SECONDS=0
    kmod generate

    # xfs was observed under 6.10.0, so it shouldn't be blacklisted on 6.12.0
    local out="$KMOD_PROFILER_STATE/generated-blacklist.conf"
    assert_file_not_contains "$out" "^blacklist xfs$"
}

@test "generate respects grace window for newly-appeared modules" {
    mock_kernel "6.10.0-test" ext4
    mock_loaded ext4
    kmod sample

    # Now a kernel update brings in a new module
    mock_kernel "6.10.0-test" ext4 brand_new_thing
    kmod kernel-changed "6.10.0-test"

    # Grace is still active for brand_new_thing
    local out="$KMOD_PROFILER_STATE/generated-blacklist.conf"
    assert_file_not_contains "$out" "^blacklist brand_new_thing$"
}

@test "generate blacklists modules whose grace has expired" {
    mock_kernel "6.10.0-test" ext4 esp4
    mock_loaded ext4
    kmod sample

    # Backdate esp4's grace entry to 30 days ago
    age_grace "esp4" 2592000

    # Use a 7-day window so esp4 is past grace
    export KMOD_GRACE_SECONDS=604800
    kmod generate

    local out="$KMOD_PROFILER_STATE/generated-blacklist.conf"
    assert_file_contains "$out" "^blacklist esp4$"
}

@test "generate auto-snapshots if no snapshot exists for target kernel" {
    mock_kernel "6.12.0-test" ext4 xfs
    # Don't sample first; just generate

    export KMOD_GRACE_SECONDS=0
    run kmod generate "6.12.0-test"

    [ "$status" -eq 0 ]
    assert_file_exists "$KMOD_PROFILER_STATE/snapshots/6.12.0-test"
}

@test "generate fails cleanly if kernel doesn't exist anywhere" {
    run kmod generate "9.9.9-nonexistent"

    [ "$status" -ne 0 ]
    [[ "$output" =~ "and no snapshot" ]]
}

@test "generate produces empty blacklist on cold start (everything in grace)" {
    mock_kernel "6.10.0-test" ext4 xfs btrfs
    mock_loaded ext4
    kmod sample

    # Default grace is 7 days; nothing has aged out
    kmod generate

    local out="$KMOD_PROFILER_STATE/generated-blacklist.conf"
    # Header should be present, but no blacklist directives
    assert_file_exists "$out"
    run grep -c "^blacklist " "$out"
    [ "$output" -eq 0 ]
}

@test "generate header reports correct counts" {
    mock_kernel "6.10.0-test" ext4 esp4 esp6 xfs
    mock_loaded ext4
    kmod sample
    export KMOD_GRACE_SECONDS=0

    kmod generate

    local out="$KMOD_PROFILER_STATE/generated-blacklist.conf"
    assert_file_contains "$out" "Available modules:  4"
    assert_file_contains "$out" "Ever observed:      1"
    assert_file_contains "$out" "Blacklisted below:  3"
}
