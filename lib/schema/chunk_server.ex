defmodule Gfs.Schema.ChunkServer do
  use Ecto.Schema

  schema "chunk_server" do
    field :name, :string
    timestamps()
    
    has_many :chunks, Gfs.Schema.Chunk
    belongs_to :node, Gfs.Schema.Node
  end
end
