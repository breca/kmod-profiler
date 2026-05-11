#!/usr/bin/env bats
# Test the kernel package hook shims.

load helpers

setup() { make_sandbox; }
teardown() { destroy_sandbox; }

# The hooks invoke /usr/local/sbin/kmod-profiler. For tests, we use a wrapper
# that points them at our test script with our test environment.
prepare_hook_env() {
    local fakebin="$SANDBOX/fakebin"
    mkdir -p "$fakebin"
    cat > "$fakebin/kmod-profiler-shim" <<EOF
#!/bin/sh
exec env \\
    KMOD_PROFILER_STATE="$KMOD_PROFILER_STATE" \\
    KMOD_PROC_MODULES="$KMOD_PROC_MODULES" \\
    KMOD_LIB_MODULES="$KMOD_LIB_MODULES" \\
    KMOD_LIVE_BLACKLIST="$KMOD_LIVE_BLACKLIST" \\
    KMOD_KERNEL_VERSION="$KMOD_KERNEL_VERSION" \\
    "$KMOD_SCRIPT" "\$@"
EOF
    chmod +x "$fakebin/kmod-profiler-shim"

    # Patch a copy of the hook to call the shim instead of the system binary.
    # Hooks now use @SBINDIR@/kmod-profiler as a placeholder; replace it.
    HOOK_DEB="$SANDBOX/60-kmod-profiler"
    sed 's|@SBINDIR@/kmod-profiler|'"$fakebin"'/kmod-profiler-shim|' \
        "${BATS_TEST_DIRNAME}/../kernel-hooks/postinst.d/60-kmod-profiler" > "$HOOK_DEB"
    chmod +x "$HOOK_DEB"

    HOOK_SYSTEMD="$SANDBOX/40-kmod-profiler.install"
    sed 's|@SBINDIR@/kmod-profiler|'"$fakebin"'/kmod-profiler-shim|' \
        "${BATS_TEST_DIRNAME}/../kernel-hooks/install.d/40-kmod-profiler.install" > "$HOOK_SYSTEMD"
    chmod +x "$HOOK_SYSTEMD"
}

@test "Debian postinst hook with valid kernel version triggers snapshot" {
    prepare_hook_env
    mock_kernel "6.12.0-test" ext4 newmod

    "$HOOK_DEB" "6.12.0-test"

    assert_file_exists "$KMOD_PROFILER_STATE/snapshots/6.12.0-test"
}

@test "Debian postinst hook with no arguments exits cleanly" {
    prepare_hook_env

    run "$HOOK_DEB"

    [ "$status" -eq 0 ]
    [ ! -d "$KMOD_PROFILER_STATE/snapshots" ]
}

@test "Debian postinst hook does not fail if kmod-profiler is missing" {
    # Don't prepare_hook_env; use the real hook with a non-existent kmod-profiler
    local hook="${BATS_TEST_DIRNAME}/../kernel-hooks/postinst.d/60-kmod-profiler"

    # The hook checks for [ -x /usr/local/sbin/kmod-profiler ] and exits 0 if absent
    run sh "$hook" "6.12.0-test"

    [ "$status" -eq 0 ]
}

@test "systemd kernel-install hook acts only on 'add' command" {
    prepare_hook_env
    mock_kernel "6.12.0-test" ext4 newmod

    "$HOOK_SYSTEMD" add "6.12.0-test"

    assert_file_exists "$KMOD_PROFILER_STATE/snapshots/6.12.0-test"
}

@test "systemd kernel-install hook ignores 'remove' command" {
    prepare_hook_env
    mock_kernel "6.10.0-test" ext4
    mock_loaded ext4
    kmod sample
    # 6.10.0-test is now snapshotted

    "$HOOK_SYSTEMD" remove "6.10.0-test"

    # Removal should NOT delete our snapshot
    assert_file_exists "$KMOD_PROFILER_STATE/snapshots/6.10.0-test"
}

@test "systemd kernel-install hook with no version exits cleanly" {
    prepare_hook_env

    run "$HOOK_SYSTEMD" add

    [ "$status" -eq 0 ]
}
