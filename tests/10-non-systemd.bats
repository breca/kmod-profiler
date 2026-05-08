#!/usr/bin/env bats
# Test non-systemd scheduler installs (cron, OpenRC, runit).

load helpers

setup() {
    make_sandbox
    INSTALL_ROOT="$SANDBOX/install-root"
    REPO_ROOT="${BATS_TEST_DIRNAME}/.."
}
teardown() { destroy_sandbox; }

@test "cron drop-in file is well-formed" {
    local f="${REPO_ROOT}/cron/kmod-profiler.cron"
    [ -f "$f" ]
    # Each non-comment line should have 6 fields: 5 cron + user + cmd...
    # Use awk to validate format
    grep -v -E '^\s*#|^\s*$|^[A-Z]+=' "$f" | while read -r line; do
        local fields; fields=$(echo "$line" | awk '{print NF}')
        if [ "$fields" -lt 7 ]; then
            echo "Malformed cron line: $line"
            return 1
        fi
    done
    # Must have at least one entry that calls kmod-profiler
    grep -q 'kmod-profiler' "$f"
}

@test "make install-cron places file at /etc/cron.d/kmod-profiler" {
    cd "$REPO_ROOT"
    run make install-cron DESTDIR="$INSTALL_ROOT"
    [ "$status" -eq 0 ]
    [ -f "$INSTALL_ROOT/etc/cron.d/kmod-profiler" ]
}

@test "OpenRC initd is a valid shell script" {
    local f="${REPO_ROOT}/openrc/kmod-profiler.initd"
    [ -f "$f" ]
    [ -x "$f" ]
    head -1 "$f" | grep -q '^#!/sbin/openrc-run'
    sh -n "$f"
}

@test "OpenRC confd is well-formed shell" {
    local f="${REPO_ROOT}/openrc/kmod-profiler.confd"
    [ -f "$f" ]
    sh -n "$f"
}

@test "make install-openrc places initd and confd correctly" {
    cd "$REPO_ROOT"
    run make install-openrc DESTDIR="$INSTALL_ROOT"
    [ "$status" -eq 0 ]
    [ -f "$INSTALL_ROOT/etc/init.d/kmod-profiler" ]
    [ -x "$INSTALL_ROOT/etc/init.d/kmod-profiler" ]
    [ -f "$INSTALL_ROOT/etc/conf.d/kmod-profiler" ]
}

@test "runit run script is valid shell" {
    local f="${REPO_ROOT}/runit/run"
    [ -f "$f" ]
    [ -x "$f" ]
    head -1 "$f" | grep -q '^#!/bin/sh'
    sh -n "$f"
}

@test "make install-runit places run script under /etc/sv/" {
    cd "$REPO_ROOT"
    run make install-runit DESTDIR="$INSTALL_ROOT"
    [ "$status" -eq 0 ]
    [ -f "$INSTALL_ROOT/etc/sv/kmod-profiler/run" ]
    [ -x "$INSTALL_ROOT/etc/sv/kmod-profiler/run" ]
}

@test "make install-no-systemd installs cron and OpenRC but NOT systemd units" {
    cd "$REPO_ROOT"
    run make install-no-systemd DESTDIR="$INSTALL_ROOT" PREFIX=/usr UNITDIR=/usr/lib/systemd/system
    [ "$status" -eq 0 ]

    # Has the binary, hooks, docs, man, cron, openrc
    [ -f "$INSTALL_ROOT/usr/sbin/kmod-profiler" ]
    [ -f "$INSTALL_ROOT/etc/cron.d/kmod-profiler" ]
    [ -f "$INSTALL_ROOT/etc/init.d/kmod-profiler" ]

    # Does NOT have systemd units
    [ ! -f "$INSTALL_ROOT/usr/lib/systemd/system/kmod-profiler.timer" ]
    [ ! -f "$INSTALL_ROOT/usr/lib/systemd/system/kmod-profiler-rescan.path" ]
}

@test "make uninstall removes cron, OpenRC, and runit artifacts" {
    cd "$REPO_ROOT"
    make install            DESTDIR="$INSTALL_ROOT" PREFIX=/usr UNITDIR=/usr/lib/systemd/system >/dev/null
    make install-cron       DESTDIR="$INSTALL_ROOT" >/dev/null
    make install-openrc     DESTDIR="$INSTALL_ROOT" >/dev/null
    make install-runit      DESTDIR="$INSTALL_ROOT" >/dev/null
    make uninstall          DESTDIR="$INSTALL_ROOT" PREFIX=/usr UNITDIR=/usr/lib/systemd/system >/dev/null

    [ ! -f "$INSTALL_ROOT/etc/cron.d/kmod-profiler" ]
    [ ! -f "$INSTALL_ROOT/etc/init.d/kmod-profiler" ]
    [ ! -f "$INSTALL_ROOT/etc/conf.d/kmod-profiler" ]
    [ ! -f "$INSTALL_ROOT/etc/sv/kmod-profiler/run" ]
    [ ! -d "$INSTALL_ROOT/etc/sv/kmod-profiler" ]
}

@test "alpine APKBUILD references all required artifacts" {
    local f="${REPO_ROOT}/alpine/APKBUILD"
    [ -f "$f" ]
    grep -q 'pkgname=kmod-profiler' "$f"
    grep -q 'license="GPL-3.0-or-later"' "$f"
    grep -q 'triggers=' "$f"
    # APKBUILD uses $pkgname variable, so check for that path form
    grep -q 'cron/\$pkgname.cron' "$f"
    grep -q 'openrc/\$pkgname.initd' "$f"
}

@test "alpine trigger script invokes rescan" {
    local f="${REPO_ROOT}/alpine/kmod-profiler.trigger"
    [ -f "$f" ]
    sh -n "$f"
    grep -q 'kmod-profiler rescan' "$f"
}

@test "install.sh detects scheduler from SCHEDULER env var" {
    # The install.sh has a detect_scheduler function. Source it and call it.
    # We have to extract the detect_scheduler function for testing in isolation.
    local detect_fn
    detect_fn=$(awk '/^detect_scheduler\(\)/,/^}/' "${REPO_ROOT}/install.sh")
    # Run with explicit override
    SCHEDULER=cron eval "$detect_fn"$'\n''result=$(detect_scheduler)'
    [ "$result" = "cron" ]

    SCHEDULER=systemd eval "$detect_fn"$'\n''result=$(detect_scheduler)'
    [ "$result" = "systemd" ]

    SCHEDULER=openrc eval "$detect_fn"$'\n''result=$(detect_scheduler)'
    [ "$result" = "openrc" ]
}
