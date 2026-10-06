# titan2-keylight — always-on keyboard backlight for the Titan 2 / Titan 2 Elite

Keep the physical-keyboard backlight on for as long as the screen is on, instead
of the stock 30-second cap — while still being able to switch it off during the
day from the stock **`keyboard_led`** Quick Settings tile.

> Unofficial community project. Not affiliated with or endorsed by Unihertz or
> Agui. Use at your own risk.

## The problem

On the Titan 2 / Titan 2 Elite the keyboard backlight is managed by a vendor
service (`com.agui.server.functional.KeyboardLightController`) and a vendor
key/value store (`/data/system/agui_settings_data.xml`). The stock maximum
timeout is 30 seconds, and the setting is not exposed through the normal Android
Settings database.

## What this does

`kbled` writes a near-infinite timeout (`2147483647` ms ≈ 24.8 days) into the
vendor store through the `agui_common` binder service. The result:

- the backlight stays on the whole time the screen is on,
- it still turns off when the screen turns off and back on when the screen wakes,
- the stock `keyboard_led` tile keeps working: **ON** = always-on, **OFF** = off.

The tile's "off" path only writes `timeout=0` without powering the LED off
immediately, so `kbled` also installs a tiny on-device watcher that notices the
toggle and turns the LED off instantly. No root and no malware-style tricks — it
only uses the vendor service the Settings app itself uses.

## Requirements

- A Titan 2 / Titan 2 Elite (or another device exposing the `agui_common`
  service). Run `./kbled doctor` to check.
- `adb` (Android platform-tools) on your computer, with the phone authorized
  over USB **or** wireless debugging.
- `bash` and `awk`. No Python, no root.

## Install

```sh
git clone https://github.com/furkan-bayrak/titan2-keylight.git
cd titan2-keylight
./install.sh
```

Or directly:

```sh
./kbled install
```

### Wireless debugging

If you don't have a USB cable:

1. On the phone: **Developer options → Wireless debugging → on**.
2. Pair once (only needed the first time):
   ```sh
   adb pair <ip>:<pairing-port>     # code shown on the phone
   ```
3. Connect:
   ```sh
   adb connect <ip>:<port>          # port shown in Wireless debugging
   ```
4. Run `./kbled install` (it picks the only connected device automatically; use
   `--serial` if you have several).

## Usage

```sh
./kbled install     # apply the mod and start the watcher (default command)
./kbled status      # show current settings and watcher state
./kbled start       # start the watcher (e.g. after a reboot)
./kbled stop        # stop the watcher
./kbled uninstall   # restore the original settings and remove the watcher
./kbled doctor      # check device support
```

Options:

| Option | Description |
|---|---|
| `--timeout-ms MS` | timeout to write (default `2147483647`) |
| `--brightness N` | set LED brightness 0–100 (default: leave unchanged) |
| `--no-watcher` | don't start the background watcher |
| `-s, --serial S` | choose a specific adb device |
| `-f, --force` | overwrite an existing backup on install |

Examples:

```sh
./kbled install --timeout-ms 3600000      # 1 hour instead of 24 days
./kbled install --brightness 60
./kbled install --no-watcher              # always-on, but "off" waits for a screen cycle
```

The first install saves your original values to
`~/.config/kbled/backup-<serial>.env`; `uninstall` restores from there.

## Everyday use

Leave the phone as normal. The stock Quick Settings tile now means:

| Tile | Effect |
|---|---|
| **ON** | backlight on whenever the screen is on |
| **OFF** | backlight off immediately |

## After a reboot

The timeout settings persist across reboots. The watcher process does **not**
start automatically (that would require root or a boot app). After a reboot run:

```sh
./kbled start
```

Without the watcher the always-on mod still works; only the tile's instant "off"
is lost (it would apply on the next screen off/on). To automate it without root,
install [Termux:Boot](https://f-droid.org/packages/com.termux.boot/) and have it
run `kbled start`, or just re-run the command when you plug in.

## Uninstall / revert

```sh
./uninstall.sh          # or ./kbled uninstall
```

This restores your saved values and removes the on-device scripts. To wipe the
backup as well: `rm -rf ~/.config/kbled`.

## Compatibility

Tested on:

| Device | Android | Result |
|---|---|---|
| Unihertz Titan 2 (`Titan_2`) | 16 | works |

The Titan 2 Elite likely uses the same Agui keyboard stack. `./kbled doctor`
verifies the `agui_common` service and the expected key before changing
anything; if your firmware is unsupported it aborts without writing.

## Troubleshooting

- **`no authorized adb device found`** — check `adb devices`; authorize the
  computer on the phone, or reconnect wireless debugging.
- **`agui_common service not found`** — your firmware/variant doesn't expose the
  vendor service. Please open an issue with `./kbled doctor` output.
- **Tile OFF doesn't switch the light off immediately** — the watcher isn't
  running. Run `./kbled start` and check `./kbled status`.
- **Multiple devices** — pass `--serial <serial>` or set `KBLED_SERIAL`.

## How it works

See [docs/TECHNICAL.md](docs/TECHNICAL.md) for the full reverse-engineering
notes: the vendor keys, the binder transaction codes, and the watcher design.

## Contributing

Issues and PRs welcome. Run `shellcheck` before submitting; CI does the same.

## License

[MIT](LICENSE)
