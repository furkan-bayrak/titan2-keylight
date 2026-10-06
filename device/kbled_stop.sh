#!/system/bin/sh
# Stop the kbled watcher.

PIDFILE=${KBLED_PIDFILE:-/data/local/tmp/kbled_watch.pid}

# True when $1 is a live process whose command line is the kbled watcher.
# Never kills a pid that was recycled by an unrelated process.
is_watcher() {
  case "$1" in '' | *[!0-9]*) return 1 ;; esac
  kill -0 "$1" 2>/dev/null || return 1
  tr '\0' '\n' < "/proc/$1/cmdline" 2>/dev/null | grep -q kbled_watch
}

if [ -f "$PIDFILE" ]; then
  pid=$(cat "$PIDFILE" 2>/dev/null)
  if is_watcher "$pid"; then
    kill "$pid" 2>/dev/null
    rm -f "$PIDFILE"
    echo "kbled watcher stopped (pid $pid)"
    exit 0
  fi
  rm -f "$PIDFILE"
fi

echo "kbled watcher not running"
