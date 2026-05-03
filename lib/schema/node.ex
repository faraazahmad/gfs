defmodule Gfs.Schema.Node do
  use Ecto.Schema
  import Ecto.Changeset

  @derive {Jason.Encoder,
           only: [:http_port, :identifier, :inserted_at, :updated_at, :role, :alive]}
  schema "node" do
    field(:identifier, :string)
    field(:role, :string)
    field(:http_port, :integer)
    field(:alive, :boolean)

    has_one(:chunk_server, Gfs.Schema.ChunkServer)

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(node, params \\ %{}) do
    node
    |> cast(params, [:http_port, :identifier, :role, :alive])
    |> validate_required([:http_port, :identifier, :role, :alive])
  end
end
