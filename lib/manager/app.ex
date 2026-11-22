defmodule Gfs.Manager.App do
  use Application

  @impl true
  def start(_type, %{runtime: runtime}) do
    children = [
      # `:pg` scope used by chunkservers to register themselves so the
      # manager can discover them without SQL/HTTP-port lookups.
      %{
        id: :pg,
        start: {:pg, :start_link, []}
      },
      Gfs.Manager.Repo,
      {Bandit, plug: {Gfs.Manager.RestApi, runtime}},
      {Gfs.Manager.Task.MonitorNodes, runtime},
      {Gfs.Manager.Task.ExpireLeases, runtime}
    ]

    IO.puts("Starting GFS Manager Application")
    Supervisor.start_link(children, strategy: :one_for_one)
  end
end
