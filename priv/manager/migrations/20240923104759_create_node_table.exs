defmodule Gfs.Repo.Manager.Migrations.CreateNodeTable do
  use Ecto.Migration

  def change do
    create table("node") do
      add :identifier, :string
      add :alive, :boolean

      timestamps()
    end
  end
end
