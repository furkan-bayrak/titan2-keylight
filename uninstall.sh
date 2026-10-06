#!/usr/bin/env bash
# Convenience wrapper: ./uninstall.sh [options]  ==  ./kbled uninstall [options]
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
exec "$HERE/kbled" uninstall "$@"
