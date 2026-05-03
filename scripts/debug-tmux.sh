#!/usr/bin/env bash
#
# Launch a local GFS debug cluster in a tmux session with 4 panes:
#   pane 0: manager  (sname: fatemah)
#   pane 1: chunkserver (sname: bob)
#   pane 2: chunkserver (sname: charlie)
#   pane 3: chunkserver (sname: david)
#
# Each node runs in its own iex session with a distinct SQLite DB so the
# chunkservers don't clobber each other.
#
# Usage:
#   scripts/debug-tmux.sh           # start (or restart) the debug session
#   scripts/debug-tmux.sh stop      # kill the debug session
#   GFS_CLEAN=1 scripts/debug-tmux.sh   # wipe debug DBs before starting
#
# Env overrides:
#   GFS_SESSION   tmux session name      (default: gfs-debug)
#   GFS_COOKIE    Erlang distribution cookie (default: gfsdev)
#   GFS_DB_ROOT   directory for per-node SQLite files
#                                       (default: ~/.gfs/database/debug)

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SESSION="${GFS_SESSION:-gfs-debug}"
COOKIE="${GFS_COOKIE:-gfsdev}"
DB_ROOT="${GFS_DB_ROOT:-$HOME/.gfs/database/debug}"

# Erlang's `--sname fatemah` registers as fatemah@<short-hostname>, so each
# chunkserver needs the manager's full short-name to dial in.
HOST_SHORT="$(hostname -s)"
MANAGER_NODE="fatemah@$HOST_SHORT"

if [[ "${1:-}" == "stop" ]]; then
  tmux kill-session -t "$SESSION" 2>/dev/null || true
  echo "Stopped tmux session: $SESSION"
  exit 0
fi

if ! command -v tmux >/dev/null 2>&1; then
  echo "tmux is not installed. Install it (e.g. brew install tmux) and retry." >&2
  exit 1
fi

if [[ "${GFS_CLEAN:-0}" == "1" ]]; then
  echo "Cleaning debug DBs in $DB_ROOT"
  rm -rf "$DB_ROOT"
fi
mkdir -p "$DB_ROOT"

# Always start fresh so reruns don't stack panes.
tmux has-session -t "$SESSION" 2>/dev/null && tmux kill-session -t "$SESSION"

# Compile once so 4 concurrent iex panes don't race on _build.
(cd "$ROOT" && mix compile)

# Create + migrate each node's DB before launching iex panes, so every
# node starts against a ready schema. Each invocation targets only the
# repo relevant to that node's role and points it at a unique DB file.
setup_db() {
  local label="$1"   # e.g. "manager" or "chunkserver:bob"
  local repo="$2"    # Ecto repo module
  local env_var="$3" # GFS_MANAGER_DB_PATH | GFS_CHUNK_DB_PATH
  local db_path="$4"

  echo "==> Setting up DB for $label  ($db_path)"
  (
    cd "$ROOT"
    export "$env_var=$db_path"
    mix ecto.create -r "$repo" --quiet
    mix ecto.migrate -r "$repo" --quiet
  )
}

setup_db "manager" Gfs.Manager.Repo GFS_MANAGER_DB_PATH "$DB_ROOT/manager.db"
setup_db "chunkserver:bob" Gfs.ChunkServer.Repo GFS_CHUNK_DB_PATH "$DB_ROOT/bob.db"
setup_db "chunkserver:charlie" Gfs.ChunkServer.Repo GFS_CHUNK_DB_PATH "$DB_ROOT/charlie.db"
setup_db "chunkserver:david" Gfs.ChunkServer.Repo GFS_CHUNK_DB_PATH "$DB_ROOT/david.db"

tmux new-session -d -s "$SESSION" -n gfs -c "$ROOT"
tmux setw -t "$SESSION:0" remain-on-exit on

manager_cmd() {
  echo "GFS_MANAGER_DB_PATH=$DB_ROOT/manager.db \
iex --cookie $COOKIE --sname fatemah -S mix run --no-halt -- manager"
}

chunk_cmd() {
  local sname="$1"
  echo "GFS_CHUNK_DB_PATH=$DB_ROOT/${sname}.db \
GFS_MANAGER_NODE=$MANAGER_NODE \
iex --cookie $COOKIE --sname ${sname} -S mix run --no-halt -- chunkserver"
}

# Create all panes first, capturing stable pane IDs. Pane indices like
# "0.1" can shift as new splits are added, so we use IDs (e.g. "%23")
# to guarantee each command is sent to the right pane.
P0="$(tmux display-message -p -t "$SESSION:0" '#{pane_id}')"
P1="$(tmux split-window -P -F '#{pane_id}' -v -t "$P0" -c "$ROOT")"
P2="$(tmux split-window -P -F '#{pane_id}' -v -t "$P0" -c "$ROOT")"
P3="$(tmux split-window -P -F '#{pane_id}' -v -t "$P1" -c "$ROOT")"

tmux select-layout -t "$SESSION:0" even-vertical

# Now send each pane its command.
tmux send-keys -t "$P0" "$(manager_cmd)" C-m
tmux send-keys -t "$P1" "$(chunk_cmd bob)" C-m
tmux send-keys -t "$P2" "$(chunk_cmd charlie)" C-m
tmux send-keys -t "$P3" "$(chunk_cmd david)" C-m

tmux select-pane -t "$P0"

exec tmux attach -t "$SESSION"
