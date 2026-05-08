# kmod-profiler

A kernel-module allowlist system based on runtime observation: profile what your machine actually loads over time, blacklist everything else, and stay coherent across kernel updates.

---

## 1. Overview

`kmod-profiler` watches `/proc/modules` over a profiling window, accumulates the set of modules that were *ever observed loaded*, and generates a `modprobe.d` blacklist for every available-but-never-observed module. It hooks into kernel package installation and `/lib/modules` directory changes so that kernel upgrades, DKMS rebuilds, and out-of-tree driver drops don't silently desynchronize the blacklist from reality.

The motivating use case is reducing the kernel's autoload attack surface against local-privilege-escalation bugs in rarely-used subsystems — but the same shape of tool is useful for any environment where "we never use that subsystem, why is it loadable?" is a reasonable question.

This is **hardening**, not an integrity boundary. See §9 for the threat-model discussion.

---

## 2. Background and motivation

### 2.1 The immediate trigger: Dirty Frag

In late April / early May 2026, security researcher Hyunwoo Kim (@v4bel) disclosed a Linux kernel local-privilege-escalation chain dubbed **Dirty Frag**. It chains two independent kernel bugs:

- **xfrm-ESP Page-Cache Write** in `esp4.ko` / `esp6.ko` (IPsec ESP). In scope from upstream commit `cac2661c53f3` (2017-01-17) onward — essentially every distro kernel since early 2017.
- **RxRPC Page-Cache Write** in `rxrpc.ko` / `rxkad`. In scope from commit `2dc334f1a63a` (2023-06) onward.

Both bugs produce a deterministic 4-byte / 8-byte write primitive against splice-pinned page-cache pages — same family as Dirty Pipe / Copy Fail. They are pure logic bugs, not race conditions: no timing window, no panic on failure, very high success rate.

The researcher's `linux-distros` embargo was scheduled for May 12, 2026. An unrelated third party published the ESP exploit publicly on May 7, breaking the embargo and forcing immediate full disclosure. At that point no distro patches existed, and the published mitigation was to disable the affected modules:

```
install esp4 /bin/false
install esp6 /bin/false
install rxrpc /bin/false
```

For most workloads, this has no practical impact. ESP is only needed if the host terminates IPsec; RxRPC is only needed for kAFS (Andrew File System), which most systems don't use. The catch is that **on Ubuntu, `rxrpc` is autoloaded on demand** via `AF_RXRPC` socket creation, so any unprivileged user could trigger the exploitable code path on a default install.

### 2.2 Why a generalized tool

Dirty Frag is one instance of a recurring pattern: a kernel module that the system never actually uses contains a bug that's exploitable as soon as something can trigger it to load. Notable historical examples include:

- Various `dccp`, `sctp`, `tipc`, `rds`, `n_hdlc`, `appletalk`, `decnet` bugs over the years
- The 2022 `nf_tables` and `io_uring` LPE chains
- `CVE-2022-27666` — heap overflow in the same `esp6.c` file Dirty Frag exploits

The pattern is so consistent that CIS benchmarks include explicit "blacklist these obscure modules" recommendations. `kmod-profiler` generalizes that approach: instead of curating a static blacklist by hand, derive it empirically from what your system actually uses.

---

## 3. Why a profiler instead of a snapshot

A naive approach — `lsmod` once, blacklist everything else — fails because most kernel modules are autoloaded *on demand* in response to specific events. A snapshot taken at a moment when a feature isn't in use will blacklist that feature's modules, and the next time it's needed the system breaks.

The autoload mechanisms are numerous; here is a survey of the major categories. None of these lists is exhaustive — the union of all triggers is essentially "every `MODULE_ALIAS()` and `MODULE_DEVICE_TABLE()` macro in the kernel tree."

