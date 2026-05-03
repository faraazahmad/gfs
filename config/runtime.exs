import Config

# Allow each locally-running node to use its own SQLite database.
# When running multiple chunkservers on the same host (e.g. via
# scripts/debug-tmux.sh), set GFS_CHUNK_DB_PATH to a unique file
# per node. Falls back to the default path used in non-debug runs.

config :gfs, Gfs.Manager.Repo,
  database:
    System.get_env(
      "GFS_MANAGER_DB_PATH",
      Path.expand("~/.gfs/database/manager.db")
    )

config :gfs, Gfs.ChunkServer.Repo,
  database:
    System.get_env(
      "GFS_CHUNK_DB_PATH",
      Path.expand("~/.gfs/database/chunk_server.db")
    )
