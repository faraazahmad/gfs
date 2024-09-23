defmodule Gfs.Repo.Manager.Migrations.CreateFileTable do
  use Ecto.Migration

  def change do
    create table("file") do
      add :path, :string

      timestamps()
    end
  end
end
