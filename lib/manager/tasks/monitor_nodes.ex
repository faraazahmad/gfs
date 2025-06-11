defmodule Gfs.Manager.Task.MonitorNodes do
  use Task, restart: :permanent

  alias Gfs.Schema
  alias Gfs.Manager

  def start_link(_) do
    Task.start_link(__MODULE__, :monitor, [])
  end

  def all_nodes do
    connected_nodes = Enum.map(Node.list(), fn node -> node end)

    registered_nodes =
      Enum.map(Manager.Repo.all(Schema.Node), fn node -> String.to_atom(node.identifier) end)

    Enum.concat(connected_nodes, registered_nodes)
    |> MapSet.new()
    |> MapSet.to_list()
  end

  def update_node_status(node, alive) do
    case Manager.Repo.get_by(Schema.Node, identifier: node) do
      nil -> %Schema.Node{identifier: node}
      object -> object
    end
    |> Schema.Node.changeset(%{alive: alive, updated_at: DateTime.utc_now()})
    |> Manager.Repo.insert_or_update()
  end

  def monitor do
    # try connecting to all known nodes
    registered_nodes = Gfs.Manager.Repo.all(Schema.Node)
    Enum.each(registered_nodes, fn node -> connect_to_node(node) end)

    # Update all nodes' status when bringing up app
    Enum.each(all_nodes(), fn node ->
      node_alive =
        case Node.ping(node) do
          :pong -> true
          _ -> false
        end

      update_node_status(Atom.to_string(node), node_alive)
    end)

    # Start monitor for all nodes' connections
    :net_kernel.monitor_nodes(true)

    receive do
      {:nodedown, node} ->
        update_node_status(Atom.to_string(node), false)

      {:nodeup, node} ->
        update_node_status(Atom.to_string(node), true)
        GenServer.cast({:chunkserver, node}, {:manager_connect, Node.self()})

      other ->
        IO.puts("Undefined state of node monitor")
        IO.inspect(other)
    end
  end

  defp connect_to_node(name) do
    IO.puts("Attempting connection to registered node: #{name}")

    case Node.connect(name) do
      true -> IO.puts("Connected to node #{name}")
      false -> IO.puts("Unable to connect to node #{name}")
      :ignored -> IO.puts("Node #{name} is offline")
    end
  end
end
