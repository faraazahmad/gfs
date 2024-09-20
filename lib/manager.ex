defmodule Gfs.Manager do
  use Application
  use GenServer

  @impl true
  def init(arg) do
    {:ok, arg}
  end

  @impl true
  def start(_type, _args) do
    children = [
      Gfs.Repo
    ]
    IO.puts "Starting GFS Manager Application"
    Supervisor.start_link(children, strategy: :one_for_one)
  end

  # receive do
  #   {:message_type, value} ->
  #     # code
  # end
  

  # use GenServer
  #
  # @chunk_servers [
  #   :"alice@Syeds-MacBook-Pro.local",
  #   :"bob@Syeds-MacBook-Pro.local",
  #   :"charlie@Syeds-MacBook-Pro.local"
  # ]
  #
  # def start_link(arg) when is_map(arg) do
  #   connect_to_chunk_servers(@chunk_servers)
  #   GenServer.start_link(__MODULE__, arg, name: __MODULE__)
  # end
  #
  # def connect_to_chunk_servers(chunk_servers) do
  #   Enum.each(chunk_servers, fn node -> Node.connect(node) end)
  #   Enum.each(chunk_servers, fn node -> Node.spawn_link(node, Manager, :start_link, %{}) end)
  # end
  #
  #
  # # @impl true
  # # def handle_call({:get_chunkservers, file_path}, _from, record) do
  # # end
  #
  # @impl true
  # def handle_call({:read, file_path}, _from, record) do
  #   {:reply, record, Map.get(record, file_path, [])}
  # end
  #
  # @impl true
  # def handle_call({:write, file_path}, _from, record) do
  #   {:reply, record, Map.put(record, file_path, [])}
  # end
end
