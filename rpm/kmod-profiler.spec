Name:           kmod-profiler
Version:        1.0.0
Release:        1%{?dist}
Summary:        Kernel module allowlist via runtime observation
License:        GPL-3.0-or-later
URL:            https://github.com/breca/kmod-profiler
Source0:        %{name}-%{version}.tar.gz
BuildArch:      noarch

BuildRequires:  make
BuildRequires:  systemd-rpm-macros

Requires:       bash >= 4
Requires:       coreutils
Requires:       findutils
Requires:       systemd
Recommends:     dracut
%{?systemd_requires}

%description
kmod-profiler observes which kernel modules your system actually loads
over time, then generates a modprobe blacklist for everything else.

It hooks into kernel package installation and watches /lib/modules for
changes so the blacklist stays coherent across kernel updates, DKMS
rebuilds, and out-of-tree driver drops. New modules introduced by a
kernel update get a configurable grace period (default 7 days) before
they can be blacklisted, so observation has a chance to catch them
before they're suppressed.

This reduces the kernel's autoload attack surface against local
privilege escalation bugs in subsystems the system never legitimately
uses (e.g., Dirty Frag's RxRPC vector). It is hardening, not an
integrity boundary; pair with module signing and lockdown for that.

%prep
%autosetup -n %{name}-%{version}

%build
# Pure shell scripts and config files; nothing to compile.
make check

%install
make install DESTDIR=%{buildroot} PREFIX=/usr SBINDIR=%{_bindir} UNITDIR=%{_unitdir}

%files
%license /usr/share/doc/kmod-profiler/LICENSE
%doc /usr/share/doc/kmod-profiler/README.md
%doc /usr/share/doc/kmod-profiler/kmod-profiler.md
%{_bindir}/kmod-profiler
%{_unitdir}/kmod-profiler.service
%{_unitdir}/kmod-profiler.timer
%{_unitdir}/kmod-profiler-rescan.service
%{_unitdir}/kmod-profiler-rescan.path
%{_sysconfdir}/kernel/postinst.d/60-kmod-profiler
%{_sysconfdir}/kernel/install.d/40-kmod-profiler.install
%{_mandir}/man8/kmod-profiler.8*

%post
%systemd_post kmod-profiler.timer
%systemd_post kmod-profiler-rescan.path
# Auto-enable the trigger units on first install.
if [ $1 -eq 1 ] ; then
    systemctl enable --now kmod-profiler.timer kmod-profiler-rescan.path >/dev/null 2>&1 || :
fi

%preun
%systemd_preun kmod-profiler.timer
%systemd_preun kmod-profiler-rescan.path

%postun
%systemd_postun_with_restart kmod-profiler.timer
%systemd_postun_with_restart kmod-profiler-rescan.path
if [ $1 -eq 0 ]; then
    # Final removal: remind about state directory and live blacklist
    cat <<EOF
Note: kmod-profiler removed. Not removed:
    /var/lib/kmod-profiler/                    (state directory)
    /etc/modprobe.d/zz-kmod-profiler.conf      (active blacklist, if any)
Remove manually if a complete cleanup is desired.
EOF
fi

%changelog
* Thu May 07 2026 Brett C. <32656963+breca@users.noreply.github.com> - 1.0.0-1
- Initial release.
- Per-kernel observation and snapshot tracking with grace-period handling
- systemd timer + path watcher for steady-state and drift detection
- Kernel hooks for both Debian-style postinst.d and systemd kernel-install.d
- Mitigates Dirty Frag (esp4/esp6/rxrpc) on systems not using IPsec or AFS
