defmodule Gfs.ChunkServer.Genserver do
  use GenServer
  alias Gfs.Schema
  alias Gfs.ChunkServer.Repo

  # Starting GenServer with initial state
  def start_link(initial_state) do
    GenServer.start_link(__MODULE__, initial_state, name: :chunkserver)
  end

  def init(state) do
    {:ok, state}
  end

  def handle_cast({:manager_connect, node_atom}, state) do
    node = Atom.to_string(node_atom)

    case Repo.get_by(Schema.Node, identifier: node) do
      nil -> %Schema.Node{identifier: node, alive: true, inserted_at: DateTime.utc_now()}
      object -> object
    end
    |> Schema.Node.changeset(%{role: "manager", updated_at: DateTime.utc_now()})
    |> Repo.insert_or_update!()

    updated_state = [node | state]
    {:noreply, updated_state}
  end
end
