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

  def update_node_status(_node, true, nil) do
    {:error, "http server port not provided for alive node"}
  end

  def update_node_status(node, alive, http_server_port) do
    IO.puts("Updating node status for node: #{node}, connection: #{alive}")
    node_str = Atom.to_string(node)

    result =
      case Repo.get_by(Schema.Node, identifier: node_str) do
        nil -> %Schema.Node{identifier: node_str}
        object -> object
      end
      |> Schema.Node.changeset(%{
        role: "chunkserver",
        http_port: http_server_port,
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
    registered_nodes = Repo.all(Schema.Node)
    # Try connecting to all known nodes, :nodeup monitor will handle updating node status
    Enum.each(registered_nodes, fn node -> connect_to_node(node.identifier) end)

    # Start monitor for all nodes' connections
    :net_kernel.monitor_nodes(true)

    receive do
      {:nodedown, node} ->
        update_node_status(node, false, nil)

      {:nodeup, node} ->
        http_server_port = GenServer.call({:chunkserver, node}, :manager_connect)

        case update_node_status(node, true, http_server_port) do
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
