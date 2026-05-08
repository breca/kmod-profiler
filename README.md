# kmod-profiler

Configured kernel-module allowlist via observation and data collection. Profile what your machine actually loads, reduce your attack surface by blacklisting everything else, stay coherent across kernel updates.

`kmod-profiler` watches `/proc/modules` over a profiling window, accumulates the set of modules that were *ever observed loaded*, and generates a `modprobe.d` blacklist for every available-but-never-observed module. It hooks into kernel package installation and `/lib/modules` directory changes so that kernel upgrades, DKMS rebuilds, and out-of-tree driver drops don't silently desynchronize the blacklist from reality.

See `docs/kmod-profiler.md` for the full design document, deployment guide, threat model, and operational reference.

## Quick install

### From a release tarball (any distro with systemd)

```sh
tar xzf kmod-profiler-1.0.0.tar.gz
cd kmod-profiler-1.0.0
sudo make install
sudo systemctl daemon-reload
sudo systemctl enable --now kmod-profiler.timer kmod-profiler-rescan.path
```

### From the standalone installer

```sh
sudo ./install.sh
```

### Distro packages

```sh
# Debian / Ubuntu / Devuan
sudo dpkg -i kmod-profiler_1.0.0-1_all.deb

# Fedora / RHEL / openSUSE
sudo rpm -i kmod-profiler-1.0.0-1.noarch.rpm

# Arch / Artix
makepkg -si    # from the arch/ subdirectory

# Alpine
abuild -r      # from the alpine/ subdirectory
sudo apk add ./kmod-profiler-1.0.0-r0.apk
```

### Non-systemd distros

The standalone `install.sh` auto-detects systemd, OpenRC, or falls back to cron. Override with `SCHEDULER=systemd|openrc|cron` if you need to.

```sh
sudo SCHEDULER=cron ./install.sh
```

Via Make (skip the systemd units, install cron + OpenRC alongside the rest):

```sh
sudo make install-no-systemd
```

## What you get

- `/usr/sbin/kmod-profiler` — the main script
- `kmod-profiler.timer` — samples loaded modules every minute
- `kmod-profiler-rescan.path` — watches `/lib/modules` for changes
- `/etc/kernel/postinst.d/60-kmod-profiler` — Debian/Ubuntu kernel hook
- `/etc/kernel/install.d/40-kmod-profiler.install` — systemd kernel-install hook
- `/usr/share/doc/kmod-profiler/` — full documentation

## Operating it

```sh
# After at least 1–4 weeks of normal use:
sudo kmod-profiler status            # check progress
sudo kmod-profiler generate          # produce candidate blacklist
less /var/lib/kmod-profiler/generated-blacklist.conf   # review!
sudo kmod-profiler apply             # install it
sudo update-initramfs -u             # (or dracut -f, or mkinitcpio -P)
sudo reboot
```

## Building packages

```sh
make tarball       # source tarball
make deb           # .deb (needs debhelper)
make rpm           # .rpm (needs rpmbuild)
# Arch: cd arch && makepkg
```

## License

GPL-3.0-or-later. See LICENSE.

## AI Disclosure

This project was developed with the assistance of AI tools (e.g. GitHub Copilot, ChatGPT) for code generation, documentation, and review. All output was reviewed and verified by the author.
