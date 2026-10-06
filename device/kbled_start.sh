#!/system/bin/sh
# Start the kbled watcher if it is not already running (pidfile guarded).

PIDFILE=${KBLED_PIDFILE:-/data/local/tmp/kbled_watch.pid}

# True when $1 is a live process whose command line is the kbled watcher.
# Guards against a stale pidfile and against a pid recycled by another app.
is_watcher() {
  case "$1" in '' | *[!0-9]*) return 1 ;; esac
  kill -0 "$1" 2>/dev/null || return 1
  tr '\0' '\n' < "/proc/$1/cmdline" 2>/dev/null | grep -q kbled_watch
}

if [ -f "$PIDFILE" ]; then
  pid=$(cat "$PIDFILE" 2>/dev/null)
  if is_watcher "$pid"; then
    echo "kbled watcher already running (pid $pid)"
    exit 0
  fi
  rm -f "$PIDFILE"
fi

nohup /system/bin/sh /data/local/tmp/kbled_watch.sh >/dev/null 2>&1 </dev/null &
sleep 1

pid=$(cat "$PIDFILE" 2>/dev/null)
if is_watcher "$pid"; then
  echo "kbled watcher started (pid $pid)"
else
  echo "kbled watcher failed to start" >&2
  exit 1
fi
