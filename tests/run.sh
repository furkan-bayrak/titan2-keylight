#!/usr/bin/env bash
# kbled test suite.
#
#   bash tests/run.sh
#
# No dependencies beyond a POSIX shell, awk and the standard coreutils; no
# network and no device. Every adb call goes to tests/stubs/adb, which answers
# from files under a scratch directory. Run from anywhere.
set -uo pipefail

TESTS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$TESTS_DIR/.." && pwd)
STUB_DIR="$TESTS_DIR/stubs"
FIXTURES="$TESTS_DIR/fixtures"
KBLED="$ROOT/kbled"

# The stub must win over any real adb in PATH, otherwise a test could talk to
# a real phone.
PATH="$STUB_DIR:$PATH"
export PATH

if [ "$(command -v adb)" != "$STUB_DIR/adb" ]; then
  printf 'FATAL: adb in PATH is %s, not the test stub - refusing to run\n' "$(command -v adb)" >&2
  exit 1
fi
if ! command -v awk >/dev/null 2>&1; then
  printf 'FATAL: awk not found in PATH\n' >&2
  exit 1
fi

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/kbled-tests.XXXXXX")
ESC=$(printf '\033')
pass=0
fail=0

# No rm -rf anywhere in this repo: delete the scratch tree bottom-up instead,
# and keep it around when something failed so it can be inspected.
cleanup() {
  if [ "$fail" -gt 0 ]; then
    printf '\nscratch kept for debugging: %s\n' "$TMP_ROOT"
    return 0
  fi
  if [ -n "${TMP_ROOT:-}" ] && [ "$TMP_ROOT" != "/" ] && [ -d "$TMP_ROOT" ]; then
    find "$TMP_ROOT" -depth -delete 2>/dev/null || true
  fi
}
trap cleanup EXIT

# --- helpers available to every case ----------------------------------------

strip_ansi() { sed "s/${ESC}\[[0-9;]*m//g"; }

expect_rc() { # expected actual
  [ "$1" = "$2" ] || {
    printf 'exit status: expected %s, got %s\n' "$1" "$2"
    return 1
  }
}

expect_eq() { # actual expected
  [ "$1" = "$2" ] || {
    printf 'value mismatch:\n  expected: [%s]\n  actual:   [%s]\n' "$2" "$1"
    return 1
  }
}

expect_contains() { # haystack needle
  case "$1" in
    *"$2"*) return 0 ;;
  esac
  printf 'output does not contain [%s]:\n%s\n' "$2" "$1"
  return 1
}

# Run ./kbled: exit status in $RC, output (stdout+stderr, colours stripped) in $OUT.
run_kbled() {
  local raw
  RC=0
  raw=$("$KBLED" "$@" 2>&1) || RC=$?
  OUT=$(printf '%s' "$raw" | strip_ansi)
}

# Run ./kbled with nothing stripped: sanitising is what is under test.
run_kbled_raw() {
  local raw
  RC=0
  raw=$("$KBLED" "$@" 2>&1) || RC=$?
  OUT=$raw
}

# Fail when device output reached the terminal with an ESC byte in it. The
# tool's own colour codes are stripped first, so only unconsumed escapes (the
# injected ones) count.
assert_no_esc() { # text
  local text
  text=$(printf '%s' "$1" | strip_ansi)
  case "$text" in
    *"$(printf '\033')"*)
      printf 'an ESC byte from the device reached the terminal\n'
      return 1
      ;;
  esac
}

# Run the device-side parser or another snippet from lib/common.sh in a plain
# shell: run_sh <script>
run_sh() { # script
  local script=$1
  RC=0
  OUT=$(sh -c "$script" 2>&1) || RC=$?
}

# Run ./kbled with a serial in the environment instead of on the command line.
run_kbled_env() { # serial, args...
  local serial=$1 raw
  shift
  RC=0
  raw=$(KBLED_SERIAL="$serial" "$KBLED" "$@" 2>&1) || RC=$?
  OUT=$(printf '%s' "$raw" | strip_ansi)
}

# Seed the fake device with the values a stock Titan 2 reports.
seed_device() {
  mkdir -p "$FAKE_ADB_STATE/dev"
  printf '5000\n' >"$FAKE_ADB_STATE/key_keyboard_brightness_timeout"
  printf '5000\n' >"$FAKE_ADB_STATE/key_keyboard_brightness_timeout_backup"
  printf '50\n' >"$FAKE_ADB_STATE/key_keyboard_led_brightness"
  printf '1\n' >"$FAKE_ADB_STATE/key_keyboard_led_auto_switch"
  printf '120\n' >"$FAKE_ADB_STATE/led"
}

device_value() { # key
  cat "$FAKE_ADB_STATE/key_$1" 2>/dev/null || true
}

adb_log() { cat "$FAKE_ADB_LOG" 2>/dev/null || true; }

