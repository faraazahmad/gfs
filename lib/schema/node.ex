defmodule Gfs.Schema.Node do
  use Ecto.Schema
  import Ecto.Changeset

  @derive {Jason.Encoder, except: [:__meta__]}
  schema "node" do
    field(:identifier, :string)
    field(:role, :string)
    field(:alive, :boolean)
    field(:inserted_at, :utc_datetime)
    field(:updated_at, :utc_datetime)

    has_one(:chunk_server, Gfs.Schema.ChunkServer)
  end

  def changeset(node, params \\ %{}) do
    node
    |> cast(params, [:identifier, :role, :alive, :inserted_at, :updated_at])
    |> validate_required([:identifier, :role, :alive, :inserted_at, :updated_at])
  end
end
