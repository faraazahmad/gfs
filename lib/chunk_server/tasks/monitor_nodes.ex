import Ecto.Query

defmodule Gfs.ChunkServer.Task.MonitorNodes do
  use Task, restart: :permanent

  alias Gfs.Schema
  alias Gfs.ChunkServer.Repo

  def start_link(_) do
    Task.start_link(__MODULE__, :monitor, [])
  end

  def monitor do
    # Search for master node in repo and connect to it
    master_node =
      Gfs.Schema.Node
      |> where(role: "manager")
      |> Repo.one()

    # if master node is found, connect to it
    if master_node do
      connect_to_node(master_node.identifier)
    end

    # else, start monitoring for nodes and save node to Repo if found to be master
    # Start monitor for all nodes' connections
    :net_kernel.monitor_nodes(true)

    receive do
      {:nodeup, node} ->
        update_node_status(Atom.to_string(node), true)

      # TODO: handle master node disconnect
      {:nodedown, node} ->
        update_node_status(Atom.to_string(node), true)

        is_node_manager =
          Repo.get_by(Schema.Node, identifier: Atom.to_string(node), role: "manager")

        if is_node_manager do
          IO.puts("Connection to manager node lost. Shutting down...")
          exit("Connection to manager node lost.")
        end

      other ->
        IO.puts("Undefined state of node monitor")
        IO.inspect(other)
    end
  end

  def update_node_status(node, alive) do
    case Repo.get_by(Schema.Node, identifier: node) do
      nil -> %Schema.Node{identifier: node}
      object -> object
    end
    |> Schema.Node.changeset(%{alive: alive})
    |> Repo.insert_or_update()
  end

  defp connect_to_node(name) do
    IO.puts("Attempting connection to registered node: #{name}")

    case Node.connect(String.to_atom(name)) do
      true -> IO.puts("Connected to node #{name}")
      false -> IO.puts("Unable to connect to node #{name}")
      :ignored -> IO.puts("Node #{name} is offline")
    end
  end
end
