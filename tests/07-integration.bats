#!/usr/bin/env bats
# Integration tests: realistic end-to-end scenarios.

load helpers

setup() { make_sandbox; }
teardown() { destroy_sandbox; }

@test "scenario: cold start produces no immediate blacklisting" {
    # Day 1: deploy, sample, generate. Nothing should be blacklisted yet.
    mock_kernel "6.10.0-test" ext4 xfs btrfs esp4 esp6 rxrpc
    mock_loaded ext4 btrfs

    kmod sample
    kmod generate

    # Default 7-day grace means everything available should be in grace
    local out="$KMOD_PROFILER_STATE/generated-blacklist.conf"
    run grep -c "^blacklist " "$out"
    [ "$output" -eq 0 ]
}

@test "scenario: dirty-frag mitigation falls out after grace expires" {
    mock_kernel "6.10.0-test" ext4 xfs btrfs esp4 esp6 rxrpc
    mock_loaded ext4 xfs btrfs

    kmod sample

    # Backdate the grace entries for the unwanted modules
    age_grace "esp4" 999999999
    age_grace "esp6" 999999999
    age_grace "rxrpc" 999999999

    kmod generate

    local out="$KMOD_PROFILER_STATE/generated-blacklist.conf"
    assert_file_contains "$out" "^blacklist esp4$"
    assert_file_contains "$out" "^blacklist esp6$"
    assert_file_contains "$out" "^blacklist rxrpc$"
    assert_file_contains "$out" "^install esp4 /bin/false$"
    assert_file_contains "$out" "^install esp6 /bin/false$"
    assert_file_contains "$out" "^install rxrpc /bin/false$"
}

@test "scenario: kernel upgrade preserves observations and grants grace to new modules" {
    # Establish baseline
    mock_kernel "6.10.0-test" ext4 xfs esp4
    mock_loaded ext4 xfs
    kmod sample

    # Backdate esp4's grace so it would be blacklisted
    age_grace "esp4" 999999999

    # Verify baseline behavior: esp4 is blacklisted
    kmod generate
    assert_file_contains "$KMOD_PROFILER_STATE/generated-blacklist.conf" "^blacklist esp4$"

    # Now: kernel upgrade. New kernel has same modules plus a new feature.
    set_kernel "6.12.0-test"
    mock_kernel "6.12.0-test" ext4 xfs esp4 brand_new_feature

    # Hook fires
    kmod kernel-changed "6.12.0-test"

    # The fresh blacklist:
    local out="$KMOD_PROFILER_STATE/generated-blacklist.conf"
    # esp4 should still be blacklisted (its grace was already expired)
    assert_file_contains "$out" "^blacklist esp4$"
    # brand_new_feature should be in grace, NOT blacklisted
    assert_file_not_contains "$out" "^blacklist brand_new_feature$"
    # ext4 and xfs were observed under 6.10, so they're still safe
    assert_file_not_contains "$out" "^blacklist ext4$"
    assert_file_not_contains "$out" "^blacklist xfs$"
}

@test "scenario: live blacklist refreshes on kernel-changed when previously applied" {
    # Profile and apply on 6.10
    mock_kernel "6.10.0-test" ext4 esp4
    mock_loaded ext4
    kmod sample
    age_grace "esp4" 999999999
    kmod generate
    cp "$KMOD_PROFILER_STATE/generated-blacklist.conf" "$KMOD_LIVE_BLACKLIST"

    # Live blacklist contains esp4 directive
    assert_file_contains "$KMOD_LIVE_BLACKLIST" "^blacklist esp4$"

    # Kernel upgrade: 6.12 still has esp4 plus a new safe module
    mock_kernel "6.12.0-test" ext4 esp4 newmod
    set_kernel "6.12.0-test"
    kmod kernel-changed "6.12.0-test"

    # Live blacklist should now reflect 6.12's state
    assert_file_contains "$KMOD_LIVE_BLACKLIST" "^blacklist esp4$"
    # newmod is in grace, so it shouldn't appear yet
    assert_file_not_contains "$KMOD_LIVE_BLACKLIST" "^blacklist newmod$"
}

@test "scenario: DKMS module dropped post-install is observed via rescan" {
    # Steady state under 6.10
    mock_kernel "6.10.0-test" ext4
    mock_loaded ext4
    kmod sample

    # DKMS rebuild drops nvidia.ko outside any kernel-package transaction
    mkdir -p "$KMOD_LIB_MODULES/6.10.0-test/extra/nvidia"
    : > "$KMOD_LIB_MODULES/6.10.0-test/extra/nvidia/nvidia.ko.zst"

    # Path watcher fires rescan
    kmod rescan

    # nvidia is now in the snapshot and the grace file
    assert_file_contains "$KMOD_PROFILER_STATE/snapshots/6.10.0-test" "^nvidia$"
    assert_file_contains "$KMOD_PROFILER_STATE/grace" "^nvidia	"
}

@test "scenario: full generate-apply-rollback cycle" {
    mock_kernel "6.10.0-test" ext4 esp4
    mock_loaded ext4
    kmod sample
    age_grace "esp4" 999999999

    # Generate
    kmod generate

    # Apply (we can't actually exercise the EUID check; just simulate the copy)
    cp "$KMOD_PROFILER_STATE/generated-blacklist.conf" "$KMOD_LIVE_BLACKLIST"
    assert_file_contains "$KMOD_LIVE_BLACKLIST" "^blacklist esp4$"

    # Rollback: remove the live file
    rm "$KMOD_LIVE_BLACKLIST"
    [ ! -f "$KMOD_LIVE_BLACKLIST" ]

    # State directory should still be intact
    assert_file_exists "$KMOD_PROFILER_STATE/observed/6.10.0-test"
    assert_file_exists "$KMOD_PROFILER_STATE/snapshots/6.10.0-test"
}
