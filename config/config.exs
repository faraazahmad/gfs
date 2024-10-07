import Config

config :gfs, Gfs.Manager.Repo,
  database: Path.expand("~/.gfs/database/manager.db")

config :gfs, Gfs.Repo.ChunkServer,
  database: Path.expand("~/.gfs/database/chunk_server.db")

config :gfs, ecto_repos: [Gfs.Manager.Repo, Gfs.Repo.ChunkServer]
