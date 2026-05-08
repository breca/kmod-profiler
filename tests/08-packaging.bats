#!/usr/bin/env bats
# Test the Makefile-driven install and uninstall paths.

load helpers

setup() {
    make_sandbox
    INSTALL_ROOT="$SANDBOX/install-root"
    PREFIX="/usr"
    UNITDIR="/usr/lib/systemd/system"
    REPO_ROOT="${BATS_TEST_DIRNAME}/.."
}
teardown() { destroy_sandbox; }

@test "make check passes" {
    cd "$REPO_ROOT"
    run make check
    [ "$status" -eq 0 ]
}

@test "make install creates expected layout" {
    cd "$REPO_ROOT"
    run make install DESTDIR="$INSTALL_ROOT" PREFIX="$PREFIX" UNITDIR="$UNITDIR"
    [ "$status" -eq 0 ]

    # Binary
    assert_file_exists "$INSTALL_ROOT/usr/sbin/kmod-profiler"
    [ -x "$INSTALL_ROOT/usr/sbin/kmod-profiler" ]

    # Systemd units
    assert_file_exists "$INSTALL_ROOT/usr/lib/systemd/system/kmod-profiler.timer"
    assert_file_exists "$INSTALL_ROOT/usr/lib/systemd/system/kmod-profiler.service"
    assert_file_exists "$INSTALL_ROOT/usr/lib/systemd/system/kmod-profiler-rescan.path"
    assert_file_exists "$INSTALL_ROOT/usr/lib/systemd/system/kmod-profiler-rescan.service"

    # Kernel hooks
    assert_file_exists "$INSTALL_ROOT/etc/kernel/postinst.d/60-kmod-profiler"
    [ -x "$INSTALL_ROOT/etc/kernel/postinst.d/60-kmod-profiler" ]
    assert_file_exists "$INSTALL_ROOT/etc/kernel/install.d/40-kmod-profiler.install"
    [ -x "$INSTALL_ROOT/etc/kernel/install.d/40-kmod-profiler.install" ]

    # Documentation
    assert_file_exists "$INSTALL_ROOT/usr/share/doc/kmod-profiler/kmod-profiler.md"
    assert_file_exists "$INSTALL_ROOT/usr/share/doc/kmod-profiler/README.md"
    assert_file_exists "$INSTALL_ROOT/usr/share/doc/kmod-profiler/LICENSE"
}

@test "make uninstall removes installed files" {
    cd "$REPO_ROOT"
    make install DESTDIR="$INSTALL_ROOT" PREFIX="$PREFIX" UNITDIR="$UNITDIR" >/dev/null

    run make uninstall DESTDIR="$INSTALL_ROOT" PREFIX="$PREFIX" UNITDIR="$UNITDIR"
    [ "$status" -eq 0 ]

    [ ! -f "$INSTALL_ROOT/usr/sbin/kmod-profiler" ]
    [ ! -f "$INSTALL_ROOT/usr/lib/systemd/system/kmod-profiler.timer" ]
    [ ! -f "$INSTALL_ROOT/etc/kernel/postinst.d/60-kmod-profiler" ]
    [ ! -d "$INSTALL_ROOT/usr/share/doc/kmod-profiler" ]
}

@test "installed script is functional (not corrupted by install)" {
    cd "$REPO_ROOT"
    make install DESTDIR="$INSTALL_ROOT" PREFIX="$PREFIX" UNITDIR="$UNITDIR" >/dev/null

    run "$INSTALL_ROOT/usr/sbin/kmod-profiler"
    # No subcommand → usage message → exit 1, but should produce help text
    [ "$status" -eq 1 ]
    [[ "$output" =~ "kmod-profiler" ]]
    [[ "$output" =~ "Usage:" ]]
}