count_matches() { # file pattern
  local n
  n=$(grep -c -- "$2" "$1" 2>/dev/null || true)
  printf '%s' "${n:-0}"
}

backup_path() { # serial
  printf '%s/kbled/backup-%s.env\n' "$XDG_CONFIG_HOME" "$1"
}

write_backup() { # path, lines on stdin
  mkdir -p "$(dirname "$1")"
  cat >"$1"
}

# --- cases ------------------------------------------------------------------

case_stub_fails_loudly() {
  # The fake adb must never answer an unhandled command with success: a test
  # would then pass for the wrong reason.
  RC=0
  OUT=$(adb shell "totally new command" 2>&1) || RC=$?
  [ "$RC" -ne 0 ] || {
    printf 'the stub accepted an unknown shell command\n'
    return 1
  }
  expect_contains "$OUT" "unhandled shell command"

  RC=0
  OUT=$(adb totally-new-subcommand 2>&1) || RC=$?
  [ "$RC" -ne 0 ] || {
    printf 'the stub accepted an unknown subcommand\n'
    return 1
  }
  expect_contains "$OUT" "unhandled command"
}

case_help() {
  run_kbled --help
  expect_rc 0 "$RC"
  expect_contains "$OUT" "Usage: kbled [options] [command]"
  expect_contains "$OUT" "Options for 'install' only:"
  # An empty --serial is a usage error; the help says so.
  expect_contains "$OUT" "--serial must not be empty"
}

case_usage_errors_exit_2() {
  local args
  for args in \
    "bogus-command" \
    "install uninstall" \
    "status --force" \
    "uninstall --brightness 5" \
    "doctor --no-watcher" \
    "version --serial FAKESERIAL" \
    "status --serial=" \
    "--nope" \
    "install --timeout-ms" \
    "install --serial"; do
    # shellcheck disable=SC2086
    run_kbled $args
    expect_rc 2 "$RC" || {
      printf 'arguments [%s] were not rejected\n' "$args"
      return 1
    }
  done
}

case_value_validation() {
  local args
  for args in \
    "install --timeout-ms 0" \
    "install --timeout-ms 2147483648" \
    "install --timeout-ms 99999999999999999999" \
    "install --timeout-ms 1e6" \
    "install --brightness 101" \
    "install --brightness -1" \
    "install --brightness 5.5" \
    "status --serial a/b" \
    "status --serial a b"; do
    # shellcheck disable=SC2086
    run_kbled $args
    expect_rc 2 "$RC" || {
      printf 'arguments [%s] were not rejected\n' "$args"
      return 1
    }
  done

  # Accepted values are normalised before they reach the device.
  seed_device
  run_kbled install --serial FAKESERIAL --no-watcher --timeout-ms 0007 --brightness 000
  expect_rc 0 "$RC"
  expect_contains "$(adb_log)" "s16 keyboard_brightness_timeout s16 7"
  expect_contains "$(adb_log)" "s16 keyboard_led_brightness s16 0"
}

case_install_end_to_end() {
  seed_device
  run_kbled install --serial FAKESERIAL
  expect_rc 0 "$RC"
  expect_contains "$OUT" "found agui_common system service"
  expect_contains "$OUT" "saved current settings to"
  expect_contains "$OUT" "keyboard_brightness_timeout = 2147483647"
  expect_contains "$OUT" "keyboard_brightness_timeout_backup = 2147483647"
  expect_contains "$OUT" "watcher started"
  expect_contains "$(adb_log)" "push $ROOT/device/kbled_watch.sh /data/local/tmp/kbled_watch.sh"

  expect_eq "$(device_value keyboard_brightness_timeout)" "2147483647"
  expect_eq "$(device_value keyboard_brightness_timeout_backup)" "2147483647"
  expect_eq "$(device_value keyboard_led_brightness)" "50"

  # The backup is private, lives in a private directory and holds the values
  # that were on the device when install ran.
  local bf
  bf=$(backup_path FAKESERIAL)
  expect_contains "$(cat "$bf")" "KBLED_DEVICE=FAKESERIAL"
  expect_contains "$(cat "$bf")" "KBLED_TIMEOUT=5000"
  expect_contains "$(cat "$bf")" "KBLED_BACKUP=5000"
  expect_contains "$(cat "$bf")" "KBLED_BRIGHTNESS=50"
  if [ -z "$(find "$bf" -perm 600 -print 2>/dev/null)" ]; then
    printf 'backup is not mode 0600: %s\n' "$(ls -l "$bf")"
    return 1
  fi
  if [ -z "$(find "$(dirname "$bf")" -perm 700 -print 2>/dev/null)" ]; then
    printf 'backup directory is not mode 0700: %s\n' "$(ls -ld "$(dirname "$bf")")"
    return 1
  fi
}

