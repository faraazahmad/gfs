defmodule Gfs.ChunkServer.Task.MonitorNodes do
  @moduledoc """
  Watches the cluster for the manager node.

  Connects to the manager (from DB or `GFS_MANAGER_NODE` env) at boot,
  then loops on `:net_kernel.monitor_nodes/1` events. If the manager
  goes down the chunkserver shuts itself down so it isn't serving in a
  partitioned state.
  """

  use GenServer
  import Ecto.Query

  alias Gfs.ChunkServer.Repo
  alias Gfs.Schema

  def start_link(_args) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @impl true
  def init(_args) do
    :net_kernel.monitor_nodes(true)
    send(self(), :bootstrap_connect)
    {:ok, %{manager_node: nil}}
  end

  @impl true
  def handle_info(:bootstrap_connect, state) do
    target =
      cond do
        node =
            Repo.one(
              from(n in Schema.Node,
                where: n.role == "manager" and n.alive == true,
                order_by: [desc: n.updated_at],
                limit: 1
              )
            ) ->
          node.identifier

        env = System.get_env("GFS_MANAGER_NODE") ->
          env

        true ->
          nil
      end

    new_state =
      if target do
        connect_to_node(target)
        %{state | manager_node: String.to_atom(target)}
      else
        state
      end

    {:noreply, new_state}
  end

  @impl true
  def handle_info({:nodeup, node}, state) do
    update_node_status(Atom.to_string(node), true)
    {:noreply, state}
  end

  @impl true
  def handle_info({:nodedown, node}, state) do
    update_node_status(Atom.to_string(node), false)

    is_manager =
      Repo.get_by(Schema.Node, identifier: Atom.to_string(node), role: "manager") != nil

    if is_manager or node == state.manager_node do
      IO.puts("Connection to manager node lost. Shutting down...")
      System.stop(1)
    end

    {:noreply, state}
  end

  @impl true
  def handle_info(other, state) do
    IO.puts("ChunkServer MonitorNodes: ignoring #{inspect(other)}")
    {:noreply, state}
  end

  ## Helpers ##

  defp update_node_status(node_str, alive) do
    case Repo.get_by(Schema.Node, identifier: node_str) do
      nil -> %Schema.Node{identifier: node_str}
      object -> object
    end
    |> Schema.Node.changeset(%{
      alive: alive,
      role: "manager",
      http_port: 0
    })
    |> Repo.insert_or_update()
  end

  defp connect_to_node(name) do
    IO.puts("ChunkServer MonitorNodes: connecting to #{name}")

    case Node.connect(String.to_atom(name)) do
      true -> IO.puts("ChunkServer MonitorNodes: connected to #{name}")
      false -> IO.puts("ChunkServer MonitorNodes: unable to connect to #{name}")
      :ignored -> IO.puts("ChunkServer MonitorNodes: #{name} offline")
    end
  end
end
