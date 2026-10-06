# shellcheck shell=bash
# Shared host-side helpers for the Titan 2 keyboard backlight mod.
# Sourced by ./kbled, ./install.sh and ./uninstall.sh.

# Export the library constants so the scripts that source this file can use
# them without shellcheck flagging them as unused.
export KBLED_VERSION="1.0.0"
export KBLED_BIG_TIMEOUT="2147483647"
export KBLED_DEFAULT_TIMEOUT="30000"
KBLED_REMOTE_DIR="/data/local/tmp"

kb_info() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
kb_ok()   { printf '\033[1;32m  ok\033[0m %s\n' "$*"; }
kb_warn() { printf '\033[1;33mwarn\033[0m %s\n' "$*" >&2; }
kb_err()  { printf '\033[1;31merr \033[0m %s\n' "$*" >&2; }
kb_die()  { printf '\033[1;31merr \033[0m %s\n' "$*" >&2; exit 1; }

# Usage errors exit with 2, the conventional code for a bad command line.
kb_usage_die() {
  printf '\033[1;31merr \033[0m %s\n' "$*" >&2
  printf 'Run kbled --help for usage.\n' >&2
  exit 2
}

kb_have() { command -v "$1" >/dev/null 2>&1; }

kb_require_tools() {
  kb_have adb || kb_die "adb not found in PATH (install Android platform-tools)"
  kb_have awk || kb_die "awk not found in PATH"
}

# Run adb, honouring the selected serial.
kb_adb() {
  if [ -n "${KBLED_SERIAL:-}" ]; then
    command adb -s "$KBLED_SERIAL" "$@"
  else
    command adb "$@"
  fi
}

kb_shell() { kb_adb shell "$@"; }

# Resolve the target device into $KBLED_SERIAL.
kb_find_device() {
  if [ -n "${KBLED_SERIAL:-}" ]; then
    command adb -s "$KBLED_SERIAL" get-state >/dev/null 2>&1 \
      || kb_die "adb device '$KBLED_SERIAL' is not available"
    kb_ok "device: $KBLED_SERIAL"
    return 0
  fi

  local devices count
  devices=$(adb devices | awk 'NR > 1 && $2 == "device" { print $1 }')
  count=$(printf '%s\n' "$devices" | grep -c . || true)

  if [ "$count" -eq 0 ]; then
    kb_die "no authorized adb device found. Connect over USB, or run 'adb pair'/'adb connect' for wireless debugging."
  fi
  if [ "$count" -gt 1 ]; then
    kb_warn "multiple adb devices are connected:"
    printf '     %s\n' "$devices" >&2
    kb_die "select one with --serial <serial>, or set KBLED_SERIAL"
  fi

  KBLED_SERIAL="$devices"
  kb_ok "device: $KBLED_SERIAL"
}

# Decode the UTF-16LE parcel emitted by `service call`.
#   word0 = header, word1 = length (code units), word2.. = code units
kb_decode_parcel() {
  awk '
    {
      line = $0
      q = index(line, "\047")            # cut off the trailing ASCII column
      if (q > 0) line = substr(line, 1, q - 1)
      gsub(/0x[0-9a-fA-F]+:/, "", line)  # drop address prefixes
      n = split(line, tok, /[^0-9a-fA-F]+/)
      for (j = 1; j <= n; j++)
        if (length(tok[j]) == 8) words[++k] = tok[j]
    }
    END {
      if (k < 2) exit
      len = hex(words[2])
      s = ""
      for (i = 1; i <= len; i++) {
        wi = 3 + int((i - 1) / 2)
        w = words[wi]
        if (length(w) != 8) break
        if (i % 2 == 1) c = hex(substr(w, 5, 4))   # low 16 bits
        else            c = hex(substr(w, 1, 4))   # high 16 bits
        s = s sprintf("%c", c)
      }
      printf "%s", s
    }
    function hex(h,   i, c, v, d) {
      v = 0
      h = tolower(h)
      for (i = 1; i <= length(h); i++) {
        c = substr(h, i, 1)
        d = index("0123456789abcdef", c) - 1
        if (d < 0) d = 0
        v = v * 16 + d
      }
      return v
    }
  '
}

# Vendor keys this tool may touch. Anything else is refused before it can
# reach an adb shell command line. keyboard_led_auto_switch is read (and only
# read) by `kbled status`.
KBLED_KNOWN_KEYS="keyboard_brightness_timeout keyboard_brightness_timeout_backup keyboard_led_brightness keyboard_led_auto_switch"

# True when $1 is one of the vendor keys above.
kb_is_known_key() {
  case " $KBLED_KNOWN_KEYS " in
    *" $1 "*) return 0 ;;
  esac
  return 1
}