case_backup_reused_and_forced() {
  seed_device
  local bf before
  bf=$(backup_path FAKESERIAL)

  run_kbled install --serial FAKESERIAL
  expect_rc 0 "$RC"
  before=$(cat "$bf")

  # A second install keeps the existing restore point.
  printf '6000\n' >"$FAKE_ADB_STATE/key_keyboard_brightness_timeout"
  run_kbled install --serial FAKESERIAL
  expect_rc 0 "$RC"
  expect_contains "$OUT" "keeping it as the restore point"
  expect_eq "$(cat "$bf")" "$before"

  # --force replaces it with the values currently on the device.
  printf '6000\n' >"$FAKE_ADB_STATE/key_keyboard_brightness_timeout"
  run_kbled install --serial FAKESERIAL --force
  expect_rc 0 "$RC"
  expect_contains "$(cat "$bf")" "KBLED_TIMEOUT=6000"
}

case_backup_path_not_a_file() {
  seed_device
  local bf
  bf=$(backup_path FAKESERIAL)

  # A directory at the backup path would make mv nest the temporary file
  # inside it instead of replacing it. Refuse and leave the directory alone.
  mkdir -p "$bf"
  : >"$bf/keep"

  run_kbled install --serial FAKESERIAL
  expect_rc 1 "$RC"
  expect_contains "$OUT" "is not a regular file"
  [ -d "$bf" ] || {
    printf 'the backup directory is gone\n'
    return 1
  }
  [ -f "$bf/keep" ] || {
    printf 'the backup directory was modified\n'
    return 1
  }
  expect_eq "$(find "$(dirname "$bf")" -name '.kbled-backup.*' -print 2>/dev/null)" ""
  expect_eq "$(count_matches "$FAKE_ADB_LOG" 'agui_common 4')" "0"
}

case_failed_backup_save_keeps_previous() {
  seed_device
  local bf before
  bf=$(backup_path FAKESERIAL)

  run_kbled install --serial FAKESERIAL
  expect_rc 0 "$RC"
  before=$(cat "$bf")

  # Simulate a device that stops answering while a new backup is captured.
  RC=0
  FAKE_ADB_MODE=read-fail bash -c \
    ". '$ROOT/lib/common.sh'; KBLED_SERIAL=FAKESERIAL; kb_save_backup '$bf'" >/dev/null 2>&1 || RC=$?
  expect_rc 1 "$RC"
  expect_eq "$(cat "$bf")" "$before"
  expect_eq "$(find "$(dirname "$bf")" -name '.kbled-backup.*' -print 2>/dev/null)" ""
}

case_backup_failure_after_temp_file() {
  seed_device
  local bf before writes
  bf=$(backup_path FAKESERIAL)

  # A good backup first: the failure below has to leave it untouched.
  run_kbled install --serial FAKESERIAL --no-watcher
  expect_rc 0 "$RC"
  before=$(cat "$bf")
  writes=$(count_matches "$FAKE_ADB_LOG" 'agui_common 4')

  # The device now answers the brightness read with something that cannot be
  # recorded. The temporary file is written first, then the parse-back
  # validation refuses it: this is the failure that happens after mktemp, so
  # it exercises the cleanup path a direct write into $bf would not have.
  printf 'not-a-number\n' >"$FAKE_ADB_STATE/key_keyboard_led_brightness"

  run_kbled install --serial FAKESERIAL --force
  expect_rc 1 "$RC"
  expect_contains "$OUT" "the generated backup is incomplete"
  # The refused value was found in the temporary file, not in the backup.
  expect_contains "$OUT" ".kbled-backup."
  expect_eq "$(cat "$bf")" "$before"
  expect_eq "$(count_matches "$FAKE_ADB_LOG" 'agui_common 4')" "$writes"
  expect_eq "$(find "$(dirname "$bf")" -name '.kbled-backup.*' -print 2>/dev/null)" ""
}

case_backup_injection_rejected() {
  seed_device
  local bf canary
  bf=$(backup_path FAKESERIAL)
  canary="$CASE_DIR/pwned"

  # A tampered backup must never be sourced or fed to a shell.
  write_backup "$bf" <<EOF
KBLED_DEVICE=FAKESERIAL
KBLED_TIMEOUT=5; touch $canary
EOF
  run_kbled uninstall --serial FAKESERIAL
  expect_rc 1 "$RC"
  expect_contains "$OUT" "refusing to restore from an invalid backup file"
  expect_eq "$(count_matches "$FAKE_ADB_LOG" 'agui_common 4')" "0"
  [ ! -f "$canary" ] || {
    printf 'the backup was executed\n'
    return 1
  }

  # Command substitution is just as inert.
  write_backup "$bf" <<EOF
KBLED_DEVICE=FAKESERIAL
KBLED_TIMEOUT=\$(touch $canary)
EOF
  run_kbled uninstall --serial FAKESERIAL
  expect_rc 1 "$RC"
  [ ! -f "$canary" ] || {
    printf 'the backup was executed\n'
    return 1
  }

  # Unknown keys and non-numeric values are refused as well.
  write_backup "$bf" <<'EOF'
KBLED_DEVICE=FAKESERIAL
EVIL=$(reboot)
EOF
  run_kbled uninstall --serial FAKESERIAL
  expect_rc 1 "$RC"

  write_backup "$bf" <<'EOF'
KBLED_DEVICE=FAKESERIAL; reboot
KBLED_TIMEOUT=5000
EOF
  run_kbled uninstall --serial FAKESERIAL
  expect_rc 1 "$RC"
  expect_eq "$(count_matches "$FAKE_ADB_LOG" 'agui_common 4')" "0"
}

