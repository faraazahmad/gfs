defmodule Gfs.ChunkServer.Genserver do
  use GenServer

  # Starting GenServer with initial state
  def start_link(_initial_state) do
    GenServer.start_link(__MODULE__, %{lease_serials: %{}}, name: :chunkserver)
  end

  @impl true
  def init(state) do
    {:ok, state}
  end

  def get_node_http_port do
    [http_server_port: port] = :ets.lookup(:port, :http_server_port)

    port
  end

  def next_serial(lease_id) do
    GenServer.call(:chunkserver, {:next_serial, lease_id})
  end

  @impl true
  def handle_call(:manager_connect, _manager_node, state) do
    {:reply, get_node_http_port(), state}
  end

  @impl true
  def handle_call({:next_serial, lease_id}, _from, state) do
    n = Map.get(state.lease_serials, lease_id, 0) + 1
    new_state = %{state | lease_serials: Map.put(state.lease_serials, lease_id, n)}
    {:reply, {:ok, n}, new_state}
  end
end
