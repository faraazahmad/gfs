defmodule Gfs.ChunkServer.Control do
  @moduledoc """
  Lightweight GenServer used as the "addressable handle" for a chunk
  server in the cluster.

  Responsibilities:
  - Joins the `:gfs_chunkservers` `:pg` group at startup so the manager
    can discover this node without doing a SQL/HTTP-port lookup.
  - Answers small "describe yourself" queries from the manager.
  - Hosts a per-node unique ULID (`uniq_id`) that the manager uses as
    the stable identity for this chunkserver across reboots.

  The data path (large appends, replicas) deliberately does NOT funnel
  through this process — see `Gfs.ChunkServer.Data` and
  `Gfs.ChunkServer.Serials`.
  """

  use GenServer

  @pg_group :gfs_chunkservers

  @doc """
  On-disk root directory for *this* chunkserver instance.

  Namespaced by `node()` so multiple chunkservers running under the
  same `$HOME` (e.g. the local `make debug` cluster on one machine)
  don't share a uniq_id file or a chunks directory.
  """
  @spec root_dir() :: String.t()
  def root_dir do
    Path.expand("~/.gfs/chunk_server/#{node()}")
  end

  @doc "Path to this chunkserver's persistent uniq_id file."
  @spec uniq_id_path() :: String.t()
  def uniq_id_path, do: Path.join(root_dir(), "uniq_id")

  ## Public API ##

  def start_link(_args) do
    GenServer.start_link(__MODULE__, %{}, name: :chunkserver)
  end

  @doc """
  Returns the `:pg` group name used to register chunkservers in the
  cluster.
  """
  def pg_group, do: @pg_group

  @doc """
  Returns a small map describing the chunkserver behind `pid`.

  Safe to call across nodes — payload is tiny.
  """
  @spec describe(pid()) :: {:ok, map()} | {:error, term()}
  def describe(pid) when is_pid(pid) do
    GenServer.call(pid, :describe, 5_000)
  rescue
    e -> {:error, e}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  @doc "Lists every chunkserver pid known to the cluster (this scope)."
  @spec list_pids() :: [pid()]
  def list_pids do
    :pg.get_members(@pg_group)
  end

  @doc "Lists every chunkserver pid running on `node`."
  @spec pids_on(node()) :: [pid()]
  def pids_on(node) do
    list_pids() |> Enum.filter(fn pid -> node(pid) == node end)
  end

  @doc """
  Ask the chunkserver control process running on `target_node` to ensure
  it is joined to the chunkserver `:pg` group.

  Safe to call repeatedly.
  """
  @spec rejoin_pg(node()) :: :ok | {:error, term()}
  def rejoin_pg(target_node) when is_atom(target_node) do
    GenServer.call({:chunkserver, target_node}, :rejoin_pg, 5_000)
  catch
    :exit, reason -> {:error, reason}
  end

  ## Callbacks ##

  @impl true
  def init(_args) do
    uniq_id = ensure_uniq_id()
    :ok = :pg.join(@pg_group, self())

    state = %{uniq_id: uniq_id, node: node(), http_port: lookup_http_port()}
    {:ok, state}
  end

  @impl true
  def handle_call(:rejoin_pg, _from, state) do
    :ok = :pg.join(@pg_group, self())
    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:describe, _from, state) do
    {:reply,
     {:ok,
      %{
        uniq_id: state.uniq_id,
        node: state.node,
        http_port: state.http_port,
        pid: self()
      }}, state}
  end

  defp lookup_http_port do
    case :ets.info(:port) do
      :undefined ->
        nil

      _ ->
        case :ets.lookup(:port, :http_server_port) do
          [{:http_server_port, port}] -> port
          _ -> nil
        end
    end
  end

  ## Helpers ##

  defp ensure_uniq_id do
    path = uniq_id_path()
    File.mkdir_p!(Path.dirname(path))

    case File.read(path) do
      {:ok, ""} ->
        write_new_uniq_id(path)

      {:ok, content} ->
        String.trim(content)

      {:error, _} ->
        write_new_uniq_id(path)
    end
  end

  defp write_new_uniq_id(path) do
    id = ExULID.ULID.generate()
    File.write!(path, id)
    id
  end
end
