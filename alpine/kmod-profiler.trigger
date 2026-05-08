#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Alpine APK trigger: fires when any package adds/modifies/removes files
# under /lib/modules. This is Alpine's native equivalent of systemd's
# path watcher and the Debian /etc/kernel/postinst.d/ hook combined —
# it captures kernel installs, kernel updates, and DKMS rebuilds in one
# mechanism.
#
# APK passes the changed paths as arguments. We don't need them; rescan
# discovers and processes everything on its own.
set -e

if [ -x /usr/sbin/kmod-profiler ]; then
    /usr/sbin/kmod-profiler rescan 2>/dev/null || true
fi

exit 0
