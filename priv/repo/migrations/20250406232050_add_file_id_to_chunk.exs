defmodule Gfs.Repo.Migrations.AddFileIdToChunk do
  use Ecto.Migration

  def change do
    alter table("chunk") do
      add :file_id, :integer
    end
  end
end
