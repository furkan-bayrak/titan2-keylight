# Changelog

All notable changes to this project are documented here.
The format is based on [Keep a Changelog](https://keepachangelog.com/).

## [Unreleased]

### Added
- A dependency-free test suite (`tests/run.sh`) with a fake `adb`: it covers the
  argument matrix, the install/uninstall round trip, backup-file injection
  attempts, parcel decoding and the on-device watcher parser.
- Test coverage for the recycled-pid guard on both sides of the wire: a live pid
  whose command line is not the watcher is neither reported as running nor
  killed, and the device-side `is_watcher` check is exercised against real
  processes.

### Changed
- CI: `ludeeus/action-shellcheck` is pinned to a release commit instead of a
  moving tag, the workflow has read-only repository access, and the test suite
  runs on every push and pull request.
- Tests: the fake `adb` fails with a clear message on an unhandled command
  instead of exiting successfully, so call-site drift cannot pass silently.
- `.gitignore`: removed an exception rule that matched nothing.
- `docs/TECHNICAL.md` is ASCII-only, like the rest of the repository.

### Fixed
- README and `--help` no longer present the tool's 30000 ms fallback as the
  stock timeout; the vendor default is 5000 ms.
- README no longer recommends Termux:Boot, which cannot keep the watcher alive
  on a stock, unrooted Titan 2.
- A backup file is parsed as data instead of being sourced, so a tampered
  backup can no longer run commands or inject arguments into an `adb` call.
- A backup that records neither a timeout nor a backup value (an empty file, or
  a v1.0.0 file written while both reads failed) is no longer reported as a
  restore; the tool warns that there is nothing to restore.
- The backup is written atomically with mode 0600 inside a 0700 directory, and a
  failed read or write leaves the previous backup untouched. Saving refuses a
  backup path that exists but is not a regular file, instead of nesting the
  temporary file inside it.
- `kbled stop` stops the watcher through its pidfile when the on-device stop
  script is missing or fails, instead of leaving it running silently. The
  on-device stop script verifies that the process is really gone before it
  removes the pidfile, and reports a watcher that survived the kill instead of
  pretending it stopped.
- A stale or recycled pid is no longer mistaken for a running watcher, and the
  pidfile content is validated before it reaches the device shell.
- A failed vendor-key write is reported with the `adb` exit status instead of
  ending the run silently.
- `kbled doctor` reports a clear error, including the sanitised `adb` output, and
  exits non-zero when `adb` cannot list the device services or read a property,
  instead of aborting silently.
- A failed read is reported as a read failure instead of showing an empty value
  or blaming the firmware; `status` prints `unavailable (read failed)`.
- Device-controlled text (vendor values, `getprop` output and the `adb` output
  echoed in failure messages) is stripped of control bytes before it is printed,
  so a hostile phone cannot inject terminal escape sequences.
- A second command, an unknown option, a missing option value or an option that
  does not apply to the chosen command now exits with code 2. An explicitly
  empty `--serial` counts as a mistake and exits 2 as well, while an empty
  `KBLED_SERIAL` still means auto-detect.
- `--timeout-ms`, `--brightness` and `--serial` are validated before anything is
  sent to the device, and numeric values are normalised.
- `kbled status` reads `keyboard_led_auto_switch` again instead of failing on it.
- Restored backup values are validated against the same timeout/brightness
  ranges as the command line and their leading zeros are normalised, so a
  hand-edited or imported backup can no longer push an out-of-range value into
  the device or fail the read-back check.

## [1.0.0] - 2026-10-06

### Added
- Initial release.
- `kbled install` / `uninstall` / `status` / `start` / `stop` / `doctor`.
- Always-on keyboard backlight via the Agui `agui_common` vendor service.
- On-device watcher that makes the stock `keyboard_led` Quick Settings tile turn
  the backlight off immediately.
- Automatic per-device backup and restore of the original values.
- Shellcheck CI.