# Read a vendor key: echo its value (empty on failure).
kb_read_key() {
  kb_is_known_key "$1" || kb_die "refusing to read unknown key '$1'"
  { kb_shell "service call agui_common 3 s16 $1 s16 -1" 2>/dev/null || true; } | kb_decode_parcel
}

# Read the raw LED sysfs value (0-255/0-100 depending on firmware).
kb_read_led() {
  { kb_shell "service call agui_common 2 s16 /sys/devices/platform/keypad_led/keyled_brightness" 2>/dev/null || true; } \
    | kb_decode_parcel
}

# Write a vendor key and verify the read-back.
kb_write_key() {
  local key=$1 val=$2 got out rc=0
  kb_is_known_key "$key" || kb_die "refusing to write unknown key '$key'"
  case "$val" in
    '' | *[!0-9]*) kb_die "refusing to write a non-numeric value for $key: '$val'" ;;
  esac
  out=$(kb_shell "service call agui_common 4 s16 $key s16 $val" 2>&1) || rc=$?
  if [ "$rc" -ne 0 ]; then
    out=$(printf '%s' "$out" | tr '\n' ' ')
    kb_die "failed to write $key (adb exit $rc)${out:+: $out}"
  fi
  got=$(kb_read_key "$key")
  [ "$got" = "$val" ] \
    || kb_die "write verification failed for $key: got '$got', expected '$val'. Your firmware may be unsupported."
}

# Pre-flight checks: vendor service present and the key readable/numeric.
kb_doctor() {
  local services model release t
  services=$(kb_shell "service list" 2>/dev/null | tr -d '\r')
  case "$services" in
    *agui_common*) kb_ok "found agui_common system service" ;;
    *) kb_die "agui_common service not found - this is not a supported Agui device" ;;
  esac

  model=$(kb_shell getprop ro.product.model | tr -d '\r')
  release=$(kb_shell getprop ro.build.version.release | tr -d '\r')
  kb_ok "device: ${model:-unknown} (Android ${release:-?})"

  t=$(kb_read_key keyboard_brightness_timeout)
  case "$t" in
    '' | *[!0-9]*) kb_die "could not read keyboard_brightness_timeout (got '$t')" ;;
    *) kb_ok "keyboard_brightness_timeout = $t" ;;
  esac
}

# Push the device-side scripts to /data/local/tmp.
kb_push_scripts() {
  local root=$1 f
  for f in kbled_watch.sh kbled_start.sh kbled_stop.sh; do
    kb_adb push "$root/device/$f" "$KBLED_REMOTE_DIR/$f" >/dev/null \
      || kb_die "failed to push $f"
  done
  kb_shell "chmod 755 $KBLED_REMOTE_DIR/kbled_watch.sh $KBLED_REMOTE_DIR/kbled_start.sh $KBLED_REMOTE_DIR/kbled_stop.sh"
}

# Watcher PID, or empty if not running. The pid must be numeric and the
# process must really be kbled_watch: a stale pidfile after a reboot, or a
# recycled pid, must never be reported as the watcher.
kb_watcher_pid() {
  local pid probe
  pid=$(kb_shell "cat $KBLED_REMOTE_DIR/kbled_watch.pid 2>/dev/null" | tr -d '\r\n' || true)
  case "$pid" in
    '' | *[!0-9]*) return 0 ;;
  esac
  probe="kill -0 $pid 2>/dev/null && tr '\\0' '\\n' < /proc/$pid/cmdline 2>/dev/null | grep -q kbled_watch"
  if kb_shell "$probe" >/dev/null 2>&1; then
    printf '%s' "$pid"
  fi
}

# Stop the watcher on the device and always report the outcome. Uses the
# pushed stop script when it is there, and falls back to killing the pidfile
# pid when the script is missing or fails, so a stop can never silently leave
# a live watcher behind.
kb_stop_watcher() {
  local pid stopped=0

  if ! kb_shell "[ -x $KBLED_REMOTE_DIR/kbled_stop.sh ]" >/dev/null 2>&1; then
    kb_warn "the on-device stop script is missing; falling back to the pidfile"
  elif kb_shell "$KBLED_REMOTE_DIR/kbled_stop.sh"; then
    stopped=1
  else
    kb_warn "the on-device stop script failed; falling back to the pidfile"
  fi

  if [ "$stopped" -eq 1 ]; then
    return 0
  fi

  pid=$(kb_watcher_pid)
  if [ -z "$pid" ]; then
    kb_ok "no watcher running"
    return 0
  fi

  if kb_shell "kill $pid 2>/dev/null" >/dev/null 2>&1; then
    kb_shell "rm -f $KBLED_REMOTE_DIR/kbled_watch.pid" >/dev/null 2>&1 || true
    kb_ok "watcher stopped (pid $pid)"
  else
    kb_warn "could not stop the watcher (pid $pid); it may still be running"
  fi
}

