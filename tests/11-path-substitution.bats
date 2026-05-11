#!/usr/bin/env bats
# Tests for @SBINDIR@ token substitution at install time.
# Regression coverage for: "kmod-profiler: /usr/sbin exists in filesystem"
# (Arch usrmerge conflict) and the latent unit-file path mismatch.

load helpers

setup() {
    make_sandbox
    INSTALL_ROOT="$SANDBOX/install-root"
    REPO_ROOT="${BATS_TEST_DIRNAME}/.."
}
teardown() { destroy_sandbox; }

@test "source files use @SBINDIR@ token, not hardcoded paths" {
    # Anything that references the binary should use the placeholder.
    # If a hardcoded /usr/sbin/, /usr/bin/, or /usr/local/sbin/ slips back
    # in, this test catches it before the bug ships.
    local violations
    violations=$(grep -rn 'kmod-profiler' \
        "$REPO_ROOT/systemd/" \
        "$REPO_ROOT/kernel-hooks/" \
        "$REPO_ROOT/cron/" \
        "$REPO_ROOT/openrc/" \
        "$REPO_ROOT/alpine/kmod-profiler.trigger" \
        2>/dev/null \
        | grep -E '(/usr/local/sbin|/usr/sbin|/usr/bin)/kmod-profiler' \
        || true)
    if [ -n "$violations" ]; then
        echo "Hardcoded binary path found — should use @SBINDIR@ instead:"
        echo "$violations"
        return 1
    fi
}

@test "install with default SBINDIR substitutes correctly" {
    cd "$REPO_ROOT"
    make install DESTDIR="$INSTALL_ROOT" PREFIX=/usr UNITDIR=/usr/lib/systemd/system >/dev/null

    # No raw tokens should remain anywhere
    if grep -r '@SBINDIR@' "$INSTALL_ROOT" 2>/dev/null; then
        echo "Unsubstituted @SBINDIR@ token leaked into install"
        return 1
    fi

    # systemd unit should point to /usr/sbin/kmod-profiler
    grep -q '^ExecStart=/usr/sbin/kmod-profiler' \
        "$INSTALL_ROOT/usr/lib/systemd/system/kmod-profiler.service"
    grep -q '^ExecStart=/usr/sbin/kmod-profiler' \
        "$INSTALL_ROOT/usr/lib/systemd/system/kmod-profiler-rescan.service"
}

@test "install with SBINDIR=/usr/bin (Arch usrmerge) substitutes correctly" {
    cd "$REPO_ROOT"
    make install \
        DESTDIR="$INSTALL_ROOT" \
        PREFIX=/usr \
        SBINDIR=/usr/bin \
        UNITDIR=/usr/lib/systemd/system >/dev/null

    # Binary lands at /usr/bin, not /usr/sbin
    [ -f "$INSTALL_ROOT/usr/bin/kmod-profiler" ]
    [ ! -d "$INSTALL_ROOT/usr/sbin" ]

    # Unit file references /usr/bin
    grep -q '^ExecStart=/usr/bin/kmod-profiler' \
        "$INSTALL_ROOT/usr/lib/systemd/system/kmod-profiler.service"

    # Kernel hook references /usr/bin
    grep -q '/usr/bin/kmod-profiler kernel-changed' \
        "$INSTALL_ROOT/etc/kernel/postinst.d/60-kmod-profiler"

    # No @SBINDIR@ tokens leaked through
    ! grep -r '@SBINDIR@' "$INSTALL_ROOT" 2>/dev/null
}

@test "non-systemd install also substitutes correctly" {
    cd "$REPO_ROOT"
    make install-cron install-openrc \
        DESTDIR="$INSTALL_ROOT" \
        PREFIX=/usr \
        SBINDIR=/usr/bin >/dev/null

    grep -q '/usr/bin/kmod-profiler sample' \
        "$INSTALL_ROOT/etc/cron.d/kmod-profiler"
    grep -q '/usr/bin/kmod-profiler' \
        "$INSTALL_ROOT/etc/init.d/kmod-profiler"
    grep -q '/usr/bin/kmod-profiler' \
        "$INSTALL_ROOT/etc/conf.d/kmod-profiler"
    ! grep -r '@SBINDIR@' "$INSTALL_ROOT" 2>/dev/null
}

@test "Arch PKGBUILD uses SBINDIR=/usr/bin" {
    grep -q 'SBINDIR=/usr/bin' "$REPO_ROOT/arch/PKGBUILD" || {
        echo "Arch PKGBUILD must set SBINDIR=/usr/bin to avoid the"
        echo "/usr/sbin filesystem conflict on usrmerge systems."
        return 1
    }
}

@test "Fedora RPM spec uses _bindir" {
    grep -q 'SBINDIR=%{_bindir}' "$REPO_ROOT/rpm/kmod-profiler.spec"
    grep -q '%{_bindir}/kmod-profiler' "$REPO_ROOT/rpm/kmod-profiler.spec"
}

@test "installed unit file ExecStart is absolute (systemd requires this)" {
    cd "$REPO_ROOT"
    make install-units \
        DESTDIR="$INSTALL_ROOT" \
        PREFIX=/usr \
        UNITDIR=/usr/lib/systemd/system >/dev/null

    # ExecStart must begin with '/'
    for unit in kmod-profiler.service kmod-profiler-rescan.service; do
        local exec_line
        exec_line=$(grep '^ExecStart=' "$INSTALL_ROOT/usr/lib/systemd/system/$unit")
        case "$exec_line" in
            ExecStart=/*) : ;;
            *) echo "ExecStart not absolute in $unit: $exec_line"; return 1 ;;
        esac
    done
}
