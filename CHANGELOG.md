# Changelog

All notable changes to this project are documented here.
The format is based on [Keep a Changelog](https://keepachangelog.com/).

## [Unreleased]

### Added
- A dependency-free test suite (`tests/run.sh`) with a fake `adb`: it covers the
  argument matrix, the install/uninstall round trip, backup-file injection
  attempts, parcel decoding and the on-device watcher parser.

### Changed
- CI: `ludeeus/action-shellcheck` is pinned to a release commit instead of a
  moving tag, the workflow has read-only repository access, and the test suite
  runs on every push and pull request.
- `.gitignore`: removed an exception rule that matched nothing.
- `docs/TECHNICAL.md` is ASCII-only, like the rest of the repository.

### Fixed
- README and `--help` no longer present the tool's 30000 ms fallback as the
  stock timeout; the vendor default is 5000 ms.
- README no longer recommends Termux:Boot, which cannot keep the watcher alive
  on a stock, unrooted Titan 2.
- A backup file is parsed as data instead of being sourced, so a tampered
  backup can no longer run commands or inject arguments into an `adb` call.
- The backup is written atomically with mode 0600 inside a 0700 directory, and a
  failed read or write leaves the previous backup untouched.
- `kbled stop` stops the watcher through its pidfile when the on-device stop
  script is missing or fails, instead of leaving it running silently.
- A stale or recycled pid is no longer mistaken for a running watcher, and the
  pidfile content is validated before it reaches the device shell.
- A failed vendor-key write is reported with the `adb` exit status instead of
  ending the run silently.
- A failed read is reported as a read failure instead of showing an empty value
  or blaming the firmware; `status` prints `unavailable (read failed)`.
- A second command, an unknown option, a missing option value or an option that
  does not apply to the chosen command now exits with code 2.
- `--timeout-ms`, `--brightness` and `--serial` are validated before anything is
  sent to the device, and numeric values are normalised.
- `kbled status` reads `keyboard_led_auto_switch` again instead of failing on it.

## [1.0.0] - 2026-10-06

### Added
- Initial release.
- `kbled install` / `uninstall` / `status` / `start` / `stop` / `doctor`.
- Always-on keyboard backlight via the Agui `agui_common` vendor service.
- On-device watcher that makes the stock `keyboard_led` Quick Settings tile turn
  the backlight off immediately.
- Automatic per-device backup and restore of the original values.
- Shellcheck CI.
