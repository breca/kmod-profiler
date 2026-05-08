# kmod-profiler — Makefile
#
# Default install layout follows the FHS:
#   /usr/local/sbin/kmod-profiler                  (or /usr/sbin under DESTDIR=/usr)
#   /lib/systemd/system/*.{service,timer,path}
#   /etc/kernel/postinst.d/60-kmod-profiler
#   /etc/kernel/install.d/40-kmod-profiler.install
#   /usr/share/doc/kmod-profiler/kmod-profiler.md
#
# Variables:
#   DESTDIR     staging root for packagers (default: empty)
#   PREFIX      installation prefix          (default: /usr/local)
#   SBINDIR     binary directory             (default: $(PREFIX)/sbin)
#   SYSCONFDIR  config directory             (default: /etc)
#   UNITDIR     systemd unit directory       (default: /lib/systemd/system)
#   DOCDIR      documentation directory      (default: $(PREFIX)/share/doc/kmod-profiler)
#
# Targets:
#   install         install everything
#   install-bin     install just the script
#   install-units   install just the systemd units
#   install-hooks   install just the kernel hooks
#   install-docs    install documentation
#   uninstall       remove everything
#   tarball         produce a release tarball
#   deb             build a .deb (requires debhelper)
#   rpm             build an .rpm (requires rpmbuild)

NAME       := kmod-profiler
VERSION    := 1.0.0

PREFIX     ?= /usr/local
SBINDIR    ?= $(PREFIX)/sbin
SYSCONFDIR ?= /etc
UNITDIR    ?= /lib/systemd/system
DOCDIR     ?= $(PREFIX)/share/doc/$(NAME)
MANDIR     ?= $(PREFIX)/share/man

INSTALL    := install

.PHONY: all install install-bin install-units install-hooks install-docs \
        install-man install-cron install-openrc install-runit \
        install-no-systemd uninstall check test tarball deb rpm arch \
        packages clean

all:
	@echo "Nothing to build. Run 'make install' to install."
	@echo "See README.md for details."

# Run the test suite. Requires bats-core.
test:
	@command -v bats >/dev/null 2>&1 || { \
		echo "Error: bats-core required. Install with:"; \
		echo "  apt install bats / dnf install bats / pacman -S bats"; \
		exit 1; }
	bats tests/

install: install-bin install-units install-hooks install-docs install-man

install-bin:
	$(INSTALL) -d $(DESTDIR)$(SBINDIR)
	$(INSTALL) -m 0755 sbin/kmod-profiler $(DESTDIR)$(SBINDIR)/kmod-profiler

install-units:
	$(INSTALL) -d $(DESTDIR)$(UNITDIR)
	$(INSTALL) -m 0644 systemd/kmod-profiler.service        $(DESTDIR)$(UNITDIR)/
	$(INSTALL) -m 0644 systemd/kmod-profiler.timer          $(DESTDIR)$(UNITDIR)/
	$(INSTALL) -m 0644 systemd/kmod-profiler-rescan.service $(DESTDIR)$(UNITDIR)/
	$(INSTALL) -m 0644 systemd/kmod-profiler-rescan.path    $(DESTDIR)$(UNITDIR)/

install-hooks:
	$(INSTALL) -d $(DESTDIR)$(SYSCONFDIR)/kernel/postinst.d
	$(INSTALL) -d $(DESTDIR)$(SYSCONFDIR)/kernel/install.d
	$(INSTALL) -m 0755 kernel-hooks/postinst.d/60-kmod-profiler \
		$(DESTDIR)$(SYSCONFDIR)/kernel/postinst.d/60-kmod-profiler
	$(INSTALL) -m 0755 kernel-hooks/install.d/40-kmod-profiler.install \
		$(DESTDIR)$(SYSCONFDIR)/kernel/install.d/40-kmod-profiler.install

install-docs:
	$(INSTALL) -d $(DESTDIR)$(DOCDIR)
	$(INSTALL) -m 0644 docs/kmod-profiler.md $(DESTDIR)$(DOCDIR)/
	$(INSTALL) -m 0644 README.md             $(DESTDIR)$(DOCDIR)/
	$(INSTALL) -m 0644 LICENSE               $(DESTDIR)$(DOCDIR)/

install-man:
	$(INSTALL) -d $(DESTDIR)$(MANDIR)/man8
	$(INSTALL) -m 0644 man/kmod-profiler.8 $(DESTDIR)$(MANDIR)/man8/kmod-profiler.8
	@if command -v gzip >/dev/null 2>&1 ; then \
		gzip -9 -n -f $(DESTDIR)$(MANDIR)/man8/kmod-profiler.8 ; \
	fi

# Non-systemd scheduler installs. Use these instead of (or alongside)
# install-units on distros without systemd.

install-cron:
	$(INSTALL) -d $(DESTDIR)$(SYSCONFDIR)/cron.d
	$(INSTALL) -m 0644 cron/kmod-profiler.cron \
		$(DESTDIR)$(SYSCONFDIR)/cron.d/kmod-profiler

