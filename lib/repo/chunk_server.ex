defmodule Gfs.Repo.ChunkServer do
  use Ecto.Repo,
    otp_app: :gfs,
    adapter: Ecto.Adapters.SQLite3
end
