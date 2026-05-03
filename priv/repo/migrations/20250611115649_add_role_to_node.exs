defmodule Gfs.Repo.Migrations.AddRoleToNode do
  use Ecto.Migration

  def change do
    alter table("node") do
      add :role, :string
    end
  end
end
