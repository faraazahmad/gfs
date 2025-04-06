defmodule Gfs.Manager.Repo.Migrations.AddChunkServerIdToChunk do
  use Ecto.Migration

  def change do
    alter table("chunk") do
      add :chunk_server_id, :integer
    end
  end
end
