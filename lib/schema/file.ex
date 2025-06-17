defmodule Gfs.Schema.File do
  use Ecto.Schema
  import Ecto.Changeset

  schema "file" do
    field(:path, :string)
    has_many(:chunks, Gfs.Schema.Chunk)

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(node, params \\ %{}) do
    node
    |> cast(params, [:path, :inserted_at, :updated_at])
    |> validate_required([:path, :inserted_at, :updated_at])
  end
end