install-openrc:
	$(INSTALL) -Dm755 openrc/kmod-profiler.initd \
		$(DESTDIR)$(SYSCONFDIR)/init.d/kmod-profiler
	$(INSTALL) -Dm644 openrc/kmod-profiler.confd \
		$(DESTDIR)$(SYSCONFDIR)/conf.d/kmod-profiler

install-runit:
	$(INSTALL) -d $(DESTDIR)$(SYSCONFDIR)/sv/kmod-profiler
	$(INSTALL) -m 0755 runit/run \
		$(DESTDIR)$(SYSCONFDIR)/sv/kmod-profiler/run

# Convenience aggregate: install everything except the systemd units, plus
# both cron AND OpenRC fallbacks (use whichever your distro favors).
install-no-systemd: install-bin install-hooks install-docs install-man \
                    install-cron install-openrc

uninstall:
	rm -f $(DESTDIR)$(SBINDIR)/kmod-profiler
	rm -f $(DESTDIR)$(UNITDIR)/kmod-profiler.service
	rm -f $(DESTDIR)$(UNITDIR)/kmod-profiler.timer
	rm -f $(DESTDIR)$(UNITDIR)/kmod-profiler-rescan.service
	rm -f $(DESTDIR)$(UNITDIR)/kmod-profiler-rescan.path
	rm -f $(DESTDIR)$(SYSCONFDIR)/kernel/postinst.d/60-kmod-profiler
	rm -f $(DESTDIR)$(SYSCONFDIR)/kernel/install.d/40-kmod-profiler.install
	rm -f $(DESTDIR)$(SYSCONFDIR)/cron.d/kmod-profiler
	rm -f $(DESTDIR)$(SYSCONFDIR)/init.d/kmod-profiler
	rm -f $(DESTDIR)$(SYSCONFDIR)/conf.d/kmod-profiler
	rm -rf $(DESTDIR)$(SYSCONFDIR)/sv/kmod-profiler
	rm -f $(DESTDIR)$(MANDIR)/man8/kmod-profiler.8
	rm -f $(DESTDIR)$(MANDIR)/man8/kmod-profiler.8.gz
	rm -rf $(DESTDIR)$(DOCDIR)
	@echo "Note: state directory /var/lib/kmod-profiler and live blacklist"
	@echo "      /etc/modprobe.d/zz-kmod-profiler.conf are NOT removed."
	@echo "      Remove them manually if desired."

# Syntax-check shell scripts and lint the man page.
check:
	bash -n sbin/kmod-profiler
	sh -n kernel-hooks/postinst.d/60-kmod-profiler
	sh -n kernel-hooks/install.d/40-kmod-profiler.install
	@if command -v mandoc >/dev/null 2>&1 ; then \
		mandoc -T lint -W warning man/kmod-profiler.8 || exit 1 ; \
		echo "Man page lints clean." ; \
	else \
		echo "(mandoc not installed; skipping man page lint)" ; \
	fi
	@echo "All shell scripts pass syntax check."

# Build a release tarball
tarball:
	git archive --format=tar.gz --prefix=$(NAME)-$(VERSION)/ \
		-o $(NAME)-$(VERSION).tar.gz HEAD 2>/dev/null || \
	tar --transform 's,^,$(NAME)-$(VERSION)/,' \
		--exclude=.git --exclude='*.tar.gz' --exclude='*.deb' --exclude='*.rpm' \
		--exclude='*.pkg.tar.zst' --exclude='arch/pkg' --exclude='arch/src' \
		-czf $(NAME)-$(VERSION).tar.gz \
		Makefile README.md LICENSE install.sh \
		sbin systemd kernel-hooks man docs tests \
		cron openrc runit alpine \
		debian rpm arch .github

deb:
	dpkg-buildpackage -us -uc -b

rpm:
	rpmbuild -bb --define "_sourcedir $(CURDIR)" \
		--define "_topdir $(CURDIR)/build/rpm" \
		rpm/$(NAME).spec

# Build the Arch package. makepkg refuses to run as root, so this target
# must be run as a normal user with sudo privileges (for installing build deps).
arch:
	@command -v makepkg >/dev/null 2>&1 || { \
		echo "Error: makepkg not found. Install: pacman -S base-devel"; \
		exit 1; }
	@if [ "$$(id -u)" -eq 0 ]; then \
		echo "Error: makepkg refuses to run as root."; \
		echo "       Run 'make arch' as a normal user."; \
		exit 1; \
	fi
	$(MAKE) tarball
	cp $(NAME)-$(VERSION).tar.gz arch/
	cd arch && makepkg -f --skipchecksums
	@echo
	@echo "Built: arch/$(NAME)-$(VERSION)-*-any.pkg.tar.zst"

# Build all three package formats. Each format's prerequisites must be installed.
packages: deb rpm arch

clean:
	rm -f $(NAME)-$(VERSION).tar.gz
	rm -f arch/$(NAME)-$(VERSION).tar.gz
	rm -f arch/$(NAME)-$(VERSION)-*.pkg.tar.zst
	rm -f arch/*.log
	rm -rf arch/pkg arch/src
	rm -rf build/
	rm -rf debian/.debhelper debian/$(NAME) debian/files debian/*.substvars debian/*.debhelper.log
