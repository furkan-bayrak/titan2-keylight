#!/usr/bin/env bash
# Convenience wrapper: ./install.sh [options]  ==  ./kbled install [options]
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
exec "$HERE/kbled" install "$@"
