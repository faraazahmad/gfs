defmodule Gfs.Schema.Chunk do
  use Ecto.Schema

  schema "chunk" do
    field :uniq_id, :string
    field :version, :integer
    field :start_byte, :integer
    field :end_byte, :integer
    field :inserted_at, :utc_datetime
    field :updated_at, :utc_datetime
    
    belongs_to :file, Gfs.Schema.File
    belongs_to :chunk_server, Gfs.Schema.ChunkServer
  end
end
