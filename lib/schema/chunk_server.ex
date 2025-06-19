defmodule Gfs.Schema.ChunkServer do
  use Ecto.Schema
  import Ecto.Changeset

  schema "chunk_server" do
    field(:uniq_id, :string)
    timestamps(type: :utc_datetime_usec)

    has_many(:chunks, Gfs.Schema.Chunk)
    belongs_to(:node, Gfs.Schema.Node)
  end

  def changeset(chunk_server, params \\ %{}) do
    chunk_server
    |> cast(params, [:uniq_id, :node_id])
    |> validate_required(params, [:uniq_id, :node_id])
  end
end
