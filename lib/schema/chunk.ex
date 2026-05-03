defmodule Gfs.Schema.Chunk do
  use Ecto.Schema
  import Ecto.Changeset

  @derive {Jason.Encoder,
           only: [
             :uniq_id,
             :version,
             :start_byte,
             :end_byte,
             :inserted_at,
             :updated_at,
             :file_id,
             :chunk_server_id
           ]}
  schema "chunk" do
    field(:uniq_id, :string)
    field(:version, :integer)
    field(:start_byte, :integer)
    field(:end_byte, :integer)

    timestamps(type: :utc_datetime_usec)

    belongs_to(:file, Gfs.Schema.File)
    belongs_to(:chunk_server, Gfs.Schema.ChunkServer)
  end

  def changeset(chunk, params \\ %{}) do
    chunk
    |> cast(params, [:version, :uniq_id, :start_byte, :end_byte, :file_id, :chunk_server_id])
    |> validate_required([:version, :uniq_id, :start_byte, :end_byte, :file_id, :chunk_server_id])
  end
end
