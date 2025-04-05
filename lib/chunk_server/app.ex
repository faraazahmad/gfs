defmodule Gfs.ChunkServer.App do
  use Application
  use GenServer

  @impl true
  def init(arg) do
    {:ok, arg}
  end

  @impl true
  def start(_type, _args) do
    # nodes = Application.fetch_env!(:gfs, :nodes)
    # Enum.each(nodes, fn node -> connect_to_node(node) end)

    children = [
      Gfs.ChunkServer.Repo,
      {Bandit, plug: Gfs.ChunkServer.RestApi, scheme: :http, port: get_free_port()},
      # Gfs.Task.MonitorNodes
    ]
    IO.puts "Starting GFS ChunkServer Application"
    Supervisor.start_link(children, strategy: :one_for_one)
  end

  def get_free_port do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, {:active, false}, {:reuseaddr, true}])
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)

    port
  end
end