case_backup_value_validation() {
  seed_device
  local bf bad
  bf=$(backup_path FAKESERIAL)

  # A backup that records a value out of range is refused before anything
  # reaches the device. 0 is in range - it is the vendor's "disabled" state -
  # and is covered by case_zero_timeout_is_valid.
  for bad in \
    "KBLED_TIMEOUT=9999999999" \
    "KBLED_TIMEOUT=-1" \
    "KBLED_BACKUP=2147483648" \
    "KBLED_BRIGHTNESS=101"; do
    write_backup "$bf" <<EOF
KBLED_DEVICE=FAKESERIAL
$bad
KBLED_BRIGHTNESS=50
EOF
    run_kbled uninstall --serial FAKESERIAL
    expect_rc 1 "$RC" || {
      printf 'backup value [%s] was accepted\n' "$bad"
      return 1
    }
    expect_contains "$OUT" "refusing to restore from an invalid backup file"
  done
  expect_eq "$(count_matches "$FAKE_ADB_LOG" 'agui_common 4')" "0"

  # Leading zeros are normalised before the value reaches the device, so the
  # read-back verification matches.
  seed_device
  write_backup "$bf" <<'EOF'
KBLED_DEVICE=FAKESERIAL
KBLED_TIMEOUT=007
KBLED_BACKUP=0005000
KBLED_BRIGHTNESS=0
EOF
  run_kbled uninstall --serial FAKESERIAL
  expect_rc 0 "$RC"
  expect_eq "$(device_value keyboard_brightness_timeout)" "7"
  expect_eq "$(device_value keyboard_brightness_timeout_backup)" "5000"
  expect_eq "$(device_value keyboard_led_brightness)" "0"
}

case_zero_timeout_is_valid() {
  seed_device
  local bf
  bf=$(backup_path FAKESERIAL)

  # 0 is the vendor's documented "disabled" state, not a broken reading: a
  # device whose light the stock tile switched off must install normally, and
  # the backup must record the 0 as the value to restore.
  printf '0\n' >"$FAKE_ADB_STATE/key_keyboard_brightness_timeout"
  run_kbled install --serial FAKESERIAL --no-watcher
  expect_rc 0 "$RC"
  expect_contains "$OUT" "saved current settings to"
  expect_contains "$(cat "$bf")" "KBLED_TIMEOUT=0"

  # The same 0 is a valid restore point, so a backup holding it (a legacy or
  # hand-written one included) is applied instead of making uninstall refuse.
  seed_device
  write_backup "$bf" <<'EOF'
KBLED_DEVICE=FAKESERIAL
KBLED_TIMEOUT=0
KBLED_BACKUP=0
KBLED_BRIGHTNESS=30
EOF
  run_kbled uninstall --serial FAKESERIAL
  expect_rc 0 "$RC"
  expect_contains "$OUT" "restored original settings from"
  expect_eq "$(device_value keyboard_brightness_timeout)" "0"
  expect_eq "$(device_value keyboard_brightness_timeout_backup)" "0"
  expect_eq "$(device_value keyboard_led_brightness)" "30"
}

case_backup_round_trip() {
  seed_device
  run_kbled install --serial FAKESERIAL --timeout-ms 6000 --brightness 42
  expect_rc 0 "$RC"
  expect_eq "$(device_value keyboard_brightness_timeout)" "6000"
  expect_eq "$(device_value keyboard_brightness_timeout_backup)" "6000"
  expect_eq "$(device_value keyboard_led_brightness)" "42"

  run_kbled uninstall --serial FAKESERIAL
  expect_rc 0 "$RC"
  expect_contains "$OUT" "restored original settings from"
  expect_eq "$(device_value keyboard_brightness_timeout)" "5000"
  expect_eq "$(device_value keyboard_brightness_timeout_backup)" "5000"
  expect_eq "$(device_value keyboard_led_brightness)" "50"
  expect_contains "$(adb_log)" "rm -f /data/local/tmp/kbled_watch.sh"
}

