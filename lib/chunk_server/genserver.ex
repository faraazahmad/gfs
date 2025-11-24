defmodule Gfs.ChunkServer.Genserver do
  use GenServer

  # Starting GenServer with initial state
  def start_link(initial_state) do
    GenServer.start_link(__MODULE__, initial_state, name: :chunkserver)
  end

  @impl true
  def init(state) do
    {:ok, state}
  end

  def get_node_http_port do
    [http_server_port: port] = :ets.lookup(:port, :http_server_port)

    port
  end

  @impl true
  def handle_call(:manager_connect, _manager_node, state) do
    {:reply, get_node_http_port(), state}
  end
end
