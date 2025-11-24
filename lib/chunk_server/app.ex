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
      Gfs.ChunkServer.Repo,
      Gfs.ChunkServer.Genserver,
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
