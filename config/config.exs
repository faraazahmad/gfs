import Config

config :ecto, json_library: Jason

config :gfs, Gfs.Manager.Repo,
  database: Path.expand("~/.gfs/database/manager.db")

config :gfs, Gfs.ChunkServer.Repo,
  database: Path.expand("~/.gfs/database/chunk_server.db")

config :gfs, ecto_repos: [Gfs.Manager.Repo, Gfs.ChunkServer.Repo]

if File.exists?("config/#{config_env()}.exs") do
  import_config "#{config_env()}.exs"
end
