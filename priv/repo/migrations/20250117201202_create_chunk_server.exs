defmodule Gfs.Manager.Repo.Migrations.CreateChunkServer do
  use Ecto.Migration

  def change do
    create table("chunk_server") do
      add :uniq_id, :string

      timestamps()
    end
  end
end
