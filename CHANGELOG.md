# Changelog

All notable changes to this project are documented here.
The format is based on [Keep a Changelog](https://keepachangelog.com/).

## [1.0.0] - 2026-10-06

### Added
- Initial release.
- `kbled install` / `uninstall` / `status` / `start` / `stop` / `doctor`.
- Always-on keyboard backlight via the Agui `agui_common` vendor service.
- On-device watcher that makes the stock `keyboard_led` Quick Settings tile turn
  the backlight off immediately.
- Automatic per-device backup and restore of the original values.
- Shellcheck CI.
