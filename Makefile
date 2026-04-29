.PHONY: debug debug-stop debug-clean

# Launch a 4-pane tmux session: 1 manager + 3 chunkservers, each in iex.
debug:
	./scripts/debug-tmux.sh

# Kill the debug tmux session.
debug-stop:
	./scripts/debug-tmux.sh stop

# Wipe per-node debug SQLite DBs and start fresh.
debug-clean:
	GFS_CLEAN=1 ./scripts/debug-tmux.sh
