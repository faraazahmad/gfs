defmodule Gfs.Repo.Manager.Migrations.SetIdentSecKey do
  use Ecto.Migration

  def change do
    create unique_index(:node, [:identifier])
  end
end
