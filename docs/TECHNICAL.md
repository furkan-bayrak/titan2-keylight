# Technical notes

How the Titan 2 / Titan 2 Elite keyboard backlight works and how this tool drives
it without root. Everything below was derived from a Unihertz Titan 2
(`Titan_2`, Android 16) over ADB. No vendor code is redistributed here; the notes
describe interfaces only.

## 1. The vendor keyboard stack

The backlight is not controlled through the standard Android `Settings`
provider. It lives in an Agui (Unihertz) vendor stack:

| Component | Location |
|---|---|
| Key/value store | `/data/system/agui_settings_data.xml` (SharedPreferences, `system:system`, mode `0600`) |
| Enforcer service | `com.agui.server.functional.KeyboardLightController` (runs inside `system_server`) |
| LED sysfs node | `/sys/devices/platform/keypad_led/keyled_brightness` |
| Binder service | `agui_common` = `com.agui.ext.common.IACommonService` |
| QS tile | `com.agui.systemui.qs.KeyboardLEDTile` (tile spec `keyboard_led`) |
| Settings activity | `com.agui.settings/.touchpad.KeyboardLEDSettingsActivity` |

### Vendor keys

| Key | Meaning | Default |
|---|---|---|
| `keyboard_brightness_timeout` | ms the light stays on after the last key; `"0"` = disabled | `5000` |
| `keyboard_brightness_timeout_backup` | value the QS tile restores when switching on | `5000` |
| `keyboard_led_brightness` | LED brightness | `50` |
| `keyboard_led_auto_switch` | auto-adjust flag (not used by the light path) | `-1` |

### KeyboardLightController behaviour

- Watches `/data/system/agui_settings_data.xml` with a `FileObserver`
  (reacts to `MODIFY`) and re-reads `keyboard_led_auto_switch`,
  `keyboard_brightness_timeout` and `keyboard_led_brightness`.
- On `SCREEN_ON`: turns the LED on.
- On `SCREEN_OFF`, shutdown, or the broadcast
  `agui.action.CLOSE_KEYBOARD_LIGHT`: forces the LED off.
- After a key press it starts a `Timer` of
  `keyboard_brightness_timeout` ms and then dims the LED to `0`.

Because the timeout is parsed with `Integer.parseInt`, the maximum usable value
is `2147483647` ms, which is effectively "never during a session". The screen-off
path still turns the light off regardless of the timeout.

## 2. Reading and writing the store without root

The store is `0600 system:system` and the device is not debuggable
(`adb root` is refused), so a normal shell cannot read or write the file. The
vendor `agui_common` binder service exposes file/key helpers that the Settings UI
uses. Its AIDL surface (transaction codes observed from the stub) is:

| Code | Method | Arguments |
|---|---|---|
| 1 | `writeFile` | path, data |
| 2 | `readStringFromFile` | path → text |
| 3 | `getStringFromFile` | key, default → value |
| 4 | `putStringToFile` | key, value |

From a shell:

```sh
# read a vendor key
service call agui_common 3 s16 keyboard_brightness_timeout s16 -1

# write a vendor key
service call agui_common 4 s16 keyboard_brightness_timeout s16 2147483647

# read the LED node (read-only observation)
service call agui_common 2 s16 /sys/devices/platform/keypad_led/keyled_brightness
```

### Parcel format

`service call` prints a `Parcel` hex dump. The values are UTF-16LE strings laid
out as 32-bit little-endian words:

```
word0 = header (0)
word1 = string length, in UTF-16 code units
word2.. = code units, two per word (low 16 bits first, then high 16 bits)
```

Example, `keyboard_brightness_timeout = 100`:

```
Result: Parcel(  00000000 00000003 00300031 00000030  '........1.0.0...')
```

- length `3`
- word `00300031` → low16 `0x0031` = `'1'`, high16 `0x0030` = `'0'`
- word `00000030` → low16 `0x0030` = `'0'`
- result: `"100"`

`lib/common.sh` decodes this with POSIX `awk` only.

## 3. The Quick Settings tile quirk

`KeyboardLEDTile.handleClick` toggles `keyboard_brightness_timeout`:

- currently on → writes `"0"`
- currently off → writes the `keyboard_brightness_timeout_backup` value

When the value becomes `"0"` the controller's `FileObserver` updates its cached
timeout but **does not** power the LED off at that moment (the "on sync" is only
posted for non-zero values). With the vendor's 5 s default this is barely
noticeable, but with the always-on timeout the light would stay lit until the
next screen off/on.

### The watcher

`device/kbled_watch.sh` polls the timeout every 2 s through `agui_common` and, on
the transition to `"0"`, sends:

```sh
am broadcast -a agui.action.CLOSE_KEYBOARD_LIGHT
```

which the controller handles by turning the LED off immediately.

Polling is used deliberately: `inotifyd` and `FileObserver` are blocked for a
shell UID by SELinux, and the store is not readable/writable by the shell, so
there is no event source available without root. The watcher costs one small
binder call every two seconds and uses only toybox tools.

The watcher is pidfile-guarded (`/data/local/tmp/kbled_watch.pid`) and is started
with `nohup` so it survives the adb session that launched it.

## 4. Why not just set `timeout=0`?

`timeout=0` is the vendor "disabled" state. The controller sets
`mCurrentBrightness = "0"`, so it never turns the LED on. That is the correct
"off" state, but it cannot be used for the always-on state, which is why the mod
uses a huge timeout plus an explicit off broadcast.

## 5. Binder services present on the device

`service list` shows the Agui binder services, none of which implement a shell
command (`cmd ...` says "No shell command implementation"):

- `agui_common` — `com.agui.ext.common.IACommonService` (file/key helpers)
- `agui_functional_service` — `com.agui.server.functional.IAguiFunctional`
  (`keyboardLightTest(String)` at transaction code 7 writes a raw value to the
  LED node; used during reverse engineering)
- `agui_daemon` — `IADaemonService`

## 6. Reboot behaviour

The store values persist in `/data/system`, so the always-on behaviour survives a
reboot. The watcher is a normal process and does not, so run `./kbled start`
after rebooting. Automating that without root requires a boot app such as
Termux:Boot.

## 7. Re-deriving transaction codes

If a firmware update changes `agui_common`, the transaction codes above may move.
`kbled` guards against this by reading the value back after every write and
aborting if it does not match. To re-derive the codes, decompile
`com.agui.ext.common.IACommonService` from the vendor framework and read the
`onTransact` switch, or probe with `service call agui_common <code> ...`.
