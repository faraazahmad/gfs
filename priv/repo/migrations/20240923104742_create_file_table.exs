defmodule Gfs.Manager.Repo.Migrations.CreateFileTable do
  use Ecto.Migration

  def change do
    create table("file") do
      add :path, :string
      add :inserted_at, :utc_datetime
      add :updated_at, :utc_datetime
    end
  end
end
