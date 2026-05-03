defmodule Gfs.Schema.File do
  use Ecto.Schema
  import Ecto.Changeset

  @derive {Jason.Encoder, only: [:path, :inserted_at, :updated_at]}
  schema "file" do
    field(:path, :string)
    has_many(:chunks, Gfs.Schema.Chunk)

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(file, params \\ %{}) do
    file
    |> cast(params, [:path, :inserted_at, :updated_at])
    |> validate_required([:path, :inserted_at, :updated_at])
    |> unique_constraint([:path])
  end
end
