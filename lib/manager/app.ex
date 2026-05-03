defmodule Gfs.Manager.App do
  use Application
  use GenServer

  @impl true
  def init(arg) do
    {:ok, arg}
  end

  @impl true
  def start(_type, _args) do
    children = [
      Gfs.Manager.Repo,
      {Bandit, plug: Gfs.Manager.RestApi},
      Gfs.Manager.Task.MonitorNodes,
      Gfs.Manager.Task.ExpireLeases
    ]
    IO.puts "Starting GFS Manager Application"
    Supervisor.start_link(children, strategy: :one_for_one)
  end
end
