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
      {Bandit, plug: Gfs.ChunkServer.RestApi},
      # Gfs.Task.MonitorNodes
    ]
    IO.puts "Starting GFS ChunkServer Application"
    Supervisor.start_link(children, strategy: :one_for_one)
  end
end
