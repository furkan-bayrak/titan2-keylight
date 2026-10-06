#!/system/bin/sh
# Start the kbled watcher if it is not already running (pidfile guarded).

PIDFILE=${KBLED_PIDFILE:-/data/local/tmp/kbled_watch.pid}

if [ -f "$PIDFILE" ]; then
  pid=$(cat "$PIDFILE" 2>/dev/null)
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    echo "kbled watcher already running (pid $pid)"
    exit 0
  fi
  rm -f "$PIDFILE"
fi

nohup /system/bin/sh /data/local/tmp/kbled_watch.sh >/dev/null 2>&1 </dev/null &
sleep 1

if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
  echo "kbled watcher started (pid $(cat "$PIDFILE"))"
else
  echo "kbled watcher failed to start" >&2
  exit 1
fi
