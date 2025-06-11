defmodule Gfs.Schema.Node do
  use Ecto.Schema
  import Ecto.Changeset

  @derive {Jason.Encoder, except: [:__meta__]}
  schema "node" do
    field(:identifier, :string)
    field(:role, :string)
    field(:alive, :boolean)

    has_one(:chunk_server, Gfs.Schema.ChunkServer)

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(node, params \\ %{}) do
    node
    |> cast(params, [:identifier, :role, :alive])
    |> validate_required([:identifier, :role, :alive])
  end
end
