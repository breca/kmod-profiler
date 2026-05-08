#!/usr/bin/env bats
# Test edge cases and corner conditions.

load helpers

setup() { make_sandbox; }
teardown() { destroy_sandbox; }

@test "all compressed module extensions are recognized" {
    local kver="6.10.0-test"
    mkdir -p "$KMOD_LIB_MODULES/$kver/kernel"
    : > "$KMOD_LIB_MODULES/$kver/kernel/plain.ko"
    : > "$KMOD_LIB_MODULES/$kver/kernel/compressed_xz.ko.xz"
    : > "$KMOD_LIB_MODULES/$kver/kernel/compressed_zst.ko.zst"
    : > "$KMOD_LIB_MODULES/$kver/kernel/compressed_gz.ko.gz"

    kmod sample

    local snap="$KMOD_PROFILER_STATE/snapshots/$kver"
    assert_file_contains "$snap" "^plain$"
    assert_file_contains "$snap" "^compressed_xz$"
    assert_file_contains "$snap" "^compressed_zst$"
    assert_file_contains "$snap" "^compressed_gz$"
}

@test "modules in nested kernel/ subdirectories are all found" {
    local kver="6.10.0-test"
    mkdir -p "$KMOD_LIB_MODULES/$kver/kernel/drivers/net/wireless/intel/iwlwifi"
    : > "$KMOD_LIB_MODULES/$kver/kernel/drivers/net/wireless/intel/iwlwifi/iwlwifi.ko.zst"
    mkdir -p "$KMOD_LIB_MODULES/$kver/kernel/fs/btrfs"
    : > "$KMOD_LIB_MODULES/$kver/kernel/fs/btrfs/btrfs.ko.zst"

    kmod sample

    local snap="$KMOD_PROFILER_STATE/snapshots/$kver"
    assert_file_contains "$snap" "^iwlwifi$"
    assert_file_contains "$snap" "^btrfs$"
}

@test "module name with hyphens in filename normalizes correctly" {
    local kver="6.10.0-test"
    mkdir -p "$KMOD_LIB_MODULES/$kver/kernel"
    : > "$KMOD_LIB_MODULES/$kver/kernel/nf-conntrack-ftp.ko.zst"

    kmod sample

    assert_file_contains "$KMOD_PROFILER_STATE/snapshots/$kver" "^nf_conntrack_ftp$"
}

@test "empty /proc/modules produces empty observed set" {
    mock_kernel "6.10.0-test" ext4 xfs
    : > "$KMOD_PROC_MODULES"

    kmod sample

    local obs="$KMOD_PROFILER_STATE/observed/6.10.0-test"
    assert_file_exists "$obs"
    [ ! -s "$obs" ]
}

@test "duplicate samples don't duplicate entries in observed file" {
    mock_kernel "6.10.0-test" ext4
    mock_loaded ext4

    kmod sample
    kmod sample
    kmod sample

    local obs="$KMOD_PROFILER_STATE/observed/6.10.0-test"
    [ "$(wc -l < "$obs")" -eq 1 ]
}

@test "regression: generate's EXIT trap survives function-local var scope" {
    # Past bug: replacing the double-quoted trap with single quotes caused
    # 'unbound variable' because tmp_grace/tmp_blacklist are function-local
    # and go out of scope before the EXIT trap fires. The trap must use
    # double-quotes for early expansion. Codified as a shellcheck disable
    # comment in the source; this test guards against accidental regression.
    grep -B1 'trap.*tmp_grace.*tmp_blacklist' "${BATS_TEST_DIRNAME}/../sbin/kmod-profiler" \
        | grep -q 'shellcheck disable=SC2064' || {
        echo "Trap line lost its shellcheck disable directive."
        echo "If you're tempted to single-quote the trap to satisfy SC2064:"
        echo "the variables are function-local; late expansion fails under set -u."
        return 1
    }

    # And the actual functional check: generate must complete cleanly
    mock_kernel "6.10.0-test" ext4 esp4
    mock_loaded ext4
    kmod sample
    export KMOD_GRACE_SECONDS=0
    run kmod generate
    [ "$status" -eq 0 ]
    [[ ! "$output" =~ "unbound variable" ]]
}

@test "grace timestamp is preserved across multiple kernel-changed calls" {
    mock_kernel "6.10.0-test" ext4
    mock_loaded ext4
    kmod sample

    mock_kernel "6.10.0-test" ext4 newthing
    kmod kernel-changed "6.10.0-test"
    local first_ts; first_ts=$(awk -F'\t' '$1=="newthing"{print $2}' "$KMOD_PROFILER_STATE/grace")

    sleep 2
    kmod kernel-changed "6.10.0-test"
    local second_ts; second_ts=$(awk -F'\t' '$1=="newthing"{print $2}' "$KMOD_PROFILER_STATE/grace")

    [ "$first_ts" = "$second_ts" ]
}

@test "grace doesn't re-add a module that has been observed" {
    mock_kernel "6.10.0-test" ext4 newthing
    mock_loaded ext4 newthing
    kmod sample

    # newthing is now in all-observed, so it shouldn't get a grace entry
    run grep "^newthing	" "$KMOD_PROFILER_STATE/grace"
    [ "$status" -ne 0 ]
}

@test "hyphenated module loaded as underscore matches filename with hyphen" {
    # /proc/modules always reports underscore form; filenames may have hyphens.
    # This exercises the normalization match between the two sources.
    local kver="6.10.0-test"
    mkdir -p "$KMOD_LIB_MODULES/$kver/kernel"
    : > "$KMOD_LIB_MODULES/$kver/kernel/foo-bar.ko.zst"
    mock_loaded "foo_bar"

    kmod sample
    export KMOD_GRACE_SECONDS=0
    kmod generate

    # The module should be considered observed and NOT blacklisted
    local out="$KMOD_PROFILER_STATE/generated-blacklist.conf"
    assert_file_not_contains "$out" "^blacklist foo_bar$"
}
