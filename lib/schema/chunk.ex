defmodule Gfs.Schema.Chunk do
  use Ecto.Schema

  schema "chunk" do
    field :uniq_id, :string
    field :version, :integer
    timestamps()
    
    belongs_to :file, Gfs.Schema.File
    belongs_to :chunk_server, Gfs.Schema.ChunkServer
  end
end
