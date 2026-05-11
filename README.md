# kmod-profiler

Configured kernel-module allowlist via observation and data collection. Profile what your machine actually loads, reduce your attack surface by blacklisting everything else, stay coherent across kernel updates.

`kmod-profiler` watches `/proc/modules` over a profiling window, accumulates the set of modules that were *ever observed loaded*, and generates a `modprobe.d` blacklist for every available-but-never-observed module. It hooks into kernel package installation and `/lib/modules` directory changes so that kernel upgrades, DKMS rebuilds, and out-of-tree driver drops don't silently desynchronize the blacklist from reality.

See `docs/kmod-profiler.md` for the full design document, deployment guide, threat model, and operational reference.

## Quick install

### From a release tarball (any distro with systemd)

```sh
tar xzf kmod-profiler-1.0.0.tar.gz
cd kmod-profiler-1.0.0
sudo make install PREFIX=/usr
sudo systemctl daemon-reload
sudo systemctl enable --now kmod-profiler.timer kmod-profiler-rescan.path
```

### From the standalone installer

```sh
sudo ./install.sh
```

The installer auto-detects systemd, OpenRC, or falls back to cron. Override with `SCHEDULER=systemd|openrc|cron`. To uninstall: `sudo ./install.sh uninstall`.

### Distro packages

```sh
# Debian / Ubuntu / Devuan
sudo apt install ./kmod-profiler_1.0.0-1_all.deb

# Fedora / RHEL / openSUSE
sudo dnf install ./kmod-profiler-1.0.0-1.noarch.rpm

# Arch / Artix
cd arch && makepkg -si

# Alpine
abuild -r    # from the alpine/ subdirectory
sudo apk add ./kmod-profiler-1.0.0-r0.apk
```

### Non-systemd distros

Via Make (installs cron + OpenRC + Alpine trigger alongside everything except systemd units):

```sh
sudo make install-no-systemd PREFIX=/usr
```

Or override the scheduler with the standalone installer:

```sh
sudo SCHEDULER=cron ./install.sh
```

## What you get (with `PREFIX=/usr`)

| Path | Description |
|---|---|
| `/usr/sbin/kmod-profiler` | Main script |
| `/lib/systemd/system/kmod-profiler.timer` | Samples loaded modules every minute |
| `/lib/systemd/system/kmod-profiler-rescan.path` | Watches `/lib/modules` for changes |
| `/etc/kernel/postinst.d/60-kmod-profiler` | Debian/Ubuntu kernel package hook |
| `/etc/kernel/install.d/40-kmod-profiler.install` | systemd kernel-install hook |
| `/etc/cron.d/kmod-profiler` | Cron fallback (non-systemd) |
| `/etc/init.d/kmod-profiler` | OpenRC service (non-systemd) |
| `/etc/apk/triggers/kmod-profiler.trigger` | Alpine drift detection |
| `/usr/share/man/man8/kmod-profiler.8` | Man page |
| `/usr/share/doc/kmod-profiler/` | Documentation |

## State directory

```
/var/lib/kmod-profiler/
  observed/<kver>/          Per-kernel observed module set (sorted, normalized)
  snapshots/<kver>/         Per-kernel available module set (sorted, normalized)
  all-observed              Union across every kernel ever profiled
  grace                     "module<TAB>first-seen-epoch" lines
  generated-blacklist.conf  Current generator output
  profile.log               Human-readable log
```

Override with `KMOD_PROFILER_STATE=/custom/path`.

## Subcommands

```sh
kmod-profiler sample            Record currently loaded modules for the running kernel
kmod-profiler status            Show profiling progress
kmod-profiler generate [kver]   Produce blacklist for a kernel (default: running)
kmod-profiler apply [file]      Install the generated blacklist
kmod-profiler rescan            Discover and process every kernel in /lib/modules
kmod-profiler diff <v1> <v2>    Show module-set differences between two snapshots
kmod-profiler kernel-changed    Package-hook entry; snapshots, marks grace, regenerates
kmod-profiler --version         Print version
```

## Operating it

```sh
# After at least 1–4 weeks of normal use:
sudo kmod-profiler status            # check progress
sudo kmod-profiler generate          # produce candidate blacklist
less /var/lib/kmod-profiler/generated-blacklist.conf   # review this!
sudo kmod-profiler apply             # install it
sudo update-initramfs -u             # (or dracut -f, or mkinitcpio -P...)
sudo reboot
```

### Example: `status` output