**udev modalias matching.** Every PCI/USB/HID/ACPI/DMI ID a driver declares becomes a udev alias. Plugging in a device emits a uevent and triggers `modprobe` against the alias. Covers GPU drivers (`i915`, `amdgpu`, `nouveau`), wifi chipset drivers, USB device classes, webcams (`uvcvideo`), fingerprint readers, NFC, smartcard readers, TPMs, hwmon sensors, IIO sensors, laptop platform drivers (`thinkpad_acpi`, `dell_laptop`, `asus_wmi`...), backlight drivers, game controllers, tablets, touchscreens.

**Filesystem mount.** `mount -t X` triggers `fs-X` alias load. Covers every fs driver: `nfsv4`, `cifs`, `9p`, `fuse`, `overlay`, `ceph`, `ntfs3`, `exfat`, `udf`, `isofs`, `squashfs`, plus character set helpers `nls_*` and codepages.

**Socket family / protocol.** `socket(AF_X, ..., proto)` triggers `net-pf-N` and `net-pf-N-proto-M` aliases. Covers `af_packet`, `af_netlink`, `af_alg` (kernel crypto API), `af_vsock`, `af_xdp`, `af_rxrpc` (the Dirty Frag vector on Ubuntu), `sctp`, `dccp`, `tipc`, `rds`, `atm`, `can`, `bluetooth`, and historical protocols like `appletalk`, `ax25`, `decnet`, `ipx`, `x25`, `phonet`, `ieee802154`.

**Netdev type.** `ip link add type X` triggers `netdev-X`. Covers `wireguard`, `vxlan`, `geneve`, `gre`, `ipip`, `sit`, `ip6tnl`, `vti`, `vlan`/`8021q`, `bridge`, `bonding`, `team`, `macvlan`, `ipvlan`, `veth`, `tun`, `dummy`, `ifb`.

**Crypto algorithm request.** Anything inside the kernel calling `crypto_alloc_*("name", ...)` triggers `crypto-name` aliases. Covers `aes_*`, `gcm`, `ccm`, `chacha20`, `poly1305`, `sha*`, `pcbc`, `cbc`, `xts`, `ecb`, `hmac`, `cmac`, every cipher template, every legacy hash. Many are pulled in only when a specific peer negotiates them.

**xfrm type.** IPsec SA negotiation triggers `xfrm-type-N` and `xfrm-offload-N`. `esp4`/`esp6` load this way.

**Netfilter / xtables / nftables.** A single `iptables-restore` of a complex ruleset can pull in dozens of modules: `nf_conntrack`, `nf_nat_*`, ALG helpers (`nf_conntrack_ftp`, `_sip`, `_h323`, `_tftp`, `_pptp`, `_irc`, `_amanda`, `_snmp`), every `xt_*` match/target, every `nft_*` expression.

**binfmt registration.** Running a binary whose magic isn't ELF triggers a binfmt module: `binfmt_misc` (Wine, Java, qemu-user-static for cross-arch containers), `binfmt_script`, `binfmt_aout`.

**device-mapper targets.** `dmsetup` with target X triggers `dm_X`: `dm_crypt`, `dm_thin`, `dm_cache`, `dm_raid`, `dm_integrity`, `dm_verity`, plus mdraid `raid0/1/4/5/6/10`.

**Block-layer / SCSI transports.** SAS/FC/iSCSI/NVMe-oF transports autoload subdrivers when a target appears.

**Tracing / perf / eBPF.** `perf record` and BPF programs can pull in `kprobes`, `uprobes`, tracer modules.

**Power-management transitions.** Different modules participate in s2idle vs s3 vs hibernate; a suspend cycle you never executed during profiling will fail to load them.

**Hypervisor / guest detection.** KVM, Hyper-V (`hv_*`), VMware (`vmw_*`), VirtualBox guest modules load based on platform detection.

**Container runtime startup.** Docker / containerd / Kubernetes start triggers `overlay`, `br_netfilter`, various `xt_*`, `ip_vs*`, possibly `sch_*` qdiscs.

**Bluetooth profile activation.** Pairing a headset vs a mouse vs a phone pulls in different L2CAP/RFCOMM/HID/A2DP submodules.

**Hot-plug events.** CPU hotplug, memory hotplug, PCI hotplug, Thunderbolt, USB-C alt-mode switching.

