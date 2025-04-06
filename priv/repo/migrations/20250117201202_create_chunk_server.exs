defmodule Gfs.Manager.Repo.Migrations.CreateChunkServer do
  use Ecto.Migration

  def change do
    create table("chunk_server") do
      add :uniq_id, :string
      add :inserted_at, :utc_datetime
      add :updated_at, :utc_datetime
    end
  end
end
