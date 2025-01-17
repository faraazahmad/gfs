defmodule Gfs.Manager.Repo.Migrations.CreateChunk do
  use Ecto.Migration

  def change do
    create table("chunk") do
      add :uniq_id, :string
      add :version, :integer

      timestamps()
    end
  end
end
