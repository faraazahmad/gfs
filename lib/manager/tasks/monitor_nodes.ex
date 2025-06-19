defmodule Gfs.Manager.Task.MonitorNodes do
  use Task, restart: :permanent

  alias Gfs.Schema
  alias Gfs.Manager.Repo

  def start_link(_) do
    Task.start_link(__MODULE__, :monitor, [])
  end

  def all_nodes do
    connected_nodes = Enum.map(Node.list(), fn node -> node end)

    registered_nodes =
      Enum.map(Repo.all(Schema.Node), fn node -> String.to_atom(node.identifier) end)

    Enum.concat(connected_nodes, registered_nodes)
    |> MapSet.new()
    |> MapSet.to_list()
  end

  def update_node_status(node, alive) do
    IO.puts("Updating node status for node: #{node}, connection: #{alive}")

    result =
      case Repo.get_by(Schema.Node, identifier: node) do
        nil -> %Schema.Node{identifier: node}
        object -> object
      end
      |> Schema.Node.changeset(%{
        role: "chunkserver",
        alive: alive
      })
      |> Repo.insert_or_update()

    case result do
      {:ok, node_record} ->
        IO.puts("Successfully updated node status for #{node}")
        {:ok, node_record}

      {:error, changeset} ->
        IO.puts("Failed to update node status for #{node}")
        {:error, changeset.errors}
    end
  end

  def upsert_chunk_server(node_record_id) do
    case Repo.get_by(Schema.ChunkServer, node_id: node_record_id) do
      nil ->
        Repo.insert!(%Schema.ChunkServer{
          node_id: node_record_id,
          uniq_id: ExULID.ULID.generate()
        })

        IO.puts("Created chunk server for node_id #{node_record_id}")

      chunk_server ->
        {:ok, chunk_server}
    end
  end

  def monitor do
    # try connecting to all known nodes
    registered_nodes = Repo.all(Schema.Node)
    Enum.each(registered_nodes, fn node -> connect_to_node(node.identifier) end)

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
        GenServer.cast({:chunkserver, node}, {:manager_connect, Node.self()})

        case update_node_status(Atom.to_string(node), true) do
          {:ok, node_record} ->
            upsert_chunk_server(node_record.id)

          {:error, errors} ->
            IO.puts(errors)
            nil
        end

      other ->
        IO.puts("Undefined state of node monitor")
        IO.inspect(other)
    end
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
