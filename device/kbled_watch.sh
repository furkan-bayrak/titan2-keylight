#!/system/bin/sh
# kbled_watch.sh - make the Quick Settings "keyboard_led" toggle turn the
# keyboard backlight off immediately.
#
# Why this exists: the stock tile only writes keyboard_brightness_timeout="0".
# The Agui KeyboardLightController updates its cached timeout but does not
# power the LED off at that moment. With a very large timeout (the always-on
# mod) the LED would otherwise stay lit until the next screen off/on cycle.
#
# This watcher polls the vendor key/value store through the agui_common binder
# service and, on the transition to "0", sends the CLOSE_KEYBOARD_LIGHT
# broadcast handled by KeyboardLightController. Polling is used because SELinux
# blocks inotify/FileObserver for a shell (non-root) UID.
#
# It is intentionally dependency-free (only /system/bin/sh + toybox tools).

KBLED_PIDFILE=${KBLED_PIDFILE:-/data/local/tmp/kbled_watch.pid}
KBLED_INTERVAL=${KBLED_INTERVAL:-2}
# Overridable so the parser below can be exercised off-device by the tests.
KBLED_SERVICE=${KBLED_SERVICE:-/system/bin/service}
KBLED_AM=${KBLED_AM:-/system/bin/am}

# Refuse to run twice: if the pidfile points at a live watcher, exit instead
# of starting a second poller. Covers a direct run of this script next to an
# already running watcher.
if [ -f "$KBLED_PIDFILE" ]; then
  oldpid=$(cat "$KBLED_PIDFILE" 2>/dev/null)
  case "$oldpid" in
    '' | *[!0-9]*) : ;;
    *)
      if [ "$oldpid" -ne "$$" ] && kill -0 "$oldpid" 2>/dev/null &&
        tr '\0' '\n' < "/proc/$oldpid/cmdline" 2>/dev/null | grep -q kbled_watch; then
        echo "kbled watcher already running (pid $oldpid)" >&2
        exit 0
      fi
      ;;
  esac
fi

echo $$ > "$KBLED_PIDFILE"
trap 'rm -f "$KBLED_PIDFILE"' EXIT

# Decode the UTF-16LE parcel returned by `service call` and return success if
# the stored timeout is exactly "0".  Parcel layout produced by the service:
#   word0 = header (0)
#   word1 = string length (UTF-16 code units)
#   word2.. = one or two code units per 32-bit little-endian word
is_off() {
  out=$("$KBLED_SERVICE" call agui_common 3 s16 keyboard_brightness_timeout s16 -1 2>/dev/null)
  # drop the "0x00000000:" address prefixes, keep 8-hex words only
  words=$(printf '%s\n' "$out" | sed 's/0x[0-9a-fA-F]*://g' | grep -oE '[0-9a-fA-F]{8}')
  n=$(printf '%s\n' "$words" | sed -n '2p')
  [ -z "$n" ] && return 1
  [ "$((0x$n))" -eq 1 ] || return 1
  w=$(printf '%s\n' "$words" | sed -n '3p')
  [ -z "$w" ] && return 1
  # low 16 bits of the word; 0x30 == ASCII '0'
  [ "$(( 0x$w & 0xffff ))" -eq 48 ]
}

prev=1
while true; do
  if is_off; then v=0; else v=1; fi
  if [ "$v" -eq 0 ] && [ "$prev" -ne 0 ]; then
    "$KBLED_AM" broadcast -a agui.action.CLOSE_KEYBOARD_LIGHT >/dev/null 2>&1
  fi
  prev=$v
  sleep "$KBLED_INTERVAL"
done
