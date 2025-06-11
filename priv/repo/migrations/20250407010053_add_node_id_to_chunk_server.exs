defmodule Gfs.Repo.Migrations.AddNodeIdToChunkServer do
  use Ecto.Migration

  def change do
    alter table("chunk_server") do
      add :node_id, :integer
    end
  end
end
