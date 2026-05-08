# kmod-profiler tests

Tests use [bats-core](https://github.com/bats-core/bats-core), the standard bash testing framework.

## Running locally

```sh
# Install bats
sudo apt-get install bats          # Debian/Ubuntu
sudo dnf install bats              # Fedora/RHEL
sudo pacman -S bats                # Arch
brew install bats-core             # macOS

# Run all tests
./tests/run.sh

# Or directly:
bats tests/

# Run one file
bats tests/02-generate.bats

# Verbose output for debugging a failing test
bats --verbose-run tests/02-generate.bats
```

## Test layout

| File | Coverage |
|---|---|
| `01-sample.bats` | The `sample` subcommand: state file creation, observation accumulation, name normalization, missing-input handling. |
| `02-generate.bats` | The `generate` subcommand: blacklist correctness, grace-window respect, cross-kernel observation reuse, header counts. |
| `03-resilience.bats` | `kernel-changed` and `rescan`: kernel-upgrade flow, DKMS drift detection, idempotency, live-blacklist refresh. |
| `04-inspection.bats` | `diff` and `status`: read-only inspection commands. |
| `05-edge-cases.bats` | Compressed extensions, deeply nested kernel/ trees, hyphen↔underscore normalization, empty inputs, duplicate samples. |
| `06-hooks.bats` | Both kernel package hooks: argument handling, command dispatch, missing-binary safety. |
| `07-integration.bats` | End-to-end scenarios: cold start, Dirty Frag mitigation, kernel upgrades, DKMS drops, rollback. |
| `08-packaging.bats` | `make install` / `make uninstall` round-trip, layout correctness, installed-script functionality. |

## How tests isolate from the host system

`tests/helpers.bash` provides `make_sandbox` / `destroy_sandbox`, called from each test's `setup` / `teardown`. The sandbox creates a temporary directory under `$BATS_TMPDIR` and exports environment variables that override every external path the script touches:

- `KMOD_PROFILER_STATE` → temp dir (instead of `/var/lib/kmod-profiler/`)
- `KMOD_PROC_MODULES` → temp file (instead of `/proc/modules`)
- `KMOD_LIB_MODULES` → temp tree (instead of `/lib/modules/`)
- `KMOD_LIVE_BLACKLIST` → temp file (instead of `/etc/modprobe.d/zz-kmod-profiler.conf`)
- `KMOD_KERNEL_VERSION` → fixed test value (instead of `uname -r`)

This means tests can run as an unprivileged user, in parallel, and without touching any real system files.

Helper functions:

- `mock_kernel <kver> <mod...>` — create a fake `/lib/modules/<kver>/` with the named modules.
- `mock_loaded <mod...>` — populate fake `/proc/modules`.
- `set_kernel <kver>` — pretend we're running a different kernel.
- `age_grace <mod> <seconds>` — backdate a module's grace timestamp without sleeping.
- `assert_file_exists`, `assert_file_contains`, `assert_file_not_contains` — readable assertions with diagnostic output.

## CI integration

The GitHub Actions workflow in `.github/workflows/build.yml` runs the test suite as the `lint` job (renamed `test`), which is a prerequisite for all package-build jobs. A failing test prevents `.deb` / `.rpm` / Arch packages from being produced, ensuring no broken release artifacts get published.