**Firmware-conditional load.** Some drivers probe and bail if firmware is missing; install a firmware package later and the driver suddenly autoloads.

The implication: a snapshot approach can only be safe if you've personally exercised every state transition, every device, every filesystem, every protocol, every container runtime, every suspend cycle. Continuous observation over a multi-week window is the only practical way to converge on a complete picture.

---

## 4. Architecture

### 4.1 State model

```
/var/lib/kmod-profiler/
├── observed/<kver>            per-kernel observed module set (sorted, normalized)
├── snapshots/<kver>           per-kernel available module set (sorted, normalized)
├── all-observed               union of observed sets across every kernel ever profiled
├── grace                      "module<TAB>first-seen-epoch" lines
├── generated-blacklist.conf   current generator output
└── profile.log                human-readable log of operations
```

Why this shape:

- **Per-kernel observed sets** let you answer "did I ever load X under kernel A?" precisely, useful for diagnosing why something is on the blacklist.
- **Per-kernel snapshots** let you `diff` two kernels — exactly what's needed to handle upgrades carefully.
- **`all-observed`** is the safe baseline: if a module has ever been observed loaded on any kernel, it's allowed.
- **`grace`** is the cold-start mitigation. When a new kernel introduces a module the system has never seen before, that module gets a first-seen timestamp. The blacklist generator excludes anything still inside its grace window.

Module names are normalized by replacing `-` with `_` everywhere comparisons happen, because the kernel does this internally. Compressed extensions (`.ko`, `.ko.xz`, `.ko.zst`, `.ko.gz`) are stripped during snapshotting.

### 4.2 Trigger paths

Three independent and complementary triggers feed the state machine:

1. **Periodic timer (`kmod-profiler.timer`, every minute).** Observes the running kernel's `/proc/modules` and updates `observed/<running-kver>` and `all-observed`.
2. **Kernel package install hooks.** When the package manager installs a kernel, the hook fires *before* initramfs regeneration. We snapshot the new kernel's module set, mark anything new with a grace timestamp, regenerate the blacklist, and refresh `/etc/modprobe.d/zz-kmod-profiler.conf`. The initramfs build that follows immediately picks up the new state.
3. **Path watcher (`kmod-profiler-rescan.path`).** Watches `/lib/modules` for changes the package hooks didn't see — DKMS rebuilds, vendor-driver drops, manual installations. Fires `kmod-profiler rescan`, which finds drift and processes it.

### 4.3 Blacklist generation policy

```
blacklist for $kver = (available in $kver) \ (all-observed) \ (in grace window)
```

A module ends up on the blacklist only if all three are true:

1. It exists as a `.ko` in `/lib/modules/$kver/`,
2. It has never been observed loaded on any kernel in the profile history, and
3. Its grace window (default 7 days from first appearance) has expired.

The output file emits both directives per blacklisted module:

```
blacklist <module>
install <module> /bin/false
```

`blacklist` blocks loading by canonical name; `install ... /bin/false` blocks loading via *any* alias (e.g. `xfrm-type-50` requesting ESP, `net-pf-45` requesting RxRPC). Both are required — `blacklist` alone is bypassed by autoloads through aliases.

### 4.4 Grace period rationale

The grace period is the load-bearing piece for resilience. When a kernel update introduces `foo_new`, the kernel hook records it with timestamp T. For 7 days, `foo_new` is allowed:

- If during those 7 days something loads it, it joins `all-observed` permanently and is never blacklisted.
- If 7 days pass with no observation, it gets blacklisted on the next `generate` cycle.

Tunable via the environment variable `KMOD_GRACE_SECONDS`. Reasonable values:

- **Servers with predictable workloads:** 2–7 days (the workload exercises everything quickly).
- **Desktops:** 7–14 days (a typical user touches all their devices and workflows within a week or two).
- **Laptops with sporadic device usage:** 30 days (`KMOD_GRACE_SECONDS=2592000`) — covers occasional travel hardware, monthly meetings on different equipment, etc.
- **Production with strict change control:** longer, plus manual review of `kmod-profiler diff` output before applying.