case_legacy_and_missing_backup() {
  seed_device
  local bf
  bf=$(backup_path FAKESERIAL)

  # v1.0.0 wrote values with printf %q, so an unread value was stored as ''.
  write_backup "$bf" <<'EOF'
KBLED_DEVICE=FAKESERIAL
KBLED_TIMEOUT=5000
KBLED_BACKUP=''
KBLED_BRIGHTNESS=''
EOF
  run_kbled uninstall --serial FAKESERIAL
  expect_rc 0 "$RC"
  expect_eq "$(device_value keyboard_brightness_timeout)" "5000"
  expect_eq "$(device_value keyboard_brightness_timeout_backup)" "30000"

  # Without a backup the tool must say what it writes and warn about it.
  seed_device
  rm -f "$bf"
  run_kbled uninstall --serial FAKESERIAL
  expect_rc 0 "$RC"
  expect_contains "$OUT" "no backup found"
  expect_contains "$OUT" "not a guaranteed restore of the stock value (the vendor default is 5000 ms)"
  expect_eq "$(device_value keyboard_brightness_timeout)" "30000"

  # A backup that records neither value is not a restore point: the tool must
  # not claim it restored something it did not.
  seed_device
  write_backup "$bf" <<'EOF'
KBLED_DEVICE=FAKESERIAL
KBLED_TIMEOUT=''
KBLED_BACKUP=''
KBLED_BRIGHTNESS=''
EOF
  run_kbled uninstall --serial FAKESERIAL
  expect_rc 0 "$RC"
  expect_contains "$OUT" "nothing to restore"
  case "$OUT" in
    *"restored original settings"*)
      printf 'an empty backup was reported as a restore\n'
      return 1
      ;;
  esac
  expect_eq "$(device_value keyboard_brightness_timeout)" "30000"

  # The same for a zero-byte backup file.
  seed_device
  : >"$bf"
  run_kbled uninstall --serial FAKESERIAL
  expect_rc 0 "$RC"
  expect_contains "$OUT" "nothing to restore"
  case "$OUT" in
    *"restored original settings"*)
      printf 'an empty backup was reported as a restore\n'
      return 1
      ;;
  esac
}

case_parcel_decoder() {
  local out
  out=$(
    # shellcheck source=../lib/common.sh
    . "$ROOT/lib/common.sh"
    kb_decode_parcel <"$FIXTURES/parcel-timeout-100.txt"
  )
  expect_eq "$out" "100"

  out=$(
    . "$ROOT/lib/common.sh"
    kb_decode_parcel <"$FIXTURES/parcel-timeout-5000.txt"
  )
  expect_eq "$out" "5000"

  # A reply that is not a parcel is a failure, not an empty value.
  run_sh ". '$ROOT/lib/common.sh'
    out=\$(printf 'error: device offline\n' | kb_decode_parcel); rc=\$?
    printf 'rc=%s out=[%s]\n' \"\$rc\" \"\$out\""
  expect_contains "$OUT" "rc=1 out=[]"
}

