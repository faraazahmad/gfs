defmodule Gfs.ChunkServer.App do
  use Supervisor

  def start_link(init_arg) do
    IO.puts("Starting GFS ChunkServer Application")
    :ets.new(:port, [:set, :protected, :named_table])
    :ets.insert(:port, {:http_server_port, get_free_port()})
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_args) do
    [http_server_port: port] = :ets.lookup(:port, :http_server_port)

    children = [
      # `:pg` is the cluster registry used to discover chunkservers
      # without going through SQL/HTTP-port lookups
      %{
        id: :pg,
        start: {:pg, :start_link, []}
      },
      Gfs.ChunkServer.Repo,
      Gfs.ChunkServer.Serials,
      Gfs.ChunkServer.Control,
      # The chunkserver Bandit is kept so any HTTP-based client can still
      # interact with the system.
      {Bandit, plug: Gfs.ChunkServer.RestApi, scheme: :http, port: port},
      Gfs.ChunkServer.Task.MonitorNodes
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  def get_free_port do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, {:active, false}, {:reuseaddr, true}])
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)

    port
  end
end
