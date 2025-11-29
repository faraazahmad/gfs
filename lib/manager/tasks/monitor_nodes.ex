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
    chunk_server =
      case Repo.get_by(Schema.ChunkServer, node_id: node_record_id) do
        nil ->
          IO.puts("Creating chunk server for node_id #{node_record_id}")

          Repo.insert!(%Schema.ChunkServer{
            node_id: node_record_id,
            uniq_id: ExULID.ULID.generate()
          })

        server_record ->
          IO.puts("ChunkServer already exists for node #{node_record_id}")
          server_record
      end

    {:ok, chunk_server}
  end

  def connect_to_known_nodes do
    Repo.all(Schema.Node)
    |> Enum.map(fn node -> connect_to_node(node) end)
    |> Enum.each(fn node -> upsert_chunk_server(node.id) end)
  end

  def monitor do
    # Connect to already registerd nodes in the background
    spawn(fn -> connect_to_known_nodes() end)

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

  defp connect_to_node(node) do
    node_identifier = node.identifier
    IO.puts("Attempting connection to registered node: #{node_identifier}")

    case Node.connect(String.to_atom(node_identifier)) do
      true -> IO.puts("Connected to node #{node_identifier}")
      false -> IO.puts("Unable to connect to node #{node_identifier}")
      :ignored -> IO.puts("Node #{node_identifier} is offline")
    end

    node
  end
end