# Path of the per-device backup file.
kb_backup_file() {
  local safe
  safe=$(printf '%s' "$KBLED_SERIAL" | tr ':. ' '___')
  printf '%s/kbled/backup-%s.env\n' "${XDG_CONFIG_HOME:-$HOME/.config}" "$safe"
}

kb_save_backup() {
  local bf=$1 dir tmp timeout backup brightness

  # Read everything first: never replace a good backup with a half-read one.
  timeout=$(kb_read_key keyboard_brightness_timeout) \
    || kb_die "cannot save a backup: failed to read keyboard_brightness_timeout"
  backup=$(kb_read_key keyboard_brightness_timeout_backup) \
    || kb_die "cannot save a backup: failed to read keyboard_brightness_timeout_backup"
  brightness=$(kb_read_key keyboard_led_brightness) \
    || kb_die "cannot save a backup: failed to read keyboard_led_brightness"
  if [ -z "$timeout" ] || [ -z "$backup" ]; then
    kb_die "cannot save a backup: the device reported no current values"
  fi

  dir=$(dirname "$bf")
  mkdir -p "$dir" 2>/dev/null || true
  [ -d "$dir" ] || kb_die "cannot create the backup directory: $dir"
  chmod 700 "$dir" 2>/dev/null || true

  # Private from the start: mktemp creates the file as 0600, in the same
  # directory so the final mv is atomic and can never leave a truncated
  # backup behind.
  tmp=$(mktemp "$dir/.kbled-backup.XXXXXX") || kb_die "cannot create a temporary file in $dir"

  if ! {
    printf '# kbled backup - generated %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'KBLED_DEVICE=%s\n' "$KBLED_SERIAL"
    printf 'KBLED_TIMEOUT=%s\n' "$timeout"
    printf 'KBLED_BACKUP=%s\n' "$backup"
    printf 'KBLED_BRIGHTNESS=%s\n' "$brightness"
  } >"$tmp"; then
    rm -f "$tmp"
    kb_die "failed to write the new backup file in $dir"
  fi
  chmod 600 "$tmp"

  # Publish only a file that parses back with the values we just captured.
  if ! kb_backup_load "$tmp" || [ -z "$KBLED_BK_TIMEOUT" ] || [ -z "$KBLED_BK_BACKUP" ]; then
    rm -f "$tmp"
    kb_die "the generated backup is incomplete; any previous backup is untouched"
  fi

  if ! mv -f "$tmp" "$bf"; then
    rm -f "$tmp"
    kb_die "failed to install the new backup at $bf"
  fi
}

# Parse a backup file into KBLED_BK_* variables. The file is read as plain
# data: nothing in it is ever evaluated or sourced. Returns non-zero (with a
# message on stderr) on anything that is not a known KEY=VALUE pair with a
# safe value, so a tampered backup can neither run host commands nor inject
# into the phone shell command line.
# parse is a data-only parser; the KBLED_BK_* variables it sets are read by
# the callers in ./kbled, which shellcheck cannot see from here.
# shellcheck disable=SC2034
kb_backup_load() {
  local file=$1 line key val
  KBLED_BK_DEVICE=""
  KBLED_BK_TIMEOUT=""
  KBLED_BK_BACKUP=""
  KBLED_BK_BRIGHTNESS=""

  [ -f "$file" ] || { kb_err "backup: $file does not exist"; return 1; }

  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      '' | '#'*) continue ;;
    esac
    case "$line" in
      *=*) key=${line%%=*}; val=${line#*=} ;;
      *) kb_err "backup: not a KEY=VALUE line in $file: $line"; return 1 ;;
    esac
    case "$key" in
      KBLED_DEVICE | KBLED_TIMEOUT | KBLED_BACKUP | KBLED_BRIGHTNESS) : ;;
      *) kb_err "backup: unknown key '$key' in $file"; return 1 ;;
    esac
    # v1.0.0 wrote values with printf %q, which renders an empty value as ''.
    if [ "$val" = "''" ]; then
      val=""
    fi
    case "$key" in
      KBLED_DEVICE)
        case "$val" in
          *[!A-Za-z0-9._:-]*) kb_err "backup: invalid device serial in $file"; return 1 ;;
        esac
        KBLED_BK_DEVICE=$val
        ;;
      *)
        # An empty value means "was not recorded" (a v1.0.0 backup written
        # while the read failed); the caller falls back to the tool default.
        # Every non-empty value must be plain digits.
        case "$val" in
          *[!0-9]*) kb_err "backup: $key must be a number (got '$val') in $file"; return 1 ;;
        esac
        case "$key" in
          KBLED_TIMEOUT) KBLED_BK_TIMEOUT=$val ;;
          KBLED_BACKUP) KBLED_BK_BACKUP=$val ;;
          KBLED_BRIGHTNESS) KBLED_BK_BRIGHTNESS=$val ;;
        esac
        ;;
    esac
  done <"$file"

  return 0
}
