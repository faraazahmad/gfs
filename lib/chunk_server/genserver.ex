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

  def handle_cast({:manager_connect, node}, state) do
    case Repo.get_by(Schema.Node, identifier: Atom.to_string(node)) do
      nil -> %Schema.Node{identifier: node}
      object -> object
    end
    |> Schema.Node.changeset(%{role: "manager", updated_at: DateTime.utc_now()})
    |> Repo.insert_or_update()

    updated_state = [node | state]
    {:noreply, updated_state}
  end

  # Handling synchronous call message
  def handle_call(:get_players, _from, state) do
    {:reply, state, state}
  end

  # Handling generic messages (not from call or cast)
  def handle_info({:remove_player, player_id}, state) do
    updated_state = List.delete(state, player_id)
    {:noreply, updated_state}
  end
end