---

## 5. Component reference

### 5.1 `kmod-profiler` (main script)

Bash script, typically installed at `/usr/local/sbin/kmod-profiler`. Subcommands:

| Subcommand | Purpose |
|---|---|
| `sample` | Record currently loaded modules. Idempotent; safe to call repeatedly. |
| `status` | Show profile progress, snapshot inventory, recent log entries. |
| `generate [kver]` | Generate blacklist for a kernel (default: running kernel). |
| `apply [file]` | Install the generated blacklist to `/etc/modprobe.d/zz-kmod-profiler.conf`. |
| `kernel-changed <kver>` | Hook entry point for package installers. Snapshots, marks grace, regenerates, refreshes live blacklist if one is deployed. |
| `rescan` | Walk `/lib/modules`, snapshot any new kernels, detect drift in existing snapshots, process changes. |
| `diff <kver1> <kver2>` | Show module-set differences between two kernel snapshots. |

Configuration via environment variables:

- `KMOD_PROFILER_STATE` — state directory (default `/var/lib/kmod-profiler`)
- `KMOD_GRACE_SECONDS` — grace window in seconds (default `604800`, 7 days)

### 5.2 `kmod-profiler.service` and `kmod-profiler.timer`

The periodic sampler. The timer fires `kmod-profiler sample` every minute (`OnUnitActiveSec=1min`) and once 10 seconds after boot (`OnBootSec=10s`) to catch early-boot module loads. The service runs as a systemd `Type=oneshot` with `Nice=19` and `IOSchedulingClass=idle` so it stays out of the way.

### 5.3 `kmod-profiler-rescan.path` and `kmod-profiler-rescan.service`

The drift watcher. The `.path` unit uses `PathChanged=/lib/modules` and `PathModified=/lib/modules` to detect kernel directories appearing, disappearing, or having their attributes touched. When triggered, the service runs `kmod-profiler rescan`, which:

- Finds any `/lib/modules/<kver>/` without a snapshot and treats it as a new kernel install.
- Re-lists modules for each existing snapshot and compares against the saved file; any drift triggers `kernel-changed` for that kernel.

Critically, `PathChanged` does **not** recurse. A change deep inside `/lib/modules/$kver/extra/` does not fire the unit by itself; the rescan logic exists specifically to handle that case by walking and comparing.

### 5.4 `60-kmod-profiler` (Debian/Ubuntu kernel hook)

POSIX shell script installed at `/etc/kernel/postinst.d/60-kmod-profiler`. Invoked by `dpkg` after a kernel package's files are placed in `/lib/modules/$KVER/`. The numeric prefix is significant: scripts in `/etc/kernel/postinst.d/` run alphabetically, and `zz-update-initramfs` (registered by `initramfs-tools`) handles the initramfs rebuild. `60-` ensures we run before `zz-`, so the regenerated blacklist is in place when the initramfs is built.

### 5.5 `40-kmod-profiler.install` (systemd kernel-install hook)

POSIX shell script installed at `/etc/kernel/install.d/40-kmod-profiler.install`. Used by Fedora, RHEL, CentOS Stream, openSUSE MicroOS, Arch (when configured for `kernel-install`), and any other distro using systemd's `kernel-install` framework. The numeric prefix orders this before `50-dracut.install` and `50-mkinitcpio.install`.

The hook receives `$1=COMMAND` (`add`, `remove`) and `$2=KVER`. We act only on `add`; `remove` is intentionally ignored so historical observation data is preserved if a kernel is uninstalled.

---

## 6. Deployment

### 6.1 Installation

