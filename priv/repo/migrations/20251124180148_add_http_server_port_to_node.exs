defmodule Gfs.Repo.Migrations.AddHttpServerPortToNode do
  use Ecto.Migration

  def change do
    alter table "node" do
      add :http_port, :integer
    end
  end
end
