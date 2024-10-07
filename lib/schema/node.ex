defmodule Gfs.Schema.Node do
  use Ecto.Schema
  import Ecto.Changeset

  @derive { Jason.Encoder, except: [:__meta__] }
  schema "node" do
    field :identifier, :string
    field :alive, :boolean

    timestamps()
  end

 def changeset(node, params \\ %{}) do
    node
    |> cast(params, [:identifier, :alive, :inserted_at, :updated_at])
    |> validate_required([:identifier, :alive, :inserted_at, :updated_at])
  end
end