```bash
# Main script
sudo install -m 755 kmod-profiler /usr/local/sbin/

# Periodic sampler
sudo install -m 644 kmod-profiler.service /etc/systemd/system/
sudo install -m 644 kmod-profiler.timer   /etc/systemd/system/

# Path-watcher (catches DKMS, vendor drivers, out-of-band installs)
sudo install -m 644 kmod-profiler-rescan.service /etc/systemd/system/
sudo install -m 644 kmod-profiler-rescan.path    /etc/systemd/system/

sudo systemctl daemon-reload
sudo systemctl enable --now kmod-profiler.timer kmod-profiler-rescan.path

# Kernel package hooks — install whichever applies to your distro.
# Both can be installed safely; the irrelevant one simply never fires.

# Debian / Ubuntu / derivatives:
sudo install -m 755 60-kmod-profiler /etc/kernel/postinst.d/

# Fedora / RHEL / CentOS / Arch (anything using systemd kernel-install):
sudo install -m 755 40-kmod-profiler.install /etc/kernel/install.d/
```

### 6.2 Verifying installation

```bash
# Timer is active and scheduled
systemctl status kmod-profiler.timer

# Path watcher is armed
systemctl status kmod-profiler-rescan.path

# Hooks are executable
ls -l /etc/kernel/postinst.d/60-kmod-profiler 2>/dev/null
ls -l /etc/kernel/install.d/40-kmod-profiler.install 2>/dev/null

# After a few minutes, status should show progress
sudo kmod-profiler status
```

### 6.3 Initial profile period

Do not `apply` on day one. The minimum useful profile period is roughly:

- **At least one full boot cycle** (catches early-boot modules).
- **At least one full week of normal use** (catches weekly workflow modules).
- **At least one suspend/resume cycle**, if applicable.
- **Mount every filesystem you'll ever mount** (USB drives, SD cards, network shares, ISO images).
- **Connect every VPN and Bluetooth peer** you use.
- **Run any container runtimes**, VMs, dev environments you use.
- **Plug in every USB device** you own at least once.
- **Exercise any unusual workflows** (printing, scanning, screen sharing, audio capture, etc.).

For most environments, 2–4 weeks is the sweet spot. Longer is safer; shorter risks blacklisting something you'll need next month.

---

## 7. Operations

### 7.1 Generating and applying

```bash
# Inspect what would be blacklisted
sudo kmod-profiler generate
less /var/lib/kmod-profiler/generated-blacklist.conf

# After review, install it
sudo kmod-profiler apply

# Rebuild initramfs so blacklist takes effect at early boot
# Debian/Ubuntu:
sudo update-initramfs -u
# Fedora/RHEL:
sudo dracut -f
# Arch:
sudo mkinitcpio -P

# Reboot and verify the system still works
sudo reboot
```

After applying, the periodic timer continues running. The `kernel-changed` hook will refresh the live blacklist on every kernel package install. You don't need to re-run `apply` manually unless you want to trigger a fresh regeneration.

### 7.2 Reviewing the generated blacklist

Before applying, scan the output for anything that gives you pause. Categories worth scrutinizing:

- **Filesystem drivers** (`xfs`, `btrfs`, `ntfs3`, `exfat`, `udf`, `isofs`) — easy to miss if you don't mount that fs type during profiling.
- **USB and storage** (`usb_storage`, `uas`, `sd_mod` variants) — only loaded when a device is actually plugged in.
- **Input** (HID variants, joystick drivers, tablet protocols) — depends on what you've connected.
- **Audio** (`snd_*`) — easy to miss if you didn't use mic or headset during profiling.
- **Bluetooth, NFC, wireless regulatory** — feature-conditional.
- **Anything you might want for recovery** — USB drivers especially. If your blacklist removes USB keyboard support, an unbootable system becomes much harder to fix.

### 7.3 Tuning the grace period

```bash
# Override per-process
sudo KMOD_GRACE_SECONDS=2592000 /usr/local/sbin/kmod-profiler generate

# Persistent override via systemd drop-in
sudo systemctl edit kmod-profiler.service
# In the editor, add:
#   [Service]
#   Environment=KMOD_GRACE_SECONDS=2592000
# Repeat for kmod-profiler-rescan.service if desired.
```

### 7.4 Rollback

```bash
# Disable the blacklist file
sudo rm /etc/modprobe.d/zz-kmod-profiler.conf

# Rebuild initramfs to remove it from early boot
sudo update-initramfs -u    # or dracut -f / mkinitcpio -P

# Reboot
sudo reboot
```

