defmodule Gfs.Manager.Task.MonitorNodes do
  @moduledoc """
  Watches the cluster and keeps the manager's view of chunkservers in
  sync.

  Two event sources:

  1. `:net_kernel.monitor_nodes(true)` — node-level liveness.
  2. `:pg.monitor(:gfs_chunkservers)` — chunkserver-process membership.

  This runs as a real GenServer with a looping receive and is
  the canonical place that flips `Gfs.Schema.Node.alive` and upserts
  `Gfs.Schema.ChunkServer` rows.

  Discovery is by `:pg` pid, addressing is `node()`, and metadata
  comes from `Gfs.ChunkServer.Control.describe/1`.
  """

  use GenServer
  require Logger

  alias Gfs.Manager.Repo
  alias Gfs.Schema

  @rejoin_attempts 5
  @rejoin_backoff_ms 500

  def start_link(_args) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @impl true
  def init(_args) do
    :net_kernel.monitor_nodes(true)
    {monitor_ref, current_members} = :pg.monitor(Gfs.ChunkServer.Control.pg_group())

    # Bootstrap: connect to nodes we already know about, and hydrate
    # state from any chunkservers already in :pg.
    send(self(), :bootstrap_known_nodes)
    Enum.each(current_members, &handle_chunkserver_join/1)

    {:ok, %{pg_ref: monitor_ref, monitored: %{}}}
  end

  @impl true
  def handle_info(:bootstrap_known_nodes, state) do
    spawn(fn -> connect_to_known_nodes() end)
    {:noreply, state}
  end

  @impl true
  def handle_info({:nodeup, node}, state) do
    IO.puts("MonitorNodes: nodeup #{node}")
    # We don't flip `alive=true` here — that happens when the
    # chunkserver actually shows up in the :pg group, which is the
    # real signal that the chunkserver process is ready to serve.
    {:noreply, state}
  end

  @impl true
  def handle_info({:nodedown, node}, state) do
    IO.puts("MonitorNodes: nodedown #{node}")
    mark_node_alive(node, false)
    {:noreply, state}
  end

  # Chunkserver process joined :pg.
  @impl true
  def handle_info({_ref, :join, _group, pids}, state) do
    new_monitored =
      Enum.reduce(pids, state.monitored, fn pid, acc ->
        case handle_chunkserver_join(pid) do
          {:ok, ref} -> Map.put(acc, pid, ref)
          :error -> acc
        end
      end)

    {:noreply, %{state | monitored: new_monitored}}
  end

  # Chunkserver process left :pg.
  #
  # We do NOT mark the node down here — `:nodedown` is the only
  # authoritative source for `alive=false`. If the underlying Erlang
  # node is still up, the chunkserver process likely just crashed/restarted,
  # so kick off a background task asking it to re-join `:pg`.
  @impl true
  def handle_info({_ref, :leave, _group, pids}, state) do
    new_monitored =
      Enum.reduce(pids, state.monitored, fn pid, acc ->
        case Map.pop(acc, pid) do
          {nil, m} ->
            m

          {ref, m} ->
            Process.demonitor(ref, [:flush])
            m
        end
      end)

    pids
    |> Enum.map(&node/1)
    |> Enum.uniq()
    |> Enum.each(&maybe_request_chunkserver_rejoin/1)

    {:noreply, %{state | monitored: new_monitored}}
  end

  # A chunkserver pid we were monitoring went DOWN. Drop the monitor
  # entry; node liveness is owned by `:nodedown`.
  @impl true
  def handle_info({:DOWN, _ref, :process, pid, reason}, state) do
    IO.puts("MonitorNodes: chunkserver #{inspect(pid)} DOWN (#{inspect(reason)})")
    {:noreply, %{state | monitored: Map.delete(state.monitored, pid)}}
  end

  @impl true
  def handle_info(other, state) do
    IO.puts("MonitorNodes: ignoring #{inspect(other)}")
    {:noreply, state}
  end

  ## Helpers ##

  defp handle_chunkserver_join(pid) when is_pid(pid) do
    case Gfs.ChunkServer.Control.describe(pid) do
      {:ok, info} ->
        ref = Process.monitor(pid)
        upsert_node_and_chunkserver(info)
        IO.puts("MonitorNodes: registered chunkserver #{info.uniq_id} on #{info.node}")
        {:ok, ref}

      {:error, reason} ->
        IO.puts(
          "MonitorNodes: failed to describe chunkserver #{inspect(pid)}: #{inspect(reason)}"
        )

        :error
    end
  end

  defp upsert_node_and_chunkserver(%{node: node, uniq_id: cs_uniq_id} = info) do
    node_str = Atom.to_string(node)
    # http_port is only used by the HTTP edge (`gfs_client` upload
    # path); east-west traffic addresses chunkservers by `node()`.
    http_port = Map.get(info, :http_port) || 0

    {:ok, node_record} =
      case Repo.get_by(Schema.Node, identifier: node_str) do
        nil -> %Schema.Node{identifier: node_str}
        existing -> existing
      end
      |> Schema.Node.changeset(%{
        role: "chunkserver",
        http_port: http_port,
        alive: true
      })
      |> Repo.insert_or_update()

    case Repo.get_by(Schema.ChunkServer, uniq_id: cs_uniq_id) do
      nil ->
        Repo.insert!(%Schema.ChunkServer{
          node_id: node_record.id,
          uniq_id: cs_uniq_id,
          role: "chunkserver"
        })

      existing ->
        # Re-bind to the (possibly new) node row in case the chunkserver
        # moved hosts.
        if existing.node_id != node_record.id do
          existing
          |> Ecto.Changeset.change(node_id: node_record.id)
          |> Repo.update!()
        else
          existing
        end
    end
  end

  defp mark_node_alive(node, alive) do
    node_str = Atom.to_string(node)

    case Repo.get_by(Schema.Node, identifier: node_str) do
      nil ->
        :ok

      record ->
        record
        |> Schema.Node.changeset(%{
          role: record.role || "chunkserver",
          http_port: record.http_port || 0,
          alive: alive
        })
        |> Repo.insert_or_update()

        :ok
    end
  end

  defp maybe_request_chunkserver_rejoin(target_node) do
    if node_alive?(target_node) do
      spawn(fn -> request_chunkserver_rejoin(target_node, @rejoin_attempts) end)
    end

    :ok
  end

  defp request_chunkserver_rejoin(_target_node, 0), do: :ok

  defp request_chunkserver_rejoin(target_node, attempts_left) do
    if node_alive?(target_node) do
      case Gfs.ChunkServer.Control.rejoin_pg(target_node) do
        :ok ->
          Logger.info("MonitorNodes: requested :pg rejoin from #{target_node}")
          :ok

        {:error, reason} ->
          Logger.warning(
            "MonitorNodes: failed requesting :pg rejoin from #{target_node}: #{inspect(reason)}"
          )

          Process.sleep(@rejoin_backoff_ms)
          request_chunkserver_rejoin(target_node, attempts_left - 1)
      end
    else
      :ok
    end
  end

  defp node_alive?(target_node) do
    target_node == node() or target_node in Node.list() or Node.ping(target_node) == :pong
  end

  defp connect_to_known_nodes do
    Repo.all(Schema.Node)
    |> Enum.each(fn node ->
      identifier = node.identifier
      IO.puts("MonitorNodes: bootstrap connect to #{identifier}")

      case Node.connect(String.to_atom(identifier)) do
        true -> IO.puts("MonitorNodes: connected to #{identifier}")
        false -> IO.puts("MonitorNodes: unable to connect to #{identifier}")
        :ignored -> IO.puts("MonitorNodes: #{identifier} offline")
      end
    end)
  end
end
