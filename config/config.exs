import Config

config :gfs, Gfs.Repo,
  database: Path.expand("~/.gfs/database.db")

config :gfs, ecto_repos: [Gfs.Repo]
