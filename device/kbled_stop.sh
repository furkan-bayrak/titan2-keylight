#!/system/bin/sh
# Stop the kbled watcher.

PIDFILE=${KBLED_PIDFILE:-/data/local/tmp/kbled_watch.pid}

if [ -f "$PIDFILE" ]; then
  pid=$(cat "$PIDFILE" 2>/dev/null)
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null
    rm -f "$PIDFILE"
    echo "kbled watcher stopped (pid $pid)"
    exit 0
  fi
  rm -f "$PIDFILE"
fi

echo "kbled watcher not running"
