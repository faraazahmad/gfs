defmodule Gfs.Schema.Chunk do
  use Ecto.Schema

  schema "chunk" do
    field :last_modified, :utc_datetime
    belongs_to :file, Gfs.Schema.File
  end
end
