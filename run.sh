#!/usr/bin/env bash
set -e

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENV="$DIR/.venv"

if [ ! -d "$VENV" ]; then
    python3 -m venv "$VENV"
fi

"$VENV/bin/pip" install --upgrade pip --quiet
"$VENV/bin/pip" install --quiet pynput

exec "$VENV/bin/python3" "$DIR/align_row.py"
