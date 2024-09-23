defmodule Gfs.Task.PingNodes do
  use Task, restart: :permanent

  alias Gfs.Schema
  alias Gfs.Repo

  @ping_minutes 1

  def start_link(_) do
    Task.start_link(__MODULE__, :ping_nodes, [])
  end

  def all_nodes do
    connected_nodes = Enum.map(Node.list, fn node -> Atom.to_string(node) end)
    registered_nodes = Enum.map(Repo.Manager.all(Schema.Node), fn node -> node.identifier end)

    Enum.concat(connected_nodes, registered_nodes)
    |> MapSet.new
    |> MapSet.to_list
  end

  def ping_nodes do
    Enum.each(all_nodes(), fn node ->
      node_status = case Node.ping(String.to_atom(node)) do
        :pong -> true
        _ -> false
      end

      case Repo.Manager.get_by(Schema.Node, identifier: node) do
        nil  -> %Schema.Node{identifier: node}
        object -> object
      end
      |> Schema.Node.changeset(%{alive: node_status, updated_at: DateTime.utc_now})
      |> Repo.Manager.insert_or_update
    end)

    Process.sleep @ping_minutes * 20 * 1000
    ping_nodes()
  end
end
