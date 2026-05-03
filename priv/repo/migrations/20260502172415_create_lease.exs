defmodule Gfs.Repo.Migrations.CreateLease do
  use Ecto.Migration

  def change do
    create table("lease") do
      add :lease_id, :string, null: false
      add :chunk_uniq_id, :string, null: false
      add :chunk_version, :integer, null: false
      add :expires_at, :utc_datetime_usec, null: false
      add :revoked_at, :utc_datetime_usec
      add :file_id, references(:file), null: false
      add :primary_chunk_server_id, references(:chunk_server), null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:lease, [:lease_id])
    create unique_index(:lease, [:chunk_uniq_id])
  end
end