case_device_is_off_parser() {
  # The device script parses the same parcel with toybox tools. Run its own
  # is_off() against recorded replies, with service replaced by a stub.
  local is_off
  is_off=$(awk '/^is_off\(\) \{/,/^\}/' "$ROOT/device/kbled_watch.sh")
  expect_contains "$is_off" "keyboard_brightness_timeout"

  cat >"$CASE_DIR/service" <<'EOF'
#!/bin/sh
cat "$FAKE_SERVICE_REPLY"
EOF
  chmod 755 "$CASE_DIR/service"

  RC=0
  OUT=$(FAKE_SERVICE_REPLY="$FIXTURES/parcel-timeout-0.txt" KBLED_SERVICE="$CASE_DIR/service" \
    sh -c "$is_off
      if is_off; then echo off; else echo on; fi" 2>&1) || RC=$?
  expect_rc 0 "$RC"
  expect_eq "$OUT" "off"

  RC=0
  OUT=$(FAKE_SERVICE_REPLY="$FIXTURES/parcel-timeout-5000.txt" KBLED_SERVICE="$CASE_DIR/service" \
    sh -c "$is_off
      if is_off; then echo off; else echo on; fi" 2>&1) || RC=$?
  expect_rc 0 "$RC"
  expect_eq "$OUT" "on"

  # A parcel that is not the timeout at all is never treated as "off".
  OUT=$(FAKE_SERVICE_REPLY="$FIXTURES/parcel-timeout-100.txt" KBLED_SERVICE="$CASE_DIR/service" \
    sh -c "$is_off
      if is_off; then echo off; else echo on; fi" 2>&1) || RC=$?
  expect_eq "$OUT" "on"
}

case_device_is_watcher() {
  local is_watcher watcher_pid other_pid dead_pid n

  if [ ! -r "/proc/$$/cmdline" ]; then
    printf 'skipped: this host has no /proc\n'
    return 0
  fi

  # The device scripts use the same liveness + cmdline check as the host. Run
  # their is_watcher() against real local processes: a pid only counts as the
  # watcher when its command line says so.
  is_watcher=$(awk '/^is_watcher\(\) \{/,/^\}/' "$ROOT/device/kbled_stop.sh")
  expect_contains "$is_watcher" "/proc/"
  expect_contains "$is_watcher" "grep -q kbled_watch"

  cat >"$CASE_DIR/kbled_watch.sh" <<'EOF'
#!/bin/sh
n=0
while [ "$n" -lt 30 ]; do
  sleep 1
  n=$((n + 1))
done
EOF
  cat >"$CASE_DIR/other_process.sh" <<'EOF'
#!/bin/sh
n=0
while [ "$n" -lt 30 ]; do
  sleep 1
  n=$((n + 1))
done
EOF
  chmod 755 "$CASE_DIR/kbled_watch.sh" "$CASE_DIR/other_process.sh"

  sh "$CASE_DIR/kbled_watch.sh" &
  watcher_pid=$!
  sh "$CASE_DIR/other_process.sh" &
  other_pid=$!
  sh -c 'exit 0' &
  dead_pid=$!
  wait "$dead_pid" 2>/dev/null || true

  # Wait for the stand-in watcher's cmdline to become visible in /proc.
  n=0
  while [ "$n" -lt 50 ] && ! tr '\0' '\n' <"/proc/$watcher_pid/cmdline" 2>/dev/null | grep -q kbled_watch; do
    sleep 0.05
    n=$((n + 1))
  done

  RC=0
  OUT=$(sh -c "$is_watcher
    check() {
      if is_watcher \"\$1\"; then printf '%s=yes\\n' \"\$1\"; else printf '%s=no\\n' \"\$1\"; fi
    }
    check $watcher_pid
    check $other_pid
    check $dead_pid
    check 999999999
    check 12x
    check ''" 2>&1) || RC=$?

  kill "$watcher_pid" "$other_pid" 2>/dev/null || true
  wait "$watcher_pid" "$other_pid" 2>/dev/null || true

  expect_rc 0 "$RC"
  expect_contains "$OUT" "$watcher_pid=yes"
  expect_contains "$OUT" "$other_pid=no"
  expect_contains "$OUT" "$dead_pid=no"
  expect_contains "$OUT" "999999999=no"
  expect_contains "$OUT" "12x=no"
  expect_contains "$OUT" "=no"
}

case_device_stop_script() {
  local pid

  if [ ! -r "/proc/$$/cmdline" ]; then
    printf 'skipped: this host has no /proc\n'
    return 0
  fi

  # A stand-in watcher that stops on SIGTERM: the pidfile goes away and the
  # script exits 0.
  cat >"$CASE_DIR/kbled_watch.sh" <<'EOF'
#!/bin/sh
while :; do sleep 1; done
EOF
  chmod 755 "$CASE_DIR/kbled_watch.sh"
  sh "$CASE_DIR/kbled_watch.sh" &
  pid=$!
  printf '%s\n' "$pid" >"$CASE_DIR/pidfile"

  RC=0
  OUT=$(KBLED_PIDFILE="$CASE_DIR/pidfile" sh "$ROOT/device/kbled_stop.sh" 2>&1) || RC=$?
  wait "$pid" 2>/dev/null || true
  expect_rc 0 "$RC"
  expect_contains "$OUT" "kbled watcher stopped (pid $pid)"
  [ ! -f "$CASE_DIR/pidfile" ] || {
    printf 'the pidfile was kept after a clean stop\n'
    return 1
  }

  # A stand-in watcher that ignores SIGTERM: the script must say the process
  # survived, keep the pidfile and exit non-zero instead of pretending.
  cat >"$CASE_DIR/kbled_watch_survivor.sh" <<'EOF'
#!/bin/sh
trap '' TERM
while :; do sleep 1; done
EOF
  chmod 755 "$CASE_DIR/kbled_watch_survivor.sh"
  sh "$CASE_DIR/kbled_watch_survivor.sh" &
  pid=$!
  printf '%s\n' "$pid" >"$CASE_DIR/pidfile"

  RC=0
  OUT=$(KBLED_PIDFILE="$CASE_DIR/pidfile" sh "$ROOT/device/kbled_stop.sh" 2>&1) || RC=$?
  kill -9 "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  expect_rc 1 "$RC"
  expect_contains "$OUT" "did not stop"
  [ -f "$CASE_DIR/pidfile" ] || {
    printf 'the pidfile was removed although the watcher survived\n'
    return 1
  }
}

case_recycled_pid_guard() {
  seed_device
  local bf
  bf="$FAKE_ADB_STATE/dev/kbled_watch.pid"

  # The pidfile pid is alive, but its command line belongs to another process:
  # a recycled pid must never be reported as the watcher, and must never be
  # killed.
  printf '4242\n' >"$bf"
  : >"$FAKE_ADB_STATE/watcher_live"
  printf '/system/bin/sh\0/data/local/tmp/other_script.sh\0' >"$FAKE_ADB_STATE/watcher_cmdline"

  run_kbled status --serial FAKESERIAL
  expect_rc 0 "$RC"
  expect_contains "$OUT" "$(printf '%-36s %s' watcher 'not running')"

  run_kbled stop --serial FAKESERIAL
  expect_rc 0 "$RC"
  expect_contains "$OUT" "no watcher running"
  expect_eq "$(count_matches "$FAKE_ADB_LOG" 'kill 4242')" "0"

  # The same live pid is the watcher once its cmdline says so.
  printf '/system/bin/sh\0/data/local/tmp/kbled_watch.sh\0' >"$FAKE_ADB_STATE/watcher_cmdline"
  run_kbled status --serial FAKESERIAL
  expect_rc 0 "$RC"
  expect_contains "$OUT" "$(printf '%-36s %s' watcher 'running (pid 4242)')"
}

case_watcher_status_and_stop() {
  seed_device
  run_kbled install --serial FAKESERIAL
  expect_rc 0 "$RC"

  run_kbled status --serial FAKESERIAL
  expect_rc 0 "$RC"
  expect_contains "$OUT" "$(printf '%-36s %s' watcher 'running (pid 4242)')"

  # Without the on-device stop script the pidfile has to be used instead.
  rm -f "$FAKE_ADB_STATE/dev/kbled_stop.sh"
  run_kbled stop --serial FAKESERIAL
  expect_rc 0 "$RC"
  expect_contains "$OUT" "falling back to the pidfile"
  expect_contains "$OUT" "watcher stopped (pid 4242)"

  run_kbled status --serial FAKESERIAL
  expect_contains "$OUT" "not running"

  # A stale pidfile whose pid belongs to something else is not the watcher.
  printf '4242\n' >"$FAKE_ADB_STATE/dev/kbled_watch.pid"
  rm -f "$FAKE_ADB_STATE/watcher_live"
  run_kbled status --serial FAKESERIAL
  expect_contains "$OUT" "not running"

  # Garbage in the pidfile never reaches the device shell.
  printf '4242; touch %s\n' "$CASE_DIR/pwned" >"$FAKE_ADB_STATE/dev/kbled_watch.pid"
  run_kbled status --serial FAKESERIAL
  expect_contains "$OUT" "not running"
  run_kbled stop --serial FAKESERIAL
  expect_contains "$OUT" "no watcher running"
  [ ! -f "$CASE_DIR/pwned" ] || {
    printf 'the pidfile content was executed\n'
    return 1
  }
  expect_eq "$(count_matches "$FAKE_ADB_LOG" '4242; touch')" "0"
}

case_device_output_sanitised() {
  seed_device
  export FAKE_ADB_MODE=control-chars

  # status prints decoded device values; one of them carries an ESC byte.
  run_kbled_raw status --serial FAKESERIAL
  expect_rc 0 "$RC"
  assert_no_esc "$OUT"
  expect_contains "$OUT" "keyboard_brightness_timeout"
  expect_contains "$OUT" "AB"

  # doctor quotes the device value that failed the numeric check.
  run_kbled_raw doctor --serial FAKESERIAL
  expect_rc 1 "$RC"
  assert_no_esc "$OUT"
  expect_contains "$OUT" "is not a number"

  # The model and release lines printed by doctor are device strings too.
  export FAKE_ADB_MODE=getprop-chars
  run_kbled_raw doctor --serial FAKESERIAL
  expect_rc 0 "$RC"
  assert_no_esc "$OUT"
  expect_contains "$OUT" "Titan_2 (Android 16)"

  # A failed read and a failed write echo the adb output in their message.
  export FAKE_ADB_MODE=read-fail
  run_kbled_raw status --serial FAKESERIAL
  assert_no_esc "$OUT"

  export FAKE_ADB_MODE=write-fail
  run_kbled_raw install --serial FAKESERIAL --force
  expect_rc 1 "$RC"
  assert_no_esc "$OUT"
}

case_error_reporting() {
  seed_device

  export FAKE_ADB_MODE=write-fail
  run_kbled install --serial FAKESERIAL
  expect_rc 1 "$RC"
  expect_contains "$OUT" "failed to write keyboard_brightness_timeout"

  export FAKE_ADB_MODE=verify-fail
  run_kbled install --serial FAKESERIAL --force
  expect_rc 1 "$RC"
  expect_contains "$OUT" "write verification failed for keyboard_brightness_timeout: got '999'"

  export FAKE_ADB_MODE=read-fail
  run_kbled status --serial FAKESERIAL
  expect_rc 0 "$RC"
  expect_contains "$OUT" "$(printf '%-36s %s' keyboard_brightness_timeout 'unavailable (read failed)')"

  export FAKE_ADB_MODE=push-fail
  run_kbled install --serial FAKESERIAL --force
  expect_rc 1 "$RC"
  expect_contains "$OUT" "failed to push kbled_watch.sh"

  export FAKE_ADB_MODE=ok
}

case_doctor() {
  seed_device
  run_kbled doctor --serial FAKESERIAL
  expect_rc 0 "$RC"
  expect_contains "$OUT" "found agui_common system service"
  expect_contains "$OUT" "Titan_2 (Android 16)"
  expect_contains "$OUT" "keyboard_brightness_timeout = 5000"

  # An adb failure during the pre-flight checks is reported, not swallowed.
  export FAKE_ADB_MODE=service-list-fail
  run_kbled doctor --serial FAKESERIAL
  expect_rc 1 "$RC"
  expect_contains "$OUT" "could not list the phone's system services"
  expect_contains "$OUT" "device offline"

  export FAKE_ADB_MODE=getprop-fail
  run_kbled doctor --serial FAKESERIAL
  expect_rc 1 "$RC"
  expect_contains "$OUT" "could not read ro.product.model"
}

case_serial_selection() {
  seed_device

  # --serial wins over the environment, and a bad serial is refused before
  # anything is written.
  run_kbled_env ENVSERIAL status
  expect_rc 0 "$RC"
  expect_contains "$OUT" "device: ENVSERIAL"

  run_kbled_env 'bad serial' status
  expect_rc 2 "$RC"

  # An explicitly empty --serial is a usage error, not a request to detect.
  run_kbled status --serial ''
  expect_rc 2 "$RC"
  expect_contains "$OUT" "--serial requires a non-empty value"

  # An empty or unset KBLED_SERIAL still means auto-detect.
  seed_device
  run_kbled_env '' status
  expect_rc 0 "$RC"
  expect_contains "$OUT" "device: FAKESERIAL"

  run_kbled status --serial 'x;id'
  expect_rc 2 "$RC"
  expect_eq "$(count_matches "$FAKE_ADB_LOG" 'x;id')" "0"
}

# --- runner -----------------------------------------------------------------

it() { # case_function
  local name=$1 dir rc
  dir="$TMP_ROOT/$name"
  mkdir -p "$dir"
  printf '  %-38s ' "$name"

  # Deliberately not wrapped in `if (...)`: a subshell whose status is tested
  # runs with `set -e` suspended, which would let failing assertions pass.
  (
    set -e
    cd "$ROOT"
    CASE_DIR="$dir"
    FAKE_ADB_STATE="$dir/state"
    FAKE_ADB_LOG="$dir/adb.log"
    XDG_CONFIG_HOME="$dir/config"
    export CASE_DIR FAKE_ADB_STATE FAKE_ADB_LOG XDG_CONFIG_HOME
    : >"$FAKE_ADB_LOG"
    "$name"
  ) >"$dir/case.out" 2>&1
  rc=$?

  if [ "$rc" -eq 0 ]; then
    pass=$((pass + 1))
    printf 'PASS\n'
  else
    fail=$((fail + 1))
    printf 'FAIL (exit %s)\n' "$rc"
    sed 's/^/      /' "$dir/case.out" >&2
  fi
}

# A case that always fails, used below to prove the runner reports failures.
case_harness_self_check() { return 1; }

printf 'kbled tests (%s)\n\n' "$ROOT"

# Self-check before anything else: a failing case has to be reported as a
# failure, otherwise a green run would prove nothing.
it case_harness_self_check >/dev/null 2>&1
if [ "$fail" -ne 1 ]; then
  printf 'FATAL: the test runner did not report a failing case\n' >&2
  exit 1
fi
pass=0
fail=0

for c in \
  case_stub_fails_loudly \
  case_help \
  case_usage_errors_exit_2 \
  case_value_validation \
  case_install_end_to_end \
  case_backup_reused_and_forced \
  case_backup_path_not_a_file \
  case_failed_backup_save_keeps_previous \
  case_backup_failure_after_temp_file \
  case_backup_injection_rejected \
  case_backup_value_validation \
  case_zero_timeout_is_valid \
  case_backup_round_trip \
  case_legacy_and_missing_backup \
  case_parcel_decoder \
  case_device_is_off_parser \
  case_device_is_watcher \
  case_recycled_pid_guard \
  case_device_stop_script \
  case_watcher_status_and_stop \
  case_device_output_sanitised \
  case_error_reporting \
  case_doctor \
  case_serial_selection; do
  it "$c"
done

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
