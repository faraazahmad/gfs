defmodule Gfs.Manager.Repo.Migrations.AddRoleToChunkServer do
  use Ecto.Migration

  def change do
    alter table("chunk_server") do
      add(:role, :string)
    end
  end
end
