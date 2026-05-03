defmodule Gfs.Repo.Migrations.AddBytesToChunk do
  use Ecto.Migration

  def change do
    alter table("chunk") do
      add :start_byte, :bigint
      add :end_byte, :bigint
    end
  end
end
