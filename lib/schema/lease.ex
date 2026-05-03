defmodule Gfs.Schema.Lease do
  use Ecto.Schema
  import Ecto.Changeset

  @derive {Jason.Encoder,
           only: [
             :lease_id,
             :chunk_uniq_id,
             :chunk_version,
             :expires_at,
             :revoked_at,
             :file_id,
             :primary_chunk_server_id,
             :inserted_at,
             :updated_at
           ]}
  schema "lease" do
    field(:lease_id, :string)
    field(:chunk_uniq_id, :string)
    field(:chunk_version, :integer)
    field(:expires_at, :utc_datetime_usec)
    field(:revoked_at, :utc_datetime_usec)

    belongs_to(:file, Gfs.Schema.File)
    belongs_to(:primary_chunk_server, Gfs.Schema.ChunkServer)

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(lease, params \\ %{}) do
    lease
    |> cast(params, [
      :lease_id,
      :chunk_uniq_id,
      :chunk_version,
      :expires_at,
      :revoked_at,
      :file_id,
      :primary_chunk_server_id
    ])
    |> validate_required([
      :lease_id,
      :chunk_uniq_id,
      :chunk_version,
      :expires_at,
      :file_id,
      :primary_chunk_server_id
    ])
    |> unique_constraint(:lease_id)
    |> unique_constraint(:chunk_uniq_id)
  end
end
