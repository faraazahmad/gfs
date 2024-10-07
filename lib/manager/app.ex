defmodule Gfs.Manager.App do
  use Application
  use GenServer

  @impl true
  def init(arg) do
    {:ok, arg}
  end

  @impl true
  def start(_type, _args) do
    nodes = Application.fetch_env!(:gfs, :nodes)
    Enum.each(nodes, fn node -> connect_to_node(node) end)

    children = [
      Gfs.Manager.Repo,
      # {Bandit, plug: Gfs.Manager.RestApi},
      Gfs.Task.MonitorNodes
    ]
    IO.puts "Starting GFS Manager Application"
    Supervisor.start_link(children, strategy: :one_for_one)
  end

  defp connect_to_node(name) do
    IO.puts "Connecting to node #{name}"
    Node.connect(name)
  end
end
