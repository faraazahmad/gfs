defmodule Gfs.Schema.ChunkServer do
  use Ecto.Schema

  schema "chunk_server" do
    field(:uniq_id, :string)
    field(:inserted_at, :utc_datetime)
    field(:updated_at, :utc_datetime)

    has_many(:chunks, Gfs.Schema.Chunk)
    belongs_to(:node, Gfs.Schema.Node)
  end
end