Keep at least one previous kernel installed in your bootloader. If a blacklist update breaks boot, you can boot the previous kernel — its initramfs was built before your latest blacklist refresh, so it loads modules normally — and clean up from there.

You can also use the kernel command line for emergency recovery: `module_blacklist=` on the cmdline overrides the modprobe blacklist for boot only.

---

## 8. Failure modes

### 8.1 Hook ordering fragility

Naming is load-bearing. `60-kmod-profiler` runs before `zz-update-initramfs`; `40-kmod-profiler.install` runs before `50-dracut.install`. Renaming either hook silently breaks the guarantee that the blacklist is current when the initramfs is built. Verify ordering with:

```bash
ls /etc/kernel/postinst.d/
ls /etc/kernel/install.d/
```

### 8.2 Path units do not recurse

`PathChanged=/lib/modules` watches the immediate contents of that directory only. A `.ko` file appearing inside `/lib/modules/$kver/extra/` does **not** fire the path unit on its own. The `rescan` subcommand exists to handle this: it walks each kernel's tree and compares against the saved snapshot. Drift is caught either when the path unit fires for any other reason, or whenever you manually run `kmod-profiler rescan`.

If you want belt-and-suspenders coverage of in-place changes, add a daily timer:

```ini
# /etc/systemd/system/kmod-profiler-rescan.timer
[Timer]
OnCalendar=daily
Persistent=true
[Install]
WantedBy=timers.target
```

### 8.3 Grace window sizing

