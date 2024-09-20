defmodule Gfs.Schema.File do
  use Ecto.Schema

  schema "file" do
    field :path, :string
    has_many :chunks, Gfs.Schema.Chunk
  end
end
