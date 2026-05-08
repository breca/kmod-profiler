#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# kmod-profiler standalone installer.
#
# Detects the init system and installs an appropriate scheduling
# mechanism for periodic sampling and drift rescans:
#
#   * systemd  -> kmod-profiler.timer + kmod-profiler-rescan.path
#   * openrc   -> /etc/init.d/kmod-profiler service
#   * other    -> /etc/cron.d/kmod-profiler
#
# Override detection with the SCHEDULER environment variable:
#   SCHEDULER=systemd|openrc|cron sudo ./install.sh
#
# Usage:
#   sudo ./install.sh             # auto-detect, install
#   sudo ./install.sh uninstall   # remove

set -eu

PREFIX=${PREFIX:-/usr/local}
SBINDIR=${SBINDIR:-$PREFIX/sbin}
SYSCONFDIR=${SYSCONFDIR:-/etc}
UNITDIR=${UNITDIR:-/lib/systemd/system}
DOCDIR=${DOCDIR:-$PREFIX/share/doc/kmod-profiler}
MANDIR=${MANDIR:-$PREFIX/share/man}

cd "$(dirname "$0")"

require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo "Must run as root." >&2
        exit 1
    fi
}

# Detect which scheduler to use. Honor SCHEDULER env var if set; otherwise
# probe in priority order (most specific to least specific).
detect_scheduler() {
    if [ -n "${SCHEDULER:-}" ]; then
        echo "$SCHEDULER"
        return
    fi
    # Live systemd has a populated /run/systemd/system
    if [ -d /run/systemd/system ]; then
        echo systemd
        return
    fi
    # OpenRC
    if [ -x /sbin/openrc-run ] || [ -x /usr/sbin/openrc-run ]; then
        echo openrc
        return
    fi
    # Anything else falls back to cron
    echo cron
}

install_common() {
    install -d "$SBINDIR" \
               "$SYSCONFDIR/kernel/postinst.d" \
               "$SYSCONFDIR/kernel/install.d" \
               "$DOCDIR" \
               "$MANDIR/man8"

    install -m 0755 sbin/kmod-profiler                          "$SBINDIR/"
    install -m 0755 kernel-hooks/postinst.d/60-kmod-profiler    \
        "$SYSCONFDIR/kernel/postinst.d/60-kmod-profiler"
    install -m 0755 kernel-hooks/install.d/40-kmod-profiler.install \
        "$SYSCONFDIR/kernel/install.d/40-kmod-profiler.install"
    install -m 0644 docs/kmod-profiler.md "$DOCDIR/"
    install -m 0644 README.md             "$DOCDIR/"
    install -m 0644 LICENSE               "$DOCDIR/"
    install -m 0644 man/kmod-profiler.8   "$MANDIR/man8/"
    if command -v gzip >/dev/null 2>&1; then
        gzip -9 -n -f "$MANDIR/man8/kmod-profiler.8"
    fi
}

install_systemd() {
    install -d "$UNITDIR"
    install -m 0644 systemd/kmod-profiler.service        "$UNITDIR/"
    install -m 0644 systemd/kmod-profiler.timer          "$UNITDIR/"
    install -m 0644 systemd/kmod-profiler-rescan.service "$UNITDIR/"
    install -m 0644 systemd/kmod-profiler-rescan.path    "$UNITDIR/"
    systemctl daemon-reload
    systemctl enable --now kmod-profiler.timer kmod-profiler-rescan.path
    echo "Scheduler: systemd timer + path watcher"
}

install_openrc() {
    install -Dm755 openrc/kmod-profiler.initd "$SYSCONFDIR/init.d/kmod-profiler"
    install -Dm644 openrc/kmod-profiler.confd "$SYSCONFDIR/conf.d/kmod-profiler"
    if command -v rc-update >/dev/null 2>&1; then
        rc-update add kmod-profiler default 2>/dev/null || true
        rc-service kmod-profiler start 2>/dev/null || true
    fi
    echo "Scheduler: OpenRC service"
}

