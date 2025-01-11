defmodule Gfs.Manager.App do
  use Application
  use GenServer

  @impl true
  def init(arg) do
    {:ok, arg}
  end

  @impl true
  def start(_type, _args) do
    registered_nodes = Gfs.Manager.Repo.all(Schema.Node)
    Enum.each(registered_nodes, fn node -> connect_to_node(node) end)

    children = [
      Gfs.Manager.Repo,
      {Bandit, plug: Gfs.Manager.RestApi},
      Gfs.Task.MonitorNodes
    ]
    IO.puts "Starting GFS Manager Application"
    Supervisor.start_link(children, strategy: :one_for_one)
  end

  defp connect_to_node(name) do
    IO.puts("Attempting connection to registered node: #{name}")

    case Node.connect(name) do
      true -> IO.puts("Connected to node #{name}")
      false -> IO.puts("Unable to connect to node #{name}")
      :ignored -> IO.puts("Node #{name} is offline")
    end
  end
end
