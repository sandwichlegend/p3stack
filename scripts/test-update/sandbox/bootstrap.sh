#!/usr/bin/env bash
set -euo pipefail
[[ $HOME == /tmp/* ]] || { echo "refusing: HOME=$HOME"; exit 99; }
here=$(cd "$(dirname "$0")/.." && pwd)
python3 -I "$here/safe-home.py" check
fresh_home=$(mktemp -d /tmp/p3stack-bootstrap.XXXXXXXX)
export HOME=$fresh_home
export CLAUDE_CONFIG_DIR=$HOME/.claude CODEX_HOME=$HOME/.codex
export XDG_CONFIG_HOME=$HOME/.config XDG_DATA_HOME=$HOME/.local/share
export XDG_CACHE_HOME=$HOME/.cache XDG_STATE_HOME=$HOME/.local/state
[[ $2 == /tmp/* && ! -e $2 ]] || { echo "refusing: fixture target already exists"; exit 99; }
mkdir "$2"
exec bash "$here/fixtures.sh" "$@"