install_cron() {
    install -Dm644 cron/kmod-profiler.cron "$SYSCONFDIR/cron.d/kmod-profiler"
    if ! command -v crond >/dev/null 2>&1 && ! command -v cron >/dev/null 2>&1; then
        echo
        echo "WARNING: no cron daemon found in PATH."
        echo "  Install one and ensure it reads /etc/cron.d/ ."
        echo "  Common packages: cronie (Fedora/Arch), vixie-cron (Debian/Devuan),"
        echo "                   busybox-suid + dcron-openrc (Alpine)."
    fi
    echo "Scheduler: cron drop-in at $SYSCONFDIR/cron.d/kmod-profiler"
}

uninstall_systemd() {
    systemctl disable --now kmod-profiler.timer       2>/dev/null || true
    systemctl disable --now kmod-profiler-rescan.path 2>/dev/null || true
    rm -f "$UNITDIR/kmod-profiler.service"
    rm -f "$UNITDIR/kmod-profiler.timer"
    rm -f "$UNITDIR/kmod-profiler-rescan.service"
    rm -f "$UNITDIR/kmod-profiler-rescan.path"
    systemctl daemon-reload 2>/dev/null || true
}

uninstall_openrc() {
    if command -v rc-service >/dev/null 2>&1; then
        rc-service kmod-profiler stop      2>/dev/null || true
        rc-update del kmod-profiler default 2>/dev/null || true
    fi
    rm -f "$SYSCONFDIR/init.d/kmod-profiler"
    rm -f "$SYSCONFDIR/conf.d/kmod-profiler"
}

uninstall_cron() {
    rm -f "$SYSCONFDIR/cron.d/kmod-profiler"
}

uninstall_common() {
    rm -f "$SBINDIR/kmod-profiler"
    rm -f "$SYSCONFDIR/kernel/postinst.d/60-kmod-profiler"
    rm -f "$SYSCONFDIR/kernel/install.d/40-kmod-profiler.install"
    rm -f "$MANDIR/man8/kmod-profiler.8"
    rm -f "$MANDIR/man8/kmod-profiler.8.gz"
    rm -rf "$DOCDIR"
}

cmd_install() {
    require_root
    sched=$(detect_scheduler)
    echo "Installing kmod-profiler (scheduler: $sched) ..."
    install_common
    case "$sched" in
        systemd) install_systemd ;;
        openrc)  install_openrc ;;
        cron|*)  install_cron ;;
    esac
    cat <<EOF

kmod-profiler installed.

Profile for at least 1-4 weeks of normal use, then:
    sudo kmod-profiler status
    sudo kmod-profiler generate
    less /var/lib/kmod-profiler/generated-blacklist.conf  # review
    sudo kmod-profiler apply
    # Then rebuild your initramfs:
    sudo update-initramfs -u   (Debian/Ubuntu/Devuan)
    sudo dracut -f             (Fedora/RHEL/openSUSE)
    sudo mkinitcpio -P         (Arch/Artix)
    sudo mkinitfs              (Alpine)

Documentation: man kmod-profiler  or  $DOCDIR/kmod-profiler.md
EOF
}

cmd_uninstall() {
    require_root
    echo "Uninstalling kmod-profiler ..."
    # Clean up every scheduler we might have installed; harmless if absent
    uninstall_systemd
    uninstall_openrc
    uninstall_cron
    uninstall_common
    cat <<EOF

kmod-profiler removed.

NOT removed (kept by design):
    /var/lib/kmod-profiler/                    (state directory)
    /etc/modprobe.d/zz-kmod-profiler.conf      (active blacklist, if any)

Remove manually for complete cleanup, then rebuild your initramfs.
EOF
}

case "${1:-install}" in
    install)   cmd_install ;;
    uninstall) cmd_uninstall ;;
    *)
        echo "Usage: $0 [install|uninstall]" >&2
        echo "       SCHEDULER={systemd|openrc|cron} to override detection" >&2
        exit 2
        ;;
esac
