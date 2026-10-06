# titan2-keylight

Keep the keyboard backlight on your Unihertz Titan 2 or Titan 2 Elite on for as long as the screen is on, and still turn it off with the phone's own Quick Settings tile when you want to.

> Unofficial community project. Not affiliated with or endorsed by Unihertz or Agui. Use at your own risk.

## What this does

The Titan 2 turns the keyboard backlight off a few seconds after your last key press, and the phone has no setting to keep it on. This project changes the hidden timeout behind that behaviour, so the backlight stays on the whole time the screen is on. It still goes off when the screen goes off, and comes back on when the screen wakes up.

The `keyboard_led` tile in Quick Settings (the panel you pull down from the top of the screen) keeps working exactly as before:

- tile **on**: backlight on whenever the screen is on,
- tile **off**: backlight off immediately.

No root, no custom firmware, no extra app installed on the phone. The scripts only use the same hidden vendor service that the phone's own Settings app uses.

## Requirements

- A Unihertz Titan 2 or Titan 2 Elite, or another phone that exposes the same `agui_common` vendor service. `./kbled doctor` checks this before anything is changed.
- A computer (macOS, Linux or Windows) with `adb` installed. `adb` is Google's free command-line tool for talking to an Android phone from a computer; it comes in the "Android platform-tools" package.
- `bash` and `awk` on that computer; no Python is needed. Both are already installed on macOS and Linux; on Windows, use WSL or Git Bash.
- A USB cable, or wireless debugging turned on (see step 2 below). No root is needed.

## Install

### 1. Get the code

```bash
git clone https://github.com/furkan-bayrak/titan2-keylight.git
cd titan2-keylight
```

### 2. Connect the phone

With a USB cable:

```bash
adb devices
```

USB debugging must be turned on in Developer options. If Developer options is not in your Settings app yet, Android shows it after you tap the build number in Settings > About phone seven times. The first time you connect, the phone asks whether to trust the computer; tap Allow. Your phone should appear in the list with the word `device` next to it.

Over Wi-Fi, using wireless debugging:

Wireless debugging is an Android feature that lets `adb` talk to the phone over your Wi-Fi network instead of a cable. Turn it on in **Developer options > Wireless debugging** (the phone shows the IP address and ports there), then run these two commands; the pairing step is only needed the first time:

```bash
adb pair <ip>:<pairing-port>    # the code is shown on the phone
adb connect <ip>:<port>         # the port is shown in the Wireless debugging screen
```

### 3. Install

```bash
./install.sh
```

`install.sh` is a shortcut for `./kbled install`, so either command does the same thing.

The script checks the phone, saves your original settings, writes the new timeout and starts a small helper (see Everyday use). A single connected device is picked automatically; if you have more than one, add `--serial <serial>`, using the serial shown by `adb devices`.

## First use

The change takes effect straight away. With the screen on, type something and stop: the backlight should stay on. To check the settings and the helper, run:

```bash
./kbled status
```

Extra options for `install`:

- `--timeout-ms MS` - how long the light stays on. The default is `2147483647` ms, about 24.8 days, which is effectively "as long as the screen is on".
- `--brightness N` - LED brightness from 0 to 100. By default your current brightness is left alone.
- `--no-watcher` - do not start the helper. The backlight is still always-on, but the tile's "off" then applies at the next screen off/on cycle.
- `-s, --serial S` - choose a specific device, or set `KBLED_SERIAL`.

```bash
./kbled install --timeout-ms 3600000    # one hour instead of "always"
./kbled install --brightness 60
./kbled install --no-watcher
```

The first install saves your phone's original values to a small file on your computer at `~/.config/kbled/backup-<serial>.env`, and `uninstall` restores from it. Later installs keep the first backup as your clean restore point unless you pass `--force` to replace it.

## Everyday use

Use the phone as usual. The backlight stays on while the screen is on, and the Quick Settings tile means:

| Tile | What happens |
| --- | --- |
| on | backlight on whenever the screen is on |
| off | backlight off immediately |

The instant "off" comes from a small helper script (the "watcher") that runs on the phone and watches for that tap. It does nothing else.

All commands, run from the cloned folder:

| Command | What it does |
| --- | --- |
| `./kbled install` | apply the change and start the watcher (what `./install.sh` runs) |
| `./kbled status` | show the current settings and watcher state |
| `./kbled start` | start the watcher |
| `./kbled stop` | stop the watcher |
| `./kbled uninstall` | restore the original settings and remove the watcher |
| `./kbled doctor` | check that the phone is supported |
| `./kbled version` | print the version |

## After a reboot

The timeout setting is stored on the phone, so the always-on backlight survives a reboot. The watcher does not start by itself, because starting it automatically would need root. After a reboot, run:

```bash
./kbled start
```

Without the watcher, the always-on part still works. Only the tile's instant "off" is lost; the light would then go off at the next screen off/on cycle.

There is no supported way to start the watcher automatically without root: `kbled` is the computer-side program, so it cannot run on the phone by itself. Run `./kbled start` from the computer again after a reboot, for example the next time you plug the phone in.

## Troubleshooting

- **"no authorized adb device found"** - the computer cannot see the phone. Run `adb devices`; if nothing is listed, authorize the computer on the phone, or reconnect wireless debugging.
- **"agui_common service not found"** - your firmware does not have the hidden vendor service this tool uses, so the phone is not supported and nothing is changed. Please open an issue with the output of `./kbled doctor`.
- **"write verification failed"** - the phone did not keep the new value, which usually means a firmware update changed that vendor service. Run `./kbled uninstall` to put your original values back, then open an issue with the output of `./kbled doctor`.
- **Tile "off" does not switch the light off immediately** - the watcher is not running. Run `./kbled start` and check `./kbled status`.
- **Multiple devices connected** - pass `--serial <serial>` or set `KBLED_SERIAL`.

## Uninstall

```bash
./uninstall.sh
```

or `./kbled uninstall`. This stops the watcher, restores the values saved at install time and deletes the helper scripts from the phone.

If no backup file is found (for example, if you installed from another computer), the timeout is reset to `30000` ms, the tool's own fallback value. That is not necessarily what your phone shipped with (the vendor default is `5000` ms), so keep the backup file if you can.

To delete the backup file from your computer as well:

```bash
rm -rf ~/.config/kbled
```

## Compatibility

Tested on:

| Phone | Android | Result |
| --- | --- | --- |
| Unihertz Titan 2 (`Titan_2`) | 16 | works |

The Titan 2 Elite most likely uses the same Agui keyboard stack, but it has not been tested here.

Before writing anything, `./kbled doctor` checks for the hidden vendor service and the expected setting, and the installer verifies every value it writes. If your firmware is unsupported, the script stops without changing anything.

## How it works

The keyboard backlight is not a normal Android setting. It lives in a hidden vendor file that only a system service can reach, so `kbled` asks that service (the same one the Settings app uses) to store a very large timeout, and keeps a small watcher running that makes the Quick Settings tile turn the light off instantly. Nothing is patched and no root is used.

The full reverse-engineering notes, including the vendor keys, the binder transaction codes and the watcher design, are in [docs/TECHNICAL.md](docs/TECHNICAL.md).

## Contributing

Issues and pull requests are welcome. Please run `shellcheck` before submitting; the CI runs it on every push and pull request.

## License

[MIT](LICENSE)