Too short, and a kernel update that introduces a module you genuinely need (but haven't exercised yet) blacklists it before observation catches up. Too long, and you carry unnecessary attack surface for the duration of the window.

The risk profile is asymmetric: too short causes user-visible breakage; too long merely delays hardening. Default toward longer for desktops and laptops, shorter for tightly-scoped servers.

### 8.4 Cold start

On first deployment, every available module appears "new to the system" and goes into grace. This is intentional: the first generated blacklist is empty (or nearly so), and the system is unaffected. Real blacklisting begins only after grace expires, by which time observation has had a chance to capture the modules actually in use.

The corollary: do not deploy this tool *and* `apply` the blacklist on the same day. Wait at least one grace period (default 7 days) and ideally one observation cycle longer.

### 8.5 Built-in modules are invisible

Modules compiled into the kernel image (`CONFIG_FOO=y` rather than `=m`) do not appear in `/lib/modules/$kver/`. They cannot be blacklisted via modprobe.d (they're already part of the kernel) and don't need to be — but be aware your blacklist only covers `=m` modules.

A subtle consequence: when a distro switches a module from `=y` to `=m` in a kernel update, that module suddenly appears available, has never been observed (because previously it was built-in and didn't show up in `/proc/modules` as a separately-loaded module), and gets the grace treatment. After grace expires, it gets blacklisted — even though it was working fine before. Inspect such transitions with `kmod-profiler diff <old-kver> <new-kver>`.

### 8.6 State drift across kernel updates

A module can be renamed (`ntfs` → `ntfs3`), split into multiple modules, or merged with others across kernel versions. The profiler doesn't track these renames; it sees only "module X is gone, module Y is new." If you depend on a renamed module, the new name will be in grace and eventually blacklisted unless something loads it during the window.

Mitigation: when reviewing `kmod-profiler diff <old-kver> <new-kver>`, watch for symmetric appear/disappear pairs and verify they're not silent renames.

### 8.7 DKMS and out-of-tree timing

DKMS rebuilds normally happen during the same kernel package install transaction (triggered by the kernel hook), so they're caught by the kernel-changed flow. Manual `dkms install` runs outside a kernel update fall to the path watcher. Worst case is a `dkms install` that races with a sample: the new module exists on disk but isn't yet in the snapshot. The next sample or rescan corrects this.

---

## 9. Threat model and hardening posture

### 9.1 What this defends against

Local privilege-escalation bugs in kernel modules that the legitimate workload never uses. Concretely:

- An unprivileged process tries to autoload a vulnerable module via socket family, netdev type, crypto algorithm name, mount, or any other autoload trigger.
- The blacklist + `install ... /bin/false` combination causes `modprobe` to fail without loading the module.
- The exploit's prerequisite — vulnerable code being resident in the kernel — is never satisfied.

This is what mitigates Dirty Frag's RxRPC half on a hardened Ubuntu box: an unprivileged user calling `socket(AF_RXRPC, ...)` no longer triggers `rxrpc.ko` to load.

### 9.2 What this does *not* defend against

- **Root-level attackers.** Anything running as UID 0 can `rmmod`, edit `/etc/modprobe.d/`, rebuild the initramfs, or simply `insmod` a `.ko` directly. The blacklist is advisory enforcement at the modprobe layer, not an integrity boundary.
- **Bugs in modules that *are* loaded.** If `ext4` has a vulnerability and you mount ext4 filesystems, the profiler does nothing for you. Allowlisting based on observation by definition allows everything observation has seen.
- **Bugs in built-in code.** Modules compiled `=y` are part of the kernel image; the profiler has no effect on them.
- **Kernel command-line attacks at boot.** An attacker with bootloader access can pass `module_blacklist=` overrides or boot a different kernel entirely.
- **Initramfs tampering.** If the initramfs is mutable post-build, a privileged attacker can inject modules into it.

### 9.3 Complementary mechanisms

For threats outside the profiler's scope, stack additional controls:

- **Module signing + lockdown mode.** `CONFIG_MODULE_SIG_FORCE=y` requires every loaded module to bear a valid signature from a trusted key. Combined with `lockdown=integrity` or `lockdown=confidentiality` (via Secure Boot, kernel cmdline, or LSM), this prevents even root from loading unsigned or unauthorized modules. This *is* a real integrity boundary.
- **Unprivileged user namespace restrictions.** `kernel.unprivileged_userns_clone=0` (Debian/Ubuntu) or `user.max_user_namespaces=0` (sysctl) blocks the namespace creation path that many LPE chains require — including Dirty Frag's ESP half.
- **AppArmor / SELinux profiles** on services that don't need access to kernel module operations.
- **Reduced kernel attack surface at build time** for environments where you can roll a custom kernel: `CONFIG_USERFAULTFD=n`, `CONFIG_BPF_UNPRIV_DEFAULT_OFF=y`, and similar hardening configs.
- **Kernel runtime guards** like LKRG (Linux Kernel Runtime Guard) for additional integrity monitoring.

The profiler-driven blacklist reduces the autoload attack surface; module signing + lockdown raises the bar against a privileged attacker; namespace restrictions cut off a major exploit precondition. They address different layers and stack cleanly.

### 9.4 Threat-model summary

| Attacker capability | Profiler blacklist | Module signing + lockdown | Namespace restrictions |
|---|---|---|---|
| Unprivileged code execution | ✅ blocks autoload of unused modules | ➖ orthogonal | ✅ blocks namespace-gated exploits |
| Root code execution | ❌ trivially bypassed | ✅ blocks unauthorized loads | ❌ orthogonal |
| Boot-time tampering | ❌ overridable via cmdline | ✅ if Secure Boot enforced | ❌ overridable |
| Bug in already-loaded module | ❌ does not apply | ❌ does not apply | ➖ may help if exploit needs ns |

---

## 10. Diagnostics

### 10.1 Inspecting state

```bash
# Overall profile progress
sudo kmod-profiler status

# Has module X ever been observed loaded on any kernel?
grep -l '^X$' /var/lib/kmod-profiler/observed/*

# What's currently in the grace window?
awk -F'\t' -v c=$(($(date +%s) - 604800)) '$2 > c' /var/lib/kmod-profiler/grace

# What changed between two kernel versions?
sudo kmod-profiler diff 6.10.0 6.12.0

# Recent activity
tail -f /var/lib/kmod-profiler/profile.log
```

### 10.2 Common debugging recipes

**"Module X stopped working after a kernel upgrade."** Run `kmod-profiler diff <old> <new>` to see if X moved or was renamed. Check `grep X /var/lib/kmod-profiler/observed/*` to see if it was ever observed under any kernel. If it's a brand-new module from the upgrade, it should be in the grace file. If grace expired before you used it, the fix is to remove the relevant lines from `/etc/modprobe.d/zz-kmod-profiler.conf`, load the module manually (`sudo modprobe X`), and let the next sample cycle pick it up — or extend the grace period and regenerate.

**"My system won't boot after `apply`."** Boot the previous kernel from the bootloader menu. Once running, remove `/etc/modprobe.d/zz-kmod-profiler.conf`, rebuild the initramfs for the broken kernel, and reboot. Then investigate which module was needed: `kmod-profiler diff` between the working and broken kernel snapshots, and check `dmesg` from the failed boot for missing-module errors.

**"My blacklist is empty / very short."** You're probably still in the cold-start grace window. Run `kmod-profiler status` and check the "In grace window" count. Wait until it drops (or temporarily lower `KMOD_GRACE_SECONDS` to test, then restore the production value).

**"DKMS module not appearing in observations."** Check `lsmod` — if it's not loaded, `modprobe X` it manually and verify the next `sample` picks it up. If it never autoloads on its own, you may need to mark it for boot-time loading via `/etc/modules-load.d/`.

### 10.3 Recovery escape hatches

In rough order of severity:

1. **Live override.** `sudo modprobe -i X` ignores the install rule. Useful for one-off testing.
2. **Edit the live blacklist.** Remove specific lines from `/etc/modprobe.d/zz-kmod-profiler.conf`, run `sudo modprobe X` to verify, then rebuild the initramfs. The next `kernel-changed` event will rewrite this file, so make the corresponding fix in the profiler state (load the module so it gets observed) before that happens.
3. **Disable the file.** `sudo mv /etc/modprobe.d/zz-kmod-profiler.conf /root/` and rebuild initramfs. System behaves as if the profiler never applied anything.
4. **Disable the timer and hooks.** `sudo systemctl disable --now kmod-profiler.timer kmod-profiler-rescan.path; sudo rm /etc/kernel/postinst.d/60-kmod-profiler /etc/kernel/install.d/40-kmod-profiler.install`. Profiler stops observing and stops refreshing the blacklist on kernel updates. State directory remains.
5. **Boot a different kernel.** Pick a previous kernel from the bootloader. Its initramfs was built with an older (or absent) blacklist.
6. **Boot with `module_blacklist=`.** Add `module_blacklist=` (empty) to the kernel command line at the bootloader to override the modprobe blacklist for that single boot.

---

## 11. Maintenance

### 11.1 When to re-profile from scratch

Most distro upgrades and routine workflow changes are handled incrementally by the existing trigger paths. Re-profile from scratch (delete `/var/lib/kmod-profiler/` and start over) when:

- You're moving to a substantially different kernel branch (e.g., from a vendor LTS to mainline, or a major version jump that reshuffles the module layout).
- You've changed the workload significantly (server repurposed, laptop changed primary role).
- The accumulated state has gotten stale or corrupted in some way.

A re-profile is cheap; the cost is a new grace-period worth of time before the next blacklist takes effect.

### 11.2 Backing up state

The state directory is small and worth backing up alongside other system configuration. A simple inclusion in your existing config-backup process is sufficient:

```bash
# Snapshot before risky operations
sudo tar -czf /root/kmod-profiler-state-$(date +%F).tar.gz /var/lib/kmod-profiler/
```

Restoring is just untarring it back into place.

### 11.3 Major distro upgrades

A distro upgrade typically installs a new kernel, which fires the kernel hook normally. The grace window protects you against any newly-introduced modules. The risk is if the upgrade *removes* the kernel package management hooks themselves — verify after upgrade that `/etc/kernel/postinst.d/60-kmod-profiler` (or the `kernel-install.d` equivalent) is still in place. Distro upgrades occasionally clean out non-package files in these directories.
