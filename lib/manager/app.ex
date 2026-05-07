defmodule Gfs.Manager.App do
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # `:pg` scope used by chunkservers to register themselves so the
      # manager can discover them without SQL/HTTP-port lookups.
      %{
        id: :pg,
        start: {:pg, :start_link, []}
      },
      Gfs.Manager.Repo,
      {Bandit, plug: Gfs.Manager.RestApi},
      Gfs.Manager.Task.MonitorNodes,
      Gfs.Manager.Task.ExpireLeases
    ]

    IO.puts("Starting GFS Manager Application")
    Supervisor.start_link(children, strategy: :one_for_one)
  end
end
