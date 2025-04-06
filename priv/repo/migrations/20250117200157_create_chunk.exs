defmodule Gfs.Manager.Repo.Migrations.CreateChunk do
  use Ecto.Migration

  def change do
    create table("chunk") do
      add :uniq_id, :string
      add :version, :integer
      add :inserted_at, :utc_datetime
      add :updated_at, :utc_datetime
    end
  end
end
