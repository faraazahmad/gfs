defmodule Gfs.Manager.Repo.Migrations.CreateNodeTable do
  use Ecto.Migration

  def change do
    create table("node") do
      add :identifier, :string
      add :alive, :boolean
      add :inserted_at, :utc_datetime
      add :updated_at, :utc_datetime
    end
  end
end