```text
Running kernel: 6.18.28-2-lts

Available (this kernel):  6417
Observed (this kernel):   156
Observed (all kernels):   156
In grace window:          6261  (window: 7 days)

Kernel snapshots on file:
  6.18.28-2-lts          6417 modules

Recent log entries:
  2026-05-11T22:15:30+10:00 snapshot 6.18.28-2-lts: 6417 modules
  2026-05-11T22:15:36+10:00 sample 6.18.28-2-lts: kernel-obs=156 total-obs=156
  2026-05-11T22:16:38+10:00 sample 6.18.28-2-lts: kernel-obs=156 total-obs=156
```

### Example: `--help` output

```text
kmod-profiler — kernel module allowlist via observation, resilient to kernel updates.

Usage:
  /usr/bin/kmod-profiler sample                    Record currently loaded modules
  /usr/bin/kmod-profiler status                    Show profiling progress
  /usr/bin/kmod-profiler generate [kver]           Generate blacklist for kernel (default: running)
  /usr/bin/kmod-profiler apply [file]              Install the generated blacklist
  /usr/bin/kmod-profiler kernel-changed <kver>     Hook entry: snapshot+grace+regen for a kernel
  /usr/bin/kmod-profiler rescan                    Find new/changed kernel dirs in /lib/modules
  /usr/bin/kmod-profiler diff <kver1> <kver2>      Show module differences between two snapshots
```

## Grace system and kernel updates

When a kernel update introduces new modules, kmod-profiler doesn't immediately blacklist them - that would break hardware that only appears after the update. Instead it uses a **grace period**:

1. **On kernel install** (via `/etc/kernel/postinst.d` hook): kmod-profiler snapshots the new kernel's module set and marks modules that aren't in `all-observed` as "graced" with the current timestamp.

2. **During sampling**: loaded modules are added to `all-observed`. Modules in the grace file that have been loaded get their grace timestamp removed (they're no longer "new").

3. **During blacklist generation**: modules still in the grace window (default 7 days) are excluded from the blacklist. This gives the system time to actually load and observe the new modules through normal use.

4. **After the grace window expires**: unobserved modules are blacklisted on the next `generate` run.

This means:
- New kernels get a 7-day grace period where their unique modules are safe
- If a module is loaded during that window, it gets added to `all-observed` and stays allowed forever
- Modules that genuinely aren't needed get blacklisted after grace expires
- The `rescan` path unit catches DKMS rebuilds and out-of-tree driver drops by detecting drift in existing kernel module sets

Override the grace period with `GRACE_SECONDS=<seconds>` (default: 604800 = 7 days).

## Makefile targets

| Target | Description |
|---|---|
| `install` | Install everything (bin, units, hooks, docs, man) |
| `install-bin` | Install just the script |
| `install-units` | Install just the systemd units |
| `install-hooks` | Install just the kernel hooks |
| `install-docs` | Install documentation |
| `install-man` | Install man page |
| `install-cron` | Install cron drop-in |
| `install-openrc` | Install OpenRC service files |
| `install-runit` | Install runit service |
| `install-alpine` | Install Alpine trigger |
| `install-no-systemd` | Install everything except systemd units |
| `uninstall` | Remove everything |
| `check` | Syntax-check shell scripts and lint man page |
| `test` | Run the bats test suite |
| `tarball` | Produce a release tarball |
| `deb` | Build a .deb (requires debhelper) |
| `rpm` | Build an .rpm (requires rpmbuild) |
| `arch` | Build an Arch PKGBUILD package (run as non-root) |
| `packages` | Build deb + rpm + arch |
| `clean` | Remove build artifacts |

## Makefile variables

| Variable | Default | Description |
|---|---|---|
| `PREFIX` | `/usr/local` | Installation prefix |
| `SBINDIR` | `$(PREFIX)/sbin` | Binary directory |
| `SYSCONFDIR` | `/etc` | Config directory |
| `UNITDIR` | `/lib/systemd/system` | Systemd unit directory |
| `DOCDIR` | `$(PREFIX)/share/doc/kmod-profiler` | Documentation directory |
| `MANDIR` | `$(PREFIX)/share/man` | Man page directory |
| `DESTDIR` | (empty) | Staging root for packagers |

## Building packages

```sh
make tarball       # source tarball
make deb           # .deb (needs debhelper)
make rpm           # .rpm (needs rpmbuild)
make arch          # .pkg.tar.zst (run as non-root user)
make packages      # build all three formats
```

## Uninstall

```sh
# From Make
sudo make uninstall PREFIX=/usr

# From standalone installer
sudo ./install.sh uninstall
```

Note: the state directory `/var/lib/kmod-profiler` and the live blacklist `/etc/modprobe.d/zz-kmod-profiler.conf` are NOT removed by uninstall. Remove them manually if desired.

## License

GPL-3.0-or-later. See LICENSE.

## AI Disclosure

This project was developed with the assistance of AI tools (e.g. GitHub Copilot, ChatGPT) for code generation, documentation, and review. All output was reviewed and verified by the author.
